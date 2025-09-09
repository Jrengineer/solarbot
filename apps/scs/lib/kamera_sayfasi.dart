import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'camera_service.dart';

class KameraSayfasi extends StatefulWidget {
  const KameraSayfasi({super.key});

  @override
  State<KameraSayfasi> createState() => _KameraSayfasiState();
}

class _KameraSayfasiState extends State<KameraSayfasi> {
  // ===== TCP Kamera =====
  Socket? _socket;
  bool _connected = false;

  int _frameCounter = 0;
  int _fps = 0;
  Timer? _fpsTimer;

  int _lastFrameTime = 0;
  int _latencyMs = 0;

  final List<int> _buffer = [];

  // ===== Klavye/UDP Kontrol =====
  static const String _jetsonIp = '192.168.1.130';
  static const int _udpPort = 8888;

  RawDatagramSocket? _udpSocket;
  Timer? _sendTimer; // 20 Hz heartbeat

  // Eksen değerleri (iç hesap)
  double _joyForward = 0.0; // ileri(+) / geri(-)  [-1..1]
  double _joyTurn = 0.0;    // sağ(+) / sol(-)     [-1..1]

  // SABİT HIZ: %50
  static const int _speedPct = 50; // INT gönderimde kullanılacak

  // WASD & Ok tuşları tutma durumları
  bool _w = false, _s = false, _a = false, _d = false;
  bool _up = false, _down = false, _left = false, _right = false;

  // Fırçalar
  bool _brush1 = false;
  bool _brush2 = false;

  // Numpad 1/2 edge detect
  bool _np1WasDown = false;
  bool _np2WasDown = false;

