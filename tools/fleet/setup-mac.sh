#!/usr/bin/env bash
# One-time Mac setup to continue the Nib fleet build. Run from the repo root: bash tools/fleet/setup-mac.sh
# Creates ~/Projects/Nib-wt/<FeatureID> worktrees (from origin/feat/<id> when it exists, else from main),
# copies the review/fix state markers, and checks the toolchain.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
PARENT="$(dirname "$ROOT")"
WT="${NIB_WT:-$PARENT/Nib-wt}"
STATE="${NIB_STATE:-$PARENT/Nib-state}"
mkdir -p "$WT" "$STATE" "${NIB_LOGS:-$PARENT/Nib-ci-logs}"

echo "== toolchain"
for t in git gh node xcodegen xcodebuild python3; do
  if command -v "$t" >/dev/null 2>&1; then echo "  ok  $t"; else echo "  MISSING  $t"; fi
done
xcodebuild -version 2>/dev/null | head -1 || true
echo "  (need Xcode 26.x for the iOS 26 SDK / Liquid Glass; brew install xcodegen gh node if missing; gh auth login)"

echo "== fetch"
git -C "$ROOT" fetch origin --prune --quiet
git -C "$ROOT" checkout -q main && git -C "$ROOT" pull -q --ff-only origin main

echo "== worktrees"
IDS=$(node -e "console.log(require('$ROOT/docs/forge-spec.json').features.map(f=>f.id).join(' '))")
for id in $IDS; do
  [ -d "$WT/$id" ] && continue
  if git -C "$ROOT" show-ref --verify --quiet "refs/remotes/origin/feat/$id"; then
    git -C "$ROOT" worktree add -q "$WT/$id" -B "feat/$id" "origin/feat/$id"
  else
    git -C "$ROOT" worktree add -q "$WT/$id" -B "feat/$id" main
  fi
  git -C "$WT/$id" branch -q --set-upstream-to="origin/feat/$id" 2>/dev/null || true
  echo ".dd/" >> "$(git -C "$WT/$id" rev-parse --git-dir)/info/exclude" 2>/dev/null || true
done
echo "  $(git -C "$ROOT" worktree list | wc -l | tr -d ' ') worktrees"

echo "== state markers"
cp -n "$ROOT"/tools/fleet/state/*.json "$STATE"/ 2>/dev/null || true
echo "  $(ls "$STATE" | wc -l | tr -d ' ') markers in $STATE"

echo "== launch args"
NIB_ROOT="$ROOT" NIB_WT="$WT" NIB_STATE="$STATE" NIB_LOCAL_BUILD="${NIB_LOCAL_BUILD:-1}" NIB_MAX_IMPL="${NIB_MAX_IMPL:-3}" \
  node "$ROOT/tools/fleet/collect-state.js"
echo "Done. Next: in Claude Code at $ROOT say: Read tools/fleet/HANDOFF.md and continue the build."
