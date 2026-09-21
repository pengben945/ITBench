# AGENTS.md

本文件约束在本仓库工作的自动化 Agent。目标是保证本地开发、远端评测、代理使用和大规模数据同步安全、可复现。

## 项目目标

本项目不是单纯运行一次 benchmark，而是系统研究 ITBench 与 PiAgent 的完整故障排查链路。所有分析、实现和实验必须服务于以下目标：

1. 理解 ITBench 的故障注入流程：应用如何部署、故障如何注入、等待条件如何触发、观测数据如何采集、Ground Truth 如何生成，以及环境如何恢复。
2. 理解 ITBench-AA 测试数据集：每类文件的来源、结构、时间范围、实体关联、可见证据、标准答案和数据泄漏边界。
3. 评估 PiAgent 的真实排障效果：是否找对根因、证据是否充分、因果链是否成立、是否误报下游症状，以及排障成本和稳定性如何。
4. 定位效果不佳的具体环节：区分数据缺失、数据解析、证据检索、假设生成、因果归因、实体命名、输出格式、模型调用、沙箱、评分器等不同失败来源。
5. 提出并验证改进方案：通过数据索引、查询工具、Prompt、工作流、上下文控制、重试机制、评分与报告等手段改善结果。

最终应形成可复现的研究结论，而不只是一个总分。至少应产出：

- ITBench 故障注入与数据采集流程说明。
- 数据集字段、文件类型、场景和 Ground Truth 的映射说明。
- 每场景、每 trial 的诊断结果、证据、评分和耗时。
- 失败案例及其所属环节的分类。
- PiAgent 能力边界、主要问题和有证据支持的改进建议。
- 改进前后的对照实验结果。

### 故障注入流程分析范围

分析上游 ITBench 时，重点追踪下列代码和配置之间的关系：

- 场景定义及 Ground Truth：`scenarios/sre/project/roles/scenarios/files/scenario_*`
- 故障调度入口：`scenarios/sre/project/manage_faults.yaml`
- 故障实现：`scenarios/sre/project/roles/faults/`
- 等待和状态确认：`scenarios/sre/project/roles/waiters/`
- 日志、指标、链路和拓扑采集：`scenarios/sre/tools/`
- 场景索引及说明：`scenarios/sre/library/`、`documentation/library/scenarios/`

对每个场景至少回答：注入了什么、注入到哪个 Kubernetes 实体、何时注入、产生了哪些直接症状、如何传播、哪些观测数据能够证明根因、Ground Truth 如何表达这些关系。

### PiAgent 效果分析原则

不能把所有失败都归因于模型。每次失败必须归入一个或多个明确环节：

- `DATA`：数据缺失、损坏、时间窗口不完整或 Ground Truth 泄漏。
- `PARSING`：TSV、嵌套 JSON、指标或 Trace 解析错误。
- `RETRIEVAL`：没有找到已有的关键证据，或被超大文件和输出截断干扰。
- `REASONING`：发现证据但因果判断错误，将症状或中间节点当成根因。
- `ENTITY`：根因概念正确，但 namespace、Kind、name 或别名归一化错误。
- `OUTPUT`：JSON 或 Schema 不合法、文件未生成。
- `INFRA`：代理、限流、超时、进程、依赖或沙箱故障。
- `GRADER`：实体归一化或评分逻辑与 Ground Truth 不一致。

评估至少包含：根因召回、误报数量、证据质量、传播链完整性、工具调用次数、处理数据量、token 用量、耗时、重试次数和基础设施成功率。汇报时必须同时给出案例证据与聚合指标，禁止只给平均分。

## 项目与环境

- 本地仓库：`/Users/Edison/ITBench`
- 远端服务器：`10.106.3.100`
- SSH 用户：`root`
- SSH 身份文件：`~/.ssh/id_ed25519`
- 远端工作区：`/data/edison/piagent-itbench-eval`
- 大数据盘：`/data`

标准 SSH 入口：

```bash
ssh -i ~/.ssh/id_ed25519 -o IdentitiesOnly=yes root@10.106.3.100
```

服务器最近确认的基础环境：

