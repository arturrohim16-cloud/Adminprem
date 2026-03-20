#!/usr/bin/python3
"""
ARISG TUNNEL V4 - ADVANCED PYTHON WEBSOCKET PROXY
Perbaikan lengkap dari script asli - Python3 Compatible
Support HTTP Custom, OpenVPN WS, SSH WS, Multi-Protocol
"""

import socket
import threading
import select
import signal
import sys
import time
import getopt
import os
import argparse
from datetime import datetime

# Konfigurasi Default
LISTENING_ADDR = '0.0.0.0'
LISTENING_PORT = 8080
PASSWORD = 'arisgtunnel'  # Password default
BUFLEN = 65536  # Buffer lebih besar (64KB)
TIMEOUT = 300   # Timeout lebih panjang
DEFAULT_TARGET = '127.0.0.1:7300'  # Dropbear default

# HTTP Responses
WEBSOCKET_HANDSHAKE = b'HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: s3pPLMBiTxaQ9kYGzzhZRbK+xOo=\r\n\r\n'
CONNECT_SUCCESS = b'HTTP/1.1 200 Connection established\r\n\r\n'
FORBIDDEN = b'HTTP/1.1 403 Forbidden\r\n\r\n'
UNAUTHORIZED = b'HTTP/1.1 401 Unauthorized\r\n\r\n'
BAD_REQUEST = b'HTTP/1.1 400 Bad Request\r\n\r\n'

class AdvancedProxyServer(threading.Thread):
    def __init__(self, host, port):
        super().__init__(daemon=True)
        self.host = host
        self.port = int(port)
        self.running = True
        self.clients = []
        self.client_lock = threading.Lock()
        self.log_lock = threading.Lock()
        self.stats = {'connections': 0, 'active': 0}

    def log(self, message, level='INFO'):
        timestamp = datetime.now().strftime('%Y-%m-%d %H:%M:%S')
        with self.log_lock:
            print(f"[{timestamp}] [{level}] {message}")

    def run(self):
        self.log(f"🚀 Proxy server started: {self.host}:{self.port}", "STARTUP")
        
        sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        sock.setsockopt(socket.SOL_SOCKET, socket.SO_KEEPALIVE, 1)
        sock.settimeout(1)
        
        try:
            sock.bind((self.host, self.port))
            sock.listen(128)
            self.log(f"📡 Listening on {self.host}:{self.port}")
            
            while self.running:
                try:
                    client_sock, addr = sock.accept()
                    client_sock.settimeout(10)
                    handler = ProxyHandler(client_sock, addr, self)
                    handler.start()
                    with self.client_lock:
                        self.clients.append(handler)
                        self.stats['connections'] += 1
                        self.stats['active'] += 1
                except socket.timeout:
                    continue
                except Exception as e:
                    self.log(f"Accept error: {e}", "ERROR")
                    
        except Exception as e:
            self.log(f"Server error: {e}", "FATAL")
        finally:
            sock.close()
            self.shutdown()

    def remove_client(self, handler):
        with self.client_lock:
            if handler in self.clients:
                self.clients.remove(handler)
                self.stats['active'] -= 1

    def shutdown(self):
        self.log("🛑 Shutting down server...", "SHUTDOWN")
        self.running = False
        with self.client_lock:
            for client in self.clients[:]:
                client.close()

    def print_stats(self):
        self.log(f"Active connections: {self.stats['active']} | Total: {self.stats['connections']}")

