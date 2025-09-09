"""Streaming node for OAK camera with optional human tracking.

This module exposes a small TCP server used by the Flutter application to
retrieve JPEG encoded frames from the OAK-D camera.  The original
implementation simply forwarded frames.  For the purposes of the exercises in
this benchmark we extend the node with a very small scale human tracking
feature implemented with OpenCV's HOG person detector.  The tracker can be
enabled/disabled via simple text commands sent over the same TCP connection and
allows tuning of the detection sensitivity and the distance at which the robot
should stop following a person.  When the person is lost the node prints the
last seen direction which could be used by a higher level controller to rotate
the robot back towards that direction.

The functionality implemented here is intentionally lightweight – the main goal
is to demonstrate how such hooks could be wired into the existing streaming
infrastructure.  It is **not** a production ready tracker.
"""

from __future__ import annotations

import socket
import struct
from typing import List, Tuple

import cv2

try:  # DepthAI is optional for tests – import lazily.
    import depthai as dai
except Exception:  # pragma: no cover - depthai may not be installed during tests
    dai = None  # type: ignore


# Pre-initialised HOG descriptor for person detection.
_hog = cv2.HOGDescriptor()
_hog.setSVMDetector(cv2.HOGDescriptor_getDefaultPeopleDetector())


def detect_humans(frame, sensitivity: float = 0.5) -> List[Tuple[int, int, int, int]]:
    """Return bounding boxes of detected humans in ``frame``.

    Parameters
    ----------
    frame:
        Input image as a ``numpy.ndarray``.  Both grayscale and BGR images are
        supported.
    sensitivity:
        Value between ``0`` and ``1`` controlling the aggressiveness of the
        detector.  Higher values result in more detections but also more false
        positives.  The value is mapped to the ``scale`` parameter of the HOG
        detector.

    Returns
    -------
    list of (x, y, w, h)
        Bounding boxes for detected persons.
    """

    if frame.ndim == 2:  # Convert grayscale to colour for the detector.
        frame = cv2.cvtColor(frame, cv2.COLOR_GRAY2BGR)

    scale = max(1.05, 2 - float(sensitivity))
    rects, _ = _hog.detectMultiScale(frame, winStride=(8, 8), padding=(16, 16), scale=scale)
    return [(int(x), int(y), int(w), int(h)) for (x, y, w, h) in rects]

def create_pipeline():
    if dai is None:  # pragma: no cover - handled at runtime
        raise RuntimeError("DepthAI is required to create the pipeline")

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

def start_server(
    host: str = "0.0.0.0",
    port: int = 5000,
    *,
    stop_distance: float = 2.0,
    sensitivity: float = 0.5,
    tracking: bool = True,
) -> None:
    """Start the TCP server used to stream frames to the Flutter app.

    Parameters allow runtime adjustment of the simple human tracking behaviour.
    ``stop_distance`` roughly corresponds to the desired distance (in arbitrary
    units) at which the robot should stop when approaching a person.  The
    ``sensitivity`` parameter tunes the HOG detector and ``tracking`` enables or
    disables person detection entirely.
    """

    server_socket = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
    server_socket.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
    server_socket.bind((host, port))
    server_socket.listen(1)

    print(f"🚀 TCP server başlatıldı: {host}:{port}")

    while True:
        print("📡 Bağlantı bekleniyor...")
        client_socket, addr = server_socket.accept()
        client_socket.settimeout(0.001)  # Non-blocking reads for control commands
        print(f"✅ Flutter bağlantısı geldi: {addr}")

        try:
            if dai is None:
                raise RuntimeError("DepthAI is not available")

            with dai.Device(create_pipeline()) as device:
                mono = device.getOutputQueue(name="mono", maxSize=1, blocking=False)

                last_direction = None
                while True:
                    try:
                        cmd = client_socket.recv(32).decode().strip()
                        if cmd == "TRACK_ON":
                            tracking = True
                        elif cmd == "TRACK_OFF":
                            tracking = False
                        elif cmd.startswith("SENS="):
                            sensitivity = float(cmd.split("=", 1)[1])
                        elif cmd.startswith("DIST="):
                            stop_distance = float(cmd.split("=", 1)[1])
                    except socket.timeout:
                        pass
                    except ValueError:
                        pass  # Ignore malformed commands

                    in_mono = mono.get()
                    frame = in_mono.getCvFrame()   # Mono frame (np.uint8, tek kanal)

                    if tracking:
                        boxes = detect_humans(frame, sensitivity)
                        if boxes:
                            x, y, w, h = boxes[0]
                            cv2.rectangle(frame, (x, y), (x + w, y + h), (0, 255, 0), 2)
                            centre = x + w / 2
                            last_direction = "left" if centre < frame.shape[1] / 2 else "right"
                            distance_est = 1.0 / max(h, 1)
                            if distance_est < stop_distance:
                                print("⛔️ Stop mesafesi aşıldı")
                        elif last_direction:
                            print(f"🔍 Kişi kayboldu, {last_direction} yönüne dönülüyor")
                            last_direction = None

                    encode_param = [int(cv2.IMWRITE_JPEG_QUALITY), 20]
                    result, img_encoded = cv2.imencode(".jpg", frame, encode_param)

                    if not result:
                        continue

                    data = img_encoded.tobytes()
                    length = struct.pack(">I", len(data))

                    try:
                        client_socket.sendall(length + data)
                    except (socket.error, BrokenPipeError):
                        print("⚡ Bağlantı koptu, yeni bağlantı bekleniyor...")
                        break

        except Exception as e:  # pragma: no cover - runtime errors are logged
            print(f"🚨 Hata oluştu: {e}")

        finally:
            client_socket.close()

def main():
    start_server()

if __name__ == "__main__":
    main()
