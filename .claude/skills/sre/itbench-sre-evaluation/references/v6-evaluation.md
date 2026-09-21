# V6 Run and Evaluation

## Baseline Files

V6 uses the following files together:

```text
evaluation/prompts/sre_system_v6.md
evaluation/prompts/sre_diagnosis_v6.md
evaluation/schemas/diagnosis-v3.schema.json
evaluation/run-configs/sre-v6.json
evaluation/scripts/run_scenario_v6.sh
evaluation/scoring/sre-v2-rubric.md
```

The system prompt gives the role, abstract investigation goal, causal-layer distinction, evidence rules, and the V6 change-evidence gate. The task prompt requires the complete validated JSON as the final Assistant message and requires `/work/diagnosis.json`. The schema's top-level contract is `schema_version`, `scenario_id`, `status`, `summary`, `findings`, `causal_chain`, `evidence`, and `actions`.

## Run Procedure

Use a new `run-NNN` for every attempt, including retries. Set the provider, model, and thinking level explicitly:

```bash
PI_EVAL_PROVIDER=<provider> \
PI_EVAL_MODEL=<model> \
PI_EVAL_THINKING=<level> \
evaluation/scripts/run_scenario_v6.sh Scenario-N run-NNN --check-only
```

Only after the preflight succeeds:

```bash
PI_EVAL_PROVIDER=<provider> \
PI_EVAL_MODEL=<model> \
PI_EVAL_THINKING=<level> \
evaluation/scripts/run_scenario_v6.sh Scenario-N run-NNN
```

The preflight must establish that the Case is readable but not writable, `/work` is writable, the schema is read-only, Ground Truth/raw data/other Cases are not visible, and Pi authentication/startup works. The formal runner refuses to overwrite an existing run.

For remote execution, first verify the remote workspace and disk state specified by the project instructions, then run from `/data/edison/piagent-itbench-eval`. Do not assume local and remote datasets are identical. Do not print API keys, auth files, proxy credentials, or private configuration.

## Run Artifacts

Inspect the complete `runs/Scenario-N/run-NNN/` directory. A normal run contains:

- `raw_output.jsonl`: original Pi events, tool calls, tool results, and assistant messages;
- `answer.json`: extracted final Assistant JSON;
- `metrics.json`: tool, token/cache, duration, output, and session metrics;
- `model_config.json`: provider/model/thinking and sandbox metadata;
- `system_prompt.txt`, `prompt.txt`, and a schema snapshot;
- `input-manifest.sha256`, `started_at.txt`, `finished_at.txt`, `exit_code.txt`, `session_id.txt`, and `stderr.log`;
- `work/diagnosis.json` when the Agent follows the output contract.

If the runner fails after preserving artifacts, analyze the failure boundary. A missing or invalid `answer.json`, absent `work/diagnosis.json`, tool-protocol error, schema error, or nonzero exit status is a result-quality failure even if some useful tool output exists.

## Diagnosis Assessment

Read `answer.json` and use `raw_output.jsonl` to verify that the cited evidence was actually retrieved. Validate:

1. JSON parsing, V3 schema, finding/causal/evidence/action ID integrity, and exact final-message format.
2. Evidence file paths, entities, timestamps, values, and event claims against the Agent-visible Case.
3. Causal direction and temporal ordering; do not accept a symptom or downstream bottleneck as the trigger without supporting evidence.
4. Coverage of available signal families and sensible bounded queries rather than unsupported claims from a tiny sample.
5. Separation of observation, inference, uncertainty, alternatives, and verification steps.

The causal analysis should distinguish:

```text
trigger source -> technical bottleneck -> failure propagation -> user symptom
```

This is an abstract attribution structure, not a requirement to invent a trigger when the data only supports a current condition. For a change claim, require before/after state or a change event. Current state alone can support a condition mismatch or candidate trigger with appropriate uncertainty.

## Scoring Rubric

Apply `evaluation/scoring/sre-v2-rubric.md` as a 100-point rubric:

| Dimension | Points |
| --- | ---: |
| Trigger identification | 25 |
| Technical bottleneck | 10 |
| Causal propagation | 15 |
| Temporal consistency | 10 |
| Evidence quality | 15 |
| Investigation coverage | 10 |
| Competing hypotheses | 5 |
| Repair and verification | 5 |
| Output and reproducibility | 5 |

Report two tracks independently:

- `ground_truth_match`: strict match to the official root-cause entities, conditions, and propagation;
- `evidence_quality`: whether the diagnosis is supported by the Case data, independent of official labels.

Use the failure categories `DATA`, `PARSING`, `RETRIEVAL`, `REASONING`, `ENTITY`, `OUTPUT`, `INFRA`, and `GRADER`. A missing historical baseline or ambiguous official label is a data/grader limitation, not automatically a model failure. A service tool-call/parser mismatch is an infrastructure/protocol failure; do not grade it as causal reasoning until a valid run is available.

Always report case-level evidence alongside aggregate scores. Include root-cause recall, false positives, evidence quality, propagation completeness, tool calls, processed data volume, tokens/cache, duration, retries, and infrastructure success.

## Tracker Entry

Append to `evaluation/reports/model-evaluation-tracker.md` without rewriting prior entries. Use this compact structure:

```text
模型：
run / session：
Prompt / Schema / 数据 revision：
运行是否有效：
关键证据是否找到：
触发源 / 技术瓶颈 / 传播链：
反证与不确定性：
虚构或事实错误：
Schema / 工作文件：
工具调用 / Token / 耗时 / 重试：
失败分类：
因果等级：
是否进入微调候选：
建议训练重点：
```

Use the tracker as a longitudinal record: preserve failed and infrastructure-invalid runs, mark them as such, and do not compare them as valid diagnosis accuracy. A retry is a new record with a new run ID.
