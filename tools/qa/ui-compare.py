#!/usr/bin/env python3
"""Compare two tools/qa/ui-results.py result folders test by test: which tests a later run fixed, broke or still fails.

Usage: python3 tools/qa/ui-compare.py <baseline results dir> <new results dir> [--show N]
Prints one line per class (baseline passed/tests -> new passed/tests, fixed / newly failing / still failing counts),
then the newly failing tests with their messages (first N per class, default 12) and a category count of what
still fails. Classes present in only one run are listed separately. Exit 0.
"""
import collections
import json
import pathlib
import re
import sys


def load(folder):
    res = json.loads((pathlib.Path(folder) / "results.json").read_text(encoding="utf-8"))
    return {c["class"]: c for c in res["classes"]}, res


def category(message):
    if "execution time allowance" in message:
        return "timeout"
    if "did not converge" in message:
        return "state-probe"
    if "Full-screen recovery" in message or "landscape" in message:
        return "window"
    if "not acquired" in message:
        return "runner"
    return "other"


def main():
    args = [a for a in sys.argv[1:] if not a.startswith("--")]
    show = int(sys.argv[sys.argv.index("--show") + 1]) if "--show" in sys.argv else 12
    base, bres = load(args[0])
    new, nres = load(args[1])
    print(f"baseline {bres.get('sha', '')[:7]} ({bres['run']})\nnew      {nres.get('sha', '')[:7]} ({nres['run']})\n")
    totals = collections.Counter()
    for cls in sorted(set(base) | set(new)):
        b, n = base.get(cls), new.get(cls)
        if not b or not n:
            print(f"== {cls}: only in {'baseline' if b else 'new run'}")
            continue
        bf = {f["test"] for f in b["failures"]}
        nf = {f["test"] for f in n["failures"]}
        fixed, broke, still = sorted(bf - nf), sorted(nf - bf), sorted(bf & nf)
        totals.update(fixed=len(fixed), broke=len(broke), still=len(still), passed=n["passed"], tests=n["tests"])
        flag = "INFRA" if n.get("infrastructureError") else ""
        print(f"== {cls}: {b['passed']}/{b['tests']} -> {n['passed']}/{n['tests']} | fixed {len(fixed)}, newly failing {len(broke)}, still failing {len(still)} {flag}")
        messages = {f["test"]: f["message"] for f in n["failures"]}
        for t in broke[:show]:
            print(f"   NEW FAIL {t.split('/')[-1]} | {' '.join(messages[t].split())[:170]}")
        if len(broke) > show:
            print(f"   ... {len(broke) - show} more newly failing")
        cats = collections.Counter(category(messages[t]) for t in nf)
        print(f"   failing now by category: {dict(cats)}")
    print(f"\ntotal: {totals['passed']}/{totals['tests']} passed now; fixed {totals['fixed']}, newly failing {totals['broke']}, still failing {totals['still']}")


if __name__ == "__main__":
    main()
