#!/bin/bash

# Server-Side Debugging Script for Debian 13
# Tests Caddy, Docker, and COOL TUNNEL configuration

echo "=========================================="
echo "Server-Side Debugging Script"
echo "Debian 13 - Caddy/Docker/Naive Proxy"
echo "=========================================="
echo ""

# Color codes
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

# Test 1: Check if Docker is running
echo "TEST 1: Check Docker Status"
echo "------------------------------------------"
if systemctl is-active --quiet docker; then
    echo -e "${GREEN}✓ Docker is running${NC}"
    docker --version
else
    echo -e "${RED}✗ Docker is NOT running${NC}"
    echo "Start Docker: sudo systemctl start docker"
fi
echo ""

# Test 2: Check Docker containers
echo "TEST 2: Check Docker Containers"
echo "------------------------------------------"
docker ps -a
echo ""

# Test 3: Check if Caddy is running (in Docker or system)
echo "TEST 3: Check Caddy Status"
echo "------------------------------------------"
if docker ps | grep -q caddy; then
    echo -e "${GREEN}✓ Caddy container is running${NC}"
    docker ps | grep caddy
elif systemctl is-active --quiet caddy; then
    echo -e "${GREEN}✓ Caddy service is running${NC}"
    systemctl status caddy --no-pager
else
    echo -e "${RED}✗ Caddy is NOT running${NC}"
    echo "Check if Caddy is in Docker or as a system service"
fi
echo ""

# Test 4: Check if port 443 is listening
echo "TEST 4: Check Port 443 Status"
echo "------------------------------------------"
if netstat -tlnp | grep -q ":443 "; then
    echo -e "${GREEN}✓ Port 443 is listening${NC}"
    netstat -tlnp | grep ":443 "
else
    echo -e "${RED}✗ Port 443 is NOT listening${NC}"
    echo "This explains why clients can't connect"
fi
echo ""

# Test 5: Check Caddy configuration
echo "TEST 5: Check Caddy Configuration"
echo "------------------------------------------"
if [ -f "/etc/caddy/Caddyfile" ]; then
    echo -e "${GREEN}✓ Caddyfile found at /etc/caddy/Caddyfile${NC}"
    echo "Contents:"
    cat /etc/caddy/Caddyfile
elif docker ps | grep -q caddy; then
    echo "Caddy is running in Docker, checking container config..."
    docker exec $(docker ps -q -f name=caddy) cat /etc/caddy/Caddyfile 2>/dev/null || echo "Could not read Caddyfile from container"
else
    echo -e "${YELLOW}⚠ Caddyfile not found at standard location${NC}"
fi
echo ""

# Test 6: Check Caddy logs
echo "TEST 6: Check Caddy Logs"
echo "------------------------------------------"
if docker ps | grep -q caddy; then
    echo "Caddy container logs (last 20 lines):"
    docker logs --tail 20 $(docker ps -q -f name=caddy)
elif systemctl is-active --quiet caddy; then
    echo "Caddy service logs (last 20 lines):"
    journalctl -u caddy -n 20 --no-pager
else
    echo -e "${YELLOW}⚠ Caddy not running, no logs available${NC}"
fi
echo ""

# Test 7: Check Docker network
echo "TEST 7: Check Docker Network"
echo "------------------------------------------"
docker network ls
echo ""
echo "Bridge network details:"
docker network inspect bridge 2>/dev/null | head -20
echo ""

# Test 8: Check firewall rules
echo "TEST 8: Check Firewall Rules"
echo "------------------------------------------"
if command -v ufw &> /dev/null; then
    echo "UFW Firewall Status:"
    sudo ufw status
elif command -v iptables &> /dev/null; then
    echo "iptables rules:"
    sudo iptables -L -n | head -20
else
    echo "No standard firewall detected"
fi
echo ""

# Test 9: Test local connection to port 443
echo "TEST 9: Test Local Connection to Port 443"
echo "------------------------------------------"
if curl -v --max-time 5 https://localhost 2>&1 | grep -q "Connected"; then
    echo -e "${GREEN}✓ Local connection to port 443 works${NC}"
else
    echo -e "${RED}✗ Local connection to port 443 FAILED${NC}"
    echo "Caddy might not be properly configured"
fi
echo ""

# Test 10: Check DNS resolution for domain
echo "TEST 10: Check DNS Resolution"
echo "------------------------------------------"
if nslookup naive.coolwhite.space > /dev/null 2>&1; then
    echo -e "${GREEN}✓ DNS resolution works${NC}"
    nslookup naive.coolwhite.space
else
    echo -e "${RED}✗ DNS resolution FAILED${NC}"
fi
echo ""

# Test 11: Check system resources
echo "TEST 11: Check System Resources"
echo "------------------------------------------"
echo "Memory usage:"
free -h
echo ""
echo "Disk usage:"
df -h
echo ""
echo "CPU usage:"
top -bn1 | head -5
echo ""

echo "=========================================="
echo "Server Debugging Complete"
echo "=========================================="
echo ""
echo "Common Issues and Fixes:"
echo "1. If Docker not running: sudo systemctl start docker"
echo "2. If Caddy not running: Check Docker containers or systemctl start caddy"
echo "3. If port 443 not listening: Check Caddy configuration"
echo "4. If firewall blocking: Allow port 443 (sudo ufw allow 443)"
echo "5. Check Caddyfile for correct domain configuration"
