# homelab

Docker Compose stacks for an Unraid server, managed with the
[Compose Manager Plus](https://github.com/mstrhakr/compose_plugin) plugin.

## Stacks

The number prefix fixes the order stacks are brought up in.

| Stack              | Services                                                                                                      |
| ------------------ | ------------------------------------------------------------------------------------------------------------- |
| `0_infrastructure` | Traefik, docker-socket-proxy, FRP client, CrowdSec                                                            |
| `1_observability`  | Grafana, Alloy, Loki                                                                                          |
| `2_identity`       | Authentik, Vaultwarden                                                                                        |
| `3_downloads`      | Seerr, Prowlarr, Sonarr, Radarr, Mylar3, qBittorrent, SABnzbd, Shelfmark, LazyLibrarian, Unpackerr, Recyclarr |
| `4_media`          | Plex, Komga, Calibre-Web-Automated, Audiobookshelf, RomM                                                      |
| `5_scans`          | Paperless-ngx                                                                                                 |
| `6_productivity`   | Actual Budget, Radicale, Outline                                                                              |
| `7_files`          | Seafile                                                                                                       |
| `8_photos`         | Immich                                                                                                        |
| `9_crypto`         | Monero node                                                                                                   |

Each stack is a folder holding `compose.yaml`, `.env.template`, and any
service config under `config/<service>/`. Its Compose project `name` is the
folder name without the number (`0_infrastructure` → `infrastructure`), so
renumbering a stack doesn't rename its containers.

`vps/` is not a stack: it holds the config for the `frps` server on the VPS
that forwards public traffic to `frpc` in `0_infrastructure`.

## Networks

| Network         | Created by                   | Members                                             |
| --------------- | ---------------------------- | --------------------------------------------------- |
| `ingress`       | hand (shared)                | Traefik and every service it routes to              |
| `docker_socket` | hand (shared)                | socket-proxy and its clients (Traefik, Alloy)       |
| `frp`           | `0_infrastructure`           | frpc and Traefik; Traefik trusts its PROXY headers  |
| `<stack>_<net>` | its stack                    | a stack's private networks, e.g. a database network |
| `towernet`      | hand (legacy, being retired) | Unraid Apps containers not yet migrated             |

The shared networks must exist before the stacks start:

```sh
docker network create ingress
docker network create docker_socket
```

A service routed through Traefik joins `ingress` and sets the
`traefik.docker.network: "ingress"` label. Databases and other backends stay
on an `internal: true` network of their own stack. When the last container
has left `towernet`, Traefik leaves it too and its provider default in
`traefik.yml` becomes `ingress`.

## Conventions

Most of these are enforced by `mise run lint`, locally and in CI.

- **Images are pinned** to a version _and_ digest: `name:1.2.3@sha256:…`.
  Floating tags such as `latest` are rejected.
- **Images come from Docker Hub** where they are published there. Renovate
  only gets release timestamps from Docker Hub, and the 3-day delay needs them.
  Images from other registries need an exception in `scripts/compose-policy.py`,
  and their updates wait for approval on the Dependency Dashboard instead.
- **Networks are segregated.** A service joins only the networks it needs.
  Nothing publishes a port unless it must be reached from outside Docker. A
  published port binds an explicit interface, and a service routed through
  Traefik publishes none.
- **Docker is reached through `socket-proxy`**, never the raw socket.
- **No privileged containers or host networking** without an exception.
- **Every service sets `restart`.**
- **Secrets come from 1Password.** `.env.template` is committed and holds
  `op://Homelab/…` references for secrets and literals for everything else.
  It is rendered to `.env` (gitignored) with `op inject`. Every variable a
  `compose.yaml` uses must be declared in its template.
- **Service keys follow one order**, defined in `.dclintrc.yaml` and applied by
  `mise run fix`:

  `image` → `restart` → `depends_on` → `user` → `entrypoint` / `command` →
  `env_file` → `environment` → `volumes` → `networks` → `ports` → security
  → `healthcheck` → `labels`

## Tooling

Tools are pinned in `mise.toml` (checksums in `mise.lock`), and hooks run
through [hk](https://hk.jdx.dev).

```sh
mise run setup   # install tools and the git hooks
mise run lint    # every check, whole repo (what CI runs)
mise run fix     # every auto-fix, whole repo
```

| Check                       | What it covers                                                  |
| --------------------------- | --------------------------------------------------------------- |
| dclint                      | Compose key order, port quoting and binding, explicit tags      |
| `scripts/compose-policy.py` | Digests, Docker Hub, restart, socket, env declarations, secrets |
| `scripts/compose-config.sh` | `docker compose config` renders each stack                      |
| prettier, yamllint          | YAML, JSON5 and Markdown formatting and lint                    |
| `alloy fmt`, taplo, pkl     | Alloy, TOML and Pkl formatting                                  |
| shellcheck, shfmt, ruff     | Scripts                                                         |
| actionlint, zizmor          | GitHub Actions correctness and security                         |
| gitleaks                    | Secrets in staged changes and history                           |

## Updates

[Renovate](https://docs.renovatebot.com) (`renovate.json5`) keeps images,
tools, actions and Traefik plugins current:

- nothing is proposed until it has been public for **3 days**;
- minor, patch and digest updates open PRs;
- major updates wait until approved on the Dependency Dashboard issue;
- tooling updates are batched into one weekly PR.

Install the [Renovate GitHub App](https://github.com/apps/renovate) on this
repository to turn it on.
