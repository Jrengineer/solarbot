import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:provider/provider.dart';

import 'camera_service.dart';

/// Otonom sayfası artık harita yerine insan takibiyle ilgili kamera
/// görüntüsünü gösterir. Gelen JSON içinde insanın konumu ve robotun mevcut
/// durumu bulunur. İnsan tespit edildiğinde kırmızı bir kare ile vurgulanır.
class OtonomPage extends StatefulWidget {
  const OtonomPage({super.key});

  @override
  State<OtonomPage> createState() => _OtonomPageState();
}

class _OtonomPageState extends State<OtonomPage> {
  Rect? _personBox; // 0-1 aralığında normalize koordinatlar
  String _status = '';
  Timer? _infoTimer;
  bool _trackingEnabled = true;

  @override
  void initState() {
    super.initState();
    _infoTimer =
        Timer.periodic(const Duration(milliseconds: 500), (_) => _fetchInfo());
  }

  Future<void> _fetchInfo() async {
    if (!_trackingEnabled) return;
    try {
      final res = await http
          .get(Uri.parse('http://192.168.1.130:8000/person_tracking'))
          .timeout(const Duration(seconds: 2));
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        final box = data['box'];
        setState(() {
          if (box is Map) {
            _personBox = Rect.fromLTWH(
              (box['x'] as num).toDouble(),
              (box['y'] as num).toDouble(),
              (box['w'] as num).toDouble(),
              (box['h'] as num).toDouble(),
            );
          } else {
            _personBox = null;
          }
          _status = data['status']?.toString() ?? '';
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _personBox = null;
        _status = 'Bilgi alınamadı';
      });
    }
  }

  Future<void> _setTracking(bool enabled) async {
    setState(() {
      _trackingEnabled = enabled;
      if (!enabled) {
        _personBox = null;
        _status = '';
      }
    });
    try {
      await http.get(Uri.parse(
          'http://192.168.1.130:8000/person_tracking_mode?enable=${enabled ? 1 : 0}'));
    } catch (_) {}
  }

  @override
  void dispose() {
    _infoTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final cameraService = Provider.of<CameraService>(context);

    return Scaffold(
      appBar: AppBar(title: const Text('Otonom')),
      body: Column(
        children: [
          Expanded(
            child: Center(
              child: cameraService.imageBytes != null
                  ? LayoutBuilder(
                      builder: (context, constraints) {
                        final w = constraints.maxWidth;
                        final h = constraints.maxHeight;
                        return Stack(
                          children: [
                            Positioned.fill(
                              child: Image.memory(
                                cameraService.imageBytes!,
                                gaplessPlayback: true,
                                fit: BoxFit.contain,
                              ),
                            ),
                            if (_personBox != null)
                              Positioned(
                                left: _personBox!.left * w,
                                top: _personBox!.top * h,
                                width: _personBox!.width * w,
                                height: _personBox!.height * h,
                                child: Container(
                                  decoration: BoxDecoration(
                                    border: Border.all(
                                        color: Colors.red, width: 3),
                                  ),
                                ),
                              ),
                          ],
                        );
                      },
                    )
                  : const CircularProgressIndicator(),
            ),
          ),
          Padding(
            padding: const EdgeInsets.all(8.0),
            child: Text('Durum: $_status'),
          ),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              const Text('İnsan Takibi'),
              Switch(
                value: _trackingEnabled,
                onChanged: _setTracking,
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(bottom: 8.0),
            child: Text(
                'FPS: ${cameraService.fps}   Gecikme: ${cameraService.latencyMs} ms'),
          ),
        ],
      ),
    );
  }
}

