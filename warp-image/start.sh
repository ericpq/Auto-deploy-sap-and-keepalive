#!/bin/bash

# 不用 set -e，手动处理关键错误
UUID=${UUID:-$(python3 -c "import uuid; print(uuid.uuid4())")}
PORT=${PORT:-8080}
XRAY_PORT=8002
VMESS_PORT=8003
[ -z "$SUB_PATH" ]  && SUB_PATH=sub
[ -z "$CFIP" ]      && CFIP=cf.877774.xyz
[ -z "$CFPORT" ]    && CFPORT=443
[ -z "$NAME" ]      && NAME=SAP-WARP
WARP_SOCKS=127.0.0.1:40000

echo "[boot] PORT=${PORT} SUB=${SUB_PATH} UUID=${UUID:0:8}..."

# ── nginx 配置生成 ─────────────────────────────────────────────────────────────
write_nginx() {
    local sub_b64="${1:-}"
    cat > /tmp/nginx.conf << NGINXEOF
worker_processes 1;
error_log /dev/null;
pid /tmp/nginx.pid;
events { worker_connections 512; }
http {
    access_log off;
    client_max_body_size 0;
    server {
        listen ${PORT};
        location = / {
            default_type text/plain;
            return 200 "Hello World\n";
        }
        location = /${SUB_PATH} {
            default_type "text/plain";
            return 200 "${sub_b64:-not_ready}";
        }
        location = /${UUID}-vless {
            proxy_pass http://127.0.0.1:${XRAY_PORT};
            proxy_http_version 1.1;
            proxy_set_header Upgrade \$http_upgrade;
            proxy_set_header Connection "upgrade";
            proxy_set_header Host \$host;
            proxy_read_timeout 300s;
        }
        location = /${UUID}-vmess {
            proxy_pass http://127.0.0.1:${VMESS_PORT};
            proxy_http_version 1.1;
            proxy_set_header Upgrade \$http_upgrade;
            proxy_set_header Connection "upgrade";
            proxy_set_header Host \$host;
            proxy_read_timeout 300s;
        }
    }
}
NGINXEOF
}

# ── 1. nginx 启动（daemon 模式，只监听 $PORT）─────────────────────────────────
write_nginx
nginx -c /tmp/nginx.conf
if [ $? -ne 0 ]; then
    echo "[nginx] 启动失败！退出"
    exit 1
fi
sleep 1
echo "[nginx] 已启动 PID=$(cat /tmp/nginx.pid 2>/dev/null)"

# ── 2. socat 桥接 8001 → $PORT（Argo 固定隧道用）────────────────────────────
socat TCP-LISTEN:8001,fork,reuseaddr TCP:127.0.0.1:${PORT} &
echo "[socat] 8001 → ${PORT}"

# ── 3. WARP ───────────────────────────────────────────────────────────────────
echo "[warp] 注册..."
cd /tmp
wgcf register --accept-tos -f >/dev/null 2>&1 || true
wgcf generate -f >/dev/null 2>&1 || true

WARP_ENABLED=false
WARP_IP=direct
if [ -f /tmp/wgcf-profile.conf ]; then
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
    wireproxy -c /tmp/wireproxy.conf &
    for i in $(seq 1 15); do
        if curl -fs --socks5 "${WARP_SOCKS}" --max-time 5 \
               https://cloudflare.com/cdn-cgi/trace >/tmp/wt.txt 2>&1; then
            WARP_IP=$(grep '^ip='   /tmp/wt.txt | cut -d= -f2)
            WARP_DC=$(grep '^colo=' /tmp/wt.txt | cut -d= -f2)
            echo "[warp] OK IP=${WARP_IP} DC=${WARP_DC}"
            WARP_ENABLED=true; break
        fi
        echo "[warp] 等待 ${i}/15"; sleep 2
    done
    [ "$WARP_ENABLED" = "false" ] && echo "[warp] 超时，回退直连"
else
    echo "[warp] wgcf 失败，使用直连"
fi

# ── 4. xray ───────────────────────────────────────────────────────────────────
mkdir -p /tmp/xray-conf
if [ "$WARP_ENABLED" = "true" ]; then
    EXTRA=', {"tag":"warp","protocol":"socks","settings":{"servers":[{"address":"127.0.0.1","port":40000}]}}'
    RTAG=warp
