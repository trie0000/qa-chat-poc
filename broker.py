#!/usr/bin/env python3
# =============================================================================
# broker.py -- local broker for the QA chat PoC
# -----------------------------------------------------------------------------
# Responsibilities:
#   * launch Edge/Chrome with --remote-debugging-port (dedicated profile)
#   * connect over CDP (raw JSON via websocket-client)
#   * wait for the user to sign in to SPO in the browser
#   * fetch chat-ui.js from the SPO library (browser fetch) and inject it (CDP)
#   * poll the list for PA-"Detected" items, generate answers with Ollama,
#     write them back (ETag optimistic lock), and log per-turn latency
#
# The broker holds NO SPO credentials: every SPO REST call runs as a browser
# fetch inside the authenticated page (via CDP Runtime.evaluate).
# =============================================================================
import csv
import datetime
import json
import math
import os
import subprocess
import sys
import time
import urllib.request
import uuid

import requests
import websocket  # websocket-client

import corp  # corporate-API search backend (embeddings + chat + SPO segments)

HERE = os.path.dirname(os.path.abspath(__file__))
DEFAULT_SYSTEM = "あなたは社内システムマニュアルのQAアシスタントです。簡潔に日本語で回答してください。"


def log(msg):
    print("[broker] " + msg, flush=True)


def utcnow():
    return datetime.datetime.now(datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def load_config():
    path = os.path.join(HERE, "config.json")
    if not os.path.exists(path):
        log("config.json がありません。config.example.json をコピーして設定してください。")
        sys.exit(2)
    with open(path, "r", encoding="utf-8") as f:
        return json.load(f)


# --- CDP client --------------------------------------------------------------
class Cdp:
    def __init__(self, ws_url):
        # suppress_origin: Chromium 111+ rejects CDP WS handshakes whose Origin header
        # is not in --remote-allow-origins. Sending no Origin header is accepted.
        self.ws = websocket.create_connection(ws_url, timeout=180, enable_multithread=True,
                                              suppress_origin=True,
                                              http_no_proxy=["127.0.0.1", "localhost", "::1"])
        self._id = 0

    def call(self, method, params=None):
        self._id += 1
        mid = self._id
        self.ws.send(json.dumps({"id": mid, "method": method, "params": params or {}}))
        while True:
            msg = json.loads(self.ws.recv())
            if msg.get("id") == mid:
                if "error" in msg:
                    raise RuntimeError("CDP %s error: %s" % (method, json.dumps(msg["error"])))
                return msg.get("result", {})
            # otherwise it's an event -> ignore

    def evaluate(self, expression, await_promise=True):
        r = self.call("Runtime.evaluate", {
            "expression": expression, "returnByValue": True,
            "awaitPromise": await_promise, "userGesture": True,
        })
        if "exceptionDetails" in r:
            raise RuntimeError("JS exception: " + json.dumps(r["exceptionDetails"])[:600])
        return r.get("result", {}).get("value")


# --- SPO REST via browser fetch ---------------------------------------------
def build_fetch_js(url, method, body, digest, odata, extra_headers):
    headers = {"Accept": "application/json;odata=%s" % odata}
    if body is not None:
        headers["Content-Type"] = "application/json;odata=%s" % odata
    if extra_headers:
        headers.update(extra_headers)
    if digest and method != "GET":
        headers["X-RequestDigest"] = digest
    opts = {"url": url, "method": method, "headers": headers, "body": body}
    o = json.dumps(opts, ensure_ascii=False)
    return (
        "(async()=>{const o=%s;"
        "const r=await fetch(encodeURI(o.url),{method:o.method,headers:o.headers,"
        "credentials:'include',body:(o.body!=null?JSON.stringify(o.body):undefined)});"
        "const t=await r.text();let j=null;try{j=JSON.parse(t)}catch(e){}"
        "return{status:r.status,ok:r.ok,etag:r.headers.get('etag'),json:j,text:t.slice(0,500)};})()"
    ) % o


class Spo:
    """SPO REST over CDP browser-fetch, with cached form digest."""
    def __init__(self, cdp, site):
        self.cdp = cdp
        self.site = site.rstrip("/")
        self._digest = None
        self._digest_exp = 0

    def digest(self):
        if self._digest and time.time() < self._digest_exp:
            return self._digest
        r = self.raw("/_api/contextinfo", method="POST")
        j = r["json"]
        self._digest = j["FormDigestValue"]
        self._digest_exp = time.time() + (j.get("FormDigestTimeoutSeconds", 1800) - 300)
        return self._digest

    def raw(self, rel, method="GET", body=None, odata="nometadata", extra_headers=None, use_digest=False):
        digest = self.digest() if use_digest else None
        js = build_fetch_js(self.site + rel, method, body, digest, odata, extra_headers)
        return self.cdp.evaluate(js, await_promise=True)

    def write(self, rel, body, extra_headers=None):
        """POST/MERGE with digest; retry once on 403 (digest refresh)."""
        res = self.raw(rel, method="POST", body=body, extra_headers=extra_headers, use_digest=True)
        if res.get("status") == 403:
            self._digest = None
            res = self.raw(rel, method="POST", body=body, extra_headers=extra_headers, use_digest=True)
        return res


# --- browser + CDP bootstrap -------------------------------------------------
def launch_browser(cfg):
    profile = os.path.join(HERE, ".edgeprofile")
    port = cfg.get("cdp_port", 9222)
    args = [
        cfg["browser_path"],
        "--remote-debugging-port=%d" % port,
        "--remote-allow-origins=*",   # allow the CDP WebSocket handshake (Chromium 111+)
        "--user-data-dir=%s" % profile,
        "--no-first-run", "--no-default-browser-check",
        cfg["site_url"],
    ]
    log("launching browser (CDP port %d, dedicated profile)" % port)
    subprocess.Popen(args)


# loopback must bypass any corporate proxy (urllib/requests otherwise route 127.0.0.1
# through the proxy and fail; Windows' WinHTTP bypasses loopback by default but Python does not).
NO_PROXY_OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))


