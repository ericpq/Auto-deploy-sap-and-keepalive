#!/bin/bash
set -e

# ── 环境变量默认值 ───────────────────────────────────────────────────────────
UUID=${UUID:-$(python3 -c "import uuid; print(uuid.uuid4())")}
# CF 平台注入 PORT，nginx 监听它；cloudflared 也指向它
PORT=${PORT:-8080}
XRAY_PORT=8002          # xray 内部，仅本机
VMESS_PORT=8003         # vmess 内部，仅本机
SUB_PATH=${SUB_PATH:-sub}
NAME=${NAME:-SAP-WARP}
CFIP=${CFIP:-cf.877774.xyz}
CFPORT=${CFPORT:-443}
WARP_SOCKS=127.0.0.1:40000

echo "=========================================="
echo "  SAP WARP Node  |  $(date '+%Y-%m-%d %H:%M:%S')"
echo "  PORT=${PORT}"
echo "=========================================="

# ── 1. WARP via wireproxy ────────────────────────────────────────────────────
echo "[WARP] 注册 Cloudflare WARP..."
cd /tmp
# 注册失败不退出，继续尝试
wgcf register --accept-tos -f > /dev/null 2>&1 || true
wgcf generate -f > /dev/null 2>&1 || true

if [ ! -f /tmp/wgcf-profile.conf ]; then
    echo "[WARP] wgcf 注册失败，跳过 WARP，使用直连出站"
    WARP_ENABLED=false
else
    PRIV_KEY=$(awk '/PrivateKey/{print $3}' /tmp/wgcf-profile.conf)
    ADDR_V4=$(awk '/Address/{print $3}' /tmp/wgcf-profile.conf | head -1)
    ADDR_V6=$(awk '/Address/{print $3}' /tmp/wgcf-profile.conf | tail -1)
    PEER_PUB=$(awk '/PublicKey/{print $3}' /tmp/wgcf-profile.conf)
    ENDPOINT=$(awk '/Endpoint/{print $3}' /tmp/wgcf-profile.conf)

    cat > /tmp/wireproxy.conf << WPCFG
[Interface]
PrivateKey = ${PRIV_KEY}
Address = ${ADDR_V4}
Address = ${ADDR_V6}
DNS = 1.1.1.1, 2606:4700:4700::1111

[Peer]
PublicKey = ${PEER_PUB}
AllowedIPs = 0.0.0.0/0, ::/0
Endpoint = ${ENDPOINT}
PersistentKeepalive = 25

[Socks5]
BindAddress = ${WARP_SOCKS}
WPCFG

    echo "[WARP] 启动 wireproxy..."
    wireproxy -c /tmp/wireproxy.conf &

    WARP_ENABLED=false
    for i in $(seq 1 15); do
        if curl -fs --socks5 "${WARP_SOCKS}" --max-time 5 https://cloudflare.com/cdn-cgi/trace > /tmp/warp_trace.txt 2>&1; then
            WARP_IP=$(grep '^ip=' /tmp/warp_trace.txt | cut -d= -f2)
            WARP_COLO=$(grep '^colo=' /tmp/warp_trace.txt | cut -d= -f2)
            echo "[WARP] 就绪  IP=${WARP_IP}  节点=${WARP_COLO}"
            WARP_ENABLED=true
            break
        fi
        echo "[WARP] 等待... (${i}/15)"
        sleep 2
    done

    if [ "$WARP_ENABLED" = "false" ]; then
        echo "[WARP] 连接超时，回退到直连出站"
    fi
fi

# ── 2. Xray 配置 ──────────────────────────────────────────────────────────────
echo "[Xray] 生成配置..."
mkdir -p /tmp/xray-conf

if [ "$WARP_ENABLED" = "true" ]; then
    OUTBOUND_TAG="warp-out"
    OUTBOUNDS='"outbounds": [
    {
      "tag": "warp-out",
      "protocol": "socks",
      "settings": { "servers": [{ "address": "127.0.0.1", "port": 40000 }] }
    },
    { "tag": "direct", "protocol": "freedom" }
  ]'
else
    OUTBOUND_TAG="direct"
    OUTBOUNDS='"outbounds": [
    { "tag": "direct", "protocol": "freedom" }
  ]'
fi

