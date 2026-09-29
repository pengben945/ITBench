#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'EOF'
Usage:
  run_scenario_v3.sh Scenario-N run-NNN --check-only
  run_scenario_v3.sh Scenario-N run-NNN

Environment overrides:
  PI_EVAL_PROVIDER   Default: deepseek
  PI_EVAL_MODEL      Default: deepseek-v4-flash
  PI_EVAL_THINKING   Default: high
  PI_EVAL_PROXY_URL  Optional HTTP(S) proxy forwarded into the sandbox
  PI_EVAL_SYSTEM_PROMPT_MODE  custom (default) or pi-default
  PI_EVAL_BATCH  Batch label recorded in model_config.json
  PI_EVAL_DATA_REVISION  Dataset revision recorded in model_config.json
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
WORK_DIR="$RUN_DIR/work"
SYSTEM_TEMPLATE=${PI_EVAL_SYSTEM_TEMPLATE:-"$PROJECT_ROOT/evaluation/prompts/sre_system_v3.md"}
TASK_TEMPLATE=${PI_EVAL_TASK_TEMPLATE:-"$PROJECT_ROOT/evaluation/prompts/sre_diagnosis_v3.md"}
PROMPT_VERSION=${PI_EVAL_PROMPT_VERSION:-3.0}
PROMPT_PLACEMENT=${PI_EVAL_PROMPT_PLACEMENT:-system}
SYSTEM_PROMPT_MODE=${PI_EVAL_SYSTEM_PROMPT_MODE:-custom}
SCHEMA_VERSION=${PI_EVAL_SCHEMA_VERSION:-2.0}
SCHEMA_FILE=${PI_EVAL_SCHEMA_FILE:-"$PROJECT_ROOT/evaluation/schemas/diagnosis-v2.schema.json"}
SCHEMA_MOUNT=${PI_EVAL_SCHEMA_MOUNT:-/instructions/diagnosis-v2.schema.json}
SCHEMA_SNAPSHOT="$RUN_DIR/$(basename "$SCHEMA_FILE")"
PI_CONFIG_DIR=${PI_CODING_AGENT_DIR:-/root/.pi/agent}
PROVIDER=${PI_EVAL_PROVIDER:-deepseek}
MODEL=${PI_EVAL_MODEL:-deepseek-v4-flash}
THINKING=${PI_EVAL_THINKING:-high}
PROXY_URL=${PI_EVAL_PROXY_URL:-}
BATCH=${PI_EVAL_BATCH:-v6-unclassified}
DATA_REVISION=${PI_EVAL_DATA_REVISION:-76df38a82288f75ba9e41dc8c515033332497473}

for command_name in bwrap pi jq python3 sha256sum; do
  command -v "$command_name" >/dev/null || {
    echo "Required command not found: $command_name" >&2
    exit 1
  }
done

case "$SYSTEM_PROMPT_MODE" in
  custom|pi-default) ;;
  *)
    echo "PI_EVAL_SYSTEM_PROMPT_MODE must be 'custom' or 'pi-default'" >&2
    exit 2
    ;;
esac

for required_path in "$CASE_DIR" "$TASK_TEMPLATE" "$SCHEMA_FILE"; do
  [[ -e "$required_path" ]] || {
    echo "Required path not found: $required_path" >&2
    exit 1
  }
done

if [[ "$SYSTEM_PROMPT_MODE" == custom && ! -f "$SYSTEM_TEMPLATE" ]]; then
  echo "Custom system prompt not found: $SYSTEM_TEMPLATE" >&2
  exit 1
fi

if find "$CASE_DIR" -type l -print -quit | grep -q .; then
  echo "Refusing case containing symbolic links: $CASE_DIR" >&2
  exit 1
fi

if find "$CASE_DIR" -type f -iname '*ground*truth*' -print -quit | grep -q .; then
  echo "Ground Truth-like file found in agent-visible case: $CASE_DIR" >&2
  exit 1
fi

# Preserve the original absolute cwd so Pi WebUI continues to group sessions by Scenario.
SESSION_KEY="-${CASE_DIR//\//-}--"
SESSION_DIR="$PI_CONFIG_DIR/sessions/$SESSION_KEY"

