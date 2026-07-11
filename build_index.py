#!/usr/bin/env python3
# =============================================================================
# build_index.py -- offline: chunk knowledge/manual.md and pre-compute embeddings
# -----------------------------------------------------------------------------
# Splits the manual by '## ' sections (windowing long ones with overlap),
# embeds each chunk with Ollama, and writes knowledge/index.json which the
# broker loads for retrieval. Run this whenever the manual changes.
#   python build_index.py
# =============================================================================
import json
import os
import re
import sys

import requests

HERE = os.path.dirname(os.path.abspath(__file__))
MANUAL = os.path.join(HERE, "knowledge", "manual.md")
OUT = os.path.join(HERE, "knowledge", "index.json")
MAX_CHARS = 900
OVERLAP = 150


def load_cfg():
    p = os.path.join(HERE, "config.json")
    if os.path.exists(p):
        with open(p, "r", encoding="utf-8") as f:
            return json.load(f)
    return {}


cfg = load_cfg()
OLLAMA = cfg.get("ollama_endpoint", "http://localhost:11434").rstrip("/")
EMBED_MODEL = cfg.get("embed_model", "nomic-embed-text")


def split_sections(md):
    """Return [(heading, text)] split on level-2 '## ' headings; preamble kept."""
    parts = re.split(r"(?m)^(##\s+.*)$", md)
    out = []
    pre = parts[0].strip()
    if pre:
        out.append(("はじめに", pre))
    for i in range(1, len(parts), 2):
        head = parts[i].strip().lstrip("#").strip()
        body = parts[i + 1] if i + 1 < len(parts) else ""
        out.append((head, (parts[i] + "\n" + body).strip()))
    return out


def windows(text, size, overlap):
    if len(text) <= size:
        return [text]
    res, i = [], 0
    while i < len(text):
        res.append(text[i:i + size])
        if i + size >= len(text):
            break
        i += size - overlap
    return res


def embed(text):
    r = requests.post(OLLAMA + "/api/embeddings", json={"model": EMBED_MODEL, "prompt": text},
                      timeout=120, proxies={"http": None, "https": None})
    r.raise_for_status()
    return r.json()["embedding"]


def main():
    if not os.path.exists(MANUAL):
        print("manual not found:", MANUAL); sys.exit(1)
    with open(MANUAL, "r", encoding="utf-8") as f:
        md = f.read()

    chunks = []
    for head, body in split_sections(md):
        for w in windows(body, MAX_CHARS, OVERLAP):
            chunks.append({"id": len(chunks), "section": head, "text": w})

    print("embedding %d chunks with '%s' ..." % (len(chunks), EMBED_MODEL))
    doc_prefix = "search_document: " if EMBED_MODEL.startswith("nomic") else ""
    for c in chunks:
        c["embedding"] = embed(doc_prefix + c["text"])
    dim = len(chunks[0]["embedding"]) if chunks else 0

    os.makedirs(os.path.dirname(OUT), exist_ok=True)
    with open(OUT, "w", encoding="utf-8") as f:
        json.dump({"model": EMBED_MODEL, "dim": dim, "chunks": chunks}, f, ensure_ascii=False)
    print("wrote %s: %d chunks, dim=%d" % (OUT, len(chunks), dim))
    print("sections:", sorted(set(c["section"] for c in chunks)))


if __name__ == "__main__":
    main()
