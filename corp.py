#!/usr/bin/env python3
# =============================================================================
# corp.py -- corporate-API search backend (Azure OpenAI compatible, tadori 契約)
# -----------------------------------------------------------------------------
# Switches the QA broker's retrieval from local Ollama to the CORPORATE API:
#   * settings (SPO segments URL + corp API config) come from the browser's
#     localStorage (qa:* keys set by the settings screen), read via CDP.
#   * query embedding via  {base}/openai/deployments/{deploy}/embeddings
#   * answer via           {base}/openai/deployments/{deploy}/chat/completions
#     (`base` is the corp gateway directly, or a loopback relay that forwards.)
#   * documents are tadori's pre-computed segments stored in SPO (float16/base64
#     embeddings), loaded via the browser session (CDP), then brute-force cosine.
#
# NOTE: the exact segment file layout (manifest + seg files) mirrors tadori's
# documented format; adjust load_segments() if your tadori output differs.
# The corp API is only reachable inside the corporate env, so the embed/chat
# calls cannot be exercised here — they are implemented to tadori's exact
# contract and unit-mocked (see tests in scratchpad).
# =============================================================================
import base64
import json
import math
import struct
from urllib.parse import urlparse

import requests


def _proxies_for(base):
    # base can be a loopback relay OR the corp gateway directly:
    #   - loopback (127.0.0.1/localhost) -> bypass the corporate proxy
    #   - remote gateway                 -> go through it (requests honors env HTTP(S)_PROXY)
    host = (urlparse(base).hostname or "").lower()
    return {"http": None, "https": None} if host in ("127.0.0.1", "localhost", "::1") else None
# Settings come from the ⚙ screen; keys mirror tadori (shared localStorage) + qa:segUrl.
SETTING_KEYS = ["qa:segUrl", "tadori:ai:corp:base-url", "tadori:ai:corp:deploy-prefix",
                "tadori:ai:corp:model", "tadori:embedding-model", "tadori:api-version",
                "tadori:dimensions", "tadori:ai:corp:key"]
REASONING = {"gpt-5", "gpt-5-mini", "gpt-5-nano", "o3", "o4-mini"}   # tadori: reasoning -> preview apiVersion


def read_settings(cdp):
    """Read settings from the browser's localStorage via CDP. Chat and embedding
    models are separate; the Azure deployment name = prefix + model (dots removed)."""
    js = "(function(){var o={};" + "".join(
        "o['%s']=localStorage.getItem('%s');" % (k, k) for k in SETTING_KEYS) + "return JSON.stringify(o);})()"
    raw = cdp.evaluate(js, False)
    d = json.loads(raw) if raw else {}
    prefix = d.get("tadori:ai:corp:deploy-prefix") or ""
    chat_model = d.get("tadori:ai:corp:model") or ""
    embed_model = d.get("tadori:embedding-model") or ""
    def dep(m):
        return (prefix + m.replace(".", "")) if m else ""
    dim = d.get("tadori:dimensions") or ""
    return {
        "seg_url": (d.get("qa:segUrl") or "").rstrip("/"),
        "base": (d.get("tadori:ai:corp:base-url") or "").rstrip("/"),
        "chat_model": chat_model,
        "embed_model": embed_model,
        "chat_deploy": dep(chat_model),
        "embed_deploy": dep(embed_model),
        "dimensions": int(dim) if dim.isdigit() else None,
        "embed_api_version": d.get("tadori:api-version") or "2024-02-01",
        "chat_api_version": "2024-12-01-preview" if chat_model in REASONING else "2024-06-01",
        "api_key": d.get("tadori:ai:corp:key") or "",
    }


def enabled(s):
    """Corp search is active only when the essential settings are present."""
    return bool(s.get("seg_url") and s.get("base") and s.get("api_key") and s.get("embed_deploy"))


