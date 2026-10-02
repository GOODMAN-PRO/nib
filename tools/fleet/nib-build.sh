#!/usr/bin/env bash
# Local build + test for the Nib fleet on this Mac (M1, 8 GB RAM, tight disk).
# Mirrors .github/workflows/ios.yml. At most NIB_SLOTS (default 2) xcodebuilds run at once, machine-wide;
# each slot has its own DerivedData, SPM clone dir and cloned simulator, so disk stays bounded.
#
# Usage:
#   nib-build.sh feature <worktree> <Fxxx>        lint --feature + build/test that feature's test targets (+ app if it owns app files)
#   nib-build.sh targets <worktree> "<T1 T2 ...>" build/test the named test targets (e.g. NibContractsTests)
#   nib-build.sh full    <worktree>               lint + xcodegen + every package test (NibKit-Package) + app build
#   nib-build.sh app     <worktree>               xcodegen + app build only (Debug, generic iOS, unsigned)
#   nib-build.sh archive <worktree>               xcodegen + Release archive + unsigned IPA into <worktree>/build
#   nib-build.sh uitest  <worktree> ["<NibUITests/Class ...>"]  XCUITest run on a dedicated iPad simulator (one UI run at a time; log local-<wt>-uitest-<class|all>.log, bundle ui-<class|all>.xcresult)
#
# The full log goes to ~/Projects/Nib-ci-logs/local-<worktree-name>-<mode>.log; its exit code to the matching .exit file.
# If your Bash call times out, the build keeps running: wait for the .exit file (e.g. `until [ -f X.exit ]; do sleep 20; done`).
# Prints "LOCAL BUILD OK" on success; on failure prints the error lines and the log tail, and exits non-zero.
set -uo pipefail
MODE="${1:?mode}"; WTREE="$(cd "${2:?worktree}" && pwd)"; ARG="${3:-}"
BASE="$HOME/Projects"
LOCKS="$BASE/Nib-locks"; LOGS="$BASE/Nib-ci-logs"; SLOTS="${NIB_SLOTS:-2}"
mkdir -p "$LOCKS" "$LOGS"
NAME="$(basename "$WTREE")"
UITAG=""
if [ "$MODE" = uitest ]; then
  UITAG="$(echo "${ARG:-all}" | sed -E 's#NibUITests/##g; s#[^A-Za-z0-9]+#-#g; s#-$##')"; UITAG="${UITAG:0:60}"
  # Hard per-job budget (set by the orchestrator through nib-codex.sh): a Codex job may start at most NIB_UI_MAX UI runs.
  if [ -n "${NIB_JOB:-}" ] && [ -n "${NIB_UI_MAX:-}" ]; then
    cf="$LOGS/uiruns-$NIB_JOB"; n=$(( $(cat "$cf" 2>/dev/null || echo 0) + 1 ))
    if [ "$n" -gt "$NIB_UI_MAX" ]; then
      echo "UI RUN BUDGET EXHAUSTED: job $NIB_JOB already used its $NIB_UI_MAX UI runs. Do not run UI tests again; finish now and answer with the results you have (unverified test-side fixes go in notes)."; exit 3
    fi
    echo "$n" > "$cf"
  fi
fi
LOG="$LOGS/local-$NAME-$MODE${UITAG:+-$UITAG}.log"; EXITF="${LOG%.log}.exit"
rm -f "$EXITF"
: > "$LOG"
say() { echo "$*" | tee -a "$LOG"; }

