import socket
import struct
import cv2
import depthai as dai

def create_pipeline():
    pipeline = dai.Pipeline()

    # Geniş açılı mono kamera (genelde LEFT)
    cam_mono = pipeline.create(dai.node.MonoCamera)
    xout_mono = pipeline.create(dai.node.XLinkOut)

    cam_mono.setBoardSocket(dai.CameraBoardSocket.LEFT)  # Geniş açılı mono için LEFT
    cam_mono.setResolution(dai.MonoCameraProperties.SensorResolution.THE_720_P)
    cam_mono.setFps(30)

    xout_mono.setStreamName("mono")
    cam_mono.out.link(xout_mono.input)

    return pipeline

def start_server(host='0.0.0.0', port=5000):
    server_socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server_socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server_socket.bind((host, port))
    server_socket.listen(1)

    print(f"🚀 TCP server başlatıldı: {host}:{port}")

    while True:
        print("📡 Bağlantı bekleniyor...")
        client_socket, addr = server_socket.accept()
        print(f"✅ Flutter bağlantısı geldi: {addr}")

        try:
            with dai.Device(create_pipeline()) as device:
                mono = device.getOutputQueue(name="mono", maxSize=1, blocking=False)

                while True:
                    in_mono = mono.get()
                    frame = in_mono.getCvFrame()   # Mono frame (np.uint8, tek kanal)

                    # İstersen görüntüyü BGR'ye çevirerek Flutter tarafında renkli gibi gösterebilirsin:
                    # frame = cv2.cvtColor(frame, cv2.COLOR_GRAY2BGR)

                    encode_param = [int(cv2.IMWRITE_JPEG_QUALITY), 20]
                    result, img_encoded = cv2.imencode('.jpg', frame, encode_param)

                    if not result:
                        continue

                    data = img_encoded.tobytes()
                    length = struct.pack('>I', len(data))

                    try:
                        client_socket.sendall(length + data)
                    except (socket.error, BrokenPipeError):
                        print("⚡ Bağlantı koptu, yeni bağlantı bekleniyor...")
                        break

        except Exception as e:
            print(f"🚨 Hata oluştu: {e}")

        finally:
            client_socket.close()

def main():
    start_server()

if __name__ == "__main__":
    main()
