#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)

export ITBENCH_REMOTE_RUNNER=evaluation/scripts/run_scenario_v6_user_prompt.sh
export ITBENCH_BATCH_LABEL=v6-user-message

exec "$SCRIPT_DIR/trigger_batch_v6.sh" "$@"