# ---- acquire a slot (atomic mkdir; stale when the owning pid is gone) --------------------------------------------
SLOT=""
acquire() {
  local pref=""
  [ -f "$LOCKS/affinity-$(basename "$WTREE")" ] && pref="$(cat "$LOCKS/affinity-$(basename "$WTREE")")"
  while :; do
    for s in $pref $(seq 1 "$SLOTS"); do
      local d="$LOCKS/slot$s"
      if mkdir "$d" 2>/dev/null; then echo $$ > "$d/pid"; SLOT=$s; return; fi
      local p; p="$(cat "$d/pid" 2>/dev/null || true)"
      if [ -n "$p" ] && ! kill -0 "$p" 2>/dev/null; then rm -rf "$d"; fi
    done
    sleep 15
  done
}
UILOCK=""
release() { [ -n "$SLOT" ] && rm -rf "$LOCKS/slot$SLOT"; [ -n "$UILOCK" ] && [ "$(cat "$UILOCK/pid" 2>/dev/null)" = "$$" ] && rm -rf "$UILOCK"; }
trap 'release' EXIT INT TERM
if [ "$MODE" = uitest ]; then
  # One UI run machine-wide. Take the UI lock BEFORE a build slot so queued UI runs never hold slots other jobs need.
  say "== waiting for the UI simulator lane"
  UILOCK="$LOCKS/ui"
  until mkdir "$UILOCK" 2>/dev/null; do p=$(cat "$UILOCK/pid" 2>/dev/null); [ -n "$p" ] && ! kill -0 "$p" 2>/dev/null && rm -rf "$UILOCK"; sleep 15; done
  echo $$ > "$UILOCK/pid"
fi
say "== waiting for a build slot ($SLOTS max)"
acquire
echo "$SLOT" > "$LOCKS/affinity-$NAME"
say "== slot $SLOT"
DD="$BASE/Nib-dd/slot$SLOT"; SPM="$BASE/Nib-spm/slot$SLOT"
mkdir -p "$DD" "$SPM"

# ---- disk guard: never start a build with < 6 GB free; trim this slot's DerivedData first ------------------------
freegb() { df -g "$HOME" | awk 'NR==2{print $4}'; }
if [ "$(freegb)" -lt 6 ]; then
  say "== low disk ($(freegb) GB): clearing this slot's DerivedData"
  rm -rf "$DD/Build/Intermediates.noindex/ArchiveIntermediates" "$DD/Logs" "$DD/Index.noindex"
fi
# Bound this slot's footprint: DerivedData accumulates every worktree's intermediates; the cloned simulator keeps test apps.
ddgb=$(du -sg "$DD" 2>/dev/null | awk '{print $1}')
ddcap=2; [ "$NAME" = integration ] && ddcap=9
if [ "${ddgb:-0}" -gt "$ddcap" ]; then say "== slot DerivedData ${ddgb} GB: wiping"; rm -rf "$DD"; mkdir -p "$DD"; fi
simid="$(xcrun simctl list devices -j | python3 -c "import json,sys;d=json.load(sys.stdin)['devices'];print(next((x['udid'] for v in d.values() for x in v if x['name']=='Nib-slot$SLOT'),''))")"
if [ -n "$simid" ]; then
  simgb=$(du -sg "$HOME/Library/Developer/CoreSimulator/Devices/$simid" 2>/dev/null | awk '{print $1}')
  if [ "${simgb:-0}" -gt 2 ]; then say "== slot simulator ${simgb} GB: erasing"; xcrun simctl shutdown "$simid" >/dev/null 2>&1; xcrun simctl erase "$simid" >/dev/null 2>&1; fi
fi
while [ "$(freegb)" -lt 4 ]; do say "== waiting: only $(freegb) GB free"; sleep 60; done

# ---- per-slot simulator (a clone of the device pick_sim.py chooses) ----------------------------------------------
sim() {
  local name="Nib-slot$SLOT" udid
  udid="$(xcrun simctl list devices available -j | python3 -c "import json,sys;d=json.load(sys.stdin)['devices'];print(next((x['udid'] for v in d.values() for x in v if x['name']=='$name'),''))")"
  if [ -z "$udid" ]; then
    local src; src="$(cd "$WTREE" && python3 Scripts/pick_sim.py 2>/dev/null)"
    xcrun simctl shutdown "$src" >/dev/null 2>&1 || true
    udid="$(xcrun simctl clone "$src" "$name")"
  fi
  echo "$udid"
}

