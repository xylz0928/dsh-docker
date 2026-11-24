#!/usr/bin/env bash
# 从当前 DSH 主机把数据迁到 dhost（目标 Docker 宿主）的 dsh-docker 数据面。幂等，可重复执行：
#   1. 确认 dhost 侧三个卷与 workspace 目录存在
#   2. ~/.dsh           → dsh-data 卷（排除 plugins）
#   3. ~/.dsh/plugins   → dsh-plugins 卷
#   4. HOME 骨架（.gitconfig/.git-credentials/.bashrc/.profile/.config/zed）→ dsh-config 卷
#      —— 旧主机的 ~/.ssh 不迁移：容器挂宿主 dhost 的 root SSH key
#   5. ~/coding/*       → /mnt/docker-files/dsh/workspace（项目数据 = 容器工作目录）
#   6. 路径改写 /home/zed → /home/dsh（storages 索引 + 会话目录名；
#      加 --rewrite-headers 时连会话文件首帧 cwd 一起改，正文不动）
#
# 用法：scripts/migrate.sh [--final]
#   --final：收尾迁移（会话历史全量对齐）——先清目标 sessions/storages 再全量重灌
#            （会话目录已按 /home/dsh 改名，直接覆盖会与旧名目录撞车）、
#            跳过 profiles（目标侧已装 dsh-docker 插件并重链 store，保留其状态）、
#            路径改写含会话文件首帧（--headers）。
set -euo pipefail

SSH_OPTS=(-F /dev/null -o StrictHostKeyChecking=accept-new -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR)
DHOST="${DHOST:-}"   # 由 local.env 或环境变量提供
IMAGE="${IMAGE:-ghcr.io/xylz0928/dsh-docker:latest}"
REPO_DIR="$(cd "$(dirname "$0")/.." && pwd)"
# 本机私有配置（gitignored）：DHOST / DSH_SSH / PORTAINER_* / DSH_PUBLIC_URL ...
if [[ -f "$REPO_DIR/local.env" ]]; then set -a; source "$REPO_DIR/local.env"; set +a; fi
: "${DHOST:?set DHOST（写进 local.env 或环境变量）}"
FINAL=0
DEEP=""
case "${1:-}" in
  --rewrite-headers) DEEP="--headers" ;;
  --final) FINAL=1; DEEP="--headers" ;;
esac

run_dhost() { ssh "${SSH_OPTS[@]}" "$DHOST" "$@"; }

echo "== 1. dhost：卷与目录 =="
run_dhost 'docker volume create dsh-config >/dev/null
           docker volume create dsh-data >/dev/null
           docker volume create dsh-plugins >/dev/null
           docker volume create dsh-skills >/dev/null
           mkdir -p /mnt/docker-files/dsh/workspace
           echo "   volumes ok"'

echo "== 2. ~/.dsh → dsh-data（排除 plugins${FINAL:+；final：先清 sessions/storages、排除 profiles}）=="
if [[ "$FINAL" == "1" ]]; then
  # 收尾迁移：目标侧会话目录已按 /home/dsh 改名，源侧新文件仍带旧名 ——
  # 直接覆盖会把同一会话拆进两个目录，必须先清再全量重灌；profiles 保留目标侧
  # 已装的 dsh-docker 插件与 store 重链状态。
  run_dhost "docker run --rm -v dsh-data:/target $IMAGE sh -c 'rm -rf /target/sessions /target/storages'"
  tar -C "$HOME/.dsh" --exclude='./plugins' --exclude='./skills' --exclude='./profiles' -cf - . \
    | run_dhost "docker run --rm -i -v dsh-data:/target $IMAGE tar -C /target -xf -"
else
  tar -C "$HOME/.dsh" --exclude='./plugins' --exclude='./skills' -cf - . \
    | run_dhost "docker run --rm -i -v dsh-data:/target $IMAGE tar -C /target -xf -"
fi
echo "   done"

echo "== 3. ~/.dsh/plugins → dsh-plugins =="
tar -C "$HOME/.dsh/plugins" -cf - . \
  | run_dhost "docker run --rm -i -v dsh-plugins:/target $IMAGE tar -C /target -xf -"
echo "   done"

echo "== 3b. ~/.dsh/skills → dsh-skills（独立卷，供其它 Agent 容器共用）=="
tar -C "$HOME/.dsh/skills" -cf - . \
  | run_dhost "docker run --rm -i -v dsh-skills:/target $IMAGE tar -C /target -xf -"
echo "   done"

echo "== 4. HOME 骨架 → dsh-config（不含 .ssh）=="
SKEL=()
for p in .gitconfig .git-credentials .bashrc .profile .config/zed; do
  [[ -e "$HOME/$p" ]] && SKEL+=("$p")
done
if [[ ${#SKEL[@]} -gt 0 ]]; then
  tar -C "$HOME" "${SKEL[@]}" -cf - \
    | run_dhost "docker run --rm -i -v dsh-config:/target $IMAGE tar -C /target -xf -"
  echo "   ${SKEL[*]}"
fi

echo "== 5. ~/coding → /mnt/docker-files/dsh/workspace =="
# -h（解引用）：workspace 落在 CIFS（Synology），该挂载建不了符号链接
# （.venv/bin、node_modules/.bin 等会报 Operation not supported 并让 tar 非零退出），
# 统一拷成普通文件；venv / .bin 这类可随时重建的链接无碍功能。
tar -C "$HOME/coding" -h -cf - . \
  | run_dhost 'tar -C /mnt/docker-files/dsh/workspace -xf -'
echo "   done"

echo "== 6. 路径改写 /home/zed → /home/dsh ${DEEP:-（仅索引与目录名）} =="
run_dhost "docker run --rm -i -v dsh-data:/target $IMAGE node - /target $DEEP" \
  < "$REPO_DIR/scripts/rewrite-paths.mjs"

echo "迁移完成。"
