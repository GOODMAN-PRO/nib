#!/usr/bin/env python3
"""Generate Nib/Resources/parity.json from docs/FEATURES.md (F098, N-028).

The in-app "Goodnotes parity & substitutions" page (FeatAbout's ParityPage) renders this file. It holds:
  * every inventory row (T-, D-, S-, P-###) whose status is `partial`, `substitute` or `n/a`, in document order, with
    its area, Goodnotes feature, status, building features and the note (what Nib does instead);
  * the "Exceptions to the modify-anything guarantee" table, row for row;
  * the status totals over the whole inventory and the "Why things are substituted" paragraph.
Items at `parity` / `parity+` and the Nib-only N-### table are left out: the page lists only what differs.

Usage:
  python3 Scripts/gen_parity.py            rewrite Nib/Resources/parity.json
  python3 Scripts/gen_parity.py --check    exit 1 when the file is out of date (nothing is written)
  python3 Scripts/gen_parity.py --stdout   print the JSON instead of writing it

The output is deterministic (document order, sorted keys, two-space indent, UTF-8), so a regenerated file only
differs when FEATURES.md does.
"""
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
FEATURES = os.path.join(ROOT, "docs", "FEATURES.md")
OUTPUT = os.path.join(ROOT, "Nib", "Resources", "parity.json")

FORMAT = 1
LISTED = ("partial", "substitute", "n/a")
STATUSES = ("parity", "parity+", "partial", "substitute", "n/a")
AREA_HEADING = re.compile(r"^## (.+?) \(([A-Z])-###\)\s*$")
EXCEPTIONS_HEADING = "## Exceptions to the modify-anything guarantee"
WHY_PREFIX = "Why things are substituted:"
ITEM_ID = re.compile(r"^[TDSP]-\d{3}$")


class ParityError(Exception):
    pass


def cells(line):
    """The cells of one Markdown table row: split on unescaped pipes, `\\|` unescaped, whitespace trimmed."""
    body = line.strip()
    if body.startswith("|"):
        body = body[1:]
    if body.endswith("|") and not body.endswith("\\|"):
        body = body[:-1]
    return [c.strip().replace("\\|", "|") for c in re.split(r"(?<!\\)\|", body)]


def is_separator(row):
    return all(re.fullmatch(r":?-{3,}:?", c) for c in row if c)


def parse(text):
    lines = text.split("\n")
    areas, items, exceptions = [], [], []
    totals = {s: 0 for s in STATUSES}
    why = None
    area = None
    in_exceptions = False
    header = None
    seen = set()

    for n, line in enumerate(lines, 1):
        if line.startswith(WHY_PREFIX) and why is None:
            why = line[len(WHY_PREFIX):].strip()
            continue
        if line.startswith("## "):
            header = None
            match = AREA_HEADING.match(line)
            in_exceptions = line.strip() == EXCEPTIONS_HEADING
            area = None
            if match:
                area = match.group(2)
                areas.append({"prefix": area, "title": match.group(1)})
            continue
        if not line.startswith("|"):
            header = None
            continue
        row = cells(line)
        if header is None:
            header = row
            continue
        if is_separator(row):
            continue

        if in_exceptions:
            if len(row) != 4:
                raise ParityError("FEATURES.md:%d: exceptions row has %d cells, expected 4" % (n, len(row)))
            exceptions.append({"class": row[0], "covers": row[1], "why": row[2], "instead": row[3]})
            continue

        if area is None or area == "N" or header[:3] != ["ID", "Goodnotes feature", "Status"]:
            continue
        if len(row) != 5:
            raise ParityError("FEATURES.md:%d: inventory row has %d cells, expected 5" % (n, len(row)))
        item_id, feature, status, built, note = row
        if not ITEM_ID.match(item_id) or not item_id.startswith(area + "-"):
            raise ParityError("FEATURES.md:%d: unexpected id %r in the %s-### table" % (n, item_id, area))
        if status not in STATUSES:
            raise ParityError("FEATURES.md:%d: %s has unknown status %r" % (n, item_id, status))
        if item_id in seen:
            raise ParityError("FEATURES.md:%d: %s is listed twice" % (n, item_id))
        seen.add(item_id)
        totals[status] += 1
        if status not in LISTED:
            continue
        if not note:
            raise ParityError("FEATURES.md:%d: %s is %s but has no note saying what Nib does instead"
                              % (n, item_id, status))
        items.append({
            "id": item_id,
            "area": area,
            "feature": feature,
            "status": status,
            "builtBy": built.split(),
            "note": note,
        })

    if not items:
        raise ParityError("FEATURES.md has no partial, substitute or n/a rows")
    if not exceptions:
        raise ParityError("FEATURES.md has no '%s' table" % EXCEPTIONS_HEADING[3:])
    totals["total"] = sum(totals[s] for s in STATUSES)
    return {
        "format": FORMAT,
        "source": "docs/FEATURES.md",
        "generator": "Scripts/gen_parity.py",
        "why": why or "",
        "totals": totals,
        "areas": [a for a in areas if a["prefix"] != "N"],
        "items": items,
        "exceptions": exceptions,
    }


def render(data):
    return json.dumps(data, indent=2, sort_keys=True, ensure_ascii=False) + "\n"


def main(argv):
    try:
        with open(FEATURES, encoding="utf-8") as f:
            data = parse(f.read())
    except (OSError, ParityError) as e:
        print("gen_parity: %s" % e, file=sys.stderr)
        return 2
    text = render(data)
    if "--stdout" in argv:
        sys.stdout.write(text)
        return 0
    current = None
    if os.path.exists(OUTPUT):
        with open(OUTPUT, encoding="utf-8") as f:
            current = f.read()
    if "--check" in argv:
        if current != text:
            print("gen_parity: Nib/Resources/parity.json is out of date; run python3 Scripts/gen_parity.py",
                  file=sys.stderr)
            return 1
        print("gen_parity: parity.json is up to date (%d items, %d exceptions)"
              % (len(data["items"]), len(data["exceptions"])))
        return 0
    if current != text:
        with open(OUTPUT, "w", encoding="utf-8") as f:
            f.write(text)
    print("gen_parity: wrote %d items (%s) and %d exceptions"
          % (len(data["items"]), ", ".join("%s %d" % (s, data["totals"][s]) for s in LISTED),
             len(data["exceptions"])))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
