#!/usr/bin/env python3
"""Builds the app's string catalog, Nib/Resources/Localizable.xcstrings, from the Swift sources (F095, P-087).

What it extracts (string literals only; a key built at run time cannot be translated):
  * `String(localized: "…")`, `AttributedString(localized: "…")`, `LocalizedStringResource("…")`,
    `LocalizedStringKey("…")` and `NSLocalizedString("…", comment: "…")`, with `defaultValue:`, `table:`,
    `bundle:` and `comment:` honoured;
  * SwiftUI's LocalizedStringKey sites: `Text("…")` (never `Text(verbatim:)`), `Button("…")`, `Toggle("…")`,
    `Label("…", …)`, `Section("…")`, `Picker("…")`, `Menu("…")`, `TextField("…")`, `Link("…")`, `Tab("…")` and the
    rest of `SWIFTUI_INITS`, plus `.navigationTitle("…")`, `.accessibilityLabel("…")`, `.accessibilityHint("…")`,
    `.help("…")`, `.alert("…")`, `.confirmationDialog("…")` and `.accessibilityAction(named: "…")`.
Interpolations become the format specifiers Swift emits (`%@`, `%lld`, `%lf`, `%.1f` from `specifier:`). The type of
an interpolated value is taken from the compiler when a build left `.stringsdata` files behind (`--stringsdata DIR`,
e.g. DerivedData; Xcode writes one per Swift file), else inferred from the declarations in the file and its module.

Where each string goes:
  * every feature module, NibContracts and the app target (`Nib/`) → the app catalog: a package module that calls
    `String(localized:)` without `bundle:` looks its strings up in `Bundle.main`, which is the app;
  * `bundle: .module` strings (NibDesign) → that module's own catalog, `NibKit/Sources/<Module>/Localizable.xcstrings`.
    They are also kept in the app catalog as the translation memory, and `--module-catalogs` copies their
    translations into the module catalog (NibDesign's catalog is architect-owned, so this is opt-in);
  * NibTesting, test targets, the widget and share extensions (their own bundles) are not scanned.

Catalog rules: entries found in code are `extractionState: manual` (the strings of Swift packages are never synced by
Xcode, so "manual" keeps Xcode from marking them stale); an entry no longer found becomes `stale` and keeps its
translations (`--prune` deletes stale entries); keys without letters are `shouldTranslate: false`. Existing
translations, comments and plural variations are never lost.

Translations (15 locales: en + TARGET_LOCALES) are produced by AI translation and committed:
  * `--export-missing FILE.json` writes what still needs translating (key, comment, where it is used);
  * `--translate` fills the gaps itself through a model (Anthropic with ANTHROPIC_API_KEY, or any OpenAI-compatible
    endpoint with NIB_TRANSLATE_URL / OPENAI_API_KEY, e.g. Ollama or LM Studio); `--model` picks the model;
  * `--import FILE.json` merges translations ({locale: {key: value | {one, few, many, other}}}); every value must use
    the same format specifiers as its key, or it is rejected.
`--check` validates the committed catalog (valid JSON, every translatable key translated into every locale, format
specifiers match, plural forms complete) and exits 1 on problems. `--check --sources` also re-extracts live source
keys and fails on missing/stale or untranslated entries. Pass `--stringsdata DIR` after merges to use compiler keys.
`--stats` lists unresolved interpolation types; heuristic fallback keys need compiler regeneration.

Unmerged feature branches: `--git-refs 'origin/feat/*'` also reads, for every feature branch not yet merged into
HEAD, that feature's own source files (docs/forge-spec.json `files`) from the branch, so their strings are translated
before they land.

Usage:
  python3 Scripts/extract_strings.py [--git-refs 'origin/feat/*'] [--stringsdata DIR ...] [--prune]
                                     [--module-catalogs] [--dry-run] [--stats]
  python3 Scripts/extract_strings.py --export-missing missing.json
  python3 Scripts/extract_strings.py --import translations.json
  python3 Scripts/extract_strings.py --translate [--model NAME] [--locales de,fr]
  python3 Scripts/extract_strings.py --check
"""
import argparse
import fnmatch
import glob
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.request

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
APP_CATALOG = os.path.join(ROOT, "Nib", "Resources", "Localizable.xcstrings")
SPEC = os.path.join(ROOT, "docs", "forge-spec.json")
SOURCE_LANGUAGE = "en"
LOCALES = ["en", "de", "es", "fr", "it", "ja", "ko", "nl", "pl", "pt-BR", "ru", "sv", "tr", "zh-Hans", "zh-Hant"]
TARGET_LOCALES = [l for l in LOCALES if l != SOURCE_LANGUAGE]
LANGUAGE_NAMES = {
    "de": "German", "es": "Spanish (Spain)", "fr": "French (France)", "it": "Italian", "ja": "Japanese",
    "ko": "Korean", "nl": "Dutch", "pl": "Polish", "pt-BR": "Brazilian Portuguese", "ru": "Russian",
    "sv": "Swedish", "tr": "Turkish", "zh-Hans": "Simplified Chinese", "zh-Hant": "Traditional Chinese (Taiwan)",
}
# CLDR plural categories each locale uses for integers (what an .xcstrings plural variation must provide).
PLURAL_CATEGORIES = {
    "en": ["one", "other"], "de": ["one", "other"], "es": ["one", "many", "other"], "fr": ["one", "many", "other"],
    "it": ["one", "many", "other"], "ja": ["other"], "ko": ["other"], "nl": ["one", "other"],
    "pl": ["one", "few", "many", "other"], "pt-BR": ["one", "many", "other"], "ru": ["one", "few", "many", "other"],
    "sv": ["one", "other"], "tr": ["one", "other"], "zh-Hans": ["other"], "zh-Hant": ["other"],
}
# Categories a translation must provide; the rest ("many" in es/fr/it/pt, used for 1,000,000) fall back to "other".
REQUIRED_PLURALS = {
    "en": ["one", "other"], "de": ["one", "other"], "es": ["one", "other"], "fr": ["one", "other"],
    "it": ["one", "other"], "ja": ["other"], "ko": ["other"], "nl": ["one", "other"],
    "pl": ["one", "few", "many", "other"], "pt-BR": ["one", "other"], "ru": ["one", "few", "many", "other"],
    "sv": ["one", "other"], "tr": ["one", "other"], "zh-Hans": ["other"], "zh-Hant": ["other"],
}

