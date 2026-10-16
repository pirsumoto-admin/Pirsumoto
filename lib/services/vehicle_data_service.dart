import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

/// Service to query the Israeli Government open data API (data.gov.il)
/// using the 3 existing government datasets:
/// 1. Main vehicle registry (`053cea08-09bc-40ec-8f7a-156f0677aff3`)
/// 2. Model & gear specs (`142afde2-6228-49f9-8a29-9b6c3a0cbe40`)
/// 3. Periodic test & mileage history (`56063a99-8a3e-4ff4-912e-5966c0279bad`)
class VehicleDataService {
  static const String _apiUrl =
      'https://data.gov.il/api/3/action/datastore_search';
  static const String _resourceId = '053cea08-09bc-40ec-8f7a-156f0677aff3';
  static const String _gearResourceId = '142afde2-6228-49f9-8a29-9b6c3a0cbe40';
  static const String _testHistoryResourceId =
      '56063a99-8a3e-4ff4-912e-5966c0279bad';

  /// Fetch vehicle information aggregated from all 3 data.gov.il sources
  static Future<Map<String, dynamic>?> fetchVehicleData(
    String licensePlate,
  ) async {
    try {
      final cleanedPlate = licensePlate.replaceAll(RegExp(r'[^0-9]'), '');
      if (cleanedPlate.isEmpty || cleanedPlate.length < 7) return null;

      // 1. Fetch main vehicle info from 053cea08
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

      // Concurrently fetch gear (142afde2) and last test kilometer (56063a99)
      final gearFuture = _fetchGearType(vehicle);
      final kmFuture = _fetchKilometerTestAharon(cleanedPlate);

      final gear = await gearFuture;
      final rawKmTest = await kmFuture;

      final year = vehicle['shnat_yitzur']?.toString() ?? '';
      final moedAliya = vehicle['moed_aliya_lakvish']?.toString() ?? '';
      final regMonth = _registrationMonth(moedAliya);
      final tokefDt = vehicle['tokef_dt']?.toString() ?? '';
      final lastTestDate = vehicle['mivchan_acharon_dt']?.toString() ?? '';
      final ownership = _mapOwnershipType(vehicle['baalut']?.toString() ?? '');

      // Parse test month and test year
      String testMonth = '';
      String testYear = '';
      if (tokefDt.contains('-')) {
        final parts = tokefDt.split('-');
        if (parts.length >= 2) {
          testYear = parts[0];
          testMonth = int.tryParse(parts[1])?.toString() ?? parts[1];
        }
      }

      int? estimatedKm;
      if (rawKmTest != null && rawKmTest > 0) {
        estimatedKm = calculateEstimatedKm(
          rawKm: rawKmTest,
          lastTestDate: lastTestDate.isNotEmpty ? lastTestDate : null,
          tokefDt: tokefDt.isNotEmpty ? tokefDt : null,
          testMonth: testMonth.isNotEmpty ? testMonth : null,
          testYear: testYear.isNotEmpty ? testYear : null,
          moedAliya: moedAliya.isNotEmpty ? moedAliya : null,
          shnatYitzur: year.isNotEmpty ? year : null,
          registrationMonth: regMonth.isNotEmpty ? regMonth : null,
        );
      }

      return {
        'license_plate': cleanedPlate,
        'maker': vehicle['tozeret_nm']?.toString() ?? '',
        'model':
            vehicle['kinuy_mishari']?.toString() ??
            vehicle['degem_nm']?.toString() ??
            '',
        'year': year,
        'color': vehicle['tzeva_rechev']?.toString() ?? '',
        'fuelType': vehicle['sug_delek_nm']?.toString() ?? '',
        'fuel_type': vehicle['sug_delek_nm']?.toString() ?? '',
        'ownership': ownership,
        'current_ownership': ownership,
        'registrationMonth': regMonth,
        'month': regMonth,
        'testExpiry': _formatTestDate(tokefDt),
        'test_month': testMonth,
        'test_year': testYear,
        'lastTestDate': lastTestDate,
        'tokef_dt': tokefDt,
        'moed_aliya_lakvish': moedAliya,
        'shnat_yitzur': year,
        'gear': gear,
        'gear_type': gear,
        'kilometer_test_aharon': rawKmTest?.toString() ?? '',
        'km':
            estimatedKm != null
                ? estimatedKm.toString()
                : (rawKmTest?.toString() ?? ''),
        'estimatedKm': estimatedKm?.toString() ?? '',
      };
    } catch (e) {
      debugPrint('[VehicleDataService] Error fetching vehicle data: $e');
      return null;
    }
  }

