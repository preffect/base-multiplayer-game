#!/usr/bin/env bash
set -euo pipefail
# ---------------------------------------------------------------------------
# post-create.sh — one-time container setup shared by devcontainer.json (VS Code) and
# dev-container.sh (CLI). Runs INSIDE the container as the vscode user.
#
#   * git trusts the bind-mounted workspace
#   * git pushes over HTTPS using the mounted host gh auth (no SSH key in the container):
#     ssh remotes are rewritten to https and gh acts as the credential helper
#   * git identity, when the container has none: GIT_AUTHOR_NAME/EMAIL if set, else the host's gh account
#   * pnpm install, then build the shared package, which typecheck and test need first
# System-level git config is used because /home/vscode/.gitconfig may be a read-only mount.
# ---------------------------------------------------------------------------
sudo git config --system --add safe.directory /workspace
sudo git config --system --add safe.directory /base-multiplayer-game # template mount (dev-container.sh) # KEEP_TEMPLATE_NAME
sudo git config --system url."https://github.com/".insteadOf "git@github.com:"
sudo git config --system credential."https://github.com".helper '!gh auth git-credential'
# Identity: GIT_AUTHOR_NAME and GIT_AUTHOR_EMAIL when set (dev-container.sh passes the host's on), else the
# gh account. A failed lookup only skips it, so pnpm install still runs.
if [[ -z "$(git config --get user.name || true)" || -z "$(git config --get user.email || true)" ]]; then
  git_name="${GIT_AUTHOR_NAME:-}"
  git_email="${GIT_AUTHOR_EMAIL:-}"
  if [[ -z "$git_name" || -z "$git_email" ]] && gh auth status >/dev/null 2>&1; then
    account="$(gh api user --jq '[.login, (if (.name // "") == "" then .login else .name end)] | @tsv' 2>/dev/null || true)"
    if [[ -n "$account" ]]; then
      git_name="${git_name:-${account#*$'\t'}}"
      git_email="${git_email:-${account%%$'\t'*}@users.noreply.github.com}"
    fi
  fi
  if [[ -n "$git_name" && -n "$git_email" ]]; then
    sudo git config --system user.name "$git_name"
    sudo git config --system user.email "$git_email"
  fi
fi
cd /workspace
pnpm install
pnpm build:shared
