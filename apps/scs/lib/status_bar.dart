import 'package:flutter/material.dart';
import 'battery_client.dart';

class StatusBar extends StatefulWidget {
  const StatusBar({Key? key}) : super(key: key);

  @override
  State<StatusBar> createState() => _StatusBarState();
}

class _StatusBarState extends State<StatusBar> {
  int _soc = 0;

  @override
  void initState() {
    super.initState();
    // Servisi başlat
    BatteryClient.instance.ensureStarted();

    // Batarya streaminden SOC oku
    BatteryClient.instance.batteryStream.listen((data) {
      final soc = (data['soc_pct'] ?? 0);
      final v = (soc is num) ? soc.round() : 0;
      if (mounted) {
        setState(() => _soc = v.clamp(0, 100));
      }
    });
  }

  IconData _batteryIcon(int level) {
    final v = level.clamp(0, 100);
    if (v >= 95) return Icons.battery_full;
    if (v >= 80) return Icons.battery_6_bar;
    if (v >= 65) return Icons.battery_5_bar;
    if (v >= 50) return Icons.battery_4_bar;
    if (v >= 35) return Icons.battery_3_bar;
    if (v >= 20) return Icons.battery_2_bar;
    if (v >= 10) return Icons.battery_1_bar;
    return Icons.battery_alert;
  }

  Color _batteryColor(int level) {
    final v = level.clamp(0, 100);
    if (v >= 50) return Colors.greenAccent.shade400;
    if (v >= 20) return Colors.amberAccent.shade700;
    return Colors.redAccent.shade200;
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<bool>(
      valueListenable: BatteryClient.instance.isConnected,
      builder: (context, connected, _) {
        final col = connected ? Colors.lightBlueAccent : Colors.redAccent;
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: Colors.black.withOpacity(0.15),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(connected ? Icons.wifi : Icons.wifi_off, color: col, size: 20),
              const SizedBox(width: 10),
              Icon(_batteryIcon(_soc), color: _batteryColor(_soc), size: 20),
              const SizedBox(width: 6),
              Text(
                "%$_soc",
                style: TextStyle(
                  fontSize: 13,
                  color: _batteryColor(_soc),
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
