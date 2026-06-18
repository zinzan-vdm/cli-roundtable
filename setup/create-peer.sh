#!/bin/sh
# create-peer.sh — Create an initial WireGuard peer via the wg-easy API.
#
# Run with: docker compose --profile setup run --rm create-peer
# Requires wg-easy to already be running (docker compose up -d).

set -e

WG_EASY_URL="http://wg-easy:51821"
COOKIE_JAR="/tmp/wg-cookies.txt"

echo "==> Waiting for wg-easy at ${WG_EASY_URL}..."

# Wait up to 30s for wg-easy to be ready
for i in $(seq 1 30); do
    if curl -sf "${WG_EASY_URL}/api/session" >/dev/null 2>&1; then
        break
    fi
    sleep 1
done

echo "==> Authenticating..."
if ! curl -sf -X POST "${WG_EASY_URL}/api/session" \
    -H "Content-Type: application/json" \
    -d "{\"password\":\"${WG_PASSWORD}\"}" \
    -c "${COOKIE_JAR}" -o /dev/null; then
    echo "Error: Authentication failed. Check WG_PASSWORD." >&2
    exit 1
fi

echo "==> Checking for existing client '${PEER_NAME}'..."
EXISTING=$(curl -sf -b "${COOKIE_JAR}" "${WG_EASY_URL}/api/wireguard/client" 2>/dev/null || echo "[]")
if echo "$EXISTING" | grep -q "\"name\":\"${PEER_NAME}\""; then
    echo "Client '${PEER_NAME}' already exists. Skipping creation."
else
    echo "==> Creating client '${PEER_NAME}'..."
    curl -sf -X POST "${WG_EASY_URL}/api/wireguard/client" \
        -H "Content-Type: application/json" \
        -b "${COOKIE_JAR}" \
        -d "{\"name\":\"${PEER_NAME}\"}" -o /dev/null
    echo "Client created."
fi

echo ""
echo "==> Fetching configuration..."
CONFIG_URL="${WG_EASY_URL}/api/wireguard/client/${PEER_NAME}/configuration"
CONFIG=$(curl -sf -b "${COOKIE_JAR}" "${CONFIG_URL}" 2>/dev/null)

if [ -z "$CONFIG" ]; then
    echo "Error: Could not fetch config. Check wg-easy logs." >&2
    exit 1
fi

echo ""
echo "═══════════════════════════════════════════════════════════"
echo "  WireGuard Configuration for: ${PEER_NAME}"
echo "═══════════════════════════════════════════════════════════"
echo ""
echo "$CONFIG"
echo ""
echo "═══════════════════════════════════════════════════════════"
echo "  Save this to your laptop as /etc/wireguard/wg0.conf"
echo "  (or import it into the WireGuard client of your choice)"
echo "═══════════════════════════════════════════════════════════"

rm -f "${COOKIE_JAR}"