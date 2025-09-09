import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

class OtonomPage extends StatefulWidget {
  const OtonomPage({super.key});

  @override
  State<OtonomPage> createState() => _OtonomPageState();
}

class _OtonomPageState extends State<OtonomPage> {
  Uint8List? _mapBytes;
  bool _mapError = false;
  Timer? _mapTimer;

  @override
  void initState() {
    super.initState();
    _fetchMap();
    _mapTimer =
        Timer.periodic(const Duration(seconds: 2), (_) => _fetchMap());
  }

  @override
  void dispose() {
    _mapTimer?.cancel();
    super.dispose();
  }

  Future<void> _fetchMap() async {
    try {
      final response = await http.get(Uri.parse('http://192.168.1.2:8000/map'));
      if (response.statusCode == 200) {
        setState(() {
          _mapBytes = response.bodyBytes;
          _mapError = false;
        });
      } else {
        setState(() {
          _mapError = true;
        });
      }
    } catch (e) {
      setState(() {
        _mapError = true;
      });
      // ignore: avoid_print
      print('Map fetch failed: $e');
    }
  }

  Future<void> _sendGoal(Offset pos) async {
    final body = '${pos.dx},${pos.dy}';
    try {
      await http.post(Uri.parse('http://192.168.1.2:8000/goal'), body: body);
    } catch (e) {
      // ignore: avoid_print
      print('Goal send failed: $e');
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Otonom')),
      body: Column(
        children: [
          Expanded(
            child: GestureDetector(
              onTapDown: (details) => _sendGoal(details.localPosition),
              child: Container(
                color: Colors.black12,
                alignment: Alignment.center,
                child: _mapBytes != null
                    ? Image.memory(_mapBytes!)
                    : _mapError
                        ? const Text('Harita yüklenemedi')
                        : const CircularProgressIndicator(),
              ),
            ),
          ),
          ElevatedButton(
            onPressed: _fetchMap,
            child: const Text('Haritayı Güncelle'),
          ),
        ],
      ),
    );
  }
}

