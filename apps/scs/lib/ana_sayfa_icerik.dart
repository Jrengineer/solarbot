import 'package:flutter/material.dart';
import 'weather_service.dart';
import 'city_selection.dart';
import 'package:intl/intl.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'dart:async';
import 'battery_client.dart';

class AnaSayfaIcerik extends StatefulWidget {
  const AnaSayfaIcerik({super.key});

  @override
  State<AnaSayfaIcerik> createState() => _AnaSayfaIcerikState();
}

class _AnaSayfaIcerikState extends State<AnaSayfaIcerik> {
  String _city = 'Eskişehir';
  Map<String, dynamic>? _forecastWeather;
  bool _isLoading = true;

  Map<String, dynamic>? _batteryData;
  StreamSubscription? _batterySub;

  @override
  void initState() {
    super.initState();
    initializeDateFormatting('tr_TR', null).then((_) {
      _fetchWeather();
    });

    // Servisi başlat ve stream'e abone ol
    BatteryClient.instance.ensureStarted();
    _batterySub = BatteryClient.instance.batteryStream.listen((data) {
      if (mounted) setState(() => _batteryData = data);
    });
  }

  Future<void> _fetchWeather() async {
    setState(() => _isLoading = true);
    final forecast = await WeatherService.fetchForecastWeather(_city);
    setState(() {
      _forecastWeather = forecast;
      _isLoading = false;
    });
  }

  void _selectCity() async {
    final selectedCity = await Navigator.push(
      context,
      MaterialPageRoute(builder: (context) => const CitySelectionPage()),
    );
    if (selectedCity != null) {
      setState(() => _city = selectedCity);
      _fetchWeather();
    }
  }

  @override
  void dispose() {
    _batterySub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return _isLoading
        ? const Center(child: CircularProgressIndicator())
        : _buildWeatherContent();
  }

  Widget _buildWeatherContent() {
    if (_forecastWeather == null) {
      return const Center(child: Text('Veri alınamadı'));
    }

    final forecastList = _forecastWeather!['list'] as List<dynamic>;

    return Padding(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        children: [
          const SizedBox(height: 10),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                '📍 $_city',
                style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
              ),
              IconButton(
                icon: const Icon(Icons.location_city),
                onPressed: _selectCity,
              ),
            ],
          ),
          const SizedBox(height: 20),
          SizedBox(
            height: 200,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: 5,
              itemBuilder: (context, index) {
                final weatherData = forecastList[index * 8];
                final date = DateTime.now().add(Duration(days: index));
                final formattedDate = DateFormat('EEEE, dd MMMM', 'tr_TR').format(date);

                return Container(
                  width: 150,
                  margin: const EdgeInsets.symmetric(horizontal: 8),
                  decoration: BoxDecoration(
                    color: Colors.blueGrey[800],
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Text(
                        formattedDate,
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 10),
                      Image.network(
                        'https://openweathermap.org/img/wn/${weatherData['weather'][0]['icon']}@2x.png',
                        width: 70,
                        height: 70,
                      ),
                      const SizedBox(height: 10),
                      Text(
                        '${weatherData['main']['temp'].toStringAsFixed(0)}°C',
                        style: const TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(height: 5),
                      Text(
                        weatherData['weather'][0]['description'],
                        textAlign: TextAlign.center,
                        style: const TextStyle(fontSize: 14),
                      ),
                    ],
                  ),
                );
              },
            ),
          ),
          const SizedBox(height: 30),

          // Batarya bilgileri
          if (_batteryData != null)
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Colors.green[800],
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                children: [
                  const Text(
                    "🔋 Batarya Durumu",
                    style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold),
                  ),
                  const SizedBox(height: 10),
                  Text("Voltaj: ${_batteryData!['voltage_v'] ?? '-'} V"),
                  Text("Akım: ${_batteryData!['current_a'] ?? '-'} A"),
                  Text("Doluluk: ${_batteryData!['soc_pct'] ?? '-'} %"),
                  Text("Kalan süre: ${_batteryData!['runtime_str'] ?? '-'}"),
                  if (_batteryData!['temps_c'] != null &&
                      (_batteryData!['temps_c'] as List).isNotEmpty)
                    Text("Sıcaklıklar: ${(_batteryData!['temps_c'] as List).join(', ')} °C"),
                ],
              ),
            )
          else
            const Text("Batarya verisi bekleniyor...", style: TextStyle(fontSize: 16)),
        ],
      ),
    );
  }
}