else
    EXTRA=''
    RTAG=direct
fi
cat > /tmp/xray-conf/config.json << XC
{
  "log":{"loglevel":"warning"},
  "inbounds":[
    {"tag":"vin","port":${XRAY_PORT},"protocol":"vless",
     "settings":{"clients":[{"id":"${UUID}","flow":""}],"decryption":"none"},
     "streamSettings":{"network":"ws","wsSettings":{"path":"/${UUID}-vless"}}},
    {"tag":"min","port":${VMESS_PORT},"protocol":"vmess",
     "settings":{"clients":[{"id":"${UUID}"}]},
     "streamSettings":{"network":"ws","wsSettings":{"path":"/${UUID}-vmess"}}}
  ],
  "outbounds":[{"tag":"direct","protocol":"freedom"}${EXTRA}],
  "routing":{"rules":[{"type":"field","network":"tcp,udp","outboundTag":"${RTAG}"}]}
}
XC
xray run -c /tmp/xray-conf/config.json &
sleep 2

# ── 5. Argo ───────────────────────────────────────────────────────────────────
if [ -n "${ARGO_AUTH}" ] && [ -n "${ARGO_DOMAIN}" ]; then
    echo "[argo] 固定隧道 ${ARGO_DOMAIN}"
    cloudflared tunnel --edge-ip-version auto --no-autoupdate \
        run --token "${ARGO_AUTH}" --logfile /tmp/argo.log &
    ARGO_DOMAIN_FINAL="${ARGO_DOMAIN}"
else
    echo "[argo] 临时隧道 -> :${PORT}"
    cloudflared tunnel --edge-ip-version auto --no-autoupdate \
        --url "http://127.0.0.1:${PORT}" --logfile /tmp/argo.log &
    for i in $(seq 1 20); do
        ARGO_DOMAIN_FINAL=$(grep -o 'https://[a-zA-Z0-9-]*\.trycloudflare\.com' \
            /tmp/argo.log 2>/dev/null | head -1 | sed 's|https://||')
        [ -n "${ARGO_DOMAIN_FINAL}" ] && break
        echo "[argo] 等待 ${i}/20"; sleep 3
    done
fi
echo "[argo] 域名=${ARGO_DOMAIN_FINAL}"

# ── 6. 订阅 + nginx 热重载 ────────────────────────────────────────────────────
if [ -n "${ARGO_DOMAIN_FINAL}" ]; then
    V="vless://${UUID}@${CFIP}:${CFPORT}?encryption=none&security=tls&sni=${ARGO_DOMAIN_FINAL}&type=ws&host=${ARGO_DOMAIN_FINAL}&path=%2F${UUID}-vless#${NAME}-vless"
    MJ="{\"v\":\"2\",\"ps\":\"${NAME}-vmess\",\"add\":\"${CFIP}\",\"port\":\"${CFPORT}\",\"id\":\"${UUID}\",\"aid\":\"0\",\"scy\":\"auto\",\"net\":\"ws\",\"type\":\"none\",\"host\":\"${ARGO_DOMAIN_FINAL}\",\"path\":\"/${UUID}-vmess\",\"tls\":\"tls\",\"sni\":\"${ARGO_DOMAIN_FINAL}\",\"alpn\":\"\"}"
    M="vmess://$(echo -n "$MJ" | base64 | tr -d '\n')"
    SUB_B64="$(printf '%s\n%s' "$V" "$M" | base64 | tr -d '\n')"
else
    SUB_B64="$(echo 'no_argo_domain' | base64 | tr -d '\n')"
fi

write_nginx "$SUB_B64"
nginx -s reload && echo "[nginx] 热重载成功" || echo "[nginx] 热重载失败（继续运行）"

echo ""
echo "================================"
echo " WARP=${WARP_ENABLED}  IP=${WARP_IP}"
echo " Argo=${ARGO_DOMAIN_FINAL}"
echo " 订阅=https://${ARGO_DOMAIN_FINAL}/${SUB_PATH}"
echo "================================"

sleep infinity
