#!/usr/bin/env bash
# One-time setup for the openclaw stack: creates /srv/appdata/openclaw, runs
# OpenClaw's onboarding (pick a model provider and paste its API key), then
# points gateway login at Authelia. Never touches git.
# Usage (as root, on the server):
#   /opt/homelab/stacks/openclaw/setup.sh
# Safe to re-run: onboarding is skipped once openclaw.json exists, and only the
# gateway settings below are re-applied.
set -euo pipefail

STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPDATA=/srv/appdata/openclaw
AUTHELIA_USERS=/srv/appdata/authelia/users/users_database.yml
# Same image as the stack, so Renovate bumps keep them in step.
IMAGE="$(sed -n 's/^ *image: *//p' "$STACK_DIR/compose.yaml" | head -1)"

if [[ $EUID -ne 0 ]]; then
  echo "Run as root." >&2
  exit 1
fi

# Same mounts and paths as compose.yaml.
openclaw() {
  docker run --rm -it \
    -v "$APPDATA/state:/home/node/.openclaw" \
    -v "$APPDATA/auth-secrets:/home/node/.config/openclaw" \
    -e HOME=/home/node \
    -e OPENCLAW_HOME=/home/node \
    -e OPENCLAW_STATE_DIR=/home/node/.openclaw \
    -e OPENCLAW_CONFIG_PATH=/home/node/.openclaw/openclaw.json \
    -e OPENCLAW_WORKSPACE_DIR=/home/node/.openclaw/workspace \
    --entrypoint node "$IMAGE" dist/index.js "$@"
}

read -rp "DOMAIN (as in Komodo, e.g. home.example.com): " DOMAIN
# Default to the first user in Authelia's user list.
default_user="$(sed -n 's/^  \([A-Za-z0-9._-]*\):$/\1/p' "$AUTHELIA_USERS" 2>/dev/null | head -1)"
read -rp "Authelia username to make OpenClaw admin [$default_user]: " ADMIN_USER
ADMIN_USER="${ADMIN_USER:-$default_user}"
if [[ -z "$DOMAIN" || -z "$ADMIN_USER" ]]; then
  echo "DOMAIN and username are required." >&2
  exit 1
fi

# Caddy's address changes between restarts, so trust the whole proxy network.
# Nothing else can reach the gateway: it publishes no ports.
PROXY_SUBNET="$(docker network inspect proxy -f '{{(index .IPAM.Config 0).Subnet}}')"

echo "==> Directories"
mkdir -p "$APPDATA/state/workspace" "$APPDATA/auth-secrets"
chmod 700 "$APPDATA/auth-secrets"
# The image runs as node (uid 1000).
chown -R 1000:1000 "$APPDATA"

echo "==> Onboarding"
if [[ -f "$APPDATA/state/openclaw.json" ]]; then
  echo "openclaw.json exists, skipping. To change providers later:"
  echo "  docker exec -it openclaw-openclaw-1 node dist/index.js configure"
else
  # Gateway auth chosen here is replaced in the next step, so any choice works.
  openclaw onboard --mode local --no-install-daemon --skip-health
fi

echo "==> Gateway: log in through Authelia"
# Remote-User is set by Caddy's forward_auth (copy_headers), which also strips
# any Remote-User a client sends. deviceAutoApprove pairs a new browser as soon
# as Authelia lets it through, instead of approving it by hand on the server.
openclaw config set --batch-json "$(cat <<JSON
[
  {"path": "gateway.mode", "value": "local"},
  {"path": "gateway.bind", "value": "lan"},
  {"path": "gateway.trustedProxies", "value": ["$PROXY_SUBNET"]},
  {"path": "gateway.controlUi.allowedOrigins", "value": ["https://openclaw.$DOMAIN"]},
  {"path": "gateway.auth.mode", "value": "trusted-proxy"},
  {"path": "gateway.auth.trustedProxy.userHeader", "value": "remote-user"},
  {"path": "gateway.auth.trustedProxy.allowUsers", "value": ["$ADMIN_USER"]},
  {"path": "gateway.auth.trustedProxy.deviceAutoApprove.enabled", "value": true},
  {"path": "gateway.auth.identityScopes", "value": {"$ADMIN_USER": ["operator.admin"]}}
]
JSON
)"
chown -R 1000:1000 "$APPDATA"

echo
echo "Done. Redeploy the openclaw stack in Komodo, then open https://openclaw.$DOMAIN"
