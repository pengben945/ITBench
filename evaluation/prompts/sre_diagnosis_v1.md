工作目录是 `{{CASE_DIR}}`，其中包含本次事故的告警、Kubernetes Events/Objects、指标、日志和调用链数据。

请使用已提供的内置只读工具 `read`、`grep`、`find`、`ls` 排查 `{{SCENARIO_ID}}` 的故障根因。

最终 JSON 必须作为本会话最后一条 Assistant 消息完整输出，以便在 WebUI 前端直接渲染。最终回答只能是一个合法 JSON 对象，不要使用 Markdown 代码块，也不要在 JSON 前后添加解释。必须符合 `diagnosis-v1.schema.json`，结构如下：

{
  "schema_version": "1.0",
  "scenario_id": "{{SCENARIO_ID}}",
  "diagnosis_status": "resolved 或 insufficient_evidence",
  "summary": "简明故障结论",
  "root_cause": {
    "kind": "Kubernetes资源类型或Service；无法确定时为null",
    "name": "根因实体名称；无法确定时为null",
    "namespace": "命名空间；无法确定时为null",
    "condition": "具体异常状态或错误配置；无法确定时为null",
    "mechanism": "该异常如何导致故障；无法确定时为null"
  },
  "affected_entities": [
    {"kind": "实体类型", "name": "实体名称", "impact": "受到的影响"}
  ],
  "timeline": [
    {"timestamp": "原始数据中的时间；不存在时为null", "event": "关键变化"}
  ],
  "evidence": [
    {
      "source_type": "alert、k8s_event、k8s_object、metric、log或trace",
      "file": "工作目录下的相对文件路径",
      "timestamp": "证据时间；不存在时为null",
      "observation": "可以从文件复核的客观事实",
      "supports": "该事实支持的判断"
    }
  ],
  "propagation": [
    {"source": "上游原因或实体", "target": "下游实体", "effect": "传播产生的影响"}
  ],
  "recommended_actions": [
    {"action": "修复动作", "verification": "修复后验证方式"}
  ],
  "confidence": 0.0,
  "uncertainties": []
}

`confidence` 必须是 0 到 1 之间的数字。
