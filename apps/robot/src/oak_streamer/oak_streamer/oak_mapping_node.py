import threading
from http.server import BaseHTTPRequestHandler, HTTPServer
import cv2
import depthai as dai
import numpy as np

latest_map_jpeg = None


def create_pipeline():
    pipeline = dai.Pipeline()

    mono_left = pipeline.create(dai.node.MonoCamera)
    mono_right = pipeline.create(dai.node.MonoCamera)
    stereo = pipeline.create(dai.node.StereoDepth)
    imu = pipeline.create(dai.node.IMU)
    xout_depth = pipeline.create(dai.node.XLinkOut)
    xout_depth.setStreamName("depth")
    xout_imu = pipeline.create(dai.node.XLinkOut)
    xout_imu.setStreamName("imu")

    mono_left.setBoardSocket(dai.CameraBoardSocket.LEFT)
    mono_right.setBoardSocket(dai.CameraBoardSocket.RIGHT)
    for mono in (mono_left, mono_right):
        mono.setResolution(dai.MonoCameraProperties.SensorResolution.THE_720_P)
        mono.setFps(30)

    mono_left.out.link(stereo.left)
    mono_right.out.link(stereo.right)
    stereo.depth.link(xout_depth.input)

    imu.enableIMUSensor(dai.IMUSensor.ACCELEROMETER_RAW, 500)
    imu.enableIMUSensor(dai.IMUSensor.GYROSCOPE_RAW, 500)
    imu.setBatchReportThreshold(1)
    imu.setMaxBatchReports(10)
    imu.out.link(xout_imu.input)

    return pipeline


def compute_map(depth_frame):
    """Generate a colorized map from a depth frame.

    The previous implementation produced a binary black/white image which was
    difficult to interpret.  This version normalizes the depth image and
    applies OpenCV's ``COLORMAP_TURBO`` to create a more informative map similar
    to commercial robot vacuum applications.  Obstacles closer than 0.5 m are
    rendered in black, while free space is colorized according to distance.  The
    robot's footprint (50 cm x 80 cm) is drawn as a white rectangle offset by
    30 cm behind the camera to provide a bird's-eye reference of the platform
    itself.

    Parameters
    ----------
    depth_frame: numpy.ndarray
        Raw depth frame from the OAK device (in millimetres).

    Returns
    -------
    numpy.ndarray
        Colorized map image suitable for JPEG encoding.
    """

    # Ensure ``float32`` for downstream operations and replace missing values
    depth_frame = depth_frame.astype(np.float32)
    depth_frame[depth_frame == 0] = 10_000  # treat missing depth as far away

    # Convert to metres and clamp far values for better contrast
    depth_m = depth_frame / 1000.0
    max_range = 4.0  # metres
    depth_m = np.clip(depth_m, 0.0, max_range)

    # Normalize to 0-255 and apply a perceptually uniform colour map
    norm = cv2.normalize(depth_m, None, 0, 255, cv2.NORM_MINMAX)
    norm = norm.astype(np.uint8)
    color_map = cv2.applyColorMap(norm, cv2.COLORMAP_TURBO)

    # Highlight obstacles (very close readings) with black pixels
    obstacle_mask = depth_m < 0.5
    color_map[obstacle_mask] = (0, 0, 0)

    # Resize to smaller map for transmission
    map_img = cv2.resize(color_map, (200, 200), interpolation=cv2.INTER_NEAREST)

    # Draw the robot footprint as a white rectangle.  The map covers ``max_range``
    # metres in each dimension, so scale metric dimensions accordingly.
    pixels_per_m = map_img.shape[0] / max_range
    robot_width_px = int(0.50 * pixels_per_m)
    robot_length_px = int(0.80 * pixels_per_m)
    camera_offset_px = int(0.30 * pixels_per_m)

    center_x = map_img.shape[1] // 2
    center_y = map_img.shape[0] // 2 + camera_offset_px
    top_left = (center_x - robot_width_px // 2, center_y - robot_length_px // 2)
    bottom_right = (center_x + robot_width_px // 2,
                    center_y + robot_length_px // 2)
    cv2.rectangle(map_img, top_left, bottom_right, (255, 255, 255), 2)

    return map_img


def device_loop():
    global latest_map_jpeg
    with dai.Device(create_pipeline()) as device:
        depth_q = device.getOutputQueue(name="depth", maxSize=1, blocking=False)
        while True:
            in_depth = depth_q.get()
            depth_frame = in_depth.getFrame()
            map_img = compute_map(depth_frame)
            _, jpeg = cv2.imencode('.jpg', map_img)
            latest_map_jpeg = jpeg.tobytes()


navig_goal = None


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path == '/map' and latest_map_jpeg is not None:
            self.send_response(200)
            self.send_header('Content-Type', 'image/jpeg')
            self.end_headers()
            self.wfile.write(latest_map_jpeg)
        else:
            self.send_response(404)
            self.end_headers()

    def do_POST(self):
        global navig_goal
        if self.path == '/goal':
            length = int(self.headers.get('Content-Length', 0))
            data = self.rfile.read(length).decode('utf-8')
            try:
                x_str, y_str = data.split(',')
                navig_goal = (float(x_str), float(y_str))
                print(f"Received goal: {navig_goal}")
                self.send_response(200)
                self.end_headers()
            except Exception:
                self.send_response(400)
                self.end_headers()
        else:
            self.send_response(404)
            self.end_headers()


def main():
    threading.Thread(target=device_loop, daemon=True).start()
    server = HTTPServer(('0.0.0.0', 8000), Handler)
    print('Map server running on port 8000')
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == '__main__':
    main()
