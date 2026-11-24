#!/usr/bin/env bash
# 通过 Portainer API 创建/更新 dsh stack（compose 取自仓库 docker-compose.yml）。
#
# 环境变量优先级：进程环境 > 已有 stack Env > 默认值
#   —— 换过域名（DSH_PUBLIC_URL）后重跑本脚本不会把手改过的值打回去；
#   DSH_IMAGE_TAG 例外：默认取 VERSION+dsh-version（重跑即升级），进程环境可覆盖。
#
# 用法：
#   PORTAINER_URL=https://portainer.mydomain.com:20443 PORTAINER_TOKEN=ptr_xxx \
#     ./scripts/portainer-deploy.sh
# 可选：PORTAINER_ENDPOINT（默认 3 = 目标 Docker 环境）、STACK_NAME（默认 dsh）、
#       DSH_PUBLIC_URL / DSH_TRUSTED_HOSTS / TZ 等 compose 环境变量。
set -euo pipefail
cd "$(dirname "$0")/.."

# 本机私有配置（gitignored）：PORTAINER_URL / PORTAINER_TOKEN / DSH_PUBLIC_URL ...
if [[ -f ./local.env ]]; then set -a; source ./local.env; set +a; fi

: "${PORTAINER_URL:?set PORTAINER_URL，如 https://portainer.mydomain.com:20443（可写进 local.env）}"
: "${PORTAINER_TOKEN:?set PORTAINER_TOKEN（Portainer access token）}"
PORTAINER_ENDPOINT="${PORTAINER_ENDPOINT:-3}"
STACK_NAME="${STACK_NAME:-dsh}"
export STACK_NAME

AUTH=(-H "X-API-Key: ${PORTAINER_TOKEN}" -H "Content-Type: application/json")
BASE="${PORTAINER_URL%/}/api"

# 1. 查已有 stack：id 与其当前 Env（作为“未显式指定时”的取值来源）
read -r STACK_ID EXISTING_ENV <<<"$(curl -sS "${AUTH[@]}" "$BASE/stacks" | python3 -c '
import json, sys
name = sys.argv[1]
for s in json.load(sys.stdin):
    if s.get("Name") == name:
        env = {e["name"]: e["value"] for e in (s.get("Env") or [])}
        print(s["Id"], json.dumps(env, ensure_ascii=False))
        break
else:
    print("", "{}")
' "$STACK_NAME")"
# 注意：不能写 ${EXISTING_ENV:-{}} —— bash 只吃到第一个 } 会把 JSON 截坏；
# 空值由 python 侧 or "{}" 兜底。
export EXISTING_ENV

TMP_PAYLOAD="$(mktemp)"
trap 'rm -f "$TMP_PAYLOAD" "$TMP_PAYLOAD.out"' EXIT

# 2. 组装 payload
python3 - > "$TMP_PAYLOAD" <<'PY'
import json
import os
import pathlib

existing = json.loads(os.environ.get("EXISTING_ENV") or "{}")
tag_default = (pathlib.Path("VERSION").read_text().strip()
               + "-dsh" + pathlib.Path("dsh-version").read_text().strip())
defaults = {
    "DSH_PUBLIC_URL": "https://dsh.mydomain.com:20443/",
    "DSH_TRUSTED_HOSTS": "",
    "TZ": "Asia/Shanghai",
    "DSH_INJECTOR_PORT": "3081",
    "DSH_PUBLISHED_BIND": "127.0.0.1:3081",
}

env_map = dict(existing)  # 保留 stack 上可能存在的其他键
for key, default in defaults.items():
    if key in os.environ:
        env_map[key] = os.environ[key]
    else:
        env_map.setdefault(key, default)
# tag 不继承旧值：默认随仓库版本前进（重跑 = 升级到当前 VERSION）
env_map["DSH_IMAGE_TAG"] = os.environ.get("DSH_IMAGE_TAG", tag_default)

json.dump(
    {
        "Name": os.environ.get("STACK_NAME", "dsh"),
        "StackFileContent": pathlib.Path("docker-compose.yml").read_text(),
        "Env": [{"name": k, "value": v} for k, v in env_map.items()],
        "FromAppTemplate": False,
    },
    __import__("sys").stdout,
    ensure_ascii=False,
)
PY

# 3. 已有则更新，否则创建
if [[ -z "${STACK_ID:-}" || "$STACK_ID" == "0" ]]; then
  echo "创建 stack $STACK_NAME（endpoint $PORTAINER_ENDPOINT）..."
  code="$(curl -sS -o "$TMP_PAYLOAD.out" -w '%{http_code}' "${AUTH[@]}" \
    --data-binary "@$TMP_PAYLOAD" \
    -X POST "$BASE/stacks/create/standalone/string?endpointId=$PORTAINER_ENDPOINT&name=$STACK_NAME")"
else
  echo "更新 stack $STACK_NAME (id=$STACK_ID)..."
  code="$(curl -sS -o "$TMP_PAYLOAD.out" -w '%{http_code}' "${AUTH[@]}" \
    --data-binary "@$TMP_PAYLOAD" \
    -X PUT "$BASE/stacks/$STACK_ID?endpointId=$PORTAINER_ENDPOINT")"
fi

echo "HTTP $code"
head -c 500 "$TMP_PAYLOAD.out"; echo
[[ "$code" == 200 ]] || exit 1
echo "完成。改 DSH_PUBLIC_URL/TZ 等：显式带上环境变量重跑本脚本，或在 Portainer UI 里改 Env 后 Update。"
