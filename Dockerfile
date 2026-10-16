# CoAutoResearch 面板 —— Docker 镜像（自建）
#
# ⚠️ 本项目**官方不提供** Dockerfile / 镜像，这个文件是自建的。
#    官方依据：SECURITY.md:33、docs/remote-server.md:146 把「容器」列为推荐的隔离方式，
#    但没有随仓库提供任何现成产物。
#
# 设计要点（都踩过坑，别随便改）：
# 1) 基础镜像选 python:3.12 —— 论文链路要求 Python >= 3.12，面板只要求 3.10+。
#    Node 22 由 NodeSource 装入（面板 CLI 要求 Node >= 20）。
# 2) 仓库**不** COPY 进镜像，运行时只读挂载到 /opt/coauto。
#    CLI 的模板根目录按脚本自身路径解析（bin/auto-research.js 的 PACKAGE_ROOT），
#    与 cwd 无关，所以只读挂载完全可行 —— 好处是服务器上 git pull 即可更新，无需重建镜像。
# 3) Claude Code 用 npm 全局装到 /usr/local，**刻意不放在 $HOME**。
#    因为 /home/coauto 要挂载具名卷，放在 $HOME 下的可执行文件首次建卷后会被卷内容遮蔽，
#    镜像升级 CLI 时卷里还是旧版本。
# 4) 以非 root 用户运行，UID/GID 用 build args 对齐宿主机，
#    否则挂载目录里由容器创建的研究产物会是 root 属主，宿主机上改不动。

FROM python:3.12-slim-bookworm

ARG NODE_MAJOR=22
ARG WITH_PAPER=0
ARG CLAUDE_CODE_PKG=@anthropic-ai/claude-code@latest
ARG APP_UID=1000
ARG APP_GID=1000
# 构建期网络开关（默认留空 = 走官方源 / 直连，行为与不传参完全一致）
ARG NPM_REGISTRY=
ARG NODESOURCE_SETUP_URL=
ARG BUILD_HTTP_PROXY=
ARG BUILD_HTTPS_PROXY=

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    PYTHONUNBUFFERED=1 \
    NPM_CONFIG_UPDATE_NOTIFIER=false \
    NPM_CONFIG_FUND=false

