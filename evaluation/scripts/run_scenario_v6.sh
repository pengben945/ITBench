#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
PROJECT_ROOT=$(cd -- "$SCRIPT_DIR/../.." && pwd -P)

export PI_EVAL_SYSTEM_TEMPLATE="$PROJECT_ROOT/evaluation/prompts/sre_system_v6.md"
export PI_EVAL_TASK_TEMPLATE="$PROJECT_ROOT/evaluation/prompts/sre_diagnosis_v6.md"
export PI_EVAL_PROMPT_VERSION=6.0
export PI_EVAL_SCHEMA_VERSION=3.0
export PI_EVAL_SCHEMA_FILE="$PROJECT_ROOT/evaluation/schemas/diagnosis-v3.schema.json"
export PI_EVAL_SCHEMA_MOUNT=/instructions/diagnosis-v3.schema.json

exec "$SCRIPT_DIR/run_scenario_v3.sh" "$@"