# Modules whose strings are not app UI (test support) and folders outside the app's bundle.
SKIP_MODULES = {"NibTesting"}
APP_DIRS = ["Nib"]
SWIFTUI_INITS = {
    "Text", "Button", "Toggle", "Label", "Section", "Picker", "Menu", "TextField", "SecureField", "Stepper", "Link",
    "NavigationLink", "DatePicker", "ColorPicker", "ProgressView", "LabeledContent", "GroupBox", "DisclosureGroup",
    "ControlGroup", "Tab", "ShareLink", "PasteButton", "MultiDatePicker", "Gauge",
}
SWIFTUI_MODIFIERS = {
    "navigationTitle", "accessibilityLabel", "accessibilityHint", "accessibilityValue", "help", "alert",
    "confirmationDialog", "navigationSubtitle", "badge", "keyboardShortcut_",  # keyboardShortcut_ never matches
}
LABELED_MODIFIERS = {("accessibilityAction", "named"), ("searchable", "prompt"), ("fileImporter", "title_")}
SPECIFIER = re.compile(r"%(?:(\d+)\$)?([-+ #0']*)(\d+|\*)?(?:\.(\d+|\*))?(hh|h|ll|l|q|L|z|t|j)?([@dDiuUxXoOfFeEgGcCsSpaA])")


# ---------------------------------------------------------------------------------------------------------------------
# Swift lexer: enough of Swift to find calls and read string literals exactly (escapes, raw and multi-line strings,
# nested interpolations, nested block comments).

class Tok:
    __slots__ = ("kind", "text", "line", "col", "parts", "interps")

    def __init__(self, kind, text, line, col, parts=None, interps=None):
        self.kind = kind          # "id", "str", "num", "punct"
        self.text = text          # source text (for str: the literal's source)
        self.line = line
        self.col = col
        self.parts = parts        # str: [("lit", text) | ("interp", source)]
        self.interps = interps    # str: token lists of each interpolation, in order

    def __repr__(self):
        return "Tok(%s, %r, %d)" % (self.kind, self.text, self.line)


class Lexer:
    def __init__(self, src):
        self.s = src
        self.n = len(src)
        self.i = 0
        self.line = 1
        self.line_start = 0

    def _adv(self, k=1):
        for _ in range(k):
            if self.i < self.n and self.s[self.i] == "\n":
                self.line += 1
                self.line_start = self.i + 1
            self.i += 1

    def tokens(self, until_close=False):
        """Tokens up to the end, or (until_close) up to the unmatched ')' closing an interpolation (consumed)."""
        out, depth, s = [], 0, self.s
        while self.i < self.n:
            c = s[self.i]
            if c in " \t\r\n\f":
                self._adv()
                continue
            if s.startswith("//", self.i):
                j = s.find("\n", self.i)
                self._adv((j if j >= 0 else self.n) - self.i)
                continue
            if s.startswith("/*", self.i):
                self._block_comment()
                continue
            line, col = self.line, self.i - self.line_start + 1
            if c == '"' or (c == "#" and self._raw_quote()):
                out.append(self._string(line, col))
                continue
            if c.isalpha() or c == "_" or c == "$" or c == "@" or (c == "#" and self.i + 1 < self.n and
                                                                   (s[self.i + 1].isalpha() or s[self.i + 1] == "_")):
                j = self.i + 1
                while j < self.n and (s[j].isalnum() or s[j] == "_"):
                    j += 1
                out.append(Tok("id", s[self.i:j], line, col))
                self._adv(j - self.i)
                continue
            if c == "`":
                j = s.find("`", self.i + 1)
                j = self.n if j < 0 else j + 1
                out.append(Tok("id", s[self.i + 1:j - 1], line, col))
                self._adv(j - self.i)
                continue
            if c.isdigit():
                m = re.compile(r"0x[0-9A-Fa-f_]+(\.[0-9A-Fa-f_]+)?([pP][-+]?\d+)?|\d[\d_]*(\.\d[\d_]*)?([eE][-+]?\d+)?").match(s, self.i)
                out.append(Tok("num", m.group(0), line, col))
                self._adv(len(m.group(0)))
                continue
            if c in "([{":
                depth += 1
            elif c in ")]}":
                if c == ")" and until_close and depth == 0:
                    self._adv()
                    return out
                depth -= 1
            out.append(Tok("punct", c, line, col))
            self._adv()
        return out

    def _block_comment(self):
        depth = 0
        while self.i < self.n:
            if self.s.startswith("/*", self.i):
                depth += 1
                self._adv(2)
            elif self.s.startswith("*/", self.i):
                depth -= 1
                self._adv(2)
                if depth == 0:
                    return
            else:
                self._adv()

    def _raw_quote(self):
        j = self.i
        while j < self.n and self.s[j] == "#":
            j += 1
        return j < self.n and self.s[j] == '"'

    def _string(self, line, col):
        s = self.s
        start = self.i
        hashes = 0
        while s[self.i] == "#":
            hashes += 1
            self._adv()
        multi = s.startswith('"""', self.i)
        self._adv(3 if multi else 1)
        close = ('"""' if multi else '"') + "#" * hashes
        esc = "\\" + "#" * hashes
        parts, interps, buf = [], [], []

        def flush():
            if buf:
                parts.append(("lit", "".join(buf)))
                buf.clear()

        while self.i < self.n:
            if s.startswith(close, self.i):
                self._adv(len(close))
                break
            if not multi and s[self.i] == "\n":
                break  # unterminated single-line string: stop at the line end
            if s.startswith(esc, self.i):
                k = self.i + len(esc)
                if k >= self.n:
                    self._adv(len(esc))
                    break
                e = s[k]
                if e == "(":
                    flush()
                    self._adv(len(esc) + 1)
                    begin = self.i
                    sub = Lexer(s)
                    sub.i, sub.line, sub.line_start = self.i, self.line, self.line_start
                    toks = sub.tokens(until_close=True)
                    code = s[begin:sub.i - 1]
                    self.i, self.line, self.line_start = sub.i, sub.line, sub.line_start
                    parts.append(("interp", code))
                    interps.append(toks)
                    continue
                if e == "u" and k + 1 < self.n and s[k + 1] == "{":
                    end = s.find("}", k)
                    try:
                        buf.append(chr(int(s[k + 2:end], 16)))
                    except ValueError:
                        buf.append(s[self.i:end + 1])
                    self._adv(end + 1 - self.i)
                    continue
                if multi and e in "\r\n":  # line continuation
                    self._adv(len(esc))
                    while self.i < self.n and s[self.i] in "\r\n":
                        self._adv()
                    continue
                buf.append({"n": "\n", "t": "\t", "r": "\r", "0": "\0", "\\": "\\", '"': '"', "'": "'"}.get(e, e))
                self._adv(len(esc) + 1)
                continue
            buf.append(s[self.i])
            self._adv()
        flush()
        if multi:
            parts = _dedent_multiline(parts)
        return Tok("str", s[start:self.i], line, col, parts, interps)


