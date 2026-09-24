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
  * docs lint: a Markdown table row in docs/*.md whose cell count differs from its header (unescaped `|`);
  * design rules (docs/DESIGN_SYSTEM.md §4) in UI feature code (modules with a ui/fullstack feature and their files
    under Nib/; never NibDesign, NibContracts, NibTesting or the app shell): raw colours, fonts, kerning/tracking,
    radii, shadows, animations and springs, materials and glass, haptics, SF Symbol strings, shaders, emoji, banned
    words and US spellings in UI copy, toast droplets and droplets inside a ScrollView/List.
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

# Design rules (DESIGN_SYSTEM.md §4): UI features compose NibDesign tokens and components only. NibDesign itself (and
# the architect's app shell) is exempt. ponytail: line regexes, not a Swift parser; a rule that misfires gets narrowed.
DESIGN_RULES = [
    ("raw colour (use NibColor / NibUIColor / NibInk / NibPaper)",
     r"(?<![\w.])(Color|UIColor)\(\s*(red|hue):|Color\(\s*hex|#colorLiteral|Color\(\s*\.sRGB|"
     r"Color\.(black|white)\.opacity\("),
    ("raw font (use NibFont / NibUIFont / NibFont.glyph)",
     r"(\.font\(\s*|Font)\.system\(\s*size:|Font\.custom\(|UIFont\.systemFont\(\s*ofSize:|UIFont\(\s*name:|"
     r"\.boldSystemFont\(|\.monospacedSystemFont\("),
    ("hand-set kerning or tracking (text styles carry Apple's tracking)", r"\.(kerning|tracking)\("),
    ("raw radius (use NibRadius / NibDropletShape)",
     r"\.cornerRadius\(\s*[\d.]|RoundedRectangle\(\s*cornerRadius:\s*[\d.]|\.cornerRadius\s*=\s*[\d.]|"
     r"UnevenRoundedRectangle\([^)]*Radius:\s*[\d.]"),
    ("raw shadow (use .nibElevation / CALayer.nibElevation)", r"\.shadow\(|\.shadow(Opacity|Radius)\b"),
    ("raw motion (use NibMotion.x.animation / NibMotion.animate / NibMotion.animateUIKit)",
     r"\.animation\(\s*\.(easeIn|easeOut|easeInOut|linear|default|bouncy|snappy|smooth)\b|"
     r"UIView\.animate\(\s*withDuration:|CABasicAnimation\("),
    ("materials and glass (use .droplet / nibGlass / opaque surfaces)",
     r"\.(ultraThin|thin|regular|thick|ultraThick)Material\b|(?<![\w.])Material\.|UIBlurEffect|UIVisualEffectView|"
     r"UIGlassEffect|UIGlassContainerEffect|\.glassEffect\(|GlassEffectContainer|\.buttonStyle\(\s*\.glass"),
    ("raw haptics (use NibHaptics.play / .nibHaptic)",
     r"UIImpactFeedbackGenerator|UISelectionFeedbackGenerator|UINotificationFeedbackGenerator|CHHapticEngine|"
     r"\.sensoryFeedback\("),
    ("SF Symbol string (use Image(nib:) / UIImage(nib:) / NibSymbol)",
     r"(?<![\w.])(Image|UIImage)\(\s*systemName:|Label\([^)]*systemImage:"),
    ("banned AI glyph (the drop is the mark)", r"\"(sparkles|sparkle|wand\.and\.stars|wand\.and\.rays)[\w.]*\""),
    ("toast droplet (use .nibToast($item))", r"\.droplet\([^)]*style:\s*\.toast\b"),
    ("shader in a feature (NibDesign components only)", r"\.(layerEffect|distortionEffect|colorEffect)\(|ShaderLibrary"),
]
# A six-digit hex literal next to a colour (ZIP and PDF magic numbers pass); withAnimation / .spring( without a token.
DESIGN_HEX = re.compile(r"\b0x[0-9A-Fa-f]{6}\b")
DESIGN_SPRING = re.compile(r"withAnimation\s*[({]|\.spring\(")
CANVAS_FEEDBACK_OK = {"FeatPencilHardware", "FeatTransform"}
EMOJI = re.compile("[\U0001F000-\U0001FAFF☀-➿]")
BANNED_WORDS = re.compile(r"\b(seamless|elevate|unleash|supercharge|magic)", re.I)
US_SPELLINGS = re.compile(r"\b(colors?|favorites?|customiz\w*|organiz\w*|summariz\w*|recogniz\w*|centers?|centered|"
                          r"gray|canceled|behaviors?)\b", re.I)
STRING_LITERAL = re.compile(r'"(?:[^"\\\n]|\\.)*"')


def strip_comment(line):
    """The line without a trailing // comment (a // inside a string literal is kept)."""
    out, in_str, i = [], False, 0
    while i < len(line):
        c = line[i]
        if c == "\\" and in_str:
            out.append(line[i:i + 2])
            i += 2
            continue
        if c == '"':
            in_str = not in_str
        elif not in_str and line.startswith("//", i):
            break
        out.append(c)
        i += 1
    return "".join(out)


def localized_literals(line):
    """String literals passed to String(localized:) on this line, with interpolations removed."""
    return [re.sub(r"\\\([^)]*\)", " ", m.group(1))
            for m in re.finditer(r'String\(\s*localized:\s*("(?:[^"\\\n]|\\.)*")', line)]


def scroll_bodies(text):
    """(start, end) character spans of every ScrollView { … } / List { … } body."""
    spans = []
    for m in re.finditer(r"\b(ScrollView|List)\b[^{}\n]*\{", text):
        depth, i = 1, m.end()
        while i < len(text) and depth:
            if text[i] == "{":
                depth += 1
            elif text[i] == "}":
                depth -= 1
            i += 1
        spans.append((m.end(), i))
    return spans


def design_lint(path, module):
    r = rel(path)
    text = open(path, encoding="utf-8", errors="replace").read()
    for n, raw in enumerate(text.split("\n"), 1):
        line = strip_comment(raw)
        if not line.strip() or line.lstrip().startswith(("*", "/*")):
            continue
        for what, pattern in DESIGN_RULES:
            if re.search(pattern, line):
                errors.append("%s:%d: %s" % (r, n, what))
        if DESIGN_HEX.search(line) and re.search(r"Color|nib", line):
            errors.append("%s:%d: raw hex colour (use NibColor / NibInk / NibPaper)" % (r, n))
        if DESIGN_SPRING.search(line) and "NibMotion" not in line:
            errors.append("%s:%d: animation or spring without a NibMotion token" % (r, n))
        if "UICanvasFeedbackGenerator" in line and module not in CANVAS_FEEDBACK_OK:
            errors.append("%s:%d: UICanvasFeedbackGenerator outside FeatPencilHardware / FeatTransform" % (r, n))
        if any(EMOJI.search(lit) for lit in STRING_LITERAL.findall(line)):
            errors.append("%s:%d: emoji in a string literal" % (r, n))
        for lit in localized_literals(line):
            if BANNED_WORDS.search(lit):
                errors.append("%s:%d: banned word in UI copy %s" % (r, n, lit))
            m = US_SPELLINGS.search(lit)
            if m:
                errors.append("%s:%d: US spelling '%s' in UI copy (British English: colour, favourite, centre...)"
                              % (r, n, m.group(0)))
    for start, end in scroll_bodies(text):
        if ".droplet(" in text[start:end]:
            errors.append("%s:%d: .droplet inside a ScrollView/List (chrome belongs to the container above the "
                          "content)" % (r, text.count("\n", 0, start) + 1))


# Scope: modules with a ui/fullstack feature (Package.swift gives them NibDesign) and feature-owned Swift files under
# Nib/ (the app target links NibKit). Not NibWidgets (no NibDesign there) and not the architect's shell (Nib/App).
design_files = []
for m in sorted({f["module"] for f in spec["features"] if f.get("layer") in ("ui", "fullstack")} & set(scan)):
    if m in SHARED:
        continue
    for dirpath, _, files in os.walk(os.path.join(SRC, m)):
        design_files += [(os.path.join(dirpath, fn), m) for fn in sorted(files) if fn.endswith(".swift")]
for f in spec["features"]:
    if f.get("layer") in ("ui", "fullstack") and (not feature_filter or f["id"] == feature_filter):
        design_files += [(os.path.join(ROOT, p), f["module"]) for p in f["files"]
                         if p.startswith("Nib/") and p.endswith(".swift") and os.path.exists(os.path.join(ROOT, p))]
for path, m in design_files:
    design_lint(path, m)

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
