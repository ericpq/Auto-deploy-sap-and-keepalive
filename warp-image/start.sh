#!/bin/bash
set -e

# ── 环境变量 ─────────────────────────────────────────────────────────────────
UUID=${UUID:-$(python3 -c "import uuid; print(uuid.uuid4())")}
PORT=${PORT:-8080}          # CF 平台注入，nginx 必须监听这个
XRAY_PORT=8002
VMESS_PORT=8003
# 空字符串保护：secrets 为空时用默认值
[ -z "$SUB_PATH" ] && SUB_PATH=sub
[ -z "$CFIP" ]    && CFIP=cf.877774.xyz
[ -z "$CFPORT" ]  && CFPORT=443
[ -z "$NAME" ]    && NAME=SAP-WARP
WARP_SOCKS=127.0.0.1:40000

echo "=========================================="
echo "  SAP WARP Node  $(date '+%Y-%m-%d %H:%M:%S')"
echo "  PORT=${PORT}  SUB_PATH=${SUB_PATH}"
echo "=========================================="

# ── 1. 先启动 nginx（最简版，让 CF 健康检查通过）──────────────────────────
mkdir -p /tmp/nginx-run
cat > /tmp/nginx.conf << NGINX_EARLY
worker_processes 1;
daemon off;
error_log /dev/null;
pid /tmp/nginx.pid;
events { worker_connections 256; }
http {
    access_log off;
    server {
        listen ${PORT};
        location / { default_type text/plain; return 200 "starting...\n"; }
    }
}
NGINX_EARLY

nginx -c /tmp/nginx.conf &
NGINX_PID=$!
echo "[Nginx] 临时监听 ${PORT}，等待初始化..."
sleep 2

# ── 2. WARP via wireproxy ────────────────────────────────────────────────────
echo "[WARP] 注册 Cloudflare WARP..."
cd /tmp
wgcf register --accept-tos -f > /dev/null 2>&1 || true
wgcf generate -f > /dev/null 2>&1 || true

WARP_ENABLED=false
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
               https://cloudflare.com/cdn-cgi/trace > /tmp/wt.txt 2>&1; then
            WARP_IP=$(grep '^ip='   /tmp/wt.txt | cut -d= -f2)
            WARP_DC=$(grep '^colo=' /tmp/wt.txt | cut -d= -f2)
            echo "[WARP] OK  IP=${WARP_IP}  DC=${WARP_DC}"
            WARP_ENABLED=true; break
        fi
        echo "[WARP] 等待... ${i}/15"; sleep 2
    done
    [ "$WARP_ENABLED" = "false" ] && echo "[WARP] 超时，回退直连"
else
    echo "[WARP] wgcf 失败，使用直连"
fi

# ── 3. Xray ──────────────────────────────────────────────────────────────────
echo "[Xray] 生成配置..."
mkdir -p /tmp/xray-conf

if [ "$WARP_ENABLED" = "true" ]; then
    OUTBOUND_TAG=warp-out
    EXTRA_OUT=', {"tag":"warp-out","protocol":"socks","settings":{"servers":[{"address":"127.0.0.1","port":40000}]}}'
else
    OUTBOUND_TAG=direct
    EXTRA_OUT=''
fi

cat > /tmp/xray-conf/config.json << XCFG
{
  "log":{"loglevel":"warning"},
  "inbounds":[
    {"tag":"vless-in","port":${XRAY_PORT},"protocol":"vless",
     "settings":{"clients":[{"id":"${UUID}","flow":""}],"decryption":"none"},
     "streamSettings":{"network":"ws","wsSettings":{"path":"/${UUID}-vless"}}},
    {"tag":"vmess-in","port":${VMESS_PORT},"protocol":"vmess",
     "settings":{"clients":[{"id":"${UUID}"}]},
     "streamSettings":{"network":"ws","wsSettings":{"path":"/${UUID}-vmess"}}}
  ],
  "outbounds":[
    {"tag":"direct","protocol":"freedom"}
    ${EXTRA_OUT}
  ],
  "routing":{"domainStrategy":"IPIfNonMatch",
    "rules":[{"type":"field","network":"tcp,udp","outboundTag":"${OUTBOUND_TAG}"}]}
}
XCFG