  static Future<String> _fetchGearType(Map<String, dynamic> vehicle) async {
    const defaultGear = 'הילוכים אוטומטיים';
    try {
      final degemNm = vehicle['degem_nm']?.toString() ?? '';
      final tozeret = vehicle['tozeret_cd'];
      final degemcd = vehicle['degem_cd'];
      final sug = vehicle['sug_degem']?.toString() ?? '';
      final yearStr = vehicle['shnat_yitzur']?.toString() ?? '';

      final filtersObj = <String, dynamic>{
        if (degemNm.isNotEmpty) 'degem_nm': degemNm,
        if (tozeret != null && tozeret.toString().isNotEmpty)
          'tozeret_cd': tozeret,
        if (degemcd != null && degemcd.toString().isNotEmpty)
          'degem_cd': degemcd,
        if (sug.isNotEmpty) 'sug_degem': sug,
        if (yearStr.isNotEmpty)
          'shnat_yitzur': int.tryParse(yearStr) ?? yearStr,
      };

      if (filtersObj.isEmpty) return defaultGear;

      final url =
          '$_apiUrl?resource_id=$_gearResourceId&filters=${Uri.encodeComponent(jsonEncode(filtersObj))}';
      final response = await http
          .get(Uri.parse(url), headers: {'Accept': 'application/json'})
          .timeout(const Duration(seconds: 10));

      if (response.statusCode != 200) return defaultGear;

      final decoded = jsonDecode(response.body);
      final records = decoded?['result']?['records'] as List?;
      if (records != null && records.isNotEmpty) {
        final dataGear = records[0] as Map<String, dynamic>;
        final automatic = dataGear['automatic_ind'];
        if (automatic == 0 || automatic == '0') {
          return 'שידור ידני';
        }
        return 'הילוכים אוטומטיים';
      }
      return defaultGear;
    } catch (_) {
      return defaultGear;
    }
  }

  static Future<int?> _fetchKilometerTestAharon(String cleanedPlate) async {
    try {
      final url =
          '$_apiUrl?resource_id=$_testHistoryResourceId&q=$cleanedPlate&offset=0';
      final response = await http
          .get(Uri.parse(url), headers: {'Accept': 'application/json'})
          .timeout(const Duration(seconds: 10));

      if (response.statusCode != 200) return null;

      final decoded = jsonDecode(response.body);
      final records = decoded?['result']?['records'] as List?;
      if (records != null && records.isNotEmpty) {
        final firstRecord = records[0] as Map<String, dynamic>;
        final kmTest = firstRecord['kilometer_test_aharon'];
        if (kmTest != null) {
          if (kmTest is int) return kmTest;
          return int.tryParse(kmTest.toString());
        }
      }
    } catch (_) {}
    return null;
  }

