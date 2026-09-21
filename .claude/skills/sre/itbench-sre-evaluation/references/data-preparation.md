# Raw Data to Agent Case

## Directory Contract

The repository root is `/Users/Edison/ITBench` locally. The standard evaluation workspace is `/data/edison/piagent-itbench-eval` on the evaluation server. Relative paths below are rooted at that project directory.

```text
datasets/raw/itbench-aa/sre/Scenario-N/  # source snapshot; includes ground_truth.yaml
datasets/agent_cases/Scenario-N/         # derived Agent-visible input; excludes Ground Truth
datasets/manifests/Scenario-N.sha256     # hashes of files in the derived Case
datasets/ground_truth/                    # scoring-only material, if materialized separately
runs/Scenario-N/run-NNN/                 # per-run raw events and outputs
outputs/                                  # normalized outputs when a reporting workflow creates them
reports/                                  # evaluation reports and model tracker
```

The raw dataset is tied to the fixed ITBench-AA revision recorded by the project (`76df38a82288f75ba9e41dc8c515033332497473`). Do not silently mix revisions; record the revision used for every experiment.

## Preparation Procedure

From the project root, run the existing preparation script for the selected scenario:

```bash
evaluation/scripts/prepare_scenario_v2.sh Scenario-N
```

The script:

1. Reads `datasets/raw/itbench-aa/sre/Scenario-N/`.
2. Performs an `rsync --dry-run --itemize-changes` preview.
3. Copies the source into `datasets/agent_cases/Scenario-N/` while excluding the root `ground_truth.yaml`.
4. Rejects symbolic links and Ground Truth-like filenames in the derived Case.
5. Compares source and Case file counts (excluding `ground_truth.yaml`).
6. Writes `datasets/manifests/Scenario-N.sha256` from the derived Case contents.

Before running it, inspect whether the destination already exists and review the dry-run output. The script does not delete destination files; do not turn this into a broad synchronization or cleanup operation. Preserve unrelated user changes.

## Verification Checklist

Preparation is complete only when all of these are true:

- The raw source exists and contains the expected `ground_truth.yaml`.
- The derived Case exists and contains no Ground Truth file, symlink, or answer-like artifact.
- The file-count check passes and the manifest is present.
- The Case contains the actual observable data needed by the scenario (alerts, Kubernetes objects/events, logs, metrics, traces, and other files as applicable).
- The Case is treated as read-only during a run; run-specific analysis files go under `runs/Scenario-N/run-NNN/work/`.

Do not load an entire large TSV or JSONL merely to inspect it. Use file listings, sizes, headers, and bounded/aggregated queries with a standards-compliant parser. Preserve nested JSON and quoted TSV fields.

## Separation Rule

The Agent diagnosis environment must expose only the derived Case, the read-only V3 schema, and the run's writable `/work`. Ground Truth may be used later by an evaluator for the `ground_truth_match` track, but it must never be passed to the model or used to compose the model's prompt.