xray run -c /tmp/xray-conf/config.json &
sleep 2

# ── 4. Argo 隧道 ──────────────────────────────────────────────────────────────
echo "[Argo] 启动隧道..."
if [ -n "${ARGO_AUTH}" ] && [ -n "${ARGO_DOMAIN}" ]; then
    echo "[Argo] 固定隧道: ${ARGO_DOMAIN}"
    cloudflared tunnel --edge-ip-version auto --no-autoupdate \
        run --token "${ARGO_AUTH}" --logfile /tmp/argo.log &
    ARGO_DOMAIN_FINAL="${ARGO_DOMAIN}"
else
    cloudflared tunnel --edge-ip-version auto --no-autoupdate \
        --url "http://127.0.0.1:${PORT}" --logfile /tmp/argo.log &
    for i in $(seq 1 20); do
        ARGO_DOMAIN_FINAL=$(grep -o 'https://[a-zA-Z0-9-]*\.trycloudflare\.com' \
            /tmp/argo.log 2>/dev/null | head -1 | sed 's|https://||')
        [ -n "${ARGO_DOMAIN_FINAL}" ] && break
        echo "[Argo] 等待... ${i}/20"; sleep 3
    done
    [ -n "${ARGO_DOMAIN_FINAL}" ] && echo "[Argo] 临时域名: ${ARGO_DOMAIN_FINAL}"
    [ -z "${ARGO_DOMAIN_FINAL}" ] && echo "[Argo] ⚠️ 未获取到域名"
fi

# ── 5. 生成订阅内容 ──────────────────────────────────────────────────────────
if [ -n "${ARGO_DOMAIN_FINAL}" ]; then
    VLESS="vless://${UUID}@${CFIP}:${CFPORT}?encryption=none&security=tls&sni=${ARGO_DOMAIN_FINAL}&type=ws&host=${ARGO_DOMAIN_FINAL}&path=%2F${UUID}-vless#${NAME}-vless"
    VJSON="{\"v\":\"2\",\"ps\":\"${NAME}-vmess\",\"add\":\"${CFIP}\",\"port\":\"${CFPORT}\",\"id\":\"${UUID}\",\"aid\":\"0\",\"scy\":\"auto\",\"net\":\"ws\",\"type\":\"none\",\"host\":\"${ARGO_DOMAIN_FINAL}\",\"path\":\"/${UUID}-vmess\",\"tls\":\"tls\",\"sni\":\"${ARGO_DOMAIN_FINAL}\",\"alpn\":\"\"}"
    VMESS="vmess://$(echo -n "${VJSON}" | base64 | tr -d '\n')"
    SUB_B64="$(printf '%s\n%s' "${VLESS}" "${VMESS}" | base64 | tr -d '\n')"
    echo "[Sub] 订阅已生成"
else
    SUB_B64="$(echo 'no subscription' | base64 | tr -d '\n')"
fi

# ── 6. 重新生成完整 nginx 配置（含订阅内容内嵌）───────────────────────────
echo "[Nginx] 重新加载完整配置..."
kill $NGINX_PID 2>/dev/null || true
sleep 1

cat > /tmp/nginx.conf << NGINX_FULL
worker_processes 1;
daemon off;
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
            default_type text/plain;
            add_header Content-Type "text/plain; charset=utf-8";
            return 200 "${SUB_B64}";
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
NGINX_FULL

echo ""
echo "=========================================="
echo "  WARP: ${WARP_ENABLED}  出口IP: ${WARP_IP:-direct}"
echo "  Argo: ${ARGO_DOMAIN_FINAL}"
echo "  订阅: https://${ARGO_DOMAIN_FINAL}/${SUB_PATH}"
echo "=========================================="

exec nginx -c /tmp/nginx.conf
