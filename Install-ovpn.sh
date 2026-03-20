#!/usr/bin/python3
"""
ARISG TUNNEL V4 - ULTRA WEBSOCKET PROXY v3.0
Perbaikan lengkap script #2 - Python3 + Fitur Canggih
Support OpenVPN WS, SSH WS, HTTP Custom, Multi-Target
"""

import socket
import threading
import select
import signal
import sys
import time
import argparse
import os
from datetime import datetime
import logging
from concurrent.futures import ThreadPoolExecutor

# Konfigurasi Canggih
LISTENING_ADDR = '0.0.0.0'
LISTENING_PORT = 2099  # Default dari script asli
PASSWORD = 'arisgtunnelv4'  # Password default
BUFLEN = 131072  # 128KB buffer super cepat
TIMEOUT = 600    # 10 menit timeout
MAX_CONNECTIONS = 1000
DEFAULT_TARGET = '127.0.0.1:1194'  # OpenVPN default

# HTTP Responses Profesional
WEBSOCKET_HANDSHAKE = b'HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\nSec-WebSocket-Protocol: arisg-tunnel\r\n\r\n'
OPENVPN_HANDSHAKE = b'HTTP/1.1 200 Websocket_openvpn\r\nContent-length: 0\r\nConnection: keep-alive\r\n\r\n'
CONNECT_SUCCESS = b'HTTP/1.1 200 Connection established\r\n\r\n'
ERROR_RESPONSES = {
    400: b'HTTP/1.1 400 Bad Request\r\n\r\n',
    401: b'HTTP/1.1 401 Unauthorized\r\n\r\n', 
    403: b'HTTP/1.1 403 Forbidden\r\n\r\n',
    408: b'HTTP/1.1 408 Request Timeout\r\n\r\n'
}

class UltraProxyServer:
    def __init__(self, host, port):
        self.host = host
        self.port = int(port)
        self.running = True
        self.clients = {}
        self.client_lock = threading.Lock()
        self.stats_lock = threading.Lock()
        self.stats = {
            'total_conn': 0,
            'active_conn': 0,
            'bytes_in': 0,
            'bytes_out': 0,
            'start_time': time.time()
        }
        self.executor = ThreadPoolExecutor(max_workers=200)
        self.setup_logging()
        signal.signal(signal.SIGINT, self.shutdown)
        signal.signal(signal.SIGTERM, self.shutdown)

    def setup_logging(self):
        logging.basicConfig(
            level=logging.INFO,
            format='%(asctime)s [%(levelname)s] %(message)s',
            handlers=[
                logging.FileHandler('/var/log/websocket_proxy.log'),
                logging.StreamHandler()
            ]
        )
        self.logger = logging.getLogger('UltraProxy')

    def log(self, msg, level='INFO'):
        self.logger.log(getattr(logging, level), msg)

    def banner(self):
        uptime = time.time() - self.stats['start_time']
        self.log(f"""
╔══════════════════════════════════════════════════════════════╗
║           🚀 ARISG TUNNEL V4 - ULTRA PROXY v3.0              ║
╠══════════════════════════════════════════════════════════════╣
║ 📡 Listening     : {self.host}:{self.port}                   ║
║ 🎯 Default Target: {DEFAULT_TARGET}                          ║
║ 🔐 Password      : {PASSWORD}                                ║
║ 📦 Buffer Size   : {BUFLEN/1024:.0f}KB                       ║
║ ⏱️  Timeout      : {TIMEOUT}s                               ║
║ 👥 Active Conn   : {self.stats['active_conn']}               ║
║ 📊 Total Conn    : {self.stats['total_conn']}                ║
║ 🕐 Uptime        : {uptime:.0f}s                            ║
╚══════════════════════════════════════════════════════════════╝
        """, 'INFO')

    def start(self):
        self.banner()
        
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
        sock.setsockopt(socket.IPPROTO_TCP, socket.TCP_NODELAY, 1)
        sock.settimeout(1)
        
        try:
            sock.bind((self.host, self.port))
            sock.listen(MAX_CONNECTIONS)
            self.log(f"✅ Server listening on {self.host}:{self.port}")
            
            while self.running:
                try:
                    client_sock, addr = sock.accept()
                    self.executor.submit(self.handle_client, client_sock, addr)
                except socket.timeout:
                    continue
                except Exception as e:
                    self.log(f"Accept error: {e}", 'ERROR')
                    
        except Exception as e:
            self.log(f"Fatal server error: {e}", 'CRITICAL')
        finally:
            sock.close()
            self.shutdown()

    def handle_client(self, client_sock, addr):
        """Handle single client connection"""
        handler = ClientHandler(client_sock, addr, self)
        with self.client_lock:
            self.stats['total_conn'] += 1
            self.stats['active_conn'] += 1
            handler.client_id = self.stats['total_conn']
        
        try:
            handler.run()
        finally:
            with self.client_lock:
                self.stats['active_conn'] -= 1
            handler.cleanup()

    def shutdown(self, signum=None, frame=None):
        self.log("🛑 Shutdown initiated", 'WARNING')
        self.running = False
        self.executor.shutdown(wait=True)
        self.log("✅ Server stopped gracefully", 'INFO')

