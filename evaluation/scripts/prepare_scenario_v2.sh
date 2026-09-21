#!/usr/bin/env bash
set -euo pipefail

usage() {
  echo "Usage: $0 Scenario-N" >&2
  exit 2
}

[[ $# -eq 1 ]] || usage
SCENARIO_ID=$1
[[ "$SCENARIO_ID" =~ ^Scenario-[0-9]+$ ]] || usage

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
PROJECT_ROOT=$(cd -- "$SCRIPT_DIR/../.." && pwd -P)
SOURCE_DIR="$PROJECT_ROOT/datasets/raw/itbench-aa/sre/$SCENARIO_ID"
CASE_DIR="$PROJECT_ROOT/datasets/agent_cases/$SCENARIO_ID"
MANIFEST_DIR="$PROJECT_ROOT/datasets/manifests"
MANIFEST_FILE="$MANIFEST_DIR/$SCENARIO_ID.sha256"

for command_name in rsync find sha256sum; do
  command -v "$command_name" >/dev/null || {
    echo "Required command not found: $command_name" >&2
    exit 1
  }
done

[[ -d "$SOURCE_DIR" ]] || {
  echo "Raw scenario not found: $SOURCE_DIR" >&2
  exit 1
}

[[ -f "$SOURCE_DIR/ground_truth.yaml" ]] || {
  echo "Expected Ground Truth not found in raw scenario: $SOURCE_DIR/ground_truth.yaml" >&2
  exit 1
}

mkdir -p "$CASE_DIR" "$MANIFEST_DIR"

echo "Dry-run: $SOURCE_DIR -> $CASE_DIR"
rsync -an --itemize-changes \
  --exclude='/ground_truth.yaml' \
  "$SOURCE_DIR/" "$CASE_DIR/"

echo "Copying scenario without Ground Truth"
rsync -a --itemize-changes \
  --exclude='/ground_truth.yaml' \
  "$SOURCE_DIR/" "$CASE_DIR/"

if find "$CASE_DIR" -type l -print -quit | grep -q .; then
  echo "Refusing prepared case containing symbolic links: $CASE_DIR" >&2
  exit 1
fi

if find "$CASE_DIR" -type f -iname '*ground*truth*' -print -quit | grep -q .; then
  echo "Ground Truth-like file leaked into prepared case: $CASE_DIR" >&2
  exit 1
fi

SOURCE_COUNT=$(find "$SOURCE_DIR" -type f ! -name 'ground_truth.yaml' | wc -l)
CASE_COUNT=$(find "$CASE_DIR" -type f | wc -l)
[[ "$SOURCE_COUNT" -eq "$CASE_COUNT" ]] || {
  echo "File-count mismatch: source=$SOURCE_COUNT case=$CASE_COUNT" >&2
  exit 1
}

(
  cd "$CASE_DIR"
  find . -type f -print0 | sort -z | xargs -0 -r sha256sum
) > "$MANIFEST_FILE"

echo "Prepared $SCENARIO_ID"
echo "  input:    $CASE_DIR"
echo "  files:    $CASE_COUNT"
echo "  manifest: $MANIFEST_FILE"
