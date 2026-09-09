#!/usr/bin/env bash
set -euo pipefail

# ---------------------------------------------------------------------------
# dev-container.sh — Start, rebuild, or exec into the Base Multiplayer Game dev container
#
# Usage:
#   ./dev-container.sh          # Start or attach
#   ./dev-container.sh rebuild  # Force rebuild
#   ./dev-container.sh stop     # Stop the container
#   ./dev-container.sh status   # Show container status
# ---------------------------------------------------------------------------

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Container/image/volume names are DERIVED from the workspace folder name (matches
# devcontainer.json's ${localWorkspaceFolderBasename}-dind). Copy this project to any
# folder and the names follow it — no per-project edits, no cross-project clashes.
PROJECT_SLUG="$(basename "$SCRIPT_DIR" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9_.-' '-' | sed 's/--*/-/g; s/^-//; s/-$//')"
CONTAINER_NAME="${PROJECT_SLUG}-dev"
IMAGE_NAME="${PROJECT_SLUG}-dev-image"
CHECKSUM_FILE="$SCRIPT_DIR/.devcontainer/.build-checksum"
DIND_VOLUME="${PROJECT_SLUG}-dind"

# Host ports this game publishes. presetup.sh rewrites these per game; new-game.sh assigns a
# FREE pair at scaffold time so two games never fight over the same ports.
SERVER_PORT=4400
CLIENT_PORT=4402

# Files that trigger a rebuild when changed
BUILD_FILES=(
  "$SCRIPT_DIR/.devcontainer/devcontainer.json"
  "$SCRIPT_DIR/.devcontainer/Dockerfile"
  "$SCRIPT_DIR/.devcontainer/.tmux.conf"
)

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

red()    { printf '\033[1;31m%s\033[0m\n' "$*"; }
green()  { printf '\033[1;32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[1;33m%s\033[0m\n' "$*"; }
blue()   { printf '\033[1;34m%s\033[0m\n' "$*"; }

confirm_rebuild() {
  if [[ "${DEVCONTAINER_YES:-}" == "1" || ! -t 0 ]]; then
    yellow "Rebuilding dev container (auto-confirmed: non-interactive)."
    return 0
  fi
  yellow "WARNING: Dev container will be rebuilt. This will stop the running container and reinstall dependencies."
  printf '\033[1;33m%s\033[0m' "Continue? [y/N] "
  read -r answer
  case "$answer" in
    [yY][eE][sS]|[yY]) return 0 ;;
    *) yellow "Rebuild cancelled."; exit 0 ;;
  esac
}

compute_checksum() {
  cat "${BUILD_FILES[@]}" 2>/dev/null | sha256sum | awk '{print $1}'
}

stored_checksum() {
  if [[ -f "$CHECKSUM_FILE" ]]; then
    cat "$CHECKSUM_FILE"
  else
    echo "none"
  fi
}

save_checksum() {
  compute_checksum > "$CHECKSUM_FILE"
}

needs_rebuild() {
  local current stored
  current="$(compute_checksum)"
  stored="$(stored_checksum)"

  if [[ "$current" != "$stored" ]]; then
    return 0  # true, needs rebuild
  fi

  # Also rebuild if image doesn't exist
  if ! docker image inspect "$IMAGE_NAME" &>/dev/null; then
    return 0
  fi

  return 1  # false, no rebuild needed
}

container_exists() {
  docker container inspect "$CONTAINER_NAME" &>/dev/null
}

container_running() {
  [[ "$(docker container inspect -f '{{.State.Running}}' "$CONTAINER_NAME" 2>/dev/null)" == "true" ]]
}

# ---------------------------------------------------------------------------
# Actions
# ---------------------------------------------------------------------------

do_build() {
  blue "Building dev container image..."
  docker build \
    -t "$IMAGE_NAME" \
    -f "$SCRIPT_DIR/.devcontainer/Dockerfile" \
    "$SCRIPT_DIR/.devcontainer"
  save_checksum
  green "Image built successfully."
}

