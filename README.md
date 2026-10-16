# CoAutoResearch 部署到 Linux 服务器（Ubuntu/Debian · SSH 隧道 · Claude Code）

本目录是一次性部署产物。目标：面板跑在 Linux 服务器上、只监听回环地址，你通过 SSH 隧道从本地浏览器访问；智能体后端用 Claude Code（Linux 上 Bash 沙箱完整可用，论文生成不需要 WSL2）。

> 版本：CoAutoResearch v2.0.1 · 目标系统 Ubuntu 22.04/24.04、Debian 12+
> 官方依据：`docs/agent-setup.md`、`docs/platforms.md`、`docs/remote-server.md`、`docs/paper-generation.md`

**两种装法，选一条即可：**

| 方式 | 产物 | 适合 |
|---|---|---|
| 直接装到宿主机 | `bootstrap.sh` + systemd 用户服务（第 1-8 节） | 最简单，论文生成开箱可用 |
| Docker | `Dockerfile` + `docker-compose.yml`（第 9 节） | 想要环境隔离、不想污染宿主机 |

⚠️ 特别说明：**本项目官方不提供 Dockerfile / 镜像**。仓库里没有任何 Docker 产物，`SECURITY.md:33` 与 `docs/remote-server.md:146` 只是把「容器」列为推荐的隔离方式。第 9 节那套是自建的。

---

## 0. 这套方案的边界（先读）

- **一个 UI 进程 = 一个可信人类 + 一组项目。** v2.0 不声称多用户、多租户隔离。多人用请一项目一进程。
- **面板能读项目文件、能拉起本地 agent 进程**，所以绝不使用 `--host 0.0.0.0` 裸奔；本方案全程只绑 `127.0.0.1`。
- 面板本身**不需要 npm install，也没有构建步骤**。
- 研究产物和数据**一律放 `~/coauto-projects`**，不要放在仓库里。
- CLI 登录**必须在服务器本机完成**，不要拷贝凭证文件。

---

## 1. 上传并运行引导脚本

在你本机（Windows 的 Git Bash / PowerShell 均可）：

```bash
# C 盘路径示例，按实际调整
scp -r D:/code/coauto-server-setup <user>@<server>:~/
```

到服务器上：

```bash
ssh <user>@<server>
cd ~/coauto-server-setup
bash bootstrap.sh                 # 面板必需依赖
# 需要论文生成（会装 1-2 GB 的 TeX）时用：
# bash bootstrap.sh --paper
```

脚本做的事：apt 基础包 → Node ≥20（不足则用 NodeSource 装 22.x）→ Python ≥3.10 检查 → 可选装 LaTeX/Poppler/`bubblewrap`+`socat` → 安装 Claude Code CLI → `git clone` 上游仓库到 `~/CoAutoResearch` → 创建 `~/coauto-projects` → 跑一次 `doctor`。

脚本**幂等**，可以重复执行；**不覆盖**已有版本、不改动 shell 配置。已存在的 `~/CoAutoResearch` 会被保留。

---

## 2. 登录 Claude Code

```bash
claude auth login
claude auth status        # 应显示已登录
```

无浏览器的服务器：按提示把打印出的链接复制到本地浏览器完成授权。

**无头环境更适合的做法**：在你本地已登录的环境里生成一个长期 OAuth token，填到服务器面板 `Settings → Agent → Claude` 的环境变量 `CLAUDE_CODE_OAUTH_TOKEN`（该变量是项目原生支持的三类 Claude 密钥之一）。这样服务器上完全不需要交互式登录。

---

## 3. 启动面板

### 先前台跑一次，确认可用

```bash
cd ~/CoAutoResearch
node bin/auto-research.js ui --projects-dir ~/coauto-projects --remote
```

`--remote` 会让你保持回环绑定、不尝试打开浏览器，并打印 SSH 端口转发指令与访问密钥。

### 需要常驻就用 systemd 用户服务

