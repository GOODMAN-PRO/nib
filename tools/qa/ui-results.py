#!/usr/bin/env python3
"""Collect the results of one `UI tests` (ui.yml) GitHub Actions run into a failure list grouped by class and owner.

The Mac-only tools/qa/ui-ci.sh snapshots, dispatches, waits and then parses one run; this script is the parsing half for
any platform (Windows, Linux, macOS), for a run that was dispatched with `gh workflow run ui.yml --ref <branch>`.

Usage: python3 tools/qa/ui-results.py <run-id> [--out DIR] [--repo GOODMAN-PRO/nib]
  Downloads the small `ui-<Class>` artifacts (summary.json, status.json, timing.json, ui.log, shots/) into
  DIR/<run-id>/ (default <repo parent>/Nib-ci-logs/ui-ci), prints one line per class and one `FAIL <Class>/<test>:
  <message>` line per failing test, maps each class to the feature owners of its QA area (tools/qa/matrix.json), and
  writes DIR/<run-id>/results.json. Exit 0 = every class passed, 1 = test failures, 2 = infrastructure error or the run
  has not completed (--partial reports the completed classes of a run that is still going).
"""
import argparse
import glob
import json
import os
import pathlib
import subprocess
import sys

ROOT = pathlib.Path(__file__).resolve().parents[2]
try:  # from a worktree, keep the logs next to the main clone (../Nib-ci-logs of the main checkout)
    _common = subprocess.run(["git", "-C", str(ROOT), "rev-parse", "--path-format=absolute", "--git-common-dir"], capture_output=True, text=True, check=True).stdout.strip()
    MAIN = pathlib.Path(_common).parent
except (OSError, subprocess.CalledProcessError):
    MAIN = ROOT


def gh(*args):
    return subprocess.run(["gh", *args], capture_output=True, text=True, check=True, encoding="utf-8").stdout


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("run")
    ap.add_argument("--repo", default="GOODMAN-PRO/nib")
    ap.add_argument("--out", default=str(MAIN.parent / "Nib-ci-logs" / "ui-ci"))
    ap.add_argument("--no-download", action="store_true", help="reuse what is already in the output folder")
    ap.add_argument("--partial", action="store_true", help="report the classes that have completed while the run is still going")
    a = ap.parse_args()
    out = pathlib.Path(a.out) / a.run
    out.mkdir(parents=True, exist_ok=True)
    run = json.loads(gh("run", "view", a.run, "--repo", a.repo, "--json", "status,conclusion,jobs,url,headSha,headBranch,displayTitle"))
    (out / "run.json").write_text(json.dumps(run, indent=1), encoding="utf-8")
    print(f"{run['displayTitle']} ({run['headBranch']} {run['headSha'][:7]}): {run['status']} {run.get('conclusion') or ''}  {run['url']}")
    if run["status"] != "completed":
        for job in run["jobs"]:
            print(f"  {job['name']}: {job['status']} {job.get('conclusion') or ''}")
        if not a.partial:
            print("run not completed yet", file=sys.stderr)
            return 2
        run["jobs"] = [j for j in run["jobs"] if j["status"] == "completed"]
    if not a.no_download:
        for stale in glob.glob(str(out / "ui-*")):
            pass  # keep earlier downloads of other classes; gh overwrites files in place
        subprocess.run(["gh", "run", "download", a.run, "--repo", a.repo, "--pattern", "ui-*", "--dir", str(out)], check=False)
    matrix = {}
    try:
        for area in json.load(open(ROOT / "tools" / "qa" / "matrix.json", encoding="utf-8"))["areas"]:
            matrix[area["key"].lower()] = area.get("owners", [])
    except (OSError, KeyError, ValueError):
        pass
    classes, errors, total = [], [], {"tests": 0, "passed": 0, "failed": 0, "skipped": 0, "expectedFailures": 0}
    for job in run["jobs"]:
        if not job["name"].startswith("UI / "):
            continue
        cls = job["name"][len("UI / "):]
        area = cls[: -len("UITests")].lower() if cls.endswith("UITests") else cls.lower()
        folder = out / f"ui-{cls}"
        entry = {"class": cls, "job": job["conclusion"], "owners": matrix.get(area, []), "tests": 0, "passed": 0, "failed": 0,
                 "skipped": 0, "expectedFailures": 0, "infrastructureError": None, "failures": [], "shots": sorted(str(p.relative_to(out)) for p in folder.glob("shots/**/*.jpg"))}
        try:
            summary = json.loads((folder / "summary.json").read_text(encoding="utf-8"))
            status = json.loads((folder / "status.json").read_text(encoding="utf-8"))
            timing = json.loads((folder / "timing.json").read_text(encoding="utf-8")) if (folder / "timing.json").exists() else {}
            entry.update(tests=summary["tests"], passed=summary["passed"], failed=summary["failed"], failures=summary["failures"],
                         skipped=summary.get("skipped", 0), expectedFailures=summary.get("expectedFailures", 0),
                         infrastructureError=status["infrastructureError"], xcodebuildExit=status.get("xcodebuildExit"),
                         minutes=round(timing.get("totalSeconds", 0) / 60))
            if status["infrastructureError"] or summary["tests"] <= 0:
                errors.append(f"{cls}: infrastructure/build error (xcodebuild exit {status.get('xcodebuildExit')}); see {folder / 'ui.log'}")
        except (OSError, KeyError, ValueError) as error:
            errors.append(f"{cls}: no usable artifact ({error}); job {job['conclusion']}")
            entry["infrastructureError"] = True
        for k in ("tests", "passed", "failed", "skipped", "expectedFailures"):
            total[k] += entry[k]
        classes.append(entry)
    for c in sorted(classes, key=lambda c: c["class"]):
        flag = "INFRA" if c["infrastructureError"] else ("PASS" if not c["failed"] else "FAIL")
        # A skipped test is one the class itself declared device-only for this run; it is never counted as passed.
        other = "".join(f"  {c[k]} {label}" for k, label in (("skipped", "skipped"), ("expectedFailures", "expected failures")) if c.get(k))
        print(f"{flag:5} {c['class']:18} {c['passed']:3}/{c['tests']:<3} passed{other}  {c.get('minutes', '?'):>3} min  owners {' '.join(c['owners']) or '-'}")
    print(f"total: {total['tests']} tests, {total['passed']} passed, {total['failed']} failed, {total['skipped']} skipped, {total['expectedFailures']} expected failures")
    for c in sorted(classes, key=lambda c: c["class"]):
        for f in c["failures"]:
            print(f"FAIL {f['test']}: {' '.join(f['message'].split())}")
    for e in errors:
        print("UI CI error: " + e, file=sys.stderr)
    (out / "results.json").write_text(json.dumps({"run": run["url"], "sha": run["headSha"], "branch": run["headBranch"],
                                                  "total": total, "classes": classes, "errors": errors}, indent=1, ensure_ascii=False), encoding="utf-8")
    print(f"results: {out / 'results.json'}")
    return 2 if errors else (1 if total["failed"] else 0)


if __name__ == "__main__":
    sys.exit(main())
