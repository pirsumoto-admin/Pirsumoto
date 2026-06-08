import 'dart:convert';
import 'package:http/http.dart' as http;

class VehicleDataService {
  static const String _apiUrl =
      'https://data.gov.il/api/3/action/datastore_search';
  static const String _resourceId = '053cea08-09bc-40ec-8f7a-156f0677aff3';

  /// Fetch vehicle information by license plate number (Israeli data.gov.il API)
  static Future<Map<String, dynamic>?> fetchVehicleData(
      String licensePlate) async {
    try {
      final cleanedPlate =
          licensePlate.replaceAll(RegExp(r'[^0-9]'), '');
      if (cleanedPlate.isEmpty || cleanedPlate.length < 7) return null;

      final response = await http.post(
        Uri.parse(_apiUrl),
        headers: {
          'Content-Type': 'application/json',
          'Accept': '*/*',
        },
        body: jsonEncode({
          'resource_id': _resourceId,
          'q': '',
          'filters': {
            'mispar_rechev': [cleanedPlate],
            'not_count_request': '0',
          },
          'limit': 1,
          'offset': 0,
          'sort': 'baalut asc',
        }),
      );

      if (response.statusCode != 200) return null;

      final data = jsonDecode(response.body);
      final records = data?['result']?['records'] as List?;
      if (records == null || records.isEmpty) return null;

      final vehicle = records[0] as Map<String, dynamic>;

      return {
        'maker': vehicle['tozeret_nm'] ?? '',
        'model': vehicle['kinuy_mishari'] ?? '',
        'year': vehicle['shnat_yitzur']?.toString() ?? '',
        'color': vehicle['tzeva_rechev'] ?? '',
        'fuelType': vehicle['sug_delek_nm'] ?? '',
        'ownership': _mapOwnershipType(vehicle['baalut'] ?? ''),
        'testExpiry': _formatTestDate(vehicle['tokef_dt'] ?? ''),
      };
    } catch (e) {
      return null;
    }
  }

  static String _mapOwnershipType(String hebrewOwnership) {
    const map = {
      'פרטי': 'פרטי',
      'חברה': 'חברה',
      'השכרה': 'השכרה',
      'ליסינג': 'ליסינג',
      'מונית': 'מונית',
      'לימוד נהיגה': 'לימוד נהיגה',
      'ייבוא אישי': 'ייבוא אישי',
      'ייבוא מקביל': 'ייבוא מקביל',
      'ממשלתי': 'ממשלתי',
      'או"ם': 'או"ם',
    };
    return map[hebrewOwnership] ?? hebrewOwnership;
  }

  /// Convert YYYY-MM-DD to MM,YYYY format
  static String _formatTestDate(String dateString) {
    if (dateString.isEmpty) return '';
    try {
      final parts = dateString.split('-');
      if (parts.length == 3) return '${parts[1]},${parts[0]}';
      return '';
    } catch (_) {
      return '';
    }
  }
}
