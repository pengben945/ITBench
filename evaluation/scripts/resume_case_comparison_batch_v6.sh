#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  evaluation/scripts/resume_case_comparison_batch_v6.sh [--dry-run] BATCH_ID

Resume a stopped Castrel V6 batch from its original plan. Fully completed
cohorts are preserved and skipped; incomplete cohorts are rerun with fresh
run IDs. Run directly on the evaluation server.

Options:
  --dry-run  Show completed and missing cohorts without running models
  -h, --help Show this help

Before resuming, verify no batch is running. If stale lock directories remain,
remove only those empty lock directories with rmdir.
EOF
}

DRY_RUN=0
BATCH_ID=
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      usage >&2
      exit 2
      ;;
    *)
      [[ -z "$BATCH_ID" ]] || { usage >&2; exit 2; }
      BATCH_ID=$1
      shift
      ;;
  esac
done

[[ "$BATCH_ID" =~ ^castrel-v6-[0-9]{8}T[0-9]{6}Z$ ]] || {
  usage >&2
  exit 2
}

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
CODE_ROOT=$(cd -- "$SCRIPT_DIR/../.." && pwd -P)
REMOTE_ROOT=${ITBENCH_REMOTE_ROOT:-/data/edison/piagent-itbench-eval}
RUN_ROOT="$REMOTE_ROOT/runs"
BATCH_DIR="$RUN_ROOT/batch-launches/$BATCH_ID"
PLAN_FILE="$BATCH_DIR/plan.tsv"
RESULTS_FILE="$BATCH_DIR/results.tsv"
PROGRESS_LOG="$BATCH_DIR/progress.log"
CASE_ROOT="$REMOTE_ROOT/datasets/agent_cases"
MANIFEST_ROOT="$REMOTE_ROOT/datasets/manifests"
DATA_REVISION=76df38a82288f75ba9e41dc8c515033332497473

[[ "$REMOTE_ROOT" =~ ^/[A-Za-z0-9_./-]+$ && "$REMOTE_ROOT" != *..* ]] || {
  echo "ITBENCH_REMOTE_ROOT must be an absolute path without '..'" >&2
  exit 2
}
[[ "$CODE_ROOT" == "$REMOTE_ROOT/ITBench" ]] || {
  echo "Run this script from the server checkout at $REMOTE_ROOT/ITBench" >&2
  exit 1
}
[[ -d "$REMOTE_ROOT" && -d "$CODE_ROOT/.git" ]] || {
  echo "Remote evaluation workspace or Git checkout is missing." >&2
  exit 1
}
[[ -d "$BATCH_DIR" && -f "$PLAN_FILE" && -s "$PROGRESS_LOG" ]] || {
  echo "Batch plan or progress log not found for $BATCH_ID: $BATCH_DIR" >&2
  exit 1
}
[[ ! -L "$RUN_ROOT" && ! -L "$BATCH_DIR" && ! -L "$PLAN_FILE" ]] || {
  echo "Refusing symlinked run, batch, or plan path." >&2
  exit 1
}

for command_name in awk bwrap cmp date find git grep head jq pi python3 sha256sum sort tail tee; do
  command -v "$command_name" >/dev/null || {
    echo "Required command not found: $command_name" >&2
    exit 1
  }
done

if ! git -C "$CODE_ROOT" config --get remote.origin.url |
  grep -Eq 'github\.com[:/]pengben945/ITBench\.git$'; then
  echo "The code repository origin is missing or does not match pengben945/ITBench" >&2
  exit 1
fi
if [[ -n "$(git -C "$CODE_ROOT" status --porcelain)" ]]; then
  echo "The remote Git checkout is dirty; refusing to resume." >&2
  exit 1
fi