def connect_cdp(port):
    base = "http://127.0.0.1:%d" % port
    deadline = time.time() + 120
    last_err = "endpoint not up (debug port never opened?)"
    while time.time() < deadline:
        try:
            data = NO_PROXY_OPENER.open(base + "/json", timeout=2).read().decode("utf-8")
            targets = json.loads(data)
            pages = [t for t in targets if t.get("type") == "page" and t.get("webSocketDebuggerUrl")]
            pref = [t for t in pages if any(s in (t.get("url") or "")
                                            for s in ("sharepoint.com", "microsoftonline", "/_forms/", "login"))]
            pick = pref or pages
            if not pick:
                last_err = "no page target yet (%d targets)" % len(targets)
            else:
                return Cdp(pick[0]["webSocketDebuggerUrl"])   # may raise (WS handshake) -> captured below
        except Exception as e:
            last_err = "%s: %s" % (type(e).__name__, e)
        time.sleep(0.5)
    raise RuntimeError(
        "CDP に接続できません (port %d)。原因: %s\n"
        "  対処: (1) Edge を全ウィンドウ閉じてから再実行  "
        "(2) 失敗後に http://127.0.0.1:%d/json/version をブラウザで開き、"
        "JSONが出なければデバッグポート未開放=社内ポリシーでリモートデバッグ無効の可能性  "
        "(3) 社内プロキシ環境変数(HTTP_PROXY等)が 127.0.0.1 を素通ししているか確認" % (port, last_err, port))


def wait_for_auth(spo):
    log("Waiting for sign-in. Please sign in to SharePoint in the browser window...")
    while True:
        try:
            res = spo.raw("/_api/web?$select=Title")
            if res.get("ok"):
                title = (res.get("json") or {}).get("Title")
                log('authenticated (Web="%s")' % title)
                return
        except Exception:
            pass
        time.sleep(2)


