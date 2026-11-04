#!/usr/bin/env python3
"""Mechanical check of translator output for one locale (and optionally one chunk), reusing the importer's own rules.

Usage: python -X utf8 tools/fleet/i18n-check.py <locale> [<chunk e.g. 03>]   (folder: $NIB_I18N or ../Nib-i18n)
Prints one JSON object: {"locale", "checked", "problems": [{"chunk", "key", "reason", "severity"}]}.
severity "error" = the importer would reject it (missing key, specifier mismatch, plural form gap, empty, bad JSON);
severity "check" = identical to the English source although it has translatable words (translate it, or accept it when it
is only a brand or technical term).
"""
import glob
import json
import os
import re
import sys

import pathlib
REPO = pathlib.Path(__file__).resolve().parents[2]            # this file lives in tools/fleet/
ROOT = os.environ.get("NIB_I18N") or str(REPO.parent / "Nib-i18n")   # in/<locale>/*.json, out/<locale>/*.json, qa/
sys.path.insert(0, str(REPO / "Scripts"))
import extract_strings as es  # noqa: E402  (validate_translation, REQUIRED_PLURALS)

BRANDS = {
    "nib", "apple", "pencil", "icloud", "drive", "onedrive", "dropbox", "google", "webdav", "pdf", "markdown", "latex",
    "mcp", "ollama", "lm", "studio", "openrouter", "anthropic", "claude", "openai", "chatgpt", "giphy", "image",
    "playground", "airprint", "voiceover", "tailscale", "altstore", "sidestore", "goodnotes", "gif", "png", "jpeg", "jpg",
    "csv", "json", "qr", "url", "http", "https", "ipad", "iphone", "ios", "ipados", "mac", "files", "wi", "fi", "bluetooth",
    "ok", "id", "api", "siri", "codex", "whisper", "bonjour", "txt", "docx", "epub", "rtf", "html", "zip", "sha", "uuid",
    "metal", "vision", "testflight", "xcode", "swift", "lan", "usb", "pro", "max", "mini", "air", "tb", "gb", "mb", "kb",
    "ms", "px", "pt", "mm", "cm", "in", "dpi", "fps", "hz", "khz", "a4", "a5", "a3", "b5", "letter", "legal", "tabloid",
    "x", "y", "z", "n", "ai", "llm", "gpt", "sonnet", "opus", "haiku", "gemini", "llama", "mistral", "deepseek", "qwen",
    "emoji", "lasso", "tape", "bluetooth", "multipeer", "eventkit", "pencilkit", "quicknote", "unicode", "utf", "ascii",
}


def brand_only(text):
    words = re.findall(r"[A-Za-z][A-Za-z'’\-]*", text)
    return all(w.lower().strip("'’-") in BRANDS for w in words)


def main():
    loc = sys.argv[1]
    only = sys.argv[2] if len(sys.argv) > 2 else None
    problems, checked = [], 0
    files = sorted(glob.glob(os.path.join(ROOT, "in", loc, "*.json")))
    if only:
        files = [f for f in files if os.path.basename(f) == only + ".json" or os.path.basename(f) == only]
    for f in files:
        chunk = os.path.basename(f)
        source = json.load(open(f, encoding="utf-8"))
        out_path = os.path.join(ROOT, "out", loc, chunk)
        if not os.path.exists(out_path):
            problems.append({"chunk": chunk, "key": None, "reason": "output file missing", "severity": "error"})
            continue
        try:
            out = json.load(open(out_path, encoding="utf-8"))
        except Exception as error:  # noqa: BLE001
            problems.append({"chunk": chunk, "key": None, "reason": "invalid JSON: %s" % error, "severity": "error"})
            continue
        if not isinstance(out, dict):
            problems.append({"chunk": chunk, "key": None, "reason": "top level must be an object", "severity": "error"})
            continue
        for key, info in source.items():
            checked += 1
            src = info["value"]
            value = out.get(key)
            if value is None:
                problems.append({"chunk": chunk, "key": key, "reason": "missing", "severity": "error"})
                continue
            why = es.validate_translation(key, src, value, loc)
            if why:
                problems.append({"chunk": chunk, "key": key, "reason": why, "severity": "error"})
                continue
            if isinstance(value, str) and value == src and re.search(r"[A-Za-z]{2,}", src) and not brand_only(src):
                problems.append({"chunk": chunk, "key": key, "severity": "check",
                                 "reason": "identical to English; translate it unless it is only a brand/technical term"})
        for key in out:
            if key not in source:
                problems.append({"chunk": chunk, "key": key, "reason": "unexpected key (not in the input)", "severity": "error"})
    errors = sum(1 for p in problems if p["severity"] == "error")
    print(json.dumps({"locale": loc, "checked": checked, "errors": errors, "problems": problems}, ensure_ascii=False, indent=1))


if __name__ == "__main__":
    main()