CODE_COMMIT=$(git -C "$CODE_ROOT" rev-parse HEAD)
REQUIRED_FILES=(
  evaluation/scripts/run_case_comparison_v6.sh
  evaluation/scripts/run_scenario_v6_pi_native.sh
  evaluation/scripts/run_scenario_v6_user_knowledge.sh
  evaluation/scripts/run_scenario_v3.sh
  evaluation/prompts/sre_diagnosis_v6_pi_native.md
  evaluation/prompts/sre_diagnosis_v6_user_knowledge.md
  evaluation/schemas/diagnosis-v3.schema.json
)
for relative_path in "${REQUIRED_FILES[@]}"; do
  if [[ ! -f "$REMOTE_ROOT/$relative_path" ]] ||
    ! cmp -s "$CODE_ROOT/$relative_path" "$REMOTE_ROOT/$relative_path"; then
    echo "Runtime copy does not match the Git checkout: $relative_path" >&2
    exit 1
  fi
done

COMPARISON_RUNNER="$REMOTE_ROOT/evaluation/scripts/run_case_comparison_v6.sh"
NATIVE_RUNNER="$REMOTE_ROOT/evaluation/scripts/run_scenario_v6_pi_native.sh"
KNOWLEDGE_RUNNER="$REMOTE_ROOT/evaluation/scripts/run_scenario_v6_user_knowledge.sh"
for runner in "$COMPARISON_RUNNER" "$NATIVE_RUNNER" "$KNOWLEDGE_RUNNER"; do
  [[ -x "$runner" ]] || {
    echo "Required V6 runner is missing or not executable: $runner" >&2
    exit 1
  }
done

MODEL_CONFIGS=(
  "castrel-qwen38-27b-base|castrel-qwen38-27b-base|high"
  "castrel-qwen38-27b-v003-1-lora-v001|castrel-qwen38-27b-v003-1-lora-v001|high"
)

[[ -d "$CASE_ROOT" && -d "$MANIFEST_ROOT" ]] || {
  echo "Agent Case directory or manifest directory is missing." >&2
  exit 1
}
[[ ! -L "$CASE_ROOT" && ! -L "$MANIFEST_ROOT" ]] || {
  echo "Refusing symlinked Agent Case or manifest root." >&2
  exit 1
}
[[ "$(head -n 1 "$PLAN_FILE")" == $'scenario\tmodel\tprovider\tthinking\tdata_revision\tcohorts' ]] || {
  echo "Unexpected batch plan header: $PLAN_FILE" >&2
  exit 1
}

declare -a SELECTED_CASES=()
declare -A CASE_SEEN=()
declare -A PAIR_SEEN=()
while IFS=$'\t' read -r scenario_id model provider thinking _revision cohorts extra; do
  [[ -n "$scenario_id" ]] || continue
  [[ "$scenario_id" =~ ^Scenario-[0-9]+$ ]] || {
    echo "Invalid Case ID in batch plan: $scenario_id" >&2
    exit 1
  }
  [[ -z "${extra:-}" ]] || {
    echo "Unexpected extra field in batch plan row for $scenario_id." >&2
    exit 1
  }
  [[ "$thinking" == high && "$cohorts" == 'v6-pi-native,v6-user-knowledge' ]] || {
    echo "Unexpected thinking level or cohort list in batch plan for $scenario_id." >&2
    exit 1
  }
  [[ "$_revision" == "$DATA_REVISION" ]] || {
    echo "Batch plan dataset revision does not match the frozen revision." >&2
    exit 1
  }

  model_found=0
  for model_config in "${MODEL_CONFIGS[@]}"; do
    IFS='|' read -r expected_model expected_provider expected_thinking <<< "$model_config"
    if [[ "$model" == "$expected_model" ]]; then
      model_found=1
      [[ "$provider" == "$expected_provider" && "$thinking" == "$expected_thinking" ]] || {
        echo "Unexpected provider or thinking level for $model in batch plan." >&2
        exit 1
      }
      break
    fi
  done
  (( model_found == 1 )) || {
    echo "Unexpected model in batch plan: $model" >&2
    exit 1
  }

  pair_key="$scenario_id|$model"
  [[ -z "${PAIR_SEEN[$pair_key]:-}" ]] || {
    echo "Duplicate Case/model row in batch plan: $pair_key" >&2
    exit 1
  }
  PAIR_SEEN[$pair_key]=1
  if [[ -z "${CASE_SEEN[$scenario_id]:-}" ]]; then
    CASE_SEEN[$scenario_id]=1
    SELECTED_CASES+=("$scenario_id")
  fi
