#!/usr/bin/env bash
# dsh-docker entrypoint — 组装容器内的 dsh web 运行环境：
#   1. 探测容器 IP（dsh 拒绝绑定通配地址，必须给一个本机接口的具体 IP）
#   2. 由 DSH_PUBLIC_URL / DSH_TRUSTED_HOSTS 生成 cordis --patch 覆盖层
#      （受信反代、监听地址；覆盖层在 cordis.patch.yml 之后应用）
#   3. 重放本地补丁（@ponydev/dsh-model-usage 三处修复，幂等）
#   4. 启动 dsh web + token 注入代理，捕获 launch token 供注入代理使用
#   5. 任一子进程退出即整体退出，交给容器 restart 策略拉起
set -euo pipefail

# 透传：docker run <image> <cmd> 时直接执行命令（迁移/排障用），不进启动编排。
if [[ $# -gt 0 ]]; then
  exec "$@"
fi

log() { printf '[entrypoint] %s\n' "$*"; }

: "${HOME:=/home/dsh}"
: "${DSH_WEB_PORT:=3080}"
: "${DSH_INJECTOR_PORT:=3081}"
: "${DSH_PUBLIC_URL:=}"        # 例：https://dsh.mydomain.com:20443/ —— 用户自己的反代链接
: "${DSH_TRUSTED_HOSTS:=}"     # 额外受信 authority，逗号或空格分隔
: "${DSH_WEB_HOST:=}"          # 留空 = 自动探测容器 IP
: "${TZ:=Asia/Shanghai}"

URL_FILE="${DSH_URL_FILE:-/tmp/dsh-launch-url}"
LOG_FILE="/tmp/dsh-web.log"
OVERLAY="/tmp/cordis.docker.patch.yml"

# ---------------------------------------------------------------- 1. 监听地址
if [[ -z "$DSH_WEB_HOST" ]]; then
  DSH_WEB_HOST="$(ip -4 -o addr show scope global 2>/dev/null \
    | awk '{ split($4, a, "/"); print a[1] }' | head -n1 || true)"
fi
if [[ -z "$DSH_WEB_HOST" ]]; then
  log "FATAL: 探测不到容器 IP，请显式设置 DSH_WEB_HOST"
  exit 1
fi
log "web bind: ${DSH_WEB_HOST}:${DSH_WEB_PORT}  tz=${TZ}"

# ---------------------------------------------------------------- 2. 受信 authority
mapfile -t TRUSTED < <(python3 - "$DSH_PUBLIC_URL" "$DSH_TRUSTED_HOSTS" "$DSH_WEB_HOST" <<'PY'
import os
import sys
from urllib.parse import urlsplit

pub, extra, ip = sys.argv[1], sys.argv[2], sys.argv[3]
out = []

def add(value):
    value = (value or "").strip()
    if value and value not in out:
        out.append(value)

if pub:
    try:
        parts = urlsplit(pub)
        if parts.hostname:
            add(parts.hostname)
            if parts.port:
                add(f"{parts.hostname}:{parts.port}")
    except Exception:
        pass
add(ip)
add("127.0.0.1")
add("localhost")
add(os.uname().nodename)
for token in extra.replace(",", " ").split():
    add(token)
print("\n".join(out))
PY
)

{
  echo "# 由 dsh-docker entrypoint 生成：容器环境覆盖层（cordis.patch.yml 之后应用）"
  echo "# 设置页「Docker DSH」分区（插件 dsh-docker，安装校验见下）"
  echo "- insert:"
  echo "    - id: docker-dsh"
  echo "      name: 'dsh-docker'"
  echo "- id: webserver"
  echo "  config:"
  echo "    host: '${DSH_WEB_HOST}'"
  echo "    port: ${DSH_WEB_PORT}"
  echo "- id: connection"
  echo "  config:"
  echo "    trustedHosts:"
  for host in "${TRUSTED[@]}"; do
    echo "      - '${host}'"
  done
  echo "    cookieMaxAgeDays: 3650"
} > "$OVERLAY"
log "trustedHosts: ${TRUSTED[*]}"

# 环境快照：设置页「Docker DSH」区块经 /docker-dsh/info 展示
export DSH_WEB_HOST
export DSH_TRUSTED_HOSTS_EFFECTIVE="${TRUSTED[*]}"
# 运行中 dsh 版本（dsh -V 只打印版本即退出，不初始化 profile）
export DSH_RUNNING_VERSION="$(dsh -V 2>/dev/null | tail -n 1 || true)"

# ---------------------------------------------------------------- 3. ssh 客户端骨架
# 注意：ssh 展开 ~ 用 passwd 的 root 家目录（/root），不认 $HOME —— 配置必须落 /root/.ssh。
mkdir -p /root/.ssh
chmod 700 /root/.ssh
# known_hosts：dhost 的清单只读挂载作种子，容器本地文件才可写 ——
# ssh 更新 known_hosts 走 rename，落在 bind mount 文件上会 EXDEV 失败（学习不落盘）。
if [[ ! -f /root/.ssh/known_hosts && -f /root/.ssh/dhost-known-hosts ]]; then
  cp /root/.ssh/dhost-known-hosts /root/.ssh/known_hosts
  chmod 600 /root/.ssh/known_hosts
fi
if [[ ! -f /root/.ssh/config ]]; then
  cat > /root/.ssh/config <<'EOF'
# dsh-docker 容器内默认 ssh 客户端配置
Host *
    IdentityFile ~/.ssh/id_rsa
    IdentitiesOnly yes
    StrictHostKeyChecking accept-new
    UserKnownHostsFile ~/.ssh/known_hosts
    ServerAliveInterval 30
EOF
  chmod 600 /root/.ssh/config
fi

# ---------------------------------------------------------------- 4. git 全局配置
# 迁移进来的仓库属主（CIFS 映射 uid）与容器内 root 不一致，放行 dubious ownership。
if [[ -z "$(git config --global --get-all safe.directory 2>/dev/null || true)" ]]; then
  git config --global safe.directory '*'
fi

# ---------------------------------------------------------------- 5. 设置页「Docker DSH」插件
PLUGIN_DIR="/opt/dsh-docker/plugin"
want="$(node -p "require('${PLUGIN_DIR}/package.json').version" 2>/dev/null || true)"
have="$(node -p "require('${HOME}/.dsh/profiles/web/node_modules/dsh-docker/package.json').version" 2>/dev/null || true)"
install_plugin() {
  # 版本不一致时先移除再装：file: 依赖仅凭 spec 无法保证内容刷新
  dsh plugin --profile web remove dsh-docker >/dev/null 2>&1 || true
  dsh plugin --profile web add "file:${PLUGIN_DIR}"
}
if [[ -z "$want" ]]; then
  log "WARN: 找不到插件包 ${PLUGIN_DIR}，设置页 Docker DSH 分区将缺失"
elif [[ "$have" != "$want" ]]; then
  log "dsh-docker plugin: ${have:-not installed} -> ${want}"
  if ! install_plugin; then
    # 迁移卷的 node_modules 记录着原机 store 绝对路径 → ERR_PNPM_UNEXPECTED_STORE：
    # 按 lockfile 在容器内重建链接（pnpm install）后重试一次。
    log "首次安装失败，pnpm install 重链后重试（迁移卷 store 路径差异）"
    if dsh plugin --profile web install && install_plugin; then
      log "dsh-docker plugin installed after store relink"
    else
      log "WARN: 插件安装失败（设置页 Docker DSH 分区将缺失），不阻断启动"
    fi
  fi
else
  log "dsh-docker plugin: ${have} (up to date)"
fi

# ---------------------------------------------------------------- 6. 重放本地补丁
python3 /opt/dsh-docker/patch-dsh-model-usage.py || log "WARN: model-usage 补丁重放失败（不阻断启动）"

# ---------------------------------------------------------------- 7. 组装并启动 dsh
# --patch 必须紧跟 profile 名（root 解析器在遇到第一个未知选项后把剩余参数全部
# 透传给 web 应用，应用不认识 --patch → "unknown option"）。
ARGS=(web --patch "$OVERLAY" --no-open --host "$DSH_WEB_HOST" --port "$DSH_WEB_PORT")
[[ -n "$DSH_PUBLIC_URL" ]] && ARGS+=(--public-url "$DSH_PUBLIC_URL")
for host in "${TRUSTED[@]}"; do ARGS+=(--trusted-host "$host"); done

rm -f "$URL_FILE"
: > "$LOG_FILE"
dsh "${ARGS[@]}" > "$LOG_FILE" 2>&1 &
DSH_PID=$!

# 落盘启动 URL（含 launch token）→ 注入代理的 token 来源；只写 0600 文件，不打印 token。
(
  for _ in $(seq 1 120); do
    tok="$(grep -oE 'https://[^[:space:]]*token=[A-Za-z0-9_-]+' "$LOG_FILE" 2>/dev/null | tail -n 1 || true)"
    if [[ -n "$tok" ]]; then
      umask 077
      printf '%s\n' "$tok" > "$URL_FILE.tmp.$$" && mv -f "$URL_FILE.tmp.$$" "$URL_FILE"
      log "launch url captured"
      exit 0
    fi
    sleep 1
  done
  log "WARN: 120s 内未捕获 launch token"
) &
CAP_PID=$!

# dsh 日志同时镜像到容器 stdout，便于 docker logs / Portainer 查看
tail -n +1 -f "$LOG_FILE" &
TAIL_PID=$!

# ---------------------------------------------------------------- 8. 注入代理
DSH_URL_FILE="$URL_FILE" \
DSH_UPSTREAM_HOST="$DSH_WEB_HOST" \
DSH_UPSTREAM_PORT="$DSH_WEB_PORT" \
DSH_LISTEN_HOST="${DSH_INJECTOR_HOST:-0.0.0.0}" \
DSH_LISTEN_PORT="$DSH_INJECTOR_PORT" \
node /opt/dsh-docker/token-injector.js &
INJ_PID=$!

log "dsh=$DSH_PID injector=$INJ_PID (injector :${DSH_INJECTOR_PORT} -> ${DSH_WEB_HOST}:${DSH_WEB_PORT})"

terminate() {
  kill "$DSH_PID" "$INJ_PID" "$CAP_PID" "$TAIL_PID" 2>/dev/null || true
}
trap terminate TERM INT

# 任一常驻子进程退出即整体退出 → docker restart 策略拉起全新一套
wait -n "$DSH_PID" "$INJ_PID" "$TAIL_PID" || true
log "a supervised process exited; shutting down"
terminate
wait || true
exit 1