def inject_ui(cdp, spo, cfg, session_id):
    ui_url = cfg["ui_code_url"]
    # cache-bust so the SPO-hosted latest is always fetched (not a stale cached copy)
    bust = ui_url + ("&" if "?" in ui_url else "?") + "_=" + str(int(time.time()))
    src = cdp.evaluate(
        "(async()=>{const r=await fetch(%s,{cache:'no-cache',credentials:'include'});"
        "if(!r.ok)throw new Error('ui fetch '+r.status);return await r.text();})()" % json.dumps(bust),
        await_promise=True,
    )
    if not src or len(src) < 50:
        raise RuntimeError("UI code fetch returned empty (check ui_code_url)")
    log("UI code fetched: %d chars" % len(src))

    qa_cfg = {
        "listTitle": cfg["list_title"],
        "sessionId": session_id,
        "pollIntervalMs": cfg.get("poll_interval_ms", 2500),
        "webUrl": spo.site,
    }
    prelude = "window.__QA_CONFIG__=%s;" % json.dumps(qa_cfg, ensure_ascii=False)
    cdp.evaluate(prelude + "true", await_promise=False)   # set config first
    cdp.evaluate(src, await_promise=False)                 # then run the UI

    # reload persistence: re-inject on every new document (loader stays on SPO)
    boot = prelude + ("(async()=>{try{var u=%s;u+=(u.indexOf('?')>=0?'&':'?')+'_='+Date.now();"
                      "const r=await fetch(u,{cache:'no-cache',credentials:'include'});"
                      "const t=await r.text();(0,eval)(t);}catch(e){console.warn('QA reinject',e);}})();"
                      % json.dumps(ui_url))
    try:
        cdp.call("Page.enable")
        cdp.call("Page.addScriptToEvaluateOnNewDocument", {"source": boot})
    except Exception as e:
        log("(reload persistence not set: %s)" % e)


# --- retrieval (RAG over the pre-computed manual index) ----------------------
def load_index(cfg):
    path = cfg.get("knowledge_index")
    if not path:
        return None
    p = path if os.path.isabs(path) else os.path.join(HERE, path)
    if not os.path.exists(p):
        return None
    with open(p, "r", encoding="utf-8") as f:
        return json.load(f)


def _cosine(a, b):
    dot = 0.0; na = 0.0; nb = 0.0
    for x, y in zip(a, b):
        dot += x * y; na += x * x; nb += y * y
    return dot / (math.sqrt(na) * math.sqrt(nb)) if na and nb else 0.0


def embed_query(cfg, text):
    url = cfg.get("ollama_endpoint", "http://localhost:11434").rstrip("/") + "/api/embeddings"
    # nomic-embed-text query prefix (must match the "search_document:" prefix used at build time)
    prompt = "search_query: " + text if str(cfg.get("embed_model", "")).startswith("nomic") else text
    r = requests.post(url, json={"model": cfg.get("embed_model", "nomic-embed-text"), "prompt": prompt},
                      timeout=120, proxies={"http": None, "https": None})
    r.raise_for_status()
    return r.json()["embedding"]


def retrieve(cfg, index, question):
    if not index or not index.get("chunks"):
        return []
    q = embed_query(cfg, question)
    scored = [(_cosine(q, c["embedding"]), c) for c in index["chunks"]]
    scored.sort(key=lambda t: t[0], reverse=True)
    return [c for _, c in scored[: cfg.get("top_k", 4)]]


