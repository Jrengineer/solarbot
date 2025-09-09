import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';

/// Jetson ile TCP+UDP batarya haberleşmesi
/// Stabilite: hysteresis, tcpNoDelay, exponential backoff, watchdog
class BatteryClient {
  BatteryClient._internal();
  static final BatteryClient instance = BatteryClient._internal();

  // Jetson/UDP/TCP
  final String jetsonIp = '192.168.1.130';
  final int tcpPort = 5001;
  final int udpPort = 8890;

  RawDatagramSocket? _udpSocket;
  Socket? _tcpSocket;

  // Yayın: batarya JSON
  final _batteryCtrl = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get batteryStream => _batteryCtrl.stream;

  // Bağlantı durumu (UI için)
  final ValueNotifier<bool> isConnected = ValueNotifier<bool>(false);

  // Heartbeat & watchdog
  Timer? _heartbeatTimer;
  Timer? _watchdogTimer;
  DateTime? _lastOkWriteAt;
  int _consecutiveWriteErrors = 0;

  // Tek seferlik başlatma koruması
  bool _starting = false;
  bool _started = false;

  // Backoff
  int _reconnectAttempt = 0;
  final List<Duration> _backoffSeq = const [
    Duration(seconds: 1),
    Duration(seconds: 2),
    Duration(seconds: 4),
    Duration(seconds: 8),
    Duration(seconds: 8),
  ];

  // Histerezis/pencere — kısa kopmalarda kırmızıya düşmeyi geciktir
  final Duration _offlineGrace = const Duration(seconds: 6);

  Future<void> ensureStarted() async {
    if (_started) return;
    if (_starting) return;
    _starting = true;
    try {
      await _startUdp();
      unawaited(_connectTcp());
      _started = true;
    } finally {
      _starting = false;
    }
  }

  Future<void> _startUdp() async {
    if (_udpSocket != null) return;
    _udpSocket = await RawDatagramSocket.bind(InternetAddress.anyIPv4, udpPort);
    _udpSocket!.listen((event) {
      if (event == RawSocketEvent.read) {
        final dg = _udpSocket!.receive();
        if (dg == null) return;
        try {
          final jsonStr = utf8.decode(dg.data);
          final data = jsonDecode(jsonStr) as Map<String, dynamic>;
          _batteryCtrl.add(data);
        } catch (_) {
          // parse hatasını yut
        }
      }
    });
  }

  Future<void> _connectTcp() async {
    if (_tcpSocket != null) return;
    try {
      final sock = await Socket.connect(
        jetsonIp,
        tcpPort,
        timeout: const Duration(seconds: 3),
      );

      // tcpNoDelay (Nagle kapalı)
      try {
        sock.setOption(SocketOption.tcpNoDelay, true);
      } catch (_) {}

      _tcpSocket = sock;
      _reconnectAttempt = 0;
      _consecutiveWriteErrors = 0;
      _lastOkWriteAt = DateTime.now();

      await _sendUdpPortLine();
      // Soket kapandığında veya hata olduğunda yeniden bağlan
      sock.listen(
        (_) {},
        onError: (_) => _handleTcpDrop(),
        onDone: _handleTcpDrop,
        cancelOnError: true,
      );

      _heartbeatTimer?.cancel();
      _heartbeatTimer = Timer.periodic(const Duration(seconds: 2), (t) async {
        await _sendHeartbeat();
      });

      _watchdogTimer?.cancel();
      _watchdogTimer = Timer.periodic(const Duration(seconds: 1), (t) {
        _evaluateConnectionAlive();
      });

      _setConnected(true);
    } catch (_) {
      _scheduleReconnect();
    }
  }

  Future<void> _sendUdpPortLine() async {
    try {
      _tcpSocket?.write('UDPPORT:$udpPort\n');
      await _tcpSocket?.flush();
      _lastOkWriteAt = DateTime.now();
      _consecutiveWriteErrors = 0;
    } catch (_) {
      _noteWriteError();
    }
  }

  Future<void> _sendHeartbeat() async {
    try {
      _tcpSocket?.write('1'); // tek byte ping
      await _tcpSocket?.flush();
      _lastOkWriteAt = DateTime.now();
      _consecutiveWriteErrors = 0;
    } catch (_) {
      _noteWriteError();
    }
  }

  void _noteWriteError() {
    _consecutiveWriteErrors++;
    // Tek hatada düşürme — 3 ardışık hatada bağlantıyı kopar
    if (_consecutiveWriteErrors >= 3) {
      _handleTcpDrop();
    }
  }

  void _evaluateConnectionAlive() {
    if (_tcpSocket == null) {
      _setConnected(false);
      return;
    }
    final last = _lastOkWriteAt;
    if (last == null) return;
    final elapsed = DateTime.now().difference(last);
    if (elapsed > _offlineGrace) {
      _handleTcpDrop();
    } else {
      _setConnected(true);
    }
  }

  void _scheduleReconnect() {
    final delay = _backoffSeq[
    (_reconnectAttempt < _backoffSeq.length)
        ? _reconnectAttempt
        : (_backoffSeq.length - 1)
    ];
    _reconnectAttempt++;
    Future.delayed(delay, _connectTcp);
  }

  void _handleTcpDrop() {
    _setConnected(false);

    _heartbeatTimer?.cancel();
    _heartbeatTimer = null;

    _watchdogTimer?.cancel();
    _watchdogTimer = null;

    try {
      _tcpSocket?.destroy();
    } catch (_) {}
    _tcpSocket = null;

    _scheduleReconnect();
  }

  void _setConnected(bool v) {
    if (isConnected.value != v) {
      isConnected.value = v;
    }
  }

  Future<void> dispose() async {
    _heartbeatTimer?.cancel();
    _watchdogTimer?.cancel();
    try {
      _tcpSocket?.destroy();
    } catch (_) {}
    try {
      _udpSocket?.close();
    } catch (_) {}
    await _batteryCtrl.close();
  }
}