def _dedent_multiline(parts):
    """Swift multi-line string rules: drop the first line break and the closing line, strip the closing indent."""
    text = "".join(p[1] if p[0] == "lit" else "\x00%d\x00" % i for i, p in enumerate(parts))
    if text.startswith("\n"):
        text = text[1:]
    last_nl = text.rfind("\n")
    indent = ""
    if last_nl >= 0 and text[last_nl + 1:].strip(" \t") == "":
        indent = text[last_nl + 1:]
        text = text[:last_nl]
    if indent:
        text = "\n".join(l[len(indent):] if l.startswith(indent) else l.lstrip(" \t") for l in text.split("\n"))
    out = []
    for piece in re.split(r"(\x00\d+\x00)", text):
        m = re.fullmatch(r"\x00(\d+)\x00", piece)
        if m:
            out.append(parts[int(m.group(1))])
        elif piece:
            out.append(("lit", piece))
    return out


def lex(src):
    return Lexer(src).tokens()


def matching(toks, i):
    """Index of the bracket closing toks[i] (an opening bracket), or len(toks)."""
    depth = 0
    for j in range(i, len(toks)):
        t = toks[j]
        if t.kind != "punct":
            continue
        if t.text in "([{":
            depth += 1
        elif t.text in ")]}":
            depth -= 1
            if depth == 0:
                return j
    return len(toks)


def call_args(toks, open_i):
    """[(label | None, [tokens])] of the call whose '(' is toks[open_i]."""
    close = matching(toks, open_i)
    args, cur, label, depth = [], [], None, 0
    j = open_i + 1
    while j < close:
        t = toks[j]
        if t.kind == "punct" and t.text in "([{":
            depth += 1
        elif t.kind == "punct" and t.text in ")]}":
            depth -= 1
        if depth == 0 and t.kind == "punct" and t.text == ",":
            args.append((label, cur))
            cur, label = [], None
            j += 1
            continue
        if depth == 0 and not cur and t.kind == "id" and j + 1 < close and toks[j + 1].kind == "punct" \
                and toks[j + 1].text == ":" and label is None:
            label = t.text
            j += 2
            continue
        cur.append(t)
        j += 1
    if cur or label:
        args.append((label, cur))
    return args


# ---------------------------------------------------------------------------------------------------------------------
# Extraction

class Found:
    __slots__ = ("key", "value", "comment", "file", "line", "module", "catalog", "raw", "interps")

    def __init__(self, key, value, comment, file, line, module, catalog, raw, interps):
        self.key = key            # catalog key (format specifiers in place of interpolations)
        self.value = value        # English value when it differs from the key (defaultValue:), else None
        self.comment = comment
        self.file = file          # repository-relative path
        self.line = line
        self.module = module
        self.catalog = catalog    # "app" or "module"
        self.raw = raw            # the key with "%arg" placeholders (for matching compiler output)
        self.interps = interps    # interpolation sources, in order


def literal_text(tok):
    """The literal of a string token without interpolations (None when it has any)."""
    if any(p[0] == "interp" for p in tok.parts):
        return None
    return "".join(p[1] for p in tok.parts)


def module_of(rel):
    parts = rel.split("/")
    if rel.startswith("NibKit/Sources/") and len(parts) > 3:
        return parts[2]
    return parts[0]


class TypeIndex:
    """Declared types of names in a module (`let x: Int`, `var n = 0`, `func f(count: Int)`), for specifiers."""
    DECL = re.compile(r"\b(?:let|var)\s+([A-Za-z_]\w*)\s*:\s*([A-Za-z_][\w.]*(?:<[^>\n]*>)?[?!]?)")
    PARAM = re.compile(r"[(,]\s*(?:[A-Za-z_]\w*\s+)?([A-Za-z_]\w*)\s*:\s*(?:inout\s+)?([A-Za-z_][\w.]*[?!]?)\s*(?=[,)=])")
    ASSIGN = re.compile(r"\b(?:let|var)\s+([A-Za-z_]\w*)\s*=\s*([^\n;]+)")
    FUNC = re.compile(r"\bfunc\s+([A-Za-z_]\w*)\s*(?:<[^>\n]*>)?\([^)]*\)\s*(?:async\s+|throws\s+|rethrows\s+)*"
                      r"->\s*([A-Za-z_][\w.]*[?!]?)")

    def __init__(self):
        self.module_types = {}
        self.file_types = {}
        self.module_returns = {}

    def add_file(self, rel, text):
        types = {}
        returns = self.module_returns.setdefault(module_of(rel), {})
        for m in self.FUNC.finditer(text):
            returns.setdefault(m.group(1), m.group(2))
        for m in self.DECL.finditer(text):
            types.setdefault(m.group(1), m.group(2))
        for m in self.PARAM.finditer(text):
            types.setdefault(m.group(1), m.group(2))
        for m in self.ASSIGN.finditer(text):
            t = expr_literal_type(m.group(2).strip())
            if t:
                types.setdefault(m.group(1), t)
        self.file_types[rel] = types
        mod = self.module_types.setdefault(module_of(rel), {})
        for k, v in types.items():
            mod.setdefault(k, v)

    def lookup(self, rel, name):
        t = self.file_types.get(rel, {}).get(name)
        if t is None:
            t = self.module_types.get(module_of(rel), {}).get(name)
        return t

    def returns(self, rel, name):
        return self.module_returns.get(module_of(rel), {}).get(name)


def expr_literal_type(expr):
    if re.fullmatch(r"-?\d[\d_]*", expr):
        return "Int"
    if re.fullmatch(r"-?\d[\d_]*\.\d+([eE][-+]?\d+)?", expr):
        return "Double"
    if expr.startswith('"'):
        return "String"
    m = re.match(r"(Int|Int64|Int32|UInt|Double|CGFloat|Float|String|TimeInterval|Bool)\s*\(", expr)
    if m:
        return m.group(1)
    return None