scheme_for() { # writes NibKit/.swiftpm/.../NibFeature.xcscheme for test targets "$1" (same as ios.yml)
  python3 - "$1" <<'EOF'
import os, sys
tests = sys.argv[1].split()
ref = ('<BuildableReference BuildableIdentifier = "primary" BlueprintIdentifier = "{0}" BuildableName = "{0}" '
       'BlueprintName = "{0}" ReferencedContainer = "container:"></BuildableReference>')
entries = "".join('<BuildActionEntry buildForTesting = "YES" buildForRunning = "NO" buildForProfiling = "NO" '
                  'buildForArchiving = "NO" buildForAnalyzing = "NO">' + ref.format(t) + "</BuildActionEntry>" for t in tests)
testables = "".join('<TestableReference skipped = "NO">' + ref.format(t) + "</TestableReference>" for t in tests)
d = "NibKit/.swiftpm/xcode/xcshareddata/xcschemes"
os.makedirs(d, exist_ok=True)
open(d + "/NibFeature.xcscheme", "w").write('<?xml version="1.0" encoding="UTF-8"?>\n<Scheme LastUpgradeVersion = "2600" version = "1.7">'
  '<BuildAction parallelizeBuildables = "YES" buildImplicitDependencies = "YES"><BuildActionEntries>' + entries +
  '</BuildActionEntries></BuildAction><TestAction buildConfiguration = "Debug" '
  'selectedDebuggerIdentifier = "Xcode.DebuggerFoundation.Debugger.LLDB" '
  'selectedLauncherIdentifier = "Xcode.DebuggerFoundation.Launcher.LLDB" '
  'shouldUseLaunchSchemeArgsEnv = "YES"><Testables>' + testables + "</Testables></TestAction></Scheme>\n")
EOF
}

feature_info() { # prints "tests|app" for feature $1 from the worktree's spec
  python3 - "$1" <<'EOF'
import json, sys
f = next(x for x in json.load(open("docs/forge-spec.json"))["features"] if x["id"] == sys.argv[1])
tests = sorted({p.split("/")[2] for p in f.get("tests", []) if p.startswith("NibKit/Tests/")})
app = any(p.split("/")[0] in ("Nib", "NibWidgets", "NibShare") for p in f["files"] + f.get("tests", []))
print(" ".join(tests) + "|" + ("1" if app else "0"))
EOF
}

run_tests() { # $1 = test targets ("" = whole NibKit-Package)
  local udid; udid="$(sim)"
  ( cd "$WTREE/NibKit"
    local common="-destination id=$udid -derivedDataPath $DD -clonedSourcePackagesDirPath $SPM -skipPackagePluginValidation"
    if [ -n "$1" ]; then
      (cd "$WTREE" && scheme_for "$1")
      local only=""; for t in $1; do only="$only -only-testing:$t"; done
      xcodebuild build-for-testing -scheme NibFeature $common $only &&
      xcodebuild test-without-building -scheme NibFeature $common $only -parallel-testing-enabled NO
    else
      xcodebuild test -scheme NibKit-Package $common -parallel-testing-enabled NO
    fi ) >> "$LOG" 2>&1
  local rc=$?
  xcrun simctl shutdown "$udid" >/dev/null 2>&1 || true
  return $rc
}

