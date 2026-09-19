#!/usr/bin/env bash
#
# Portal 构建与上线前检查流水线
#
# 用法:
#   scripts/ci.sh                 完整流程: clean → deps → typecheck → build → docker → smoke
#   scripts/ci.sh all             同上
#   scripts/ci.sh <步骤>          只重跑某一步 (如: scripts/ci.sh smoke)
#   scripts/ci.sh --from <步骤>   从某一步开始继续跑 (如: scripts/ci.sh --from build)
#   scripts/ci.sh --local         跳过 Docker 步骤，冒烟测试改用本地 vite preview
#   scripts/ci.sh --list          列出所有步骤
#
# 约定:
#   - 端口口径统一来自根目录 .env (PORTAL_PORT)，本地开发与容器对外一致
#   - 依赖安装统一 npm ci + frontend-portal/.npmrc
#   - 每步日志写入 .ci/logs/，失败时打印末尾日志与重跑命令
#   - 冒烟产生的临时容器/进程/文件在退出时自动清理，不残留中间产物
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_DIR="$ROOT_DIR/frontend-portal"
CI_DIR="$ROOT_DIR/.ci"
LOG_DIR="$CI_DIR/logs"
TMP_DIR="$CI_DIR/tmp"

# ---- 环境：端口单一来源 ----
if [ -f "$ROOT_DIR/.env" ]; then
  set -a
  # shellcheck disable=SC1091
  . "$ROOT_DIR/.env"
  set +a
fi
PORTAL_PORT="${PORTAL_PORT:-8081}"
SMOKE_PORT="${SMOKE_PORT:-18081}"

# ---- 版本信息：产物可对应到具体代码版本 ----
APP_VERSION="$(node -p "require('$APP_DIR/package.json').version" 2>/dev/null || echo 'dev')"
RAW_COMMIT="$(git -C "$ROOT_DIR" rev-parse --short HEAD 2>/dev/null || echo 'unknown')"
GIT_COMMIT="$RAW_COMMIT"
if ! git -C "$ROOT_DIR" diff --quiet 2>/dev/null || ! git -C "$ROOT_DIR" diff --cached --quiet 2>/dev/null; then
  GIT_COMMIT="$RAW_COMMIT-dirty"
fi
IMAGE_NAME="portal-frontend"
IMAGE_TAG="$IMAGE_NAME:$APP_VERSION-$GIT_COMMIT"

STEPS=(clean deps typecheck build docker smoke)
LOCAL_ONLY=0
DOCKER_MODE="unavailable"

# ---- 输出辅助 ----
if [ -t 1 ]; then
  C_RED=$'\033[31m'; C_GREEN=$'\033[32m'; C_YELLOW=$'\033[33m'; C_BLUE=$'\033[34m'; C_BOLD=$'\033[1m'; C_OFF=$'\033[0m'
else
  C_RED=''; C_GREEN=''; C_YELLOW=''; C_BLUE=''; C_BOLD=''; C_OFF=''
fi
info()  { echo "${C_BLUE}==>${C_OFF} $*"; }
ok()    { echo "${C_GREEN}✓${C_OFF} $*"; }
warn()  { echo "${C_YELLOW}!${C_OFF} $*"; }
fail()  { echo "${C_RED}✗ $*${C_OFF}" >&2; }

step_title() {
  case "$1" in
    clean)     echo "清理上次失败的中间产物" ;;
    deps)      echo "安装依赖 (npm ci，与容器同口径)" ;;
    typecheck) echo "类型检查 (vue-tsc)" ;;
    build)     echo "构建产物 (vite build + 版本元数据)" ;;
    docker)    echo "构建镜像 ($IMAGE_TAG)" ;;
    smoke)     echo "冒烟测试 (接口响应校验)" ;;
    *)         echo "$1" ;;
  esac
}