# Contract properties whose names are not declared in the feature's own files.
WELL_KNOWN = {
    "count": "Int", "pageCount": "Int", "index": "Int", "number": "Int", "total": "Int", "done": "Int",
    "pending": "Int", "row": "Int", "column": "Int", "layer": "Int", "activeLayer": "Int", "rotation": "Int",
    "title": "String", "name": "String", "text": "String", "message": "String", "id": "String", "raw": "String",
    "description": "String", "localizedDescription": "String", "author": "String", "plainText": "String",
    "displayName": "String", "language": "String", "rawValue": "String", "hint": "String", "path": "String",
    "zoom": "Double", "width": "Double", "height": "Double", "duration": "Double", "t": "Double", "x": "Double",
    "y": "Double", "scale": "Double", "progress": "Double", "fraction": "Double", "opacity": "Double",
}
INT_TYPES = {"Int": "%lld", "Int64": "%lld", "Int16": "%d", "Int8": "%d", "Int32": "%d", "UInt": "%llu",
             "UInt64": "%llu", "UInt32": "%u", "UInt16": "%u", "UInt8": "%u"}
FLOAT_TYPES = {"Double": "%lf", "CGFloat": "%lf", "TimeInterval": "%lf", "Float": "%f", "Float64": "%lf"}


def type_specifier(t):
    if t is None:
        return None
    t = t.rstrip("?!")
    t = t.split(".")[-1] if t.startswith(("Swift.", "CoreGraphics.", "Foundation.")) else t
    if t in INT_TYPES:
        return INT_TYPES[t]
    if t in FLOAT_TYPES:
        return FLOAT_TYPES[t]
    return "%@"


UNRESOLVED_INTERPOLATIONS = set()


def infer_specifier(code, rel, types):
    """Best-effort Swift format specifier, or None when the type cannot be resolved."""
    c = code.strip()
    m = re.search(r",\s*specifier:\s*\"([^\"]+)\"\s*$", c)
    if m:
        return m.group(1)
    if re.search(r",\s*(format|style):", c):
        return "%@"
    lit = expr_literal_type(c)
    if lit:
        return type_specifier(lit)
    if re.match(r"(Text|Image|AttributedString|String)\s*\(", c) or c.startswith('"'):
        return "%@"
    if re.search(r"\.(formatted|joined|lowercased|uppercased|capitalized|localizedCapitalized|trimmingCharacters|"
                 r"replacingOccurrences|prefix|suffix|localizedStringWithFormat|name|title|description|"
                 r"localizedDescription|rawValue|displayName|plainText|localizedName)\b", c):
        return "%@"
    m = re.search(r"\?\?\s*(.+)$", c)
    if m:
        t = expr_literal_type(m.group(1).strip())
        if t:
            return type_specifier(t)
        return infer_specifier(m.group(1), rel, types)
    m = re.match(r"(.+?)\s*[-+*/%]\s*(\d[\d_]*(\.\d+)?)$", c) or re.match(r"(\d[\d_]*(\.\d+)?)\s*[-+*/]\s*(.+)$", c)
    if m:
        num = m.group(2) if m.group(2) and m.group(2)[0].isdigit() else m.group(1)
        if "." in num:
            return "%lf"
        other = infer_specifier(m.group(1) if m.group(1) is not num else m.group(3), rel, types)
        return other if other in ("%lf", "%f", "%llu", "%d", "%lld") else None
    m = re.match(r"(?:[A-Za-z_][\w.]*\.)?([A-Za-z_]\w*)\s*\((.*)\)$", c)
    if m and not re.match(r"(Int|Double|Float|CGFloat|String)\b", c):
        t = types.returns(rel, m.group(1))
        return type_specifier(t) if t else None
    if re.search(r"\.count\b|\bcount\s*$|Count\s*$|\.(firstIndex|lastIndex)\(", c):
        return "%lld"
    m = re.match(r"(?:[A-Za-z_]\w*\??\.)*([A-Za-z_]\w*)$", c.replace("self.", ""))
    if m:
        name = m.group(1)
        t = types.lookup(rel, name) or WELL_KNOWN.get(name)
        if t:
            return type_specifier(t)
        if re.search(r"(Count|Index|Number|Total)$", name) or name in ("n", "i", "j", "k"):
            return "%lld"
    return None


def normalise(key):
    """A key with every format specifier replaced by %arg (to match compiler keys against source literals)."""
    return SPECIFIER.sub("%arg", key.replace("%%", "\x01")).replace("\x01", "%%")


def specifiers(value):
    """Format specifiers of a value, as (position or None, conversion) — %1$@ and %@ are both '@'."""
    out = []
    for m in SPECIFIER.finditer(value.replace("%%", "")):
        conv = (m.group(5) or "") + m.group(6)
        out.append((int(m.group(1)) if m.group(1) else None, conv, m.group(4)))
    return out


def specifier_signature(value):
    """Specifiers in argument order (positional ones sorted), so a reordered translation compares equal."""
    specs = specifiers(value)
    if specs and all(p is not None for p, _, _ in specs):
        return tuple(c for _, c, _ in sorted(specs, key=lambda x: x[0]))
    return tuple(c for _, c, _ in specs)


def build_key(tok, rel, types, oracle, interpolated_escapes=True):
    """(key, raw) of a string token: interpolations become specifiers, '%' in literal text becomes '%%'."""
    has_interp = any(p[0] == "interp" for p in tok.parts)
    raw_parts, codes = [], []
    for kind, text in tok.parts:
        if kind == "lit":
            raw_parts.append(text.replace("%", "%%") if has_interp and interpolated_escapes else text)
        else:
            raw_parts.append("\x02")
            codes.append(text)
    raw = "".join(raw_parts)
    if not codes:
        return raw, raw, codes
    probe = raw.replace("\x02", "%arg")
    exact = oracle.lookup(rel, probe) if oracle else None
    if exact is not None:
        return exact, probe, codes
    pieces = raw.split("\x02")
    out = pieces[0]
    for code, piece in zip(codes, pieces[1:]):
        specifier = infer_specifier(code, rel, types)
        if specifier is None:
            UNRESOLVED_INTERPOLATIONS.add((rel, tok.line, code))
        out += (specifier or "%@") + piece
    return out, probe, codes


