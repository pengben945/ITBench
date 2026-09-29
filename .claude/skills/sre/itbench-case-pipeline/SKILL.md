---
name: itbench-case-pipeline
description: Run a paired Pi-Agent-native and user-knowledge ITBench Case, assess both results, and register the scored runs in the dashboard.
---

# ITBench Case Comparison Pipeline

Use this skill when asked to execute an ITBench Case and compare Pi-Agent without added troubleshooting knowledge against Pi-Agent with user-provided troubleshooting knowledge. For raw-data preparation or the full scoring contract, also follow `itbench-sre-evaluation`.

## Comparison definition

The two new, canonical cohorts are:

- `v6-pi-native`: Pi's default system prompt and a neutral Case task.
- `v6-user-knowledge`: the same Pi default system prompt and task/output contract, with user-provided troubleshooting knowledge added to the user prompt.

Both cohorts use the same Case, model, provider, thinking level, schema, tools, sandbox, and dataset revision. Only the user-provided troubleshooting knowledge differs. Do not relabel historic `v6-user-full`, `v6-user-minimal`, or `v6-system` data as either new cohort; their prompt conditions are different.

## Running a comparison

1. Verify that the selected derived Case and its SHA-256 manifest already exist. Do not expose Ground Truth, raw data, other Cases, or prior runs to Pi. If preparation is required, use the preparation workflow in `itbench-sre-evaluation` first.
2. Freeze and explicitly set the provider, model, and thinking level. Confirm the dataset revision and use the same values for both runs.
3. If running on `10.106.3.100`, first verify the host, disk, outer workspace contents, Git worktree, branch, and commit using the read-only checks in `AGENTS.md`. The comparison runner and dashboard API must already be deployed to the runtime workspace. Treat code deployment as a separate reviewed operation; never sync runtime data or run `rsync --delete` as part of execution.
4. From the evaluation workspace root, execute:

   ```bash
   PI_EVAL_PROVIDER=<provider> \
   PI_EVAL_MODEL=<model> \
   PI_EVAL_THINKING=<level> \
   evaluation/scripts/run_case_comparison_v6.sh Scenario-N
   ```

   The script runs both Bubblewrap preflights before making either model call, then executes the two cohorts sequentially. It allocates fresh run IDs, never clears Pi sessions, and stops on the first failed run while preserving all artifacts. A retry is a new comparison with new run IDs.
5. Inspect each run's `exit_code.txt`, `answer.json`, `raw_output.jsonl`, `metrics.json`, `model_config.json`, prompt snapshot, and `/work/diagnosis.json`. Verify the cited observations in Agent-visible Case data. Mark protocol-broken or unsupported diagnoses invalid; preserve their records without comparison scores.

## Scoring and registration

Score only after a run has completed. Ground Truth is scoring-only and must never be passed to Pi or used to compose either prompt.

For every run, create `runs/Scenario-N/run-NNN/score.json` following `evaluation/schemas/run-score-v1.schema.json`. Record:

- `diagnosis_valid`: whether the result satisfies the evaluation's validity gate;
- `official_gt_score`: the official root-cause entity score in `[0, 1]`, with normalized entities and TP/FP/FN;
- `evidence_quality_score`: the independent nine-dimension rubric total in `[0, 100]`;
- every evidence subscore and a short case-specific rationale;
- failure categories and relevant scoring limitations in `notes`.

For an invalid diagnosis, set both scores to `null` and `evidence_subscores` to `{}`. Do not assign accuracy scores to protocol failures or unsupported answers. Keep any failure categories and explanatory notes.

Append a concise case-level entry for each run to
`evaluation/reports/model-evaluation-tracker.md`, preserving the historical
records and keeping the two score tracks distinct.

After validating the score file, register the run:

```bash
python3 evaluation/scripts/register_scored_run.py \
  runs/Scenario-N/run-NNN \
  --dashboard-url http://10.106.3.100:8790
```

The endpoint is idempotent for an identical registration and rejects a conflicting score for the same batch/Case/run key. Confirm the response reports `ok: true`; then confirm the record appears in the dashboard API. Do not register a run before its scoring record is complete.

## Pi-Agent links

The dashboard adds an `打开 Pi-Agent` action for every run with a session ID. Configure the Pi-Agent URL template in the dashboard using the actual deployed route and `{session}` placeholder. Do not assume the WebUI URL pattern or expose session links in public reports.

## Safety and reproducibility

- Never delete, reuse, or overwrite historical runs or Pi session data.
- Do not start a remote batch or deploy dashboard code as part of this skill unless explicitly requested.
- Preserve the existing scoring rubric and report official and evidence-quality scores independently.
- Keep the two prompt snapshots, Pi version, model configuration, Case manifest, and all run artifacts with each result.
