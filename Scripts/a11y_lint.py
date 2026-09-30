#!/usr/bin/env python3
"""Accessibility lint for Nib's Swift UI code (F095, P-088; DESIGN_SYSTEM.md §4). Reports warnings; CI runs it as a
warning step, so it never fails a build unless `--strict` is given.

Every control VoiceOver cannot name is a warning:
  * a SwiftUI `Button` whose label is only an `Image` (no `Text`/`Label`) and that has no `.accessibilityLabel(`;
  * a `NibIconButton` / `NibDropletButton(symbol:…)` whose `label:` is empty;
  * a `.droplet(` whose view has no text content and no `.accessibilityLabel(`;
  * an `Image` made tappable with `.onTapGesture` and no label or button trait;
  * UIKit: a `UIButton` given only an image (`setImage` / an image configuration) with no `accessibilityLabel` and no
    title, a `UIBarButtonItem(image:…)` with no `accessibilityLabel`, a `UIAction(title: "", image: …)`;
  * a toolbar, menu, panel or key-command descriptor with an empty `title:` (its title is its VoiceOver label).
Labels that VoiceOver would read in English whatever the language are warnings too: a string literal assigned to
UIKit's `accessibilityLabel`/`accessibilityHint`, or passed as a NibDesign `label:`, instead of `String(localized:)`.

Usage: python3 Scripts/a11y_lint.py [--feature F012] [--strict] [paths...]
  (no paths: every module in NibKit/Sources except NibTesting, and the app target in Nib/)
Output: `warning: <path>:<line>: <message>` lines, GitHub annotations when GITHUB_ACTIONS is set, and a count.
"""
import argparse
import glob
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from extract_strings import lex, matching, call_args, module_of, ROOT, SPEC  # noqa: E402

TEXTUAL = {"Text", "Label", "LabeledContent", "NibHUDText", "TextField", "SecureField", "NibButton",
           "NibDropletButton", "NibChip", "NibRow", "NibInspectorRow", "NibSidebarRow", "NibBanner", "NibTraceRow",
           "NibEmptyState", "NibPanelHeader", "NibSheetHeader", "NibBarTitle", "NibToolbarItem", "NibIconButton",
           "NibToggle", "NibField", "NibSearchField", "NibOptionTile", "NibWidthPresetButton", "NibTool",
           "NibToolButton", "NibQRCode", "NibCodeBlock", "Toggle", "Stepper", "Picker", "Menu", "Link", "ShareLink",
           "NibPopoverPanel", "NibInspectorSection", "NibBudPopover", "NibFolderTile", "NibPageThumbnail"}
LABEL_MODIFIERS = {"accessibilityLabel", "accessibilityRepresentation", "accessibilityHidden"}
# Views that never carry text: a label or droplet built only from these is icon-only. Anything else (a feature's own
# row or panel type) is given the benefit of the doubt, since its text lives in its own file.
ICON_VIEWS = {"Image", "Color", "Circle", "Capsule", "Rectangle", "RoundedRectangle", "Ellipse", "UnevenRoundedRectangle",
              "ContainerRelativeShape", "NibDropletShape", "NibMiniPageThumbnail", "NibFolderGlyphView", "NibStatusDot",
              "NibWaveform", "NibPenSwatch"}
LAYOUT_VIEWS = {"HStack", "VStack", "ZStack", "Group", "Spacer", "EmptyView", "Divider", "ForEach", "GeometryReader",
                "ViewThatFits", "AnyView", "CGFloat", "CGSize", "CGPoint", "CGRect", "Double", "Int", "Angle", "Font",
                "Edge", "Alignment", "UnitPoint", "EdgeInsets"}
DESCRIPTORS = {"ToolbarItemDescriptor", "MenuItemDescriptor", "PanelDescriptor", "KeyCommandDescriptor",
               "CanvasToolDescriptor", "SettingsPageDescriptor"}


class Report:
    def __init__(self):
        self.items = []

    def warn(self, rel, line, message):
        self.items.append((rel, line, message))


def is_id(t, name=None):
    return t.kind == "id" and (name is None or t.text == name)


def is_punct(t, text):
    return t.kind == "punct" and t.text == text


def literal(tok):
    if tok.kind != "str" or any(p[0] == "interp" for p in tok.parts):
        return None
    return "".join(p[1] for p in tok.parts)