class Oracle:
    """Exact keys from compiler-emitted .stringsdata files, indexed by (repository path, normalised key)."""
    PATH = re.compile(r"(NibKit/Sources/.+|Nib/(?:App|Intents)/.+|NibWidgets/.+|NibShare/.+)$")

    def __init__(self):
        self.by_file = {}
        self.by_module = {}
        self.files = 0

    def load(self, directory):
        for path in glob.glob(os.path.join(directory, "**", "*.stringsdata"), recursive=True):
            if os.path.basename(path).startswith("ExtractedAppShortcutsMetadata"):
                continue
            try:
                data = json.load(open(path, encoding="utf-8"))
            except (ValueError, OSError):
                continue
            m = self.PATH.search(data.get("source", ""))
            if not m:
                continue
            rel = m.group(1)
            self.files += 1
            for table in data.get("tables", {}).values():
                for entry in table:
                    key = entry.get("key")
                    if not key or "%" not in key:
                        continue
                    n = normalise(key)
                    self.by_file.setdefault((rel, n), set()).add(key)
                    self.by_module.setdefault((module_of(rel), n), set()).add(key)

    def load_module_catalogs(self):
        """Keys a module catalog already lists (NibDesign's were written from compiler output)."""
        for path in glob.glob(os.path.join(ROOT, "NibKit", "Sources", "*", "Localizable.xcstrings")):
            module = os.path.basename(os.path.dirname(path))
            try:
                keys = json.load(open(path, encoding="utf-8")).get("strings", {})
            except (ValueError, OSError):
                continue
            for key in keys:
                if "%" in key:
                    self.by_module.setdefault((module, normalise(key)), set()).add(key)

    def lookup(self, rel, probe):
        for index, k in ((self.by_file, (rel, probe)), (self.by_module, (module_of(rel), probe))):
            keys = index.get(k)
            if keys and len(keys) == 1:
                return next(iter(keys))
        return None


def extract_tokens(toks, rel, module, types, oracle, out):
    n = len(toks)
    for i, t in enumerate(toks):
        if t.kind == "str" and t.interps:
            for sub in t.interps:
                extract_tokens(sub, rel, module, types, oracle, out)
        if t.kind != "id" or i + 1 >= n or toks[i + 1].kind != "punct" or toks[i + 1].text != "(":
            continue
        prev = toks[i - 1] if i > 0 else None
        is_member = prev is not None and prev.kind == "punct" and prev.text == "."
        args = None
        key_tok = None
        name = t.text
        if not is_member and name in ("String", "AttributedString"):
            args = call_args(toks, i + 1)
            if args and args[0][0] == "localized" and len(args[0][1]) == 1 and args[0][1][0].kind == "str":
                key_tok = args[0][1][0]
        elif not is_member and name in ("LocalizedStringResource", "LocalizedStringKey", "NSLocalizedString"):
            args = call_args(toks, i + 1)
            if args and args[0][0] is None and len(args[0][1]) == 1 and args[0][1][0].kind == "str":
                key_tok = args[0][1][0]
        elif not is_member and name in SWIFTUI_INITS:
            args = call_args(toks, i + 1)
            if args and args[0][0] is None and len(args[0][1]) == 1 and args[0][1][0].kind == "str":
                key_tok = args[0][1][0]
        elif is_member and name in SWIFTUI_MODIFIERS:
            args = call_args(toks, i + 1)
            if args and args[0][0] is None and len(args[0][1]) == 1 and args[0][1][0].kind == "str":
                key_tok = args[0][1][0]
        elif is_member:
            args = call_args(toks, i + 1)
            for label, arg in args:
                if (name, label) in LABELED_MODIFIERS and len(arg) == 1 and arg[0].kind == "str":
                    key_tok = arg[0]
                    break
        if key_tok is None:
            continue
        labels = {label: arg for label, arg in (args or [])}
        table = labels.get("table")
        if table is not None and not (len(table) == 1 and table[0].kind == "str" and literal_text(table[0]) == "Localizable"):
            continue
        bundle = labels.get("bundle")
        catalog = "app"
        if bundle is not None:
            btxt = "".join(x.text for x in bundle)
            if btxt in (".module", "Bundle.module", "Foundation.Bundle.module"):
                catalog = "module"
        comment = None
        c = labels.get("comment")
        if c and len(c) == 1 and c[0].kind == "str":
            comment = literal_text(c[0])
        value = None
        d = labels.get("defaultValue")
        if d and len(d) == 1 and d[0].kind == "str":
            value, _, _ = build_key(d[0], rel, types, oracle)
        # Swift escapes '%' in the literal segments of an interpolated LocalizationValue / LocalizedStringKey.
        key, raw, codes = build_key(key_tok, rel, types, oracle)
        if name == "NSLocalizedString" and not codes:
            key = literal_text(key_tok)
        if not key.strip():
            continue  # Text("") and friends: nothing to translate
        out.append(Found(key, value, comment, rel, key_tok.line, module, catalog, raw, codes))


def extract_source(rel, text, types, oracle):
    out = []
    try:
        toks = lex(text)
    except (IndexError, ValueError) as e:  # the lexer never raises on valid Swift; report and move on
        print("warning: %s: could not be read (%s)" % (rel, e), file=sys.stderr)
        return out
    extract_tokens(toks, rel, module_of(rel), types, oracle, out)
    return out


# ---------------------------------------------------------------------------------------------------------------------
# Sources: the working tree, plus unmerged feature branches (--git-refs).

def git(*args):
    r = subprocess.run(["git", "-C", ROOT] + list(args), capture_output=True, text=True)
    return r.stdout if r.returncode == 0 else None


def working_tree_sources():
    files = {}
    src = os.path.join(ROOT, "NibKit", "Sources")
    for path in glob.glob(os.path.join(src, "**", "*.swift"), recursive=True):
        rel = os.path.relpath(path, ROOT).replace(os.sep, "/")
        if module_of(rel) in SKIP_MODULES:
            continue
        files[rel] = open(path, encoding="utf-8", errors="replace").read()
    for d in APP_DIRS:
        for path in glob.glob(os.path.join(ROOT, d, "**", "*.swift"), recursive=True):
            rel = os.path.relpath(path, ROOT).replace(os.sep, "/")
            files[rel] = open(path, encoding="utf-8", errors="replace").read()
    return files


