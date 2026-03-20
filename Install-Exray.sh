#!/bin/bash
# ARISG TUNNEL V4 - XRAY MANAGER INSTALLER
# Support Ubuntu 22 / 23 / 24
set -e

# --- Fungsi bantu ---
function info() {
    echo -e "\e[34m[INFO]\e[0m $1"
}
function warning() {
    echo -e "\e[33m[WARN]\e[0m $1"
}
function error() {
    echo -e "\e[31m[ERROR]\e[0m $1"
}

function cek_root() {
    if [[ "$EUID" -ne 0 ]]; then
        error "Jalankan skrip ini sebagai root (sudo)."
        exit 1
    fi
}

function install_dependencies() {
    info "Update repository dan install dependensi dasar..."
    apt update && apt upgrade -y
    apt install -y curl socat cron bash jq lsof net-tools unzip nginx certbot iptables-persistent
}

function install_xray() {
    info "Download dan install Xray-core versi terbaru..."
    XRAY_BIN="/usr/local/bin/xray"
    LATEST_VERSION=$(curl -s https://api.github.com/repos/XTLS/Xray-core/releases/latest | jq -r .tag_name)
    URL="https://github.com/XTLS/Xray-core/releases/download/${LATEST_VERSION}/Xray-linux-64.zip"

    wget -q -O /tmp/xray.zip $URL
    unzip -o /tmp/xray.zip -d /usr/local/bin/
    chmod +x $XRAY_BIN
    rm -f /tmp/xray.zip

    info "Xray core versi $LATEST_VERSION berhasil diinstall."
}

function setup_nginx() {
    info "Konfigurasi Nginx sebagai Reverse Proxy..."

    # Stop nginx dulu kalau sudah jalan
    systemctl stop nginx
    systemctl disable nginx

    # Buat file konfigurasi Nginx untuk domain dan proxy websocket
    cat > /etc/nginx/sites-available/xray.conf << EOF
server {
    listen 80;
    listen [::]:80;
    server_name ${DOMAIN};

    root /var/www/html;
    index index.html index.htm;

    location / {
        # Optionally buat halaman empty agar port 80 dapat response
        try_files \$uri \$uri/ =404;
    }

    location /vmess {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:10000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }

    location /vless {
        proxy_redirect off;
        proxy_pass http://127.0.0.1:10001;
        proxy_http_version 1.1;
        proxy_set_header Upgrade \$http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host \$host;
        proxy_set_header X-Real-IP \$remote_addr;
        proxy_set_header X-Forwarded-For \$proxy_add_x_forwarded_for;
    }
}
EOF

    ln -sf /etc/nginx/sites-available/xray.conf /etc/nginx/sites-enabled/xray.conf
    # Remove default if exists
    rm -f /etc/nginx/sites-enabled/default /etc/nginx/sites-available/default

    nginx -t
    systemctl enable nginx
    systemctl restart nginx
    info "Nginx siap sebagai reverse proxy tanpa TLS (port 80)."
}

function setup_certbot_tls() {
    info "Memasang sertifikat SSL TLS otomatis dengan certbot..."

    # Pasang sertifikat menggunakan standalone mode untuk domain yang sudah diarahkan
    certbot certonly --standalone -d ${DOMAIN} --non-interactive --agree-tos -m ${EMAIL} || {
        warning "Certbot gagal memasang SSL. Pastikan domain sudah diarahkan dan port 80 belum terpakai saat instalasi."
        return 1
    }

    # Setup renew certbot otomatis dengan cron (harus ada service certbot di sistem ubuntu)
    echo "0 3 * * * root certbot renew --quiet && systemctl restart xray nginx" >/etc/cron.d/certbot-renew

    info "SSL certificate terpasang di /etc/letsencrypt/live/${DOMAIN}/"
}

function setup_xray_config() {
    info "Membuat konfigurasi Xray dengan VMess dan VLess WebSocket + TLS + port TCP lainnya..."

    UUID_VLESS=$(uuidgen)
    UUID_VMESS=$(uuidgen)

    mkdir -p /usr/local/etc/xray

    cat > /usr/local/etc/xray/config.json << EOF
{
  "log": {
    "access": "/var/log/xray/access.log",
    "error": "/var/log/xray/error.log",
    "loglevel": "warning"
  },
  "inbounds": [
    {
      "port": 443,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${UUID_VLESS}",
            "flow": "xtls-rprx-vision"
          }
        ],
        "decryption": "none",
        "fallbacks": [
          {
            "dest": 80
          }
        ]
      },
      "streamSettings": {
        "network": "ws",
        "security": "tls",
        "tlsSettings": {
          "certificates": [
            {
              "certificateFile": "/etc/letsencrypt/live/${DOMAIN}/fullchain.pem",
              "keyFile": "/etc/letsencrypt/live/${DOMAIN}/privkey.pem"
            }
          ],
          "alpn": ["h2","http/1.1"]
        },
        "wsSettings": {
          "path": "/vless"
        }
      }
    },
    {
      "port": 10000,
      "protocol": "vmess",
      "settings": {
        "clients": [
          {
            "id": "${UUID_VMESS}",
            "alterId": 0
          }
        ]
      },
      "streamSettings": {
        "network": "ws",
        "wsSettings": {
          "path": "/vmess"
        }
      }
    },
    {
      "port": 65535,
      "protocol": "vmess",
      "settings": {
        "clients": [
          {
            "id": "${UUID_VMESS}",
            "alterId": 0
          }
        ]
      },
      "streamSettings": {
        "network": "tcp"
      }
    },
    {
      "port": 7300,
      "protocol": "vless",
      "settings": {
        "clients": [
          {
            "id": "${UUID_VLESS}"
          }
        ],
        "decryption": "none"
      },
      "streamSettings": {
        "network": "tcp"
      }
    },
    {
      "port": 7100,
      "protocol": "trojan",
      "settings": {
        "clients": [
          {
            "password": "trojanpass123"
          }
        ]
      },
      "streamSettings": {
        "network": "tcp"
      }
    }
  ],
  "outbounds": [
    {
      "protocol": "freedom",
      "settings": {}
    }
  ]
}
EOF
    info "Config Xray di /usr/local/etc/xray/config.json telah dibuat."
    echo "UUID VLESS: $UUID_VLESS"
    echo "UUID VMess: $UUID_VMESS"
    echo "Password Trojan: trojanpass123"
}

