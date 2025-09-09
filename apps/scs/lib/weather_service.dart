import 'dart:convert';
import 'package:http/http.dart' as http;

class WeatherService {
  static const String _apiKey = '1cea73639e76dc04cd4d437e045b07ff';
  static const String _baseUrl = 'https://api.openweathermap.org/data/2.5';

  static Future<Map<String, dynamic>?> fetchCurrentWeather(String city) async {
    try {
      final response = await http.get(Uri.parse(
          '$_baseUrl/weather?q=$city&appid=$_apiKey&units=metric&lang=tr'));
      if (response.statusCode == 200) {
        return jsonDecode(response.body);
      } else {
        print('Current weather API error: ${response.statusCode}');
        return null;
      }
    } catch (e) {
      print('Current weather fetch error: $e');
      return null;
    }
  }

  static Future<Map<String, dynamic>?> fetchForecastWeather(String city) async {
    try {
      final response = await http.get(Uri.parse(
          '$_baseUrl/forecast?q=$city&appid=$_apiKey&units=metric&lang=tr'));
      if (response.statusCode == 200) {
        return jsonDecode(response.body);
      } else {
        print('Forecast weather API error: ${response.statusCode}');
        return null;
      }
    } catch (e) {
      print('Forecast weather fetch error: $e');
      return null;
    }
  }
}