```bash
mkdir -p ~/.config/systemd/user ~/.config/coauto
cp ~/coauto-server-setup/coauto.env.example ~/.config/coauto/env
chmod 600 ~/.config/coauto/env
# 编辑 env：至少设 COAUTO_REMOTE_MODE=ssh；要从其他机器连就设 COAUTO_REMOTE_TARGET=user@host
# 想要固定访问密钥：COAUTO_REMOTE_AUTH_TOKEN=$(openssl rand -hex 32)
cp ~/coauto-server-setup/coauto-ui.service ~/.config/systemd/user/
systemctl --user daemon-reload
systemctl --user enable --now coauto-ui
journalctl --user -u coauto-ui -f        # 这里能看到 SSH 指令和访问密钥
sudo loginctl enable-linger $USER        # 让用户服务在注销后继续运行
```

`coauto-ui.service` 里的 `ExecStart=/usr/bin/node ...` 请用 `command -v node` 确认实际路径后再改。

**更简单的替代方案**：如果你不想用应用层访问密钥，可以去掉 `--remote`，改成
`node bin/auto-research.js ui --host 127.0.0.1 --port 8765 --no-open`。
此时访问控制完全依赖 SSH（能连上服务器的人才能转发端口），单用户场景下够用。官方推荐的仍是 `--remote`。

---

## 4. 从本地建立隧道并打开

```bash
ssh -N -L 8765:127.0.0.1:8765 <user>@<server>
```

浏览器打开 `http://127.0.0.1:8765`。若服务器打印的端口不是 8765（被占用时 CLI 会自动换），转发对应端口即可，例如 `-L 8766:127.0.0.1:8766`。

用 Windows 的话，Git Bash 里的 `ssh` 或 `cmd` 自带的 `ssh` 都行，命令相同。

---

## 5. 验收清单

按官方 `docs/agent-setup.md` 的要求逐项确认，**不要只看 doctor**：

1. ☐ `node bin/auto-research.js doctor` 输出中 node / python / git / claude 均为 ok（生产环境应无 `missing`）
2. ☐ 面板 URL 能打开，进程保持存活
3. ☐ 设置对话框正确识别出 Claude Code 及其登录状态（改过 CLI 或账号后点 **Refresh login and models**）
4. ☐ 在 UI 里建一个一次性测试项目，选中 Claude 后端，能正常打开
5. ☐ `Settings → Agent` 能列出模型和可用的推理档位，保存成功（**模型发现失败必须修掉，不能猜一个模型名蒙过去**）
6. ☐ 回到主研究对话，输入框可用；刷新页面后项目仍在

> `doctor` 只证明工具装上了，**不证明模型能调用**。第 3-6 项必须在浏览器里人工过一遍。
> 不要为了验证安装就去启动一次真实研究。

---

## 6. 论文链路（可选）

```bash
# 1) 先确保 Python >= 3.12、latexmk、Poppler、bubblewrap、socat 都在
python3 --version && command -v latexmk pdfinfo bwrap socat

# 2) 安装四个 pinned skills + 独立虚拟环境，并做编译与渲染冒烟测试
cd ~/CoAutoResearch
python3 templates/default/ui/paper_tools.py --setup
```

**必须看到输出里 `"smoke_test": "passed"`。**缺可执行文件、下载失败、编译失败都算没装好，不能算完成。

之后在面板里 **Manuscript → Generate paper** 走 UI 按钮生成，不要手工写稿代替测试。

为什么 Linux 上这件事很重要：`paper_export.py:339` 给 Claude 传的是
`--permission-mode dontAsk` + `sandbox.enabled/failIfUnavailable/allowUnsandboxedCommands=false`，
也就是**沙箱起不来就硬失败、且不给绕过沙箱的机会**。Linux 上 `bubblewrap`+`socat` 就绪即可通过；原生 Windows 上这一条根本不支持，所以才要 WSL2。

---

## 7. 排错

