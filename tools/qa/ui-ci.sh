#!/bin/bash
# Usage: [NIB_UI_DEVICE="iPhone 17 Pro"] tools/qa/ui-ci.sh <name> "<identifiers or empty>" [extra paths...]
# Exit: 0 passed, 1 test failures, 2 build/infrastructure/client error.
set -euo pipefail
repo=GOODMAN-PRO/nib
run_id=
temporary_index=
run_dir=
fail() { echo "UI CI error: $*" >&2; exit 2; }
cleanup() {
    result=$?
    trap - EXIT
    if [ -n "$temporary_index" ]; then rm -f "$temporary_index" "$temporary_index.lock"; fi
    if [ "$result" -ne 0 ] && [ "$result" -ne 1 ]; then
        if [ -n "$run_id" ]; then
            gh run view "$run_id" --repo "$repo" --log-failed 2>&1 | tail -80 >&2 || true
        fi
        exit 2
    fi
    exit "$result"
}
trap cleanup EXIT
# GitHub's API drops connections now and then; retry every network call instead of abandoning a long run.
retry() { local attempt; for attempt in 1 2 3 4 5 6 7 8; do "$@" && return 0; sleep $((attempt * 15)); done; return 1; }
trap 'exit 2' HUP INT TERM
[ "$#" -ge 2 ] || fail 'Usage: tools/qa/ui-ci.sh <name> "<identifiers or empty>" [extra paths...]'
name=$1
only=$2
shift 2
case "$name" in ''|*[!a-zA-Z0-9_-]*) fail 'Name must contain only letters, digits, underscores, or hyphens';; esac
for dependency in git gh python3 ditto; do command -v "$dependency" >/dev/null || fail "Missing $dependency"; done
root=$(git rev-parse --show-toplevel) || fail 'Run from the intended Nib worktree'
cd "$root"
# Validate before pushing; an empty selection snapshots every current class, including new files.
classes=$(python3 - "$only" <<'PY'
import glob, pathlib, re, sys
identifiers = sys.argv[1].split()
classes = set()
for identifier in identifiers:
    if not re.fullmatch(r'NibUITests/[A-Za-z_][A-Za-z0-9_]*UITests(?:/[A-Za-z_][A-Za-z0-9_]*(?:\(\))?)?', identifier):
        sys.exit('Invalid UI test identifier: ' + identifier)
    classes.add(identifier.split('/')[1])
if not identifiers:
    classes = {pathlib.Path(p).stem for p in glob.glob('NibUITests/*UITests.swift')}
if not classes:
    sys.exit('No UI test classes found')
for cls in sorted(classes):
    if not pathlib.Path('NibUITests', cls + '.swift').is_file():
        sys.exit('Missing test class: ' + cls)
    print(cls)
PY
) || fail 'Invalid test selection'
temporary_index=$(mktemp "${TMPDIR:-/tmp}/nib-ui-index.XXXXXX")
# read-tree needs either a valid index or a nonexistent file, not mktemp's empty file.
rm -f "$temporary_index"
sha=$(
    export GIT_INDEX_FILE="$temporary_index"
    git read-tree HEAD || exit 2
    git add -- .github/workflows/ui.yml tools/qa NibUITests/Support || exit 2
    while IFS= read -r cls; do git add -- "NibUITests/$cls.swift" || exit 2; done <<< "$classes"
    if [ "$#" -gt 0 ]; then git add -- "$@" || exit 2; fi
    tree=$(git write-tree) || exit 2
    git commit-tree "$tree" -p HEAD -m "UI CI snapshot $name" || exit 2
) || fail 'Could not create snapshot'
retry git push -q -f origin "$sha:refs/heads/qa-ci/$name" || fail 'Could not push snapshot'
echo "UI CI $name: snapshot $sha" >&2
# NIB_UI_DEVICE picks the simulator (device name prefix, e.g. "iPhone 17 Pro"); unset = the workflow default (iPad Pro 13-inch).
device_args=()
if [ -n "${NIB_UI_DEVICE:-}" ]; then device_args=(-f "device=$NIB_UI_DEVICE"); fi
gh workflow run ui.yml --repo "$repo" --ref "qa-ci/$name" -f "only=$only" -f "label=$name" ${device_args[@]+"${device_args[@]}"} || retry gh workflow run ui.yml --repo "$repo" --ref "qa-ci/$name" -f "only=$only" -f "label=$name" ${device_args[@]+"${device_args[@]}"} || fail 'Could not dispatch workflow'
attempt=0
while [ -z "$run_id" ]; do
    runs=$(retry gh run list --repo "$repo" --workflow ui.yml --branch "qa-ci/$name" --limit 100 --json databaseId,headSha) || fail 'Could not list runs'
    run_id=$(python3 -c 'import json,sys; print(next((str(r["databaseId"]) for r in json.load(sys.stdin) if r["headSha"] == sys.argv[1]), ""))' "$sha" <<< "$runs")
    attempt=$((attempt + 1))
    [ -n "$run_id" ] && break
    [ "$attempt" -lt 120 ] || fail 'Dispatched run did not appear within 10 minutes'
    sleep 5