do_create() {
  # Remove old container if it exists
  if container_exists; then
    yellow "Removing old container..."
    docker rm -f "$CONTAINER_NAME" &>/dev/null || true
  fi

  blue "Creating container..."

  # Host config mounted into the container (mirrors devcontainer.json "mounts"):
  #   ~/.claude      Claude Code state + plugins (rw)
  #   ~/.config/gh   GitHub CLI auth — agents open PRs / update issues as the host user (rw so
  #                  gh can refresh tokens; the host stays the source of truth) — WORKFLOW.md
  #   ~/.gitconfig   git identity (ro)
  local host_mounts=""
  local claude_dir="${HOME}/.claude"
  if [[ -d "$claude_dir" ]]; then
    host_mounts+=" -v ${claude_dir}:/home/vscode/.claude:cached"
  else
    yellow "Warning: ~/.claude not found, skipping mount"
  fi
  if [[ -d "${HOME}/.config/gh" ]]; then
    host_mounts+=" -v ${HOME}/.config/gh:/home/vscode/.config/gh:cached"
  else
    yellow "Warning: ~/.config/gh not found — gh will be unauthenticated inside the container"
  fi
  if [[ -f "${HOME}/.gitconfig" ]]; then
    host_mounts+=" -v ${HOME}/.gitconfig:/home/vscode/.gitconfig:ro"
  fi

  # Pre-flight: our published ports must be free. Give a clear message naming the offender
  # instead of letting `docker run` fail with a cryptic "port is already allocated".
  local _p _owner
  for _p in "$SERVER_PORT" "$CLIENT_PORT"; do
    _owner="$(docker ps --filter "publish=${_p}" --format '{{.Names}}' 2>/dev/null | grep -v "^${CONTAINER_NAME}$" | head -1 || true)"
    if [[ -n "$_owner" ]]; then
      red "Port ${_p} is already in use by container '${_owner}'."
      yellow "This game uses ports ${SERVER_PORT}/${CLIENT_PORT}; you run one game container at a time."
      yellow "Stop the other game (its './dev-container.sh stop'), or scaffold games with"
      yellow "../new-game.sh — it auto-assigns a free port pair so they never collide."
      exit 1
    fi
  done

  # Create DinD volume if it doesn't exist (overlayfs can't stack on overlayfs)
  docker volume create "$DIND_VOLUME" &>/dev/null || true

  # shellcheck disable=SC2086
  docker run -d \
    --init \
    --name "$CONTAINER_NAME" \
    --privileged \
    -v "$SCRIPT_DIR:/workspace:cached" \
    -v "$DIND_VOLUME:/var/lib/docker" \
    $host_mounts \
    -p "${SERVER_PORT}:${SERVER_PORT}" \
    -p "${CLIENT_PORT}:${CLIENT_PORT}" \
    -w /workspace \
    -u vscode \
    -e "HOME=/home/vscode" \
    "$IMAGE_NAME" \
    sleep infinity

  # The workspace is a bind mount owned by the host user; tell git it is safe.
  docker exec -u root "$CONTAINER_NAME" git config --system --add safe.directory /workspace

  blue "Running pnpm install..."
  docker exec -u vscode -w /workspace "$CONTAINER_NAME" \
    pnpm install \
    || yellow "pnpm install had issues — you may need to run it manually inside the container"

  # Normalize formatting after install. presetup.sh's identity rename can shift Prettier
  # line-wrapping (it runs on the host where Prettier isn't available), so format here in
  # the container where it is. Idempotent — a no-op once the tree is already clean.
  blue "Normalizing formatting (prettier --write)..."
  docker exec -u vscode -w /workspace "$CONTAINER_NAME" \
    sh -lc 'pnpm exec prettier --write . >/dev/null 2>&1' \
    || yellow "prettier format skipped (run ./validate.sh lint to check)"

  green "Container created and ready."
}

do_exec() {
  if [[ ! -t 0 || ! -t 1 ]]; then
    green "Container '$CONTAINER_NAME' is running (no TTY — not attaching)."
    return 0
  fi
  blue "Attaching to $CONTAINER_NAME..."
  docker exec -it -u vscode -w /workspace \
    -e "HOME=/home/vscode" \
    -e "TERM=${TERM:-xterm-256color}" \
    "$CONTAINER_NAME" \
    bash -l
}

do_stop() {
  if container_running; then
    yellow "Stopping $CONTAINER_NAME..."
    docker stop "$CONTAINER_NAME"
    green "Stopped."
  else
    yellow "Container is not running."
  fi
}

do_status() {
  if container_running; then
    green "Container '$CONTAINER_NAME' is running."
    docker container inspect -f 'Created: {{.Created}}' "$CONTAINER_NAME"
    docker container inspect -f 'Ports: {{range $k, $v := .NetworkSettings.Ports}}{{$k}} -> {{(index $v 0).HostPort}} {{end}}' "$CONTAINER_NAME" 2>/dev/null || true
  elif container_exists; then
    yellow "Container '$CONTAINER_NAME' exists but is stopped."
  else
    red "Container '$CONTAINER_NAME' does not exist."
  fi

  if needs_rebuild; then
    yellow "Build files have changed — rebuild needed."
  else
    green "Build files unchanged — no rebuild needed."
  fi
}

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

main() {
  local cmd="${1:-}"

  case "$cmd" in
    rebuild)
      do_build
      do_create
      do_exec
      ;;
    stop)
      do_stop
      ;;
    status)
      do_status
      ;;
    *)
      # Default: smart start/attach
      if container_running; then
        if needs_rebuild; then
          yellow "Build files changed since last build."
          confirm_rebuild
          do_build
          do_create
        fi
        do_exec
      else
        # Need to start (and maybe build)
        if needs_rebuild; then
          confirm_rebuild
          do_build
        fi
        if container_exists; then
          blue "Starting stopped container..."
          docker start "$CONTAINER_NAME"
        else
          do_create
        fi
        do_exec
      fi
      ;;
  esac
}

main "$@"
