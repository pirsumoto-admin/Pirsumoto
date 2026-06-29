import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:permission_handler/permission_handler.dart';
import 'features/form/form_provider.dart' as fp;
import 'features/publish/yad2_screen.dart';
import 'routing/app_router.dart';
import 'services/whatsapp_message_bridge_service.dart';
import 'services/yad2_automation_models.dart';
import 'shared/theme/app_theme.dart';

import 'package:easy_localization/easy_localization.dart';
import 'package:firebase_core/firebase_core.dart';
// import 'package:flutter_skill/flutter_skill.dart';
// import 'package:flutter_gemma/flutter_gemma.dart';

void main() async {
  // FlutterSkillBinding.ensureInitialized();
  WidgetsFlutterBinding.ensureInitialized();
  await EasyLocalization.ensureInitialized();
  await Firebase.initializeApp();
  // await FlutterGemma.initialize();

  runApp(
    EasyLocalization(
      supportedLocales: const [Locale('he'), Locale('en')],
      path: 'assets/translations',
      fallbackLocale: const Locale('he'),
      startLocale: const Locale('he'),
      child: const ProviderScope(child: MyApp()),
    ),
  );
}

class MyApp extends ConsumerStatefulWidget {
  const MyApp({super.key});

  @override
  ConsumerState<MyApp> createState() => _MyAppState();
}

