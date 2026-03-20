#!/usr/bin/python3
"""
ARISG TUNNEL V4 - MEGA WEBSOCKET PROXY v4.0
Perbaikan lengkap script #3 - Python3 Enterprise Edition
Stunnel WS, SSH WS, OpenVPN WS, HTTP Custom Ultimate
"""

import socket
import threading
import select
import signal
import sys
import time
import argparse
import os
import json
import psutil
from datetime import datetime, timedelta
from collections import defaultdict
import logging
from typing import Optional, Tuple

# Konfigurasi Enterprise
LISTENING_ADDR = '0.0.0.0'  # Fixed dari 127.0.0.1 → 0.0.0.0
LISTENING_PORT = 700        # Default dari script asli
PASSWORD = 'mega_tunnel_v4'  # Password kuat default
BUFLEN = 262144             # 256KB buffer ultra cepat
TIMEOUT = 900               # 15 menit timeout
MAX_CONCURRENT = 5000
STATS_INTERVAL = 5
DEFAULT_TARGET = '127.0.0.1:109'

# Professional HTTP Responses
STUNNEL_HANDSHAKE = b'HTTP/1.1 101 Switching Protocols_Stunnel\r\n\r\n'
WEBSOCKET_HANDSHAKE = b'HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n\r\n'
HELLO_WORLD = b'HTTP/1.1 200 Hello_World!\r\nContent-length: 0\r\n\r\n'
CONNECT_ESTABLISHED = b'HTTP/1.1 200 Connection established\r\n\r\n'

ERROR_CODES = {
    400: b'HTTP/1.1 400 Bad Request\r\n\r\n',
    401: b'HTTP/1.1 401 Unauthorized\r\nX-Error: Invalid Password\r\n\r\n',
    403: b'HTTP/1.1 403 Forbidden\r\nX-Error: Access Denied\r\n\r\n',
    408: b'HTTP/1.1 408 Request Timeout\r\n\r\n',
    429: b'HTTP/1.1 429 Too Many Requests\r\n\r\n',
    500: b'HTTP/1.1 500 Internal Server Error\r\n\r\n'
}