done < <(tail -n +2 "$PLAN_FILE")

COUNT=${#SELECTED_CASES[@]}
(( COUNT >= 20 && COUNT <= 30 )) || {
  echo "Batch plan must contain 20–30 unique Cases; found $COUNT." >&2
  exit 1
}
(( ${#PAIR_SEEN[@]} == COUNT * ${#MODEL_CONFIGS[@]} )) || {
  echo "Batch plan must contain exactly one row per Case/model pair." >&2
  exit 1
}
for scenario_id in "${SELECTED_CASES[@]}"; do
  for model_config in "${MODEL_CONFIGS[@]}"; do
    IFS='|' read -r model _provider _thinking <<< "$model_config"
    pair_key="$scenario_id|$model"
    [[ -n "${PAIR_SEEN[$pair_key]:-}" ]] || {
      echo "Batch plan is missing $scenario_id/$model." >&2
      exit 1
    }
  done

  case_dir="$CASE_ROOT/$scenario_id"
  manifest_file="$MANIFEST_ROOT/$scenario_id.sha256"
  [[ ! -L "$case_dir" && -d "$case_dir" ]] || {
    echo "Invalid or symlinked Agent Case: $case_dir" >&2
    exit 1
  }
  [[ ! -L "$manifest_file" && -s "$manifest_file" ]] || {
    echo "Missing, empty, or symlinked Case manifest: $manifest_file" >&2
    exit 1
  }
  [[ -f "$case_dir/k8s_objects_raw.tsv" ]] || {
    echo "Incomplete Agent Case: $case_dir" >&2
    exit 1
  }
  if find "$case_dir" -type l -print -quit | grep -q .; then
    echo "Refusing Agent Case containing symbolic links: $case_dir" >&2
    exit 1
  fi
  if find "$case_dir" -type f -iname '*ground*truth*' -print -quit | grep -q .; then
    echo "Ground Truth-like file found in Agent-visible Case: $case_dir" >&2
    exit 1
  fi
done

BATCH_EPOCH=$(python3 - "$BATCH_ID" <<'PY'
from datetime import datetime, timezone
import re
import sys

match = re.fullmatch(r"castrel-v6-(\d{8}T\d{6}Z)", sys.argv[1])
if not match:
    raise SystemExit("Invalid batch timestamp")
timestamp = datetime.strptime(match.group(1), "%Y%m%dT%H%M%SZ")
print(int(timestamp.replace(tzinfo=timezone.utc).timestamp()))
PY
)

completed_run_id() {
  local scenario_id=$1
  local model=$2
  local provider=$3
  local cohort=$4
  local run_log=${5:-$PROGRESS_LOG}
  python3 - "$RUN_ROOT/$scenario_id" "$model" "$provider" "$cohort" \
    "$DATA_REVISION" "$BATCH_EPOCH" "$run_log" "$scenario_id" <<'PY'
from datetime import datetime, timezone
import json
from pathlib import Path
import re
import sys

run_root = Path(sys.argv[1])
model, provider, cohort = sys.argv[2:5]
revision = sys.argv[5]
batch_epoch = int(sys.argv[6])
progress_log = Path(sys.argv[7])
scenario_id = sys.argv[8]
prompt_version = {
    "v6-pi-native": "6.1-pi-native",
    "v6-user-knowledge": "6.1-user-knowledge",
}[cohort]
matches = []
progress_lines = set(progress_log.read_text(encoding="utf-8").splitlines())

if run_root.is_dir() and not run_root.is_symlink():
    for run_dir in sorted(run_root.glob("run-[0-9][0-9][0-9]")):
        if run_dir.is_symlink() or not run_dir.is_dir():
            continue
        if not re.fullmatch(r"run-\d{3}", run_dir.name):
            continue
        started_marker = (
            f"Current run: case={scenario_id} cohort={cohort} "
            f"model={provider}/{model} session_name={scenario_id}-{run_dir.name}"
        )
        if started_marker not in progress_lines:
            continue
        try:
            config = json.loads((run_dir / "model_config.json").read_text(encoding="utf-8"))
            started_text = (run_dir / "started_at.txt").read_text(encoding="utf-8").strip()
            finished_text = (run_dir / "finished_at.txt").read_text(encoding="utf-8").strip()
            started = datetime.fromisoformat(started_text.replace("Z", "+00:00"))
            finished = datetime.fromisoformat(finished_text.replace("Z", "+00:00"))
            exit_code = (run_dir / "exit_code.txt").read_text(encoding="utf-8").strip()
            session_id = (run_dir / "session_id.txt").read_text(encoding="utf-8").strip()
            if started.tzinfo is None or finished.tzinfo is None:
                continue
            if int(started.astimezone(timezone.utc).timestamp()) < batch_epoch:
                continue
            if finished < started or exit_code != "0" or not session_id:
                continue
            if (
                config.get("id") != model
                or config.get("provider") != provider
                or config.get("thinkingLevel") != "high"
                or config.get("batch") != cohort
                or config.get("dataRevision") != revision
                or config.get("systemPromptMode") != "pi-default"
                or config.get("promptVersion") != prompt_version
            ):
                continue
            for required in ("answer.json", "metrics.json", "input-manifest.sha256"):
                if not (run_dir / required).is_file() or (run_dir / required).stat().st_size == 0:
                    raise ValueError(f"{run_dir.name} is missing {required}")
            for json_file in ("answer.json", "metrics.json"):
                json.loads((run_dir / json_file).read_text(encoding="utf-8"))
        except (OSError, ValueError, json.JSONDecodeError):
            continue
        matches.append(run_dir.name)

if len(matches) > 1:
    print(
        f"Found multiple complete {cohort} runs in this batch window for {run_root.name}: "
        + ", ".join(matches),
        file=sys.stderr,
    )
    raise SystemExit(1)
if matches:
    print(matches[0])
PY
}

declare -A COMPLETED_RUNS=()
remaining_runs=0
echo "Resume plan for $BATCH_ID ($COUNT Cases):"
for scenario_id in "${SELECTED_CASES[@]}"; do
  for model_config in "${MODEL_CONFIGS[@]}"; do
    IFS='|' read -r model provider _thinking <<< "$model_config"
    native_id=$(completed_run_id "$scenario_id" "$model" "$provider" v6-pi-native)
    knowledge_id=$(completed_run_id "$scenario_id" "$model" "$provider" v6-user-knowledge)
    COMPLETED_RUNS["$scenario_id|$model|v6-pi-native"]=$native_id
    COMPLETED_RUNS["$scenario_id|$model|v6-user-knowledge"]=$knowledge_id
    (( ${#native_id} > 0 )) || remaining_runs=$((remaining_runs + 1))
    (( ${#knowledge_id} > 0 )) || remaining_runs=$((remaining_runs + 1))
    printf '  %s %s: native=%s knowledge=%s\n' "$scenario_id" "$model" \
      "${native_id:-missing}" "${knowledge_id:-missing}"
  done
done
echo "Completed cohort runs: $((COUNT * ${#MODEL_CONFIGS[@]} * 2 - remaining_runs)); remaining: $remaining_runs"

if (( DRY_RUN == 1 )); then
  echo "Dry run only: no run directories, locks, or model calls were created."
  exit 0
fi

LOCK_DIR="$RUN_ROOT/.case-comparison-batch-v6.lock"
if [[ -e "$LOCK_DIR" ]]; then
  echo "Batch lock already exists: $LOCK_DIR" >&2
  echo "Confirm no evaluation is running, then remove this empty stale lock with rmdir." >&2
  exit 1
fi
for scenario_id in "${SELECTED_CASES[@]}"; do
  case_lock="$RUN_ROOT/.case-pipeline-$scenario_id.lock"
  if [[ -e "$case_lock" ]]; then
    echo "Case lock already exists: $case_lock" >&2
    echo "Confirm no evaluation is running, then remove this empty stale lock with rmdir." >&2
    exit 1
  fi
done
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  echo "Another V6 comparison batch appears to be running: $LOCK_DIR" >&2
  exit 1
fi
trap 'rmdir "$LOCK_DIR" 2>/dev/null || true' EXIT

[[ -f "$RESULTS_FILE" && ! -L "$RESULTS_FILE" ]] || {
  echo "Batch results file is missing or symlinked: $RESULTS_FILE" >&2
  exit 1
}
[[ "$(head -n 1 "$RESULTS_FILE")" == $'scenario\tmodel\tprovider\tthinking\tdata_revision\tstatus\texit_code\tstarted_at\tfinished_at' ]] || {
  echo "Unexpected batch results header: $RESULTS_FILE" >&2
  exit 1
}
[[ ! -L "$PROGRESS_LOG" ]] || {
  echo "Refusing symlinked progress log: $PROGRESS_LOG" >&2
  exit 1
}

umask 077
exec > >(tee -a "$PROGRESS_LOG") 2>&1
PI_VERSION=$(pi --version | head -n 1)
printf '\n=== Resuming %s at %s ===\n' "$BATCH_ID" "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
printf 'code_commit=%s\npi_version=%s\ndata_revision=%s\n' \
  "$CODE_COMMIT" "$PI_VERSION" "$DATA_REVISION"
echo "Progress log: $PROGRESS_LOG"

next_run_id() {
  local scenario_id=$1
  local highest=0
  local run_dir run_number
  shopt -s nullglob
  for run_dir in "$RUN_ROOT/$scenario_id"/run-[0-9][0-9][0-9]; do
    [[ -d "$run_dir" ]] || continue
    run_number=${run_dir##*/run-}
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

run_single_cohort() (
  set -euo pipefail
  local scenario_id=$1
  local model=$2
  local provider=$3
  local thinking=$4
  local cohort=$5
  local runner
  local case_lock="$RUN_ROOT/.case-pipeline-$scenario_id.lock"
  local run_id

  if [[ "$cohort" == v6-pi-native ]]; then
    runner=$NATIVE_RUNNER
  else
    runner=$KNOWLEDGE_RUNNER
  fi
  if ! mkdir "$case_lock" 2>/dev/null; then
    echo "Another Case pipeline appears to be running: $case_lock" >&2
    return 1
  fi
  trap 'rmdir "$case_lock" 2>/dev/null || true' EXIT

  cd "$REMOTE_ROOT"
  env \
    PI_EVAL_PROVIDER="$provider" \
    PI_EVAL_MODEL="$model" \
    PI_EVAL_THINKING="$thinking" \
    PI_EVAL_DATA_REVISION="$DATA_REVISION" \
    "$runner" "$scenario_id" run-999 --check-only

  run_id=$(next_run_id "$scenario_id")
  printf 'Current run: case=%s cohort=%s model=%s/%s session_name=%s-%s\n' \
    "$scenario_id" "$cohort" "$provider" "$model" "$scenario_id" "$run_id"
  env \
    PI_EVAL_PROVIDER="$provider" \
    PI_EVAL_MODEL="$model" \
    PI_EVAL_THINKING="$thinking" \
    PI_EVAL_DATA_REVISION="$DATA_REVISION" \
    "$runner" "$scenario_id" "$run_id"
)

run_logged() {
  local log_file=$1
  shift
  local -a pipeline_status
  set +e
  "$@" 2>&1 | tee -a "$log_file"
  pipeline_status=("${PIPESTATUS[@]}")
  set -e
  if (( pipeline_status[0] != 0 )); then
    return "${pipeline_status[0]}"
  fi
  return "${pipeline_status[1]}"
}

has_completed_result() {
  local scenario_id=$1
  local model=$2
  awk -F '\t' -v scenario="$scenario_id" -v model="$model" \
    'NR > 1 && $1 == scenario && $2 == model && $6 == "completed" && $7 == "0" { found = 1 } END { exit !found }' \
    "$RESULTS_FILE"
}

comparison_count=0
failure_count=0
for scenario_id in "${SELECTED_CASES[@]}"; do
  for model_config in "${MODEL_CONFIGS[@]}"; do
    IFS='|' read -r model provider thinking <<< "$model_config"
    pair_started_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    log_file="$BATCH_DIR/${scenario_id}-${model}.log"
    native_id=${COMPLETED_RUNS["$scenario_id|$model|v6-pi-native"]}
    knowledge_id=${COMPLETED_RUNS["$scenario_id|$model|v6-user-knowledge"]}

    if [[ -n "$native_id" && -n "$knowledge_id" ]]; then
      echo "Already complete; skipping $scenario_id $model (native=$native_id knowledge=$knowledge_id)"
      if ! has_completed_result "$scenario_id" "$model"; then
        finished_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
        printf '%s\t%s\t%s\t%s\t%s\tcompleted\t0\t%s\t%s\n' \
          "$scenario_id" "$model" "$provider" "$thinking" "$DATA_REVISION" \
          "$pair_started_at" "$finished_at" >> "$RESULTS_FILE"
      fi
      continue
    fi

    echo "=== Resume $scenario_id | $provider/$model | $thinking ==="
    run_status=0
    if [[ -z "$native_id" && -z "$knowledge_id" ]]; then
      if run_logged "$log_file" env \
        PI_EVAL_PROVIDER="$provider" \
        PI_EVAL_MODEL="$model" \
        PI_EVAL_THINKING="$thinking" \
        PI_EVAL_DATA_REVISION="$DATA_REVISION" \
        "$COMPARISON_RUNNER" "$scenario_id"; then
        :
      else
        run_status=$?
      fi
    elif [[ -z "$native_id" ]]; then
      if run_logged "$log_file" run_single_cohort \
        "$scenario_id" "$model" "$provider" "$thinking" v6-pi-native; then
        :
      else
        run_status=$?
      fi
    else
      if run_logged "$log_file" run_single_cohort \
        "$scenario_id" "$model" "$provider" "$thinking" v6-user-knowledge; then
        :
      else
        run_status=$?
      fi
    fi

    if (( run_status == 0 )); then
      native_id=$(completed_run_id "$scenario_id" "$model" "$provider" v6-pi-native "$log_file")
      knowledge_id=$(completed_run_id "$scenario_id" "$model" "$provider" v6-user-knowledge "$log_file")
      if [[ -z "$native_id" || -z "$knowledge_id" ]]; then
        echo "Runner returned success but a complete cohort artifact is missing for $scenario_id/$model." >&2
        run_status=1
      fi
    fi

    finished_at=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    result_status=completed
    if (( run_status != 0 )); then
      result_status=failed
      failure_count=$((failure_count + 1))
    fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$scenario_id" "$model" "$provider" "$thinking" "$DATA_REVISION" \
      "$result_status" "$run_status" "$pair_started_at" "$finished_at" >> "$RESULTS_FILE"
    comparison_count=$((comparison_count + 1))
    echo "Pair $result_status: $scenario_id $model (exit=$run_status)"
  done
done

echo "Resume finished: $comparison_count comparisons attempted; failures=$failure_count."
echo "Results: $RESULTS_FILE"
if (( failure_count > 0 )); then
  exit 1
fi