# --- float16 <-> float32 (matches tadori encodeEmbedding: LE uint16, base64) ---
def _f16_to_f32(h):
    sign = (h & 0x8000) << 16
    exp = (h & 0x7c00) >> 10
    mant = h & 0x03ff
    if exp == 0:
        if mant == 0:
            bits = sign
        else:
            e = -1
            m = mant
            while (m & 0x400) == 0:
                e += 1
                m <<= 1
            m &= 0x03ff
            bits = sign | ((e + 127 - 15 + 1) << 23) | (m << 13)
    elif exp == 0x1f:
        bits = sign | 0x7f800000 | (mant << 13)
    else:
        bits = sign | ((exp - 15 + 127) << 23) | (mant << 13)
    return struct.unpack("<f", struct.pack("<I", bits & 0xffffffff))[0]


def decode_embedding(b64):
    raw = base64.b64decode(b64)
    n = len(raw) // 2
    return [_f16_to_f32(h) for h in struct.unpack("<%dH" % n, raw[:n * 2])]


# --- corp API (Azure OpenAI compatible) --------------------------------------
def embed(s, text):
    url = "%s/openai/deployments/%s/embeddings?api-version=%s" % (s["base"], s["embed_deploy"], s.get("embed_api_version", "2024-02-01"))
    body = {"input": [text]}
    if s.get("dimensions"):
        body["dimensions"] = s["dimensions"]
    r = requests.post(url, headers={"Content-Type": "application/json", "api-key": s["api_key"]},
                      json=body, timeout=120, proxies=_proxies_for(s["base"]))
    r.raise_for_status()
    return r.json()["data"][0]["embedding"]


def chat(s, messages):
    url = "%s/openai/deployments/%s/chat/completions?api-version=%s" % (s["base"], s["chat_deploy"], s.get("chat_api_version", "2024-06-01"))
    r = requests.post(url, headers={"Content-Type": "application/json", "api-key": s["api_key"]},
                      json={"messages": messages}, timeout=300, proxies=_proxies_for(s["base"]))
    r.raise_for_status()
    return (r.json()["choices"][0]["message"]["content"] or "").strip()


# --- segments (tadori pre-vectorized docs, stored in SPO) --------------------
def _sp_json(cdp, url):
    js = ("(async()=>{const r=await fetch(encodeURI(%s)+((%s).indexOf('?')>=0?'&':'?')+'_='+Date.now(),"
          "{credentials:'include',cache:'no-cache'});if(!r.ok)throw new Error('HTTP '+r.status);"
          "return await r.text();})()" % (json.dumps(url), json.dumps(url)))
    txt = cdp.evaluate(js, True)
    return json.loads(txt)


def load_segments(cdp, seg_url):
    """Load tadori segments from SPO via the browser session.
    Assumes: <seg_url>/manifest.json lists seg file names; each seg file is a
    list of records (or {records:[...]}) with base64-float16 `embedding`."""
    manifest = _sp_json(cdp, seg_url + "/manifest.json")
    files = manifest.get("files") or manifest.get("segments") or manifest.get("seg") or []
    out = []
    for f in files:
        u = f if str(f).startswith("http") else (seg_url + "/" + f)
        seg = _sp_json(cdp, u)
        recs = seg.get("records") if isinstance(seg, dict) else seg
        for r in (recs or []):
            emb = r.get("embedding")
            if isinstance(emb, str):
                emb = decode_embedding(emb)
            if not emb:
                continue
            out.append({
                "id": r.get("id"),
                "section": r.get("subject") or r.get("slideTitle") or r.get("from") or "",
                "text": r.get("body") or "",
                "embedding": emb,
                "meta": r,
            })
    return out


# --- brute-force cosine (L2-normalized dot; tadori ADR-008) ------------------
def _norm(v):
    n = math.sqrt(sum(x * x for x in v)) or 1.0
    return [x / n for x in v]


def search(cdp, s, segments, question, top_k):
    q = _norm(embed(s, question))
    scored = []
    for seg in segments:
        e = seg["embedding"]
        if len(e) != len(q):
            continue
        en = _norm(e)
        dot = 0.0
        for i in range(len(q)):
            dot += q[i] * en[i]
        scored.append((dot, seg))
    scored.sort(key=lambda t: t[0], reverse=True)
    return [seg for _, seg in scored[:top_k]]