def names_in(toks):
    """Identifiers in a token list, including inside string interpolations."""
    out = set()
    for t in toks:
        if t.kind == "id":
            out.add(t.text)
        elif t.kind == "str" and t.interps:
            for sub in t.interps:
                out |= names_in(sub)
    return out


def view_calls(toks):
    """Capitalised identifiers used as views or values in a token list: `Image(…)`, `HStack {…}`, `Color.clear`."""
    out = set()
    for k, t in enumerate(toks):
        if t.kind == "str" and t.interps:
            for sub in t.interps:
                out |= view_calls(sub)
        if t.kind != "id" or not t.text[:1].isupper() or (k > 0 and is_punct(toks[k - 1], ".")):
            continue
        nxt = toks[k + 1] if k + 1 < len(toks) else None
        if nxt is not None and nxt.kind == "punct" and nxt.text in "({" or t.text == "Color":
            out.add(t.text)
    return out


def icon_only(toks):
    """True when a view is built only from images and shapes (and layout around them), with no text."""
    calls = view_calls(toks)
    return bool(calls & ICON_VIEWS) and calls <= (ICON_VIEWS | LAYOUT_VIEWS) and not any(t.kind == "str" for t in toks)


def modifier_chain(toks, j):
    """Modifier names applied after position j (the index after a view expression), and where the chain ends."""
    names = []
    n = len(toks)
    while j + 1 < n and is_punct(toks[j], ".") and is_id(toks[j + 1]):
        names.append(toks[j + 1].text)
        j += 2
        while j < n and (is_punct(toks[j], "(") or is_punct(toks[j], "{")):
            j = matching(toks, j) + 1
            # a trailing closure may carry a label: `.contextMenu { } preview: { }`
            if j + 2 < n and is_id(toks[j]) and is_punct(toks[j + 1], ":") and is_punct(toks[j + 2], "{"):
                j += 2
    return names, j


def expression_start(toks, i):
    """Walks back from toks[i] (the '.' of a modifier) to the start of the view expression it modifies."""
    j = i - 1
    while j >= 0:
        t = toks[j]
        if t.kind == "punct" and t.text in ")]}":
            depth = 0
            k = j
            while k >= 0:
                if toks[k].kind == "punct" and toks[k].text in ")]}":
                    depth += 1
                elif toks[k].kind == "punct" and toks[k].text in "([{":
                    depth -= 1
                    if depth == 0:
                        break
                k -= 1
            j = k - 1
            continue
        if t.kind == "id" and j > 0 and is_punct(toks[j - 1], "."):
            j -= 2
            continue
        if t.kind in ("id", "str", "num"):
            return j
        return j + 1
    return 0


def closure_label(toks, i):
    """Tokens of a Button's label (None when its title is a string or the label cannot be found)."""
    n = len(toks)
    j = i + 1
    label = None
    if j < n and is_punct(toks[j], "("):
        close = matching(toks, j)
        args = call_args(toks, j)
        if args and args[0][0] is None:
            return None  # Button("Title") / Button(titleKey) / Button(someString)
        for lab, arg in args:
            if lab == "label":
                label = arg
        j = close + 1
    if j < n and is_punct(toks[j], "{"):
        close = matching(toks, j)
        first = toks[j + 1:close]
        j = close + 1
        if j + 2 < n and is_id(toks[j], "label") and is_punct(toks[j + 1], ":") and is_punct(toks[j + 2], "{"):
            close2 = matching(toks, j + 2)
            label = toks[j + 3:close2]
            j = close2 + 1
        elif label is None:
            label = first
    return label, j