# --- answer generation -------------------------------------------------------
def build_system(cfg, chunks):
    """System prompt + retrieved context. Framed as 'read then answer' (not
    refuse-first) so smaller models still extract facts that are present."""
    system = cfg.get("system_prompt", DEFAULT_SYSTEM)
    if chunks:
        ctx = "\n\n".join("【%s】\n%s" % (c["section"], c["text"]) for c in chunks)
        system += (
            "\n\n以下の【参考資料】をよく読み、質問に答えてください。"
            "\n- 参考資料に根拠がある場合は、その内容（数値・条件も含む）を使って具体的に答えてください。"
            "\n- 参考資料のどこにも関連する記述が無い場合に限り「資料に記載がありません」と答えてください。"
            "\n- 最後に参照した見出しを示してください。"
            "\n\n===== 参考資料 =====\n" + ctx
        )
    return system


def build_messages(spo, by_list, cfg, session_id, cur_turn, cur_question, rag):
    hist_max = cfg.get("history_max_turns", 10)
    q = (by_list + "/items?$select=Turn,Question,Answer&$filter=SessionId eq '%s' and Status eq 'Answered'"
         "&$orderby=Turn asc&$top=200") % session_id
    res = spo.raw(q)
    rows = [r for r in ((res.get("json") or {}).get("value", [])) if r.get("Turn", 0) < cur_turn]
    rows = rows[-hist_max:]

    if rag.get("mode") == "corp":
        chunks = corp.search(rag["cdp"], rag["settings"], rag["segments"], cur_question, cfg.get("top_k", 4))
    else:
        chunks = retrieve(cfg, rag.get("index"), cur_question)
    if chunks:
        log("retrieved: %s" % [c.get("section") for c in chunks])
    messages = [{"role": "system", "content": build_system(cfg, chunks)}]
    for r in rows:
        messages.append({"role": "user", "content": (r.get("Question") or "")[:2000]})
        messages.append({"role": "assistant", "content": (r.get("Answer") or "")[:2000]})
    messages.append({"role": "user", "content": (cur_question or "")[:2000]})
    return messages


def ollama_chat(cfg, messages):
    url = cfg.get("ollama_endpoint", "http://localhost:11434").rstrip("/") + "/api/chat"
    payload = {"model": cfg.get("ollama_model", "gemma3:4b"), "messages": messages, "stream": False}
    r = requests.post(url, json=payload, timeout=600, proxies={"http": None, "https": None})
    r.raise_for_status()
    return (r.json().get("message", {}).get("content", "") or "").strip()


# --- latency logging ---------------------------------------------------------
LAT_HEADER = ["SessionId", "Turn", "CreatedAt", "PA_DetectedAt",
              "Broker_PickedAt", "AnsweredAt", "DisplayedAt"]


def log_latency(row):
    os.makedirs(os.path.join(HERE, "logs"), exist_ok=True)
    path = os.path.join(HERE, "logs", "latency.csv")
    new = not os.path.exists(path)
    with open(path, "a", newline="", encoding="utf-8-sig") as f:
        w = csv.writer(f)
        if new:
            w.writerow(LAT_HEADER)
        w.writerow(row)


# --- main loop ---------------------------------------------------------------
def handle_detected(spo, by_list, cfg, session_id, it, picked, rag):
    item_id = it["Id"]
    turn = it.get("Turn", 0)
    etag = it.get("odata.etag") or "*"
    picked_at = utcnow()

    claim = spo.write(by_list + "/items(%d)" % item_id, {"Status": "Answering"},
                      extra_headers={"X-HTTP-Method": "MERGE", "If-Match": etag})
    if not claim.get("ok"):
        if claim.get("status") == 412:
            return  # another broker/worker claimed it
        log("claim failed item %d: %s %s" % (item_id, claim.get("status"), claim.get("text")))
        return
    picked[item_id] = picked_at
    log("picked item %d (turn %d)" % (item_id, turn))

    try:
        messages = build_messages(spo, by_list, cfg, session_id, turn, it.get("Question", ""), rag)
        answer = corp.chat(rag["settings"], messages) if rag.get("mode") == "corp" else ollama_chat(cfg, messages)
        spo.write(by_list + "/items(%d)" % item_id,
                  {"Answer": answer, "Status": "Answered", "AnsweredAt": utcnow()},
                  extra_headers={"X-HTTP-Method": "MERGE", "If-Match": "*"})
        log("answered item %d (%d chars)" % (item_id, len(answer)))
    except Exception as e:
        try:
            spo.write(by_list + "/items(%d)" % item_id,
                      {"Answer": ("[error] %s" % e)[:1900], "Status": "Error"},
                      extra_headers={"X-HTTP-Method": "MERGE", "If-Match": "*"})
        except Exception:
            pass
        log("handle error on item %d: %s" % (item_id, e))