| 现象 | 原因 / 处理 |
|---|---|
| `doctor` 报 python `missing` | 自动探测失败。设 `COAUTO_PYTHON=/usr/bin/python3`（或 3.12 的路径） |
| `doctor` 报 claude `warn/missing` | `~/.local/bin` 不在 PATH。service 里已显式设置了 PATH，前台运行请 `export PATH="$HOME/.local/bin:$PATH"` |
| 启动时报后端未登录 | 在服务器上跑 `claude auth status`；未登录则 `claude auth login`（或配 `CLAUDE_CODE_OAUTH_TOKEN`） |
| 模型列表加载不出来 | 服务器连不上 `api.anthropic.com`。在 `~/.config/coauto/env` 里设 `HTTPS_PROXY`/`HTTP_PROXY` 后重启服务；代理由 agent 子进程继承 |
| 论文生成瞬间失败 | `bwrap` / `socat` 缺失，或 `paper_tools.py --setup` 未通过。补装后重跑 setup 并确认 `smoke_test: passed` |
| 端口被占用 | CLI 会自动换端口，按它打印的端口调整 `ssh -L`；或显式加 `--port 8766` |
| 注销后服务停了 | `sudo loginctl enable-linger $USER` |
| 想强制只用一个后端 | env 里设 `COAUTO_AGENT_BACKEND=claude`。注意：设了之后面板会显示提示且 UI 无法切换，移除该变量后 UI 的选择才重新生效 |

---

## 8. 安全提醒

- 隧道链接与访问密钥**不要**贴到聊天、日志、截图或共享的 shell 历史里。
- Claude 的 Bash 沙箱**默认允许读取整机**（含 `~/.ssh`、`~/.aws/credentials`），只限制写入与网络。本项目用 `--tools` 白名单 + 禁用全部 MCP + `--safe-mode` 收窄，但那是指令层约束。服务器上若有敏感凭证，建议单独建一个 OS 账号跑面板。
- 长期对外使用：保持回环绑定，前面挂 VPN / Cloudflare Access / 带鉴权的 HTTPS 反代，并配 `COAUTO_REMOTE_AUTH_TOKEN`、`COAUTO_ALLOWED_HOSTS`、`COAUTO_ALLOWED_ORIGINS`。TLS、限流、审计由你负责。

---

## 9. Docker 部署

> ⚠️ **本项目官方没有 Dockerfile、没有镜像、没有 devcontainer。** 仓库里一个 Docker 相关文件都没有（只有 `SECURITY.md`/`docs/remote-server.md` 把「容器」列为推荐的隔离方式）。本节的 `Dockerfile` + `docker-compose.yml` 是自建的。
>
> **已在真机验证（2026-10-15，Oracle Cloud arm64 / Ubuntu 22.04 / Docker 29.1.3）**：
> 镜像构建成功（arm64 无需改动）、容器 healthy、面板 `127.0.0.1:8765` 返回 200、
> SSH 隧道端到端可达、doctor 显示 `ok selected agent - claude`。
> 仍**未验证**：`WITH_PAPER=1` 的论文链路（LaTeX/Poppler/bwrap 在容器内的行为）。

> **命令风格：统一用 `docker compose`（v2 插件，空格）。**
>
> ⚠️ **`docker-compose` v1.29.2 与 Docker Engine ≥ 25 不兼容，不要用。** 实测症状：
> 改完 `.env` 后执行 `docker-compose up -d`，只要需要**重建容器**就会崩在
> `KeyError: 'ContainerConfig'`（`compose/service.py:1579 get_container_data_volumes`），
> 原因是新 Engine 的 `docker inspect` 不再返回该字段；而且它是**先把旧容器删掉再崩**，
> 容器会直接消失。首次 `up` 之所以能成功，只是因为当时没有旧容器可重建。
> 安装 v2 插件（免 apt，`docker` 会自动发现 `cli-plugins` 目录）：
>
> ```bash
> mkdir -p /usr/local/lib/docker/cli-plugins
> curl -fSL "https://github.com/docker/compose/releases/latest/download/docker-compose-linux-$(dpkg --print-architecture)" \
>   -o /usr/local/lib/docker/cli-plugins/docker-compose
> chmod +x /usr/local/lib/docker/cli-plugins/docker-compose
> docker compose version
> ```
>
> v2 会对顶层 `version: "3.8"` 打一句 `the attribute 'version' is obsolete` 警告 —— **无害**，
> 留着是为了万一还要兼容 v1。
>
> **项目名推荐命令行显式指定 `-p coauto`**：v1.29.2 **不读** `.env` 里的 `COMPOSE_PROJECT_NAME`
> （实测卷名跟着目录名走，变成 `coautoresearch_coauto-home`）；v2 会读，两边都写上是双保险。
> 项目名只影响卷名/容器标签，不影响功能（`container_name: coauto` 是显式写死的）。