def lint_swiftui(toks, rel, report):
    n = len(toks)
    for i, t in enumerate(toks):
        if t.kind == "str" and t.interps:
            for sub in t.interps:
                lint_swiftui(sub, rel, report)
        if t.kind != "id":
            continue
        prev_dot = i > 0 and is_punct(toks[i - 1], ".")
        # Button whose label is only an image.
        if t.text == "Button" and not prev_dot and i + 1 < n and (is_punct(toks[i + 1], "(") or is_punct(toks[i + 1], "{")):
            found = closure_label(toks, i)
            if found is None:
                continue
            label, end = found
            if not label:
                continue
            names = names_in(label)
            if icon_only(label) and not (names & TEXTUAL) and not (names & LABEL_MODIFIERS):
                chain, _ = modifier_chain(toks, end)
                if not (set(chain) & LABEL_MODIFIERS):
                    report.warn(rel, t.line, "Button with only an Image as its label needs .accessibilityLabel(…)")
        # NibIconButton / NibDropletButton(symbol:) with an empty or English-only label.
        if t.text in ("NibIconButton", "NibDropletButton", "NibWidthPresetButton") and not prev_dot \
                and i + 1 < n and is_punct(toks[i + 1], "("):
            for lab, arg in call_args(toks, i + 1):
                if lab != "label":
                    continue
                if len(arg) == 1 and literal(arg[0]) is not None:
                    if not literal(arg[0]).strip():
                        report.warn(rel, t.line, "%s has an empty label: VoiceOver cannot name it" % t.text)
                    else:
                        report.warn(rel, t.line, "%s label %r is not localised (use String(localized:))"
                                    % (t.text, literal(arg[0])))
        # .droplet on a view without text.
        if t.text == "droplet" and prev_dot and i + 1 < n and is_punct(toks[i + 1], "("):
            start = expression_start(toks, i - 1)
            base = toks[start:i - 1]
            names = names_in(base)
            chain, _ = modifier_chain(toks, i - 1)
            # Only droplets drawn from images and shapes: a container that exposes its children
            # (.accessibilityElement(children: .contain)) is named by them, a view the caller passed in (`content`) is
            # the caller's to label, and a feature's own panel type carries its text in its own file.
            container = "accessibilityElement" in chain or "accessibilityElement" in names
            if icon_only(base) and not (names & TEXTUAL) and not container and not (set(chain) & LABEL_MODIFIERS) \
                    and not (names & LABEL_MODIFIERS):
                report.warn(rel, t.line, ".droplet(…) around a view without text needs .accessibilityLabel(…)")
        # Tappable images.
        if t.text == "Image" and not prev_dot and i + 1 < n and is_punct(toks[i + 1], "("):
            chain, _ = modifier_chain(toks, matching(toks, i + 1) + 1)
            if "onTapGesture" in chain and not (set(chain) & LABEL_MODIFIERS):
                report.warn(rel, t.line, "Image with .onTapGesture needs .accessibilityLabel(…) and the button trait "
                                         "(or make it a Button)")
        # Descriptors with an empty title.
        if t.text in DESCRIPTORS and not prev_dot and i + 1 < n and is_punct(toks[i + 1], "("):
            for lab, arg in call_args(toks, i + 1):
                if lab == "title" and len(arg) == 1 and literal(arg[0]) is not None and not literal(arg[0]).strip():
                    report.warn(rel, t.line, "%s has an empty title (its VoiceOver label)" % t.text)


UIKIT_ASSIGN = re.compile(r"\b([A-Za-z_][\w.]*)\.(accessibilityLabel|accessibilityHint)\s*=\s*\"([^\"\\\n]*)\"")
UIBUTTON = re.compile(r"\b(?:let|var)\s+([A-Za-z_]\w*)\s*(?::\s*UIButton\s*)?=\s*UIButton\s*\(")
BAR_ITEM = re.compile(r"\b(?:let|var)\s+([A-Za-z_]\w*)\s*(?::\s*UIBarButtonItem\s*)?=\s*UIBarButtonItem\s*\(\s*image:")
EMPTY_ACTION = re.compile(r"UIAction\s*\(\s*title:\s*\"\"\s*,\s*image:")


def strip_comments(text):
    """The text with comments blanked (line numbers kept), for the UIKit regex checks."""
    out, i, n = [], 0, len(text)
    in_str = False
    while i < n:
        c = text[i]
        if in_str:
            out.append(c)
            if c == "\\" and i + 1 < n:
                out.append(text[i + 1])
                i += 2
                continue
            if c == '"' or c == "\n":
                in_str = False
            i += 1
            continue
        if c == '"':
            in_str = True
            out.append(c)
            i += 1
            continue
        if text.startswith("//", i):
            j = text.find("\n", i)
            j = n if j < 0 else j
            i = j
            continue
        if text.startswith("/*", i):
            j = text.find("*/", i + 2)
            j = n if j < 0 else j + 2
            out.append("".join("\n" if ch == "\n" else " " for ch in text[i:j]))
            i = j
            continue
        out.append(c)
        i += 1
    return "".join(out)


