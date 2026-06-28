#!/bin/sh
set -e

echo "======================================================"
echo "  密钥注入脚本（仅用于 CI/CD 构建）"
echo "======================================================"

SECRET_DIR="/opt/installer/tmp"

# ==========================================
# SSH 密钥注入
# ==========================================
echo "[1/3] SSH 密钥注入..."

if [ -f ${SECRET_DIR}/ssh_private_key ]; then
    mkdir -p /root/.ssh
    chmod 700 /root/.ssh

    cp ${SECRET_DIR}/ssh_private_key /root/.ssh/id_ed25519
    chmod 600 /root/.ssh/id_ed25519

    if [ -f ${SECRET_DIR}/ssh_public_key ]; then
        cp ${SECRET_DIR}/ssh_public_key /root/.ssh/id_ed25519.pub
        chmod 644 /root/.ssh/id_ed25519.pub
    fi

    cat << 'EOF' > /root/.ssh/config
Host gitea.allenmagic.cn
    HostName 192.168.8.137
    User git
    IdentityFile ~/.ssh/id_ed25519
    StrictHostKeyChecking no

Host github
    HostName github.com
    User git
    IdentityFile ~/.ssh/id_ed25519
    StrictHostKeyChecking no
EOF
    chmod 600 /root/.ssh/config

    if [ -f ${SECRET_DIR}/ssh_known_hosts ]; then
        cp ${SECRET_DIR}/ssh_known_hosts /root/.ssh/known_hosts
        chmod 644 /root/.ssh/known_hosts
    fi

    touch /root/.ssh/known_hosts
    chmod 644 /root/.ssh/known_hosts

    echo "  → SSH 密钥注入完成"
else
    echo "  → 未找到 ${SECRET_DIR}/ssh_private_key，跳过"
fi

# ==========================================
# Tailscale / Headscale 密钥注入
# ==========================================
echo "[2/3] Tailscale / Headscale 密钥注入..."

# 1) Tailscale: /etc/tailscale/config.json -> authKey=file:/etc/tailscale/authkey
if [ -f "${SECRET_DIR}/tailscale_authkey" ]; then
    mkdir -p /etc/tailscale
    cp "${SECRET_DIR}/tailscale_authkey" /etc/tailscale/authkey
    chmod 600 /etc/tailscale/authkey
    echo "  → Tailscale authkey 已注入"
else
    echo "  → 未找到 ${SECRET_DIR}/tailscale_authkey，跳过"
fi

# 2) sing-box: config.json -> endpoints[].auth_key
if [ -f "${SECRET_DIR}/headscale_authkey" ]; then
    if [ -f /etc/sing-box/config.json ]; then
        HS_AUTH_KEY="$(cat "${SECRET_DIR}/headscale_authkey")"
        # Escape for sed replacement.
        HS_AUTH_KEY_ESCAPED="$(printf '%s' "$HS_AUTH_KEY" | sed -e 's/[\\/&|]/\\&/g')"
        sed -i "s|__ROUTER_HEADSCALE_AUTH_KEY__|${HS_AUTH_KEY_ESCAPED}|g" /etc/sing-box/config.json
        echo "  → sing-box auth_key 已注入"
    else
        echo "  → 未找到 /etc/sing-box/config.json，跳过"
    fi
else
    echo "  → 未找到 ${SECRET_DIR}/headscale_authkey，跳过"
fi

# 3) tailscaled.log.conf: tailnode.log.tailscale.io 上报密钥
if [ -f "${SECRET_DIR}/tailscale_log_private_id" ]; then
    if [ -f /etc/sing-box/headscale/tailscaled.log.conf ]; then
        TS_LOG_KEY="$(cat "${SECRET_DIR}/tailscale_log_private_id")"
        TS_LOG_KEY_ESCAPED="$(printf '%s' "$TS_LOG_KEY" | sed -e 's/[\\/&|]/\\&/g')"
        sed -i "s|__TS_AUTH_KEY__|${TS_LOG_KEY_ESCAPED}|g" /etc/sing-box/headscale/tailscaled.log.conf
        echo "  → tailscale log key 已注入"
    else
        echo "  → 未找到 /etc/sing-box/headscale/tailscaled.log.conf，跳过"
    fi
else
    echo "  → 未找到 ${SECRET_DIR}/tailscale_log_private_id，跳过"
fi

# ==========================================
# 清理临时文件
# ==========================================
echo "[3/3] 清理临时文件..."
rm -rf ${SECRET_DIR}
echo "  → 临时文件已清理"

echo "======================================================"
echo "  密钥注入完成"
echo "======================================================"