  /// Calculates estimated current kilometers from last test kilometers,
  /// test date, production year/month, and elapsed months.
  static int calculateEstimatedKm({
    required int rawKm,
    dynamic lastTestDate,
    dynamic tokefDt,
    dynamic testMonth,
    dynamic testYear,
    dynamic moedAliya,
    dynamic shnatYitzur,
    dynamic registrationMonth,
    DateTime? now,
  }) {
    DateTime? testDate = _parseGovDate(lastTestDate);
    if (testDate == null) {
      final tokefDate = _parseGovDate(tokefDt);
      if (tokefDate != null) {
        testDate = DateTime(tokefDate.year - 1, tokefDate.month, tokefDate.day);
      }
    }
    if (testDate == null) {
      final tM = int.tryParse(testMonth?.toString() ?? '');
      final tY = int.tryParse(testYear?.toString() ?? '');
      if (tM != null && tY != null) {
        testDate = DateTime(tY - 1, tM, 1);
      }
    }

    int? prodYear;
    int prodMonth = 1;

    final moedStr = moedAliya?.toString().trim() ?? '';
    if (moedStr.contains('-')) {
      final parts = moedStr.split('-');
      if (parts.isNotEmpty) {
        prodYear = int.tryParse(parts[0]);
        if (parts.length >= 2) {
          prodMonth = int.tryParse(parts[1]) ?? 1;
        }
      }
    }

    if (prodYear == null && shnatYitzur != null) {
      prodYear = int.tryParse(shnatYitzur.toString().trim());
    }

    if (prodMonth == 1 && registrationMonth != null) {
      prodMonth = int.tryParse(registrationMonth.toString().trim()) ?? 1;
    }

    if (testDate == null || prodYear == null || prodYear <= 0) {
      return rawKm;
    }

    final tYear = testDate.year;
    final tMonth = testDate.month;

    int totalMonthsUpToTest = (tYear - prodYear) * 12 + (tMonth - prodMonth);
    if (totalMonthsUpToTest <= 0) {
      totalMonthsUpToTest = 1;
    }

    final double avgKmPerMonth = rawKm / totalMonthsUpToTest;

    final currentDate = now ?? DateTime.now();
    final monthsPast =
        (currentDate.year - tYear) * 12 + (currentDate.month - tMonth);

    double addedKm = 0.0;
    if (monthsPast > 0) {
      addedKm = avgKmPerMonth * monthsPast;
    } else if (monthsPast == 0) {
      addedKm = avgKmPerMonth * 0.5;
    } else {
      addedKm = 0.0;
    }

    return (rawKm + addedKm).round();
  }

  static DateTime? _parseGovDate(dynamic rawDate) {
    if (rawDate == null) return null;
    final str = rawDate.toString().trim();
    if (str.isEmpty) return null;

    final parsed = DateTime.tryParse(str);
    if (parsed != null) return parsed;

    if (str.contains('-')) {
      final parts = str.split('-');
      if (parts.length >= 2) {
        if (parts[0].length == 4) {
          final y = int.tryParse(parts[0]);
          final m = int.tryParse(parts[1]);
          final d = parts.length >= 3 ? int.tryParse(parts[2]) : 1;
          if (y != null && m != null) return DateTime(y, m, d ?? 1);
        } else if (parts.length >= 3 && parts[2].length == 4) {
          final y = int.tryParse(parts[2]);
          final m = int.tryParse(parts[1]);
          final d = int.tryParse(parts[0]);
          if (y != null && m != null) return DateTime(y, m, d ?? 1);
        }
      }
    } else if (str.contains('/')) {
      final parts = str.split('/');
      if (parts.length >= 2) {
        if (parts.last.length == 4) {
          final y = int.tryParse(parts.last);
          final m = int.tryParse(parts[1]);
          final d = int.tryParse(parts[0]);
          if (y != null && m != null) return DateTime(y, m, d ?? 1);
        }
      }
    }
    return null;
  }

  static String _mapOwnershipType(String hebrewOwnership) {
    if (hebrewOwnership.trim() == 'סוחר') return '';
    const map = {
      'פרטי': 'פרטית',
      'פרטית': 'פרטית',
      'חברה': 'חברה',
      'השכרה': 'השכרה',
      'ליסינג': 'ליסינג',
      'מונית': 'מונית',
      'לימוד נהיגה': 'לימוד נהיגה',
      'ייבוא אישי': 'ייבוא אישי',
      'ייבוא מקביל': 'ייבוא מקביל',
      'ממשלתי': 'ממשלתי',
      'או"ם': 'או"ם',
      'החכר': 'החכר',
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
