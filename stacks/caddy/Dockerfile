# Stock Caddy plus the Cloudflare DNS module, so Caddy can answer Let's Encrypt
# DNS challenges. Komodo builds this on deploy (run_build in stacks.toml).
# Keep both tags on the same version; Renovate bumps them together.
FROM caddy:2.11.7-builder-alpine AS builder
RUN xcaddy build --with github.com/caddy-dns/cloudflare

FROM caddy:2.11.7-alpine
COPY --from=builder /usr/bin/caddy /usr/bin/caddy
