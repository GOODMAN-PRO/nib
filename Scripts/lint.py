#!/usr/bin/env python3
"""Nib repository lint (runs in CI before building).

Errors (exit 1):
  * a feature module imports another NibKit module (only NibContracts, NibDesign, its own module, ZIPFoundation,
    SwiftMath and Apple frameworks are allowed; Package.swift gives NibDesign to ui/fullstack modules only);
  * `applyRemote(` outside NibSync / FeatCollab;
  * `UserDefaults.standard` outside NibContracts / NibTesting / FeatManagedConfig;
  * `BGTaskScheduler` used by a feature (register BackgroundTaskDescriptors instead; the shell registers them);
  * a forge-spec feature file listed for a module that lives in another module's folder;
  * a file path owned by two features (files + tests);
  * docs lint: a Markdown table row in docs/*.md whose cell count differs from its header (unescaped `|`).
Warnings: print( / fatalError( in package sources, spec files missing on disk, module files not listed in the spec,
  settings/Keychain/.nib-library writes outside a command file, and a feature registering command ids other than
  exactly its "Commands owned" list.
Usage: python3 Scripts/lint.py [--feature F012]   (--feature: code rules only for that feature's module; CI's
  feat/<FeatureID> run uses it, so another module's problems never fail your branch)
"""
import glob
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SRC = os.path.join(ROOT, "NibKit", "Sources")
SPEC = os.path.join(ROOT, "docs", "forge-spec.json")
REMOTE_OK = {"NibSync", "FeatCollab"}
DEFAULTS_OK = {"NibContracts", "FeatManagedConfig", "NibTesting"}
SHARED = ("NibContracts", "NibTesting", "NibDesign")  # architect-owned, importable modules (not features)

errors, warnings = [], []
modules = sorted(d for d in os.listdir(SRC) if os.path.isdir(os.path.join(SRC, d))) if os.path.isdir(SRC) else []
module_set = set(modules)
feature_filter = None
if len(sys.argv) > 2 and sys.argv[1] == "--feature":
    feature_filter = sys.argv[2]

spec = json.load(open(SPEC, encoding="utf-8")) if os.path.exists(SPEC) else {"features": []}
owned = {}
for f in spec["features"]:
    for p in f["files"] + f.get("tests", []):
        if p in owned:
            errors.append("%s is listed by both %s and %s" % (p, owned[p], f["id"]))
        owned[p] = f["id"]


def rel(p):
    return os.path.relpath(p, ROOT).replace(os.sep, "/")


def owned_commands(desc):
    """Command ids from a feature's 'Commands owned: …' list."""
    i = desc.find("Commands owned: ")
    if i < 0:
        return set()
    text = desc[i + len("Commands owned: "):]
    cut = text.find(". Module ")
    text = text[:cut] if cut >= 0 else text
    return set(re.findall(r'(?<![\w.`"])([a-z][a-zA-Z0-9]*(?:\.[a-zA-Z0-9]+)+) \{', text))


scan = modules
if feature_filter:
    scan = sorted({f["module"] for f in spec["features"] if f["id"] == feature_filter} & module_set)
    if not any(f["id"] == feature_filter for f in spec["features"]):
        errors.append("unknown feature %s (not in docs/forge-spec.json)" % feature_filter)

