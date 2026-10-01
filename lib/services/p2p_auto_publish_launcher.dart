import 'package:publication_protocol/publication_protocol.dart';
import '../remote_control/firebase_chat_receiver.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../features/publish/facebook_screen.dart';
import '../features/publish/yad2_screen.dart';
import '../routing/app_router.dart';
import 'db_service.dart';
import 'yad2_automation_models.dart';

/// Launches automated publication from internal P2P chat vehicle data.
class P2PAutoPublishLauncher {
  /// Main entrypoint to launch publication from vehicle state map.
  static Future<bool> launch(
    Map<String, String> data, {
    PublicationIdentity? identity,
  }) async {
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
          await const MethodChannel(
            'com.pirsumoto/accessibility',
          ).invokeMethod('bringAppToForeground');
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

      final publishData = buildPublishData(data, identity: identity);

      // 3. Save listing to database asynchronously
      unawaited(
        DBService().saveListingFromPublishData(
          publishData,
          platform: 'p2p_chat',
        ),
      );

      // 4. Route to Facebook or Yad2 automation based on includeYad2
      bool includeYad2 = publishData.includeYad2;
      try {
        final uid =
            FirebaseChatReceiver.activeOwnerUid ??
            FirebaseAuth.instance.currentUser?.uid;
        if (uid != null && uid.isNotEmpty) {
          final settings = await DBService().getSettingsData(uid);
          if (settings != null && settings.containsKey('includeYad2')) {
            includeYad2 = settings['includeYad2'] == true;
          }
        }
      } catch (e) {
        debugPrint('[P2PAutoPublish] Error checking user settings: $e');
      }

      debugPrint(
        '[P2PAutoPublish] Routing publication: includeYad2 = $includeYad2',
      );
      if (!includeYad2) {
        return await _openFacebookScreen(
          publishData.copyWith(includeYad2: false),
        );
      } else {
        return await _openYad2Screen(publishData.copyWith(includeYad2: true));
      }
    } catch (e, st) {
      debugPrint('[P2PAutoPublish] Error launching auto publish: $e\n$st');
      return false;
    }
  }

  /// Builds a [VehiclePublishData] instance from the validation service state map.
  static VehiclePublishData buildPublishData(
    Map<String, String> data, {
    PublicationIdentity? identity,
  }) {
    final color = _firstNonEmpty([data['color']], fallback: 'כחול');
    final images = _imagePathsFromVehicleData(data);
    final expectedCount = int.tryParse(
      data['image_expected_count'] ?? data['KEY_IMAGE_EXPECTED_COUNT'] ?? '',
    );
    final List<String> resolvedImages;
    if (expectedCount != null && expectedCount == 0) {
      resolvedImages = const <String>[];
    } else if (images.isNotEmpty) {
      resolvedImages =
          (expectedCount != null &&
                  expectedCount > 0 &&
                  images.length > expectedCount)
              ? images.sublist(images.length - expectedCount)
              : images;
    } else {
      resolvedImages = images;
    }

    final rawIncludeYad2 = data['includeYad2'] ?? data['include_yad2'];
    final bool includeYad2 =
        rawIncludeYad2 != null
            ? rawIncludeYad2.toString().toLowerCase() != 'false'
            : true;

    final testUntil = data['test_until']?.toString() ?? '';
    String? testYear = data['test_year']?.toString();
    String? testMonth = data['test_month']?.toString();
    if (testUntil.isNotEmpty &&
        ((testYear == null || testYear.isEmpty) ||
            (testMonth == null || testMonth.isEmpty))) {
      final parts = testUntil.split(RegExp(r'[/.-]'));
      if (parts.length >= 2) {
        if (testMonth == null || testMonth.isEmpty) testMonth = parts[0].trim();
        if (testYear == null || testYear.isEmpty) {
          String y = parts[1].trim();
          if (y.length == 2) y = '20$y';
          testYear = y;
        }
      }
    }

    final rawGovIl = data['govIl']?.toString().trim();
    String desc = data['description']?.toString() ?? '';
    bool hasNoGovilMarker = desc.contains('[NO_GOVIL]');
    bool hasGovilMarker = desc.contains('[GOVIL]');
    
    final bool isGovIl;
    if (hasNoGovilMarker) {
      isGovIl = false;
    } else if (hasGovilMarker) {
      isGovIl = true;
    } else {
      isGovIl = (rawGovIl != null && rawGovIl.isNotEmpty)
          ? (rawGovIl.toLowerCase() == 'true' || rawGovIl == '1')
          : (testUntil.isEmpty &&
              (data['maker'] != null &&
                  data['maker']!.toString().isNotEmpty &&
                  data['maker'] != 'לא ידוע'));
    }

    if (hasNoGovilMarker || hasGovilMarker) {
      desc = desc.replaceAll('[NO_GOVIL]', '').replaceAll('[GOVIL]', '').trim();
      data['description'] = desc;
    }

    final rawHandicapped = data['handicapped']?.toString().trim();
    final bool handicapped =
        rawHandicapped == 'כן' ||
        rawHandicapped?.toLowerCase() == 'true' ||
        rawHandicapped == '1';

    final rawNoTest = data['no_test']?.toString().trim();
    final bool noTest =
        rawNoTest == 'כן' ||
        rawNoTest?.toLowerCase() == 'true' ||
        rawNoTest == '1';

    return VehiclePublishData(
      publicationIdentity: identity,
      city: data['city'] ?? '',
      licenseNumber: _firstNonEmpty([data['license_plate'], data['license']]),
      color: color,
      shade: color,
      hand: _handToHebrew(data['hand']),
      currentOwnership: _firstNonEmpty([
        data['current_ownership'],
      ], fallback: 'פרטית'),
      previousOwnership: _firstNonEmpty([
        data['previous_ownership'],
      ], fallback: 'פרטית'),
      kilometers: _firstNonEmpty([data['km'], data['kilometers']]),
      month: _firstNonEmpty([
        data['month'],
        data['test_month'],
      ], fallback: DateTime.now().month.toString()),
      price: _firstNonEmpty([data['price']]),
      handicapped: handicapped,
      noTest: noTest,
      images: resolvedImages,
      maker: _firstNonEmpty([data['maker']]),
      model: _firstNonEmpty([data['model']]),
      year: _firstNonEmpty([data['year']]),
      fuelType: _firstNonEmpty([data['fuel_type']]),
      gear: _gearForForm(data['gear_type']),
      vehicleCondition: _firstNonEmpty([
        data['vehicle_condition'],
      ], fallback: 'טוב'),
      description: _firstNonEmpty([data['description']]),
      expectedImageCount: expectedCount,
      testYear: testYear,
      testMonth: testMonth,
      govIl: isGovIl,
      includeYad2: includeYad2,
    );
  }

  static Future<bool> _openFacebookScreen(
    VehiclePublishData publishData, {
    int attempt = 0,
  }) async {
    if (!FirebaseChatReceiver.isCurrent(publishData.publicationIdentity))
      return false;
    final navigator = rootNavigatorKey.currentState;
    if (navigator != null && navigator.mounted) {
      navigator.push(
        MaterialPageRoute(
          builder: (_) => FacebookScreen(publishData: publishData),
        ),
      );
      debugPrint(
        '[P2PAutoPublish] Successfully opened FacebookScreen for ${publishData.licenseNumber}',
      );
      return true;
    }

    if (attempt >= 20) {
      debugPrint(
        '[P2PAutoPublish] Failed to open Facebook: navigator missing after $attempt attempts',
      );
      return false;
    }

    await Future.delayed(const Duration(milliseconds: 300));
    return _openFacebookScreen(publishData, attempt: attempt + 1);
  }

  static Future<bool> _openYad2Screen(
    VehiclePublishData publishData, {
    int attempt = 0,
  }) async {
    if (!FirebaseChatReceiver.isCurrent(publishData.publicationIdentity))
      return false;
    final navigator = rootNavigatorKey.currentState;
    if (navigator != null && navigator.mounted) {
      navigator.push(
        MaterialPageRoute(
          builder:
              (_) => Yad2Screen(
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
        list =
            decoded
                .map((v) => v?.toString().trim() ?? '')
                .where((v) => v.isNotEmpty)
                .toList();
      }
    } catch (_) {
      list =
          raw
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