done
url="https://github.com/$repo/actions/runs/$run_id"
echo "UI CI $name: watching $url" >&2
# No timeout: UI suites can take hours. Retry transient watch errors while still active.
while :; do
    gh run watch "$run_id" --repo "$repo" --interval 60 > /dev/null || true
    state=$(retry gh run view "$run_id" --repo "$repo" --json status --jq .status) || fail 'Could not read run status'
    [ "$state" = completed ] && break
    sleep 10
done
run_dir="$HOME/Projects/Nib-ci-logs/ui-ci/$name/$run_id"
mkdir -p "$run_dir"
retry gh run view "$run_id" --repo "$repo" --json conclusion,jobs,url,headSha > "$run_dir/run.json" || fail 'Could not read completed run'
download() { rm -rf "$run_dir"/ui-*; gh run download "$run_id" --repo "$repo" --pattern 'ui-*' --dir "$run_dir"; }
retry download || fail 'Could not download UI artifacts'
python3 - "$run_dir" "$name" "$classes" "$url" <<'PY'
import json, pathlib, subprocess, sys
root, name, classes, url = pathlib.Path(sys.argv[1]), *sys.argv[2:]
run = json.loads((root / 'run.json').read_text())
errors, reports, bundles = [], [], []
for cls in classes.split():
    artifact = root / ('ui-' + cls)
    try:
        report = json.loads((artifact / 'summary.json').read_text())
        status = json.loads((artifact / 'status.json').read_text())
        if report['class'] != cls or report['tests'] <= 0 or status['infrastructureError']:
            errors.append(cls + ': missing tests or infrastructure/build error')
        reports.append(report)
        archive = artifact / 'ui.xcresult.zip'
        if not archive.is_file():
            raise ValueError('Missing zipped xcresult')
        subprocess.run(['ditto', '-x', '-k', str(archive), str(artifact)], check=True)
        bundle = artifact / 'ui.xcresult'
        if not bundle.is_dir():
            raise ValueError('Missing extracted xcresult')
        bundles.append(str(bundle))
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        errors.append(cls + ': ' + str(error))
for job in run['jobs']:
    if job['conclusion'] not in ('success', 'failure'):
        errors.append(job['name'] + ': ' + job['conclusion'])
    if job['conclusion'] == 'failure':
        failed_steps = [s['name'] for s in job['steps'] if s['conclusion'] == 'failure']
        if not failed_steps or any(s != 'Fail if tests failed' for s in failed_steps):
            errors.append(job['name'] + ': ' + ', '.join(failed_steps))
tests = sum(r['tests'] for r in reports)
passed = sum(r['passed'] for r in reports)
failed = sum(r['failed'] for r in reports)
if run['conclusion'] != 'success' and not failed:
    errors.append('Run concluded ' + run['conclusion'])
print(f'UI CI {name}: {tests} tests, {passed} passed, {failed} failed (run {url})', flush=True)
for report in reports:
    for failure in report['failures']:
        print('FAIL ' + failure['test'] + ': ' + ' '.join(failure['message'].split()), flush=True)
for bundle in bundles:
    print(bundle, flush=True)
for error in errors:
    print('UI CI error: ' + error, file=sys.stderr)
sys.exit(2 if errors else 1 if failed else 0)
PY
