#!/usr/bin/env python3
# -*- coding: utf-8 -*-

import socket
import json
import time
import math
import serial
import threading
import traceback
from typing import Dict, Any, Optional, Tuple, List

TCP_CONTROL_HOST = "0.0.0.0"
TCP_CONTROL_PORT = 5001
DEFAULT_UDP_TARGET_PORT = 8890
SERIAL_PORT = "/dev/ttyUSB0"
SERIAL_BAUD = 9600
SERIAL_TIMEOUT_S = 1.2
READ_PERIOD_S = 1.0

DID_90 = 0x90
DID_93 = 0x93
DID_94 = 0x94
DID_96 = 0x96
DID_92 = 0x92

def checksum(buf: bytes) -> int:
    return sum(buf) & 0xFF

def build_frame(did: int) -> bytearray:
    frame = [0xA5, 0x40, did, 0x08] + [0x00]*8
    frame.append(checksum(frame))
    return bytearray(frame)

def read_fixed_reply(ser: serial.Serial, expect_did: int, tries: int = 4, sleep_s: float = 0.06) -> Optional[bytes]:
    for _ in range(tries):
        try:
            ser.reset_input_buffer()
        except Exception:
            pass
        ser.write(build_frame(expect_did))
        ser.flush()
        time.sleep(sleep_s)
        resp = ser.read(13)
        if len(resp) != 13:
            continue
        if resp[0] != 0xA5 or resp[2] != expect_did:
            continue
        if checksum(resp[:-1]) != resp[-1]:
            continue
        return resp
    return None

def be16(hi: int, lo: int) -> int: return (hi << 8) | lo
def be32(b0: int, b1: int, b2: int, b3: int) -> int: return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3

def parse_did_90(resp: bytes) -> Tuple[float, float, float]:
    d = resp[4:12]
    cumu_v = be16(d[0], d[1]) / 10.0
    curr  = (be16(d[4], d[5]) - 30000) / 10.0
    soc   = be16(d[6], d[7]) / 10.0
    return cumu_v, curr, soc

def parse_did_93(resp: bytes) -> int:
    d = resp[4:12]
    remain_mah = be32(d[4], d[5], d[6], d[7])
    return remain_mah

def parse_did_94(resp: bytes) -> Tuple[int, int]:
    d = resp[4:12]
    series_cells = d[0]
    temp_count   = d[1]
    return series_cells, temp_count

def read_all_temps_via_96(ser: serial.Serial, temp_count: int) -> List[float]:
    if temp_count <= 0: return []
    frames_needed = min(3, max(1, math.ceil(temp_count / 7)))
    got_frames: Dict[int, List[Optional[float]]] = {}
    attempts = 0
    max_attempts = frames_needed * 6
    while len(got_frames) < frames_needed and attempts < max_attempts:
        resp = read_fixed_reply(ser, DID_96, tries=1, sleep_s=0.06)
        attempts += 1
        if not resp: continue
        frame_no = resp[4]
        if frame_no == 0xFF or frame_no > 2: continue
        payload = resp[5:12]
        temps_this_frame = [(v - 40) if v != 0xFF else None for v in payload]
        got_frames[frame_no] = temps_this_frame
        time.sleep(0.05)
    temps: List[float] = []
    for fn in range(frames_needed):
        if fn in got_frames:
            for t in got_frames[fn]:
                if t is None: continue
                if t <= -39.5: continue
                temps.append(t)
    return temps[:temp_count]

def read_maxmin_temp_via_92(ser: serial.Serial) -> Optional[Tuple[float,int,float,int]]:
    resp = read_fixed_reply(ser, DID_92, tries=4, sleep_s=0.06)
    if not resp: return None
    d = resp[4:12]
    tmax = d[0] - 40
    tmax_idx = d[1]
    tmin = d[2] - 40
    tmin_idx = d[3]
    return tmax, tmax_idx, tmin, tmin_idx

def estimate_runtime_hours(remain_mah: Optional[int], current_a: Optional[float], min_current_a: float = 0.05) -> Optional[float]:
    if remain_mah is None or current_a is None: return None
    i = abs(current_a)
    if i < min_current_a: return None
    return remain_mah / (i * 1000.0)

def fmt_hours(h: Optional[float]) -> Optional[str]:
    if h is None: return None
    total_minutes = int(round(h * 60))
    hh = total_minutes // 60
    mm = total_minutes % 60
    return f"{mm} dk" if hh == 0 else f"{hh} sa {mm} dk"