gen_project() {
  ( cd "$WTREE" && { [ -d Nib/Assets.xcassets/AppIcon.appiconset ] && ls Nib/Assets.xcassets/AppIcon.appiconset/*.png >/dev/null 2>&1 || swift Scripts/make_icons.swift; } && xcodegen generate ) >> "$LOG" 2>&1
}
build_app() {
  gen_project && ( cd "$WTREE" && xcodebuild build -project Nib.xcodeproj -scheme Nib -configuration Debug \
    -destination 'generic/platform=iOS' -derivedDataPath "$DD" -clonedSourcePackagesDirPath "$SPM" \
    -skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" ) >> "$LOG" 2>&1
}
archive_app() {
  gen_project && ( cd "$WTREE" && mkdir -p build && rm -rf build/Nib.xcarchive build/Payload &&
    xcodebuild archive -project Nib.xcodeproj -scheme Nib -configuration Release -destination 'generic/platform=iOS' \
      -archivePath build/Nib.xcarchive -derivedDataPath "$DD" -clonedSourcePackagesDirPath "$SPM" \
      -skipPackagePluginValidation CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO CODE_SIGN_IDENTITY="" &&
    mkdir -p build/Payload && cp -R build/Nib.xcarchive/Products/Applications/Nib.app build/Payload/ &&
    for ext in build/Payload/Nib.app/PlugIns/*.appex; do n=$(basename "$ext" .appex); codesign --force --sign - --entitlements "$n/$n.entitlements" "$ext" || true; done &&
    { codesign --force --sign - --entitlements Nib/Nib.entitlements build/Payload/Nib.app || true; } &&
    (cd build && rm -f Nib-unsigned.ipa && zip -qry Nib-unsigned.ipa Payload) ) >> "$LOG" 2>&1
}

ui_tests() { # $1 = optional space-separated -only-testing identifiers (e.g. "NibUITests/PenUITests")
  local name="Nib-ui-ipad" udid
  udid="$(xcrun simctl list devices available -j | python3 -c "import json,sys;d=json.load(sys.stdin)['devices'];print(next((x['udid'] for v in d.values() for x in v if x['name']=='$name'),''))")"
  if [ -z "$udid" ]; then
    local rt; rt="$(xcrun simctl list runtimes -j | python3 -c "import json,sys;r=[x for x in json.load(sys.stdin)['runtimes'] if x['isAvailable'] and x['platform']=='iOS'];print(sorted(r,key=lambda x:x['version'])[-1]['identifier'])")"
    local dt; dt="$(xcrun simctl list devicetypes -j | python3 -c "import json,sys;print(next(x['identifier'] for x in json.load(sys.stdin)['devicetypes'] if x['name'].startswith('iPad Pro 13')))")"
    udid="$(xcrun simctl create "$name" "$dt" "$rt")"
  fi
  local only=""; for t in $1; do only="$only -only-testing:$t"; done
  local RB="$LOGS/ui-$UITAG.xcresult"; rm -rf "$RB" "$LOGS/ui-latest.xcresult"
  echo "== result bundle $RB" >> "$LOG"
  gen_project && ( cd "$WTREE" && xcodebuild test -project Nib.xcodeproj -scheme NibUITests -destination "id=$udid" \
      -derivedDataPath "$DD" -clonedSourcePackagesDirPath "$SPM" -skipPackagePluginValidation $only \
      -resultBundlePath "$RB" CODE_SIGN_IDENTITY=- CODE_SIGNING_REQUIRED=NO ) >> "$LOG" 2>&1
  local rc=$?
  ln -sfn "$RB" "$LOGS/ui-latest.xcresult"
  xcrun simctl shutdown "$udid" >/dev/null 2>&1 || true
  return $rc
}

rc=0
cd "$WTREE"
case "$MODE" in
  feature)
    info="$(feature_info "$ARG")"; tests="${info%|*}"; app="${info#*|}"
    say "== $ARG: lint, tests [$tests], app build $([ "$app" = 1 ] && echo yes || echo no)"
    python3 Scripts/lint.py --feature "$ARG" >> "$LOG" 2>&1 || rc=$?
    [ $rc -eq 0 ] && [ -n "$tests" ] && { run_tests "$tests" || rc=$?; }
    [ $rc -eq 0 ] && [ "$app" = 1 ] && { build_app || rc=$?; } ;;
  targets) say "== targets [$ARG]"; run_tests "$ARG" || rc=$? ;;
  full)
    say "== full: lint + package tests + app"
    gen_project || rc=$?
    [ $rc -eq 0 ] && { python3 Scripts/lint.py >> "$LOG" 2>&1 || rc=$?; }
    [ $rc -eq 0 ] && { run_tests "" || rc=$?; }
    [ $rc -eq 0 ] && { build_app || rc=$?; } ;;
  app) build_app || rc=$? ;;
  archive) archive_app || rc=$? ;;
  uitest) say "== UI tests [${ARG:-all}] (log $LOG, result bundle $LOGS/ui-$UITAG.xcresult)"; ui_tests "$ARG" || rc=$? ;;
  *) echo "unknown mode $MODE"; rc=2 ;;
esac

echo "$rc" > "$EXITF"
if [ $rc -eq 0 ]; then
  echo "LOCAL BUILD OK ($MODE $NAME, slot $SLOT). Log: $LOG"
else
  echo "LOCAL BUILD FAILED rc=$rc ($MODE $NAME). Log: $LOG"
  grep -nE "error:|\*\* BUILD FAILED|\*\* TEST FAILED|failed \(|fatal|Testing failed|XCTAssert|lint:|FAIL|Test Case .* failed" "$LOG" | grep -v '^.*warning:' | head -60
  echo "---- tail"; tail -25 "$LOG"
fi
exit $rc