def branch_sources(patterns, files):
    """Adds the owned Swift files of every feature branch matching `patterns` that HEAD does not contain yet."""
    refs = (git("for-each-ref", "--format=%(refname:short)", "refs/remotes", "refs/heads") or "").split()
    spec = json.load(open(SPEC, encoding="utf-8"))
    features = {f["id"]: f for f in spec["features"]}
    used = []
    for ref in sorted(refs):
        if not any(fnmatch.fnmatch(ref, p) for p in patterns):
            continue
        m = re.search(r"feat/(F\d{3})$", ref)
        if not m or m.group(1) not in features:
            continue
        merged = subprocess.run(["git", "-C", ROOT, "merge-base", "--is-ancestor", ref, "HEAD"]).returncode == 0
        if merged:
            continue
        f = features[m.group(1)]
        for p in f["files"]:
            if not p.endswith(".swift") or module_of(p) in SKIP_MODULES:
                continue
            if not (p.startswith("NibKit/Sources/") or p.split("/")[0] in APP_DIRS):
                continue
            text = git("show", "%s:%s" % (ref, p))
            if text is not None:
                files[p] = text
        used.append(ref)
    return used


# ---------------------------------------------------------------------------------------------------------------------
# Catalog

def load_catalog(path):
    if os.path.exists(path):
        with open(path, encoding="utf-8") as fh:
            data = json.load(fh)
    else:
        data = {}
    data.setdefault("sourceLanguage", SOURCE_LANGUAGE)
    data.setdefault("strings", {})
    data.setdefault("version", "1.0")
    return data


def save_catalog(path, data):
    text = json.dumps(data, ensure_ascii=False, indent=2, sort_keys=True, separators=(",", " : "))
    with open(path, "w", encoding="utf-8") as fh:
        fh.write(text + "\n")


def translatable(key):
    return bool(re.search(r"[^\W\d_]", SPECIFIER.sub("", key)))


def merge(catalog, found, comment_note=None):
    """Adds/refreshes found keys; marks the rest stale. Returns (added, stale) counts."""
    strings = catalog["strings"]
    by_key = {}
    for f in found:
        by_key.setdefault(f.key, []).append(f)
    added = 0
    for key, uses in sorted(by_key.items()):
        entry = strings.get(key)
        if entry is None:
            entry = strings[key] = {}
            added += 1
        entry["extractionState"] = "manual"
        comments = sorted({u.comment for u in uses if u.comment})
        if comments:
            entry["comment"] = "\n".join(comments)
        if not translatable(key):
            entry["shouldTranslate"] = False
        else:
            entry.pop("shouldTranslate", None)
        values = {u.value for u in uses if u.value}
        if values:
            loc = entry.setdefault("localizations", {})
            loc[SOURCE_LANGUAGE] = {"stringUnit": {"state": "translated", "value": sorted(values)[0]}}
    stale = 0
    for key, entry in strings.items():
        if key not in by_key and entry.get("extractionState") != "stale":
            entry["extractionState"] = "stale"
            stale += 1
    return added, stale


def source_value(key, entry):
    loc = entry.get("localizations", {}).get(SOURCE_LANGUAGE)
    if loc and "stringUnit" in loc:
        return loc["stringUnit"].get("value", key)
    return key


def plural_forms(loc):
    """{category: value} of a localization with a plural variation (first substitution or top level), else None."""
    variations = loc.get("variations", {})
    if "plural" in variations:
        return {k: v.get("stringUnit", {}).get("value") for k, v in variations["plural"].items()}
    return None


def check_catalog(catalog, locales=TARGET_LOCALES):
    problems = []
    for key, entry in sorted(catalog["strings"].items()):
        if entry.get("extractionState") == "stale" or entry.get("shouldTranslate") is False:
            continue
        src = source_value(key, entry)
        want = specifier_signature(src)
        locs = entry.get("localizations", {})
        for l in locales:
            loc = locs.get(l)
            if loc is None:
                problems.append("%s: %r has no translation" % (l, key))
                continue
            forms = plural_forms(loc)
            if forms is not None:
                for cat in REQUIRED_PLURALS[l]:
                    if not forms.get(cat):
                        problems.append("%s: %r is missing the plural form '%s'" % (l, key, cat))
                for cat, value in forms.items():
                    if value is None or cat not in PLURAL_CATEGORIES[l] + ["zero"]:
                        problems.append("%s: %r has an unknown plural form '%s'" % (l, key, cat))
                    elif value and set(specifier_signature(value)) - set(want):
                        problems.append("%s: %r plural '%s' uses specifiers %s, the key has %s"
                                        % (l, key, cat, specifier_signature(value), want))
                continue
            unit = loc.get("stringUnit")
            if not unit or not unit.get("value"):
                problems.append("%s: %r has an empty translation" % (l, key))
                continue
            if unit.get("state") not in ("translated", "needs_review"):
                problems.append("%s: %r is in state %s" % (l, key, unit.get("state")))
            got = specifier_signature(unit["value"])
            if got != want:
                problems.append("%s: %r uses specifiers %s, the key has %s" % (l, key, got, want))
    return problems


def validate_translation(key, src, value, locale):
    """None when `value` (a string or a plural dict) may be stored for `key`, else the reason."""
    want = specifier_signature(src)
    if isinstance(value, dict):
        for cat in REQUIRED_PLURALS[locale]:
            if not value.get(cat):
                return "missing plural form '%s'" % cat
        for cat, v in value.items():
            if cat not in PLURAL_CATEGORIES[locale] + ["zero"]:
                return "unknown plural form '%s'" % cat
            if not isinstance(v, str) or not v.strip():
                return "empty plural form '%s'" % cat
            if set(specifier_signature(v)) - set(want):
                return "plural form '%s' uses specifiers %s, the key has %s" % (cat, specifier_signature(v), want)
        return None
    if not isinstance(value, str) or not value.strip():
        return "empty value"
    if specifier_signature(value) != want:
        return "uses specifiers %s, the key has %s" % (specifier_signature(value), want)
    return None


def store_translation(entry, locale, value):
    loc = entry.setdefault("localizations", {})
    if isinstance(value, dict):
        loc[locale] = {"variations": {"plural": {cat: {"stringUnit": {"state": "translated", "value": v}}
                                                 for cat, v in value.items()}}}
    else:
        loc[locale] = {"stringUnit": {"state": "translated", "value": value}}


