#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage:
  PI_EVAL_PROVIDER=... PI_EVAL_MODEL=... PI_EVAL_THINKING=... \
    evaluation/scripts/run_case_comparison_v6.sh Scenario-N

Runs the same Case and model twice: once with Pi's default system prompt
and a neutral task, then with user-provided troubleshooting knowledge.
Both preflights run before either model invocation. Score and register each
completed run separately with evaluation/scripts/register_scored_run.py.
EOF
  exit 2
}

[[ $# -eq 1 ]] || usage
SCENARIO_ID=$1
[[ "$SCENARIO_ID" =~ ^Scenario-[0-9]+$ ]] || usage

: "${PI_EVAL_PROVIDER:?Set PI_EVAL_PROVIDER explicitly}"
: "${PI_EVAL_MODEL:?Set PI_EVAL_MODEL explicitly}"
: "${PI_EVAL_THINKING:?Set PI_EVAL_THINKING explicitly}"

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
PROJECT_ROOT=$(cd -- "$SCRIPT_DIR/../.." && pwd -P)
RUN_ROOT="$PROJECT_ROOT/runs"
LOCK_DIR="$RUN_ROOT/.case-pipeline-$SCENARIO_ID.lock"

mkdir -p "$RUN_ROOT"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  echo "Another Case comparison appears to be running for $SCENARIO_ID: $LOCK_DIR" >&2
  exit 1
fi
trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT

next_run_id() {
  local scenario_id=$1
  local highest=0
  local run_dir run_name run_number
  shopt -s nullglob
  for run_dir in "$RUN_ROOT/$scenario_id"/run-[0-9][0-9][0-9]; do
    [[ -d "$run_dir" ]] || continue
    run_name=$(basename "$run_dir")
    run_number=${run_name#run-}
    if (( 10#$run_number > highest )); then
      highest=$((10#$run_number))
    fi
  done
  shopt -u nullglob
  if (( highest >= 999 )); then
    echo "No three-digit run IDs remain for $scenario_id" >&2
    return 1
  fi
  printf 'run-%03d\n' "$((highest + 1))"
}

NATIVE_RUNNER="$SCRIPT_DIR/run_scenario_v6_pi_native.sh"
KNOWLEDGE_RUNNER="$SCRIPT_DIR/run_scenario_v6_user_knowledge.sh"
for runner in "$NATIVE_RUNNER" "$KNOWLEDGE_RUNNER"; do
  [[ -x "$runner" ]] || {
    echo "Comparison runner is missing or not executable: $runner" >&2
    exit 1
  }
done

echo "Checking both V6 variants for $SCENARIO_ID ($PI_EVAL_PROVIDER/$PI_EVAL_MODEL)..."
for runner in "$NATIVE_RUNNER" "$KNOWLEDGE_RUNNER"; do
  (
    cd "$PROJECT_ROOT"
    PI_EVAL_PROVIDER="$PI_EVAL_PROVIDER" \
    PI_EVAL_MODEL="$PI_EVAL_MODEL" \
    PI_EVAL_THINKING="$PI_EVAL_THINKING" \
      "$runner" "$SCENARIO_ID" run-999 --check-only
  )
done

NATIVE_RUN_ID=$(next_run_id "$SCENARIO_ID")
(
  cd "$PROJECT_ROOT"
  PI_EVAL_PROVIDER="$PI_EVAL_PROVIDER" \
  PI_EVAL_MODEL="$PI_EVAL_MODEL" \
  PI_EVAL_THINKING="$PI_EVAL_THINKING" \
    "$NATIVE_RUNNER" "$SCENARIO_ID" "$NATIVE_RUN_ID"
)

KNOWLEDGE_RUN_ID=$(next_run_id "$SCENARIO_ID")
(
  cd "$PROJECT_ROOT"
  PI_EVAL_PROVIDER="$PI_EVAL_PROVIDER" \
  PI_EVAL_MODEL="$PI_EVAL_MODEL" \
  PI_EVAL_THINKING="$PI_EVAL_THINKING" \
    "$KNOWLEDGE_RUNNER" "$SCENARIO_ID" "$KNOWLEDGE_RUN_ID"
)

printf '\nBoth runs completed. Score each run independently, then register it:\n'
printf '  %s\n' "$RUN_ROOT/$SCENARIO_ID/$NATIVE_RUN_ID"
printf '  %s\n' "$RUN_ROOT/$SCENARIO_ID/$KNOWLEDGE_RUN_ID"
