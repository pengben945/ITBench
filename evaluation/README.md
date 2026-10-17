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

### Pi-Agent 原生与用户排查知识对照

新的成对对照使用固定批次：

- `v6-pi-native`（看板显示“Pi-Agent 原生”）：Pi 默认系统提示 + 中性 Case 任务。
- `v6-user-knowledge`（看板显示“用户排查知识增强”）：相同 Pi 默认系统提示、Case 任务契约、Schema、工具和沙箱，额外在 user prompt 中提供排查知识。

两组只改变用户提供的排查知识。旧批次 `v6-user-full`、`v6-user-minimal` 和 `v6-system` 保留历史标签，不映射到新对照，以免把不同 Prompt 条件混为一谈。

在已准备 Case 的评测工作区中运行一组对照：

```bash
PI_EVAL_PROVIDER=deepseek \
PI_EVAL_MODEL=deepseek-v4-flash \
PI_EVAL_THINKING=high \
evaluation/scripts/run_case_comparison_v6.sh Scenario-1
```

脚本先对两组运行执行 Bubblewrap 预检，再顺序调用模型。完成后按 `evaluation/schemas/run-score-v1.schema.json` 分别评分，并登记到看板：

```bash
python3 evaluation/scripts/register_scored_run.py runs/Scenario-1/run-NNN
```

批量比较两个 Castrel 模型时，可先检查计划，再启动前台串行批次：

```bash
evaluation/scripts/trigger_case_comparison_batch_v6.sh --count 20 --dry-run
evaluation/scripts/trigger_case_comparison_batch_v6.sh --count 20
```

`--count` 可设为 20–30，默认 20。脚本按 `Scenario-N` 数字顺序，从已有且有 SHA-256 manifest 的 Agent Cases 中选择指定数量；不会准备或覆盖 Case，也不会访问 Ground Truth。每个 Case 分别使用 `castrel-qwen38-27b-base` 和 `castrel-qwen38-27b-v003-1-lora-v001`，每个模型都依次运行 `v6-pi-native` 和 `v6-user-knowledge`，provider 使用对应模型 ID，thinking level 固定为 `high`，数据 revision 固定为 `76df38a82288f75ba9e41dc8c515033332497473`。默认 20 Case 共 80 次模型运行，并发为 1；脚本保持前台直到批次结束，并在远端 `runs/batch-launches/` 保存计划、结果和逐比较日志。运行时会显示当前 Case、cohort、模型和 Pi session name（格式为 `Scenario-N-run-NNN`）。失败比较会记录并继续后续比较，最终以非零状态报告失败；不会自动重试、评分或登记。

脚本只调用已部署的远端 runner，不同步或改写远端代码。运行前会验证远端 Git 来源、代码副本、Case 隔离及 SHA-256 manifest 存在；若准备好的 Case 不足指定数量或 run ID 不足，会在任何模型调用前退出。

看板只显示两个聚合显示组：`v6-pi-native` 合并展示 `v6-pi-native` 与历史 `v6-user-minimal`（及最小 UserMessage 别名）；`v6-user-knowledge` 合并展示 `v6-user-knowledge` 与历史 `v6-user-full` / UserMessage 别名。该规则仅用于页面过滤、分组和重新计算统计，API、run 目录及 `model_config.json` 中的原始批次 ID 均不改写；详细记录中保留原始批次。历史最小/完整提示使用自定义控制 system prompt，与新版 Pi 默认提示条件不同，因此合并均值是展示聚合，不能解释为同一提示条件下的严格对照。Review-only 记录仍显示但不计正式均分；不在两组映射表中的批次（如 `v6-system`）不显示。

显示映射同时覆盖已登记的历史别名；两个 Neohorse `review-only` 批次继续归入知识增强显示组，原批次名保留，人工复核记录不计入正式均分。映射不会修改历史 run 的提示快照、批次字段或评分文件。

看板两个显示名为“Pi-Agent 原生”和“用户排查知识增强”；详细记录可查看原始批次。模型下拉框从 Pi-Agent 的 `~/.pi/agent/models.json` 实时读取唯一模型 ID 和显示名，选项只显示模型名称（未配置名称时回退到模型 ID），筛选使用模型 ID。默认读取看板进程用户的 Home 目录，也可用 `PI_AGENT_MODELS_FILE` 指定其他路径。API 不返回配置中的认证字段。Pi-Agent 跳转按钮使用看板顶部配置的 URL 模板，必须填入部署环境实际支持的路由并包含 `{session}`；不要假设 WebUI 链接格式。

显示聚合对所有模型生效，模型下拉框可将统计限定到单一模型；历史批次映射只改变页面分组，不修改原始 batch、Prompt 快照或 `score.json`。

每次运行都保留新的 run ID。协议无效或诊断无效的记录照常登记，但不能带有效诊断分数。Ground Truth 仅供评分使用，绝不能提供给被评测的 Pi-Agent。

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
│   ├── sre_diagnosis_v6.md
│   ├── sre_diagnosis_v6_pi_native.md
│   └── sre_diagnosis_v6_user_knowledge.md
├── schemas/
│   ├── diagnosis-v1.schema.json
│   ├── diagnosis-v2.schema.json
│   ├── diagnosis-v3.schema.json
│   └── run-score-v1.schema.json
├── run-configs/
│   ├── sre-v1.json
│   ├── sre-v2.json
│   ├── sre-v3.json
│   ├── sre-v4.json
│   ├── sre-v5.json
│   └── sre-v6.json
├── scoring/
│   └── sre-v2-rubric.md
├── dashboard/
│   ├── index.html
│   ├── server.py
│   └── test_server.py
└── scripts/
    ├── prepare_scenario_v2.sh
    ├── run_scenario_v1.sh
    ├── run_scenario_v2.sh
    ├── run_scenario_v3.sh
    ├── run_scenario_v4.sh
    ├── run_scenario_v5.sh
    ├── run_scenario_v6.sh
    ├── run_scenario_v6_pi_native.sh
    ├── run_scenario_v6_user_knowledge.sh
    ├── run_case_comparison_v6.sh
    ├── trigger_case_comparison_batch_v6.sh
    ├── register_scored_run.py
    ├── test_register_scored_run.py
    └── summarize_run.py
```

The dashboard implementation and a focused registration/API test live in `evaluation/dashboard/`.

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