class MegaProxyServer:
    def __init__(self, host: str, port: int):
        self.host = host
        self.port = port
        self.running = True
        self.clients: dict = {}
        self.client_lock = threading.RLock()
        self.stats_lock = threading.RLock()
        self.rate_limit = defaultdict(int)
        
        # Advanced Stats
        self.stats = {
            'start_time': time.time(),
            'total_connections': 0,
            'active_connections': 0,
            'total_bytes_in': 0,
            'total_bytes_out': 0,
            'peak_connections': 0,
            'errors': 0,
            'uptime': 0
        }
        
        self.setup_professional_logging()
        self.register_signals()
        self.health_thread = threading.Thread(target=self.health_monitor, daemon=True)
        self.stats_thread = threading.Thread(target=self.stats_reporter, daemon=True)

    def setup_professional_logging(self):
        """Logging profesional dengan file rotation"""
        log_dir = '/var/log/mega_proxy'
        os.makedirs(log_dir, exist_ok=True)
        
        logging.basicConfig(
            level=logging.INFO,
            format='%(asctime)s [%(levelname)8s] %(message)s',
            handlers=[
                logging.handlers.RotatingFileHandler(
                    f'{log_dir}/mega_proxy.log', 
                    maxBytes=10*1024*1024, 
                    backupCount=5
                ),
                logging.StreamHandler()
            ]
        )
        self.logger = logging.getLogger('MegaProxy')

    def register_signals(self):
        """Graceful shutdown handling"""
        for sig in (signal.SIGINT, signal.SIGTERM, signal.SIGHUP):
            signal.signal(sig, self.shutdown_signal)

    def log(self, message: str, level: str = 'INFO'):
        client_info = f"[{self.get_client_context()}]" if hasattr(self, 'current_client') else ""
        self.logger.log(getattr(logging, level), f"{client_info} {message}")

    def get_client_context(self) -> str:
        """Context untuk client saat ini"""
        if hasattr(self, 'current_client'):
            return f"ID:{self.current_client['id']:05d} {self.current_client['ip']}"
        return "SERVER"

    def banner(self):
        """Professional startup banner"""
        uptime = time.time() - self.stats['start_time']
        cpu = psutil.cpu_percent()
        mem = psutil.virtual_memory().percent
        
        banner = f"""
╔══════════════════════════════════════════════════════════════════════╗
║                    🚀 MEGA PROXY v4.0 - ENTERPRISE EDITION           ║
╠══════════════════════════════════════════════════════════════════════╣
║ 📡 Server          : {self.host}:{self.port}                         ║
║ 🎯 Default Target  : {DEFAULT_TARGET}                                ║
║ 🔐 Auth Password   : {PASSWORD}                                      ║
║ ⚡ Buffer           : {BUFLEN/1024/1024:.1f}MB                       ║
║ ⏱️  Timeout         : {TIMEOUT}s                                    ║
║ 👥 Max Connections  : {MAX_CONCURRENT}                               ║
║ 💾 CPU Usage        : {cpu:.1f}% | MEM: {mem:.1f}%                  ║
║ 🕐 Uptime           : {uptime/3600:.1f}h                            ║
╚══════════════════════════════════════════════════════════════════════╝
        """
        self.log(banner.strip(), 'INFO')

    def rate_limit_check(self, client_ip: str) -> bool:
        """Rate limiting per IP"""
        now = time.time()
        self.rate_limit[client_ip] = self.rate_limit.get(client_ip, 0) + 1
        
        # Reset setiap 60 detik
        if now - self.rate_limit.get(f"{client_ip}_time", 0) > 60:
            self.rate_limit[client_ip] = 1
            self.rate_limit[f"{client_ip}_time"] = now
        
        return self.rate_limit[client_ip] <= 100  # Max 100 conn/min/IP

    def start(self):
        self.banner()
        self.health_thread.start()
        self.stats_thread.start()
        
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
        sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_SNDBUF, BUFLEN * 2)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, BUFLEN * 2)
        sock.settimeout(0.5)
        
        try:
            sock.bind((self.host, self.port))
            sock.listen(MAX_CONCURRENT)
            self.log(f"✅ Ultra proxy listening on {self.host}:{self.port}")
            
            while self.running:
                try:
                    client_sock, addr = sock.accept()
                    if self.rate_limit_check(addr[0]):
                        client_thread = threading.Thread(
                            target=self.handle_client, 
                            args=(client_sock, addr),
                            daemon=True
                        )
                        client_thread.start()
                    else:
                        client_sock.send(ERROR_CODES[429])
                        client_sock.close()
                        
                except socket.timeout:
                    continue
                except Exception as e:
                    self.log(f"Accept error: {e}", 'ERROR')
                    
        except Exception as e:
            self.log(f"Fatal bind error: {e}", 'CRITICAL')
        finally:
            sock.close()
            self.shutdown()

    def handle_client(self, client_sock, addr):
        """Advanced client handler dengan context"""
        self.current_client = {'ip': f"{addr[0]}:{addr[1]}", 'id': self.stats['total_connections'] + 1}
        
        handler = MegaClientHandler(client_sock, addr, self)
        try:
            handler.process()
        except Exception as e:
            self.log(f"Client handler crashed: {e}", 'ERROR')
        finally:
            self.current_client = None
            with self.client_lock:
                if 'active_connections' in self.stats:
                    self.stats['active_connections'] = max(0, self.stats['active_connections'] - 1)

    def health_monitor(self):
        """System health monitoring"""
        while self.running:
            try:
                cpu = psutil.cpu_percent(interval=1)
                mem = psutil.virtual_memory().percent
                if cpu > 90 or mem > 90:
                    self.log(f"⚠️  High resource usage - CPU:{cpu:.1f}% MEM:{mem:.1f}%", 'WARNING')
                time.sleep(30)
            except:
                pass

    def stats_reporter(self):
        """Real-time statistics"""
        while self.running:
            time.sleep(STATS_INTERVAL)
            with self.stats_lock:
                uptime = time.time() - self.stats['start_time']
                self.log(f"📊 Active:{self.stats['active_connections']} Total:{self.stats['total_connections']} "
                        f"Peak:{self.stats['peak_connections']} Uptime:{uptime/3600:.1f}h", 'STATS')

    def shutdown_signal(self, signum, frame):
        self.log(f"Shutdown signal {signum} received", 'WARNING')
        self.running = False

    def shutdown(self):
        self.log("🔴 Graceful shutdown initiated", 'INFO')
        self.running = False
        time.sleep(2)
        self.log("✅ Mega proxy stopped", 'INFO')