  // Klavye olayları için odak
  final FocusNode _focusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _connectToServer();
    _startFpsTimer();
    _startUdp();
    _startHeartbeat();

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focusNode.requestFocus();
    });
  }

  // ========= FPS sayaç =========
  void _startFpsTimer() {
    _fpsTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {
        _fps = _frameCounter;
        _frameCounter = 0;
      });
    });
  }

  // ========= TCP Kamera =========
  void _connectToServer() async {
    try {
      _socket = await Socket.connect('192.168.1.130', 5000);
      if (!mounted) return;
      setState(() {
        _connected = true;
      });
      _socket!.listen(_onData, onDone: _onDone, onError: _onError);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _connected = false;
      });
      Future.delayed(const Duration(seconds: 2), _connectToServer);
    }
  }

  void _onData(Uint8List data) {
    final cameraService = Provider.of<CameraService>(context, listen: false);

    _buffer.addAll(data);

    while (_buffer.length >= 4) {
      final lengthBytes = Uint8List.fromList(_buffer.sublist(0, 4));
      final frameLength =
      ByteData.sublistView(lengthBytes).getUint32(0, Endian.big);

      if (_buffer.length < 4 + frameLength) break;

      final frameData = _buffer.sublist(4, 4 + frameLength);
      _buffer.removeRange(0, 4 + frameLength);

      final now = DateTime.now().millisecondsSinceEpoch;
      final latency = _lastFrameTime == 0 ? 0 : now - _lastFrameTime;
      _lastFrameTime = now;

      cameraService.updateCameraData(
        Uint8List.fromList(frameData),
        _fps,
        latency,
      );

      if (!mounted) return;
      setState(() {
        _frameCounter++;
        _latencyMs = latency;
      });
    }
  }

  void _onDone() {
    debugPrint('Kamera bağlantısı kapandı.');
    if (!mounted) return;
    setState(() {
      _connected = false;
    });
    Future.delayed(const Duration(seconds: 2), _connectToServer);
  }

  void _onError(error) {
    debugPrint('Kamera bağlantı hatası: $error');
    if (!mounted) return;
    setState(() {
      _connected = false;
    });
    Future.delayed(const Duration(seconds: 2), _connectToServer);
  }

  // ========= UDP & Heartbeat =========
  Future<void> _startUdp() async {
    try {
      _udpSocket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      _udpSocket?.broadcastEnabled = false;
    } catch (e) {
      debugPrint('UDP bind hatası: $e');
    }
  }

  void _startHeartbeat() {
    _sendTimer?.cancel();
    _sendTimer = Timer.periodic(const Duration(milliseconds: 50), (_) {
      _recomputeAxesFromKeys();
      _sendUdp();
    });
  }

  void _recomputeAxesFromKeys() {
    // Dijital WASD & Ok tuşları -> eksen toplamı
    final fRaw = (_w || _up ? 1.0 : 0.0) + (_s || _down ? -1.0 : 0.0);
    final tRaw = (_d || _right ? 1.0 : 0.0) + (_a || _left ? -1.0 : 0.0);

    // [-1..1] sınırla
    _joyForward = fRaw.clamp(-1.0, 1.0);
    _joyTurn = tRaw.clamp(-1.0, 1.0);
  }

  void _sendUdp() {
    if (_udpSocket == null) return;

    // INT gönder: -50..+50 (sabit %50 hız)
    final int forwardInt = (_joyForward * _speedPct).round();
    final int turnInt = (_joyTurn * _speedPct).round();

    final payload = <String, dynamic>{
      'ts': DateTime.now().millisecondsSinceEpoch,
      'joystick_forward': forwardInt,
      'joystick_turn': turnInt,
      'brush1': _brush1 ? 1 : 0,
      'brush2': _brush2 ? 1 : 0,
    };

    final bytes = utf8.encode(jsonEncode(payload));
    _udpSocket!.send(bytes, InternetAddress(_jetsonIp), _udpPort);
  }

  // ========= Klavye eventleri =========
  void _handleKey(RawKeyEvent event) {
    final isDown = event is RawKeyDownEvent;
    final key = event.logicalKey;

    // WASD
    if (key == LogicalKeyboardKey.keyW) _w = isDown;
    if (key == LogicalKeyboardKey.keyS) _s = isDown;
    if (key == LogicalKeyboardKey.keyA) _a = isDown;
    if (key == LogicalKeyboardKey.keyD) _d = isDown;

    // Ok tuşları
    if (key == LogicalKeyboardKey.arrowUp) _up = isDown;
    if (key == LogicalKeyboardKey.arrowDown) _down = isDown;
    if (key == LogicalKeyboardKey.arrowLeft) _left = isDown;
    if (key == LogicalKeyboardKey.arrowRight) _right = isDown;

    // Numpad 1 -> brush1 toggle
    if (key == LogicalKeyboardKey.numpad1) {
      if (isDown && !_np1WasDown) _brush1 = !_brush1;
      _np1WasDown = isDown;
    }

    // Numpad 2 -> brush2 toggle
    if (key == LogicalKeyboardKey.numpad2) {
      if (isDown && !_np2WasDown) _brush2 = !_brush2;
      _np2WasDown = isDown;
    }

    // Anında eksenleri güncelle
    _recomputeAxesFromKeys();
    setState(() {});
  }

  @override
  void dispose() {
    _socket?.destroy();
    _fpsTimer?.cancel();

    _sendTimer?.cancel();
    _udpSocket?.close();

    _focusNode.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cameraService = Provider.of<CameraService>(context);

    return RawKeyboardListener(
      focusNode: _focusNode,
      autofocus: true,
      onKey: _handleKey,
      child: Scaffold(
        appBar: AppBar(
          title: const Text('Kamera Görüntüsü'),
        ),
        body: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            // Kamera görüntüsü
            Expanded(
              flex: 5,
              child: Center(
                child: _connected
                    ? (cameraService.imageBytes != null
                    ? Image.memory(
                  cameraService.imageBytes!,
                  gaplessPlayback: true,
                  fit: BoxFit.contain,
                  width: MediaQuery.of(context).size.width * 0.9,
                  height: MediaQuery.of(context).size.height * 0.6,
                )
                    : const CircularProgressIndicator())
                    : const Text('Kamera bağlantısı kurulamadı'),
              ),
            ),
            const SizedBox(height: 10),
            // Alt panel: FPS, Gecikme, Sabit hız etiketi
            Expanded(
              flex: 1,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text('FPS: ${cameraService.fps}', style: const TextStyle(fontSize: 18)),
                      const SizedBox(width: 24),
                      Text('Gecikme: ${cameraService.latencyMs} ms', style: const TextStyle(fontSize: 18)),
                    ],
                  ),
                  const SizedBox(height: 8),
                  const Text('Hız: %50 (int gönderim -50..+50)'),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
