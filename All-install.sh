#!/bin/bash
# ARISG TUNNEL V4 - PYTHON PROXY MULTI-SERVICES AUTO INSTALLER
# Creates 5 dedicated systemd services: Dropbear/TLS/NonTLS/Stunnel/OVPN

set -e

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
PURPLE='\033[0;35m'
CYAN='\033[0;36m'
NC='\033[0m'

banner() {
    clear
    cat << "EOF"
╔══════════════════════════════════════════════════════════════════════╗
║              🐍 PYTHON PROXY MULTI-SERVICES v4.0                    ║
║             Dropbear | TLS | NonTLS | Stunnel | OVPN                ║
╠══════════════════════════════════════════════════════════════════════╣
║  ✅ 5 Dedicated Systemd Services                                    ║
║  ✅ Optimized Python3 Proxy Scripts                                 ║
║  ✅ Auto Port Management & Firewall                                 ║
║  ✅ Ready for HTTP Custom / All Clients                             ║
╚══════════════════════════════════════════════════════════════════════╝
EOF
}

info() { echo -e "${CYAN}[INFO]${NC} $1"; }
success() { echo -e "${GREEN}[SUCCESS]${NC} $1"; }
warning() { echo -e "${YELLOW}[WARNING]${NC} $1"; }
error() { echo -e "${RED}[ERROR]${NC} $1"; }

# Cek root
[[ $EUID -ne 0 ]] && { error "Jalankan sebagai root"; exit 1; }

# Konfigurasi Services
declare -A SERVICES=(
    ["droplet"]="127.0.0.1:7300|8082|droplet|Dropbear Proxy"
    ["tls"]="127.0.0.1:443|8443|tls|TLS Proxy"
    ["nontls"]="127.0.0.1:80|8000|nontls|Non-TLS Proxy"
    ["stunnel"]="127.0.0.1:8443|8083|stunnel|Stunnel Proxy"
    ["ovpn"]="127.0.0.1:1194|8084|ovpn|OpenVPN Proxy"
)

install_python_dependencies() {
    info "Install Python3 & dependencies..."
    apt update
    apt install -y python3 python3-pip python3-venv iptables-persistent net-tools curl
    
    python3 -m venv /opt/python-proxies
    source /opt/python-proxies/bin/activate
    pip install --upgrade pip
    deactivate
    success "Python environment ready"
}

create_proxy_script() {
    local name=$1
    local target_host_port=$2
    local proxy_port=$3
    local script_type=$4
    local description=$5
    
    info "Creating $description script..."
    
    cat > "/opt/python-proxies/${name}_proxy.py" << EOF
#!/opt/python-proxies/bin/python
# ARISG TUNNEL V4 - ${description^^}
# Target: ${target_host_port} | Proxy Port: ${proxy_port}

import socket, threading, select, signal, sys, time, os
from datetime import datetime

TARGET_HOST, TARGET_PORT = "${target_host_port}".split(':')
PROXY_PORT = ${proxy_port}
PASSWORD = "${name}pass123"
BUFLEN = 131072
TIMEOUT = 900

RESPONSES = {
    'websocket': b'HTTP/1.1 101 Switching Protocols\\r\\nUpgrade: websocket\\r\\nConnection: Upgrade\\r\\n\\r\\n',
    'stunnel': b'HTTP/1.1 101 Switching Protocols_${name}\\r\\n\\r\\n',
    'connect': b'HTTP/1.1 200 Connection established\\r\\n\\r\\n',
    'ovpn': b'HTTP/1.1 200 ${name^^}_WS\\r\\n\\r\\n'
}

class ${name^^}ProxyServer(threading.Thread):
    def __init__(self):
        super().__init__(daemon=True)
        self.running = True
        self.clients = []
        
    def log(self, msg):
        print(f"[{datetime.now().strftime('%H:%M:%S')}] [{name.upper()}] {msg}")
    
    def run(self):
        self.log(f"${name^^} Proxy started on port {PROXY_PORT}")
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        sock.bind(('0.0.0.0', PROXY_PORT))
        sock.listen(500)
        
        signal.signal(signal.SIGINT, lambda s,f: setattr(self, 'running', False))
        
        while self.running:
            try:
                client, addr = sock.accept()
                handler = ${name^^}Handler(client, addr)
                handler.start()
                self.clients.append(handler)
            except:
                if not self.running:
                    break
        
        sock.close()
        self.log("Proxy stopped")

class ${name^^}Handler(threading.Thread):
    def __init__(self, client, addr):
        super().__init__(daemon=True)
        self.client = client
        self.addr = addr
        self.target = None
        
    def parse_header(self, data, header):
        try:
            lines = data.decode('utf-8', errors='ignore').split('\\r\\n')
            for line in lines:
                if line.lower().startswith(header.lower() + ':'):
                    return line.split(':', 1)[1].strip()
        except:
            pass
        return ''
    
    def authenticate(self, data):
        passwd = self.parse_header(data, 'X-Pass')
        return not PASSWORD or passwd == PASSWORD
    
    def get_target(self):
        return f"{TARGET_HOST}:{TARGET_PORT}"
    
    def run(self):
        try:
            data = self.client.recv(BUFLEN)
            if not self.authenticate(data):
                self.client.send(b'HTTP/1.1 401 Unauthorized\\r\\n\\r\\n')
                return
            
            target = self.get_target()
            
            # Protocol detection
            if b'websocket' in data:
                self.client.send(RESPONSES['websocket'])
                print(f"[${name^^}] WS {self.addr[0]} -> {target}")
            elif b'stunnel' in data.lower():
                self.client.send(RESPONSES['stunnel'])
                print(f"[${name^^}] Stunnel {self.addr[0]} -> {target}")
            elif b'connect' in data:
                self.client.send(RESPONSES['connect'])
                print(f"[${name^^}] CONNECT {self.addr[0]} -> {target}")
            else:
                self.client.send(RESPONSES['ovpn'])
                print(f"[${name^^}] OVPN {self.addr[0]} -> {target}")
            
            # Connect target
            host, port = target.split(':')
            addr_info = socket.getaddrinfo(host, int(port))[0]
            self.target = socket.socket(addr_info[0], addr_info[1])
            self.target.connect(addr_info[4])
            
            # Bi-directional proxy
            sockets = [self.client, self.target]
            while len(sockets) == 2:
                readable, _, _ = select.select(sockets, [], sockets, 1)
                for sock in readable:
                    data = sock.recv(BUFLEN)
                    if data:
                        if sock == self.client:
                            self.target.sendall(data)
                        else:
                            self.client.sendall(data)
                    else:
                        sockets.remove(sock)
            
        except Exception as e:
            print(f"[${name^^}] ERROR {self.addr[0]}: {e}")
        finally:
            if self.client:
                self.client.close()
            if self.target:
                self.target.close()

if __name__ == '__main__':
    server = ${name^^}ProxyServer()
    server.start()
EOF

    chmod +x "/opt/python-proxies/${name}_proxy.py"
}

