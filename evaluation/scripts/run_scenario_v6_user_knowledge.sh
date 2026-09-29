#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
PROJECT_ROOT=$(cd -- "$SCRIPT_DIR/../.." && pwd -P)

export PI_EVAL_SYSTEM_PROMPT_MODE=pi-default
export PI_EVAL_TASK_TEMPLATE="$PROJECT_ROOT/evaluation/prompts/sre_diagnosis_v6_user_knowledge.md"
export PI_EVAL_PROMPT_VERSION=6.1-user-knowledge
export PI_EVAL_PROMPT_PLACEMENT=user
export PI_EVAL_BATCH=v6-user-knowledge
export PI_EVAL_SCHEMA_VERSION=3.0
export PI_EVAL_SCHEMA_FILE="$PROJECT_ROOT/evaluation/schemas/diagnosis-v3.schema.json"
export PI_EVAL_SCHEMA_MOUNT=/instructions/diagnosis-v3.schema.json

exec "$SCRIPT_DIR/run_scenario_v3.sh" "$@"
