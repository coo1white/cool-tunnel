#!/bin/bash

# Step-by-Step Debugging for Naive Proxy
# Run each command individually to identify the issue

echo "=== STEP 1: Check if NaiveProxy is running ==="
lsof -iTCP:1080 -sTCP:LISTEN
echo ""
echo "If no output above, NaiveProxy is NOT running. Start it from the app."
echo ""

echo "=== STEP 2: Test local SOCKS proxy ==="
curl -x socks5h://127.0.0.1:1080 --max-time 5 -v https://www.google.com/generate_204
echo ""
echo "If this fails, local proxy is not working."
echo ""

echo "=== STEP 3: Check DNS for server ==="
nslookup naive.coolwhite.space
echo ""

echo "=== STEP 4: Test server HTTPS connection ==="
curl -v --max-time 10 https://naive.coolwhite.space
echo ""

echo "=== STEP 5: Test server with credentials ==="
curl -v --max-time 10 --connect-timeout 5 https://nick:19990515Wry@naive.coolwhite.space
echo ""

echo "=== STEP 6: Check system proxy settings ==="
/usr/sbin/networksetup -getsocksfirewallproxy "Wi-Fi"
echo ""

echo "=== STEP 7: Check config file ==="
cat ~/Library/Application\ Support/NaiveProxyMac/config.json
echo ""

echo "=== STEP 8: Check NaiveProxy binary ==="
ls -lh /Users/lukebai/Library/Developer/Xcode/DerivedData/naive-gndwnmgfabynfhbvplhkypxgcygi/Build/Products/Debug/naive.app/Contents/Resources/naive
echo ""
