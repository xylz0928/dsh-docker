# syntax=docker/dockerfile:1
# dsh-docker — 官方 @deepseek-ai/dsh 的容器化打包。
# 双版本号：DSH_IMAGE_VERSION（本仓库打包版本）与 DSH_VERSION（所打包的官方 dsh 版本），
# 两者同时写进镜像 tag（见 .github/workflows/build.yml）与 OCI 标签。
# 层序注意：写入版本信息的 RUN 与 LABEL 放在 COPY 之后 —— 只改 DSH_GIT_REV 的
# 重建只重算末尾几层，apt/npm 缓存保持命中。
ARG NODE_IMAGE=node:24-bookworm-slim
FROM ${NODE_IMAGE}

# 官方 dsh 版本，取自仓库根 dsh-version 文件；打包版本取自 VERSION。
ARG DSH_VERSION=0.2.2-rc.5
ARG DSH_IMAGE_VERSION=1.0.0
ARG DSH_GIT_REV=unknown

ENV DEBIAN_FRONTEND=noninteractive \
    TZ=Asia/Shanghai \
    HOME=/home/dsh

# 运行期依赖：
#   bubblewrap    dsh 的文件沙箱（dsh-sandbox-local 的 Linux runner，容器内回落 landlock）
#   git/openssh   会话内 git 操作与 GitHub 远端
#   iproute2      启动时探测容器 IP（dsh 拒绝绑定通配地址）
#   python3       启动时重放本地补丁（patch-dsh-model-usage.py）
#   tini          PID 1，信号转发
RUN apt-get update && apt-get install -y --no-install-recommends \
      bubblewrap \
      ca-certificates \
      curl \
      git \
      iproute2 \
      openssh-client \
      procps \
      python3 \
      tini \
      tzdata \
    && rm -rf /var/lib/apt/lists/*

# pnpm：`dsh plugin --profile web add` 会把参数原样转发给 pnpm（缺了会报
# "pnpm was not found"），版本对齐原主机（12.21.0 / lockfileVersion 9.0）。
RUN npm install -g "@deepseek-ai/dsh@${DSH_VERSION}" pnpm@12.21.0 --no-audit --no-fund \
    && npm cache clean --force

# 数据目录骨架：/home/dsh 由 compose 的具名卷与挂载覆盖，这里只保证挂载点存在。
# 以 root 运行：需要读取宿主 /root/.ssh 下 600 权限的密钥（bind mount 不改属主）。
RUN mkdir -p /home/dsh/.dsh/plugins /home/dsh/.ssh /workspace

COPY payload/ /opt/dsh-docker/
COPY plugin/ /opt/dsh-docker/plugin/
RUN chmod 755 /opt/dsh-docker/entrypoint.sh && \
    chmod 644 /opt/dsh-docker/token-injector.js /opt/dsh-docker/patch-dsh-model-usage.py

# 镜像版本信息，供设置页「Docker DSH」区块读取（含构建提交号）。
RUN mkdir -p /etc/dsh && \
    printf 'DSH_PACK_VERSION=%s\nDSH_OFFICIAL_VERSION=%s\nDSH_GIT_REV=%s\n' \
      "${DSH_IMAGE_VERSION}" "${DSH_VERSION}" "${DSH_GIT_REV}" > /etc/dsh/image-info

LABEL org.opencontainers.image.title="dsh-docker" \
      org.opencontainers.image.description="DeepSeek Harness (dsh) web GUI, packaged for Docker" \
      org.opencontainers.image.version="${DSH_IMAGE_VERSION}" \
      org.opencontainers.image.revision="${DSH_GIT_REV}" \
      org.opencontainers.image.source="https://github.com/xylz0928/dsh-docker" \
      io.dsh.official-version="${DSH_VERSION}" \
      io.dsh.pack-version="${DSH_IMAGE_VERSION}"

WORKDIR /workspace

# 3081 = 注入代理（反代指向的端口）；3080 = dsh web 本体（仅容器内可达）
EXPOSE 3080 3081

HEALTHCHECK --interval=30s --timeout=6s --start-period=45s --retries=3 \
  CMD curl -fsS --max-time 5 "http://127.0.0.1:${DSH_INJECTOR_PORT:-3081}/" -o /dev/null || exit 1

ENTRYPOINT ["/usr/bin/tini", "--", "/opt/dsh-docker/entrypoint.sh"]