# ---- 系统依赖 + Node.js ----------------------------------------------------
# 注意：这里显式导出构建期代理，只在本条 RUN 内生效，不会漏进运行时的容器环境变量。
RUN set -eux; \
    if [ -n "$BUILD_HTTP_PROXY" ]; then export http_proxy="$BUILD_HTTP_PROXY" HTTP_PROXY="$BUILD_HTTP_PROXY"; fi; \
    if [ -n "$BUILD_HTTPS_PROXY" ]; then export https_proxy="$BUILD_HTTPS_PROXY" HTTPS_PROXY="$BUILD_HTTPS_PROXY"; fi; \
    apt-get update; \
    apt-get install -y --no-install-recommends \
      ca-certificates curl gnupg git tini procps; \
    node_src="${NODESOURCE_SETUP_URL:-https://deb.nodesource.com/setup_${NODE_MAJOR}.x}"; \
    echo "NodeSource: $node_src"; \
    curl -fsSL "$node_src" | bash -; \
    apt-get install -y --no-install-recommends nodejs; \
    rm -rf /var/lib/apt/lists/*; \
    node -v; \
    python3 --version

# ---- 论文链路依赖（可选，镜像 +1~2GB）-------------------------------------
# bubblewrap + socat 是 Claude Code 的 Bash 沙箱在 Linux 上的硬依赖；
# 缺了它们，论文生成会因为 sandbox.failIfUnavailable=true 直接硬失败（paper_export.py:339）。
RUN set -eux; \
    if [ "$WITH_PAPER" = "1" ]; then \
      if [ -n "$BUILD_HTTP_PROXY" ]; then export http_proxy="$BUILD_HTTP_PROXY" HTTP_PROXY="$BUILD_HTTP_PROXY"; fi; \
      if [ -n "$BUILD_HTTPS_PROXY" ]; then export https_proxy="$BUILD_HTTPS_PROXY" HTTPS_PROXY="$BUILD_HTTPS_PROXY"; fi; \
      apt-get update; \
      apt-get install -y --no-install-recommends \
           latexmk texlive-latex-base texlive-latex-extra texlive-fonts-recommended \
           poppler-utils bubblewrap socat; \
      rm -rf /var/lib/apt/lists/*; \
      for c in latexmk pdflatex pdfinfo pdftoppm bwrap socat; do \
           command -v "$c" >/dev/null || { echo "缺少 $c"; exit 1; }; \
      done; \
      echo "论文链路依赖安装完成"; \
    else \
      echo "跳过论文链路依赖（WITH_PAPER=0）"; \
    fi

# ---- Claude Code CLI（全局安装，不依赖 $HOME）-----------------------------
RUN set -eux; \
    if [ -n "$BUILD_HTTP_PROXY" ]; then export http_proxy="$BUILD_HTTP_PROXY" HTTP_PROXY="$BUILD_HTTP_PROXY"; fi; \
    if [ -n "$BUILD_HTTPS_PROXY" ]; then export https_proxy="$BUILD_HTTPS_PROXY" HTTPS_PROXY="$BUILD_HTTPS_PROXY"; fi; \
    if [ -n "$NPM_REGISTRY" ]; then npm config set registry "$NPM_REGISTRY"; echo "npm registry: $NPM_REGISTRY"; fi; \
    npm install -g "${CLAUDE_CODE_PKG}"; \
    claude --version

# ---- 非 root 用户 ----------------------------------------------------------
# APP_UID/APP_GID 为 0 时直接失败：useradd/groupadd 会给出难以理解的报错，
# 而"以非 root 运行"正是这套配置的前提（避免研究产物在宿主机上是 root 属主）。
RUN set -eux; \
    if [ "${APP_UID}" = "0" ] || [ "${APP_GID}" = "0" ]; then \
      echo "错误: APP_UID/APP_GID 不能为 0。宿主机是 root 时请保持 1000:1000，" \
           "然后把 PROJECTS_DIR 目录 chown 给 1000:1000。" >&2; \
      exit 1; \
    fi; \
    groupadd --gid "${APP_GID}" coauto; \
    useradd --create-home --uid "${APP_UID}" --gid "${APP_GID}" --shell /bin/bash coauto; \
    mkdir -p /opt/coauto /home/coauto/coauto-projects /home/coauto/.co-auto-research; \
    chown -R coauto:coauto /home/coauto

ENV HOME=/home/coauto \
    COAUTO_PYTHON=/usr/local/bin/python3

# cwd 必须可写：面板会把 dashboard 运行时状态写到 --projects-dir 下，
# 但 CLI 自身也可能在 cwd 建默认目录，所以不要用只读的 /opt/coauto 当 cwd。
WORKDIR /home/coauto
USER coauto

EXPOSE 8765

# 用 node 内建 fetch 探活；401（未带访问密钥）也算存活，只要不是 5xx。
# 若你改了 --port，这里要同步改。
HEALTHCHECK --interval=30s --timeout=5s --start-period=30s --retries=3 \
  CMD node -e "fetch('http://127.0.0.1:8765/').then(r=>process.exit(r.status<500?0:1)).catch(()=>process.exit(1))"

# tini 负责回收 agent 启动的子进程组（编译器、agent CLI 等），避免僵尸进程。
ENTRYPOINT ["/usr/bin/tini","--"]

# 启动前先自检 /opt/coauto 是否真的挂进来了。
# 背景（实测踩过）：REPO_DIR 指向不存在的路径时，Docker 对 bind 挂载的**不存在的源路径会
# 静默创建一个空目录**（不报错），结果只抛一句很难定位的
#   Error: Cannot find module '/opt/coauto/bin/auto-research.js'
# 再被 restart: unless-stopped 放大成无限重启刷屏。这里把它变成一句人话 + 打印实际挂载内容。
# 注意：Dockerfile 不对 CMD/ENTRYPOINT 做变量替换，所以脚本里的 $REPO_DIR 会原样保留、
# 由容器内的 sh 解释（此时未定义，因此用单引号包住，只作为提示文字打印出来）。
# 想绕过自检直接进容器：docker-compose run --rm --entrypoint bash coauto
CMD ["sh","-c","test -f /opt/coauto/bin/auto-research.js || { echo '[coauto] 错误: /opt/coauto 里没有代码。多半是 .env 的 REPO_DIR 指向了不存在的路径 —— Docker 对不存在的挂载源会静默创建空目录，不报错。下面是实际挂载内容:'; ls -la /opt/coauto; echo '[coauto] 请在宿主机核对: set -a; . ./.env; set +a; ls -l $REPO_DIR/bin/auto-research.js'; exit 1; }; exec node /opt/coauto/bin/auto-research.js ui --projects-dir /home/coauto/coauto-projects --remote"]