class ClientHandler:
    def __init__(self, client_sock, addr, server):
        self.client = client_sock
        self.addr = addr
        self.server = server
        self.target = None
        self.client_closed = False
        self.target_closed = False
        self.client_id = 0
        self.start_time = time.time()

    def log(self, msg, level='INFO'):
        duration = time.time() - self.start_time
        self.server.log(f"ID:{self.client_id:04d} {self.addr[0]}:{self.addr[1]} [{duration:.1f}s] {msg}", level)

    def cleanup(self):
        """Safe cleanup resources"""
        if self.client and not self.client_closed:
            try:
                self.client.shutdown(socket.SHUT_RDWR)
                self.client.close()
            except:
                pass
        if self.target and not self.target_closed:
            try:
                self.target.shutdown(socket.SHUT_RDWR)
                self.target.close()
            except:
                pass

    def parse_header(self, data, header):
        """Parse header dengan case-insensitive"""
        try:
            lines = data.decode('utf-8', errors='ignore').split('\r\n')
            for line in lines:
                parts = line.split(':', 1)
                if len(parts) == 2 and parts[0].lower() == header.lower():
                    return parts[1].strip()
        except:
            pass
        return ''

    def authenticate(self, data):
        passwd = self.parse_header(data, 'X-Pass')
        return not PASSWORD or passwd == PASSWORD

    def get_target_host(self, data):
        target = self.parse_header(data, 'X-Real-Host')
        if not target:
            target = DEFAULT_TARGET
        return target

    def send_response(self, response):
        try:
            self.client.sendall(response)
        except:
            pass

    def handle_request(self):
        """Handle initial HTTP request"""
        try:
            data = self.client.recv(BUFLEN)
            if not data:
                return False

            # Authentication
            if not self.authenticate(data):
                self.send_response(ERROR_RESPONSES[401])
                self.log("❌ Authentication failed", "AUTH")
                return False

            target_host = self.get_target_host(data)
            
            # WebSocket handshake
            if b'Upgrade: websocket' in data or b'GET /' in data:
                self.send_response(WEBSOCKET_HANDSHAKE)
                self.log(f"✅ WebSocket → {target_host}", "WS")
            # OpenVPN/CONNECT
            elif b'CONNECT' in data:
                self.send_response(CONNECT_SUCCESS)
                self.log(f"✅ CONNECT → {target_host}", "CONNECT")
            # OpenVPN WS specific
            elif b'websocket_openvpn' in data:
                self.send_response(OPENVPN_HANDSHAKE)
                self.log(f"✅ OpenVPN WS → {target_host}", "OVPN")
            else:
                self.send_response(ERROR_RESPONSES[400])
                self.log("❌ Unknown protocol", "PROTO")
                return False

            return self.connect_target(target_host)
            
        except Exception as e:
            self.log(f"❌ Request handling error: {e}", "REQUEST")
            return False

    def connect_target(self, host_port):
        """Connect ke target dengan DNS resolution"""
        try:
            if ':' in host_port:
                host, port = host_port.split(':', 1)
                port = int(port)
            else:
                host = host_port
                port = 443 if 'CONNECT' in self.client.recv(1024).decode(errors='ignore') else LISTENING_PORT

            addr_info = socket.getaddrinfo(host, port, 0, socket.SOCK_STREAM, 0)[0]
            self.target = socket.socket(addr_info[0], addr_info[1])
            self.target.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
            self.target.settimeout(TIMEOUT)
            self.target.connect(addr_info[4])
            self.target_closed = False
            self.log(f"🎯 Target OK {host}:{port}")
            return True
        except Exception as e:
            self.log(f"❌ Target connect failed: {e}", "TARGET")
            return False

    def proxy_data(self):
        """Ultra fast bidirectional proxying"""
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
        
        self.log(f"📊 {bytes_in/1024:.1f}KB in ↔ {bytes_out/1024:.1f}KB out", "STATS")

    def run(self):
        """Main handler execution"""
        try:
            if not self.handle_request():
                return
            
            self.proxy_data()
            
        except Exception as e:
            self.log(f"❌ Fatal handler error: {e}", "FATAL")
        finally:
            self.cleanup()

def main():
    parser = argparse.ArgumentParser(description='ARISG Ultra WebSocket Proxy v3.0')
    parser.add_argument('-p', '--port', type=int, default=2099, help='Proxy port (default: 2099)')
    parser.add_argument('-b', '--bind', default='0.0.0.0', help='Bind address')
    parser.add_argument('-t', '--target', default=DEFAULT_TARGET, help='Default target host:port')
    parser.add_argument('-P', '--password', default=PASSWORD, help='Auth password')
    parser.add_argument('--log-level', choices=['DEBUG', 'INFO', 'WARNING'], default='INFO')
    
    global LISTENING_PORT, LISTENING_ADDR, PASSWORD, DEFAULT_TARGET
    args = parser.parse_args()
    
    LISTENING_PORT = args.port
    LISTENING_ADDR = args.bind
    PASSWORD = args.password
    DEFAULT_TARGET = args.target
    
    server = UltraProxyServer(args.bind, args.port)
    server.start()

if __name__ == '__main__':
    main()
