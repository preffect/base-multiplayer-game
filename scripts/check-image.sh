#!/usr/bin/env bash
# Builds the game's prod image and runs it as the platform does: as user 65532, read-only with an empty /tmp, no
# capabilities, PORT set. It must serve the page, answer /api/health, and accept a WebSocket at /ws.
# Template-owned. CI runs it (.github/workflows/image.yml); it needs Docker, so not inside a dev pod.
#
#   scripts/check-image.sh [image name]
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
IMAGE="${1:-game:check}"
PORT=8080
PLATFORM_USER=65532:65532
TRIES=30
failures=0
check() { # check <label> <wanted> <got>
  if [[ "$3" == "$2" ]]; then echo "pass  $1"; else echo "FAIL  $1 (wanted '$2', got '$3')"; failures=$((failures + 1)); fi
}

docker build --quiet --load --tag "$IMAGE" . >/dev/null
check "The image runs as the platform's user" "$PLATFORM_USER" "$(docker image inspect --format '{{.Config.User}}' "$IMAGE")"
check "and has no package manager" none \
  "$(docker run --rm --entrypoint sh "$IMAGE" -c 'for t in npm npx corepack yarn pnpm; do command -v $t; done' | xargs | sed 's/^$/none/')"

container="$(docker run --detach --read-only --tmpfs /tmp --user "$PLATFORM_USER" --cap-drop ALL \
  --security-opt no-new-privileges --env "PORT=$PORT" --publish "127.0.0.1::$PORT" "$IMAGE")"
trap 'docker rm --force "$container" >/dev/null' EXIT
address="$(docker port "$container" "$PORT/tcp" | head -n 1)"
health=""
for _ in $(seq 1 "$TRIES"); do
  health="$(curl --silent --max-time 2 "http://$address/api/health" || true)"
  [[ -n "$health" ]] && break
  sleep 1
done
check "It answers /api/health" '{"status":"ok"}' "$health"
check "It serves the page" yes "$(curl --silent "http://$address/" | grep -qi '<app-root\|<!doctype html' && echo yes || echo no)"
check "and the page for a client-side route" yes "$(curl --silent "http://$address/some/route" | grep -qi '<!doctype html' && echo yes || echo no)"
# The image sets GAME_CLIENT_DIR and not DEBUG_MCP, so neither MCP is mounted: not even the page answers there.
for path in /debug-mcp /mcp; do
  check "There's no MCP at $path" 404 "$(curl --silent --output /dev/null --write-out '%{http_code}' --request POST \
    --header 'Content-Type: application/json' --data '{}' "http://$address$path")"
done
check "An unknown API path is a 404, not the page" 404 "$(curl --silent --output /dev/null --write-out '%{http_code}' "http://$address/api/nothing")"
check "It accepts a WebSocket at /ws" 101 "$(curl --silent --http1.1 --max-time 3 --output /dev/null --write-out '%{http_code}' \
  --header 'Connection: Upgrade' --header 'Upgrade: websocket' --header 'Sec-WebSocket-Version: 13' \
  --header 'Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==' "http://$address/ws?clientId=image-check" || true)"
if ((failures > 0)); then echo "--- its log:"; docker logs "$container" 2>&1 | tail -20; fi
echo "$failures failed"
exit "$((failures > 0))"