- Ubuntu 24.04 LTS
- 系统 Python 3.12；评测项目要求 Python 3.13
- Node.js v24.16.0
- Pi v0.85.1
- Bubblewrap v0.9.0
- `uv` 位于 `/root/.local/bin/uv`，非交互 SSH 中可能不在 `PATH`

PiAgent 已安装在服务器上。默认直接使用服务器现有的 `pi`，运行前通过 `pi --version` 记录版本；除非用户明确要求，不得重复安装、卸载或升级 PiAgent。实验期间必须冻结 PiAgent、provider、model、thinking level、Prompt 和数据集 revision，避免无法比较不同批次结果。

远程执行 Python 项目前先使用：

```bash
export PATH="/root/.local/bin:$PATH"
```

不要假设远端目录内容与本地一致。每次操作前必须先检查：

```bash
ssh -i ~/.ssh/id_ed25519 -o IdentitiesOnly=yes root@10.106.3.100 \
  'hostname; df -h /data; du -sh /data/edison/piagent-itbench-eval 2>/dev/null; find /data/edison/piagent-itbench-eval -mindepth 1 -maxdepth 1 -printf "%f\n" | sort'
```

## Mihomo 代理

服务器使用 Mihomo：

- systemd 服务：`mihomo.service`
- 程序：`/usr/local/bin/mihomo`
- 主配置：`/etc/mihomo/config.yaml`
- 运行数据：`/var/lib/mihomo`
- HTTP/SOCKS 混合端口：`127.0.0.1:7890`
- REST 控制器：`127.0.0.1:9090`
- DNS：`127.0.0.1:1053`
- 主策略组：`飞鸟云`
- 服务只监听本机，不允许 LAN 访问。

服务已配置为开机启动。只读检查命令：

```bash
systemctl status mihomo --no-pager
systemctl is-enabled mihomo
ss -lntup | grep -E ':(7890|9090|1053)\b'
journalctl -u mihomo -n 50 --no-pager
```

只有用户明确要求改变服务状态时，才可以执行：

```bash
systemctl start mihomo
systemctl stop mihomo
systemctl restart mihomo
systemctl enable --now mihomo
```

### 为当前 Shell 开启或关闭代理

服务运行不代表当前 Shell 自动使用代理。服务器没有全局 `HTTP_PROXY`/`HTTPS_PROXY` 配置。
Mihomo 当前也没有启用 TUN/透明代理，因此仅启动服务或切换节点，不会让已有的 Git、Python、`curl`、`wget` 等进程自动使用代理。代理环境变量必须在启动目标进程之前设置；切换节点后，必要时重新启动已有下载进程以建立新连接。

开启：

```bash
export http_proxy=http://127.0.0.1:7890
export https_proxy=http://127.0.0.1:7890
export all_proxy=socks5h://127.0.0.1:7890
export no_proxy=127.0.0.1,localhost,10.106.3.100
```

关闭：

```bash
unset http_proxy https_proxy all_proxy HTTP_PROXY HTTPS_PROXY ALL_PROXY no_proxy NO_PROXY
```

验证时必须分别测试直连和代理，避免把服务存活误判为节点可用：

```bash
curl -I --connect-timeout 8 https://huggingface.co
curl -I --proxy http://127.0.0.1:7890 --connect-timeout 8 https://huggingface.co
```

### Git 使用代理

推荐给单条 Git 命令显式指定代理，避免依赖当前 Shell 是否正确继承环境变量：

```bash
git -c http.proxy=http://127.0.0.1:7890 \
  ls-remote https://github.com/pengben945/ITBench.git HEAD

git -c http.proxy=http://127.0.0.1:7890 \
  clone https://github.com/pengben945/ITBench.git
```

也可以先导出大小写两套变量，再启动 Git：

```bash
export http_proxy=http://127.0.0.1:7890
export https_proxy=http://127.0.0.1:7890
export HTTP_PROXY="$http_proxy"
export HTTPS_PROXY="$https_proxy"

git clone https://github.com/pengben945/ITBench.git
```

不要使用 `git config --global http.proxy ...`，除非用户明确要求永久设置；全局代理在 Mihomo 停止时会导致所有 Git 网络操作失败。

### Hugging Face 下载使用代理

