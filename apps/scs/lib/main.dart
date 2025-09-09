import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'camera_service.dart';
import 'ana_sayfa.dart';
import 'tek_joystick_spawn.dart'; // Tek joystick sayfası
import 'otonom.dart';

void main() {
  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => CameraService()),
      ],
      child: const MyApp(),
    ),
  );
}

class MyApp extends StatelessWidget {
  const MyApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      title: 'SCS App',
      theme: ThemeData.dark(),
      home: const AnaSayfa(),
      routes: {
        '/tek-joystick-spawn': (context) => const TekJoystickSpawnPage(),
        '/otonom': (context) => const OtonomPage(),
      },
    );
  }
}
