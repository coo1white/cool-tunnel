# NaiveProxy Server Setup on Debian

This guide shows how to build a working NaiveProxy + Caddy server on Debian.

## Prerequisites

- Debian server with root access
- Domain pointing to server IP
- Docker installed

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

:443, naive.example.com {
    tls your@email.com
    forward_proxy {
        basic_auth nick ***REMOVED***
        hide_ip
        hide_via
        probe_resistance
    }
    root * /srv
    file_server
}
```

**Important:**
- Use `:443, DOMAIN` syntax (not just `DOMAIN`)
- Include `tls your@email.com` directive
- Use `root * /srv` with `file_server` (not `respond "OK"`)
- Do not pin Caddy version (use `caddy:builder` and `caddy:latest`)

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

## Setup Commands

```bash
# Create project folder
mkdir -p /opt/cool-tunnel
cd /opt/cool-tunnel

# Create Dockerfile
cat > Dockerfile <<'EOF'
FROM caddy:builder AS builder
RUN xcaddy build \
    --with github.com/caddyserver/forwardproxy@caddy2=github.com/klzgrad/forwardproxy@naive
FROM caddy:latest
COPY --from=builder /usr/bin/caddy /usr/bin/caddy
EOF

# Create Caddyfile (replace email and credentials)
cat > Caddyfile <<'EOF'
{
    order forward_proxy before file_server
}

:443, naive.example.com {
    tls your@email.com
    forward_proxy {
        basic_auth nick ***REMOVED***
        hide_ip
        hide_via
        probe_resistance
    }
    root * /srv
    file_server
}
EOF

# Create site folder
mkdir -p site
echo OK > site/index.html

# Create docker-compose.yml
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

# Build and start
docker compose build --no-cache
docker compose up -d
```

## Management Commands

```bash
# Check logs
docker logs --tail 30 cool-tunnel

# Watch logs in real-time
docker logs -f cool-tunnel

# Confirm forward_proxy module loaded
docker exec cool-tunnel caddy list-modules | grep forward

# Restart container
docker compose restart

# Stop container
docker compose down

# Rebuild after changes
docker compose down
docker compose build --no-cache
docker compose up -d
```

## Testing

### Test HTTPS directly
```bash
curl -v https://naive.example.com
```
Expected: `OK`

### Test proxy directly from server
```bash
curl -v --proxy "https://nick:***REMOVED***@naive.example.com:443" https://ipinfo.io
```
Expected: Shows server IP

### Test from Mac client
```bash
curl -x socks5h://127.0.0.1:1080 -vk --max-time 30 https://www.google.com/generate_204
```
Expected: `HTTP/2 204`

## Key Points

1. **Caddyfile syntax is critical** - use `:443, DOMAIN` format
2. **Include TLS directive** - `tls your@email.com`
3. **Use file_server as fallback** - `root * /srv file_server`
4. **Do not use respond "OK"** - this breaks forward_proxy
5. **Do not pin Caddy version** - use latest for compatibility
6. **Order directive is required** - `order forward_proxy before file_server`

## Troubleshooting

If you get `SSL_ERROR_SYSCALL` on Mac client:
- Verify Caddyfile uses `:443, DOMAIN` syntax
- Check that `tls` directive is present
- Ensure `file_server` is used instead of `respond "OK"`
- Confirm forward_proxy module is loaded: `docker exec cool-tunnel caddy list-modules | grep forward`

If container won't start:
- Check port 80 and 443 are free: `ss -ltnp | grep -E ':80|:443'`
- Stop conflicting services: `systemctl stop nginx apache2 caddy`
- Check Docker logs: `docker logs cool-tunnel`
