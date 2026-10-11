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
   git clone https://github.com/willvenab/homelab.git /opt/homelab
   /opt/homelab/bootstrap/install.sh
   ```
   The repo is private, so `git clone` asks for credentials: enter `willvenab` as the username and the GitHub token (see [GitHub token](#github-token)) as the password. Git doesn't save it. The script prints the Komodo URL and the generated admin password.

## GitHub token

The repo and any images on `ghcr.io/willvenab/...` are private, so Komodo needs a token to clone and pull them. Create one **classic** personal access token (GitHub → **Settings → Developer settings → Personal access tokens → Tokens (classic)**) with the `repo` and `read:packages` scopes. Fine-grained tokens can't read ghcr.io packages. Give it an expiry and put a reminder in your calendar to rotate it.

The token goes into the Komodo UI only (next section). The TOML files just name the account (`git_account = "willvenab"`).

## Domain and HTTPS

Caddy gets one real Let's Encrypt wildcard cert for `*.<DOMAIN>` using a DNS challenge, so every device trusts it and nothing is exposed to the internet.

1. Buy a domain on Cloudflare, or move an existing domain's nameservers to Cloudflare (the free plan is fine). You can use the domain itself (`example.com`) or a subdomain (`home.example.com`) as `DOMAIN`.
2. Cloudflare dashboard → **My Profile → API Tokens → Create Token** → "Edit zone DNS" template, limited to that zone. Keep the token for the next section.
3. You don't need any public DNS records. The names only resolve on your LAN, through AdGuard (step 5 below).

## After bootstrap (one-time, in the Komodo UI)

1. Log in and change the admin password.
2. **Settings → Variables**: add `DOMAIN` (e.g. `home.example.com`), `CLOUDFLARE_API_TOKEN` (mark it secret), `BESZEL_AGENT_KEY` (any value for now; mark it secret), `OPENWEATHERMAP_API_KEY` (from openweathermap.org; mark it secret), and the Tailscale variables from [Remote access with Tailscale](#remote-access-with-tailscale).
3. **Settings → Providers**:
   - **Git accounts**: add provider `github.com`, username `willvenab`, and the token. Every stack and the sync clone with this account.
   - **Registry accounts**: add provider `ghcr.io`, username `willvenab`, and the same token. Only stacks that pull private images use it (see [Adding a service](#adding-a-service)).
4. **Syncs → New**: name it `homelab`, repo `willvenab/homelab`, git account `willvenab`, branch `main`, resource path `komodo/syncs`. Run it. From then on the sync manages itself.
5. Point `*.<DOMAIN>` at the server. AdGuard's UI is only reachable through Caddy, so first add a temporary line to `/etc/hosts` on your computer: `<server IP>  adguard.<DOMAIN>`. Then open `adguard.<DOMAIN>`, finish the setup wizard (see `stacks/adguard/compose.yaml`), and add **Filters → DNS rewrites** → `*.<DOMAIN>` → `<server IP>`. Point your router's DHCP DNS at the server and remove the `/etc/hosts` line.
6. Set up Beszel (see [Beszel](#beszel) below).

## Beszel

The hub (web UI) and the agent run in the same stack and talk over a unix socket, so the agent doesn't need a port. Both containers mount `/srv/appdata/beszel/socket` at `/beszel_socket`, so Beszel must always be given the in-container path `/beszel_socket/beszel.sock`, never the host path. The agent only accepts the hub if it has the hub's public key, so the first deploy takes two passes:

1. Open `beszel.<DOMAIN>` and create the admin account (the first visit asks for one).
2. Click **Add system**. Copy the **Public key** shown in the dialog, then close the dialog without adding anything. The key belongs to the hub and stays the same, so you can come back for it later.
3. In Komodo, set the `BESZEL_AGENT_KEY` variable to that key (the whole `ssh-ed25519 AAAA...` line) and redeploy the `beszel` stack.
4. Back in Beszel, click **Add system** again and fill it in:

   | Field     | Value                        |
   |-----------|------------------------------|
   | Name      | `elitedesk` (any name)       |
   | Host / IP | `/beszel_socket/beszel.sock` |
   | Port      | leave the default (`45876`); it's ignored for a socket path |

   Ignore the `docker compose` snippet in the dialog; `stacks/beszel/compose.yaml` already does that.
5. Click **Add system**. The system should go green within a minute.

If it stays red, the hub's errors aren't in `docker logs`: open `beszel.<DOMAIN>/_/` → **Logs** and filter with `level > 0`. The hub logs `System down` once when a system goes down, not on every retry, so an old entry may still be the current cause.

- `dial unix ...: no such file or directory`: **Host / IP** is wrong (most likely the host path `/srv/appdata/...`). Edit the system and set it to `/beszel_socket/beszel.sock`.
- `handshake failed` / `unable to authenticate`: `BESZEL_AGENT_KEY` doesn't match the hub's public key, or the stack wasn't redeployed after you changed it.

## Remote access with Tailscale

The `tailscale` stack makes the server a [subnet router](https://tailscale.com/kb/1019/subnets), so your phone can reach the LAN (and every `*.<DOMAIN>` service) from anywhere, with no ports opened on your router.

1. Create a free account at [tailscale.com](https://tailscale.com) and install the Tailscale app on your phone, logged into the same account.
2. Admin console → **Settings → Keys → Generate auth key** (one-off, not ephemeral). In Komodo, add the variables `TS_AUTHKEY` (mark it secret) and `LAN_SUBNET` (your LAN in CIDR form, e.g. `192.168.1.0/24`).
3. Re-run `bootstrap/install.sh` once if this box was set up before the Tailscale stack existed, so IP forwarding is enabled.
4. Deploy the `tailscale` stack. In the admin console, open the `elitedesk` machine and:
   - **Edit route settings** → approve the `LAN_SUBNET` route.
   - **Disable key expiry**, so the server doesn't drop off the tailnet after 180 days.
5. Admin console → **DNS → Nameservers → Add nameserver → Custom**: enter the server's LAN IP, tick **Restrict to domain** (split DNS) and enter `<DOMAIN>`. Now `*.<DOMAIN>` resolves through AdGuard on your phone whenever Tailscale is on. (Skip "Restrict to domain" and enable **Override DNS servers** instead if you also want AdGuard's ad blocking while away.)

Tailscale has no local web UI, so its tile on `home.<DOMAIN>` links to the admin console instead.

## Adding a service

1. Create `stacks/<name>/compose.yaml`. Follow these conventions:
   - Pin the image tag (never `:latest`).
   - Add `restart: unless-stopped` and a `mem_limit`.
   - Put data in `/srv/appdata/<name>/...` bind mounts.
   - Don't publish ports. Join the external `proxy` network and add a `@name host` matcher and `handle` block to `stacks/caddy/conf/Caddyfile`.
   - Put secrets in Komodo Variables, referenced as `[[NAME]]` in the stack's `environment`.
   - Add `homepage.*` labels (group, name, icon, href, description) to the container with the web UI, so it shows up on `home.<DOMAIN>`. See `stacks/beszel/compose.yaml`. The `href` uses `${DOMAIN}`, so add `DOMAIN = [[DOMAIN]]` to the stack's `environment`.
2. Add a `[[stack]]` block to `komodo/syncs/stacks.toml`. Keep `git_account = "willvenab"`, or Komodo can't clone the repo.
   - If the stack uses a private image from `ghcr.io/willvenab/...`, also add `registry_provider = "ghcr.io"` and `registry_account = "willvenab"` so Komodo logs in before pulling. Public images don't need this.
3. Push.

## Backups

Back up `/srv/appdata` and `/etc/komodo` off the box (e.g. restic or Backrest to a NAS or B2). Komodo also writes dated database dumps to `/etc/komodo/backups`.

## Notes for an old box

- Docker logs use the `local` driver, capped at 30 MB per container (`bootstrap/daemon.json`). journald is capped at 200 MB.
- zram swap uses compressed RAM instead of disk swap.
- Docker bypasses ufw. Any port that isn't on the reverse proxy should be bound to `127.0.0.1`.
- For Jellyfin or Plex, pass `/dev/dri` through so transcoding uses the Intel iGPU (QuickSync), not the CPU.
- Run `powertop --auto-tune` (as a systemd oneshot) to cut idle power.
