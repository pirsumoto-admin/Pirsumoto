import 'dart:convert';
import 'package:http/http.dart' as http;

class VehicleDataService {
  static const String _apiUrl =
      'https://data.gov.il/api/3/action/datastore_search';
  static const String _resourceId = '053cea08-09bc-40ec-8f7a-156f0677aff3';

  /// Fetch vehicle information by license plate number (Israeli data.gov.il API)
  static Future<Map<String, dynamic>?> fetchVehicleData(
    String licensePlate,
  ) async {
    try {
      final cleanedPlate = licensePlate.replaceAll(RegExp(r'[^0-9]'), '');
      if (cleanedPlate.isEmpty || cleanedPlate.length < 7) return null;

      final url =
          '$_apiUrl?resource_id=$_resourceId&filters=%7B%22mispar_rechev%22%3A%5B$cleanedPlate%5D%7D';
      final response = await http
          .get(Uri.parse(url), headers: {'Accept': 'application/json'})
          .timeout(const Duration(seconds: 15));

      if (response.statusCode != 200) return null;

      final data = jsonDecode(response.body);
      final records = data?['result']?['records'] as List?;
      if (records == null || records.isEmpty) return null;

      final vehicle = records[0] as Map<String, dynamic>;

      return {
        'maker': vehicle['tozeret_nm']?.toString() ?? '',
        'model':
            vehicle['kinuy_mishari']?.toString() ??
            vehicle['degem_nm']?.toString() ??
            '',
        'year': vehicle['shnat_yitzur']?.toString() ?? '',
        'color': vehicle['tzeva_rechev']?.toString() ?? '',
        'fuelType': vehicle['sug_delek_nm']?.toString() ?? '',
        'ownership': _mapOwnershipType(vehicle['baalut']?.toString() ?? ''),
        'registrationMonth': _registrationMonth(
          vehicle['moed_aliya_lakvish'] ?? '',
        ),
        'testExpiry': _formatTestDate(vehicle['tokef_dt']?.toString() ?? ''),
        'lastTestDate': vehicle['mivchan_acharon_dt']?.toString() ?? '',
        'tokef_dt': vehicle['tokef_dt']?.toString() ?? '',
        'moed_aliya_lakvish': vehicle['moed_aliya_lakvish']?.toString() ?? '',
        'shnat_yitzur': vehicle['shnat_yitzur']?.toString() ?? '',
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

  static String _registrationMonth(Object rawValue) {
    final value = rawValue.toString().trim();
    if (value.isEmpty) return '';
    final match = RegExp(r'^(\d{4})[-/](\d{1,2})').firstMatch(value);
    if (match != null) {
      final month = int.tryParse(match.group(2) ?? '');
      if (month != null && month >= 1 && month <= 12) return '$month';
    }
    final compactMatch = RegExp(r'^(\d{4})(\d{2})$').firstMatch(value);
    if (compactMatch != null) {
      final month = int.tryParse(compactMatch.group(2) ?? '');
      if (month != null && month >= 1 && month <= 12) return '$month';
    }
    return '';
  }
}
