import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/material.dart';

/// Jetson'daki udp_listener_node ile uyumlu tek-joystick sayfası.
/// - 20 Hz UDP heartbeat
/// - JSON: ts, joystick_forward, joystick_turn, brush1, brush2
/// - Joystick: basılan noktada spawn; bırakınca F=0, T=0
/// - İleri (+F): yukarı; Dönüş (+T): sağa
/// - Eksene yapışma (±15°): saf ileri/saf dönüş kolaylığı
class TekJoystickSpawnPage extends StatefulWidget {
  const TekJoystickSpawnPage({super.key});

  @override
  State<TekJoystickSpawnPage> createState() => _TekJoystickSpawnPageState();
}

class _TekJoystickSpawnPageState extends State<TekJoystickSpawnPage> {
  // ===== Ağ / UDP =====
  final String _targetIP = '192.168.1.130'; // Jetson
  final int _targetPort = 8888;             // udp_listener_node port
  RawDatagramSocket? _udp;
  bool _udpReady = false;

  // ===== Gönderim =====
  Timer? _sendTimer;
  final int _sendHz = 20; // 20 Hz -> 50 ms
  int _forward = 0; // [-100..100]
  int _turn = 0;    // [-100..100]
  int _brush1 = 0;  // 0/1
  int _brush2 = 0;  // 0/1

  // ===== Joystick Durumu =====
  bool _active = false;     // parmak basılı mı
  Offset? _origin;          // joystick'in doğduğu nokta (alan local coord)
  Offset? _point;           // son dokunma
  double _maxRadius = 110;  // px
  double _deadZone = 8;     // px
  double _expo = 0.15;      // merkez hassasiyeti

  // --- Eksene yapışma parametreleri ---
  double _snapAngleDeg = 15.0; // eksene ± açı eşiği
  int _snapIntThreshold = 2;   // çok küçük değerleri 0'la (±2)

  // ===== UI Alanı =====
  double _areaFraction = 0.78; // kısa kenarın %78'i kadar kare alan

  @override
  void initState() {
    super.initState();
    _bindUdp();
    _startHeartbeat();
  }

  Future<void> _bindUdp() async {
    try {
      _udp = await RawDatagramSocket.bind(InternetAddress.anyIPv4, 0);
      _udpReady = true;
    } catch (e) {
      _udpReady = false;
      debugPrint('UDP bind hatası: $e');
    }
    if (mounted) setState(() {});
  }

  void _startHeartbeat() {
    _sendTimer?.cancel();
    _sendTimer = Timer.periodic(Duration(milliseconds: (1000 / _sendHz).round()), (_) {
      _sendPacket();
    });
  }

  void _stopHeartbeat() {
    _sendTimer?.cancel();
    _sendTimer = null;
  }

  @override
  void dispose() {
    // Emniyet: bırakırken STOP gönder.
    _forward = 0;
    _turn = 0;
    _sendPacket();
    _stopHeartbeat();
    _udp?.close();
    super.dispose();
  }

  // ===== Joystick Hesabı =====
  void _onPanStart(Offset localPos) {
    setState(() {
      _active = true;
      _origin = localPos;
      _point = localPos;
    });
    _recomputeFromTouch();
  }

  void _onPanUpdate(Offset localPos) {
    setState(() {
      _point = localPos;
    });
    _recomputeFromTouch();
  }

  void _onPanEnd() {
    setState(() {
      _active = false;
      _origin = null;
      _point = null;
      _forward = 0;
      _turn = 0;
    });
  }

  void _recomputeFromTouch() {
    if (!_active || _origin == null || _point == null) {
      _forward = 0;
      _turn = 0;
      return;
    }
    final dx = _point!.dx - _origin!.dx;
    final dy = _point!.dy - _origin!.dy;

    final vec = Offset(dx, dy);
    final dist = vec.distance;

    // menzile sınırla
    final clamped = dist > _maxRadius
        ? _origin! + (vec / (dist == 0 ? 1 : dist)) * _maxRadius
        : _point!;
    final ddx = clamped.dx - _origin!.dx;
    final ddy = clamped.dy - _origin!.dy;

    // ölü bölge
    final mag = sqrt(ddx * ddx + ddy * ddy);
    if (mag < _deadZone) {
      _forward = 0;
      _turn = 0;
      return;
    }

    // normalize [-1..1]
    double nx = (ddx / _maxRadius).clamp(-1.0, 1.0);
    double ny = (ddy / _maxRadius).clamp(-1.0, 1.0);

    // Ekranda +y aşağı -> ileri = -ny, sağa dönüş = +nx
    double f = -ny;
    double t = nx;

    // Expo (merkezde yumuşaklık)
    f = (1 - _expo) * f + _expo * f * f * f;
    t = (1 - _expo) * t + _expo * t * t * t;

    // --- Eksene yapışma (snap-to-axis) ---
    final af = f.abs();
    final at = t.abs();
    final snapTan = tan(_snapAngleDeg * pi / 180.0);

    // Yataya yakınsa (saf dönüş)
    if (af < at * snapTan) {
      f = 0.0;
    }
    // Dikiye yakınsa (saf ileri/geri)
    else if (at < af * snapTan) {
      t = 0.0;
    }

    // Tamsayı + küçükleri 0
    int fInt = (f * 100).round();
    int tInt = (t * 100).round();
    if (fInt.abs() <= _snapIntThreshold) fInt = 0;
    if (tInt.abs() <= _snapIntThreshold) tInt = 0;

    _forward = fInt.clamp(-100, 100);
    _turn = tInt.clamp(-100, 100);
  }

