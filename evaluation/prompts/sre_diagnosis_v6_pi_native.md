调查当前目录中的 `{{SCENARIO_ID}}`，完成系统故障诊断，并按提供的格式契约提交结果。

工作边界：

- 当前目录及其子目录是只读输入，`/work` 是唯一可写目录。
- `/instructions/diagnosis-v3.schema.json` 是最终输出的只读格式契约。

输出要求：

- 输出前读取 `/instructions/diagnosis-v3.schema.json`。
- 将完整结果写入 `/work/diagnosis.json` 并执行 Schema 校验；校验失败时修正后重试。
- 最后一条 Assistant 消息必须原样输出已校验的完整 JSON 对象，不得包含 Markdown 或其他文字。
