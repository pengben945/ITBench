# Curated SRE Fine-Tuning Data

Use this workflow when turning evaluated Pi-Agent runs into supervised fine-tuning
or preference data. A successful run is not automatically a good training example:
selection must consider official root-cause accuracy, evidence quality, protocol
validity, and investigation efficiency independently.

## Data separation

- The model may see only the prepared `datasets/agent_cases/Scenario-N/`, its
  assigned prompt/schema, and that run's `/work`. Ground Truth is scoring-only.
- Keep scores, selection decisions, reviewer notes, canonical labels, and coaching
  metadata in a sidecar manifest, never in model-visible conversations.
- Preserve the original `raw_output.jsonl` and run artifacts as immutable audit
  records. An edited or coached trajectory is a separate candidate with a clear
  link to its source run.
- Do not include secrets, prior-run sessions, unrelated Cases, or evaluator files
  in exported conversations or observations.

## Selection gates

Apply these gates in order and record a pass/fail reason for every run.

### 1. Protocol and diagnosis eligibility

A candidate must have a successful runner exit, parseable final JSON that matches
`answer.json`, a valid V3 schema, the required `/work/diagnosis.json`, complete
run metadata, and an auditable input manifest. Confirm that the cited evidence
was actually retrieved in `raw_output.jsonl` and that no Ground Truth was exposed.
Infrastructure- or protocol-invalid runs are retained for failure analysis, not
positive diagnosis SFT.

### 2. Positive diagnosis SFT

Use the following initial high-quality threshold; it is a project data-curation
policy, not an official ITBench metric:

- `official_gt_score == 1.0` (all official root causes recalled with no false
  positives);
- `evidence_quality_score >= 85/100`; and
- minimum core subscores: trigger identification `>= 20/25`, causal propagation
  `>= 12/15`, temporal consistency `>= 8/10`, and evidence quality `>= 12/15`.

The evidence score is a human-audited rubric. Record all nine subscores and a
case-specific rationale; do not infer a pass from the total alone. A reviewer must
also verify entity normalization, evidence paths/timestamps/values, causal
direction, and that the conclusion does not overstate what the Case supports.
Thresholds may be changed for a new dataset release, but must be versioned and
applied consistently to the whole release.

### 3. Keep other outcomes separate

- Full official score with low evidence quality is not a positive high-quality
  diagnosis example.
- High evidence quality with an official miss is useful for error analysis, but
  its final diagnosis must not be labeled as an official-correct SFT target.
- Invalid diagnoses and infrastructure failures belong in a diagnostic/rejection
  report, not in the positive dataset.
- Coached runs are marked `coached=true`, retain every intervention, and are
  reported separately from one-shot runs. They may enter a separately versioned
  coached-SFT subset only after the same validity, scoring, and evidence review.

## Reduce redundant tool use without teaching under-investigation

Do not impose one global maximum tool-call count: Cases differ in size and
complexity. Compare runs within the same Case and identify calls as redundant
only when they repeat the same query scope without adding evidence, narrowing a
hypothesis, or validating a conclusion. Record total calls, repeated/no-new-
evidence calls, tokens, elapsed time, and the evidence gained at each useful
step.

Prefer trajectories on the quality/efficiency Pareto frontier: do not trade away
root-cause recall, causal support, or evidence quality just to reduce calls.
Where a high-scoring trajectory is verbose, curate only after verifying that
removed actions do not carry unique evidence or necessary uncertainty checks.
Teach an explicit stop rule: once independent evidence supports the causal chain
and alternatives have been checked sufficiently, synthesize and stop querying.

## Training products and format

The current exporter, `evaluation/scripts/export_sharegpt.py`, emits
LLaMA-Factory ShareGPT JSONL records:

```json
{
  "id": "Scenario-N-run-NNN-full-000",
  "conversations": [
    {"from": "system", "value": "..."},
    {"from": "human", "value": "..."},
    {"from": "function_call", "value": "{\"name\":\"grep\",\"arguments\":{}}"},
    {"from": "observation", "value": "..."},
    {"from": "gpt", "value": "..."}
  ],
  "tools": "[{\"name\":\"read\", ...}]"
}
```

Keep the LLaMA-Factory `conversations` roles and JSON-string `tools` field
compatible. Store scores and curation metadata in a separate `manifest.jsonl`;
never add Ground Truth labels or reviewer-only metadata to `conversations`.

The exporter currently creates three views:

- `sharegpt_full.jsonl`: one full trace per run; retain for audit and use for
  trajectory learning only after redundancy review.
- `sharegpt_steps.jsonl`: one sample per tool-decision step; do not train on all
  raw steps by default, because long runs would be oversampled and repeated
  actions would teach the model to over-call tools.
- `sharegpt_final.jsonl`: investigation context followed by the final diagnosis.
  Verify that the context contains retrieved evidence, not just a list of tool
  names/arguments. A mechanical action digest is not sufficient evidence context.

For an initial SFT release, create two deliberately curated targets:

1. **Tool decision / stopping** — current task plus the concise, already observed
   evidence needed to choose one useful next action or to stop and synthesize.
   Include only steps that add information or perform a meaningful verification.
2. **Evidence-to-diagnosis** — a compact, source-linked evidence bundle followed
   by the validated final diagnosis JSON.

Keep a full trajectory as an audit/reference product. Do not blindly train on
full, every step, and final samples from the same run together; that multiplies
the influence of long trajectories. If chosen/rejected preference pairs are
later created, place them in a separate DPO dataset with explicit pair IDs and
review reasons; never mix rejected answers into positive SFT targets.

The current exporter converts selected run directories; it does not implement
the score gates above. Build the selection manifest first, export only approved
run IDs, and verify record counts, final-answer equality, tool/output integrity,
and Ground Truth leakage checks before publishing a dataset version.

## Provenance, split, and release checks

Each selection-manifest entry should include at least:

- source Case, run ID, session ID, and source trajectory path/hash;
- provider, model ID, thinking level, prompt version/hash, schema version/hash,
  Pi version, and dataset revision;
- protocol/diagnosis validity, official score, all nine evidence subscores and
  total, TP/FP/FN, and reviewer rationale;
- tool-call count, repeated/no-new-evidence count, tokens, duration, retry count,
  coaching flag/interventions, selection decision, and rejection reason.

Split by `Scenario-N`, never by individual run or generated sample, so runs from
one Case cannot leak across train/validation/test. Use a distinct held-out
scenario set for final evaluation; if the available Cases are too few for a
meaningful split, report that limitation instead of claiming generalization.
Version the score thresholds, source revision, selected run IDs, exporter version,
and hashes with each dataset release.
