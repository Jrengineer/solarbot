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

  @override
  void initState() {
    super.initState();
    _fetchMap();
  }

  Future<void> _fetchMap() async {
    try {
      final response = await http.get(Uri.parse('http://192.168.1.2:8000/map'));
      if (response.statusCode == 200) {
        setState(() {
          _mapBytes = response.bodyBytes;
        });
      }
    } catch (e) {
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
                child: _mapBytes == null
                    ? const Text('Harita yükleniyor...')
                    : Image.memory(_mapBytes!),
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