create_systemd_service() {
    local name=$1
    local proxy_port=$2
    local service_name="${name}_proxy"
    
    info "Creating systemd service for ${name^^}..."
    
    cat > "/etc/systemd/system/${service_name}.service" << EOF
[Unit]
Description=ARISG Tunnel V4 - Python ${name^^} Proxy Mod
Documentation=https://t.me/arisgtunnel
After=network.target nss-lookup.target

[Service]
Type=simple
User=nobody
Group=nogroup
WorkingDirectory=/opt/python-proxies
CapabilityBoundingSet=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_ADMIN CAP_NET_BIND_SERVICE
NoNewPrivileges=true
ExecStart=/opt/python-proxies/bin/python /opt/python-proxies/${name}_proxy.py ${proxy_port}
Restart=always
RestartSec=3
LimitNOFILE=65535

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "${service_name}"
    systemctl start "${service_name}"
}

setup_firewall() {
    info "Configuring firewall for all proxy ports..."
    
    apt install -y iptables-persistent
    
    for service in "${!SERVICES[@]}"; do
        IFS='|' read -r _ _ proxy_port _ <<< "${SERVICES[$service]}"
        iptables -A INPUT -p tcp --dport "$proxy_port" -j ACCEPT
    done
    
    # Essential ports
    iptables -A INPUT -p tcp --dport 22 -j ACCEPT
    iptables -A INPUT -p tcp --dport 80 -j ACCEPT
    iptables -A INPUT -p tcp --dport 443 -j ACCEPT
    iptables -A INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
    iptables -A INPUT -i lo -j ACCEPT
    iptables -P INPUT DROP
    
    netfilter-persistent save
    success "Firewall configured"
}

show_status() {
    info "All services status:"
    echo ""
    for service in "${!SERVICES[@]}"; do
        service_name="${service}_proxy"
        status=$(systemctl is-active "$service_name" 2>/dev/null || echo "inactive")
        color=$([[ "$status" == "active" ]] && echo "$GREEN" || echo "$RED")
        echo -e "${color}${service^^}: ${status}${NC}"
    done
    echo ""
}

main_menu() {
    banner
    
    echo "Services yang akan dibuat:"
    for service in "${!SERVICES[@]}"; do
        IFS='|' read -r target _ proxy_port desc <<< "${SERVICES[$service]}"
        echo "  ${service^^}: ${target} → ${proxy_port} (${desc})"
    done
    echo ""
    
    read -p "Install semua services? (y/N): " confirm
    [[ $confirm != "y" && $confirm != "Y" ]] && exit 0
    
    info "Starting installation..."
    
    install_python_dependencies
    
    for service in "${!SERVICES[@]}"; do
        IFS='|' read -r target_host_port _ proxy_port script_type desc <<< "${SERVICES[$service]}"
        create_proxy_script "$service" "$target_host_port" "$proxy_port" "$script_type" "$desc"
        create_systemd_service "$service" "$proxy_port"
    done
    
    setup_firewall
    show_status
    
    success "🎉 INSTALASI 100% SELESAI!"
    echo ""
    echo "Commands penting:"
    echo "systemctl status droplet_proxy"
    echo "journalctl -u ovpn_proxy -f"
    echo "iptables -L -n -v"
    echo ""
    read -p "Tekan ENTER untuk keluar..."
}

main_menu
