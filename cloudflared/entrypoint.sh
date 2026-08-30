#!/bin/sh
set -e

# ==============================================================================
# Cloudflared Smart Entrypoint (100% ENV Driven)
# ==============================================================================

echo "[cloudflared-entrypoint] Initializing Cloudflare Tunnel container..."

# ------------------------------------------------------------------------------
# 1. TOKEN MODE (Cloudflare Zero Trust Remote-Managed Tunnel)
# ------------------------------------------------------------------------------
if [ -n "$TUNNEL_TOKEN" ]; then
    echo "[cloudflared-entrypoint] Running in TOKEN mode (Cloudflare Zero Trust Dashboard managed)."
    exec cloudflared tunnel --no-autoupdate run --token "$TUNNEL_TOKEN"
fi

# ------------------------------------------------------------------------------
# 2. AUTO-GENERATED CONFIG MODE (Local YAML from Environment Variables)
# ------------------------------------------------------------------------------
if [ -n "$TUNNEL_ID" ]; then
    echo "[cloudflared-entrypoint] TUNNEL_ID detected: $TUNNEL_ID"
    mkdir -p /etc/cloudflared /etc/cloudflared/credentials

    # Write base64 credentials if provided directly via ENV
    if [ -n "$TUNNEL_CREDENTIALS_BASE64" ]; then
        echo "[cloudflared-entrypoint] Decoding credentials from TUNNEL_CREDENTIALS_BASE64..."
        echo "$TUNNEL_CREDENTIALS_BASE64" | base64 -d > "/etc/cloudflared/credentials/${TUNNEL_ID}.json"
    elif [ -n "$TUNNEL_CREDENTIALS_JSON" ]; then
        echo "[cloudflared-entrypoint] Writing credentials from TUNNEL_CREDENTIALS_JSON..."
        echo "$TUNNEL_CREDENTIALS_JSON" > "/etc/cloudflared/credentials/${TUNNEL_ID}.json"
    fi

    CONFIG_FILE="/etc/cloudflared/config.yml"

    # Only generate config.yml if it doesn't already exist or if FORCE_GENERATE_CONFIG=true
    if [ ! -f "$CONFIG_FILE" ] || [ "$FORCE_GENERATE_CONFIG" = "true" ]; then
        echo "[cloudflared-entrypoint] Auto-generating $CONFIG_FILE from environment variables..."

        PRIMARY_DOMAIN=${PRIMARY_DOMAIN:-"app.example.com"}
        UPSTREAM_HOST=${UPSTREAM_HOST:-"nginx"}
        UPSTREAM_PORT=${UPSTREAM_PORT:-"80"}
        TUNNEL_PROTOCOL=${TUNNEL_PROTOCOL:-"auto"}

        cat <<EOF > "$CONFIG_FILE"
# Auto-generated Cloudflare Tunnel Configuration
tunnel: ${TUNNEL_ID}
credentials-file: /etc/cloudflared/credentials/${TUNNEL_ID}.json
protocol: ${TUNNEL_PROTOCOL}

ingress:
  - hostname: ${PRIMARY_DOMAIN}
    service: http://${UPSTREAM_HOST}:${UPSTREAM_PORT}
    originRequest:
      noTLSVerify: true
      connectTimeout: 30s
      keepAliveTimeout: 1m30s
      http2Origin: true
EOF

        # Add secondary domain if configured
        if [ -n "$SECONDARY_DOMAIN" ]; then
            SECONDARY_UPSTREAM_HOST=${SECONDARY_UPSTREAM_HOST:-"nginx"}
            SECONDARY_UPSTREAM_PORT=${SECONDARY_UPSTREAM_PORT:-"80"}
            cat <<EOF >> "$CONFIG_FILE"
  - hostname: ${SECONDARY_DOMAIN}
    service: http://${SECONDARY_UPSTREAM_HOST}:${SECONDARY_UPSTREAM_PORT}
EOF
        fi

        # Add whoami diagnostic domain if configured
        if [ -n "$WHOAMI_DOMAIN" ]; then
            cat <<EOF >> "$CONFIG_FILE"
  - hostname: ${WHOAMI_DOMAIN}
    service: http://whoami:80
EOF
        fi

        # Append default catch-all 404 rule
        cat <<EOF >> "$CONFIG_FILE"
  - service: http_status:404
EOF
        echo "[cloudflared-entrypoint] Successfully generated $CONFIG_FILE"
    fi

    echo "[cloudflared-entrypoint] Starting tunnel with config $CONFIG_FILE..."
    exec cloudflared tunnel --config "$CONFIG_FILE" run
fi

# ------------------------------------------------------------------------------
# 3. FALLBACK: Execute default command or error
# ------------------------------------------------------------------------------
if [ "$#" -gt 0 ]; then
    exec "$@"
fi

echo "[cloudflared-entrypoint] ERROR: Neither TUNNEL_TOKEN nor TUNNEL_ID was provided in environment variables."
echo "[cloudflared-entrypoint] Please set TUNNEL_TOKEN in your .env file or Cloudflare dashboard."
exit 1

