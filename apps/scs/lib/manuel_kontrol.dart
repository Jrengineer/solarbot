import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/material.dart';

class ManuelKontrol extends StatefulWidget {
  const ManuelKontrol({super.key});

  @override
  State<ManuelKontrol> createState() => _ManuelKontrolState();
}

class _ManuelKontrolState extends State<ManuelKontrol> {
  RawDatagramSocket? _udpSocket;
  final String _targetIP = '192.168.1.130';
  final int _targetPort = 8888;
  Map<int, Offset> _touchStartPoints = {};
  Map<int, Offset> _touchCurrentPoints = {};
  double _speed = 50;
  Timer? _sendTimer;

  Socket? _tcpSocket;
  Uint8List? _cameraImageBytes;
  List<int> _cameraBuffer = [];
  int _fps = 0;
  int _frameCounter = 0;
  int _latencyMs = 0;
  Timer? _fpsTimer;
  int _lastFrameTime = 0;

  Rect? _leftJoystickArea;
  Rect? _rightJoystickArea;
  Rect? _cameraArea;

  bool _isBrush1On = false;
  bool _isBrush2On = false;

  @override
  void initState() {
    super.initState();
    _initUdp();
    _initTcp();
    _sendTimer = Timer.periodic(const Duration(milliseconds: 10), (_) => _sendData());
    _fpsTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      setState(() {
        _fps = _frameCounter;
        _frameCounter = 0;
      });
    });
  }

  void _initUdp() async {
    _udpSocket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
  }

  void _initTcp() async {
    try {
      _tcpSocket = await Socket.connect('192.168.1.130', 5000);
      _tcpSocket!.listen(_onCameraData, onDone: _onCameraDone, onError: _onCameraError);
    } catch (e) {
      print('TCP bağlantı hatası: $e');
    }
  }

  void _onCameraData(Uint8List data) {
    _cameraBuffer.addAll(data);

    while (_cameraBuffer.length >= 4) {
      final byteData = ByteData.sublistView(Uint8List.fromList(_cameraBuffer));
      final frameLength = byteData.getUint32(0, Endian.big);

      if (_cameraBuffer.length < 4 + frameLength) break;

      final frameData = _cameraBuffer.sublist(4, 4 + frameLength);
      _cameraBuffer = _cameraBuffer.sublist(4 + frameLength);

      final now = DateTime.now().millisecondsSinceEpoch;
      final latency = _lastFrameTime == 0 ? 0 : now - _lastFrameTime;
      _lastFrameTime = now;

      setState(() {
        _cameraImageBytes = Uint8List.fromList(frameData);
        _latencyMs = latency;
        _frameCounter++;
      });
    }
  }

  void _onCameraDone() {
    print('Kamera bağlantısı kapandı.');
    _tcpSocket?.destroy();
  }

  void _onCameraError(error) {
    print('Kamera bağlantı hatası: $error');
    _tcpSocket?.destroy();
  }

  // Responsive yerleşim (sol/orta/sağ şeritler)
  void _calculateAreas(Size size) {
    final bool isSmall = size.shortestSide < 600;

    // Sol ve sağ joystick şerit genişliği (ekranın ~%33'ü)
    final double sideW = size.width * (isSmall ? 0.24 : 0.20);
    final double middleW = size.width - (2 * sideW);

    // Kamera boyutu: orta şeridin %90'ı kadar genişlik, yükseklik ekranın ~%55'i (küçük ekranda daha büyük)
    final double camWidth = middleW * 1;
    final double camHeight = max(
      220.0,
      size.height * (isSmall ? 0.55 : 0.48),
    );

    // Üstte biraz boşluk
    final double topPad = 16.0;
    double camX = sideW + (middleW - camWidth) / 2;
    double camY = topPad;
    // Taşmaması için sınırla
    if (camY + camHeight > size.height - 16) {
      camY = max(8, size.height - camHeight - 16);
    }

    _cameraArea = Rect.fromLTWH(camX, camY, camWidth, min(camHeight, size.height - camY - 8));

    // Joystick alanlarını tüm yükseklik boyunca ver (kamera ile çakışma zaten kontrol ediliyor)
    _leftJoystickArea  = Rect.fromLTWH(0, 0, sideW, size.height);
    _rightJoystickArea = Rect.fromLTWH(size.width - sideW, 0, sideW, size.height);
  }
  // ----------------------------------------------------------

  bool _isInJoystickArea(Offset position) {
    if (_cameraArea != null && _cameraArea!.contains(position)) return false;
    return (_leftJoystickArea?.contains(position) ?? false) ||
        (_rightJoystickArea?.contains(position) ?? false);
  }

  void _sendData() {
    if (_udpSocket == null) return;

    double forwardBackward = 0;
    double leftRight = 0;

    bool validTouchExists = false;
    _touchCurrentPoints.forEach((pointer, currentPosition) {
      final start = _touchStartPoints[pointer];
      if (start != null && _isInJoystickArea(start)) {
        validTouchExists = true;
        if (_leftJoystickArea!.contains(start)) {
          forwardBackward = (start.dy - currentPosition.dy) / 100;
        } else if (_rightJoystickArea!.contains(start)) {
          leftRight = (currentPosition.dx - start.dx) / 100;
        }
      }
    });

    forwardBackward = forwardBackward.clamp(-1.0, 1.0);
    leftRight = leftRight.clamp(-1.0, 1.0);

    final int scaledForwardBackward = (forwardBackward * _speed).toInt();
    final int scaledLeftRight = (leftRight * _speed).toInt();

    final messageMap = {
      "joystick_forward": validTouchExists ? scaledForwardBackward : 0,
      "joystick_turn": validTouchExists ? scaledLeftRight : 0,
      "brush1": _isBrush1On ? 1 : 0,
      "brush2": _isBrush2On ? 1 : 0,
      "ts": DateTime.now().millisecondsSinceEpoch,
    };
    final message = jsonEncode(messageMap);
    _udpSocket!.send(utf8.encode(message), InternetAddress(_targetIP), _targetPort);
  }

  @override
  void dispose() {
    _udpSocket?.close();
    _tcpSocket?.destroy();
    _sendTimer?.cancel();
    _fpsTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Manuel Kontrol')),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final area = Size(constraints.maxWidth, constraints.maxHeight);
          _calculateAreas(area);
          return Stack(
            children: [
              if (_cameraImageBytes != null)
                Positioned(
                  left: _cameraArea!.left,
                  top: _cameraArea!.top,
                  width: _cameraArea!.width,
                  height: _cameraArea!.height,
                  child: Image.memory(
                    _cameraImageBytes!,
                    fit: BoxFit.contain,
                    gaplessPlayback: true,
                  ),
                ),
              _buildJoystickLayer(area),
            ],
          );
        },
      ),
      bottomNavigationBar: SafeArea(
        top: false,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 16),
          decoration: BoxDecoration(
            color: Theme.of(context).colorScheme.surface,
            boxShadow: const [BoxShadow(blurRadius: 8, offset: Offset(0, -2), color: Colors.black26)],
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text("Ön Fırça", style: TextStyle(fontWeight: FontWeight.bold)),
                  Switch(value: _isBrush1On, onChanged: (v) => setState(() => _isBrush1On = v)),
                ],
              ),
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('Hız Limiti'),
                  SizedBox(
                    width: 160,
                    child: Slider(
                      value: _speed, min: 10, max: 100, divisions: 9,
                      label: '${_speed.round()}%',
                      onChanged: (v) => setState(() => _speed = v),
                    ),
                  ),
                  Text('Seçili: ${_speed.round()}%', style: const TextStyle(fontSize: 12)),
                  const SizedBox(height: 4),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('FPS: $_fps', style: const TextStyle(fontSize: 12)),
                      const SizedBox(width: 12),
                      Text('Gecikme: $_latencyMs ms', style: const TextStyle(fontSize: 12)),
                    ],
                  ),
                ],
              ),
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text("Arka Fırça", style: TextStyle(fontWeight: FontWeight.bold)),
                  Switch(value: _isBrush2On, onChanged: (v) => setState(() => _isBrush2On = v)),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildJoystickLayer(Size size) {
    return Positioned.fill(
      child: Listener(
        onPointerDown: (details) {
          if (_isInJoystickArea(details.localPosition)) {
            setState(() {
              _touchStartPoints[details.pointer] = details.localPosition;
              _touchCurrentPoints[details.pointer] = details.localPosition;
            });
          }
        },
        onPointerMove: (details) {
          if (_touchStartPoints.containsKey(details.pointer)) {
            setState(() {
              _touchCurrentPoints[details.pointer] = _limitMovement(
                _touchStartPoints[details.pointer]!,
                details.localPosition,
                100,
              );
            });
          }
        },
        onPointerUp: (details) {
          setState(() {
            _touchStartPoints.remove(details.pointer);
            _touchCurrentPoints.remove(details.pointer);
          });
        },
        onPointerCancel: (details) {
          setState(() {
            _touchStartPoints.remove(details.pointer);
            _touchCurrentPoints.remove(details.pointer);
          });
        },
        child: CustomPaint(
          size: Size.infinite,
          painter: JoystickPainter(
            startPoints: _touchStartPoints,
            currentPoints: _touchCurrentPoints,
            leftJoystickArea: _leftJoystickArea!,
            rightJoystickArea: _rightJoystickArea!,
          ),
        ),
      ),
    );
  }

  Offset _limitMovement(Offset center, Offset current, double maxDistance) {
    final dx = current.dx - center.dx;
    final dy = current.dy - center.dy;
    final distance = sqrt(dx * dx + dy * dy);
    if (distance > maxDistance) {
      final angle = atan2(dy, dx);
      return Offset(center.dx + maxDistance * cos(angle), center.dy + maxDistance * sin(angle));
    } else {
      return current;
    }
  }
}

class JoystickPainter extends CustomPainter {
  final Map<int, Offset> startPoints;
  final Map<int, Offset> currentPoints;
  final Rect leftJoystickArea;
  final Rect rightJoystickArea;

  JoystickPainter({
    required this.startPoints,
    required this.currentPoints,
    required this.leftJoystickArea,
    required this.rightJoystickArea,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final greenPaint = Paint()..color = Colors.green.withOpacity(0.25);
    final yellowPaint = Paint()..color = Colors.yellow.withOpacity(0.5);
    final orangePaint = Paint()..color = Colors.orange;

    // Geniş joystick alanları
    canvas.drawRect(leftJoystickArea, greenPaint);
    canvas.drawRect(rightJoystickArea, greenPaint);

    startPoints.forEach((pointer, start) {
      final current = currentPoints[pointer];
      if (current != null) {
        canvas.drawCircle(start, 60, yellowPaint);
        canvas.drawCircle(current, 30, orangePaint);
      }
    });
  }

  @override
  bool shouldRepaint(covariant JoystickPainter oldDelegate) => true;
}
