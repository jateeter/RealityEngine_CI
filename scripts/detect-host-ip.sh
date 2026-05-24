#!/bin/bash
# Detect the host's primary non-loopback LAN IPv4 address.
# Works on macOS (Darwin) and Linux.
# Outputs the IP on stdout; exits 1 if no address is found.

if command -v ip >/dev/null 2>&1; then
    # Linux: use ip route to find the src address used to reach the internet
    _addr=$(ip route get 1.1.1.1 2>/dev/null \
        | awk '{for(i=1;i<=NF;i++) if ($i=="src") {print $(i+1); exit}}')
else
    # macOS: use route + ipconfig
    _iface=$(route get 1.1.1.1 2>/dev/null | awk '/interface:/{print $2}')
    if [ -n "$_iface" ]; then
        _addr=$(ipconfig getifaddr "$_iface" 2>/dev/null)
    fi
fi

# Fallback: first non-loopback inet address from ifconfig/ip addr
if [ -z "$_addr" ]; then
    if command -v ip >/dev/null 2>&1; then
        _addr=$(ip addr show 2>/dev/null \
            | awk '/inet /{gsub(/\/.*/, "", $2); if ($2 != "127.0.0.1") {print $2; exit}}')
    else
        _addr=$(ifconfig 2>/dev/null \
            | awk '/inet /{if ($2 != "127.0.0.1") {print $2; exit}}')
    fi
fi

if [ -z "$_addr" ]; then
    echo "127.0.0.1"  # last resort — avoids breaking caller
    exit 1
fi

echo "$_addr"