### 9.1 设计取舍（为什么这么写）

| 决定 | 原因 |
|---|---|
| 基础镜像 `python:3.12-slim-bookworm` | 论文链路要求 Python ≥3.12，面板只要 ≥3.10。Node 22 由 NodeSource 装进去 |
| 仓库**不** COPY 进镜像，只读挂载 `/opt/coauto:ro` | **你已经 clone 在服务器上了，直接用这份**；以后 `git pull` 就更新，不用重建镜像。CLI 的模板根目录按脚本路径（`PACKAGE_ROOT`）解析，与 cwd 无关，只读挂载没问题 |
| Claude Code 用 `npm i -g` 装到 `/usr/local` | 因为 `/home/coauto` 挂了具名卷，装在 `$HOME/.local/bin` 的可执行文件首次建卷后会被卷遮蔽，镜像升级 CLI 会失效 |
| `network_mode: host` | 容器的 `127.0.0.1` 就是宿主机回环 → 面板照旧只绑回环、**不发布任何端口**，SSH 隧道方式与第 4 节完全一致 |
| 非 root 运行 + `APP_UID/APP_GID` 对齐宿主机 | 否则容器创建的研究产物在宿主机上是 root 属主，你改不动 |
| `tini` 作 entrypoint | 回收 agent 拉起的子进程组（编译器、agent CLI），避免僵尸进程 |
| `CMD` 内置启动自检 | `REPO_DIR` 指错时 Docker 会静默挂空目录；自检把它变成一句人话并打印实际挂载内容，避免只有一句 `Cannot find module` 循环刷屏 |
| `environment:` 里透传 `COAUTO_AGENT_BACKEND` | **踩过的坑**：写进 `.env` 不会自动变成容器内的环境变量（`.env` 只参与 compose 插值）。不在这里透传，面板就会沿用 CLI 的默认后端 `codex`，doctor 报 `selected agent - codex (selected backend missing)` |

### 9.2 启动

三件事必须先讲清楚，否则很容易踩坑：

1. **`.env` 必须和 `docker-compose.yml` 在同一个目录。** v1 和 v2 都按「compose 文件所在目录」解析 `.env`、`build.context` 和项目名。你可以把这套 docker 文件放在 clone 目录里，也可以单独放一个目录——`REPO_DIR` 用的是宿主机**绝对路径**，与文件位置无关。
2. **`REPO_DIR` 写错不会报错，会静默挂一个空目录进来。** Docker 发现 bind 挂载的源路径不存在时，默认会**创建一个空目录**，然后面板启动后找不到代码。所以下面第一步就是自检。
3. **宿主机是 root 时，`APP_UID`/`APP_GID` 保持 `1000:1000`，别填 0。** 容器以非 root 运行是这套配置的前提（Dockerfile 里对 0 做了显式拒绝）。root 环境下改为把产物目录 chown 给 1000。

```bash
cd <放 docker-compose.yml 的目录>          # 例: ~/coauto-server-setup 或 clone 目录本身
cp .env.docker.example .env
chmod 600 .env
# 编辑 .env：REPO_DIR 填 clone 的绝对路径（例 /root/study/CoAutoResearch）
#            PROJECTS_DIR 填仓库外的绝对路径（例 /root/coauto-projects）

# --- 自检（强烈建议，能挡掉 90% 的"起来了但打不开"）---
set -a; . ./.env; set +a
echo "REPO_DIR=[$REPO_DIR]"                # 看一眼有没有多余空格/引号/^M
test -f "$REPO_DIR/bin/auto-research.js" || { echo "REPO_DIR 不对: $REPO_DIR"; exit 1; }
test -f Dockerfile || { echo "缺少 Dockerfile（要与 compose 文件同目录）"; exit 1; }
mkdir -p "$PROJECTS_DIR" && chown "$APP_UID:$APP_GID" "$PROJECTS_DIR"
id -u "$APP_UID" >/dev/null 2>&1 || echo "提示: 宿主机上没有 UID=$APP_UID 的用户（root 环境下正常，产物属主会是数字 UID）"

# --- 构建 + 启动（-p 必须写在子命令前面）---
docker compose -p coauto build            # 要论文链路: WITH_PAPER=1 docker compose -p coauto build
docker compose -p coauto up -d
docker compose -p coauto logs --tail=80   # 这里会打印 SSH 隧道指令和访问密钥
```