function setup_xray_service() {
    info "Membuat systemd service untuk Xray..."
    cat > /etc/systemd/system/xray.service <<EOF
[Unit]
Description=Xray Service
After=network.target nss-lookup.target

[Service]
User=nobody
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=/usr/local/bin/xray -config /usr/local/etc/xray/config.json
Restart=on-failure
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable xray
    systemctl start xray

    info "Xray service telah dijalankan."
}

function setup_firewall() {
    info "Mengatur iptables untuk membuka port..."
    iptables -F
    iptables -t nat -F

    # Izinkan port TCP yang penting
    for port in 22 80 443 65535 7300 7100; do
        iptables -A INPUT -p tcp --dport $port -j ACCEPT
        iptables -A INPUT -p udp --dport $port -j ACCEPT
    done

    # Buka established connections & loopback
    iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    iptables -A INPUT -i lo -j ACCEPT

    # Drop semua selain yang diijinkan
    iptables -P INPUT DROP

    netfilter-persistent save

    info "Firewall telah disetup dengan aturan iptables."
}

function main() {
    cek_root

    echo "Anda akan menginstall XRAY Manager pada VPS Ubuntu 22/23/24."
    read -rp "Masukkan domain yang sudah diarahkan ke VPS (ex: domainanda.com): " DOMAIN
    read -rp "Masukkan email untuk sertifikat SSL (Let's Encrypt): " EMAIL

    if [[ -z "$DOMAIN" || -z "$EMAIL" ]]; then
        error "Domain dan email tidak boleh kosong."
        exit 1
    fi

    install_dependencies
    install_xray
    setup_nginx
    setup_certbot_tls || warning "Lewati pemasangan TLS jika gagal."
    setup_xray_config
    setup_xray_service
    setup_firewall

    info ""
    echo "=== INSTALASI XRAY MANAGER SELESAI ==="
    echo "- Domain      : $DOMAIN"
    echo "- Email TLS   : $EMAIL"
    echo "- UUID VLESS  : $(jq -r '.inbounds[0].settings.clients[0].id' /usr/local/etc/xray/config.json)"
    echo "- UUID VMess  : $(jq -r '.inbounds[1].settings.clients[0].id' /usr/local/etc/xray/config.json)"
    echo "- Trojan Pass : trojanpass123"
    echo "Pastikan aplikasi client diset sesuai:"
    echo "- VLESS TLS WS: path /vless port 443"
    echo "- VMess WS     : path /vmess port 10000"
    echo "- VMess TCP   : port 65535"
    echo "- VLESS TCP   : port 7300"
    echo "- Trojan TCP  : port 7100"
    echo ""
    echo "Gunakan 'systemctl status xray' atau 'journalctl -u xray' untuk cek status."
    echo ""
    read -rp "Tekan ENTER untuk kembali ke menu..."
}

main
