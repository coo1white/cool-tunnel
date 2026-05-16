# NaiveProxy Server Setup on Debian

**Replace every `<USERNAME>` and `<PASSWORD>` below with strong unique values** (e.g. `openssl rand -base64 24`). Never copy example credentials from any guide into production. Earlier revisions of this file shipped a real password by mistake — see [SECURITY.md](./SECURITY.md) for rotation guidance.

Prereqs: Debian + root + domain pointing at the server IP + Docker installed.

## Setup

```bash
mkdir -p /opt/cool-tunnel && cd /opt/cool-tunnel

cat > Dockerfile <<'EOF'
FROM caddy:builder AS builder
RUN xcaddy build \
    --with github.com/caddyserver/forwardproxy@caddy2=github.com/klzgrad/forwardproxy@naive
FROM caddy:latest
COPY --from=builder /usr/bin/caddy /usr/bin/caddy
EOF

cat > Caddyfile <<'EOF'
{
    order forward_proxy before file_server
}

:443, proxy.example.com {
    tls your@email.com
    forward_proxy {
        basic_auth <USERNAME> <PASSWORD>
        hide_ip
        hide_via
        probe_resistance
    }
    root * /srv
    file_server
}
EOF

mkdir -p site && echo OK > site/index.html

cat > docker-compose.yml <<'EOF'
services:
  cool-tunnel:
    build: .
    container_name: cool-tunnel
    restart: unless-stopped
    ports:
      - "80:80"
      - "443:443"
      - "443:443/udp"
    volumes:
      - ./Caddyfile:/etc/caddy/Caddyfile:ro
      - ./site:/srv:ro
      - naive_caddy_data:/data
      - naive_caddy_config:/config

volumes:
  naive_caddy_data:
  naive_caddy_config:
EOF

docker compose build --no-cache && docker compose up -d
```

Caddyfile requirements (deviation breaks the proxy): `:443, DOMAIN` syntax (not just `DOMAIN`); `tls your@email.com` present; `root * /srv` with `file_server` (not `respond "OK"`); `order forward_proxy before file_server` at the top.

## Management

```bash
docker logs --tail 30 cool-tunnel
docker exec cool-tunnel caddy list-modules | grep forward    # confirm forward_proxy loaded
docker compose restart
docker compose down && docker compose build --no-cache && docker compose up -d   # rebuild
```

## Testing

```bash
curl -v https://proxy.example.com                                          # expect: OK
curl -v --proxy "https://<USERNAME>:<PASSWORD>@proxy.example.com:443" https://ipinfo.io   # expect: server IP
curl -x socks5h://127.0.0.1:1080 -vk --max-time 30 https://www.google.com/generate_204    # from Mac client: HTTP/2 204
```

## Troubleshooting

`SSL_ERROR_SYSCALL` on Mac client → verify Caddyfile against the four requirements above and confirm `docker exec cool-tunnel caddy list-modules | grep forward` shows `forward_proxy`.

Container won't start → check ports 80 + 443 free (`ss -ltnp | grep -E ':80|:443'`), stop conflicting services (`systemctl stop nginx apache2 caddy`), inspect (`docker logs cool-tunnel`).
