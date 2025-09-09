#!/usr/bin/env python3

import rclpy
from rclpy.node import Node
import socket
import json
import threading
import time

class TCPHeartbeatServer(Node):
    def __init__(self):
        super().__init__('tcp_heartbeat_server')
        self.host = '0.0.0.0'
        self.port = 5001
        self.sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
        self.sock.bind((self.host, self.port))
        self.sock.listen(1)
        self.get_logger().info(f"📡 TCP Heartbeat dinleniyor: {self.host}:{self.port}")

        # Bağlantı kabulü ayrı thread'de
        threading.Thread(target=self.accept_loop, daemon=True).start()

    def accept_loop(self):
        while True:
            conn, addr = self.sock.accept()
            self.get_logger().info(f"✅ Flutter bağlandı: {addr}")
            threading.Thread(target=self.handle_client, args=(conn,), daemon=True).start()

    def handle_client(self, conn):
        try:
            while True:
                time.sleep(0.2)  # 200ms'de bir ACK gönder
                ack = json.dumps({"ack": True}).encode()
                conn.sendall(ack)
        except Exception as e:
            self.get_logger().warn(f"❌ Flutter bağlantısı kesildi: {e}")
            conn.close()

def main(args=None):
    rclpy.init(args=args)
    node = TCPHeartbeatServer()
    rclpy.spin(node)
    node.destroy_node()
    rclpy.shutdown()
