import sys
from pathlib import Path

import numpy as np

sys.path.append(str(Path(__file__).resolve().parents[1] / "oak_streamer"))
from oak_streamer_node import detect_humans  # type: ignore


def test_detect_humans_returns_list():
    frame = np.zeros((480, 640, 3), dtype=np.uint8)
    boxes = detect_humans(frame)
    assert isinstance(boxes, list)