# ---- 清理：退出时回收冒烟测试的临时资源 ----
SMOKE_CONTAINER=""
PREVIEW_PID=""
cleanup() {
  [ -n "$SMOKE_CONTAINER" ] && docker rm -f "$SMOKE_CONTAINER" >/dev/null 2>&1 || true
  [ -n "$PREVIEW_PID" ] && kill "$PREVIEW_PID" 2>/dev/null || true
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

docker_available() {
  command -v docker >/dev/null 2>&1 && docker info >/dev/null 2>&1
}

# ============================================================
# 步骤定义
# ============================================================

step_clean() {
  echo "删除构建产物: frontend-portal/dist"
  rm -rf "$APP_DIR/dist"
  echo "删除流水线临时目录: .ci/tmp"
  rm -rf "$TMP_DIR"
  mkdir -p "$TMP_DIR"
  if docker_available; then
    # 清理上次失败可能残留的冒烟容器
    local orphans
    orphans="$(docker ps -aq --filter "name=portal-smoke-" 2>/dev/null || true)"
    if [ -n "$orphans" ]; then
      echo "清理残留冒烟容器: $orphans"
      echo "$orphans" | xargs docker rm -f >/dev/null
    fi
  fi
}

step_deps() {
  cd "$APP_DIR"
  echo "npm ci (registry 与缓存口径见 frontend-portal/.npmrc)"
  npm ci
}

step_typecheck() {
  cd "$APP_DIR"
  npm run typecheck
}

step_build() {
  cd "$APP_DIR"
  VITE_APP_VERSION="$APP_VERSION" VITE_GIT_COMMIT="$RAW_COMMIT" npm run build
  echo "--- 校验产物 ---"
  [ -f dist/index.html ] || { echo "缺少 dist/index.html"; return 1; }
  [ -f dist/build-meta.json ] || { echo "缺少 dist/build-meta.json"; return 1; }
  cat dist/build-meta.json
  node -e "
    const m = require('$APP_DIR/dist/build-meta.json')
    if (m.commit !== '$RAW_COMMIT') {
      console.error(\`产物 commit(\${m.commit}) 与当前代码(\$RAW_COMMIT) 不一致\`)
      process.exit(1)
    }
    console.log('产物版本与当前代码一致:', m.version + '@' + m.commit)
  "
}

step_docker() {
  if [ "$LOCAL_ONLY" = "1" ]; then
    warn "已指定 --local，跳过镜像构建"
    return 0
  fi
  if ! docker_available; then
    if [ "${EXPLICIT_STEP:-0}" = "1" ]; then
      echo "Docker 不可用（未安装或 daemon 未运行），无法构建镜像" >&2
      return 1
    fi
    warn "Docker 不可用，跳过镜像构建（冒烟测试将使用本地 vite preview）"
    return 0
  fi
  docker build \
    --build-arg APP_VERSION="$APP_VERSION" \
    --build-arg GIT_COMMIT="$RAW_COMMIT" \
    -t "$IMAGE_TAG" \
    -t "$IMAGE_NAME:latest" \
    "$APP_DIR"
  echo "--- 镜像版本 label ---"
  docker inspect -f 'version={{ index .Config.Labels "org.opencontainers.image.version" }} revision={{ index .Config.Labels "org.opencontainers.image.revision" }}' "$IMAGE_TAG"
}

# ---- 冒烟测试辅助 ----

# 等待 URL 可访问: wait_for_url <url> <秒数>
wait_for_url() {
  local url="$1" tries="$2" i
  for i in $(seq 1 "$tries"); do
    if curl -sf -o /dev/null --max-time 2 "$url" 2>/dev/null; then
      return 0
    fi
    sleep 1
  done
  return 1
}

# HTTP 检查: check_http <描述> <url> <期望状态码> [响应应包含的内容]
check_http() {
  local desc="$1" url="$2" want_code="$3" want_body="${4:-}"
  local body="$TMP_DIR/smoke-body.out" code
  if ! code="$(curl -sS -o "$body" -w '%{http_code}' --max-time 10 "$url" 2>"$TMP_DIR/smoke-curl.err")"; then
    echo "  ✗ $desc: 请求失败 $url —— $(cat "$TMP_DIR/smoke-curl.err")"
    return 1
  fi
  if [ "$code" != "$want_code" ]; then
    echo "  ✗ $desc: $url 期望 HTTP $want_code，实际 HTTP $code"
    head -c 300 "$body" | sed 's/^/      /'
    return 1
  fi
  if [ -n "$want_body" ] && ! grep -qF "$want_body" "$body"; then
    echo "  ✗ $desc: $url 响应中未找到期望内容: $want_body"
    head -c 300 "$body" | sed 's/^/      /'
    return 1
  fi
  echo "  ✓ $desc: $url → HTTP $code"
}

# 校验线上产物版本与当前代码一致
check_build_meta() {
  local base="$1" meta="$TMP_DIR/build-meta.json"
  if ! curl -sfS --max-time 10 -o "$meta" "$base/build-meta.json" 2>/dev/null; then
    echo "  ✗ 版本元数据: $base/build-meta.json 不可访问"
    return 1
  fi
  local got
  got="$(node -p "JSON.parse(require('fs').readFileSync('$meta', 'utf8')).commit" 2>/dev/null || echo '')"
  if [ "$got" != "$RAW_COMMIT" ]; then
    echo "  ✗ 版本元数据: 部署产物 commit=$got，当前代码 commit=$RAW_COMMIT，版本不对应"
    return 1
  fi
  echo "  ✓ 版本元数据: commit=$got 与当前代码一致 ($(node -p "JSON.parse(require('fs').readFileSync('$meta','utf8')).version"))"
}

smoke_via_docker() {
  echo "  模式: Docker 容器 (镜像 $IMAGE_TAG, 端口 $SMOKE_PORT)"
  docker image inspect "$IMAGE_TAG" >/dev/null 2>&1 || {
    echo "  镜像 $IMAGE_TAG 不存在，请先运行: scripts/ci.sh docker"
    return 1
  }
  SMOKE_CONTAINER="portal-smoke-$$"
  docker run -d --name "$SMOKE_CONTAINER" -p "$SMOKE_PORT:80" "$IMAGE_TAG" >/dev/null
  local base="http://127.0.0.1:$SMOKE_PORT"
  if ! wait_for_url "$base/healthz" 30; then
    echo "  ✗ 容器 30s 内未就绪，最近日志:"
    docker logs --tail 20 "$SMOKE_CONTAINER" 2>&1 | sed 's/^/      /'
    return 1
  fi
  check_http "健康检查" "$base/healthz" 200 "ok" &&
  check_http "首页响应" "$base/" 200 'id="app"' &&
  check_build_meta "$base"
  local rc=$?
  docker rm -f "$SMOKE_CONTAINER" >/dev/null 2>&1 || true
  SMOKE_CONTAINER=""
  return $rc
}

smoke_via_preview() {
  [ -d "$APP_DIR/dist" ] || {
    echo "  frontend-portal/dist 不存在，请先运行: scripts/ci.sh build"
    return 1
  }
  echo "  模式: 本地 vite preview (端口 $SMOKE_PORT；/healthz 为 nginx 专有，此处跳过)"
  # 经 exec 直接运行 vite，保证 $! 就是服务进程本身，kill 不会留下孤儿进程
  (cd "$APP_DIR" && exec ./node_modules/.bin/vite preview --port "$SMOKE_PORT" --strictPort) >"$TMP_DIR/preview.log" 2>&1 &
  PREVIEW_PID=$!
  local base="http://127.0.0.1:$SMOKE_PORT"
  if ! wait_for_url "$base/" 30; then
    echo "  ✗ preview 服务 30s 内未就绪，日志:"
    sed 's/^/      /' "$TMP_DIR/preview.log"
    return 1
  fi
  check_http "首页响应" "$base/" 200 'id="app"' &&
  check_build_meta "$base"
  local rc=$?
  kill "$PREVIEW_PID" 2>/dev/null || true
  wait "$PREVIEW_PID" 2>/dev/null || true
  PREVIEW_PID=""
  return $rc
}

step_smoke() {
  mkdir -p "$TMP_DIR"
  if [ "$LOCAL_ONLY" != "1" ] && docker_available && docker image inspect "$IMAGE_TAG" >/dev/null 2>&1; then
    smoke_via_docker
  else
    smoke_via_preview
  fi
}

# ============================================================
# 运行框架
# ============================================================

run_step() {
  local name="$1" idx="$2" total="$3"
  local log="$LOG_DIR/$(printf '%02d' "$idx")-$name.log"
  info "${C_BOLD}[$idx/$total] $name${C_OFF} —— $(step_title "$name")"
  local start=$SECONDS
  if "step_$name" >"$log" 2>&1; then
    ok "[$idx/$total] $name 完成 ($((SECONDS - start))s)，日志: ${log#"$ROOT_DIR"/}"
    # 关键输出透传到终端（产物元数据、镜像 label、冒烟逐项结果）
    grep -E '^\s*(✓|✗|版本|\{|\}|"|---|mode|模式)' "$log" | head -30 || true
  else
    local rc=$?
    echo "" >&2
    fail "[$idx/$total] 步骤 '$name' 失败 (退出码 $rc)"
    echo "  日志 ${log#"$ROOT_DIR"/} 末尾 20 行:" >&2
    tail -20 "$log" | sed 's/^/    /' >&2
    echo "" >&2
    echo "  重跑本步:    scripts/ci.sh $name" >&2
    echo "  从此步继续:  scripts/ci.sh --from $name" >&2
    exit "$rc"
  fi
}

usage() {
  sed -n '2,18p' "${BASH_SOURCE[0]}" | sed 's/^# \{0,1\}//'
}

main() {
  local from_step="" only_step=""
  while [ $# -gt 0 ]; do
    case "$1" in
      all)            shift ;;
      --local)        LOCAL_ONLY=1; shift ;;
      --from)         from_step="${2:?--from 需要步骤名}"; shift 2 ;;
      --list)         printf '%s\n' "${STEPS[@]}"; exit 0 ;;
      -h|--help)      usage; exit 0 ;;
      clean|deps|typecheck|build|docker|smoke) only_step="$1"; EXPLICIT_STEP=1; shift ;;
      *) echo "未知参数: $1" >&2; usage >&2; exit 64 ;;
    esac
  done

  # 校验步骤名
  if [ -n "$from_step" ] && ! printf '%s\n' "${STEPS[@]}" | grep -qx "$from_step"; then
    echo "未知步骤: $from_step (可选: ${STEPS[*]})" >&2; exit 64
  fi

  # 确定要执行的步骤序列
  local plan=()
  if [ -n "$only_step" ]; then
    plan=("$only_step")
  elif [ -n "$from_step" ]; then
    local hit=0 s
    for s in "${STEPS[@]}"; do
      [ "$s" = "$from_step" ] && hit=1
      [ "$hit" = "1" ] && plan+=("$s")
    done
  else
    plan=("${STEPS[@]}")
  fi

  docker_available && DOCKER_MODE="available"

  # 每次运行重建日志目录，不残留上次失败的内容
  rm -rf "$LOG_DIR"
  mkdir -p "$LOG_DIR" "$TMP_DIR"

  echo "${C_BOLD}========================================${C_OFF}"
  echo "${C_BOLD} Portal 构建与上线前检查流水线${C_OFF}"
  echo " 版本:   $APP_VERSION"
  echo " 提交:   $GIT_COMMIT"
  echo " 端口:   $PORTAL_PORT (来源: 根目录 .env)"
  echo " Docker: $DOCKER_MODE$([ "$LOCAL_ONLY" = "1" ] && echo ' (--local 强制跳过)')"
  echo " 步骤:   ${plan[*]}"
  echo "${C_BOLD}========================================${C_OFF}"

  local i=0 total=${#plan[@]} s
  for s in "${plan[@]}"; do
    i=$((i + 1))
    run_step "$s" "$i" "$total"
  done

  echo ""
  ok "${C_BOLD}流水线全部通过${C_OFF} —— 产物: frontend-portal/dist ($APP_VERSION@$GIT_COMMIT)"
  if docker_available && [ "$LOCAL_ONLY" != "1" ]; then
    echo "  镜像: $IMAGE_TAG (另附 $IMAGE_NAME:latest)"
  fi
  echo "  上线前可访问 http://localhost:$PORTAL_PORT 复核"
}

main "$@"
