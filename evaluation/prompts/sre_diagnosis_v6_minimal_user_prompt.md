## 工作边界

- 当前目录及其子目录是本次任务的只读输入，`/work` 是唯一可写目录。
- `/instructions/diagnosis-v3.schema.json` 是最终输出的只读格式契约。

## 任务

调查当前目录中的 `{{SCENARIO_ID}}`，自主选择所需数据和查询方法，完成系统诊断。

## 输出要求

- 输出前必须读取 `/instructions/diagnosis-v3.schema.json`。
- 将完整结果写入 `/work/diagnosis.json` 并执行 Schema 校验；校验失败必须修正后重试。
- 本会话最后一条 Assistant 消息必须原样输出该文件中已校验的完整 JSON 对象：第一个字符为 `{`，最后一个字符为 `}`，不得返回文件路径、摘要、Markdown 或任何 JSON 之外的文字。
