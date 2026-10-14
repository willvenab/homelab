#!/usr/bin/env bash
# One-time bootstrap for a fresh minimal Debian install.
# Usage (as root, from a clone of this repo on the server):
#   ./bootstrap/install.sh
# Safe to re-run: it also upgrades Komodo when the tags in komodo/ change.
set -euo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
KOMODO_DIR=/etc/komodo/core

if [[ $EUID -ne 0 ]]; then
  echo "Run as root." >&2
  exit 1
fi

export DEBIAN_FRONTEND=noninteractive

echo "==> Base packages"
apt-get update
apt-get install -y --no-install-recommends \
  ca-certificates curl git unattended-upgrades zram-tools

echo "==> Unattended security upgrades"
echo "unattended-upgrades unattended-upgrades/enable_auto_updates boolean true" | debconf-set-selections
dpkg-reconfigure -f noninteractive unattended-upgrades

echo "==> zram swap (compressed RAM instead of disk swap)"
cat > /etc/default/zramswap <<'EOF'
ALGO=zstd
PERCENT=50
EOF
systemctl restart zramswap

echo "==> Cap journald disk usage"
mkdir -p /etc/systemd/journald.conf.d
cat > /etc/systemd/journald.conf.d/size.conf <<'EOF'
[Journal]
SystemMaxUse=200M
EOF
systemctl restart systemd-journald

echo "==> IP forwarding (Tailscale subnet router)"
cat > /etc/sysctl.d/99-tailscale.conf <<'EOF2'
net.ipv4.ip_forward = 1
net.ipv6.conf.all.forwarding = 1
EOF2
sysctl -p /etc/sysctl.d/99-tailscale.conf

echo "==> Docker CE from Docker's apt repo"
if ! command -v docker >/dev/null; then
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/debian/gpg -o /etc/apt/keyrings/docker.asc
  chmod a+r /etc/apt/keyrings/docker.asc
  # shellcheck source=/dev/null
  codename="$(. /etc/os-release && echo "$VERSION_CODENAME")"
  cat > /etc/apt/sources.list.d/docker.sources <<EOF
Types: deb
URIs: https://download.docker.com/linux/debian
Suites: ${codename}
Components: stable
Signed-By: /etc/apt/keyrings/docker.asc
EOF
  apt-get update
  apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
fi

install -m 0644 "$REPO_DIR/bootstrap/daemon.json" /etc/docker/daemon.json
install -D -m 0644 "$REPO_DIR/bootstrap/docker-socket-restart.conf" /etc/systemd/system/docker.service.d/socket-restart.conf
systemctl daemon-reload
systemctl enable docker
systemctl restart docker

echo "==> Directories and shared proxy network"
mkdir -p /srv/appdata "$KOMODO_DIR" /etc/komodo/backups
docker network inspect proxy >/dev/null 2>&1 || docker network create proxy

echo "==> Komodo"
install -m 0644 "$REPO_DIR/komodo/compose.yaml" "$KOMODO_DIR/compose.yaml"
admin_password=""
if [[ ! -f "$KOMODO_DIR/compose.env" ]]; then
  admin_password="$(head -c 18 /dev/urandom | base64 | tr -d '/+=')"
  install -m 0600 "$REPO_DIR/komodo/compose.env.example" "$KOMODO_DIR/compose.env"
  for var in KOMODO_DATABASE_PASSWORD KOMODO_WEBHOOK_SECRET KOMODO_JWT_SECRET; do
    sed -i "s|^${var}=CHANGEME|${var}=$(head -c 32 /dev/urandom | base64 | tr -d '/+=')|" "$KOMODO_DIR/compose.env"
  done
  sed -i "s|^KOMODO_INIT_ADMIN_PASSWORD=CHANGEME|KOMODO_INIT_ADMIN_PASSWORD=${admin_password}|" "$KOMODO_DIR/compose.env"
fi

docker compose -p komodo -f "$KOMODO_DIR/compose.yaml" --env-file "$KOMODO_DIR/compose.env" up -d

echo
echo "Done. Komodo UI: http://$(hostname -I | awk '{print $1}'):9120"
if [[ -n "$admin_password" ]]; then
  echo "Login: admin / ${admin_password}  (change it after first login)"
fi
echo "Next steps: see README.md → 'After bootstrap'."