for m in scan:
    if m in SHARED:
        continue
    for dirpath, _, files in os.walk(os.path.join(SRC, m)):
        for fn in files:
            if not fn.endswith(".swift"):
                continue
            path = os.path.join(dirpath, fn)
            text = open(path, encoding="utf-8", errors="replace").read()
            r = rel(path)
            for imp in re.findall(r"^\s*(?:@testable\s+)?import\s+(?:class\s+|struct\s+|enum\s+|func\s+)?([A-Za-z_][A-Za-z0-9_]*)", text, re.M):
                if imp in module_set and imp not in ("NibContracts", "NibDesign", m):
                    errors.append("%s imports feature module %s (use commands/services instead)" % (r, imp))
            if "applyRemote(" in text and m not in REMOTE_OK:
                errors.append("%s calls applyRemote (only NibSync/FeatCollab may)" % r)
            if "UserDefaults.standard" in text and m not in DEFAULTS_OK:
                errors.append("%s uses UserDefaults.standard (use SettingsStore / SettingKey)" % r)
            if "BGTaskScheduler" in text:
                errors.append("%s uses BGTaskScheduler (register a BackgroundTaskDescriptor; app.scheduleBackgroundTask)" % r)
            if re.search(r"(?<![A-Za-z_.])print\(", text):
                warnings.append("%s uses print( (use os.Logger)" % r)
            if "fatalError(" in text and "init(coder" not in text:
                warnings.append("%s uses fatalError(" % r)
            is_command_file = "NibCommand" in text or "CommandDescriptor(" in text
            if not is_command_file and re.search(r"settings\.set(JSON)?\(|Keychain\.set(String)?\(|\.nib-library/", text):
                warnings.append("%s writes settings/Keychain/.nib-library outside a command file (make it a command)" % r)
            if r not in owned and not re.search(r"Feature\.swift$", fn):
                warnings.append("%s is not listed in forge-spec.json" % r)

for f in spec["features"]:
    if feature_filter and f["id"] != feature_filter:
        continue
    for p in f["files"]:
        if p.startswith("NibKit/Sources/"):
            mod = p.split("/")[2]
            if mod != f["module"]:
                errors.append("%s lists %s outside its module %s" % (f["id"], p, f["module"]))
        if feature_filter and not os.path.exists(os.path.join(ROOT, p)):
            warnings.append("%s: %s does not exist yet" % (f["id"], p))
    present = [os.path.join(ROOT, p) for p in f["files"] if p.endswith(".swift") and os.path.exists(os.path.join(ROOT, p))]
    if present:
        registered = set()
        for p in present:
            registered |= set(re.findall(r'CommandDescriptor\(\s*id:\s*"([^"]+)"', open(p, encoding="utf-8", errors="replace").read()))
        expected = owned_commands(f["description"])
        for extra in sorted(registered - expected):
            warnings.append("%s registers %s, which ARCHITECTURE §6.5 does not list for it" % (f["id"], extra))
        if feature_filter:
            for missing in sorted(expected - registered):
                warnings.append("%s does not register %s yet" % (f["id"], missing))

# Docs lint: every Markdown table row has as many cells as its header.
for md in sorted(glob.glob(os.path.join(ROOT, "docs", "*.md"))):
    header, in_code = None, False
    for n, line in enumerate(open(md, encoding="utf-8").read().split("\n"), 1):
        if line.strip().startswith("```"):
            in_code = not in_code
        if in_code or not line.startswith("|"):
            header = None
            continue
        parts = [c.strip() for c in re.split(r"(?<!\\)\|", line.strip().strip("|"))]
        cells = len(parts)
        if header is None:
            header = cells
        elif cells != header:
            errors.append("%s:%d: table row has %d cells, header has %d (escape | as \\|)" % (rel(md), n, cells, header))
        elif md.endswith("ARCHITECTURE.md") and cells == 5 and re.match(r"`[a-z][a-zA-Z0-9]*(\.[a-zA-Z0-9]+)+`$", parts[0]):
            # §6.5 catalogue row: | `id` | effect | params | Fxxx | summary |
            if not re.match(r"F\d{3}$", parts[3]) or not re.match(r"(read|session|edit|library|irreversible)\b", parts[1]):
                errors.append("%s:%d: catalogue row %s is malformed (effect '%s', owner '%s')" % (rel(md), n, parts[0], parts[1], parts[3]))

for w in warnings:
    print("warning: " + w)
for e in errors:
    print("error: " + e)
print("lint: %d error(s), %d warning(s)" % (len(errors), len(warnings)))
sys.exit(1 if errors else 0)