build_bwrap_args() {
  local writable_work=$1
  BWRAP_ARGS=(
    --die-with-parent
    --new-session
    --unshare-user
    --uid 0
    --gid 0
    --unshare-pid
    --unshare-ipc
    --unshare-uts
    --hostname pi-eval
    --cap-drop ALL
    --clearenv
    --setenv HOME /root
    --setenv PATH /usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
    --setenv TMPDIR /tmp
    --setenv ITBENCH_WORK_DIR /work
    --setenv ITBENCH_SCHEMA_FILE "$SCHEMA_MOUNT"
    --setenv PI_CODING_AGENT_DIR "$PI_CONFIG_DIR"
    --setenv PI_EVAL_PROVIDER "$PROVIDER"
    --setenv PI_EVAL_MODEL "$MODEL"
    --proc /proc
    --dev /dev
    --tmpfs /tmp
    --ro-bind /usr /usr
    --dir /etc
    --dir /root
    --dir /root/.pi
    --dir /root/.pi/agent
    --dir /root/.pi/agent/sessions
    --dir /data
    --dir /data/edison
    --dir /data/edison/piagent-itbench-eval
    --dir /data/edison/piagent-itbench-eval/datasets
    --dir /data/edison/piagent-itbench-eval/datasets/agent_cases
    --dir /instructions
    --ro-bind "$SCHEMA_FILE" "$SCHEMA_MOUNT"
    --ro-bind "$CASE_DIR" "$CASE_DIR"
    --bind "$writable_work" /work
    --chdir "$CASE_DIR"
  )

  if [[ -n "$PROXY_URL" ]]; then
    BWRAP_ARGS+=(
      --setenv http_proxy "$PROXY_URL"
      --setenv https_proxy "$PROXY_URL"
      --setenv HTTP_PROXY "$PROXY_URL"
      --setenv HTTPS_PROXY "$PROXY_URL"
      --setenv no_proxy 127.0.0.1,localhost
      --setenv NO_PROXY 127.0.0.1,localhost
      --setenv NODE_USE_ENV_PROXY 1
    )
  fi

  for runtime_path in /bin /lib /lib64; do
    [[ -e "$runtime_path" ]] && BWRAP_ARGS+=(--ro-bind "$runtime_path" "$runtime_path")
  done

  for system_path in \
    /etc/ssl \
    /etc/ca-certificates.conf \
    /etc/ld.so.cache \
    /etc/resolv.conf \
    /etc/hosts \
    /etc/nsswitch.conf \
    /etc/passwd \
    /etc/group \
    /etc/localtime; do
    [[ -e "$system_path" ]] && BWRAP_ARGS+=(--ro-bind "$system_path" "$system_path")
  done

  for config_file in auth.json models.json models-store.json settings.json; do
    [[ -f "$PI_CONFIG_DIR/$config_file" ]] && \
      BWRAP_ARGS+=(--ro-bind "$PI_CONFIG_DIR/$config_file" "$PI_CONFIG_DIR/$config_file")
  done
}

if [[ "$MODE" == "--check-only" ]]; then
  CHECK_DIR=$(mktemp -d /tmp/itbench-bwrap-check.XXXXXX)
  trap 'rm -rf -- "$CHECK_DIR"' EXIT
  build_bwrap_args "$CHECK_DIR"
  bwrap "${BWRAP_ARGS[@]}" /bin/bash -c '
    set -eu
    test -r k8s_objects_raw.tsv
    test -r "$ITBENCH_SCHEMA_FILE"
    if touch .bwrap-input-write-test 2>/dev/null; then
      rm -f .bwrap-input-write-test
      echo "Case input is unexpectedly writable" >&2
      exit 1
    fi
    if printf "{}\n" > "$ITBENCH_SCHEMA_FILE" 2>/dev/null; then
      echo "Output schema is unexpectedly writable" >&2
      exit 1
    fi
    test ! -e /data/edison/piagent-itbench-eval/datasets/raw
    test ! -e /data/edison/piagent-itbench-eval/evaluation/ground_truth
    touch /work/write-test
    rm /work/write-test
    pi --version
    pi auth check --model "$PI_EVAL_PROVIDER/$PI_EVAL_MODEL" --json --no-refresh >/dev/null
  '
  echo "Sandbox check passed for $SCENARIO_ID"
  exit 0
fi

if [[ -e "$RUN_DIR" ]]; then
  echo "Refusing to overwrite existing run: $RUN_DIR" >&2
  exit 1
fi

umask 077
mkdir -p "$WORK_DIR" "$SESSION_DIR"
if [[ "$SYSTEM_PROMPT_MODE" == custom ]]; then
  cp "$SYSTEM_TEMPLATE" "$RUN_DIR/system_prompt.txt"
  SYSTEM_PROMPT_SHA256=$(sha256sum "$RUN_DIR/system_prompt.txt" | cut -d ' ' -f1)
else
  SYSTEM_PROMPT_SHA256=null
fi
sed "s/{{SCENARIO_ID}}/$SCENARIO_ID/g" "$TASK_TEMPLATE" > "$RUN_DIR/prompt.txt"
cp "$SCHEMA_FILE" "$SCHEMA_SNAPSHOT"

TASK_PROMPT_SHA256=$(sha256sum "$RUN_DIR/prompt.txt" | cut -d ' ' -f1)
SCHEMA_SHA256=$(sha256sum "$SCHEMA_SNAPSHOT" | cut -d ' ' -f1)
PI_VERSION=$(pi --version | head -n 1)

