#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PID_FILE="$SCRIPT_DIR/.game.pid"
LOG_DIR="$SCRIPT_DIR/.game-logs"

SERVER_PORT="${PORT:-4400}"
CLIENT_PORT="${CLIENT_PORT:-4402}"

# ================================================
# Dependency checks
# ================================================

check_deps() {
  local missing=false

  if ! command -v node &>/dev/null; then
    echo "ERROR: node is not installed."
    echo "  Install Node.js >= 24: https://nodejs.org/ or use nvm:"
    echo "    curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.40.1/install.sh | bash"
    echo "    nvm install 24"
    echo ""
    missing=true
  else
    local node_major
    node_major=$(node -v | sed 's/v\([0-9]*\).*/\1/')
    if (( node_major < 24 )); then
      echo "ERROR: Node.js >= 24 is required (found $(node -v))."
      echo "  Update with nvm: nvm install 24"
      echo ""
      missing=true
    fi
  fi

  if ! command -v pnpm &>/dev/null; then
    echo "ERROR: pnpm is not installed."
    echo "  Install pnpm >= 10:"
    echo "    corepack enable && corepack prepare pnpm@latest --activate"
    echo "  Or: npm install -g pnpm"
    echo "  Or: https://pnpm.io/installation"
    echo ""
    missing=true
  else
    local pnpm_major
    pnpm_major=$(pnpm -v | sed 's/\([0-9]*\).*/\1/')
    if (( pnpm_major < 10 )); then
      echo "ERROR: pnpm >= 10 is required (found $(pnpm -v))."
      echo "  Update: corepack prepare pnpm@latest --activate"
      echo "  Or: npm install -g pnpm@latest"
      echo ""
      missing=true
    fi
  fi

  if $missing; then
    echo "Fix the above and try again."
    exit 1
  fi

}

usage() {
  cat <<EOF
Base Multiplayer Game - run.sh

Usage: ./run.sh [OPTIONS]

Options:
  --help          Show this help message
  --install       Run pnpm install before starting
  --server-only   Start only the game server
  --client-only   Start only the client dev server
  --stop          Stop running processes
  --status        Check if services are running
  --logs          Tail the server and client logs

Environment variables:
  PORT            Game server port    (default: 4400)
  CLIENT_PORT     Angular client port (default: 4402)

EOF
  exit 0
}

kill_tree() {
  local pid="$1"
  # Kill all descendants first (children, grandchildren, etc.)
  local children
  children=$(pgrep -P "$pid" 2>/dev/null) || true
  for child in $children; do
    kill_tree "$child"
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill "$pid" 2>/dev/null
  fi
}

stop_processes() {
  local any_stopped=false

  # 1. Kill recorded PIDs and their entire process trees
  if [[ -f "$PID_FILE" ]]; then
    while read -r pid; do
      if kill -0 "$pid" 2>/dev/null; then
        kill_tree "$pid"
        echo "    Stopped process tree for PID $pid"
        any_stopped=true
      fi
    done < "$PID_FILE"
    rm -f "$PID_FILE"
  fi

  # 2. Kill any orphaned tsx watch processes for the server
  local orphans
  orphans=$(pgrep -f 'tsx.*watch.*src/index\.ts' 2>/dev/null) || true
  for pid in $orphans; do
    kill_tree "$pid"
    echo "    Stopped orphaned server process $pid"
    any_stopped=true
  done

  # 3. Kill anything still listening on the server port
  local port_pids
  port_pids=$(lsof -ti :"$SERVER_PORT" 2>/dev/null) || true
  for pid in $port_pids; do
    kill "$pid" 2>/dev/null && echo "    Stopped process $pid on port $SERVER_PORT"
    any_stopped=true
  done

  if $any_stopped; then
    # Give processes a moment to exit
    sleep 0.5
    return 0
  fi
  return 1
}

do_stop() {
  echo "==> Stopping Base Multiplayer Game..."
  if stop_processes; then
    echo "    Done."
  else
    echo "Base Multiplayer Game is not running."
  fi
  exit 0
}

do_status() {
  if [[ ! -f "$PID_FILE" ]]; then
    echo "Base Multiplayer Game is not running."
    exit 0
  fi

  all_dead=true
  while read -r pid; do
    if kill -0 "$pid" 2>/dev/null; then
      echo "Running: PID $pid"
      all_dead=false
    else
      echo "Dead:    PID $pid"
    fi
  done < "$PID_FILE"

  if $all_dead; then
    rm -f "$PID_FILE"
    echo "Base Multiplayer Game is not running (stale PID file cleaned up)."
  fi
  exit 0
}

do_logs() {
  if [[ ! -d "$LOG_DIR" ]]; then
    echo "No logs found. Is Base Multiplayer Game running?"
    exit 1
  fi
  tail -f "$LOG_DIR"/*.log
  exit 0
}

DO_INSTALL=false
RUN_SERVER=true
RUN_CLIENT=true

for arg in "$@"; do
  case "$arg" in
    --help)        usage ;;
    --stop)        do_stop ;;
    --status)      do_status ;;
    --logs)        do_logs ;;
    --install)     DO_INSTALL=true ;;
    --server-only) RUN_CLIENT=false ;;
    --client-only) RUN_SERVER=false ;;
    *)
      echo "Unknown option: $arg"
      echo "Run ./run.sh --help for usage."
      exit 1
      ;;
  esac
done

# Verify required tools are available before starting
check_deps

# Always clean up any existing server processes before starting
echo "==> Cleaning up old processes..."
if stop_processes; then
  echo "    Cleaned up old processes."
fi

if $DO_INSTALL; then
  echo "==> Installing dependencies..."
  pnpm install
fi

if [[ ! -d "$SCRIPT_DIR/node_modules" ]]; then
  echo "ERROR: node_modules not found. Dependencies have not been installed."
  echo "  Run: pnpm install"
  echo "  Or:  ./run.sh --install"
  exit 1
fi

mkdir -p "$LOG_DIR"
> "$PID_FILE"

if $RUN_SERVER; then
  echo "==> Starting game server on port ${SERVER_PORT}..."
  PORT="$SERVER_PORT" pnpm dev:server > "$LOG_DIR/server.log" 2>&1 &
  echo $! >> "$PID_FILE"
fi

if $RUN_CLIENT; then
  echo "==> Starting Angular client on port ${CLIENT_PORT}..."
  pnpm dev:client > "$LOG_DIR/client.log" 2>&1 &
  echo $! >> "$PID_FILE"
fi

echo ""
echo "============================================"
echo "  Base Multiplayer Game is running!"
echo ""
if $RUN_SERVER; then
echo "  Server (API/WS): http://localhost:${SERVER_PORT}"
fi
if $RUN_CLIENT; then
echo "  Game URL:         http://localhost:${CLIENT_PORT}"
fi
echo ""
echo "  ./run.sh --stop     Stop the game"
echo "  ./run.sh --status   Check status"
echo "  ./run.sh --logs     Tail logs"
echo "============================================"