class _MyAppState extends ConsumerState<MyApp> with WidgetsBindingObserver {
  final Set<String> _promptedWhatsAppSetup = {};
  StreamSubscription<WhatsAppBridgeEvent>? _whatsAppEventsSubscription;
  String? _lastAutoPublishVehicleFingerprint;
  bool _whatsAppBootstrapRunning = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _listenToWhatsAppBridgeEvents();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _consumePendingWhatsAppAutoPublish();
      _bootstrapWhatsAppBridge();
    });
  }

  @override
  void dispose() {
    _whatsAppEventsSubscription?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _consumePendingWhatsAppAutoPublish();
      _bootstrapWhatsAppBridge();
    }
  }

  Future<void> _bootstrapWhatsAppBridge() async {
    if (!Platform.isAndroid || _whatsAppBootstrapRunning) return;

    _whatsAppBootstrapRunning = true;
    try {
      final bridge = WhatsAppMessageBridgeService.instance;

      final notificationStatus = await Permission.notification.status;
      if (!notificationStatus.isGranted &&
          _promptedWhatsAppSetup.add('postNotifications')) {
        await Permission.notification.request();
      }

      await bridge.configure(autoReplyEnabled: true);
      await bridge.start();
      await _consumePendingWhatsAppAutoPublish();

      final status = await bridge.getStatus();
      if (!status.notificationListenerEnabled &&
          _promptedWhatsAppSetup.add('notificationListener')) {
        await bridge.openNotificationListenerSettings();
        return;
      }

      if (!status.allFilesAccessGranted &&
          _promptedWhatsAppSetup.add('allFilesAccess')) {
        await bridge.openAllFilesAccessSettings();
        return;
      }

      if (!status.fullScreenIntentAllowed &&
          _promptedWhatsAppSetup.add('fullScreenIntent')) {
        await bridge.openFullScreenIntentSettings();
        return;
      }

      if (!status.overlayPermissionGranted &&
          _promptedWhatsAppSetup.add('overlayPermission')) {
        await bridge.openOverlayPermissionSettings();
        return;
      }

      if (!status.batteryOptimizationIgnored &&
          _promptedWhatsAppSetup.add('batteryOptimization')) {
        await bridge.openBatteryOptimizationSettings();
        return;
      }
    } catch (error, stackTrace) {
      debugPrint('WhatsApp bridge bootstrap failed: $error\n$stackTrace');
    } finally {
      _whatsAppBootstrapRunning = false;
    }
  }

  void _listenToWhatsAppBridgeEvents() {
    if (!Platform.isAndroid) return;
    _whatsAppEventsSubscription = WhatsAppMessageBridgeService.instance.events
        .listen(
          _handleWhatsAppBridgeEvent,
          onError: (Object error, StackTrace stackTrace) {
            debugPrint(
              'WhatsApp bridge event stream failed: $error\n$stackTrace',
            );
          },
        );
  }

  void _handleWhatsAppBridgeEvent(WhatsAppBridgeEvent event) {
    if (event.name != 'locallyProcessed' &&
        event.name != 'autoPublishLaunchRequested') {
      return;
    }

    final vehicleData = _stringMap(event.data['vehicleData']);
    if (vehicleData.isEmpty) return;

    _applyWhatsAppVehicleData(vehicleData);

    final shouldStartAutoPublish =
        event.name == 'autoPublishLaunchRequested' ||
        event.data['autoPublishRequested'] == true ||
        event.data['autoPublishRequested']?.toString() == 'true';
    if (shouldStartAutoPublish) {
      _startWhatsAppAutoPublish(vehicleData);
    }
  }

  Future<void> _consumePendingWhatsAppAutoPublish() async {
    if (!Platform.isAndroid) return;
    try {
      final vehicleData =
          await WhatsAppMessageBridgeService.instance
              .consumePendingAutoPublish();
      if (vehicleData.isNotEmpty) {
        _startWhatsAppAutoPublish(vehicleData);
      }
    } catch (error, stackTrace) {
      debugPrint('WhatsApp auto-publish consume failed: $error\n$stackTrace');
    }
  }

  void _applyWhatsAppVehicleData(Map<String, String> data) {
    final notifier = ref.read(fp.formControllerProvider.notifier);

    void update(String field, String? value) {
      final trimmed = value?.trim();
      if (trimmed != null && trimmed.isNotEmpty) {
        notifier.updateField(field, trimmed);
      }
    }

    update('license', data['license_plate']);
    update('color', data['color']);
    update('maker', data['maker']);
    update('model', data['model']);
    update('year', data['year']);
    update('fuelType', data['fuel_type']);
    update('month', data['month']);
    update('test', _testValue(data));
    update('hand', _handToHebrew(data['hand']));
    update('ownership', data['current_ownership']);
    update('prevOwnership', data['previous_ownership']);
    update('km', data['km']);
    update('price', data['price']);
    update('vehicleCondition', data['vehicle_condition']);
    update('description', data['description']);
    update('gear', _gearForForm(data['gear_type']));
  }

  void _startWhatsAppAutoPublish(Map<String, String> data) {
    final fingerprint = '${data['license_plate']}_${data['timestamp'] ?? DateTime.now().millisecondsSinceEpoch ~/ 10000}';
    if (_lastAutoPublishVehicleFingerprint == fingerprint) {
      debugPrint('Ignoring duplicate auto-publish request for fingerprint: $fingerprint');
      return;
    }
    _lastAutoPublishVehicleFingerprint = fingerprint;

    _applyWhatsAppVehicleData(data);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      _openYad2WhenReady(data);
    });
  }

  void _openYad2WhenReady(Map<String, String> data, {int attempt = 0}) {
    if (_openYad2FromWhatsApp(data)) return;
    if (attempt >= 12) {
      debugPrint(
        'WhatsApp auto-publish could not open Yad2: navigator missing',
      );
      return;
    }
    Future<void>.delayed(const Duration(milliseconds: 500), () {
      _openYad2WhenReady(data, attempt: attempt + 1);
    });
  }

  bool _openYad2FromWhatsApp(Map<String, String> data) {
    final navigator = rootNavigatorKey.currentState;
    if (navigator == null) return false;

    final formState = ref.read(fp.formControllerProvider);
    final color = _firstNonEmpty([
      formState.color,
      data['color'],
    ], fallback: 'כחול');
    final whatsAppImages = _imagePathsFromVehicleData(data);
    final publishData = VehiclePublishData(
      licenseNumber: _firstNonEmpty([formState.license, data['license_plate']]),
      color: color,
      shade: color,
      hand: _firstNonEmpty([
        _handToHebrew(formState.hand),
        _handToHebrew(data['hand']),
      ], fallback: 'יד שנייה'),
      currentOwnership: _firstNonEmpty([
        formState.ownership,
        data['current_ownership'],
      ], fallback: 'פרטית'),
      previousOwnership: _firstNonEmpty([
        formState.prevOwnership,
        data['previous_ownership'],
      ], fallback: 'פרטית'),
      kilometers: _firstNonEmpty([formState.km, data['km']]),
      month: _firstNonEmpty([
        formState.month,
        data['month'],
      ], fallback: DateTime.now().month.toString()),
      price: _firstNonEmpty([formState.price, data['price']]),
      handicapped: false,
      noTest: false,
      images: whatsAppImages.isNotEmpty ? whatsAppImages : formState.images,
      maker: _firstNonEmpty([formState.maker, data['maker']]),
      model: _firstNonEmpty([formState.model, data['model']]),
      year: _firstNonEmpty([formState.year, data['year']]),
      fuelType: _firstNonEmpty([formState.fuelType, data['fuel_type']]),
      gear: _firstNonEmpty([
        _gearForForm(formState.gear),
        _gearForForm(data['gear_type']),
      ], fallback: 'הילוכים אוטומטיים'),
      vehicleCondition: _firstNonEmpty([
        formState.vehicleCondition,
        data['vehicle_condition'],
      ], fallback: 'טוב'),
      warranties: formState.warranties,
      warrantyDurations: formState.warrantyDurations,
      treatments: formState.treatments,
      services: formState.services,
    );

    navigator.push(
      MaterialPageRoute(
        builder:
            (_) => Yad2Screen(
              publishData: publishData,
              useGemmaAutomation: true,
              startedFromWhatsApp: data['whatsapp_origin'] == 'true',
              whatsAppSenderKey: data['whatsapp_sender_key'],
            ),
      ),
    );
    return true;
  }

  Map<String, String> _stringMap(Object? value) {
    if (value is! Map) return const {};
    final result = <String, String>{};
    value.forEach((key, rawValue) {
      final text = rawValue?.toString().trim();
      if (text != null && text.isNotEmpty) {
        result[key.toString()] = text;
      }
    });
    return result;
  }

  List<String> _imagePathsFromVehicleData(Map<String, String> data) {
    final raw = data['image_paths']?.trim();
    if (raw == null || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        return decoded
            .map((value) => value?.toString().trim() ?? '')
            .where((value) => value.isNotEmpty)
            .toList();
      }
    } catch (_) {
      return raw
          .split('|')
          .map((value) => value.trim())
          .where((value) => value.isNotEmpty)
          .toList();
    }
    return const [];
  }

  String? _testValue(Map<String, String> data) {
    final month = data['test_month']?.trim();
    final year = data['test_year']?.trim();
    if (month == null || month.isEmpty || year == null || year.isEmpty) {
      return null;
    }
    return '$month,$year';
  }

  String? _gearForForm(String? value) {
    final text = value?.trim();
    if (text == null || text.isEmpty) return null;
    if (text.contains('ידני')) return 'שידור ידני';
    if (text.contains('אוטומט')) return 'הילוכים אוטומטיים';
    return text;
  }

  String? _handToHebrew(String? value) {
    final text = value?.trim();
    if (text == null || text.isEmpty) return null;
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

  String _firstNonEmpty(List<String?> values, {String fallback = ''}) {
    for (final value in values) {
      final text = value?.trim();
      if (text != null && text.isNotEmpty) return text;
    }
    return fallback;
  }

  @override
  Widget build(BuildContext context) {
    final router = ref.watch(appRouterProvider);

    return MaterialApp.router(
      title: 'Pirsumoto',
      localizationsDelegates: context.localizationDelegates,
      supportedLocales: context.supportedLocales,
      locale: context.locale,
      theme: AppTheme.darkTheme,
      themeMode: ThemeMode.dark, // Defaulting to dark for modern rich aesthetic
      routerConfig: router,
      debugShowCheckedModeBanner: false,
    );
  }
}
