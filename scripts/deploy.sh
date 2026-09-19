#!/usr/bin/env bash
#
# 构建与上线前检查的串联流程：
#
#   ① 读取/生成版本信息（git commit、分支、package.json version）
#   ② docker compose build            —— 构建带版本标签的镜像
#   ③ 启动一次性临时容器（空闲随机端口）
#   ④ 等待 healthy → 对临时容器执行冒烟检查
#   ⑤ 冒烟通过才 docker compose up -d 正式切换；失败销毁临时容器并退出非 0
#
# 特性：
#   - 任何一步失败立即停止；set -euo pipefail + trap 保证不留上次失败的临时容器
#   - 幂等可重跑：临时容器名固定加 smoke 前缀，启动前先清理同名残留
#   - 可只跑其中一段（参数化），失败后重跑不需要从头再来：
#       ./scripts/deploy.sh build     仅构建镜像
#       ./scripts/deploy.sh verify    仅对已构建镜像起临时容器做冒烟
#       ./scripts/deploy.sh up        仅正式上线
#       ./scripts/deploy.sh all       全流程（默认）
#   - 想重试某个接口检查：API_CHECKS='...' ./scripts/deploy.sh verify
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# ---------- 加载根目录 .env（PORT / BACKEND_URL 等，与 compose 同一来源） ----------
if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi
PORT="${PORT:-8081}"
CONTAINER_PORT="${CONTAINER_PORT:-8081}"
export PORT CONTAINER_PORT

# ---------- 版本信息（产物对应到具体代码提交） ----------
export VCS_REF="${VCS_REF:-$(git -c safe.directory='*' rev-parse --short HEAD 2>/dev/null || echo unknown)}"
export VCS_BRANCH="${VCS_BRANCH:-$(git -c safe.directory='*' rev-parse --abbrev-ref HEAD 2>/dev/null || echo unknown)}"
export APP_VERSION="${APP_VERSION:-$(node -p "require('./frontend-portal/package.json').version" 2>/dev/null || echo 0.0.0)}"
export BUILD_DATE="${BUILD_DATE:-$(date -u +%Y-%m-%dT%H:%M:%SZ)}"

IMAGE="portal-frontend:${VCS_REF}"
SMOKE_NAME="portal-frontend-smoke-$$"
SMOKE_PORT=""

log()  { printf '\n\033[1;36m▶ [%s] %s\033[0m\n' "$(date +%H:%M:%S)" "$*"; }
ok()   { printf '\033[1;32m✔ %s\033[0m\n' "$*"; }
die()  { printf '\n\033[1;31m✘ %s\033[0m\n' "$*" >&2; exit 1; }

# 选一个当前空闲的宿主机端口供临时容器使用（不影响正在跑的正式容器）
free_port() {
  node -e '
    const net = require("net");
    const s = net.createServer();
    s.listen(0, "127.0.0.1", () => { console.log(s.address().port); s.close(); });
  '
}

cleanup() {
  local rc=$?
  if [[ -n "$SMOKE_NAME" ]] && docker ps -a --format '{{.Names}}' | grep -q "^${SMOKE_NAME}$"; then
    log "清理临时冒烟容器 ${SMOKE_NAME}"
    docker rm -f "$SMOKE_NAME" >/dev/null 2>&1 || true
  fi
  if [[ $rc -ne 0 ]]; then
    printf '\n\033[1;31m✘ 流程失败（退出码 %s）。未对正式环境做任何变更，可修复后直接重跑本脚本。\033[0m\n' "$rc" >&2
  fi
  exit $rc
}
trap cleanup EXIT

compose() { docker compose "$@"; }

do_build() {
  log "① 构建镜像 ${IMAGE}（branch=${VCS_BRANCH}, version=${APP_VERSION}, builtAt=${BUILD_DATE}）"
  compose build
  ok "镜像构建完成: ${IMAGE}"
}

wait_healthy() {
  local name=$1 timeout_s=${SMOKE_TIMEOUT:-60} waited=0
  log "等待容器 ${name} 健康（最多 ${timeout_s}s）"
  while (( waited < timeout_s )); do
    local status
    status=$(docker inspect -f '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}' "$name" 2>/dev/null || echo missing)
    case "$status" in
      healthy) ok "容器已健康（${waited}s）"; return 0 ;;
      unhealthy)
        docker logs --tail 50 "$name" >&2 || true
        die "容器健康检查失败（unhealthy），以上为容器日志"
        ;;
    esac
    sleep 2
    waited=$((waited + 2))
  done
  docker logs --tail 50 "$name" >&2 || true
  die "等待容器健康超时（${timeout_s}s）"
}

do_verify() {
  docker image inspect "$IMAGE" >/dev/null 2>&1 || die "镜像 ${IMAGE} 不存在，请先执行: $0 build"

  SMOKE_PORT=$(free_port)
  log "② 启动一次性临时容器: 127.0.0.1:${SMOKE_PORT} -> ${CONTAINER_PORT}"
  # 清理同名残留（上一次失败遗留时也能干净重跑）
  docker ps -a --format '{{.Names}}' | grep -q "^${SMOKE_NAME}$" && docker rm -f "$SMOKE_NAME" >/dev/null || true
  docker run -d --name "$SMOKE_NAME" \
    -p "127.0.0.1:${SMOKE_PORT}:${CONTAINER_PORT}" \
    -e CONTAINER_PORT="${CONTAINER_PORT}" \
    -e BACKEND_URL="${BACKEND_URL:-http://host.docker.internal:8080}" \
    --add-host host.docker.internal:host-gateway \
    "$IMAGE" >/dev/null

  wait_healthy "$SMOKE_NAME"

  log "③ 对临时容器执行冒烟检查 127.0.0.1:${SMOKE_PORT}"
  BASE_URL="http://127.0.0.1:${SMOKE_PORT}" node scripts/smoke.mjs
  ok "冒烟检查通过"

  log "④ 销毁临时容器"
  docker rm -f "$SMOKE_NAME" >/dev/null
  SMOKE_NAME=""
}

do_up() {
  log "⑤ 正式上线（滚动重建，对外端口 ${PORT}）"
  compose up -d
  ok "已发布: http://localhost:${PORT}（镜像 ${IMAGE}）"
  cat <<EOF

  版本核对:
    curl -s http://localhost:${PORT}/version.json
  存活探针:
    curl -i http://localhost:${PORT}/healthz

EOF
}

main() {
  local stage=${1:-all}
  case "$stage" in
    build)  do_build ;;
    verify) do_verify ;;
    up)    do_up ;;
    all)   do_build; do_verify; do_up ;;
    *)     die "未知参数: $stage（可选: build | verify | up | all）" ;;
  esac
  ok "完成: ${stage}"
}

main "$@"
