#!/bin/bash
set -e

# ── 环境变量默认值 ───────────────────────────────────────────────────────────
UUID=${UUID:-$(cat /proc/sys/kernel/random/uuid 2>/dev/null || python3 -c "import uuid; print(uuid.uuid4())")}
ARGO_PORT=${ARGO_PORT:-8001}    # nginx 对外监听，也是 CF 路由端口
XRAY_PORT=8002                  # xray 内部端口，仅本机访问
SUB_PATH=${SUB_PATH:-sub}
NAME=${NAME:-SAP-WARP}
CFIP=${CFIP:-cf.877774.xyz}
CFPORT=${CFPORT:-443}
WARP_SOCKS=127.0.0.1:40000

echo "=========================================="
echo "  SAP WARP Node  |  $(date '+%Y-%m-%d %H:%M:%S')"
echo "=========================================="

# ── 1. WARP via wireproxy ────────────────────────────────────────────────────
echo "[WARP] 注册 Cloudflare WARP 账号..."
cd /tmp
wgcf register --accept-tos -f > /dev/null 2>&1
wgcf generate -f > /dev/null 2>&1

PRIV_KEY=$(awk '/PrivateKey/{print $3}' wgcf-profile.conf)
ADDR_V4=$(awk '/Address/{print $3}' wgcf-profile.conf | head -1)
ADDR_V6=$(awk '/Address/{print $3}' wgcf-profile.conf | tail -1)
PEER_PUB=$(awk '/PublicKey/{print $3}' wgcf-profile.conf)
ENDPOINT=$(awk '/Endpoint/{print $3}' wgcf-profile.conf)

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
WARP_PID=$!

# 等待 wireproxy 就绪
for i in $(seq 1 15); do
    if curl -fs --socks5 "${WARP_SOCKS}" --max-time 5 https://cloudflare.com/cdn-cgi/trace > /tmp/warp_trace.txt 2>&1; then
        WARP_IP=$(grep '^ip=' /tmp/warp_trace.txt | cut -d= -f2)
        echo "[WARP] 就绪，出口 IP: ${WARP_IP}  (Cloudflare: $(grep '^colo=' /tmp/warp_trace.txt | cut -d= -f2))"
        break
    fi
    echo "[WARP] 等待连接... (${i}/15)"
    sleep 2
done

# ── 2. Xray 配置（出站走 wireproxy SOCKS5）──────────────────────────────────
echo "[Xray] 生成配置..."
mkdir -p /tmp/xray-conf

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
      "port": 8003,
      "protocol": "vmess",
      "settings": {
        "clients": [{ "id": "${UUID}" }]
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": { "path": "/${UUID}-vmess" }
      }
    }
  ],
  "outbounds": [
    {
      "tag": "warp-out",
      "protocol": "socks",
      "settings": {
        "servers": [{ "address": "127.0.0.1", "port": 40000 }]
      }
    },
    {
      "tag": "direct",
      "protocol": "freedom"
    }
  ],
  "routing": {
    "domainStrategy": "IPIfNonMatch",
    "rules": [
      {
        "type": "field",
        "network": "tcp,udp",
        "outboundTag": "warp-out"
      }
    ]
  }
}
XCFG

# nginx 同时把 vmess 路径也代理到 8003
# 修补 nginx 模板：vmess proxy_pass 指向 8003
export UUID SUB_PATH

echo "[Xray] 启动..."
xray run -c /tmp/xray-conf/config.json &
sleep 2

# ── 3. Argo 隧道 ─────────────────────────────────────────────────────────────
echo "[Argo] 启动隧道..."
if [ -n "${ARGO_AUTH}" ] && [ -n "${ARGO_DOMAIN}" ]; then
    echo "[Argo] 使用固定隧道: ${ARGO_DOMAIN}"
    cloudflared tunnel --edge-ip-version auto --no-autoupdate \
        run --token "${ARGO_AUTH}" \
        --logfile /tmp/argo.log &
    ARGO_DOMAIN_FINAL="${ARGO_DOMAIN}"
