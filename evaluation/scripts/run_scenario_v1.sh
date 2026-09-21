#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage:
  run_scenario_v1.sh Scenario-N run-NNN --check-only
  run_scenario_v1.sh Scenario-N run-NNN

Environment overrides:
  PI_EVAL_PROVIDER   Default: deepseek
  PI_EVAL_MODEL      Default: deepseek-v4-flash
  PI_EVAL_THINKING   Default: high
EOF
  exit 2
}

[[ $# -ge 2 && $# -le 3 ]] || usage
SCENARIO_ID=$1
RUN_ID=$2
MODE=${3:-run}

[[ "$SCENARIO_ID" =~ ^Scenario-[0-9]+$ ]] || usage
[[ "$RUN_ID" =~ ^run-[0-9]{3}$ ]] || usage
[[ "$MODE" == "run" || "$MODE" == "--check-only" ]] || usage

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
PROJECT_ROOT=$(cd -- "$SCRIPT_DIR/../.." && pwd -P)
CASE_DIR="$PROJECT_ROOT/datasets/agent_cases/$SCENARIO_ID"
RUN_DIR="$PROJECT_ROOT/runs/$SCENARIO_ID/$RUN_ID"
SYSTEM_TEMPLATE="$PROJECT_ROOT/evaluation/prompts/sre_system_v1.md"
TASK_TEMPLATE="$PROJECT_ROOT/evaluation/prompts/sre_diagnosis_v1.md"
SCHEMA_FILE="$PROJECT_ROOT/evaluation/schemas/diagnosis-v1.schema.json"
PROVIDER=${PI_EVAL_PROVIDER:-deepseek}
MODEL=${PI_EVAL_MODEL:-deepseek-v4-flash}
THINKING=${PI_EVAL_THINKING:-high}

for command_name in pi jq python3 sha256sum; do
  command -v "$command_name" >/dev/null || {
    echo "Required command not found: $command_name" >&2
    exit 1
  }
done

for required_path in "$CASE_DIR" "$SYSTEM_TEMPLATE" "$TASK_TEMPLATE" "$SCHEMA_FILE"; do
  [[ -e "$required_path" ]] || {
    echo "Required path not found: $required_path" >&2
    exit 1
  }
done

if find "$CASE_DIR" -type l -print -quit | grep -q .; then
  echo "Refusing case containing symbolic links: $CASE_DIR" >&2
  exit 1
fi

if find "$CASE_DIR" -type f -iname '*ground*truth*' -print -quit | grep -q .; then
  echo "Ground Truth-like file found in agent-visible case: $CASE_DIR" >&2
  exit 1
fi

if [[ "$MODE" == "--check-only" ]]; then
  pi --version
  pi auth check --model "$PROVIDER/$MODEL" --json --no-refresh >/dev/null
  echo "Non-sandboxed V1 check passed for $SCENARIO_ID"
  exit 0
fi

if [[ -e "$RUN_DIR" ]]; then
  echo "Refusing to overwrite existing run: $RUN_DIR" >&2
  exit 1
fi

umask 077
mkdir -p "$RUN_DIR"
cp "$SYSTEM_TEMPLATE" "$RUN_DIR/system_prompt.txt"
sed \
  -e "s|{{SCENARIO_ID}}|$SCENARIO_ID|g" \
  -e "s|{{CASE_DIR}}|$CASE_DIR|g" \
  "$TASK_TEMPLATE" > "$RUN_DIR/prompt.txt"
cp "$SCHEMA_FILE" "$RUN_DIR/diagnosis-v1.schema.json"

printf '{\n  "version": "1.0",\n  "provider": "%s",\n  "id": "%s",\n  "thinkingLevel": "%s",\n  "tools": ["read", "grep", "find", "ls"],\n  "sandbox": null\n}\n' \
  "$PROVIDER" "$MODEL" "$THINKING" > "$RUN_DIR/model_config.json"

(
  cd "$CASE_DIR"
  find . -type f -print0 | sort -z | xargs -0 -r sha256sum
) > "$RUN_DIR/input-manifest.sha256"

SYSTEM_PROMPT=$(<"$RUN_DIR/system_prompt.txt")
TASK_PROMPT=$(<"$RUN_DIR/prompt.txt")

date -Iseconds > "$RUN_DIR/started_at.txt"
set +e
(
  cd "$CASE_DIR"
  pi \
    --offline \
    --provider "$PROVIDER" \
    --model "$MODEL" \
    --thinking "$THINKING" \
    --mode json \
    --print \
    --name "$SCENARIO_ID-$RUN_ID" \
    --tools read,grep,find,ls \
    --no-extensions \
    --no-skills \
    --no-prompt-templates \
    --no-context-files \
    --system-prompt "$SYSTEM_PROMPT" \
    -- "$TASK_PROMPT" \
    </dev/null > "$RUN_DIR/raw_output.jsonl" 2> "$RUN_DIR/stderr.log"
)
RUN_STATUS=$?
set -e

date -Iseconds > "$RUN_DIR/finished_at.txt"
printf '%s\n' "$RUN_STATUS" > "$RUN_DIR/exit_code.txt"

if [[ "$RUN_STATUS" -ne 0 ]]; then
  echo "Pi exited with status $RUN_STATUS; see $RUN_DIR/stderr.log" >&2
  exit "$RUN_STATUS"
fi

jq -rs '
  [.[] | select(.type == "message_end" and .message.role == "assistant")]
  | last
  | [.message.content[] | select(.type == "text") | .text]
  | join("")
' "$RUN_DIR/raw_output.jsonl" > "$RUN_DIR/answer.json"

head -n 1 "$RUN_DIR/raw_output.jsonl" | jq -r '.id' > "$RUN_DIR/session_id.txt"

python3 - "$RUN_DIR/answer.json" "$RUN_DIR/diagnosis-v1.schema.json" <<'PY'
import json
import sys

import jsonschema

with open(sys.argv[1], encoding="utf-8") as answer_file:
    answer = json.load(answer_file)
with open(sys.argv[2], encoding="utf-8") as schema_file:
    schema = json.load(schema_file)
jsonschema.validate(answer, schema)
PY

python3 "$SCRIPT_DIR/summarize_run.py" "$RUN_DIR" >/dev/null

echo "Completed $SCENARIO_ID/$RUN_ID (V1)"
echo "  answer:  $RUN_DIR/answer.json"
echo "  metrics: $RUN_DIR/metrics.json"
echo "  session: $(<"$RUN_DIR/session_id.txt")"