class MegaClientHandler:
    def __init__(self, client_sock, addr, server):
        self.client = client_sock
        self.addr = addr
        self.server = server
        self.target = None
        self.start_time = time.time()

    def log(self, msg: str, level: str = 'INFO'):
        duration = time.time() - self.start_time
        self.server.log(f"{self.addr[0]}:{self.addr[1]} [{duration:.1f}s] {msg}", level)

    def parse_request(self, data: bytes) -> Tuple[Optional[str], bool]:
        """Parse HTTP request dengan AI-level accuracy"""
        try:
            lines = data.decode('utf-8', errors='ignore').split('\r\n')
            headers = {}
            
            for line in lines[1:]:  # Skip first line
                if ':' in line:
                    key, value = line.split(':', 1)
                    headers[key.strip().lower()] = value.strip()
            
            # Auth check
            passwd = headers.get('x-pass', '')
            if PASSWORD and passwd != PASSWORD:
                return None, False
            
            target = headers.get('x-real-host', DEFAULT_TARGET)
            return target, True
            
        except Exception:
            return None, False

    def send_response(self, response: bytes):
        """Safe response sending"""
        try:
            self.client.sendall(response)
        except:
            pass

    def connect_target(self, target_host: str) -> bool:
        """Advanced target connection dengan retry"""
        for attempt in range(3):
            try:
                host, port_str = target_host.split(':')
                port = int(port_str)
            except:
                self.log(f"❌ Invalid target format: {target_host}", 'ERROR')
                return False

            try:
                addr_info = socket.getaddrinfo(host, port, 0, socket.SOCK_STREAM, 0)[0]
                self.target = socket.socket(addr_info[0], addr_info[1])
                self.target.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
                self.target.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
                self.target.settimeout(TIMEOUT)
                self.target.connect(addr_info[4])
                
                self.log(f"✅ Target connected {host}:{port} (attempt {attempt+1})")
                return True
                
            except Exception as e:
                self.log(f"❌ Target connect failed (attempt {attempt+1}): {e}", 'WARN')
                time.sleep(0.1)
        
        return False

    def process(self):
        """Main processing pipeline"""
        try:
            # Read initial request
            data = self.client.recv(BUFLEN)
            if not data:
                return

            target_host, auth_ok = self.parse_request(data)
            if not auth_ok or not target_host:
                self.send_response(ERROR_CODES[401])
                self.log("❌ Auth/Target failed", 'AUTH')
                return

            # Determine response type
            if b'Stunnel' in data:
                self.send_response(STUNNEL_HANDSHAKE)
                self.log("🔐 Stunnel WS", 'STUNNEL')
            elif b'websocket' in data.lower():
                self.send_response(WEBSOCKET_HANDSHAKE)
                self.log("🌐 WebSocket", 'WS')
            elif b'CONNECT' in data:
                self.send_response(CONNECT_ESTABLISHED)
                self.log("🔗 CONNECT", 'CONNECT')
            else:
                self.send_response(HELLO_WORLD)
                self.log("🌍 Hello World", 'HELLO')

            # Connect target
            if not self.connect_target(target_host):
                return

            # Ultra-fast bidirectional proxy
            self.proxy_loop()

        except Exception as e:
            self.log(f"❌ Processing error: {e}", 'ERROR')

    def proxy_loop(self):
        """MEGA fast proxy loop dengan stats"""
        sockets = [self.client, self.target]
        bytes_in, bytes_out = 0, 0
        
        while len(sockets) == 2:
            try:
                readable, _, _ = select.select(sockets, [], sockets, 1)
                
                for sock in readable:
                    data = sock.recv(BUFLEN)
                    if not data:
                        sockets.remove(sock)
                        continue
                    
                    if sock == self.client:
                        self.target.sendall(data)
                        bytes_in += len(data)
                    else:
                        self.client.sendall(data)
                        bytes_out += len(data)
                        
            except Exception:
                break
        
        duration = time.time() - self.start_time
        speed_in = bytes_in / duration / 1024
        speed_out = bytes_out / duration / 1024
        self.log(f"📈 {bytes_in/1024/1024:.1f}MB↓ {bytes_out/1024/1024:.1f}MB↑ "
                f"{speed_in:.1f}KB/s↗ {speed_out:.1f}KB/s↖ [{duration:.1f}s]", 'STATS')

def main():
    parser = argparse.ArgumentParser(
        description='ARISG Mega WebSocket Proxy v4.0 - Enterprise Edition',
        formatter_class=argparse.RawDescriptionHelpFormatter,
        epilog="""
Examples:
  python3 mega_proxy.py                    # Default port 700
  python3 mega_proxy.py -p 8080            # Custom port
  python3 mega_proxy.py -p 8080 -t 127.0.0.1:7300  # Dropbear
  python3 mega_proxy.py -P mypass -p 2099  # Custom pass
        """
    )
    
    parser.add_argument('-p', '--port', type=int, default=700, help='Proxy port')
    parser.add_argument('-b', '--bind', default='0.0.0.0', help='Bind address')
    parser.add_argument('-t', '--target', default=DEFAULT_TARGET, help='Default target')
    parser.add_argument('-P', '--password', default=PASSWORD, help='Auth password')
    parser.add_argument('--cpu-limit', type=float, default=90.0, help='CPU limit %')
    
    global LISTENING_PORT, LISTENING_ADDR, PASSWORD, DEFAULT_TARGET
    args = parser.parse_args()
    
    LISTENING_PORT = args.port
    LISTENING_ADDR = args.bind
    PASSWORD = args.password
    DEFAULT_TARGET = args.target
    
    server = MegaProxyServer(args.bind, args.port)
    server.start()

if __name__ == '__main__':
    main()