在启动 `hf download`、`huggingface-cli` 或 `snapshot_download` 之前导出代理变量：

```bash
export http_proxy=http://127.0.0.1:7890
export https_proxy=http://127.0.0.1:7890
export HTTP_PROXY="$http_proxy"
export HTTPS_PROXY="$https_proxy"
export HF_HUB_DISABLE_XET=1
```

`HF_HUB_DISABLE_XET=1` 让 Hugging Face Hub 使用标准 HTTP 下载路径，以便稳定继承代理设置。正式下载前先执行小请求验证：

```bash
curl -fsSI --proxy http://127.0.0.1:7890 https://huggingface.co
```

### 查看和切换节点

当前控制器只绑定 `127.0.0.1`，可在服务器本机调用。不要将 9090 端口暴露到公网。

查看主策略组当前选择和节点列表：

```bash
curl -fsS 'http://127.0.0.1:9090/proxies/%E9%A3%9E%E9%B8%9F%E4%BA%91' | python3 -m json.tool
```

切换节点使用 Mihomo REST API。下面仅是格式示例，执行前应先检查节点健康状态，不能长期假定某个节点可用：

```bash
curl -fsS -X PUT \
  'http://127.0.0.1:9090/proxies/%E9%A3%9E%E9%B8%9F%E4%BA%91' \
  -H 'Content-Type: application/json' \
  --data '{"name":"新加坡01aws"}'
```

切回自动选择：

```bash
curl -fsS -X PUT \
  'http://127.0.0.1:9090/proxies/%E9%A3%9E%E9%B8%9F%E4%BA%91' \
  -H 'Content-Type: application/json' \
  --data '{"name":"自动选择"}'
```

切换后必须再次查询策略组，并通过代理请求目标站点验证。不要仅根据 HTTP 200 的切换响应判断节点可用。

当前配置包含静态节点，没有配置 `proxy-providers`，因此不会自动更新订阅。修改配置时必须：

1. 不输出、提交或记录订阅 URL、密码、UUID、密钥等敏感信息。
2. 在临时文件中准备新配置，并保留受限权限。
3. 使用 `mihomo -t -d /var/lib/mihomo -f <candidate-config>` 校验。
4. 校验通过后才能替换 `/etc/mihomo/config.yaml` 并重启服务。
5. 重启后检查服务状态、监听端口、节点状态和实际连通性。

## 评测数据

ITBench-AA 数据来源：

- 数据集：`https://huggingface.co/datasets/ArtificialAnalysis/ITBench-AA`
- 固定 revision：`76df38a82288f75ba9e41dc8c515033332497473`
- 公开 SRE 场景数：40
- License：CC-BY-4.0

数据必须分层管理：

- `datasets/raw/`：下载的原始数据，只读使用。
- `datasets/agent_cases/`：Agent 可见的派生快照，不得包含 Ground Truth。
- `datasets/ground_truth/`：仅评分流程可读。
- `datasets/manifests/`：数据 revision、文件大小和 SHA-256，可提交 Git。
- `runs/`：原始模型事件和运行元数据。
- `outputs/`：标准化 Agent 输出。
- `reports/`：评分报告。

禁止把 `datasets/raw/`、`datasets/agent_cases/`、`datasets/ground_truth/`、`.venv/`、`runs/`、`outputs/` 或 `reports/` 提交到普通 Git。临时目录 `datasets/itbench-aa-prepare-*` 也必须忽略。

Agent 不得直接读取 Ground Truth 来生成诊断结果。数据准备流程应拒绝软链接、隔离答案文件，并对 Agent 可见文件生成 SHA-256 清单。

## 排障分析顺序

处理单个离线事故场景时遵循以下顺序：

1. 列出文件和大小，禁止直接 `cat` 大型 TSV。
2. 从 alerts 确定事故窗口、告警对象和首次触发时间。
3. 从 Kubernetes events 查找调度、拉取镜像、探针、OOM、挂载和网络异常。
4. 从 Kubernetes objects 对照 Deployment、Pod、ConfigMap、Secret、Service、NetworkPolicy 等配置与状态。
5. 使用 OTEL logs 验证错误发生的位置和时间。
6. 使用 metrics 验证异常开始时间及影响范围。
7. 使用 traces 构建上游根因到下游症状的传播链。
8. 排除告警对象、下游服务和中间故障等症状，只保留不可约的根因实体。
9. 按 JSON Schema 生成输出并校验。

