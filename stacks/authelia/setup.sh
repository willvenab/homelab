#!/usr/bin/env bash
# One-time setup for the authelia stack: creates its secrets, the OIDC signing
# key and the first user under /srv/appdata/authelia. Never touches git.
# Usage (as root, on the server):
#   /opt/homelab/stacks/authelia/setup.sh
# Safe to re-run: existing files are kept, and the client secrets are printed
# again so you can paste them into Komodo and Beszel.
set -euo pipefail

STACK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APPDATA=/srv/appdata/authelia
SECRETS="$APPDATA/secrets"
USERS_FILE="$APPDATA/users/users_database.yml"
# Same image as the stack, so Renovate bumps keep them in step.
IMAGE="$(sed -n 's/^ *image: *//p' "$STACK_DIR/compose.yaml" | head -1)"

if [[ $EUID -ne 0 ]]; then
  echo "Run as root." >&2
  exit 1
fi

authelia() {
  docker run --rm -v "$SECRETS:/keys" "$IMAGE" authelia "$@"
}

random() {
  head -c 48 /dev/urandom | base64 | tr -d '/+=\n'
}

mkdir -p "$SECRETS" "$APPDATA/users" "$APPDATA/data"
chmod 700 "$SECRETS"

echo "==> Secrets"
for name in jwt_secret session_secret storage_encryption_key oidc_hmac_secret; do
  if [[ ! -f "$SECRETS/$name" ]]; then
    (umask 077; random > "$SECRETS/$name")
  fi
done

echo "==> OIDC signing key"
if [[ ! -f "$SECRETS/oidc_jwks.pem" ]]; then
  authelia crypto pair rsa generate --bits 2048 --directory /keys
  mv "$SECRETS/private.pem" "$SECRETS/oidc_jwks.pem"
  rm -f "$SECRETS/public.pem"
fi

echo "==> OIDC client secrets"
# Authelia only keeps the hash (<client>_client_secret.digest); the plain secret
# is kept next to it so this script can print it again.
for client in komodo beszel; do
  if [[ ! -f "$SECRETS/${client}_client_secret.digest" ]]; then
    out="$(authelia crypto hash generate pbkdf2 --variant sha512 \
      --random --random.length 72 --random.charset rfc3986)"
    (umask 077
      sed -n 's/^Random Password: //p' <<<"$out" > "$SECRETS/${client}_client_secret"
      sed -n 's/^Digest: //p' <<<"$out" > "$SECRETS/${client}_client_secret.digest")
    if [[ ! -s "$SECRETS/${client}_client_secret" || ! -s "$SECRETS/${client}_client_secret.digest" ]]; then
      rm -f "$SECRETS/${client}_client_secret" "$SECRETS/${client}_client_secret.digest"
      echo "Couldn't parse Authelia's output:" >&2
      echo "$out" >&2
      exit 1
    fi
  fi
done
chmod 600 "$SECRETS"/*

echo "==> First user"
if [[ ! -f "$USERS_FILE" ]]; then
  read -rp "Username: " username
  read -rp "Display name: " displayname
  # Use the same email as your Beszel account, so Beszel links the two.
  read -rp "Email: " email
  read -rsp "Password: " password; echo
  read -rsp "Password again: " password2; echo
  if [[ "$password" != "$password2" ]]; then
    echo "Passwords don't match." >&2
    exit 1
  fi
  digest="$(authelia crypto hash generate argon2 --password "$password" | sed -n 's/^Digest: //p')"
  if [[ -z "$digest" ]]; then
    echo "Couldn't hash the password." >&2
    exit 1
  fi
  (umask 077; cat > "$USERS_FILE" <<EOF
# Authelia users. To add one, copy a block and hash its password with:
#   docker run --rm $IMAGE authelia crypto hash generate argon2
users:
  ${username}:
    disabled: false
    displayname: '${displayname}'
    password: '${digest}'
    email: '${email}'
    groups:
      - admins
EOF
  )
else
  echo "$USERS_FILE already exists; leaving it alone."
fi

cat <<EOF

Done. Deploy (or redeploy) the authelia stack in Komodo, then finish the
setup in README.md → "Single sign-on".

Komodo client secret (KOMODO_OIDC_CLIENT_SECRET):
  $(cat "$SECRETS/komodo_client_secret")
Beszel client secret:
  $(cat "$SECRETS/beszel_client_secret")
EOF
