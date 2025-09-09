import 'dart:async';
import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';

/// A global service that maintains a single camera TCP connection and
/// exposes the latest frame along with FPS and latency information.
///
/// Having a shared service prevents multiple pages from opening their own
/// sockets which previously caused the camera stream to fail when several
/// widgets tried to access it simultaneously.
class CameraService extends ChangeNotifier {
  static const String _cameraIp = '192.168.1.130';
  static const int _cameraPort = 5000;

  Socket? _socket;
  bool _connected = false;
  final List<int> _buffer = [];

  Uint8List? _imageBytes;
  int _fps = 0;
  int _latencyMs = 0;

  int _frameCounter = 0;
  int _lastFrameTime = 0;
  Timer? _fpsTimer;

  bool get connected => _connected;
  Uint8List? get imageBytes => _imageBytes;
  int get fps => _fps;
  int get latencyMs => _latencyMs;

  CameraService() {
    _connect();
    _startFpsTimer();
  }

  void _startFpsTimer() {
    _fpsTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _fps = _frameCounter;
      _frameCounter = 0;
      notifyListeners();
    });
  }

  void _connect() async {
    try {
      _socket = await Socket.connect(_cameraIp, _cameraPort);
      _connected = true;
      _socket!.listen(_onData,
          onDone: _handleDisconnect,
          onError: (error) => _handleDisconnect());
      notifyListeners();
    } catch (e) {
      _connected = false;
      notifyListeners();
      Future.delayed(const Duration(seconds: 2), _connect);
    }
  }

  void _handleDisconnect() {
    _socket?.destroy();
    _connected = false;
    notifyListeners();
    Future.delayed(const Duration(seconds: 2), _connect);
  }

  void _onData(Uint8List data) {
    _buffer.addAll(data);
    while (_buffer.length >= 4) {
      final length = ByteData.sublistView(Uint8List.fromList(_buffer))
          .getUint32(0, Endian.big);
      if (_buffer.length < 4 + length) break;
      final frame = _buffer.sublist(4, 4 + length);
      _buffer.removeRange(0, 4 + length);

      final now = DateTime.now().millisecondsSinceEpoch;
      _latencyMs = _lastFrameTime == 0 ? 0 : now - _lastFrameTime;
      _lastFrameTime = now;

      _imageBytes = Uint8List.fromList(frame);
      _frameCounter++;
      notifyListeners();
    }
  }

  @override
  void dispose() {
    _socket?.destroy();
    _fpsTimer?.cancel();
    super.dispose();
  }
}
