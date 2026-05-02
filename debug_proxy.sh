#!/bin/bash

# COOL TUNNEL Debugging Script
# Tests connectivity from macOS client to Debian server with Caddy/Docker

echo "=========================================="
echo "Naive Proxy Debugging Script"
echo "=========================================="
echo ""

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

SERVER="naive.coolwhite.space"
USERNAME="nick"
PORT="1080"

# Test 1: Check if local NaiveProxy is running
echo "TEST 1: Check if local NaiveProxy is running"
echo "------------------------------------------"
if lsof -iTCP:$PORT -sTCP:LISTEN > /dev/null 2>&1; then
    echo -e "${GREEN}✓ NaiveProxy is listening on port $PORT${NC}"
    lsof -iTCP:$PORT -sTCP:LISTEN
else
    echo -e "${RED}✗ NaiveProxy is NOT listening on port $PORT${NC}"
    echo "Start the proxy from the macOS app first"
fi
echo ""

# Test 2: Check local SOCKS proxy connectivity
echo "TEST 2: Test local SOCKS proxy connectivity"
echo "------------------------------------------"
echo "Testing connection through local proxy to Google..."
if curl -x socks5h://127.0.0.1:$PORT --max-time 10 -s https://www.google.com/generate_204 > /dev/null 2>&1; then
    echo -e "${GREEN}✓ Local SOCKS proxy is working${NC}"
else
    echo -e "${RED}✗ Local SOCKS proxy is NOT working${NC}"
    echo "This indicates the NaiveProxy process is not functioning correctly"
fi
echo ""

# Test 3: Check DNS resolution for server
echo "TEST 3: Check DNS resolution for $SERVER"
echo "------------------------------------------"
if nslookup $SERVER > /dev/null 2>&1; then
    echo -e "${GREEN}✓ DNS resolution for $SERVER works${NC}"
    nslookup $SERVER
else
    echo -e "${RED}✗ DNS resolution for $SERVER FAILED${NC}"
    echo "Check your DNS settings and network connectivity"
fi
echo ""

# Test 4: Check server connectivity (HTTP)
echo "TEST 4: Test server HTTP connectivity"
echo "------------------------------------------"
echo "Testing HTTP connection to $SERVER..."
if curl -v --max-time 10 https://$SERVER 2>&1 | grep -q "Connected"; then
    echo -e "${GREEN}✓ Server $SERVER is reachable via HTTPS${NC}"
else
    echo -e "${RED}✗ Server $SERVER is NOT reachable via HTTPS${NC}"
    echo "Check if Caddy is running and the server is accessible"
fi
echo ""

# Test 5: Check if server port 443 is open
echo "TEST 5: Check if server port 443 is open"
echo "------------------------------------------"
if nc -z -v -w 5 $SERVER 443 2>&1 | grep -q "succeeded"; then
    echo -e "${GREEN}✓ Server port 443 is open${NC}"
else
    echo -e "${RED}✗ Server port 443 is NOT accessible${NC}"
    echo "Check firewall settings on Debian server"
fi
echo ""

# Test 6: Test direct connection to server with credentials
echo "TEST 6: Test direct connection to server with credentials"
echo "------------------------------------------"
echo "Testing HTTPS connection with authentication..."
if curl -v --max-time 10 --connect-timeout 5 https://${USERNAME}:19990515Wry@${SERVER} 2>&1 | grep -q "Connected"; then
    echo -e "${GREEN}✓ Server authentication works${NC}"
else
    echo -e "${RED}✗ Server authentication FAILED${NC}"
    echo "Check username/password and server configuration"
fi
echo ""

# Test 7: Check macOS system proxy settings
echo "TEST 7: Check macOS system proxy settings"
echo "------------------------------------------"
echo "Current SOCKS proxy settings:"
/usr/sbin/networksetup -getsocksfirewallproxy "Wi-Fi"
echo ""
echo "Current Auto Proxy settings:"
/usr/sbin/networksetup -getautoproxyurl "Wi-Fi"
echo ""

# Test 8: Test NaiveProxy configuration file
echo "TEST 8: Check NaiveProxy configuration file"
echo "------------------------------------------"
CONFIG_FILE="$HOME/Library/Application Support/NaiveProxyMac/config.json"
if [ -f "$CONFIG_FILE" ]; then
    echo -e "${GREEN}✓ Config file exists: $CONFIG_FILE${NC}"
    echo "Contents (password masked):"
    cat "$CONFIG_FILE" | sed 's/"password":"[^"]*"/"password":"***"/'
else
    echo -e "${RED}✗ Config file not found: $CONFIG_FILE${NC}"
fi
echo ""

# Test 9: Check NaiveProxy binary
echo "TEST 9: Check NaiveProxy binary"
echo "------------------------------------------"
NAIVE_BINARY="/Users/lukebai/Library/Developer/Xcode/DerivedData/naive-gndwnmgfabynfhbvplhkypxgcygi/Build/Products/Debug/naive.app/Contents/Resources/naive"
if [ -f "$NAIVE_BINARY" ]; then
    echo -e "${GREEN}✓ NaiveProxy binary exists${NC}"
    echo "Binary info:"
    file "$NAIVE_BINARY"
    ls -lh "$NAIVE_BINARY"
else
    echo -e "${RED}✗ NaiveProxy binary not found${NC}"
    echo "Expected location: $NAIVE_BINARY"
fi
echo ""

# Test 10: Test NaiveProxy directly with config
echo "TEST 10: Test NaiveProxy binary directly"
echo "------------------------------------------"
if [ -f "$NAIVE_BINARY" ] && [ -f "$CONFIG_FILE" ]; then
    echo "Starting NaiveProxy manually for testing..."
    echo "Will run for 5 seconds then stop..."
    timeout 5 "$NAIVE_BINARY" "$CONFIG_FILE" 2>&1 | head -20
    echo ""
    echo "Check if it started listening:"
    sleep 2
    if lsof -iTCP:$PORT -sTCP:LISTEN > /dev/null 2>&1; then
        echo -e "${GREEN}✓ NaiveProxy can start and listen on port $PORT${NC}"
    else
        echo -e "${RED}✗ NaiveProxy failed to start or listen${NC}"
    fi
else
    echo "Skipping - binary or config not found"
fi
echo ""

# Test 11: Network trace to server
echo "TEST 11: Network trace to server"
echo "------------------------------------------"
echo "Traceroute to $SERVER:"
traceroute -m 10 $SERVER 2>&1 | head -10
echo ""

# Test 12: Check for any firewall issues
echo "TEST 12: Check macOS firewall status"
echo "------------------------------------------"
if /usr/libexec/ApplicationFirewall/socketfilterfw --getglobalstate | grep -q "enabled"; then
    echo -e "${YELLOW}⚠ macOS Firewall is enabled${NC}"
    echo "This might block connections. Check firewall settings."
else
    echo -e "${GREEN}✓ macOS Firewall is disabled${NC}"
fi
echo ""

echo "=========================================="
echo "Debugging Complete"
echo "=========================================="
echo ""
echo "Summary:"
echo "1. Check for RED marks above - these indicate issues"
echo "2. Ensure NaiveProxy is running and listening on port $PORT"
echo "3. Verify server $SERVER is accessible from your network"
echo "4. Check Caddy/Docker logs on Debian server if server tests fail"
echo "5. Test the 'Test Proxy' button in the macOS app for detailed diagnostics"