  // ===== UDP Gönderimi =====
  void _sendPacket() {
    if (!_udpReady || _udp == null) return;

    final payload = {
      "ts": DateTime.now().millisecondsSinceEpoch,
      "joystick_forward": _forward,
      "joystick_turn": _turn,
      "brush1": _brush1,
      "brush2": _brush2,
    };

    try {
      final bytes = utf8.encode(jsonEncode(payload));
      _udp!.send(bytes, InternetAddress(_targetIP), _targetPort);
    } catch (e) {
      debugPrint('UDP send hatası: $e');
    }
  }

  // ===== UI =====
  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false, // geri butonu yok
        title: const Text('Tek Joystick (Modbus Node Uyumlu)'),
        centerTitle: true,
        actions: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12.0),
            child: Center(
              child: Row(
                children: [
                  _udpReady
                      ? const Icon(Icons.wifi_tethering, size: 18)
                      : const Icon(Icons.portable_wifi_off, size: 18),
                  const SizedBox(width: 6),
                  Text(_udpReady ? 'UDP Hazır' : 'UDP Yok',
                      style: theme.textTheme.bodyMedium),
                ],
              ),
            ),
          ),
        ],
      ),
      drawer: Drawer( // diğer sayfalardaki menüyle aynı olmalı
        child: ListView(
          padding: EdgeInsets.zero,
          children: const [
            DrawerHeader(
              decoration: BoxDecoration(color: Colors.blue),
              child: Text('Menü'),
            ),
            // menü öğelerini buraya ekle
          ],
        ),
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          final shortSide = min(constraints.maxWidth, constraints.maxHeight);
          final areaSize = shortSide * _areaFraction;
          final area = Size(areaSize, areaSize);
          final areaOffset = Offset(
            (constraints.maxWidth - area.width) / 2,
            (constraints.maxHeight - area.height) / 2,
          );

          return Stack(
            children: [
              Positioned(
                left: areaOffset.dx,
                top: areaOffset.dy,
                width: area.width,
                height: area.height,
                child: _buildJoystickArea(theme),
              ),
              Positioned(
                right: 12,
                top: 12,
                child: _buildBrushPanel(theme),
              ),
              Positioned(
                left: 12,
                bottom: 12,
                child: _buildTelemetry(theme),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildJoystickArea(ThemeData theme) {
    return LayoutBuilder(
      builder: (context, c) {
        final boxSize = Size(c.maxWidth, c.maxHeight);
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanStart: (d) => _onPanStart(d.localPosition),
          onPanUpdate: (d) => _onPanUpdate(d.localPosition),
          onPanEnd: (_) => _onPanEnd(),
          onPanCancel: _onPanEnd,
          child: CustomPaint(
            painter: _AreaPainter(),
            child: Stack(
              children: [
                if (_active && _origin != null)
                  CustomPaint(
                    painter: _JoystickPainter(
                      origin: _origin!,
                      point: _point ?? _origin!,
                      radius: _maxRadius,
                    ),
                    size: boxSize,
                  ),
                IgnorePointer(
                  ignoring: true,
                  child: Center(
                    child: Container(
                      width: 4,
                      height: 4,
                      decoration: BoxDecoration(
                        color: Colors.white.withOpacity(0.6),
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildBrushPanel(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface.withOpacity(0.9),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.black.withOpacity(0.12)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('Fırçalar', style: theme.textTheme.titleSmall),
          const SizedBox(height: 8),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Brush 1'),
              Switch(
                value: _brush1 == 1,
                onChanged: (v) {
                  setState(() => _brush1 = v ? 1 : 0);
                },
              ),
            ],
          ),
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text('Brush 2'),
              Switch(
                value: _brush2 == 1,
                onChanged: (v) {
                  setState(() => _brush2 = v ? 1 : 0);
                },
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildTelemetry(ThemeData theme) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: theme.colorScheme.surface.withOpacity(0.9),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.black.withOpacity(0.12)),
      ),
      child: DefaultTextStyle(
        style: theme.textTheme.bodyMedium!,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('F: '),
            Text('$_forward'),
            const SizedBox(width: 12),
            const Text('T: '),
            Text('$_turn'),
            const SizedBox(width: 12),
            const Text('B1: '),
            Text('$_brush1'),
            const SizedBox(width: 12),
            const Text('B2: '),
            Text('$_brush2'),
          ],
        ),
      ),
    );
  }
}

class _AreaPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final bg = Paint()
      ..color = const Color(0xFFE0B800).withOpacity(0.12);
    final border = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3
      ..color = const Color(0xFFE0B800).withOpacity(0.85);
    final rect = RRect.fromRectAndRadius(Offset.zero & size, const Radius.circular(18));
    canvas.drawRRect(rect, bg);

    final grid = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1
      ..color = const Color(0xFFE0B800).withOpacity(0.35);
    const step = 32.0;
    for (double x = step; x < size.width; x += step) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), grid);
    }
    for (double y = step; y < size.height; y += step) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }

    canvas.drawRRect(rect, border);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class _JoystickPainter extends CustomPainter {
  final Offset origin;
  final Offset point;
  final double radius;

  _JoystickPainter({
    required this.origin,
    required this.point,
    required this.radius,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final centerPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2
      ..color = Colors.white.withOpacity(0.9);
    final ringPaint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.5
      ..color = Colors.white.withOpacity(0.55);
    final fillPaint = Paint()
      ..style = PaintingStyle.fill
      ..color = Colors.white.withOpacity(0.18);

    canvas.drawCircle(origin, radius, ringPaint);
    canvas.drawLine(origin, point, centerPaint);
    canvas.drawCircle(point, 22, fillPaint);
    canvas.drawCircle(point, 22, centerPaint);
  }

  @override
  bool shouldRepaint(covariant _JoystickPainter oldDelegate) {
    return oldDelegate.origin != origin ||
        oldDelegate.point != point ||
        oldDelegate.radius != radius;
  }
}