else
    echo "[Argo] 使用临时隧道..."
    cloudflared tunnel --edge-ip-version auto --no-autoupdate \
        --url "http://127.0.0.1:${ARGO_PORT}" \
        --logfile /tmp/argo.log &

    # 等待获取临时域名
    for i in $(seq 1 20); do
        ARGO_DOMAIN_FINAL=$(grep -o 'https://[a-zA-Z0-9-]*\.trycloudflare\.com' /tmp/argo.log 2>/dev/null | head -1 | sed 's|https://||')
        [ -n "${ARGO_DOMAIN_FINAL}" ] && break
        echo "[Argo] 等待域名... (${i}/20)"
        sleep 3
    done

    if [ -z "${ARGO_DOMAIN_FINAL}" ]; then
        echo "[Argo] ⚠️ 未能获取临时域名，请改用固定隧道"
    else
        echo "[Argo] 临时域名: ${ARGO_DOMAIN_FINAL}"
    fi
fi

# ── 4. Nginx 配置 ─────────────────────────────────────────────────────────────
echo "[Nginx] 生成配置..."

# 生成 nginx 配置（把 vmess 代理到独立端口 8003）
envsubst '${UUID} ${SUB_PATH}' < /app/nginx.conf.tmpl > /tmp/nginx.conf

# vmess 走 8003 而非 8002，替换对应 block
sed -i "s|location = /${UUID}-vmess {|location = /${UUID}-vmess {\n            # vmess 独立端口|" /tmp/nginx.conf
sed -i "/# vmess 独立端口/{n; s|proxy_pass http://127.0.0.1:8002;|proxy_pass http://127.0.0.1:8003;|}" /tmp/nginx.conf

# ── 5. 生成订阅内容 ──────────────────────────────────────────────────────────
if [ -n "${ARGO_DOMAIN_FINAL}" ]; then
    VLESS_URI="vless://${UUID}@${CFIP}:${CFPORT}?encryption=none&security=tls&sni=${ARGO_DOMAIN_FINAL}&type=ws&host=${ARGO_DOMAIN_FINAL}&path=%2F${UUID}-vless#${NAME}-vless"

    VMESS_JSON=$(cat << JSON
{"v":"2","ps":"${NAME}-vmess","add":"${CFIP}","port":"${CFPORT}","id":"${UUID}","aid":"0","scy":"auto","net":"ws","type":"none","host":"${ARGO_DOMAIN_FINAL}","path":"/${UUID}-vmess","tls":"tls","sni":"${ARGO_DOMAIN_FINAL}","alpn":""}
JSON
)
    VMESS_URI="vmess://$(echo -n "${VMESS_JSON}" | base64 | tr -d '\n')"

    printf '%s\n%s' "${VLESS_URI}" "${VMESS_URI}" | base64 | tr -d '\n' > /tmp/sub.b64
    echo "[Sub] 订阅已生成: https://${ARGO_DOMAIN_FINAL}/${SUB_PATH}"
else
    echo "no subscription" | base64 > /tmp/sub.b64
    echo "[Sub] ⚠️ 域名未就绪，订阅暂不可用"
fi

# ── 6. 启动 Nginx ─────────────────────────────────────────────────────────────
echo "[Nginx] 启动，监听 :${ARGO_PORT}..."
nginx -c /tmp/nginx.conf

# ── 汇总输出 ──────────────────────────────────────────────────────────────────
echo ""
echo "=========================================="
echo "  部署完成！"
echo "  WARP 出口 IP : ${WARP_IP}"
echo "  Argo 域名    : ${ARGO_DOMAIN_FINAL}"
echo "  订阅地址     : https://${ARGO_DOMAIN_FINAL}/${SUB_PATH}"
echo "=========================================="

# 保持主进程运行，监控子进程
wait
