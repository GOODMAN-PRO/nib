#!/usr/bin/env python3
"""Categorise the failures of a tools/qa/ui-results.py results.json into a compact digest for triage.

Usage: python3 tools/qa/ui-digest.py <results-dir>     (the folder holding results.json; writes digest.json next to it)
Categories: timeout, state-probe, launch/fixture, not-hittable, missing-element, assertion, wait-expectation, other.
Messages are cut before the accessibility-tree dump and to 420 characters; the test file:line is kept when present.
Prints the category counts per class, one example per category and the most frequent message shapes per class.
"""
import collections
import json
import pathlib
import re
import sys

CATS = [("timeout", r"exceeded execution time allowance"), ("state-probe", r"State did not converge|nib\.qa\.state"),
        ("launch/fixture", r"Failed to launch|fixtureError|not running|crash|Lost connection|Application .* quit"),
        ("not-hittable", r"not hittable|Failed to tap|Failed to scroll"),
        ("missing-element", r"No matches found|Failed to find|does not exist|not found|Unable to find"),
        ("assertion", r"XCTAssert|is not equal|is not true|is not false|not greater|not less"),
        ("wait-expectation", r"Asynchronous wait failed|Exceeded timeout|timed out waiting")]


def short(message):
    message = re.split(r"Attributes: Application|Element subtree:", message)[0]
    return " ".join(message.split())[:420]


def category(message):
    for name, pattern in CATS:
        if re.search(pattern, message, re.I):
            return name
    return "other"


def shape(message):
    message = re.sub(r"^failed(: caught error: )?(- )?", "", message)
    return re.sub(r'"[^"]*"', '"…"', message)[:70]


def main():
    root = pathlib.Path(sys.argv[1])
    res = json.loads((root / "results.json").read_text(encoding="utf-8"))
    digest = {"run": res["run"], "sha": res.get("sha"), "classes": {}, "categories": collections.Counter()}
    for c in res["classes"]:
        failures = []
        for f in c["failures"]:
            kind = category(f["message"])
            digest["categories"][kind] += 1
            loc = re.search(r", (/[^ ,]+\.swift:\d+)\s*$", f["message"])
            failures.append({"test": f["test"], "category": kind, "message": short(f["message"]), "location": loc.group(1) if loc else None})
        digest["classes"][c["class"]] = {"tests": c["tests"], "passed": c["passed"], "failed": c["failed"], "minutes": c.get("minutes"),
                                         "owners": c["owners"], "infrastructureError": c.get("infrastructureError"), "failures": failures}
    digest["categories"] = dict(digest["categories"])
    (root / "digest.json").write_text(json.dumps(digest, ensure_ascii=False, indent=1), encoding="utf-8")
    print("categories:", digest["categories"])
    for cls, d in digest["classes"].items():
        counts = collections.Counter(f["category"] for f in d["failures"])
        print(f"{cls}: {d['passed']}/{d['tests']} passed, {d['minutes']} min ->", dict(counts))
    seen = set()
    print("\n--- one example per category ---")
    for d in digest["classes"].values():
        for f in d["failures"]:
            if f["category"] not in seen:
                seen.add(f["category"])
                print(f"[{f['category']}] {f['test']}: {f['message'][:300]}")
    print("\n--- most frequent message shapes per class ---")
    for cls, d in digest["classes"].items():
        counts = collections.Counter(shape(f["message"]) for f in d["failures"])
        print(f"== {cls} ({d['failed']} failed)")
        for k, n in counts.most_common(6):
            print(f"   {n:3}  {k}")
    print(f"\ndigest: {root / 'digest.json'}")


if __name__ == "__main__":
    main()
