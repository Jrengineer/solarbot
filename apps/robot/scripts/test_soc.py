#!/usr/bin/env python3
import serial
import time
import math

PORT = "/dev/ttyUSB0"
BAUDRATE = 9600
TIMEOUT_S = 1.2

# Data IDs
DID_90 = 0x90  # Cumulative V, Gather V, Current, SOC
DID_93 = 0x93  # State/MOS/Life + Remain Capacity (mAh)
DID_94 = 0x94  # Counts (series, temp count, charger/load, DI/DO bits)
DID_96 = 0x96  # Temperatures (multi-frame, 7 değer/çerçeve, offset -40°C)
DID_92 = 0x92  # Max/Min temperature (offset 40°C)

def checksum(buf):
    return sum(buf) & 0xFF

def build_frame(did):
    # [A5][40][DID][08][00 x 8][CS]
    frame = [0xA5, 0x40, did, 0x08] + [0x00]*8
    frame.append(checksum(frame))
    return bytearray(frame)

def read_fixed_reply(ser, expect_did, tries=4, sleep_s=0.06):
    """Sabit 13 byte cevap: başlık/DID/CS doğrular; birkaç kez dener."""
    for _ in range(tries):
        ser.reset_input_buffer()
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

def be16(hi, lo): return (hi << 8) | lo
def be32(b0, b1, b2, b3): return (b0 << 24) | (b1 << 16) | (b2 << 8) | b3

def parse_did_90(resp):
    """
    resp[4..11] (8 byte):
      0-1: Cumulative total voltage (0.1V)
      2-3: Gather total voltage (0.1V)
      4-5: Current (offset 30000, 0.1A)
      6-7: SOC (0.1%)
    """
    d = resp[4:12]
    cumu_v = be16(d[0], d[1]) / 10.0
    curr  = (be16(d[4], d[5]) - 30000) / 10.0
    soc   = be16(d[6], d[7]) / 10.0
    return cumu_v, curr, soc

def parse_did_93(resp):
    """
    resp[4..11] (8 byte):
      4-7: Remain capacity (mAh) (big-endian)
    """
    d = resp[4:12]
    remain_mah = be32(d[4], d[5], d[6], d[7])
    return remain_mah

def parse_did_94(resp):
    """
    resp[4..11] (8 byte):
      0: seri hücre sayısı
      1: sıcaklık sensör sayısı
    """
    d = resp[4:12]
    series_cells = d[0]
    temp_count   = d[1]
    return series_cells, temp_count

def read_all_temps_via_96(ser, temp_count):
    """
    0x96 çok-kare:
      resp[4]    : frame index (0,1,2; 0xFF geçersiz)
      resp[5..11]: 7 sıcaklık (her biri offset -40°C)
    Gereken çerçeve sayısı: ceil(temp_count / 7) (en fazla 3)
    """
    if temp_count <= 0:
        return []

    frames_needed = min(3, max(1, math.ceil(temp_count / 7)))
    got_frames = {}
    attempts = 0
    max_attempts = frames_needed * 6  # her frame için birkaç deneme

    while len(got_frames) < frames_needed and attempts < max_attempts:
        resp = read_fixed_reply(ser, DID_96, tries=1, sleep_s=0.06)
        attempts += 1
        if not resp:
            continue
        frame_no = resp[4]
        if frame_no == 0xFF or frame_no > 2:
            continue
        payload = resp[5:12]  # 7 değer
        temps_this_frame = [(v - 40) if v != 0xFF else None for v in payload]
        got_frames[frame_no] = temps_this_frame
        time.sleep(0.05)

    temps = []
    for fn in range(frames_needed):
        if fn in got_frames:
            for t in got_frames[fn]:
                if t is None:
                    continue
                if t <= -39.5:  # -40°C ve altını gizle (bağlı değil)
                    continue
                temps.append(t)

    return temps[:temp_count]

