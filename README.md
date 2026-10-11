# homelab

A minimal Debian host on an HP EliteDesk. Every service is a Docker Compose stack, deployed from this repo by [Komodo](https://komo.do).

```
bootstrap/       one-time host setup (Docker, log limits, zram, Komodo)
komodo/          Komodo's own compose stack + the resource sync (komodo/syncs/*.toml)
stacks/<name>/   one directory per service: compose.yaml (+ config files)
```

## How deploys work

1. You push to `main`.
2. Every 30 seconds, Komodo's `gitops-reconcile` procedure runs the `homelab` sync, which applies `komodo/syncs/*.toml`, then redeploys any stack whose files changed.
3. Renovate opens PRs to bump pinned image tags. Merging one redeploys that stack.

Komodo itself isn't in the sync. To upgrade it, bump the tags in `komodo/` and re-run `bootstrap/install.sh`.

## Fresh install

1. Install Debian from the netinst ISO. At "Software selection", tick only **SSH server** and **standard system utilities**.
2. BIOS: set **power on after AC loss**, and give the box a DHCP reservation on your router.
3. Check that the CPU has AVX (`grep -c avx /proc/cpuinfo`). This repo uses FerretDB, so Komodo works either way, but some apps need AVX.
4. On the server, as root:
   ```sh
   apt-get install -y git
   git clone https://github.com/Willven/homelab.git /opt/homelab
   /opt/homelab/bootstrap/install.sh
   ```
   The script prints the Komodo URL and the generated admin password.

## Domain and HTTPS

Caddy gets one real Let's Encrypt wildcard cert for `*.<DOMAIN>` using a DNS challenge, so every device trusts it and nothing is exposed to the internet.

1. Buy a domain on Cloudflare, or move an existing domain's nameservers to Cloudflare (the free plan is fine). You can use the domain itself (`example.com`) or a subdomain (`home.example.com`) as `DOMAIN`.
2. Cloudflare dashboard → **My Profile → API Tokens → Create Token** → "Edit zone DNS" template, limited to that zone. Keep the token for the next section.
3. You don't need any public DNS records. The names only resolve on your LAN, through AdGuard (step 6 below).

## After bootstrap (one-time, in the Komodo UI)

1. Log in and change the admin password.
2. **Settings → Variables**: add `DOMAIN` (e.g. `home.example.com`), `CLOUDFLARE_API_TOKEN` (mark it secret), `BESZEL_AGENT_KEY` (any value for now; mark it secret) and `OPENWEATHERMAP_API_KEY` (from openweathermap.org; mark it secret).
3. If the repo is private, add a GitHub account/token under **Settings → Git Accounts** and set `git_account` in the TOML files.
4. **Syncs → New**: name it `homelab`, repo `Willven/homelab`, branch `main`, resource path `komodo/syncs`. Run it. From then on the sync manages itself.
5. Beszel: open `beszel.<DOMAIN>`, click **Add system**, copy the public key into `BESZEL_AGENT_KEY`, redeploy the `beszel` stack, and add the system with host `/beszel_socket/beszel.sock`.
6. Point `*.<DOMAIN>` at the server. AdGuard's UI is only reachable through Caddy, so first add a temporary line to `/etc/hosts` on your computer: `<server IP>  adguard.<DOMAIN>`. Then open `adguard.<DOMAIN>`, finish the setup wizard (see `stacks/adguard/compose.yaml`), and add **Filters → DNS rewrites** → `*.<DOMAIN>` → `<server IP>`. Point your router's DHCP DNS at the server and remove the `/etc/hosts` line.

## Adding a service

1. Create `stacks/<name>/compose.yaml`. Follow these conventions:
   - Pin the image tag (never `:latest`).
   - Add `restart: unless-stopped` and a `mem_limit`.
   - Put data in `/srv/appdata/<name>/...` bind mounts.
   - Don't publish ports. Join the external `proxy` network and add a `@name host` matcher and `handle` block to `stacks/caddy/Caddyfile`.
   - Put secrets in Komodo Variables, referenced as `[[NAME]]` in the stack's `environment`.
   - Add `homepage.*` labels (group, name, icon, href, description) to the container with the web UI, so it shows up on `home.<DOMAIN>`. See `stacks/beszel/compose.yaml`. The `href` uses `${DOMAIN}`, so add `DOMAIN = [[DOMAIN]]` to the stack's `environment`.
2. Add a `[[stack]]` block to `komodo/syncs/stacks.toml`.
3. Push.

## Backups

Back up `/srv/appdata` and `/etc/komodo` off the box (e.g. restic or Backrest to a NAS or B2). Komodo also writes dated database dumps to `/etc/komodo/backups`.

## Notes for an old box

- Docker logs use the `local` driver, capped at 30 MB per container (`bootstrap/daemon.json`). journald is capped at 200 MB.
- zram swap uses compressed RAM instead of disk swap.
- Docker bypasses ufw. Any port that isn't on the reverse proxy should be bound to `127.0.0.1`.
- For Jellyfin or Plex, pass `/dev/dri` through so transcoding uses the Intel iGPU (QuickSync), not the CPU.
- Run `powertop --auto-tune` (as a systemd oneshot) to cut idle power.
