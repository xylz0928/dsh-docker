#!/usr/bin/env bash
# 账号重新登录的本地回环入口。
#
# dsh 的 DeepSeek 账号 OAuth 只接受回环 origin（loginOrigin() 仅放行
# http://localhost|127.0.0.1|[::1]:<port>，官方注释即 "local or SSH-forwarded
# login"），https 域名（你的反代域名）无法完成登录 —— 登录丢失时必须
# 把 dhost 上注入代理的回环端口转发到本机，用 http://localhost:<port>/ 登录。
#
# 用法：
#   ./scripts/login-tunnel.sh            # 本机 3080 → dhost 127.0.0.1:3081
#   ./scripts/login-tunnel.sh 18080      # 指定本机端口
#   DSH_SSH=user@other-host ./scripts/login-tunnel.sh
# 打开打印的地址 → 页面里完成登录 → Ctrl-C 关闭隧道即可。
# 登录态（grant）存服务端 .credentials.yaml，登录一次后各域名入口自动生效。
set -euo pipefail

REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
if [[ -f "$REPO_DIR/local.env" ]]; then set -a; source "$REPO_DIR/local.env"; set +a; fi
: "${DSH_SSH:?set DSH_SSH（写进 local.env 或环境变量）}"
LOCAL_PORT="${1:-3080}"
DSH_SSH="${DSH_SSH:-}"   # 由 local.env 或环境变量提供
REMOTE_PORT="${DSH_REMOTE_PORT:-3081}"   # dhost 上发布的注入代理回环端口（compose DSH_PUBLISHED_BIND）

echo "转发: http://localhost:${LOCAL_PORT}/ → ${DSH_SSH} 的 127.0.0.1:${REMOTE_PORT}（注入代理）"
echo "浏览器打开 http://localhost:${LOCAL_PORT}/ 完成登录，Ctrl-C 关闭。"

exec ssh -F /dev/null \
  -o StrictHostKeyChecking=accept-new \
  -o UserKnownHostsFile=/dev/null \
  -o LogLevel=ERROR \
  -N -L "${LOCAL_PORT}:127.0.0.1:${REMOTE_PORT}" \
  "$DSH_SSH"
