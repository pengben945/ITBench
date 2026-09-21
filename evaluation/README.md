# PiAgent ITBench 评测流程

本目录保存可提交和复用的 Prompt、Schema 与运行脚本。原始数据、Agent 可见副本、Ground Truth、运行输出和报告不应提交到普通 Git。

## V1/V2/V3/V4/V5/V6 对照设计

### V1：最小基线

- 不使用 Bubblewrap 沙箱。
- 只开放 Pi 内置只读工具 `read`、`grep`、`find`、`ls`。
- Prompt 只提供工作目录、排查根因任务和 V1 JSON 输出结构，不提供调查路径。
- 目的：观察模型在最少引导下的自发检索和归因能力。

### V2：结构化排障

V2 将事故结论拆分为：

```text
触发源 → 技术瓶颈 → 故障传播 → 用户症状
```

Agent 必须按照“系统指标 → 请求维度 → 用户/租户 → 配置/发布 → 业务事件”完成覆盖检查，并在最终 JSON 中提供调查步骤、候选假设、统一时间线和证据引用。

V1 → V2 同时改变 Prompt、工具和隔离策略，因此评估的是“整套工作流升级”，不能将差异只归因于 Prompt。

### V3：抽象化 Prompt 对照

V3 保持 V2 的模型、工具、Bubblewrap 隔离和 `diagnosis-v2.schema.json` 不变，只将诊断提示改为抽象目标：

- 模型根据上下文自主识别数据源、查询工具和访问方式。
- 模型自主决定调查顺序，不强制五层路径或 Case 特定问题。
- 不在 Prompt 中规定调查原则、禁止项或最终回答的具体输出方式。
- Schema 以只读文件挂载到 `/instructions/diagnosis-v2.schema.json`，不再将完整 JSON 结构复制进任务提示词。

V2 → V3 用于尽量隔离评估“结构化调查 Prompt”与“抽象化自主调查 Prompt”的效果差异。

### V4：抽象目标与因果分层

V4 保留 V3 的自主调查方式，但增加三项最小约束：

- 使用“触发源 → 技术瓶颈 → 故障传播 → 用户症状”区分归因层级，不以信号显著程度代替因果优先级。
- 综合定量关系、时间、拓扑和反事实检验触发候选。
- 明确要求校验诊断 JSON，并将 JSON 本体作为最终消息输出。

缺少历史基线或直接证据时，V4 允许保留推断候选，但必须降低置信度并声明不确定性与验证方法。

### V5：精简因果发现

V5 保留 V4 的调查与归因原则，将最终输出精简为 `summary`、`findings`、`causal_chain`、`evidence` 和 `actions` 等八个顶层字段。触发源、技术瓶颈、故障传播、用户症状和备选解释统一表示为带角色的 finding，避免在多个字段中重复描述同一结论。

### V6：变化结论证据门槛

V6 保留 V5 的精简输出结构，并要求任何“发生变化”的结论必须由前后状态或变更事件支持；只有当前状态时，只能归因为条件不匹配或候选触发源。

## 文件

```text
evaluation/
├── prompts/
│   ├── sre_system_v1.md
│   ├── sre_diagnosis_v1.md
│   ├── sre_system_v2.md
│   ├── sre_diagnosis_v2.md
│   ├── sre_system_v3.md
│   ├── sre_diagnosis_v3.md
│   ├── sre_system_v4.md
│   ├── sre_diagnosis_v4.md
│   ├── sre_system_v5.md
│   ├── sre_diagnosis_v5.md
│   ├── sre_system_v6.md
│   └── sre_diagnosis_v6.md
├── schemas/
│   ├── diagnosis-v1.schema.json
│   ├── diagnosis-v2.schema.json
│   └── diagnosis-v3.schema.json
├── run-configs/
│   ├── sre-v1.json
│   ├── sre-v2.json
│   ├── sre-v3.json
│   ├── sre-v4.json
│   ├── sre-v5.json
│   └── sre-v6.json
├── scoring/
│   └── sre-v2-rubric.md
└── scripts/
    ├── prepare_scenario_v2.sh
    ├── run_scenario_v1.sh
    ├── run_scenario_v2.sh
    ├── run_scenario_v3.sh
    ├── run_scenario_v4.sh
    ├── run_scenario_v5.sh
    ├── run_scenario_v6.sh
    └── summarize_run.py
```

## 准备 Case

在服务器评测项目根目录执行：

```bash
evaluation/scripts/prepare_scenario_v2.sh Scenario-1
```

脚本会先执行 rsync dry-run，然后复制除 `ground_truth.yaml` 之外的数据，并检查文件数量、软链接和 Ground Truth 泄漏。

## 检查沙箱

检查不会调用模型，也不会创建正式 run：

```bash
evaluation/scripts/run_scenario_v2.sh Scenario-1 run-004 --check-only
evaluation/scripts/run_scenario_v3.sh Scenario-1 run-007 --check-only
```

检查内容包括：

- Case 数据可读；
- `/work` 可写；
- Ground Truth 路径不可见；
- Pi 可以在 Bubblewrap 中启动。

## 运行

V1 最小基线：

```bash
evaluation/scripts/run_scenario_v1.sh Scenario-1 run-005 --check-only
evaluation/scripts/run_scenario_v1.sh Scenario-1 run-005
```

V2 结构化排障：

```bash
evaluation/scripts/run_scenario_v2.sh Scenario-1 run-004
```

V3 抽象化 Prompt 对照：

```bash
evaluation/scripts/run_scenario_v3.sh Scenario-1 run-007 --check-only
evaluation/scripts/run_scenario_v3.sh Scenario-1 run-007
```

V4 抽象因果分层对照：

```bash
evaluation/scripts/run_scenario_v4.sh Scenario-1 run-008 --check-only
evaluation/scripts/run_scenario_v4.sh Scenario-1 run-008
```

V5 精简输出结构对照：

```bash
evaluation/scripts/run_scenario_v5.sh Scenario-1 run-009 --check-only
evaluation/scripts/run_scenario_v5.sh Scenario-1 run-009
```

V6 变化结论证据门槛对照：

```bash
evaluation/scripts/run_scenario_v6.sh Scenario-1 run-010 --check-only
evaluation/scripts/run_scenario_v6.sh Scenario-1 run-010
```

默认配置：

```text
provider: deepseek
model: deepseek-v4-flash
thinking: high
tools: read, grep, find, ls, bash
```

可通过环境变量覆盖模型配置：

```bash
PI_EVAL_PROVIDER=deepseek \
PI_EVAL_MODEL=deepseek-v4-flash \
PI_EVAL_THINKING=high \
evaluation/scripts/run_scenario_v2.sh Scenario-1 run-004
```

运行 V3/V4/V5/V6 时使用相同的环境变量，并保持与 V2 相同的 provider、model 和 thinking level。

V2/V3/V4/V5/V6 的每个 run 使用独立的 `work/`，不得复用其他轮次的中间文件。Agent 输入只读，Ground Truth 和其他 Case 不进入沙箱。最终输出由外层 Runner 从标准输出保存并执行 JSON Schema 校验。

## 调查记录

保留三类记录：

1. `raw_output.jsonl`：Pi 原始事件、工具调用、工具结果和模型 reasoning。
2. `answer.json`：稳定、可评分的调查步骤、假设、证据链和最终结论。
3. `metrics.json`：耗时、工具调用、token/cache 用量、输出大小和会话 ID。

分析时优先使用结构化的 `answer.json`；`raw_output.jsonl` 用于审计 Agent 是否真正执行了对应查询。