def read_maxmin_temp_via_92(ser):
    """
    resp[4..11] (8 byte):
      0: Max temp (offset 40°C)
      1: Max temp sensör no
      2: Min temp (offset 40°C)
      3: Min temp sensör no
    """
    resp = read_fixed_reply(ser, DID_92, tries=4, sleep_s=0.06)
    if not resp:
        return None
    d = resp[4:12]
    tmax = d[0] - 40
    tmax_idx = d[1]
    tmin = d[2] - 40
    tmin_idx = d[3]
    return tmax, tmax_idx, tmin, tmin_idx

# --- Kalan Çalışma Süresi Hesabı (Yeni) ---
def estimate_runtime_hours(remain_mah, current_a, min_current_a=0.05):
    """
    remain_mah: mAh
    current_a : A (deşarj genelde negatif gelir)
    min_current_a: çok küçük akımlarda (ör. bekleme) hesap yapmamak için eşik

    Formül: saat = remain_mAh / (|current_A| * 1000)
    (A'yı mA'ya çevirmek için 1000 ile çarpıyoruz)
    """
    if remain_mah is None:
        return None
    if current_a is None:
        return None

    i = abs(current_a)
    if i < min_current_a:
        # Akım çok küçük (ya şarj oluyor ya da neredeyse sıfır tüketim)
        return None
    return remain_mah / (i * 1000.0)

def fmt_hours(h):
    """Saat cinsini 'Xs Ydk' veya 'X.Y saat' gibi okunur formata çevir."""
    if h is None:
        return "hesaplanamadı"
    total_minutes = int(round(h * 60))
    hh = total_minutes // 60
    mm = total_minutes % 60
    if hh == 0:
        return f"{mm} dk"
    return f"{hh} sa {mm} dk"

def main():
    with serial.Serial(PORT, BAUDRATE, bytesize=8, parity='N', stopbits=1, timeout=TIMEOUT_S) as ser:
        print("--- Battery Data ---")

        # 0x90: SOC / Voltaj / Akım
        cumu_v = curr_a = soc = None
        r90 = read_fixed_reply(ser, DID_90, tries=6)
        if r90:
            cumu_v, curr_a, soc = parse_did_90(r90)
            print(f"Cumulative Voltage: {cumu_v:.1f} V")
            print(f"Current: {curr_a:.1f} A")
            print(f"SOC: {soc:.1f} %")
        else:
            print("[!] 0x90 cevabı alınamadı")

        time.sleep(0.07)

        # 0x93: Remain capacity (mAh)
        remain_mah = None
        r93 = read_fixed_reply(ser, DID_93, tries=6)
        if r93:
            remain_mah = parse_did_93(r93)
            print(f"Remain Capacity: {remain_mah} mAh")
        else:
            print("[!] 0x93 cevabı alınamadı")

        # --- Yeni: Tahmini kalan çalışma süresi ---
        hours_left = estimate_runtime_hours(remain_mah, curr_a, min_current_a=0.05)
        print(f"Estimated Runtime (instant): {fmt_hours(hours_left)}")

        time.sleep(0.07)

        # 0x94: Sıcaklık sensör sayısı (0x96'ya hazırlık)
        temps = []
        r94 = read_fixed_reply(ser, DID_94, tries=6)
        if r94:
            _, temp_count = parse_did_94(r94)
            if temp_count > 0:
                temps = read_all_temps_via_96(ser, temp_count)

        # 0x96 yine gelmediyse, 0x92 ile en azından Max/Min ver
        if temps:
            print("\n--- All Temperature Sensors ---")
            for i, t in enumerate(temps, start=1):
                print(f"T{i}: {t} °C")
        else:
            alt = read_maxmin_temp_via_92(ser)
            if alt:
                tmax, tmax_idx, tmin, tmin_idx = alt
                print("\n--- Temperature (fallback 0x92) ---")
                print(f"Max: {tmax} °C (sensor {tmax_idx})")
                print(f"Min: {tmin} °C (sensor {tmin_idx})")
            else:
                print("[!] 0x96/0x92 sıcaklık verisi alınamadı")

if __name__ == "__main__":
    main()
