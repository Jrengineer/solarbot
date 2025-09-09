#!/usr/bin/env python3
"""
UDP üzerinden joystick ve fırça verilerini alıp, Delta PLC'ye Modbus TCP ile gönderen ROS2 Node.
Bağlantı koptuğunda tekrar bağlantı bekler, terminalde bağlantı durumunu açıkça yazar.
"""

import rclpy
from rclpy.node import Node
import time
import socket
import json
from pymodbus.client import ModbusTcpClient

class UDPJoystickListener(Node):
    def __init__(self):
        super().__init__('udp_listener_node')
        self.plc_ip = '192.168.1.5'
        self.plc_port = 502
        self.modbus_timeout = 1.0

        self.udp_ip = "0.0.0.0"
        self.udp_port = 8888

        self.is_connected = True
        self.timeout_counter = 0

        self.last_forward = 0
        self.last_turn = 0
        self.last_brush1 = None
        self.last_brush2 = None

        self.sock = None
        self.listener_active = False

        self.client = None
        self.ensure_modbus_client()

        self.create_udp_socket()
        self.timer = self.create_timer(0.05, self.main_loop)  # 20Hz

    def ensure_modbus_client(self):
        if self.client is None or not self.client.connected:
            try:
                if self.client is not None:
                    self.client.close()
                self.client = ModbusTcpClient(self.plc_ip, port=self.plc_port, timeout=self.modbus_timeout)
                connected = self.client.connect()
                if connected:
                    self.get_logger().info("Modbus TCP bağlantısı başarılı!")
                else:
                    self.get_logger().warn("Modbus TCP bağlantısı kurulamadı, tekrar denenecek...")
            except Exception as e:
                self.get_logger().error(f"Modbus TCP bağlantı hatası: {e}")

    def create_udp_socket(self):
        if self.sock:
            try:
                self.sock.close()
            except Exception:
                pass

        self.sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
        self.sock.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        try:
            self.sock.bind((self.udp_ip, self.udp_port))
            self.sock.settimeout(0.01)
            print(f"📡 UDP bağlantısı bekleniyor... ({self.udp_ip}:{self.udp_port})")
            self.get_logger().info(f"UDP listener aktif: {self.udp_ip}:{self.udp_port}")
            self.listener_active = True
        except Exception as e:
            print(f"🚨 UDP soketi başlatılamadı: {e}")
            self.get_logger().error(f"UDP soketi başlatılamadı: {e}")
            self.listener_active = False

    def main_loop(self):
        self.ensure_modbus_client()

        if not self.listener_active:
            print("⚡ UDP bağlantısı kapalı, tekrar dinleniyor...")
            self.get_logger().warn("UDP bağlantısı kapalı, tekrar dinleniyor...")
            self.create_udp_socket()
            return

        try:
            self.check_and_receive()
        except Exception as e:
            print(f"🚨 Beklenmeyen ana hata: {e}")
            self.get_logger().error(f"Beklenmeyen ana hata: {e}")
            self.listener_active = False
            self.create_udp_socket()

    def check_and_receive(self):
        last_payload = None

        while True:
            try:
                data, addr = self.sock.recvfrom(1024)
                payload = json.loads(data.decode())
                last_payload = payload
                if not self.is_connected:
                    print(f"✅ Mobil uygulama bağlantısı geldi! ({addr})")
                self.is_connected = True
            except socket.timeout:
                break
            except Exception as e:
                print(f"🚨 UDP decode hatası: {e}")
                self.get_logger().error(f"UDP decode hatası: {str(e)}")
                self.listener_active = False
                return

        if last_payload is not None:
            pkt_ts = int(last_payload.get('ts', 0))
            now_ts = int(time.time() * 1000)
            gecikme_ms = now_ts - pkt_ts
            self.get_logger().info(f"UDP paket gecikmesi: {gecikme_ms} ms")

            if gecikme_ms > 3000:
                if self.is_connected:
                    print("⚡ Ağ gecikmesi yüksek, robot güvenli moda geçti!")
                    self.get_logger().warn("AĞ GECİKMESİ YÜKSEK! Robot ve fırçalar güvenli moda geçti.")
                self.is_connected = False
                self.process_joystick(0, 0, force=True)
                self.write_brush(2068, 0, force=True)
                self.write_brush(2069, 0, force=True)
                self.timeout_counter = 0
                return

            joy_f = int(last_payload.get('joystick_forward', 0))
            joy_t = int(last_payload.get('joystick_turn', 0))
            brush1 = int(last_payload.get("brush1", 0))
            brush2 = int(last_payload.get("brush2", 0))
            self.process_joystick(joy_f, joy_t)
            self.write_brush(2068, brush1)
            self.write_brush(2069, brush2)

            self.timeout_counter = 0

        else:
            self.timeout_counter += 1

        if self.timeout_counter >= 3:
            if self.is_connected:
                print("❌ Mobil uygulama bağlantısı koptu, tekrar bağlantı bekleniyor...")
                self.get_logger().warn("❌ Mobil uygulama bağlantısı koptu, robot ve fırçalar durduruluyor.")
            self.is_connected = False
            self.process_joystick(0, 0, force=True)
            self.write_brush(2068, 0, force=True)
            self.write_brush(2069, 0, force=True)

    def process_joystick(self, forward, turn, force=False):
        if force or forward != self.last_forward or turn != self.last_turn:
            self.ensure_modbus_client()
            left = right = 0
            base_speed = min(max(abs(forward), 0), 100)

            try:
                if forward > 0:
                    res1 = self.client.write_coils(2048 + 11, [True, False])
                    res2 = self.client.write_coils(2048 + 3, [False, False])
                    if turn > 0:
                        left = base_speed
                        right = int(base_speed * (1 - abs(turn) / 100))
                    elif turn < 0:
                        right = base_speed
                        left = int(base_speed * (1 - abs(turn) / 100))
                    else:
                        left = right = base_speed
                elif forward < 0:
                    res1 = self.client.write_coils(2048 + 11, [False, True])
                    res2 = self.client.write_coils(2048 + 3, [False, False])
                    if turn > 0:
                        left = base_speed
                        right = int(base_speed * (1 - abs(turn) / 100))
                    elif turn < 0:
                        right = base_speed
                        left = int(base_speed * (1 - abs(turn) / 100))
                    else:
                        left = right = base_speed
                elif forward == 0:
                    res1 = self.client.write_coils(2048 + 11, [False, False])
                    if turn > 0:
                        res2 = self.client.write_coils(2048 + 3, [True, False])
                        left = right = min(abs(turn), 100)
                    elif turn < 0:
                        res2 = self.client.write_coils(2048 + 3, [False, True])
                        left = right = min(abs(turn), 100)
                    else:
                        res2 = self.client.write_coils(2048 + 3, [False, False])

                left = max(0, min(100, left))
                right = max(0, min(100, right))

                res3 = self.client.write_registers(10, [left, right])
                for i, res in enumerate([res1, res2, res3]):
                    if res is not None and res.isError():
                        self.get_logger().error(f"Modbus write error {i}: {res}")

            except Exception as e:
                self.get_logger().error(f"Modbus process_joystick Exception: {e}")

            self.get_logger().info(f"Joystick → F:{forward}, T:{turn} | D10={left}, D11={right}")
            self.last_forward = forward
            self.last_turn = turn

    def write_brush(self, coil_addr, value, force=False):
        last_val = self.last_brush1 if coil_addr == 2068 else self.last_brush2
        if force or value != last_val:
            self.ensure_modbus_client()
            try:
                res = self.client.write_coil(coil_addr, bool(value))
                if res is not None and res.isError():
                    self.get_logger().error(f"Modbus write_brush ({coil_addr}) Error: {res}")
                self.get_logger().info(f"Fırça {coil_addr} → {bool(value)}")
                if coil_addr == 2068:
                    self.last_brush1 = value
                elif coil_addr == 2069:
                    self.last_brush2 = value
            except Exception as e:
                self.get_logger().error(f"write_brush Exception ({coil_addr}): {e}")

def main(args=None):
    rclpy.init(args=args)
    node = UDPJoystickListener()
    rclpy.spin(node)
    node.destroy_node()
    rclpy.shutdown()

if __name__ == "__main__":
    main()