def line_of(text, pos):
    return text.count("\n", 0, pos) + 1


def lint_uikit(text, rel, report):
    code = strip_comments(text)
    for m in UIKIT_ASSIGN.finditer(code):
        report.warn(rel, line_of(code, m.start()), "%s = %r is not localised (use String(localized:))"
                    % (m.group(2), m.group(3)))
    for m in UIBUTTON.finditer(code):
        name = re.escape(m.group(1))
        imaged = re.search(r"\b%s\.(setImage\(|configuration\s*=)" % name, code) or \
            re.search(r"UIButton\s*\([^)]*image:", code[m.start():m.start() + 300])
        titled = re.search(r"\b%s\.(setTitle\(|setAttributedTitle\(|accessibilityLabel\s*=|configuration\??\.title\s*=|"
                           r"isAccessibilityElement\s*=\s*false)" % name, code) \
            or re.search(r"\b%s\.configuration\s*=\s*[^\n]*title" % name, code)
        if imaged and not titled:
            report.warn(rel, line_of(code, m.start()), "UIButton '%s' shows only an image: set accessibilityLabel"
                        % m.group(1))
    for m in BAR_ITEM.finditer(code):
        name = re.escape(m.group(1))
        if not re.search(r"\b%s\.(accessibilityLabel|title)\s*=" % name, code):
            report.warn(rel, line_of(code, m.start()), "UIBarButtonItem '%s' with an image needs accessibilityLabel"
                        % m.group(1))
    for m in EMPTY_ACTION.finditer(code):
        report.warn(rel, line_of(code, m.start()), "UIAction with an empty title and an image has no VoiceOver label")


def lint_file(path, report):
    rel = os.path.relpath(path, ROOT).replace(os.sep, "/")
    text = open(path, encoding="utf-8", errors="replace").read()
    try:
        toks = lex(text)
    except (IndexError, ValueError) as e:
        report.warn(rel, 1, "could not be read (%s)" % e)
        return
    lint_swiftui(toks, rel, report)
    lint_uikit(text, rel, report)


def default_files(feature=None):
    if feature:
        spec = json.load(open(SPEC, encoding="utf-8"))
        f = next((x for x in spec["features"] if x["id"] == feature), None)
        if f is None:
            sys.exit("a11y_lint: unknown feature %s" % feature)
        files = glob.glob(os.path.join(ROOT, "NibKit", "Sources", f["module"], "**", "*.swift"), recursive=True)
        files += [os.path.join(ROOT, p) for p in f["files"] if p.endswith(".swift") and not p.startswith("NibKit/")]
        return sorted(p for p in set(files) if os.path.exists(p))
    files = [p for p in glob.glob(os.path.join(ROOT, "NibKit", "Sources", "**", "*.swift"), recursive=True)
             if module_of(os.path.relpath(p, ROOT).replace(os.sep, "/")) != "NibTesting"]
    files += glob.glob(os.path.join(ROOT, "Nib", "**", "*.swift"), recursive=True)
    return sorted(files)


def main(argv=None):
    ap = argparse.ArgumentParser(description="Accessibility lint (warnings).")
    ap.add_argument("paths", nargs="*", help="Swift files or folders (default: the whole app)")
    ap.add_argument("--feature", help="only this feature's module and files")
    ap.add_argument("--strict", action="store_true", help="exit 1 when there are warnings")
    args = ap.parse_args(argv)
    files = []
    for p in args.paths:
        if os.path.isdir(p):
            files += glob.glob(os.path.join(p, "**", "*.swift"), recursive=True)
        else:
            files.append(p)
    if not args.paths:
        files = default_files(args.feature)
    report = Report()
    for f in sorted(set(os.path.abspath(x) for x in files)):
        lint_file(f, report)
    annotate = bool(os.environ.get("GITHUB_ACTIONS"))
    for rel, line, message in sorted(report.items):
        print("warning: %s:%d: %s" % (rel, line, message))
        if annotate:
            print("::warning file=%s,line=%d::%s" % (rel, line, message))
    print("a11y_lint: %d warning(s) in %d file(s)" % (len(report.items), len(set(files))))
    return 1 if args.strict and report.items else 0


if __name__ == "__main__":
    sys.exit(main())
