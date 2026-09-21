---
name: itbench-sre-evaluation
description: Prepare and run ITBench SRE cases, assess V6 diagnosis quality, record model results, and synchronize evaluation code between the local and remote Git worktrees.
---

# ITBench SRE Evaluation

Use this skill when a request involves the ITBench-AA data-to-case pipeline, a Scenario run, V6 prompt/schema evaluation, diagnosis scoring, model comparison, recording a model result, or synchronizing the local and remote evaluation code. It is a project workflow, not a replacement for the scripts or prompts in `evaluation/`.

## Fixed Baseline

The current comparison baseline is:

- system prompt: `evaluation/prompts/sre_system_v6.md`
- task prompt: `evaluation/prompts/sre_diagnosis_v6.md`
- output schema: `evaluation/schemas/diagnosis-v3.schema.json`
- runner: `evaluation/scripts/run_scenario_v6.sh`
- rubric: `evaluation/scoring/sre-v2-rubric.md`

Do not edit the prompt, schema, runner, or rubric as part of an ordinary case run. A prompt or schema change is a separate experiment and must be explicitly requested. Always freeze and record provider, model, thinking level, prompt version, schema version, data revision, and run ID.

## Workflow Routing

1. **Raw data to Case**: read [references/data-preparation.md](references/data-preparation.md). Identify the raw source, create or verify the Agent-visible derived Case, check Ground Truth isolation, and record the manifest.
2. **Run a model**: read [references/v6-evaluation.md](references/v6-evaluation.md). Use a fresh run ID, run `--check-only` first, then execute the formal V6 runner with explicit model variables.
3. **Assess a run**: use the same V6 reference and the rubric. Inspect `answer.json`, `raw_output.jsonl`, `metrics.json`, exit status, and `/work/diagnosis.json` evidence before assigning a quality grade.
4. **Record a result**: append the model's run/session, evidence, causal quality, failures, metrics, and fine-tuning recommendation to `evaluation/reports/model-evaluation-tracker.md`. Preserve prior records; retries use new run IDs.
5. **Synchronize code**: read [references/synchronization.md](references/synchronization.md). Treat the shared Git remote as the code authority; either endpoint may create a commit, and the other endpoint updates with a fast-forward pull.

## Non-negotiable Invariants

- The model must see only `datasets/agent_cases/Scenario-N/`; `ground_truth.yaml`, raw data, other Cases, and prior runs must not be mounted into its sandbox.
- Case input is read-only. The run-specific `work/` directory is the only Agent write location.
- Never infer a configuration change from a current snapshot alone. A claim that something changed requires before/after states or a recorded change event; a current state can support only a condition mismatch or a candidate trigger.
- Keep symptoms, intermediate propagation, technical bottlenecks, and trigger candidates distinct. Do not promote the most visible alert to the root cause without evidence.
- A schema-valid answer is not automatically a valid diagnosis. Check evidence paths, entities, timestamps, values, causal direction, and whether the Agent actually queried the data.
- Classify failures with the project categories `DATA`, `PARSING`, `RETRIEVAL`, `REASONING`, `ENTITY`, `OUTPUT`, `INFRA`, and `GRADER`; separate infrastructure/protocol failures from model capability.
- Do not delete old Cases, sessions, runs, outputs, or reports as part of this workflow. Do not use `rsync --delete`.
- Do not force-push, reset, overwrite a dirty worktree, or resolve a divergent branch by discarding commits. Stop and report the divergence for explicit resolution.

## Expected Deliverables

For preparation, expect an Agent-visible Case directory and a SHA-256 manifest. For each run, retain the runner artifacts (`raw_output.jsonl`, `answer.json`, `metrics.json`, prompt/schema snapshots, model metadata, timing, exit status, and session ID). For evaluation, produce a case-level conclusion plus an appended tracker entry; do not report only a total score or average.

When the user asks for a new scenario, model, or comparison, use the existing scripts and references above and keep the operation reproducible. If a prerequisite is absent or the runner fails, preserve the artifacts and report the exact failure boundary rather than silently treating it as a diagnosis result.

## Two-Endpoint Code Synchronization

The local and remote **code** worktrees use the same Git remote and can be kept identical by commit:

```text
local:  /Users/Edison/ITBench
remote: /data/edison/piagent-itbench-eval/ITBench
remote host: 10.106.3.100
ssh user: root
ssh key: ~/.ssh/id_ed25519
remote Git remote: https://github.com/pengben945/ITBench.git
```

Either endpoint may be the place where a code change is made. The endpoint that changes code must commit and push it; the other endpoint must fetch and `pull --ff-only` the commit before continuing. “Synchronized” means the two code worktrees resolve to the same Git commit and have no uncommitted code changes.

The outer remote workspace is different from the Git worktree:

```text
/data/edison/piagent-itbench-eval/evaluation/  # runtime evaluation files
/data/edison/piagent-itbench-eval/datasets/    # raw/Agent Case/Ground Truth data
/data/edison/piagent-itbench-eval/runs/       # historical runs
```

These data and run directories are not bidirectionally mirrored by Git and must not be overwritten during a code sync. Deploying a newly committed `evaluation/` or Skill into the outer runtime workspace is a separate, reviewed operation; use a dry-run and never use `rsync --delete`.
