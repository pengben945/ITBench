#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage:
  trigger_batch_v6.sh
  trigger_batch_v6.sh --start 2 --end 9

The default batch starts one GPT-5.6 Luna run and one DeepSeek V4 Flash
run for each Scenario-N in the inclusive range. The remote launcher
prepares missing Agent Cases, runs all V6 preflights, preserves existing Pi
sessions, starts the runs detached, verifies that the child processes are
alive, and then exits without tracking completion.

Environment overrides:
  ITBENCH_REMOTE_HOST    Default: root@10.106.3.100
  ITBENCH_REMOTE_ROOT    Default: /data/edison/piagent-itbench-eval
  ITBENCH_SSH_KEY        Default: ~/.ssh/id_ed25519
  ITBENCH_REMOTE_RUNNER  Default: evaluation/scripts/run_scenario_v6.sh
  ITBENCH_BATCH_LABEL    Optional launch-manifest prefix
EOF
  exit 2
}

START_SCENARIO=2
END_SCENARIO=9

while [[ $# -gt 0 ]]; do
  case "$1" in
    --start)
      [[ $# -ge 2 ]] || usage
      START_SCENARIO=$2
      shift 2
      ;;
    --end)
      [[ $# -ge 2 ]] || usage
      END_SCENARIO=$2
      shift 2
      ;;
    -h|--help)
      usage
      ;;
    *)
      usage
      ;;
  esac
done

[[ "$START_SCENARIO" =~ ^[0-9]+$ ]] || usage
[[ "$END_SCENARIO" =~ ^[0-9]+$ ]] || usage
(( START_SCENARIO >= 1 && START_SCENARIO <= END_SCENARIO )) || usage

REMOTE_HOST=${ITBENCH_REMOTE_HOST:-root@10.106.3.100}
REMOTE_ROOT=${ITBENCH_REMOTE_ROOT:-/data/edison/piagent-itbench-eval}
SSH_KEY=${ITBENCH_SSH_KEY:-"$HOME/.ssh/id_ed25519"}
REMOTE_RUNNER=${ITBENCH_REMOTE_RUNNER:-evaluation/scripts/run_scenario_v6.sh}
BATCH_LABEL=${ITBENCH_BATCH_LABEL:-}

[[ "$REMOTE_RUNNER" != /* && "$REMOTE_RUNNER" != *..* ]] || {
  echo "ITBENCH_REMOTE_RUNNER must be a relative path without '..': $REMOTE_RUNNER" >&2
  exit 2
}
[[ -z "$BATCH_LABEL" || "$BATCH_LABEL" =~ ^[a-z0-9-]+$ ]] || {
  echo "ITBENCH_BATCH_LABEL must contain only lowercase letters, digits, and hyphens" >&2
  exit 2
}

ssh -T \
  -i "$SSH_KEY" \
  -o IdentitiesOnly=yes \
  -o ConnectTimeout=15 \
  "$REMOTE_HOST" \
  bash -s -- "$REMOTE_ROOT" "$START_SCENARIO" "$END_SCENARIO" \
  "$REMOTE_RUNNER" "$BATCH_LABEL" <<'REMOTE_LAUNCHER'
set -euo pipefail

REMOTE_ROOT=$1
START_SCENARIO=$2
END_SCENARIO=$3
REMOTE_RUNNER=$4
BATCH_LABEL=$5
RUNNER="$REMOTE_ROOT/$REMOTE_RUNNER"
PREPARER="$REMOTE_ROOT/evaluation/scripts/prepare_scenario_v2.sh"
CASE_ROOT="$REMOTE_ROOT/datasets/agent_cases"
RAW_ROOT="$REMOTE_ROOT/datasets/raw/itbench-aa/sre"
RUN_ROOT="$REMOTE_ROOT/runs"

for command_name in bash bwrap find jq pi python3 rsync sha256sum; do
  command -v "$command_name" >/dev/null || {
    echo "Required remote command not found: $command_name" >&2
    exit 1
  }
done

[[ -x "$RUNNER" ]] || {
  echo "V6 runner not executable: $RUNNER" >&2
  exit 1
}
[[ -x "$PREPARER" ]] || {
  echo "Case preparer not executable: $PREPARER" >&2
  exit 1
}

SCENARIOS=()
for scenario_number in $(seq "$START_SCENARIO" "$END_SCENARIO"); do
  SCENARIOS+=("Scenario-$scenario_number")
done

echo "Checking raw data and preparing Agent Cases..."
for scenario_id in "${SCENARIOS[@]}"; do
  raw_dir="$RAW_ROOT/$scenario_id"
  case_dir="$CASE_ROOT/$scenario_id"
  [[ -d "$raw_dir" ]] || {
    echo "Raw scenario missing: $raw_dir" >&2
    exit 1
  }
  [[ -f "$raw_dir/ground_truth.yaml" ]] || {
    echo "Ground Truth missing from raw scenario: $raw_dir/ground_truth.yaml" >&2
    exit 1
  }
  if [[ ! -d "$case_dir" ]]; then
    "$PREPARER" "$scenario_id"
  fi
done

for scenario_id in "${SCENARIOS[@]}"; do
  case_dir="$CASE_ROOT/$scenario_id"
  [[ -d "$case_dir" ]] || {
    echo "Agent Case missing after preparation: $case_dir" >&2
    exit 1
  }
  if find "$case_dir" -type l -print -quit | grep -q .; then
    echo "Refusing Case containing symbolic links: $case_dir" >&2
    exit 1
  fi
  if find "$case_dir" -type f -iname '*ground*truth*' -print -quit | grep -q .; then
    echo "Ground Truth-like file leaked into Agent Case: $case_dir" >&2
    exit 1
  fi
done

echo "Running V6 preflights for ${#SCENARIOS[@]} cases and 2 models..."
for scenario_id in "${SCENARIOS[@]}"; do
  for model_config in \
    "Maas-gpt|gpt-5.6-luna|high" \
    "deepseek|deepseek-v4-flash|high"; do
    IFS='|' read -r provider model thinking <<<"$model_config"
    echo "  preflight $scenario_id $provider/$model"
    (
      cd "$REMOTE_ROOT"
      PI_EVAL_PROVIDER="$provider" \
      PI_EVAL_MODEL="$model" \
      PI_EVAL_THINKING="$thinking" \
        "$RUNNER" "$scenario_id" run-999 --check-only
    ) >/dev/null
  done
done

next_run_number() {
  local scenario_id=$1
  local highest=0
  local run_dir run_name run_number
  shopt -s nullglob
  for run_dir in "$RUN_ROOT/$scenario_id"/run-[0-9][0-9][0-9]; do
    run_name=$(basename "$run_dir")
    run_number=${run_name#run-}
    if (( 10#$run_number > highest )); then
      highest=$((10#$run_number))
    fi
  done
  shopt -u nullglob
  printf '%03d\n' "$((highest + 1))"
}

LAUNCH_ID="${BATCH_LABEL:+${BATCH_LABEL}-}$(date -u +%Y%m%dT%H%M%SZ)"
LAUNCH_DIR="$RUN_ROOT/batch-launches/$LAUNCH_ID"
mkdir -p "$LAUNCH_DIR"
MANIFEST="$LAUNCH_DIR/manifest.tsv"
{
  printf 'scenario\trun_id\tprovider\tmodel\tthinking\tpid\tlog\n'
} > "$MANIFEST"

declare -a PIDS=()
declare -a LABELS=()

echo "Starting detached V6 runs..."
for scenario_id in "${SCENARIOS[@]}"; do
  run_number=$(next_run_number "$scenario_id")
  for model_config in \
    "Maas-gpt|gpt-5.6-luna|high" \
    "deepseek|deepseek-v4-flash|high"; do
    IFS='|' read -r provider model thinking <<<"$model_config"
    run_id="run-$run_number"
    run_number=$(printf '%03d' "$((10#$run_number + 1))")
    log_file="$LAUNCH_DIR/${scenario_id}-${run_id}.log"
    (
      cd "$REMOTE_ROOT"
      exec env \
        PI_EVAL_PROVIDER="$provider" \
        PI_EVAL_MODEL="$model" \
        PI_EVAL_THINKING="$thinking" \
        "$RUNNER" "$scenario_id" "$run_id"
    ) </dev/null >"$log_file" 2>&1 &
    pid=$!
    PIDS+=("$pid")
    LABELS+=("$scenario_id/$run_id $provider/$model")
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$scenario_id" "$run_id" "$provider" "$model" "$thinking" "$pid" "$log_file" \
      >> "$MANIFEST"
  done
done

sleep 3
failed=0
for index in "${!PIDS[@]}"; do
  pid=${PIDS[$index]}
  if kill -0 "$pid" 2>/dev/null; then
    echo "  started ${LABELS[$index]} (pid=$pid)"
  else
    echo "  failed to remain running: ${LABELS[$index]} (pid=$pid)" >&2
    failed=1
  fi
done

echo "Batch launch manifest: $MANIFEST"
if (( failed != 0 )); then
  echo "At least one detached runner exited during startup; inspect the launch logs." >&2
  exit 1
fi

echo "All ${#PIDS[@]} V6 runner processes were triggered; no runtime tracking will be performed."
REMOTE_LAUNCHER