cat > /tmp/xray-conf/config.json << XCFG
{
  "log": { "loglevel": "warning" },
  "inbounds": [
    {
      "tag": "vless-in",
      "port": ${XRAY_PORT},
      "protocol": "vless",
      "settings": {
        "clients": [{ "id": "${UUID}", "flow": "" }],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": { "path": "/${UUID}-vless" }
      }
    },
    {
      "tag": "vmess-in",
      "port": ${VMESS_PORT},
      "protocol": "vmess",
      "settings": { "clients": [{ "id": "${UUID}" }] },
      "streamSettings": {
        "network": "ws",
        "wsSettings": { "path": "/${UUID}-vmess" }
      }
    }
  ],
  ${OUTBOUNDS},
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [{ "type": "field", "network": "tcp,udp", "outboundTag": "${OUTBOUND_TAG}" }]
  }
}
XCFG

echo "[Xray] 启动..."
xray run -c /tmp/xray-conf/config.json &
sleep 2

# ── 3. Nginx 配置（监听 CF 注入的 PORT）─────────────────────────────────────
echo "[Nginx] 生成配置，端口=${PORT}..."
export UUID SUB_PATH PORT XRAY_PORT VMESS_PORT
envsubst '${UUID} ${SUB_PATH} ${PORT} ${XRAY_PORT} ${VMESS_PORT}' \
    < /app/nginx.conf.tmpl > /tmp/nginx.conf

# ── 4. Argo 隧道 ──────────────────────────────────────────────────────────────
echo "[Argo] 启动隧道..."
if [ -n "${ARGO_AUTH}" ] && [ -n "${ARGO_DOMAIN}" ]; then
    echo "[Argo] 固定隧道: ${ARGO_DOMAIN}"
    cloudflared tunnel --edge-ip-version auto --no-autoupdate \
        run --token "${ARGO_AUTH}" \
        --logfile /tmp/argo.log &
    ARGO_DOMAIN_FINAL="${ARGO_DOMAIN}"
else
    echo "[Argo] 临时隧道 -> http://127.0.0.1:${PORT}"
    cloudflared tunnel --edge-ip-version auto --no-autoupdate \
        --url "http://127.0.0.1:${PORT}" \
        --logfile /tmp/argo.log &

    for i in $(seq 1 20); do
        ARGO_DOMAIN_FINAL=$(grep -o 'https://[a-zA-Z0-9-]*\.trycloudflare\.com' /tmp/argo.log 2>/dev/null \
            | head -1 | sed 's|https://||')
        [ -n "${ARGO_DOMAIN_FINAL}" ] && break
        echo "[Argo] 等待域名... (${i}/20)"
        sleep 3
    done

    [ -z "${ARGO_DOMAIN_FINAL}" ] && echo "[Argo] ⚠️ 临时域名获取失败"
    [ -n "${ARGO_DOMAIN_FINAL}" ] && echo "[Argo] 临时域名: ${ARGO_DOMAIN_FINAL}"
fi

# ── 5. 生成订阅 ───────────────────────────────────────────────────────────────
if [ -n "${ARGO_DOMAIN_FINAL}" ]; then
    VLESS_URI="vless://${UUID}@${CFIP}:${CFPORT}?encryption=none&security=tls&sni=${ARGO_DOMAIN_FINAL}&type=ws&host=${ARGO_DOMAIN_FINAL}&path=%2F${UUID}-vless#${NAME}-vless"

    VMESS_JSON="{\"v\":\"2\",\"ps\":\"${NAME}-vmess\",\"add\":\"${CFIP}\",\"port\":\"${CFPORT}\",\"id\":\"${UUID}\",\"aid\":\"0\",\"scy\":\"auto\",\"net\":\"ws\",\"type\":\"none\",\"host\":\"${ARGO_DOMAIN_FINAL}\",\"path\":\"/${UUID}-vmess\",\"tls\":\"tls\",\"sni\":\"${ARGO_DOMAIN_FINAL}\",\"alpn\":\"\"}"
    VMESS_URI="vmess://$(echo -n "${VMESS_JSON}" | base64 | tr -d '\n')"

    printf '%s\n%s' "${VLESS_URI}" "${VMESS_URI}" | base64 | tr -d '\n' > /tmp/sub.b64
    echo "[Sub] 订阅: https://${ARGO_DOMAIN_FINAL}/${SUB_PATH}"
else
    echo "暂无订阅" | base64 > /tmp/sub.b64
fi

# ── 6. 启动 Nginx（前台，作为主进程）─────────────────────────────────────────
echo "[Nginx] 启动..."
echo ""
echo "=========================================="
echo "  WARP=${WARP_ENABLED}  出口IP=${WARP_IP:-direct}"
echo "  Argo域名: ${ARGO_DOMAIN_FINAL}"
echo "  订阅: https://${ARGO_DOMAIN_FINAL}/${SUB_PATH}"
echo "=========================================="

exec nginx -c /tmp/nginx.conf
