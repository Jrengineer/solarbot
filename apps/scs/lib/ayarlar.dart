import 'package:flutter/material.dart';

class Ayarlar extends StatelessWidget {
  const Ayarlar({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Ayarlar'),
      ),
      body: const Center(
        child: Text(
          'Ayarlar Sayfası',
          style: TextStyle(fontSize: 24),
        ),
      ),
    );
  }
}
