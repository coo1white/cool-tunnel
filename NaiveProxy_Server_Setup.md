# NaiveProxy Server Setup on Debian

Build a working NaiveProxy + Caddy server on Debian.

**Replace every `<USERNAME>` and `<PASSWORD>` placeholder below with strong, unique values that you generate fresh** (e.g. `openssl rand -base64 24`). Never copy a literal example password from a guide — including this one — into production. Earlier revisions of this file shipped a real password by mistake; if you used those values verbatim, rotate them now.

Prerequisites: Debian server with root access, domain pointing to server IP, Docker installed.

## Files

### Dockerfile
```dockerfile
FROM caddy:builder AS builder
RUN xcaddy build \
    --with github.com/caddyserver/forwardproxy@caddy2=github.com/klzgrad/forwardproxy@naive
FROM caddy:latest
COPY --from=builder /usr/bin/caddy /usr/bin/caddy
```

### Caddyfile
```caddyfile
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
```

Requirements: use `:443, DOMAIN` syntax (not just `DOMAIN`); include `tls your@email.com`; use `root * /srv` with `file_server` (not `respond "OK"`); do not pin Caddy version (use `caddy:builder` and `caddy:latest`); `order forward_proxy before file_server` is required.

### docker-compose.yml
```yaml
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
```

## Setup commands

```bash
mkdir -p /opt/cool-tunnel
cd /opt/cool-tunnel

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

mkdir -p site
echo OK > site/index.html

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

docker compose build --no-cache
docker compose up -d
```

## Management

```bash
docker logs --tail 30 cool-tunnel                              # check logs
docker logs -f cool-tunnel                                     # watch in real-time
docker exec cool-tunnel caddy list-modules | grep forward      # confirm forward_proxy loaded
docker compose restart
docker compose down
docker compose down && docker compose build --no-cache && docker compose up -d   # rebuild after changes
```

## Testing

```bash
# HTTPS directly — expected: OK
curl -v https://proxy.example.com

# Proxy directly from server — expected: shows server IP
curl -v --proxy "https://<USERNAME>:<PASSWORD>@proxy.example.com:443" https://ipinfo.io

# From Mac client — expected: HTTP/2 204
curl -x socks5h://127.0.0.1:1080 -vk --max-time 30 https://www.google.com/generate_204
```

## Troubleshooting

`SSL_ERROR_SYSCALL` on Mac client: verify Caddyfile uses `:443, DOMAIN` syntax; check `tls` directive is present; ensure `file_server` (not `respond "OK"`); confirm forward_proxy module loaded (`docker exec cool-tunnel caddy list-modules | grep forward`).

Container won't start: check ports 80 and 443 are free (`ss -ltnp | grep -E ':80|:443'`); stop conflicting services (`systemctl stop nginx apache2 caddy`); check Docker logs (`docker logs cool-tunnel`).
