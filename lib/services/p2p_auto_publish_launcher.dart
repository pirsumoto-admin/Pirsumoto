import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../features/publish/yad2_screen.dart';
import '../routing/app_router.dart';
import 'db_service.dart';
import 'yad2_automation_models.dart';

/// Launches Yad2 automated publication from internal P2P chat vehicle data.
class P2PAutoPublishLauncher {
  /// Main entrypoint to launch Yad2 publication from vehicle state map.
  static Future<bool> launch(Map<String, String> data) async {
    try {
      final licensePlate = _firstNonEmpty([
        data['license_plate'],
        data['license'],
      ]);
      debugPrint(
        '[P2PAutoPublish] launch requested for license: $licensePlate',
      );

      // 1. Wake device screen and bring Pirsumoto app to the foreground
      if (Platform.isAndroid) {
        try {
          const MethodChannel('com.pirsumoto/accessibility')
              .invokeMethod('bringAppToForeground');
          debugPrint(
            '[P2PAutoPublish] Invoked bringAppToForeground on accessibility channel',
          );
        } catch (e) {
          debugPrint(
            '[P2PAutoPublish] Failed to invoke bringAppToForeground: $e',
          );
        }
      }

      // 2. Keep screen awake during automation
      try {
        await WakelockPlus.enable();
      } catch (e) {
        debugPrint('[P2PAutoPublish] Wakelock enable error: $e');
      }

      final publishData = buildPublishData(data);

      // 3. Save listing to database asynchronously
      unawaited(
        DBService().saveListingFromPublishData(
          publishData,
          platform: 'p2p_chat',
        ),
      );

      // 4. Navigate to Yad2Screen on main thread
      return await _openYad2Screen(publishData);
    } catch (e, st) {
      debugPrint('[P2PAutoPublish] Error launching Yad2 auto publish: $e\n$st');
      return false;
    }
  }

  /// Builds a [VehiclePublishData] instance from the validation service state map.
  static VehiclePublishData buildPublishData(Map<String, String> data) {
    final color = _firstNonEmpty([data['color']], fallback: 'כחול');
    final images = _imagePathsFromVehicleData(data);
    final expectedCount = int.tryParse(
      data['image_expected_count'] ?? data['KEY_IMAGE_EXPECTED_COUNT'] ?? '',
    );
    final List<String> resolvedImages;
    if (expectedCount != null && expectedCount == 0) {
      resolvedImages = const <String>[];
    } else if (images.isNotEmpty) {
      resolvedImages = (expectedCount != null &&
              expectedCount > 0 &&
              images.length > expectedCount)
          ? images.sublist(images.length - expectedCount)
          : images;
    } else {
      resolvedImages = images;
    }

    return VehiclePublishData(
      licenseNumber: _firstNonEmpty([data['license_plate'], data['license']]),
      color: color,
      shade: color,
      hand: _handToHebrew(data['hand']),
      currentOwnership: _firstNonEmpty(
        [data['current_ownership']],
        fallback: 'פרטית',
      ),
      previousOwnership: _firstNonEmpty(
        [data['previous_ownership']],
        fallback: 'פרטית',
      ),
      kilometers: _firstNonEmpty([data['km'], data['kilometers']]),
      month: _firstNonEmpty(
        [data['month'], data['test_month']],
        fallback: DateTime.now().month.toString(),
      ),
      price: _firstNonEmpty([data['price']]),
      handicapped: false,
      noTest: false,
      images: resolvedImages,
      maker: _firstNonEmpty([data['maker']]),
      model: _firstNonEmpty([data['model']]),
      year: _firstNonEmpty([data['year']]),
      fuelType: _firstNonEmpty([data['fuel_type']]),
      gear: _gearForForm(data['gear_type']),
      vehicleCondition: _firstNonEmpty(
        [data['vehicle_condition']],
        fallback: 'טוב',
      ),
      description: _firstNonEmpty([data['description']]),
      expectedImageCount: expectedCount,
    );
  }

  static Future<bool> _openYad2Screen(
    VehiclePublishData publishData, {
    int attempt = 0,
  }) async {
    final navigator = rootNavigatorKey.currentState;
    if (navigator != null && navigator.mounted) {
      navigator.push(
        MaterialPageRoute(
          builder: (_) => Yad2Screen(
            publishData: publishData,
            useGemmaAutomation: true,
          ),
        ),
      );
      debugPrint(
        '[P2PAutoPublish] Successfully opened Yad2Screen for ${publishData.licenseNumber}',
      );
      return true;
    }

    if (attempt >= 20) {
      debugPrint(
        '[P2PAutoPublish] Failed to open Yad2: navigator missing after $attempt attempts',
      );
      return false;
    }

    await Future.delayed(const Duration(milliseconds: 300));
    return _openYad2Screen(publishData, attempt: attempt + 1);
  }

  static List<String> _imagePathsFromVehicleData(Map<String, String> data) {
    final raw = data['image_paths']?.trim() ?? data['KEY_IMAGE_PATHS']?.trim();
    if (raw == null || raw.isEmpty) return const [];
    List<String> list = const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        list = decoded
            .map((v) => v?.toString().trim() ?? '')
            .where((v) => v.isNotEmpty)
            .toList();
      }
    } catch (_) {
      list = raw
          .split('|')
          .map((v) => v.trim())
          .where((v) => v.isNotEmpty)
          .toList();
    }
    return list;
  }

  static String _handToHebrew(String? value) {
    final text = value?.trim();
    if (text == null || text.isEmpty) return 'יד שנייה';
    if (text.startsWith('יד')) return text;
    switch (text) {
      case '1':
        return 'יד ראשונה';
      case '2':
        return 'יד שנייה';
      case '3':
        return 'יד שלישית';
      case '4':
        return 'יד רביעית';
      case '5':
        return 'יד חמישית';
      default:
        return 'יד $text';
    }
  }

  static String _gearForForm(String? value) {
    final text = value?.trim();
    if (text == null || text.isEmpty) return 'הילוכים אוטומטיים';
    if (text.contains('ידני')) return 'שידור ידני';
    if (text.contains('אוטומט')) return 'הילוכים אוטומטיים';
    return text;
  }

  static String _firstNonEmpty(List<String?> values, {String fallback = ''}) {
    for (final value in values) {
      final text = value?.trim();
      if (text != null && text.isNotEmpty) return text;
    }
    return fallback;
  }
}