> 注意最后一行用的是 `logs --tail=80` 而不是 `logs -f`：v1.29 的日志跟随器在**容器反复重启**时
> 会抛一个 `KeyError: 'id'` 的 Python traceback（`compose/cli/log_printer.py`），看着吓人但只是
> 跟随线程崩了，不影响容器本身。排查阶段用 `--tail` 或 `docker logs coauto` 更清爽。

> 构建慢或卡在拉源阶段（国内服务器常见）：在 `.env` 里设 `NPM_REGISTRY=https://registry.npmmirror.com`；
> 需要走代理请在 `BUILD_HTTP_PROXY` / `BUILD_HTTPS_PROXY` 填**宿主机 docker0 网关**地址（如 `http://172.17.0.1:7890`），
> 不要填 `127.0.0.1:7890` —— 构建容器里的 `127.0.0.1` 是它自己，不是宿主机。
> 运行时（agent 出海）的代理是另一组变量 `HTTPS_PROXY`/`HTTP_PROXY`，因为用了 host 网络，那里填 `127.0.0.1:端口` 才是对的。

然后本地照第 4 节建隧道：

```bash
ssh -N -L 8765:127.0.0.1:8765 <user>@<server>
```

#### 起不来时先跑这一组（这里列的两类都是真机上实测遇到的）

**症状 A：`Error: Cannot find module '/opt/coauto/bin/auto-research.js'` 无限刷屏**

这是**最常见**的失败：`REPO_DIR` 指向的宿主机路径不存在，Docker 静默建了个空目录挂进来（不报错）。
镜像的 `CMD` 里已经内置了自检，会先打印一句人话 + 实际挂载内容；要手工定位就跑这三条：

```bash
cd <compose 目录>
cat -A .env | grep -E 'REPO_DIR|PROJECTS_DIR'        # 看行尾有没有 ^M（CRLF）或多余空格
set -a; . ./.env; set +a
ls -l "$REPO_DIR/bin/auto-research.js"               # ① 宿主机上真的有这个文件吗
docker compose -p coauto config | sed -n '/volumes:/,$p'   # ② compose 实际解析出的挂载源
docker run --rm -v "$REPO_DIR":/x:ro --entrypoint ls coauto-research:2.0.1 -la /x   # ③ 容器视角

# 改好之后强制重建容器
docker compose -p coauto up -d --force-recreate
```

- ① 报 No such file → 把 `REPO_DIR` 改成 `realpath .` 的输出（即 clone 目录的绝对路径）。
- ① 有文件、③ 是空的 → 看 ② 解析出来的路径是不是被引号 / `^M` / 空格污染了。

**症状 B：`docker-compose up -d` 报 `KeyError: 'ContainerConfig'`，然后容器不见了**

**v1.29.2 与 Docker Engine ≥ 25 的已知不兼容**（不是你的配置问题）。见本节开头的说明，
装上 Compose v2 插件并改用 `docker compose`（空格）即可。改完执行：

```bash
cd <compose 目录>
docker compose -p coauto up -d
```

**症状 C：`docker compose up -d` 报 `unknown shorthand flag: 'd'` 或 `unknown command: docker compose`**

说明 v2 插件没装好（`docker` 找不到 `cli-plugins/docker-compose`）。按本节开头那条 `curl` 重装，
再用 `docker compose version` 确认。**不要退回 v1** —— 它在这台 Engine 上重建容器必崩。

**顺带**：容器配了 `restart: unless-stopped`，失败时会一直重启刷屏。排查期间可以先
`docker compose -p coauto stop coauto` 止住，改完再 `up -d`。

**症状 D：面板起来了，但 doctor 报 `warn selected agent - codex (selected backend missing)`**

