import threading
import socket
import json
import time
from http.server import BaseHTTPRequestHandler, HTTPServer
import cv2
import depthai as dai
import numpy as np
import math

latest_map_jpeg = None

# Robot pose estimate in metres/radians (x, y, yaw)
robot_pose = [0.0, 0.0, 0.0]

# Destination the robot should drive towards (x, y) in metres
navig_goal = None


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
    """Generate a bird's-eye occupancy map from a depth frame.

    Instead of returning the raw camera view, the depth information is projected
    onto the ground plane to create a top-down map similar to SLAM outputs.
    Free space is rendered in white, obstacles in black and unexplored regions
    in grey.  The robot's footprint (50 cm x 80 cm) is drawn as a white
    rectangle offset 30 cm behind the camera to provide context.

    Parameters
    ----------
    depth_frame: numpy.ndarray
        Raw depth frame from the OAK device (in millimetres).

    Returns
    -------
    numpy.ndarray
        Top-down occupancy map suitable for JPEG encoding.
    """

    depth_frame = depth_frame.astype(np.float32)
    max_range = 4.0  # metres
    depth_frame[depth_frame == 0] = max_range * 1000  # treat missing depth as far away

    h, w = depth_frame.shape
    fx = fy = 610.0  # approximate focal length in pixels for 720p cameras
    cx, cy = w / 2.0, h / 2.0

    map_size = 200
    map_img = np.full((map_size, map_size), 127, dtype=np.uint8)  # grey for unknown
    pixels_per_m = map_size / max_range
    origin = (map_size // 2, map_size - 1)

    step = 4  # skip pixels for efficiency
    for v in range(0, h, step):
        for u in range(0, w, step):
            z = depth_frame[v, u] / 1000.0  # convert to metres
            if z >= max_range:
                continue
            x = (u - cx) * z / fx
            map_x = int(origin[0] + x * pixels_per_m)
            map_y = int(origin[1] - z * pixels_per_m)
            if 0 <= map_x < map_size and 0 <= map_y < map_size:
                cv2.line(map_img, origin, (map_x, map_y), 255, 1)
                map_img[map_y, map_x] = 0

    map_img = cv2.cvtColor(map_img, cv2.COLOR_GRAY2BGR)

    robot_width = 0.50
    robot_length = 0.80
    camera_offset = 0.30
    rw_px = int(robot_width * pixels_per_m)
    rl_px = int(robot_length * pixels_per_m)
    offset_px = int(camera_offset * pixels_per_m)
    top_left = (origin[0] - rw_px // 2, origin[1] - offset_px - rl_px)
    bottom_right = (origin[0] + rw_px // 2, origin[1] - offset_px)
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


def goal_udp_listener(port: int = 8000):
    """Listen for goal coordinates via UDP.

    Incoming datagrams should contain two comma-separated floats
    representing the target ``x`` and ``y`` in metres, e.g. ``"1.2,3.4"``.
    Any malformed packets are ignored.
    """
    global navig_goal
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.bind(("0.0.0.0", port))
    while True:
        data, _ = sock.recvfrom(1024)
        try:
            x_str, y_str = data.decode().split(",")
            navig_goal = (float(x_str), float(y_str))
            print(f"Received goal via UDP: {navig_goal}")
        except Exception as exc:
            print(f"Invalid UDP goal '{data}': {exc}")


def navigation_loop():
    """Continuously drive the robot towards ``navig_goal``.

    A very small proportional controller translates the distance and heading
    error into joystick commands which are sent over UDP to the existing
    ``udp_listener_node`` (port 8888).  Odometry is approximated by integrating
    the commands we send assuming fixed linear and angular speeds.
    """

    global navig_goal
    cmd_sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    dest = ("127.0.0.1", 8888)

    # Controller constants
    kp_dist = 50.0  # convert metres to joystick percentage
    kp_ang = 60.0   # convert radians to joystick percentage
    max_lin = 0.3   # m/s when joystick_forward=100
    max_ang = math.radians(90)  # rad/s when joystick_turn=100
    dt = 0.1

    while True:
        if navig_goal is not None:
            dx = navig_goal[0] - robot_pose[0]
            dy = navig_goal[1] - robot_pose[1]
            dist = math.hypot(dx, dy)
            desired_heading = math.atan2(dx, dy)
            heading_err = (desired_heading - robot_pose[2] + math.pi) % (2 * math.pi) - math.pi

            forward = max(-100, min(100, int(kp_dist * dist)))
            turn = max(-100, min(100, int(kp_ang * heading_err)))

            pkt = {
                "joystick_forward": forward,
                "joystick_turn": turn,
                "brush1": 0,
                "brush2": 0,
                "ts": int(time.time() * 1000),
            }
            cmd_sock.sendto(json.dumps(pkt).encode(), dest)

            v = forward / 100.0 * max_lin
            w = turn / 100.0 * max_ang
            robot_pose[2] += w * dt
            robot_pose[0] += v * math.sin(robot_pose[2]) * dt
            robot_pose[1] += v * math.cos(robot_pose[2]) * dt

            if dist < 0.1:
                stop_pkt = {
                    "joystick_forward": 0,
                    "joystick_turn": 0,
                    "brush1": 0,
                    "brush2": 0,
                    "ts": int(time.time() * 1000),
                }
                cmd_sock.sendto(json.dumps(stop_pkt).encode(), dest)
                navig_goal = None

        time.sleep(dt)


def main():
    threading.Thread(target=device_loop, daemon=True).start()
    threading.Thread(target=goal_udp_listener, daemon=True).start()
    threading.Thread(target=navigation_loop, daemon=True).start()
    server = HTTPServer(('0.0.0.0', 8000), Handler)
    print('Map server running on port 8000')
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == '__main__':
    main()