def import_translations(catalog, data):
    strings = catalog["strings"]
    stored, rejected = 0, []
    for locale, table in data.items():
        if locale not in TARGET_LOCALES + [SOURCE_LANGUAGE]:
            rejected.append("%s: not one of the catalog's locales" % locale)
            continue
        for key, value in table.items():
            entry = strings.get(key)
            if entry is None:
                rejected.append("%s: %r is not in the catalog" % (locale, key))
                continue
            why = validate_translation(key, source_value(key, entry), value, locale)
            if why:
                rejected.append("%s: %r %s" % (locale, key, why))
                continue
            store_translation(entry, locale, value)
            stored += 1
    return stored, rejected


def missing(catalog, locales):
    out = {}
    for key, entry in sorted(catalog["strings"].items()):
        if entry.get("extractionState") == "stale" or entry.get("shouldTranslate") is False:
            continue
        need = [l for l in locales if l not in entry.get("localizations", {})]
        if need:
            out[key] = {"comment": entry.get("comment", ""), "locales": need, "value": source_value(key, entry)}
    return out


# ---------------------------------------------------------------------------------------------------------------------
# AI translation (--translate): the same bring-your-own-model idea as the app.

TRANSLATE_PROMPT = """You translate the user interface of Nib, a handwriting note-taking app for iPad and iPhone (like \
Goodnotes), into {language}. Translate every JSON value below. Rules:
- Match Apple's own {language} terminology for iPadOS (Settings, Files, VoiceOver, Apple Pencil, Undo, Share…).
- Keep format specifiers exactly: %@, %lld, %lf, %d, %.1f and %% must all appear in the translation; when the word \
order needs it, use positional forms (%1$@, %2$lld). Keep \\n line breaks, quotes and "…".
- Keep product and brand names (Nib, Apple Pencil, iCloud Drive, WebDAV, PDF, Markdown, LaTeX, OneDrive, MCP) as they are.
- Menu and button titles stay short, in the imperative/infinitive style Apple uses in {language}.
- Where a key contains exactly one %lld count, return an object with the plural forms {forms} instead of a string.
- Answer with one JSON object mapping each key to its translation, nothing else.
Context for each key ("comment") says where it appears.
"""


def call_model(prompt, payload, model):
    body_text = json.dumps(payload, ensure_ascii=False)
    if os.environ.get("ANTHROPIC_API_KEY") and not os.environ.get("NIB_TRANSLATE_URL"):
        req = urllib.request.Request(
            "https://api.anthropic.com/v1/messages",
            data=json.dumps({"model": model or "claude-sonnet-4-5", "max_tokens": 16000,
                             "system": prompt, "messages": [{"role": "user", "content": body_text}]}).encode(),
            headers={"x-api-key": os.environ["ANTHROPIC_API_KEY"], "anthropic-version": "2023-06-01",
                     "content-type": "application/json"})
        with urllib.request.urlopen(req, timeout=600) as r:
            reply = json.load(r)
        text = "".join(b.get("text", "") for b in reply.get("content", []) if b.get("type") == "text")
    else:
        base = os.environ.get("NIB_TRANSLATE_URL", "https://api.openai.com/v1").rstrip("/")
        headers = {"content-type": "application/json"}
        if os.environ.get("OPENAI_API_KEY"):
            headers["authorization"] = "Bearer " + os.environ["OPENAI_API_KEY"]
        req = urllib.request.Request(
            base + "/chat/completions",
            data=json.dumps({"model": model or os.environ.get("NIB_TRANSLATE_MODEL", "gpt-4.1"),
                             "messages": [{"role": "system", "content": prompt},
                                          {"role": "user", "content": body_text}],
                             "response_format": {"type": "json_object"}}).encode(),
            headers=headers)
        with urllib.request.urlopen(req, timeout=600) as r:
            reply = json.load(r)
        text = reply["choices"][0]["message"]["content"]
    m = re.search(r"\{.*\}", text, re.S)
    return json.loads(m.group(0)) if m else {}


def translate(catalog, locales, model, batch=60):
    todo = missing(catalog, locales)
    if not todo:
        print("extract_strings: nothing to translate")
        return 0
    if not (os.environ.get("ANTHROPIC_API_KEY") or os.environ.get("NIB_TRANSLATE_URL") or os.environ.get("OPENAI_API_KEY")):
        sys.exit("extract_strings: --translate needs ANTHROPIC_API_KEY, OPENAI_API_KEY or NIB_TRANSLATE_URL")
    stored = 0
    for locale in locales:
        keys = [k for k, v in todo.items() if locale in v["locales"]]
        prompt = TRANSLATE_PROMPT.format(language=LANGUAGE_NAMES[locale], forms=", ".join(REQUIRED_PLURALS[locale]))
        for start in range(0, len(keys), batch):
            chunk = {k: {"text": todo[k]["value"], "comment": todo[k]["comment"]} for k in keys[start:start + batch]}
            for attempt in range(3):
                try:
                    reply = call_model(prompt, chunk, model)
                    break
                except (urllib.error.URLError, ValueError, KeyError) as e:
                    print("extract_strings: %s batch %d failed (%s), retrying" % (locale, start, e), file=sys.stderr)
                    time.sleep(2 ** attempt)
            else:
                continue
            n, rejected = import_translations(catalog, {locale: {k: v for k, v in reply.items() if k in chunk}})
            stored += n
            for r in rejected:
                print("extract_strings: rejected %s" % r, file=sys.stderr)
            print("extract_strings: %s %d/%d" % (locale, min(start + batch, len(keys)), len(keys)))
    return stored


# ---------------------------------------------------------------------------------------------------------------------

def collect(args):
    UNRESOLVED_INTERPOLATIONS.clear()
    files = working_tree_sources()
    refs = branch_sources(args.git_refs, files) if args.git_refs else []
    types = TypeIndex()
    for rel, text in files.items():
        types.add_file(rel, text)
    oracle = Oracle()
    oracle.load_module_catalogs()
    for d in args.stringsdata:
        oracle.load(os.path.expanduser(d))
    found = []
    for rel in sorted(files):
        found += extract_source(rel, files[rel], types, oracle)
    return found, refs, oracle


