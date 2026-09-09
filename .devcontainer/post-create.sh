#!/usr/bin/env bash
set -euo pipefail
# ---------------------------------------------------------------------------
# post-create.sh — one-time container setup shared by devcontainer.json (VS Code) and
# dev-container.sh (CLI). Runs INSIDE the container as the vscode user.
#
#   * git trusts the bind-mounted workspace
#   * git pushes over HTTPS using the mounted host gh auth (no SSH key in the container):
#     ssh remotes are rewritten to https and gh acts as the credential helper
#   * git identity from the host's gh account when the container has none
#   * pnpm install + prettier normalisation
# System-level git config is used because /home/vscode/.gitconfig may be a read-only mount.
# ---------------------------------------------------------------------------
sudo git config --system --add safe.directory /workspace
sudo git config --system url."https://github.com/".insteadOf "git@github.com:"
sudo git config --system credential."https://github.com".helper '!gh auth git-credential'
if [[ -z "$(git config --get user.name || true)" ]] && gh auth status >/dev/null 2>&1; then
  login="$(gh api user --jq .login)"
  sudo git config --system user.name "$(gh api user --jq '.name // .login')"
  sudo git config --system user.email "${login}@users.noreply.github.com"
fi
cd /workspace
pnpm install
pnpm exec prettier --write . >/dev/null 2>&1 || true
