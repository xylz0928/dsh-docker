#!/usr/bin/env bash
# dsh-docker 部署后自检（在宿主 dhost 上执行）：
#   scripts/verify.sh [base_url]   默认 http://127.0.0.1:3081
# 检查：容器健康、注入代理自动换 cookie、受信 Host 围栏、
#       设置页数据接口（/docker-dsh/info、/docker-dsh/latest）、启动日志关键行。
set -euo pipefail

BASE="${1:-http://127.0.0.1:3081}"
JAR="$(mktemp)"
trap 'rm -f "$JAR"' EXIT
fail=0
ok()  { printf '  \033[32mPASS\033[0m %s\n' "$1"; }
bad() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; fail=1; }

echo "== 1. 容器 =="
if docker ps --format '{{.Names}}\t{{.Status}}' | grep -q '^dsh[[:space:]]'; then
  ok "容器 dsh 运行中: $(docker ps --format '{{.Status}}' --filter name=^dsh$)"
else
  bad "容器 dsh 未运行"; docker ps -a --filter name=^dsh$ --format '{{.Names}} {{.Status}}' || true
fi

echo "== 2. 注入代理（自动补 launch token 换 cookie）=="
# 无 cookie 的 GET / 会303 回自身（dsh 的换 cookie 跳转），带 cookie jar 跟随后应 200
code="$(curl -sS -o /dev/null -w '%{http_code}' -c "$JAR" "$BASE/" || echo 000)"
if [[ "$code" == "303" || "$code" == "200" ]]; then
  ok "GET / -> $code（launch token 交换）"
else
  bad "GET / -> $code（期望303/200）"
fi
code="$(curl -sS -o /dev/null -w '%{http_code}' -b "$JAR" -c "$JAR" -L --max-redirs 5 "$BASE/" || echo 000)"
[[ "$code" == "200" ]] && ok "带 cookie 跟随重定向 -> 200" || bad "带 cookie 跟随 -> $code"

echo "== 3. 受信 Host 围栏（/api：受信=401 未认证，伪造=403）=="
# 期望的受信 authority 从容器 DSH_PUBLIC_URL 推导 —— 以后换域名无需改本脚本
EXPECT_HOST="$(docker exec dsh printenv DSH_PUBLIC_URL 2>/dev/null \
  | python3 -c "
import sys, urllib.parse as u
raw = sys.stdin.read().strip()
if not raw:
    raise SystemExit(1)
p = u.urlsplit(raw)
print(f'{p.hostname}:{p.port}' if p.port else (p.hostname or ''))" 2>/dev/null || true)"
if [[ -n "$EXPECT_HOST" ]]; then
  code="$(curl -sS -o /dev/null -w '%{http_code}' -H "Host: $EXPECT_HOST" "$BASE/api" || echo 000)"
  [[ "$code" == "401" ]] && ok "受信 Host($EXPECT_HOST) -> 401（围栏放行、等认证）" || bad "受信 Host($EXPECT_HOST) -> $code（期望401）"
else
  echo "  NOTE 容器未设 DSH_PUBLIC_URL，跳过受信 Host 断言"
fi
code="$(curl -sS -o /dev/null -w '%{http_code}' -H 'Host: evil.example.com' "$BASE/api" || echo 000)"
[[ "$code" == "403" ]] && ok "未受信 Host -> 403（围栏拦截）" || bad "未受信 Host -> $code（期望403）"

echo "== 4. 设置页数据接口 =="
info="$(curl -sS -b "$JAR" "$BASE/docker-dsh/info" || true)"
if echo "$info" | grep -q '"packVersion"'; then
  ok "/docker-dsh/info -> $(echo "$info" | head -c 200)..."
else
  bad "/docker-dsh/info -> ${info:0:120}"
fi
latest="$(curl -sS -b "$JAR" "$BASE/docker-dsh/latest" || true)"
if echo "$latest" | grep -q '"version"'; then
  ok "/docker-dsh/latest -> $latest"
else
  bad "/docker-dsh/latest -> ${latest:0:120}"
fi

echo "== 5. 插件与启动日志 =="
if docker exec dsh node -p "require('/home/dsh/.dsh/profiles/web/node_modules/dsh-docker/package.json').version" >/dev/null 2>&1; then
  ok "dsh-docker 插件已装入 profile（版本 $(docker exec dsh node -p "require('/home/dsh/.dsh/profiles/web/node_modules/dsh-docker/package.json').version" 2>/dev/null)）"
else
  bad "dsh-docker 插件未装入 profile"
fi
logs="$(docker logs dsh 2>&1 | tail -n 200 || true)"
for pat in 'dsh-docker plugin' 'trustedHosts' 'injector'; do
  if echo "$logs" | grep -q "$pat"; then ok "日志含 [$pat]"; else bad "日志缺 [$pat]"; fi
done
if echo "$logs" | grep -qiE 'sandbox.*(bwrap|landlock)|runner'; then
  ok "沙箱探测: $(echo "$logs" | grep -iE 'sandbox|bwrap|landlock' | tail -n 2 | tr '\n' ' ')"
else
  echo "  NOTE 未见沙箱探测日志（不阻断）"
fi

echo
[[ $fail -eq 0 ]] && echo "全部通过。" || echo "存在失败项。"
exit $fail
