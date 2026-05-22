#!/bin/bash
set -e

# ── 环境变量 ─────────────────────────────────────────────────────────────────
UUID=${UUID:-$(python3 -c "import uuid; print(uuid.uuid4())")}
PORT=${PORT:-8080}
XRAY_PORT=8002
VMESS_PORT=8003
[ -z "$SUB_PATH" ] && SUB_PATH=sub
[ -z "$CFIP" ]    && CFIP=cf.877774.xyz
[ -z "$CFPORT" ]  && CFPORT=443
[ -z "$NAME" ]    && NAME=SAP-WARP
WARP_SOCKS=127.0.0.1:40000
NGINX_CONF=/tmp/nginx.conf
NGINX_PID_FILE=/tmp/nginx.pid

echo "=============================="
echo "  SAP WARP Node  $(date '+%H:%M:%S')"
echo "  PORT=${PORT}  SUB=${SUB_PATH}"
echo "=============================="

# ── 工具函数：写 nginx 配置 ───────────────────────────────────────────────────
write_nginx() {
    local sub_body="${1:-starting...}"
    rm -f "$NGINX_PID_FILE"
    cat > "$NGINX_CONF" << NGINXEOF
worker_processes 1;
daemon off;
error_log stderr warn;
pid ${NGINX_PID_FILE};
events { worker_connections 512; }
http {
    access_log off;
    client_max_body_size 0;
    server {
        listen ${PORT};
        listen 8001;

        location = / {
            default_type text/plain;
            return 200 "Hello World\n";
        }

        location = /${SUB_PATH} {
            default_type "text/plain; charset=utf-8";
            return 200 "${sub_body}";
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

# ── 1. 立即启动 nginx（让 CF 健康检查通过）──────────────────────────────────
echo "[Nginx] 初始启动 port=${PORT} 和 8001..."
write_nginx "starting"
nginx -c "$NGINX_CONF"
# nginx 以 daemon off 在前台跑，但我们在后台调用它——用子 shell
# 改用 daemon 模式启动，之后手动管理
# 注意：daemon off 不能后台运行，改用 daemon on（默认）
# 重写：不加 daemon off
rm -f "$NGINX_PID_FILE"
cat > "$NGINX_CONF" << NGINXEOF
worker_processes 1;
error_log /dev/null;
pid ${NGINX_PID_FILE};
events { worker_connections 512; }
http {
    access_log off;
    client_max_body_size 0;
    server {
        listen ${PORT};
        listen 8001;

        location = / {
            default_type text/plain;
            return 200 "Hello World\n";
        }

        location = /${SUB_PATH} {
            default_type "text/plain; charset=utf-8";
            return 200 "starting";
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

nginx -c "$NGINX_CONF"
sleep 2
echo "[Nginx] 已启动，PID=$(cat $NGINX_PID_FILE 2>/dev/null)"

# ── 2. WARP ──────────────────────────────────────────────────────────────────
echo "[WARP] 注册..."
cd /tmp
wgcf register --accept-tos -f >/dev/null 2>&1 || true
wgcf generate -f >/dev/null 2>&1 || true

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
               https://cloudflare.com/cdn-cgi/trace >/tmp/wt.txt 2>&1; then
            WARP_IP=$(grep '^ip='   /tmp/wt.txt | cut -d= -f2)
            WARP_DC=$(grep '^colo=' /tmp/wt.txt | cut -d= -f2)
            echo "[WARP] OK IP=${WARP_IP} DC=${WARP_DC}"
            WARP_ENABLED=true; break
        fi
        echo "[WARP] 等待 ${i}/15"; sleep 2
    done
    [ "$WARP_ENABLED" = "false" ] && echo "[WARP] 超时，回退直连"
else
    echo "[WARP] wgcf 失败，使用直连"
fi

# ── 3. Xray ──────────────────────────────────────────────────────────────────
echo "[Xray] 启动..."
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
  "outbounds":[{"tag":"direct","protocol":"freedom"}${EXTRA_OUT}],
  "routing":{"domainStrategy":"IPIfNonMatch",
    "rules":[{"type":"field","network":"tcp,udp","outboundTag":"${OUTBOUND_TAG}"}]}
}
XCFG

xray run -c /tmp/xray-conf/config.json &
sleep 2

# ── 4. Argo ───────────────────────────────────────────────────────────────────
echo "[Argo] 启动..."
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
        echo "[Argo] 等待 ${i}/20"; sleep 3
    done
    [ -n "${ARGO_DOMAIN_FINAL}" ] && echo "[Argo] 域名: ${ARGO_DOMAIN_FINAL}"
    [ -z "${ARGO_DOMAIN_FINAL}" ] && echo "[Argo] ⚠️ 未获取到域名"
fi

# ── 5. 生成订阅并热重载 nginx ─────────────────────────────────────────────────
if [ -n "${ARGO_DOMAIN_FINAL}" ]; then
    VLESS="vless://${UUID}@${CFIP}:${CFPORT}?encryption=none&security=tls&sni=${ARGO_DOMAIN_FINAL}&type=ws&host=${ARGO_DOMAIN_FINAL}&path=%2F${UUID}-vless#${NAME}-vless"
    VJSON="{\"v\":\"2\",\"ps\":\"${NAME}-vmess\",\"add\":\"${CFIP}\",\"port\":\"${CFPORT}\",\"id\":\"${UUID}\",\"aid\":\"0\",\"scy\":\"auto\",\"net\":\"ws\",\"type\":\"none\",\"host\":\"${ARGO_DOMAIN_FINAL}\",\"path\":\"/${UUID}-vmess\",\"tls\":\"tls\",\"sni\":\"${ARGO_DOMAIN_FINAL}\",\"alpn\":\"\"}"
    VMESS="vmess://$(echo -n "${VJSON}" | base64 | tr -d '\n')"
    SUB_B64="$(printf '%s\n%s' "${VLESS}" "${VMESS}" | base64 | tr -d '\n')"
else
    SUB_B64="$(echo 'no subscription' | base64 | tr -d '\n')"
fi

echo "[Nginx] 热重载，写入订阅..."
cat > "$NGINX_CONF" << NGINXFINAL
worker_processes 1;
error_log /dev/null;
pid ${NGINX_PID_FILE};
events { worker_connections 512; }
http {
    access_log off;
    client_max_body_size 0;
    server {
        listen ${PORT};
        listen 8001;

        location = / {
            default_type text/plain;
            return 200 "Hello World\n";
        }

        location = /${SUB_PATH} {
            default_type "text/plain; charset=utf-8";
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
NGINXFINAL

# 热重载（不中断现有连接）
nginx -c "$NGINX_CONF" -s reload
echo "[Nginx] 热重载完成"

echo ""
echo "=============================="
echo "  WARP: ${WARP_ENABLED}  IP: ${WARP_IP:-direct}"
echo "  Argo: ${ARGO_DOMAIN_FINAL}"
echo "  订阅: https://${ARGO_DOMAIN_FINAL}/${SUB_PATH}"
echo "=============================="

# 保持容器运行
wait