def reap_latency(spo, by_list, session_id, picked, logged):
    """Collect fully-completed turns (DisplayedAt written by UI) into latency.csv."""
    q = (by_list + "/items?$select=Id,Turn,Created,DetectedAt,AnsweredAt,DisplayedAt"
         "&$filter=SessionId eq '%s' and Status eq 'Answered'&$orderby=Turn asc&$top=200") % session_id
    res = spo.raw(q)
    for it in (res.get("json") or {}).get("value", []):
        if it["Id"] in logged:
            continue
        if not it.get("DisplayedAt"):
            continue
        log_latency([
            session_id, it.get("Turn"),
            it.get("Created", ""), it.get("DetectedAt", ""),
            picked.get(it["Id"], ""), it.get("AnsweredAt", ""), it.get("DisplayedAt", ""),
        ])
        logged.add(it["Id"])


def monitor(spo, cfg, session_id, rag):
    by_list = "/_api/web/lists/getbytitle('%s')" % cfg["list_title"]
    poll_s = cfg.get("poll_interval_ms", 2500) / 1000.0
    picked = {}     # item_id -> broker pick time
    logged = set()  # item_ids already written to latency.csv
    log("monitoring list '%s' for Detected items (session %s)" % (cfg["list_title"], session_id))
    while True:
        try:
            q = (by_list + "/items?$select=Id,Turn,Question,Status&$filter=SessionId eq '%s' and Status eq 'Detected'"
                 "&$orderby=Turn asc&$top=50") % session_id
            res = spo.raw(q, odata="minimalmetadata")  # minimalmetadata -> per-item odata.etag
            for it in (res.get("json") or {}).get("value", []):
                handle_detected(spo, by_list, cfg, session_id, it, picked, rag)
            reap_latency(spo, by_list, session_id, picked, logged)
        except Exception as e:
            log("monitor loop error: %s" % e)
        time.sleep(poll_s)


def main():
    cfg = load_config()
    session_id = str(uuid.uuid4())
    log("session %s" % session_id)
    launch_browser(cfg)
    cdp = connect_cdp(cfg.get("cdp_port", 9222))
    log("CDP connected")
    spo = Spo(cdp, cfg["site_url"])
    wait_for_auth(spo)
    inject_ui(cdp, spo, cfg, session_id)
    log("UI injected")

    # Retrieval backend: corp API (if settings screen is configured) else local Ollama index.
    cs = corp.read_settings(cdp)
    rag = None
    if corp.enabled(cs):
        try:
            segments = corp.load_segments(cdp, cs["seg_url"])
            rag = {"mode": "corp", "settings": cs, "segments": segments, "cdp": cdp}
            log("corp search ON: %d segments (base=%s embed=%s chat=%s)"
                % (len(segments), cs["base"], cs["embed_deploy"], cs["chat_deploy"]))
        except Exception as e:
            log("corp segments load failed (%s) -> falling back to local Ollama" % e)
    if rag is None:
        index = load_index(cfg)
        rag = {"mode": "local", "index": index}
        log("local Ollama RAG: %d chunks" % len(index.get("chunks", [])) if index else "no knowledge (plain chat)")
    monitor(spo, cfg, session_id, rag)


if __name__ == "__main__":
    try:
        main()
    except KeyboardInterrupt:
        pass
