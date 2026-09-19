#!/usr/bin/env bash
#
# 本地"构建产物"冒烟：构建 -> 起 vite preview -> 执行 smoke.mjs -> 退出即停掉 preview
# 用于不依赖 Docker 也能在本地/CI 上验证产物。
#
# 用法：
#   ./scripts/local-smoke.sh             # 构建并冒烟
#   PORT=8081 ./scripts/local-smoke.sh   # 指定端口（默认读根目录 .env）
#
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR/frontend-portal"

if [[ -f "$ROOT_DIR/.env" ]]; then
  set -a
  # shellcheck disable=SC1091
  source "$ROOT_DIR/.env"
  set +a
fi
PORT="${PORT:-8081}"
export PORT
LOG_FILE="/tmp/portal-preview.$$.log"
CHILD_PIDS=()
NPM_PID=""

# 通过 /proc 反查监听端口的 PID（不依赖 ss/lsof/fuser）
listener_pid() {
  node "$ROOT_DIR/scripts/port-pid.mjs" "$1" 2>/dev/null || true
}

# 递归收集子孙进程
collect_children() {
  local parent=$1
  local child
  while IFS= read -r child; do
    [[ -z "$child" ]] && continue
    CHILD_PIDS+=("$child")
    collect_children "$child"
  done < <(ps -o pid= --ppid "$parent" 2>/dev/null | tr -d ' ')
}

cleanup() {
  # npm 会派生 vite/esbuild 子进程。注意：先杀 npm 会让 vite/esbuild 被
  # init 收养而成为孤儿，之后无法再按进程树回收。因此先收集整棵进程树，
  # 再从监听端口的叶子进程开始一次性回收，保证不留任何中间产物/进程。
  local pid
  CHILD_PIDS=()
  pid=$(listener_pid "$PORT" || true)
  if [[ -n "$pid" ]]; then
    CHILD_PIDS+=("$pid")
    collect_children "$pid"
  fi
  [[ -n "${NPM_PID:-}" ]] && CHILD_PIDS+=("$NPM_PID")
  # 去重后一并发送 TERM
  if [[ ${#CHILD_PIDS[@]} -gt 0 ]]; then
    local uniq_pids
    uniq_pids=$(printf '%s\n' "${CHILD_PIDS[@]}" | sort -u | tr '\n' ' ')
    # shellcheck disable=SC2086
    kill $uniq_pids 2>/dev/null || true
  fi
  rm -f "$LOG_FILE"
}
trap cleanup EXIT

# 启动前确认端口没有上一次失败遗留的进程（strictPort 也会兜底，但报错信息不直观）
if [[ -n "$(listener_pid "$PORT" || true)" ]]; then
  echo "✘ 端口 ${PORT} 已被占用（PID: $(listener_pid "$PORT")），可能是上次冒烟遗留的 preview 进程" >&2
  echo "  处理: kill $(listener_pid "$PORT")" >&2
  exit 1
fi

echo "▶ 构建生产产物（npm run build）"
npm run build

echo "▶ 启动 vite preview（端口 ${PORT}）"
npm run preview -- --port "$PORT" >"$LOG_FILE" 2>&1 &
NPM_PID=$!

# 等待服务就绪（最多 30s）
ready=0
for _ in $(seq 1 30); do
  if node -e "fetch('http://127.0.0.1:${PORT}/healthz').then(r=>process.exit(r.ok?0:1)).catch(()=>process.exit(1))" 2>/dev/null; then
    ready=1
    break
  fi
  if ! kill -0 "$NPM_PID" 2>/dev/null; then
    cat "$LOG_FILE" >&2
    echo "✘ vite preview 进程异常退出（见上方日志）" >&2
    exit 1
  fi
  sleep 1
done

if [[ $ready -ne 1 ]]; then
  cat "$LOG_FILE" >&2
  echo "✘ vite preview 在 30s 内未就绪（见上方日志）" >&2
  exit 1
fi

echo "▶ 执行冒烟检查"
BASE_URL="http://127.0.0.1:${PORT}" node "$ROOT_DIR/scripts/smoke.mjs"

echo "✔ 本地冒烟通过"