说明容器用的后端是 `codex`，但镜像里只装了 Claude Code。检查两处：

```bash
# 1) 容器内到底有没有拿到这个变量（没输出 = 没透传进来）
docker compose -p coauto exec coauto sh -lc 'echo COAUTO_AGENT_BACKEND=$COAUTO_AGENT_BACKEND'
# 2) compose 文件里是否透传了（本包的 docker-compose.yml 已加好）
grep -n COAUTO_AGENT_BACKEND docker-compose.yml
```

`.env` 里的值**不会自动**变成容器内进程的环境变量，必须由 `environment:` 段透传。

### 9.3 登录 Claude

容器内登录需要交互式 OAuth，**这一步只能在你的终端里做**（浏览器授权 + 粘贴 code）：

```bash
# 方式 A：容器内交互式登录，凭证存在 coauto_coauto-home 卷里，重启不丢
docker compose -p coauto exec coauto claude auth login
#   订阅账号（默认）: docker compose -p coauto exec coauto claude auth login
#   Console 按 API 计费: ... claude auth login --console

# 方式 B：在你本地已登录的环境生成长期 token，填进 .env 后重启
#   本地执行: claude setup-token   → 形如 sk-ant-oat01-...
#   然后 .env 里 CLAUDE_CODE_OAUTH_TOKEN=<那个值>，再:
docker compose -p coauto up -d

# 方式 C：不用 Anthropic 账号，走第三方 Anthropic 兼容网关
#   （DeepSeek / 智谱 GLM / Kimi / 通义），在面板 Settings → Agent → Claude 里选
#   custom_anthropic 并填 base_url + token。
```

验证登录是否生效（`loggedIn` 应为 `true`）：

```bash
docker compose -p coauto exec coauto claude auth status
```

### 9.4 验收

```bash
# 0) 先验证 compose 文件本身能被解析（v1 报错时最有用）
docker compose -p coauto config >/dev/null && echo "compose OK"

# 1) 工具链齐全（注意：exec 的 cwd 是 /home/coauto，必须用绝对路径）
docker compose -p coauto exec coauto node /opt/coauto/bin/auto-research.js doctor
docker compose -p coauto exec coauto sh -lc 'node -v; python3 --version; claude --version'

# 2) 容器确实能看到你的只读仓库
docker compose -p coauto exec coauto ls -l /opt/coauto/bin/auto-research.js

# 3) 面板存活
curl -sS -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8765/

# 4) 浏览器里按第 5 节的 6 项清单过一遍（doctor 只证明工具装上了，不证明模型能调用）
```

> 已在此服务器实测通过：第 0 项输出 `compose OK`（v2 会附一句 `version is obsolete` 警告，无害）、
> 第 1 项 node v22.23.3 / Python 3.12.15 / claude 2.1.300、第 2 项能看到 `auto-research.js`、
> 第 3 项返回 `200`。**只有第 4 项（模型真能调用）依赖你的登录，尚未验证。**

### 9.5 论文生成在容器里能不能跑？——必须先探测

这是 Docker 方案**唯一真正的坑**。`paper_export.py:339` 给 Claude 传的是
`sandbox.enabled=true` + **`failIfUnavailable=true`** + `allowUnsandboxedCommands=false`，
即**沙箱起不来就硬失败、且不给绕过沙箱的机会**。而 Linux 上这个沙箱依赖 `bubblewrap` 创建用户命名空间，
容器里能否创建**取决于宿主机内核 sysctl + Docker 的 seccomp/apparmor 配置 + 容器权限**，
各发行版差异很大，**不存在一组万能参数**。

先探测（前提：镜像是用 `WITH_PAPER=1` 构建的，否则镜像里根本没有 bwrap）：

```bash
docker compose -p coauto run --rm --entrypoint bwrap coauto --ro-bind / / true
echo "exit=$?"
```

- **exit=0** → bwrap 可用，论文生成应当能跑，跳过下面的放开项。
- **非 0**（典型报错 `No permissions to create new namespace` / `Operation not permitted`）→ 需要放开。把 `docker-compose.yml` 里被注释的那段取消注释：