PI_EVAL_PROMPT_VERSION="$PROMPT_VERSION" \
PI_EVAL_PROMPT_PLACEMENT="$PROMPT_PLACEMENT" \
PI_EVAL_SYSTEM_PROMPT_MODE="$SYSTEM_PROMPT_MODE" \
PI_EVAL_SYSTEM_PROMPT_SHA256="$SYSTEM_PROMPT_SHA256" \
PI_EVAL_TASK_PROMPT_SHA256="$TASK_PROMPT_SHA256" \
PI_EVAL_SCHEMA_SHA256="$SCHEMA_SHA256" \
PI_EVAL_SCHEMA_VERSION="$SCHEMA_VERSION" \
PI_EVAL_PROVIDER="$PROVIDER" \
PI_EVAL_MODEL="$MODEL" \
PI_EVAL_THINKING="$THINKING" \
PI_EVAL_PI_VERSION="$PI_VERSION" \
PI_EVAL_BATCH="$BATCH" \
PI_EVAL_DATA_REVISION="$DATA_REVISION" \
PI_EVAL_PROXY_URL="$PROXY_URL" \
python3 - "$RUN_DIR/model_config.json" <<'PY'
import json
import os
import sys

system_prompt_sha256 = os.environ["PI_EVAL_SYSTEM_PROMPT_SHA256"]
config = {
    "promptVersion": os.environ["PI_EVAL_PROMPT_VERSION"],
    "promptPlacement": os.environ["PI_EVAL_PROMPT_PLACEMENT"],
    "systemPromptMode": os.environ["PI_EVAL_SYSTEM_PROMPT_MODE"],
    "systemPromptSha256": (
        None if system_prompt_sha256 == "null" else system_prompt_sha256
    ),
    "taskPromptSha256": os.environ["PI_EVAL_TASK_PROMPT_SHA256"],
    "schemaSha256": os.environ["PI_EVAL_SCHEMA_SHA256"],
    "outputSchemaVersion": os.environ["PI_EVAL_SCHEMA_VERSION"],
    "provider": os.environ["PI_EVAL_PROVIDER"],
    "id": os.environ["PI_EVAL_MODEL"],
    "thinkingLevel": os.environ["PI_EVAL_THINKING"],
    "piVersion": os.environ["PI_EVAL_PI_VERSION"],
    "batch": os.environ["PI_EVAL_BATCH"],
    "dataRevision": os.environ["PI_EVAL_DATA_REVISION"],
    "tools": ["read", "grep", "find", "ls", "bash"],
    "sandbox": "bubblewrap",
    "proxyEnabled": bool(os.environ.get("PI_EVAL_PROXY_URL")),
}
with open(sys.argv[1], "w", encoding="utf-8") as stream:
    json.dump(config, stream, ensure_ascii=False, indent=2)
    stream.write("\n")
PY

(
  cd "$CASE_DIR"
  find . -type f -print0 | sort -z | xargs -0 -r sha256sum
) > "$RUN_DIR/input-manifest.sha256"

build_bwrap_args "$WORK_DIR"
BWRAP_ARGS+=(--bind "$SESSION_DIR" "$SESSION_DIR")

TASK_PROMPT=$(<"$RUN_DIR/prompt.txt")
PI_ARGS=(
  pi
  --offline
  --provider "$PROVIDER"
  --model "$MODEL"
  --thinking "$THINKING"
  --mode json
  --print
  --name "$SCENARIO_ID-$RUN_ID"
  --tools read,grep,find,ls,bash
  --no-extensions
  --no-skills
  --no-prompt-templates
  --no-context-files
)
if [[ "$SYSTEM_PROMPT_MODE" == custom ]]; then
  SYSTEM_PROMPT=$(<"$RUN_DIR/system_prompt.txt")
  PI_ARGS+=(--system-prompt "$SYSTEM_PROMPT")
fi
PI_ARGS+=(-- "$TASK_PROMPT")

date -Iseconds > "$RUN_DIR/started_at.txt"
set +e
bwrap "${BWRAP_ARGS[@]}" "${PI_ARGS[@]}" \
  </dev/null > "$RUN_DIR/raw_output.jsonl" 2> "$RUN_DIR/stderr.log"
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

python3 - "$RUN_DIR/answer.json" "$SCHEMA_SNAPSHOT" <<'PY'
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

echo "Completed $SCENARIO_ID/$RUN_ID with Prompt V$PROMPT_VERSION"
echo "  answer:  $RUN_DIR/answer.json"
echo "  metrics: $RUN_DIR/metrics.json"
echo "  session: $(<"$RUN_DIR/session_id.txt")"
