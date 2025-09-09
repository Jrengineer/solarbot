import 'dart:typed_data';
import 'package:flutter/material.dart';

class CameraService extends ChangeNotifier {
  Uint8List? _imageBytes;
  int _fps = 0;
  int _latencyMs = 0;

  Uint8List? get imageBytes => _imageBytes;
  int get fps => _fps;
  int get latencyMs => _latencyMs;

  void updateCameraData(Uint8List image, int fps, int latency) {
    _imageBytes = image;
    _fps = fps;
    _latencyMs = latency;
    notifyListeners();
  }
}
