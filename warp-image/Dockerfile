FROM alpine:3.20

RUN apk add --no-cache \
    bash curl wget unzip ca-certificates \
    nginx python3 gettext openssl

WORKDIR /app

# xray
RUN set -e; \
    VER=$(curl -fsSL https://api.github.com/repos/XTLS/Xray-core/releases/latest \
          | grep '"tag_name"' | head -1 | cut -d'"' -f4); \
    wget -qO /tmp/xray.zip \
      "https://github.com/XTLS/Xray-core/releases/download/${VER}/Xray-linux-64.zip"; \
    unzip -q /tmp/xray.zip -d /tmp/xray; \
    mv /tmp/xray/xray /usr/local/bin/xray; \
    chmod +x /usr/local/bin/xray; \
    rm -rf /tmp/xray /tmp/xray.zip

# cloudflared
RUN wget -qO /usr/local/bin/cloudflared \
      "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-amd64" && \
    chmod +x /usr/local/bin/cloudflared

# wireproxy
RUN set -e; \
    VER=$(curl -fsSL https://api.github.com/repos/pufferffish/wireproxy/releases/latest \
          | grep '"tag_name"' | head -1 | cut -d'"' -f4); \
    wget -qO /tmp/wireproxy.tar.gz \
      "https://github.com/pufferffish/wireproxy/releases/download/${VER}/wireproxy_linux_amd64.tar.gz"; \
    tar -xzf /tmp/wireproxy.tar.gz -C /usr/local/bin wireproxy; \
    chmod +x /usr/local/bin/wireproxy; \
    rm /tmp/wireproxy.tar.gz

# wgcf
RUN set -e; \
    VER=$(curl -fsSL https://api.github.com/repos/ViRb3/wgcf/releases/latest \
          | grep '"tag_name"' | head -1 | cut -d'"' -f4); \
    wget -qO /usr/local/bin/wgcf \
      "https://github.com/ViRb3/wgcf/releases/download/${VER}/wgcf_${VER#v}_linux_amd64"; \
    chmod +x /usr/local/bin/wgcf

COPY start.sh /app/start.sh
COPY nginx.conf.tmpl /app/nginx.conf.tmpl

RUN chmod +x /app/start.sh

EXPOSE 8001

CMD ["/app/start.sh"]
