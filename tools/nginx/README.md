# Nginx Reverse-Proxy Toolkit

Set up a **containerized nginx reverse proxy** in front of your app containers,
with **Let's Encrypt SSL**, **automatic websocket upgrades**, and a clean,
predictable file layout on the server.

| Script | What it does |
|--------|--------------|
| `init-nginx.sh` | Scaffolds the stack (compose + config layout) and starts nginx. Run once per host. |
| `add-app.sh` | Interactive — adds a reverse-proxy vhost for a new app, obtains its SSL cert, wires websockets, reloads nginx. Run once per app. |
| `renew.sh` | Renews certificates and reloads nginx. Put it on a cron/timer. |

Requires Docker + Compose v2 (install with [`tools/docker/setup-docker.sh`](../docker/README.md)).

## On-server layout

Everything lives under a single base directory (default `/opt/nginx`):

```
/opt/nginx/
  docker-compose.yml          nginx + certbot services
  nginx/
    nginx.conf                main config (includes conf.d/*)
    conf.d/
      00-websocket-map.conf   $http_upgrade -> $connection_upgrade (http context)
      00-default.conf         default catch-all + ACME webroot
      <app>.conf              one clean vhost per app (added by add-app.sh)
    snippets/
      ssl-params.conf         modern TLS + HSTS
      proxy-common.conf       proxy headers + websocket upgrade
  certbot/
    conf/                     /etc/letsencrypt (certs + accounts)
    www/                      ACME http-01 webroot
  logs/
    nginx/  certbot/          bind-mounted logs (per-app access/error too)
```

nginx joins an **external Docker network** (default `meshcaster`) shared with
your app containers, so vhosts proxy straight to a container by name:
`proxy_pass http://booking-api:8080;`.

## 1. Initialize the host (once)

```bash
sudo ./init-nginx.sh                       # base /opt/nginx, network meshcaster
sudo ./init-nginx.sh --base /srv/nginx --network myapps
```

This creates the layout, writes the shared config, ensures the network exists,
and starts nginx. It never touches existing per-app vhosts, so it's safe to
re-run after an update.

## 2. Add an application (per app)

Just run it and answer the prompts:

```bash
sudo ./add-app.sh
```

```
? App name / vhost slug: booking-api
? Domain(s), space-separated (first = primary): api.example.com
? Upstream target (container-name:port): booking-api:8080
? Does this app use websockets? [y/N]: y
?   Websocket path [/ws]: /hubs
? ACME (Let's Encrypt) email: ops@example.com
```

It writes `conf.d/booking-api.conf`, obtains the certificate over HTTP-01,
switches the vhost to HTTPS, and reloads nginx — rolling the vhost back if the
config fails to validate, so a bad app never takes the proxy down.

You can pre-fill any answer with a flag (good for re-runs / scripting):

```bash
sudo ./add-app.sh --app booking-api --domains "api.example.com" \
  --upstream booking-api:8080 --ws-path /hubs --email ops@example.com

# preview the generated vhost without changing anything
sudo ./add-app.sh --app booking-api --domains api.example.com \
  --upstream booking-api:8080 --ws-path none --email ops@example.com --dry-run

# test against Let's Encrypt staging first (avoids rate limits)
sudo ./add-app.sh ... --staging
```

### Websocket handling

Upgrade headers are applied to **every** proxied location via
`snippets/proxy-common.conf` (backed by the `map` in `00-websocket-map.conf`),
so `wss://` works out of the box — including SignalR, Socket.IO, and plain WS.
Answering *yes* to the websocket prompt additionally gives that path extended
(1 h) read/send timeouts so long-lived connections aren't cut.

## 3. Automate renewal

Certificates last 90 days. Add a cron entry (as root):

```bash
sudo crontab -e
# renew twice daily; only reloads nginx when something actually renews
0 3,15 * * * /opt/nginx/renew.sh --base /opt/nginx >> /var/log/nginx-renew.log 2>&1
```

Copy `renew.sh` next to the stack (or point `--base` at it) so the path exists.

## Prerequisites checklist

Before running `add-app.sh` for a domain:

- The app container is running and attached to the shared network (`meshcaster`).
- DNS `A`/`AAAA` records for every domain point at this server.
- Ports **80** and **443** are open to the internet (certbot needs 80).

## Running from your workstation

These are interactive, so run them **on the server** (`ssh` in, then run). To
get the files there without git, copy the folder over:

```bash
scp -r tools/nginx user@vps1:/tmp/nginx-tools
ssh user@vps1 'sudo /tmp/nginx-tools/init-nginx.sh'
```