def module_catalogs(found, app):
    """Copies translations from the app catalog into each module catalog that `bundle: .module` strings use."""
    by_module = {}
    for f in found:
        if f.catalog == "module":
            by_module.setdefault(f.module, []).append(f)
    for module, fs in sorted(by_module.items()):
        path = os.path.join(ROOT, "NibKit", "Sources", module, "Localizable.xcstrings")
        cat = load_catalog(path)
        merge(cat, fs)
        for key, entry in cat["strings"].items():
            src = app["strings"].get(key)
            if not src:
                continue
            for l, loc in src.get("localizations", {}).items():
                if l != SOURCE_LANGUAGE:
                    entry.setdefault("localizations", {})[l] = loc
        save_catalog(path, cat)
        print("extract_strings: %s (%d keys)" % (os.path.relpath(path, ROOT), len(cat["strings"])))


def report_unresolved():
    print("extract_strings: %d unresolved interpolation type(s); regenerate with --stringsdata after merges"
          % len(UNRESOLVED_INTERPOLATIONS))
    for rel, line, code in sorted(UNRESOLVED_INTERPOLATIONS):
        print("  unresolved: %s:%d: %s (temporary %%@ fallback)" % (rel, line, code))


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__.split("\n")[0])
    ap.add_argument("--catalog", default=APP_CATALOG, help="the app catalog (default Nib/Resources/Localizable.xcstrings)")
    ap.add_argument("--git-refs", action="append", default=[], metavar="GLOB",
                    help="also read unmerged feature branches matching GLOB (e.g. 'origin/feat/*')")
    ap.add_argument("--stringsdata", action="append", default=[], metavar="DIR",
                    help="a folder with compiler .stringsdata files (DerivedData) for exact interpolation types")
    ap.add_argument("--prune", action="store_true", help="delete stale entries instead of keeping them")
    ap.add_argument("--module-catalogs", action="store_true", help="also update bundle: .module catalogs (NibDesign)")
    ap.add_argument("--dry-run", action="store_true", help="report, write nothing")
    ap.add_argument("--stats", action="store_true", help="print per-module and per-locale counts")
    ap.add_argument("--list", metavar="FILE", help="write every extracted key with its uses as JSON (review aid)")
    ap.add_argument("--export-missing", metavar="FILE", help="write untranslated keys per locale as JSON and exit")
    ap.add_argument("--import", dest="import_file", metavar="FILE", help="merge translations from a JSON file and exit")
    ap.add_argument("--translate", action="store_true", help="translate what is missing with an AI model")
    ap.add_argument("--model", help="model name for --translate")
    ap.add_argument("--locales", help="comma-separated subset of locales for --translate / --export-missing")
    ap.add_argument("--sources", action="store_true", help="with --check: re-extract and validate live source keys")
    ap.add_argument("--check", action="store_true", help="validate the catalog; exit 1 on problems")
    args = ap.parse_args(argv)
    if args.sources and not args.check:
        ap.error("--sources requires --check")
    locales = args.locales.split(",") if args.locales else TARGET_LOCALES
    for l in locales:
        if l not in TARGET_LOCALES:
            sys.exit("extract_strings: unknown locale %s (one of %s)" % (l, ", ".join(TARGET_LOCALES)))

    catalog = load_catalog(args.catalog)
    rel_catalog = os.path.relpath(args.catalog, ROOT)
    if args.check:
        problems = check_catalog(catalog, locales)
        if args.sources:
            found, _, _ = collect(args)
            for key in sorted({f.key for f in found}):
                entry = catalog["strings"].get(key)
                if entry is None or entry.get("extractionState") == "stale":
                    problems.append("live source key %r is missing or stale" % key)
            if args.stats:
                report_unresolved()
        for p in problems[:200]:
            print("error: %s: %s" % (rel_catalog, p))
        live = sum(1 for e in catalog["strings"].values() if e.get("extractionState") != "stale")
        print("extract_strings: %d keys (%d live), %d problem(s)" % (len(catalog["strings"]), live, len(problems)))
        return 1 if problems else 0
    if args.export_missing:
        todo = missing(catalog, locales)
        with open(args.export_missing, "w", encoding="utf-8") as fh:
            json.dump(todo, fh, ensure_ascii=False, indent=1, sort_keys=True)
        print("extract_strings: %d keys need translating → %s" % (len(todo), args.export_missing))
        return 0
    if args.import_file:
        data = json.load(open(args.import_file, encoding="utf-8"))
        stored, rejected = import_translations(catalog, data)
        for r in rejected:
            print("warning: rejected %s" % r)
        if not args.dry_run:
            save_catalog(args.catalog, catalog)
        print("extract_strings: stored %d translations, rejected %d" % (stored, len(rejected)))
        return 1 if rejected else 0
    if args.translate:
        stored = translate(catalog, locales, args.model)
        if not args.dry_run:
            save_catalog(args.catalog, catalog)
        print("extract_strings: stored %d translations" % stored)
        return 0

    found, refs, oracle = collect(args)
    if refs:
        print("extract_strings: read %d unmerged feature branches" % len(refs))
    if oracle.files:
        print("extract_strings: %d compiler .stringsdata files for interpolation types" % oracle.files)
    added, stale = merge(catalog, found)
    if args.prune:
        catalog["strings"] = {k: v for k, v in catalog["strings"].items() if v.get("extractionState") != "stale"}
    keys = {f.key for f in found}
    print("extract_strings: %d uses, %d keys (%d new, %d newly stale) in %s"
          % (len(found), len(keys), added, stale, rel_catalog))
    if args.stats:
        report_unresolved()
        per = {}
        for f in found:
            per.setdefault(f.module, set()).add(f.key)
        for m, ks in sorted(per.items(), key=lambda x: -len(x[1])):
            print("  %-24s %d" % (m, len(ks)))
        live = {k: e for k, e in catalog["strings"].items() if e.get("extractionState") != "stale"}
        for l in TARGET_LOCALES:
            done = sum(1 for e in live.values() if l in e.get("localizations", {}) or e.get("shouldTranslate") is False)
            print("  %-8s %d/%d translated" % (l, done, len(live)))
    if args.list:
        listing = {}
        for f in found:
            e = listing.setdefault(f.key, {"uses": [], "comment": f.comment or "", "catalog": f.catalog})
            e["uses"].append("%s:%d" % (f.file, f.line))
        with open(args.list, "w", encoding="utf-8") as fh:
            json.dump(listing, fh, ensure_ascii=False, indent=1, sort_keys=True)
    if args.dry_run:
        return 0
    save_catalog(args.catalog, catalog)
    if args.module_catalogs:
        module_catalogs(found, catalog)
    return 0


if __name__ == "__main__":
    sys.exit(main())