TSV 中可能含引号、嵌套 JSON 和换行内容，必须使用标准 CSV/TSV 解析器并提高字段大小限制；禁止依赖简单的 `line.split("\t")` 处理所有记录。优先创建可复用的只读查询脚本，避免 Agent 每次临时编写解析代码或扫描数百 MB 文件。

## Git 与同步规则

- 现有未提交内容属于用户；不要清理、覆盖或回滚无关改动。
- 不要把远端目录当成权威 Git 工作区，除非已确认 `.git`、remote、branch 和 commit。
- 代码通过 Git 同步；大数据通过固定 revision 重新下载，或通过独立对象存储/`rsync` 同步。
- 执行 `rsync` 前必须先使用 `--dry-run --itemize-changes`。
- 未经用户明确授权，不得使用 `rsync --delete`、递归删除、覆盖远端配置或清理远端数据。
- 不同步 `.venv`；使用锁文件在目标机器重建环境。
- 不提交 `/etc/mihomo/config.yaml`、运行日志、SSH 文件或任何代理订阅信息。

推荐发布顺序：

1. 检查本地 `git status`，运行测试。
2. 提交代码、配置模板、Schema、Prompt、测试和数据 manifest。
3. 在服务器拉取明确的 commit。
4. 重建 Python 环境。
5. 下载固定 revision 的原始数据。
6. 重新生成 Agent cases 和 Ground Truth 隔离目录。
7. 校验 manifest 和场景数。
8. 执行单场景 smoke test。
9. smoke test 通过后再执行完整评测。

## 安全底线

- 默认对服务器执行只读检查。
- 不打印私钥、代理节点凭据、订阅 URL、API Key 或完整敏感配置。
- 不擅自切换节点、重启服务、删除数据或覆盖配置。
- 任何大规模同步、删除、替换或重新生成数据前，先报告源路径、目标路径、预计大小和 dry-run 结果。
- 如果远端目录大小或结构在操作过程中异常变化，立即停止写操作并向用户报告。

## V2 离线评测运行约定

V2 Prompt、Schema 和运行脚本位于：

- `evaluation/prompts/sre_system_v2.md`
- `evaluation/prompts/sre_diagnosis_v2.md`
- `evaluation/schemas/diagnosis-v2.schema.json`
- `evaluation/scripts/prepare_scenario_v2.sh`
- `evaluation/scripts/run_scenario_v2.sh`

V2 只使用 Pi 内置的 `read`、`grep`、`find`、`ls` 和 `bash`。不启用 `write`、`edit` 或第三方扩展。Bash 用于通过 Python、jq、rg、awk 等本机程序执行只读解析和聚合。

正式运行必须进入 Bubblewrap：

- 当前 `datasets/agent_cases/Scenario-*` 只读挂载。
- 当前 run 的 `work/` 是 Agent 唯一的数据分析写入目录。
- `/tmp` 使用临时文件系统。
- Ground Truth、原始数据根目录、其他 Case 和其他历史 run 不得挂载。
- 当前 Scenario 的 Pi session 目录单独挂载，以保留 WebUI 会话。
- 每个 run 使用全新的 `work/`，禁止跨轮次复用中间结果。

运行前先执行 `run_scenario_v2.sh ... --check-only`。只有沙箱确认 Case 可读、`/work` 可写、Ground Truth 不可见且 Pi 可启动后，才允许正式调用模型。

## V1/V2 对照评测

- V1 是最小基线：不使用沙箱，只开放 Pi 内置 `read`、`grep`、`find`、`ls`，Prompt 只包含工作目录、根因排查任务和 JSON 格式。
- V2 是结构化排障基线：使用 Bubblewrap、`/work` 和五层调查路径。
- V1 → V2 是整套工作流对照，不得将差异单独归因于 Prompt。
- 每次正式运行都要保存 `metrics.json`，至少比较根因命中、证据质量、工具调用数、token/cache 用量、耗时与基础设施成功率。