```yaml
    cap_add: [SYS_ADMIN]
    security_opt: [seccomp:unconfined, apparmor:unconfined]
    sysctls: {kernel.unprivileged_userns_clone: "1"}
```

然后 `docker compose -p coauto up -d` 并重新探测。**注意这会显著削弱容器隔离**（等价于给容器开了系统管理能力、关掉了 seccomp 和 AppArmor），Ubuntu 23.10+ 还可能需要宿主机 `sysctl -w kernel.apparmor_restrict_unprivileged_userns=0`。

**如果探测始终失败**，我建议不要为了论文生成把容器扒开，而是二选一：

1. **用宿主机方案跑论文生成**（第 1-8 节的 systemd 部署，bwrap 在裸机上没这问题）；
2. 或者把 `paper_export.py` 那三个 sandbox 参数改掉 —— **但这等于拆掉官方为无人值守流程设的安全边界，我不建议，而且属于改产品代码**。

> 换句话说：**Docker 方案下「面板 + 研究」没问题，「论文生成」需要拿隔离度去换。** 这是官方把沙箱设为硬性要求带来的直接后果，不是 compose 配置能绕开的。

### 9.6 日常维护

```bash
docker compose -p coauto logs --tail=80            # 看输出（含访问密钥）
docker compose -p coauto ps                        # 看容器状态（healthcheck 结果）
git -C "$REPO_DIR" pull && docker compose -p coauto restart   # 更新代码，不重建镜像
docker compose -p coauto build --no-cache          # CLI/依赖升级时才需要重建
docker compose -p coauto down                      # 停止（卷保留，登录状态不丢）

docker volume ls | grep coauto-home                # 先看实际卷名
docker volume rm <上面列出的卷名>                   # 彻底清除登录凭证与 paper-tools 缓存
```

> 卷名是「项目名_卷名」。项目名跟着 compose 文件所在目录走（clone 在 `~/study/CoAutoResearch`
> 时就是 `coautoresearch_coauto-home`），加了 `-p coauto` 之后才会变成 `coauto_coauto-home`。
> **换了项目名就等于换了一个全新的空卷**，登录状态要重做一次，所以别在中途改。
>
> 早期那次失败启动还留下了一个孤儿卷 `coautoresearch_coauto-home`（当时没登录过，里面没有凭证），
> 确认不用了可以 `docker volume rm coautoresearch_coauto-home` 清掉。

### 9.7 本机（Oracle Cloud arm64）的实际落位

这份 README 是通用指南；下面是**这台服务器**上已经生效的具体值，照抄即可：

| 项 | 值 |
|---|---|
| 仓库 | `/root/study/CoAutoResearch`（`REPO_DIR`，只读挂到容器 `/opt/coauto`） |
| 研究产物 | `/root/coauto-projects`（宿主 UID 1000 = `opc`，已 chown 1000:1000） |
| compose 文件 | 与仓库同目录（`Dockerfile` / `docker-compose.yml` / `.env` 都在仓库根） |
| 项目名 | `coauto`（必须写 `-p coauto`） |
| 卷 | `coauto_coauto-home` |
| 网络 | `network_mode: host`；面板只绑 `127.0.0.1:8765` |
| 出网 | `api.anthropic.com` / `registry.npmjs.org` / `deb.nodesource.com` 均直连可达 → **不需要代理** |
| 架构 | aarch64（Ampere），镜像/NodeSource/Claude Code 都有 arm64 版，无需改动 |

日常三条命令：

```bash
cd /root/study/CoAutoResearch
docker compose -p coauto ps                    # 看状态
docker compose -p coauto logs --tail=60        # 看访问密钥
docker compose -p coauto up -d                 # 改完配置后重建
```

本地（Windows）侧建隧道：用 `connect-tunnel.bat`（双击），或手写

```bash
ssh -i ~/.ssh/coauto_deploy_ed25519 -N -L 8765:127.0.0.1:8765 -p 1922 root@170.9.228.162
```

然后浏览器打开 `http://127.0.0.1:8765` 并输入访问密钥（在 `.env` 的 `COAUTO_REMOTE_AUTH_TOKEN`，
或 `docker compose -p coauto logs` 里那份）。

