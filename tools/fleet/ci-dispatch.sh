#!/usr/bin/env bash
# Dispatch a workflow run and wait for it, retrying when GitHub never acquires a macOS runner for it.
#   tools/fleet/ci-dispatch.sh <workflow.yml> <ref> [-f key=value ...]
# When macOS arm64 capacity is constrained, GitHub leaves the jobs unacquired for ~20 min and then ends the run with
# every job "cancelled" and no steps run ("The job was not acquired by Runner of type hosted"). That is not a result:
# this script sleeps CI_RETRY_SLEEP seconds (default 600) and dispatches again, up to CI_RETRIES times (default 8).
# Prints "RUN <id> <conclusion>" for a real result and exits 0 on success, 1 on a real failure, 2 when retries ran out.
set -uo pipefail
WF="$1"; REF="$2"; shift 2
REPO="${CI_REPO:-GOODMAN-PRO/nib}"
RETRIES="${CI_RETRIES:-8}"; SLEEP="${CI_RETRY_SLEEP:-600}"
for attempt in $(seq 1 "$RETRIES"); do
  before=$(gh run list --repo "$REPO" --workflow "$WF" --branch "$REF" --limit 1 --json databaseId --jq '.[0].databaseId // 0')
  gh workflow run "$WF" --repo "$REPO" --ref "$REF" "$@" >/dev/null || { echo "DISPATCH_FAILED $WF $REF"; exit 1; }
  run=""
  for i in $(seq 1 30); do
    sleep 10
    run=$(gh run list --repo "$REPO" --workflow "$WF" --branch "$REF" --limit 3 --json databaseId,createdAt --jq 'sort_by(.createdAt) | last | .databaseId')
    [ -n "$run" ] && [ "$run" != "$before" ] && break
    run=""
  done
  [ -n "$run" ] || { echo "RUN_NOT_FOUND $WF $REF (attempt $attempt)"; exit 1; }
  echo "attempt $attempt: run $run (https://github.com/$REPO/actions/runs/$run)"
  gh run watch "$run" --repo "$REPO" --interval 120 >/dev/null 2>&1 || true
  while [ "$(gh run view "$run" --repo "$REPO" --json status --jq .status)" != "completed" ]; do sleep 30; done
  conclusion=$(gh run view "$run" --repo "$REPO" --json conclusion --jq .conclusion)
  if [ "$conclusion" = "success" ]; then echo "RUN $run success"; exit 0; fi
  # Unacquired: ignoring the planning job and skipped jobs, every job either succeeded or was cancelled without having run a
  # single step, and at least one was cancelled (GitHub sometimes acquires a runner for one job of a run and not another).
  unacquired=$(gh api "repos/$REPO/actions/runs/$run/jobs" --jq '[.jobs[] | select(.name != "plan" and .conclusion != "skipped")] | if length == 0 then false else (any(.conclusion == "cancelled") and all(.conclusion == "success" or (.conclusion == "cancelled" and ((.steps // []) | map(select(.status == "completed" and .conclusion != "skipped")) | length == 0)))) end')
  if [ "$unacquired" = "true" ]; then
    echo "attempt $attempt: run $run never acquired a runner (macOS capacity); retrying in $SLEEP s"
    sleep "$SLEEP"; continue
  fi
  echo "RUN $run $conclusion"; exit 1
done
echo "GAVE_UP after $RETRIES attempts"; exit 2
