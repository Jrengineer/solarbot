import 'package:flutter/material.dart';

class OtonomPage extends StatefulWidget {
  const OtonomPage({super.key});

  @override
  State<OtonomPage> createState() => _OtonomPageState();
}

class _OtonomPageState extends State<OtonomPage> {
  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('Otonom')),
      body: Column(
        children: [
          Expanded(
            child: Container(
              color: Colors.black12,
              child: const Center(
                child: Text('Harita / Kamera görüntüsü burada'),
              ),
            ),
          ),
          ElevatedButton(
            onPressed: () {
              // Örneğin harita üzerindeki bir noktayı ROS'a hedef olarak gönderme.
            },
            child: const Text('Hedef Gönder'),
          ),
        ],
      ),
    );
  }
}

