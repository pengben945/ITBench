当前目录包含事件 `{{SCENARIO_ID}}` 期间采集的可观测性快照，包括告警、Kubernetes Events/Objects、指标、OpenTelemetry 日志和调用链。

请调查本次事故，并完成以下任务：

1. 识别最早可验证的故障触发源，而不仅是资源瓶颈或告警对象。
2. 分别给出触发源、技术瓶颈、传播过程和用户可见症状。
3. 按“系统指标 → 请求维度 → 用户/租户 → 配置/发布 → 业务事件”检查全部层级。
4. 建立统一时间线，并验证原因必须早于其解释的结果。
5. 对请求量、错误率、延迟和资源指标进行时间聚合，不能只根据少量样本判断趋势。
6. 保留并验证竞争假设，主动寻找反证。
7. 给出直接处理触发源的动作、缓解技术瓶颈的动作，以及各自的验证方式。
8. 在 `/work` 中保存必要的只读查询脚本和小型聚合结果；不得修改当前目录中的输入文件。

最终 JSON 必须作为本会话最后一条 Assistant 消息完整输出，以便在 WebUI 前端直接渲染；不能只写入 `/work` 或仅返回文件路径。最终回答只能是一个合法 JSON 对象，不要使用 Markdown 代码块，也不要在 JSON 前后添加解释。必须符合 `diagnosis-v2.schema.json`，主要结构如下：

{
  "schema_version": "2.0",
  "scenario_id": "{{SCENARIO_ID}}",
  "diagnosis_status": "resolved、partially_resolved 或 insufficient_evidence",
  "summary": "简明事故结论",
  "root_cause": {
    "kind": "实体类型或null",
    "name": "实体名称或null",
    "namespace": "命名空间或null",
    "trigger_type": "configuration_change、deployment_change、traffic_change、resource_failure、dependency_failure、business_event或unknown",
    "condition": "异常状态或变化；无法确定时为null",
    "mechanism": "触发机制；无法确定时为null",
    "evidence_ids": ["E1"]
  },
  "bottleneck": {
    "kind": "实体类型",
    "name": "实体名称",
    "namespace": "命名空间或null",
    "condition": "容量或资源瓶颈",
    "mechanism": "瓶颈如何影响请求",
    "evidence_ids": ["E2"]
  },
  "symptoms": [
    {
      "kind": "实体类型",
      "name": "实体名称",
      "condition": "用户可见错误或告警",
      "evidence_ids": ["E3"]
    }
  ],
  "timeline": [
    {
      "timestamp": "原始数据时间或null",
      "event_type": "trigger、bottleneck、propagation、symptom或context",
      "event": "关键事件",
      "entities": ["Kind/name"],
      "evidence_ids": ["E1"]
    }
  ],
  "evidence": [
    {
      "id": "E1",
      "source_type": "alert、k8s_event、k8s_object、metric、log或trace",
      "file": "当前目录下的相对文件路径",
      "timestamp": "证据时间或null",
      "observation": "可复核的客观事实",
      "supports": "该证据支持或反对什么判断",
      "quality": "direct或indirect"
    }
  ],
  "investigation_steps": [
    {
      "step_id": 1,
      "layer": "system_metrics、requests、users_or_tenants、configuration_or_release或business_events",
      "question": "本步骤要回答的问题",
      "hypothesis": "正在验证的假设",
      "action": "执行的查询或聚合",
      "observation": "获得的客观事实",
      "inference": "基于事实得到的有限推断",
      "next_step": "下一步验证方向或null"
    }
  ],
  "hypotheses": [
    {
      "id": "H1",
      "statement": "候选假设",
      "classification": "trigger、bottleneck、symptom或alternative",
      "status": "supported、rejected或unresolved",
      "evidence_for": ["E1"],
      "evidence_against": [],
      "missing_evidence": []
    }
  ],
  "causal_chain": [
    {
      "source": "上游原因或实体",
      "target": "下游实体",
      "effect": "传播影响",
      "evidence_ids": ["E1", "E2"]
    }
  ],
  "coverage": {
    "system_metrics": {"status": "checked或unavailable", "summary": "结论", "evidence_ids": []},
    "requests": {"status": "checked或unavailable", "summary": "结论", "evidence_ids": []},
    "users_or_tenants": {"status": "checked或unavailable", "summary": "结论", "evidence_ids": []},
    "configuration_or_release": {"status": "checked或unavailable", "summary": "结论", "evidence_ids": []},
    "business_events": {"status": "checked或unavailable", "summary": "结论", "evidence_ids": []}
  },
  "recommended_actions": [
    {
      "target": "trigger、bottleneck或symptom",
      "action": "修复动作",
      "verification": "验证方式"
    }
  ],
  "confidence": 0.0,
  "uncertainties": []
}

`confidence` 必须是 0 到 1 之间的数字。开始时先检查文件清单和时间范围，再按调查路径逐层推进。