class ProxyHandler(threading.Thread):
    def __init__(self, client_sock, addr, server):
        super().__init__(daemon=True)
        self.client = client_sock
        self.addr = addr
        self.server = server
        self.target = None
        self.client_closed = False
        self.target_closed = False
        self.buffer = b''

    def log(self, msg, level='INFO'):
        self.server.log(f"{self.addr[0]}:{self.addr[1]} - {msg}", level)

    def safe_close(self, sock, closed_flag):
        if sock and not getattr(self, closed_flag, True):
            try:
                sock.shutdown(socket.SHUT_RDWR)
                sock.close()
            except:
                pass
            setattr(self, closed_flag, True)

    def close(self):
        self.safe_close(self.client, 'client_closed')
        self.safe_close(self.target, 'target_closed')
        self.server.remove_client(self)

    def parse_header(self, data, header_name):
        """Parse HTTP header lebih aman"""
        try:
            lines = data.decode('utf-8', errors='ignore').split('\r\n')
            for line in lines:
                if line.lower().startswith(header_name.lower() + ':'):
                    return line.split(':', 1)[1].strip().lower()
        except:
            pass
        return ''

    def authenticate(self, data):
        """Autentikasi dengan X-Pass"""
        passwd = self.parse_header(data, 'X-Pass')
        return not PASSWORD or passwd == PASSWORD

    def get_target(self, data):
        """Ambil target dari X-Real-Host atau default"""
        target = self.parse_header(data, 'X-Real-Host')
        if not target:
            target = DEFAULT_TARGET
        return target

    def handle_handshake(self):
        """Handle WebSocket/CONNECT handshake"""
        initial_data = self.client.recv(BUFLEN)
        
        if not self.authenticate(initial_data):
            self.client.send(UNAUTHORIZED)
            self.log("❌ Auth failed", "AUTH")
            return False

        target_host = self.get_target(initial_data)
        
        # WebSocket atau CONNECT
        if b'Upgrade: websocket' in initial_data or b'GET /' in initial_data:
            self.client.send(WEBSOCKET_HANDSHAKE)
            self.log(f"✅ WebSocket to {target_host}", "WS")
        elif b'CONNECT' in initial_data:
            self.client.send(CONNECT_SUCCESS)
            self.log(f"✅ CONNECT to {target_host}", "CONNECT")
        else:
            self.client.send(BAD_REQUEST)
            self.log("❌ Invalid request", "PROTO")
            return False

        return target_host

    def connect_target(self, host_port):
        """Connect ke target dengan error handling"""
        try:
            host, port_str = host_port.split(':')
            port = int(port_str)
        except:
            self.log(f"❌ Invalid target: {host_port}", "TARGET")
            return False

        try:
            addr_info = socket.getaddrinfo(host, port, 0, socket.SOCK_STREAM)[0]
            self.target = socket.socket(addr_info[0], addr_info[1])
            self.target.settimeout(TIMEOUT)
            self.target.connect(addr_info[4])
            self.target_closed = False
            self.log(f"🎯 Target connected {host}:{port}")
            return True
        except Exception as e:
            self.log(f"❌ Target connect failed: {e}", "TARGET")
            return False

    def proxy_loop(self):
        """Main proxy data forwarding loop"""
        sockets = [self.client, self.target]
        
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
                    else:
                        self.client.sendall(data)
                        
            except Exception as e:
                self.log(f"❌ Proxy loop error: {e}", "PROXY")
                break

    def run(self):
        try:
            target_host = self.handle_handshake()
            if not target_host or not self.connect_target(target_host):
                return

            self.proxy_loop()
            
        except Exception as e:
            self.log(f"❌ Handler crashed: {e}", "CRASH")
        finally:
            self.close()

def parse_args():
    parser = argparse.ArgumentParser(description='ARISG Tunnel WebSocket Proxy')
    parser.add_argument('-p', '--port', type=int, default=8080, help='Proxy port')
    parser.add_argument('-b', '--bind', default='0.0.0.0', help='Bind address')
    parser.add_argument('-t', '--target', default=DEFAULT_TARGET, help='Target host:port')
    parser.add_argument('-P', '--password', default=PASSWORD, help='Auth password')
    parser.add_argument('--stats', action='store_true', help='Show stats')
    
    return parser.parse_args()

def print_banner(args):
    print("\n" + "="*70)
    print("🛡️  ARISG TUNNEL V4 - ADVANCED WEBSOCKET PROXY v2.0")
    print("="*70)
    print(f"📡 Listening:  {args.bind}:{args.port}")
    print(f"🎯 Target:     {args.target}")
    print(f"🔐 Password:   {args.password}")
    print(f"📦 Buffer:     {BUFLEN/1024}KB")
    print(f"⏱️  Timeout:   {TIMEOUT}s")
    print("="*70 + "\n")

def main():
    args = parse_args()
    
    # Global config
    global LISTENING_ADDR, LISTENING_PORT, PASSWORD, DEFAULT_TARGET
    LISTENING_ADDR = args.bind
    LISTENING_PORT = args.port
    PASSWORD = args.password
    DEFAULT_TARGET = args.target
    
    print_banner(args)
    
    server = AdvancedProxyServer(args.bind, args.port)
    server.start()
    
    # Stats loop
    try:
        while True:
            time.sleep(10)
            if args.stats:
                server.print_stats()
    except KeyboardInterrupt:
        print("\n🛑 Ctrl+C received, shutting down...")
        server.shutdown()

if __name__ == '__main__':
    main()
