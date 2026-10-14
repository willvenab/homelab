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
2. **Settings → Variables**: add `DOMAIN` (e.g. `home.example.com`), `CLOUDFLARE_API_TOKEN` (mark it secret), `BESZEL_AGENT_KEY` (any value for now; mark it secret), `OPENWEATHERMAP_API_KEY` (from openweathermap.org; mark it secret), `OSRS_PRICES_USER_AGENT` (e.g. `osrs-tools (homelab) - contact: you@example.com`; the OSRS Wiki asks for a way to reach you), and the Tailscale variables from [Remote access with Tailscale](#remote-access-with-tailscale).
3. **Settings → Providers**:
   - **Git accounts**: add provider `github.com`, username `willvenab`, and the token. Every stack and the sync clone with this account.
   - **Registry accounts**: add provider `ghcr.io`, username `willvenab`, and the same token. Only stacks that pull private images use it (see [Adding a service](#adding-a-service)).
4. **Syncs → New**: name it `homelab`, repo `willvenab/homelab`, git account `willvenab`, branch `main`, resource path `komodo/syncs`. Run it. From then on the sync manages itself.
5. Create Authelia's secrets and your login: on the server, as root, run `/opt/homelab/stacks/authelia/setup.sh`, then redeploy the `authelia` stack. Caddy asks Authelia before showing AdGuard, so this has to come first.
6. Point `*.<DOMAIN>` at the server. AdGuard's UI is only reachable through Caddy, so first add a temporary line to `/etc/hosts` on your computer: `<server IP>  adguard.<DOMAIN> auth.<DOMAIN>`. Then open `adguard.<DOMAIN>`, log in with your Authelia user, finish the setup wizard (see `stacks/adguard/compose.yaml`), and add **Filters → DNS rewrites** → `*.<DOMAIN>` → `<server IP>`. Point your router's DHCP DNS at the server and remove the `/etc/hosts` line.
7. Set up Beszel (see [Beszel](#beszel) below).
8. Finish single sign-on (see [Single sign-on](#single-sign-on) below).

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

## Single sign-on

The `authelia` stack serves one login page at `auth.<DOMAIN>`. Once you've logged in there, the session cookie covers every `*.<DOMAIN>` service for a week (a month if you tick **Remember me**).

| Service  | How it logs in |
|----------|----------------|
| Komodo   | OIDC: a "Log in with Authelia" flow, set up below |
| Beszel   | OIDC, set up below |
| AdGuard  | Caddy asks Authelia first (`import authelia` in the Caddyfile) |
| Homepage | Caddy asks Authelia first |
| OSRS Tools | Caddy asks Authelia first |
| Stirling-PDF | Caddy asks Authelia first |
| Hermes   | OIDC, no setup needed (a public client, so no secret); only the `admins` group gets in |

Secrets, the OIDC signing key and the user list live in `/srv/appdata/authelia` and are created by `stacks/authelia/setup.sh` (see [After bootstrap](#after-bootstrap-one-time-in-the-komodo-ui), step 5). Re-running it is safe; it prints the Komodo and Beszel client secrets again. If this box was set up before Authelia existed, `git -C /opt/homelab pull` first, then run it and redeploy `authelia`.

**Komodo.** Its settings aren't in the sync, so this is done on the server:

1. In `/etc/komodo/core/compose.env`, set `KOMODO_HOST=https://komodo.<DOMAIN>` (exactly: Komodo builds the OIDC redirect URL from it) and add the "Single sign-on" block from `komodo/compose.env.example`, uncommented, with your domain and the Komodo client secret. A `compose.env` made before Authelia existed doesn't have that block, so copy it from the example.
2. Komodo needs to create a user for you on your first Authelia login, but `KOMODO_DISABLE_USER_REGISTRATION=true` blocks that ("User registration is disabled"). On 2.3.3, `KOMODO_DISABLE_OIDC_USER_REGISTRATION=false` alone didn't get around it, so set `KOMODO_DISABLE_USER_REGISTRATION=false` for now.
3. Restart Komodo with the new settings, and check that they took effect:
   ```sh
   docker compose -p komodo -f /etc/komodo/core/compose.yaml --env-file /etc/komodo/core/compose.env up -d
   docker exec komodo-core-1 env | grep -E 'KOMODO_HOST|OIDC|REGISTRATION'
   ```
   This is the last line of `bootstrap/install.sh`. Running the whole script works too, but it also restarts Docker and every container.
4. Open `komodo.<DOMAIN>` in a private window. It redirects to Authelia and back, then says your user is disabled: that's expected, since it's a new Komodo user.
5. Open `komodo.<DOMAIN>/login?disableAutoLogin=true`, log in as `admin`, and under **Settings → Users** enable the new user and make it an admin.
6. Set `KOMODO_DISABLE_USER_REGISTRATION=true` again and re-run the `docker compose` command from step 3. Existing users can still log in. From then on, use Authelia. Keep the local `admin` password somewhere safe as a way in if Authelia is down.

**Beszel.** Use the same email in Authelia as your Beszel account, so Beszel links the two instead of creating a second user.

This is done in the PocketBase admin at `beszel.<DOMAIN>/_/` (type the `/_/` in yourself; Beszel's own **Settings** page doesn't have these options). Log in with your Beszel admin email and password.

1. **Settings** (gear icon in the left sidebar) → **Application**: at the bottom, turn off **Hide collection create and edit controls** and save.
2. **Collections** (database icon) → **users** → ⚙ next to the collection name → **Options → OAuth2**: enable it, **Add provider → OpenID Connect**, and fill in the fields below. Replace `<DOMAIN>` with your real domain in all three URLs, with no trailing slash:

   | Field         | Value |
   |---------------|-------|
   | Client ID     | `beszel` |
   | Client secret | the Beszel secret from `setup.sh` |
   | Display name  | `Authelia` |
   | Auth URL      | `https://auth.<DOMAIN>/api/oidc/authorization` |
   | Token URL     | `https://auth.<DOMAIN>/api/oidc/token` |
   | User info URL | `https://auth.<DOMAIN>/api/oidc/userinfo` |

3. Save, log out of Beszel and log back in with **Authelia**.
4. Once that works, turn **Hide collection create and edit controls** back on, so the collections can't be edited by accident. You can also uncomment `DISABLE_PASSWORD_AUTH` in `stacks/beszel/compose.yaml` to hide the password form.

If the login fails with `Failed to fetch OAuth2 user`, the token step worked (so the client ID, secret and redirect are fine) but fetching your profile didn't. Check the **User info URL** first. The real error is in `/_/` → **Logs** (filter with `level > 0`).

**AdGuard.** Authelia now guards it, so drop AdGuard's own login: in `/srv/appdata/adguard/conf/AdGuardHome.yaml`, replace the `users:` list with `users: []` and redeploy the `adguard` stack.

**Adding users.** Edit `/srv/appdata/authelia/users/users_database.yml`; Authelia picks up changes without a restart. The file's header shows how to hash a password.

**Two-factor.** Everything uses `one_factor` (password only). To also require a passkey or TOTP code, change the policies in `stacks/authelia/config/configuration.yml` to `two_factor`. Register the device at `auth.<DOMAIN>` first. Authelia has no mail server, so the confirmation code it "emails" is written to `/srv/appdata/authelia/data/notification.txt`.

If a login fails, check the `authelia` stack's log in Komodo. Komodo and Beszel reach `auth.<DOMAIN>` through a network alias on Caddy (`stacks/caddy/compose.yaml`), not through DNS.

## Remote access with Tailscale

The `tailscale` stack makes the server a [subnet router](https://tailscale.com/kb/1019/subnets), so your phone can reach the LAN (and every `*.<DOMAIN>` service) from anywhere, with no ports opened on your router.

1. Create a free account at [tailscale.com](https://tailscale.com) and install the Tailscale app on your phone, logged into the same account.
2. Admin console → **Settings → Keys → Generate auth key** (one-off, not ephemeral). In Komodo, add the variables `TS_AUTHKEY` (mark it secret) and `LAN_SUBNET` (your LAN in CIDR form, e.g. `192.168.1.0/24`). Use the network address, ending in `.0` for a `/24`, not the server's own IP: `192.168.1.10/24` is rejected ("non-address bits set") and the container crash-loops.
3. Re-run `bootstrap/install.sh` once if this box was set up before the Tailscale stack existed, so IP forwarding is enabled.
4. Deploy the `tailscale` stack. In the admin console, open the `elitedesk` machine and do the steps below. If the machine doesn't appear, it never logged in: check the container's logs (Komodo → `tailscale` stack → **Log**). The usual causes are a bad `LAN_SUBNET` or a rejected auth key. If the key was rejected, generate a new one, update `TS_AUTHKEY` and redeploy.
   - **Edit route settings** → approve the `LAN_SUBNET` route.
   - **Disable key expiry**, so the server doesn't drop off the tailnet after 180 days.
5. Admin console → **DNS → Nameservers → Add nameserver → Custom**: enter the server's LAN IP, tick **Restrict to domain** (split DNS) and enter `<DOMAIN>`. Now `*.<DOMAIN>` resolves through AdGuard on your phone whenever Tailscale is on. (Skip "Restrict to domain" and enable **Override DNS servers** instead if you also want AdGuard's ad blocking while away.)

Tailscale has no local web UI, so its tile on `home.<DOMAIN>` links to the admin console instead.

## Hermes Agent

[Hermes Agent](https://github.com/NousResearch/hermes-agent) is an AI agent that remembers things, learns skills and runs scheduled jobs. The `hermes` stack runs two containers that share everything in `/srv/appdata/hermes` (model, API keys, memories, skills, sessions):

- `hermes`, the gateway: connects chat apps (Telegram, Discord, ...) and runs scheduled jobs. The agent's built-in dashboard is turned off.
- `hermes-webui`, [Hermes WebUI](https://github.com/nesquena/hermes-webui) at `hermes.<DOMAIN>`: chat in the browser. It runs its own copy of the agent, so tools you trigger from it run in this container, not the gateway's. Its file browser shows `/srv/appdata/hermes-webui/workspace`.

1. Deploy the `hermes` stack (after `authelia`, which has its OIDC client). It starts without any API keys; it just can't answer until it has some. The WebUI's first start takes a few minutes while it installs the agent: `docker logs -f hermes-hermes-webui-1`.
2. On the server, run the setup wizard and pick a model provider (e.g. OpenRouter, Anthropic or Nous Portal). Set up a chat app here too:
   ```sh
   docker exec -it hermes-hermes-1 hermes setup
   ```
   The keys go into `/srv/appdata/hermes/.env`, not Komodo. Then restart the gateway: `docker exec hermes-hermes-1 hermes gateway restart`. Run the wizard again later to add another chat app.
3. Open `hermes.<DOMAIN>` and sign in with Authelia. Only users in the `admins` group (in `users_database.yml`) are let in; change `HERMES_WEBUI_OIDC_ALLOW_VALUES` in `stacks/hermes/compose.yaml` to allow others.

Neither container has the Docker socket, so the agent's shell commands stay inside its own container. Logs: `docker logs hermes-hermes-1` (or `docker exec hermes-hermes-1 hermes logs --follow`) and `docker logs hermes-hermes-webui-1`.

**Upgrades.** The WebUI needs the agent's code, so on each deploy the `agent-src` container copies it out of the agent image, and the WebUI reinstalls it. The stack is set to `destroy_before_deploy` for that, so any deploy restarts the gateway too. Upstream treats a WebUI release and an agent release as a pair: if something breaks after one side is bumped, bump the other too. The WebUI's tags on ghcr.io mix stable and experimental builds, so Renovate takes WebUI versions from its stable GitHub releases instead (see `renovate.json`).

If the WebUI can't read `/srv/appdata/hermes` (`Permission denied` in its log), check the owner with `stat -c '%u:%g' /srv/appdata/hermes` and set `WANTED_UID`/`WANTED_GID` in the compose file to match.

## Adding a service

1. Create `stacks/<name>/compose.yaml`. Follow these conventions:
   - Pin the image tag (never `:latest`).
   - Add `restart: unless-stopped` and a `mem_limit`.
   - Put data in `/srv/appdata/<name>/...` bind mounts.
   - Don't publish ports. Join the external `proxy` network and add a `@name host` matcher and `handle` block to `stacks/caddy/conf/Caddyfile`.
   - Log in through Authelia. If the app supports OIDC, add a client to `stacks/authelia/config/configuration.yml` (Authelia has [guides per app](https://www.authelia.com/integration/openid-connect/clients/introduction/)) and a `<name>_client_secret` to the loop in `stacks/authelia/setup.sh`. Otherwise add `import authelia` to its `handle` block.
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