def read_battery_snapshot(ser: serial.Serial) -> Dict[str, Any]:
    data: Dict[str, Any] = {
        "ts": time.time(),
        "voltage_v": None, "current_a": None, "soc_pct": None,
        "remain_mah": None, "temps_c": [], "temp_fallback": None,
        "runtime_hours": None, "runtime_str": None,
        "ok": False, "err": None
    }
    try:
        r90 = read_fixed_reply(ser, DID_90, tries=6)
        if r90:
            v, i, soc = parse_did_90(r90)
            data.update(voltage_v=round(v,1), current_a=round(i,2), soc_pct=round(soc,1))
        r93 = read_fixed_reply(ser, DID_93, tries=6)
        if r93:
            data["remain_mah"] = parse_did_93(r93)
        data["runtime_hours"] = (estimate_runtime_hours(data["remain_mah"], data["current_a"])
                                 if (data["remain_mah"] is not None and data["current_a"] is not None) else None)
        data["runtime_str"] = fmt_hours(data["runtime_hours"])
        temps = []
        r94 = read_fixed_reply(ser, DID_94, tries=6)
        if r94:
            _, temp_count = parse_did_94(r94)
            if temp_count and temp_count > 0:
                temps = read_all_temps_via_96(ser, temp_count)
        if temps:
            data["temps_c"] = temps
        else:
            alt = read_maxmin_temp_via_92(ser)
            if alt:
                tmax, tmax_idx, tmin, tmin_idx = alt
                data["temp_fallback"] = {"tmax": tmax, "tmax_idx": tmax_idx, "tmin": tmin, "tmin_idx": tmin_idx}
        if (data["voltage_v"] is not None) or (data["soc_pct"] is not None):
            data["ok"] = True
    except Exception as e:
        data["err"] = f"{type(e).__name__}: {e}"
    return data

def udp_stream_loop(stop_evt: threading.Event, target_ip: str, target_port: int):
    print(f"📤 UDP yayın başlıyor -> {target_ip}:{target_port}")
    udp_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    ser: Optional[serial.Serial] = None
    last_err_log_t = 0.0
    try:
        while not stop_evt.is_set():
            if ser is None or not ser.is_open:
                try:
                    ser = serial.Serial(SERIAL_PORT, SERIAL_BAUD, bytesize=8, parity='N',
                                        stopbits=1, timeout=SERIAL_TIMEOUT_S)
                    print(f"🔌 Seri porta bağlandı: {SERIAL_PORT} @ {SERIAL_BAUD}")
                except Exception as e:
                    now = time.time()
                    if now - last_err_log_t > 5.0:
                        print(f"⚠️ Seri port açılamadı: {e}")
                        last_err_log_t = now
                    time.sleep(1.0)
                    continue
            snapshot = read_battery_snapshot(ser)
            payload = json.dumps(snapshot, ensure_ascii=False).encode("utf-8")
            try:
                udp_sock.sendto(payload, (target_ip, target_port))
            except Exception as e:
                now = time.time()
                if now - last_err_log_t > 5.0:
                    print(f"⚠️ UDP send hatası: {e}")
                    last_err_log_t = now
            stop_evt.wait(READ_PERIOD_S)
    finally:
        try: udp_sock.close()
        except Exception: pass
        if ser is not None:
            try: ser.close()
            except Exception: pass
        print("🛑 UDP yayın durdu.")

def start_server():
    srv = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    srv.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    srv.bind((TCP_CONTROL_HOST, TCP_CONTROL_PORT))
    srv.listen(1)
    print(f"🚀 Battery UDP node kontrol TCP sunucusu: {TCP_CONTROL_HOST}:{TCP_CONTROL_PORT}")
    while True:
        print("📡 Flutter bağlantısı bekleniyor...")
        client_sock, addr = srv.accept()
        client_ip, _ = addr
        print(f"✅ Flutter TCP bağlandı: {addr}")
        target_udp_port = DEFAULT_UDP_TARGET_PORT
        client_sock.settimeout(1.0)
        try:
            raw = client_sock.recv(64)
            if raw:
                try:
                    text = raw.decode("utf-8", errors="ignore").strip()
                    if text.startswith("UDPPORT:"):
                        p = int(text.split(":", 1)[1].strip())
                        if 1 <= p <= 65535:
                            target_udp_port = p
                            print(f"🔧 İstemciden UDP port alındı: {target_udp_port}")
                except Exception:
                    pass
        except socket.timeout:
            pass
        except Exception as e:
            print(f"TCP ilk okuma hatası: {e}")
        stop_evt = threading.Event()
        t = threading.Thread(target=udp_stream_loop, args=(stop_evt, client_ip, target_udp_port), daemon=True)
        t.start()
        try:
            while True:
                hb = client_sock.recv(1)
                if not hb:
                    break
        except Exception:
            pass
        print("⚡ Flutter TCP bağlantısı koptu, UDP yayını durduruluyor…")
        stop_evt.set()
        t.join(timeout=3.0)
        try: client_sock.close()
        except Exception: pass

def main():
    try:
        start_server()
    except KeyboardInterrupt:
        print("\nÇıkılıyor (CTRL+C).")
    except Exception as e:
        print(f"🚨 Ana döngü hatası: {e}")
        traceback.print_exc()

if __name__ == "__main__":
    main()