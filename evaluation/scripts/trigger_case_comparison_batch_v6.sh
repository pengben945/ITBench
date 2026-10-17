#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  evaluation/scripts/trigger_case_comparison_batch_v6.sh [--count 20..30] [--dry-run]

Runs each selected Case with both Castrel models. For each model/Case pair,
the Pi-Agent native and user-knowledge cohorts run sequentially. The script
stays attached until all comparisons finish.

Options:
  --count N   Number of prepared Cases to select, from 20 through 30 (default: 20)
  --dry-run   Validate the remote workspace and print the selected run plan
  -h, --help  Show this help

Environment overrides:
  ITBENCH_REMOTE_HOST  Default: root@10.106.3.100
  ITBENCH_REMOTE_ROOT  Default: /data/edison/piagent-itbench-eval
  ITBENCH_SSH_KEY     Default: ~/.ssh/id_ed25519
EOF
}

COUNT=20
DRY_RUN=0
while [[ $# -gt 0 ]]; do
  case "$1" in
    --count)
      [[ $# -ge 2 ]] || { usage >&2; exit 2; }
      COUNT=$2
      shift 2
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      usage >&2
      exit 2
      ;;
  esac
done

[[ "$COUNT" =~ ^[0-9]+$ ]] || { usage >&2; exit 2; }
COUNT=$((10#$COUNT))
(( COUNT >= 20 && COUNT <= 30 )) || {
  echo "--count must be between 20 and 30" >&2
  exit 2
}

REMOTE_HOST=${ITBENCH_REMOTE_HOST:-root@10.106.3.100}
REMOTE_ROOT=${ITBENCH_REMOTE_ROOT:-/data/edison/piagent-itbench-eval}
SSH_KEY=${ITBENCH_SSH_KEY:-"$HOME/.ssh/id_ed25519"}

[[ "$REMOTE_HOST" =~ ^[A-Za-z0-9._-]+@[A-Za-z0-9.-]+$ ]] || {
  echo "Invalid ITBENCH_REMOTE_HOST" >&2
  exit 2
}
[[ "$REMOTE_ROOT" =~ ^/[A-Za-z0-9_./-]+$ && "$REMOTE_ROOT" != *..* ]] || {
  echo "ITBENCH_REMOTE_ROOT must be an absolute path without '..'" >&2
  exit 2
}
[[ -f "$SSH_KEY" ]] || {
  echo "SSH identity file not found: $SSH_KEY" >&2
  exit 1
}

ssh -T \
  -i "$SSH_KEY" \
  -o IdentitiesOnly=yes \
  -o ConnectTimeout=15 \
  -o ServerAliveInterval=30 \
  -o ServerAliveCountMax=10 \
  "$REMOTE_HOST" \
  bash -s -- "$REMOTE_ROOT" "$COUNT" "$DRY_RUN" <<'REMOTE_BATCH'
set -euo pipefail

REMOTE_ROOT=$1
COUNT=$2
DRY_RUN=$3

echo "=== Remote workspace preflight ==="
hostname
df -h /data
du -sh "$REMOTE_ROOT" 2>/dev/null || true
find "$REMOTE_ROOT" -mindepth 1 -maxdepth 1 -printf '%f\n' | sort

[[ -d "$REMOTE_ROOT" ]] || {
  echo "Remote workspace not found: $REMOTE_ROOT" >&2
  exit 1
}

CODE_ROOT="$REMOTE_ROOT/ITBench"
[[ -e "$CODE_ROOT/.git" ]] || {
  echo "Git repository metadata not found: $CODE_ROOT" >&2
  exit 1
}
if ! git -C "$CODE_ROOT" config --get remote.origin.url |
  grep -Eq 'github\.com[:/]pengben945/ITBench\.git$'; then
  echo "The code repository origin is missing or does not match pengben945/ITBench" >&2
  exit 1
fi

CODE_BRANCH=$(git -C "$CODE_ROOT" rev-parse --abbrev-ref HEAD)
CODE_COMMIT=$(git -C "$CODE_ROOT" rev-parse HEAD)
printf 'code_repository=%s\ncode_branch=%s\ncode_commit=%s\n' \
  "$CODE_ROOT" "$CODE_BRANCH" "$CODE_COMMIT"
git -C "$CODE_ROOT" status --short

REQUIRED_FILES=(
  evaluation/scripts/run_case_comparison_v6.sh
  evaluation/scripts/run_scenario_v6_pi_native.sh
  evaluation/scripts/run_scenario_v6_user_knowledge.sh
  evaluation/scripts/run_scenario_v3.sh
  evaluation/prompts/sre_diagnosis_v6_pi_native.md
  evaluation/prompts/sre_diagnosis_v6_user_knowledge.md
  evaluation/schemas/diagnosis-v3.schema.json
)
if ! git -C "$CODE_ROOT" diff --quiet HEAD -- "${REQUIRED_FILES[@]}"; then
  echo "Relevant evaluation sources have uncommitted changes; refusing to run." >&2
  exit 1
fi
for relative_path in "${REQUIRED_FILES[@]}"; do
  if [[ ! -f "$REMOTE_ROOT/$relative_path" ]] ||
    ! cmp -s "$CODE_ROOT/$relative_path" "$REMOTE_ROOT/$relative_path"; then
    echo "Runtime copy does not match the Git checkout: $relative_path" >&2
    exit 1
  fi
done

for command_name in bwrap cmp find git grep jq pi python3 sha256sum sort tee; do
  command -v "$command_name" >/dev/null || {
    echo "Required remote command not found: $command_name" >&2
    exit 1
  }
done

COMPARISON_RUNNER="$REMOTE_ROOT/evaluation/scripts/run_case_comparison_v6.sh"
[[ -x "$COMPARISON_RUNNER" ]] || {
  echo "V6 comparison runner is missing or not executable: $COMPARISON_RUNNER" >&2
  exit 1
}
echo "Pi runtime:"
pi --version

CASE_ROOT="$REMOTE_ROOT/datasets/agent_cases"
MANIFEST_ROOT="$REMOTE_ROOT/datasets/manifests"
[[ -d "$CASE_ROOT" && -d "$MANIFEST_ROOT" ]] || {
  echo "Agent Case directory or SHA-256 manifest directory is missing." >&2
  exit 1
}
[[ ! -L "$CASE_ROOT" && ! -L "$MANIFEST_ROOT" ]] || {
  echo "Refusing symlinked Agent Case or manifest root." >&2
  exit 1
}

mapfile -t CANDIDATE_CASES < <(
  find "$CASE_ROOT" -mindepth 1 -maxdepth 1 -type d \
    -regextype posix-extended \
    -regex '.*/Scenario-[0-9]+' -printf '%f\n' |
    sort -V
)

SELECTED_CASES=()
for scenario_id in "${CANDIDATE_CASES[@]}"; do
  manifest_file="$MANIFEST_ROOT/$scenario_id.sha256"
  if [[ ! -s "$manifest_file" ]]; then
    echo "Skipping $scenario_id: SHA-256 manifest is missing."
    continue
  fi
  if [[ -L "$manifest_file" ]]; then
    echo "Refusing symlinked manifest: $manifest_file" >&2
    exit 1
  fi
  SELECTED_CASES+=("$scenario_id")
  if (( ${#SELECTED_CASES[@]} == COUNT )); then
    break
  fi
done

if (( ${#SELECTED_CASES[@]} < COUNT )); then
  echo "Found only ${#SELECTED_CASES[@]} prepared Cases with manifests; $COUNT required." >&2
  exit 1
fi

for scenario_id in "${SELECTED_CASES[@]}"; do
  case_dir="$CASE_ROOT/$scenario_id"
  if [[ -L "$case_dir" ]] || [[ ! -f "$case_dir/k8s_objects_raw.tsv" ]]; then
    echo "Invalid or incomplete Agent Case: $case_dir" >&2
    exit 1
  fi
  if find "$case_dir" -type l -print -quit | grep -q .; then
    echo "Refusing Agent Case containing symbolic links: $case_dir" >&2
    exit 1
  fi
  if find "$case_dir" -type f -iname '*ground*truth*' -print -quit | grep -q .; then
    echo "Ground Truth-like file found in Agent-visible Case: $case_dir" >&2
    exit 1
  fi
done

# Existing run metadata uses each Castrel model ID as its provider and thinking=high.
MODEL_CONFIGS=(
  "castrel-qwen38-27b-base|castrel-qwen38-27b-base|high"
  "castrel-qwen38-27b-v003-1-lora-v001|castrel-qwen38-27b-v003-1-lora-v001|high"
)
DATA_REVISION=76df38a82288f75ba9e41dc8c515033332497473
RUN_ROOT="$REMOTE_ROOT/runs"
[[ ! -L "$RUN_ROOT" ]] || {
  echo "Refusing symlinked run root: $RUN_ROOT" >&2
  exit 1
}

RUN_SLOTS_PER_CASE=$((${#MODEL_CONFIGS[@]} * 2))
shopt -s nullglob
for scenario_id in "${SELECTED_CASES[@]}"; do
  highest_run_number=0
  for run_dir in "$RUN_ROOT/$scenario_id"/run-[0-9][0-9][0-9]; do
    [[ -d "$run_dir" ]] || continue
    run_number=${run_dir##*/run-}
    if (( 10#$run_number > highest_run_number )); then
      highest_run_number=$((10#$run_number))
    fi
  done
  if (( highest_run_number + RUN_SLOTS_PER_CASE > 999 )); then
    echo "Insufficient three-digit run IDs for $scenario_id (highest: $highest_run_number)." >&2
    exit 1
  fi
  for ((offset = 1; offset <= RUN_SLOTS_PER_CASE; offset++)); do
    next_run_id=$(printf 'run-%03d' "$((highest_run_number + offset))")
    if [[ -e "$RUN_ROOT/$scenario_id/$next_run_id" ]]; then
      echo "Next run ID already exists for $scenario_id: $next_run_id" >&2
      exit 1
    fi
  done
done
shopt -u nullglob

print_plan() {
  echo "Selected $COUNT prepared Cases (numeric order):"
  printf '  %s\n' "${SELECTED_CASES[@]}"
  echo "Models: castrel-qwen38-27b-base, castrel-qwen38-27b-v003-1-lora-v001"
  echo "Cohorts: v6-pi-native, v6-user-knowledge"
  echo "Provider: each model's configured Castrel provider; thinking: high"
  echo "Dataset revision: $DATA_REVISION"
  echo "Concurrency: 1; planned model runs: $((COUNT * 2 * 2))"
}

if [[ "$DRY_RUN" == 1 ]]; then
  print_plan
  echo "Dry run only: no batch artifacts or model calls were created."
  exit 0
fi

umask 077
mkdir -p "$RUN_ROOT/batch-launches"
LOCK_DIR="$RUN_ROOT/.case-comparison-batch-v6.lock"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  echo "Another V6 comparison batch appears to be running: $LOCK_DIR" >&2
  exit 1
fi
trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT

BATCH_ID="castrel-v6-$(date -u +%Y%m%dT%H%M%SZ)"
BATCH_DIR="$RUN_ROOT/batch-launches/$BATCH_ID"
mkdir "$BATCH_DIR"
PROGRESS_LOG="$BATCH_DIR/progress.log"
exec > >(tee -a "$PROGRESS_LOG") 2>&1
print_plan
echo "Batch artifacts: $BATCH_DIR"
echo "Progress log: $PROGRESS_LOG"

PLAN_FILE="$BATCH_DIR/plan.tsv"
RESULTS_FILE="$BATCH_DIR/results.tsv"
printf 'scenario\tmodel\tprovider\tthinking\tdata_revision\tcohorts\n' > "$PLAN_FILE"
printf 'scenario\tmodel\tprovider\tthinking\tdata_revision\tstatus\texit_code\tstarted_at\tfinished_at\n' \
  > "$RESULTS_FILE"
PI_VERSION=$(pi --version)
{
  printf 'batch_id=%s\n' "$BATCH_ID"
  printf 'code_repository=%s\ncode_branch=%s\ncode_commit=%s\n' \
    "$CODE_ROOT" "$CODE_BRANCH" "$CODE_COMMIT"
  printf 'pi_version=%s\ndata_revision=%s\ncase_count=%s\nconcurrency=1\n' \
    "$PI_VERSION" "$DATA_REVISION" "$COUNT"
  printf 'cohorts=v6-pi-native,v6-user-knowledge\n'
} > "$BATCH_DIR/metadata.txt"
for scenario_id in "${SELECTED_CASES[@]}"; do
  for model_config in "${MODEL_CONFIGS[@]}"; do
    IFS='|' read -r model provider thinking <<< "$model_config"
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$scenario_id" "$model" "$provider" "$thinking" "$DATA_REVISION" \
      'v6-pi-native,v6-user-knowledge' >> "$PLAN_FILE"
  done
done

comparison_count=0
failure_count=0
for scenario_id in "${SELECTED_CASES[@]}"; do
  for model_config in "${MODEL_CONFIGS[@]}"; do
    IFS='|' read -r model provider thinking <<< "$model_config"
    started_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    log_file="$BATCH_DIR/${scenario_id}-${model}.log"
    echo "=== $scenario_id | $provider/$model | $thinking ==="

    set +e
    (
      cd "$REMOTE_ROOT"
      env \
        PI_EVAL_PROVIDER="$provider" \
        PI_EVAL_MODEL="$model" \
        PI_EVAL_THINKING="$thinking" \
        PI_EVAL_DATA_REVISION="$DATA_REVISION" \
        "$COMPARISON_RUNNER" "$scenario_id"
    ) 2>&1 | tee "$log_file"
    pipeline_status=("${PIPESTATUS[@]}")
    set -e

    runner_status=${pipeline_status[0]:-1}
    tee_status=${pipeline_status[1]:-1}
    result_code=$runner_status
    status=completed
    if (( runner_status != 0 || tee_status != 0 )); then
      status=failed
      failure_count=$((failure_count + 1))
      if (( result_code == 0 )); then
        result_code=$tee_status
      fi
    fi
    finished_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$scenario_id" "$model" "$provider" "$thinking" "$DATA_REVISION" \
      "$status" "$result_code" "$started_at" "$finished_at" >> "$RESULTS_FILE"
    comparison_count=$((comparison_count + 1))
    echo "Pair $status: $scenario_id $model (exit=$result_code)"
  done
done

echo "Batch finished: $comparison_count/$((COUNT * 2)) model/Case comparisons; failures=$failure_count."
echo "Results: $RESULTS_FILE"
if (( failure_count > 0 )); then
  exit 1
fi
REMOTE_BATCH
