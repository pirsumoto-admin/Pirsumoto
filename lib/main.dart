// [WHATSAPP-DISABLED] dart:async was used for StreamSubscription of WA bridge events.
// import 'dart:async';
// [WHATSAPP-DISABLED] dart:convert was used to decode image_paths JSON in WA flow.
// import 'dart:convert';
import 'dart:io'; // Keep: used in main() for Platform.isAndroid / Platform.isIOS

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
// [WHATSAPP-DISABLED] permission_handler was used to request manageExternalStorage for WA.
// import 'package:permission_handler/permission_handler.dart';
// [WHATSAPP-DISABLED] form_provider was used in _applyWhatsAppVehicleData.
// import 'features/form/form_provider.dart' as fp;
// [WHATSAPP-DISABLED] yad2_screen was used to open Yad2 from WhatsApp auto-publish flow.
// import 'features/publish/yad2_screen.dart';
import 'routing/app_router.dart';
// [WHATSAPP-DISABLED] WhatsApp bridge service — disabled, app uses P2P chat instead.
// import 'services/whatsapp_message_bridge_service.dart';
// [WHATSAPP-DISABLED] WhatsApp text validation service calls from main.dart disabled.
// import 'services/whatsapp_text_validation_service.dart';
// [WHATSAPP-DISABLED] yad2_automation_models was used in _openYad2FromWhatsApp.
// import 'services/yad2_automation_models.dart';
// [WHATSAPP-DISABLED] db_service was used to save listing from WhatsApp auto-publish.
// import 'services/db_service.dart';
import 'shared/theme/app_theme.dart';
import 'remote_control/remote_receiver_service.dart';

import 'package:easy_localization/easy_localization.dart';
import 'package:firebase_core/firebase_core.dart';
// [WHATSAPP-DISABLED] shared_preferences was used by WA config dialog (has_seen_whatsapp_config).
// import 'package:shared_preferences/shared_preferences.dart';
import 'firebase_options.dart';

// import 'package:flutter_skill/flutter_skill.dart';
// import 'package:flutter_gemma/flutter_gemma.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  if (Platform.isAndroid || Platform.isIOS) {
    try {
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    } catch (e) {
      debugPrint('Failed to set SystemUI: $e');
    }
  }

  try {
    await EasyLocalization.ensureInitialized();
  } catch (e) {
    debugPrint('EasyLocalization init failed: $e');
  }

  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
  } catch (e) {
    debugPrint('Firebase init failed (continuing anyway): $e');
  }

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
  // [WHATSAPP-DISABLED] WhatsApp bridge state fields disabled.
  // final Set<String> _promptedWhatsAppSetup = {};
  // StreamSubscription<WhatsAppBridgeEvent>? _whatsAppEventsSubscription;
  // String? _lastAutoPublishVehicleFingerprint;
  // bool _whatsAppBootstrapRunning = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // [WHATSAPP-DISABLED] WhatsApp bridge event listener disabled.
    // _listenToWhatsAppBridgeEvents();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // [WHATSAPP-DISABLED] WhatsApp auto-publish consumer and bridge bootstrap disabled.
      // _consumePendingWhatsAppAutoPublish();
      // _bootstrapWhatsAppBridge();
      RemoteControlReceiverService.instance.initialize();
    });
  }

  @override
  void dispose() {
    // [WHATSAPP-DISABLED] _whatsAppEventsSubscription?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      // [WHATSAPP-DISABLED] WhatsApp bootstrap calls disabled.
      // _consumePendingWhatsAppAutoPublish();
      // _bootstrapWhatsAppBridge();
    }
  }

  // ─────────────────────────────────────────────────────────────────────────
  // [WHATSAPP-DISABLED] All methods below were part of the WhatsApp bridge
  // integration. They are commented out because the main app no longer uses
  // WhatsApp for communication. The P2P internal chat via whatsapp_chat_screen.dart
  // still uses WhatsAppTextValidationService (in the remote_control module).
  // ─────────────────────────────────────────────────────────────────────────

  // Future<void> _bootstrapWhatsAppBridge() async { ... }
  // void _listenToWhatsAppBridgeEvents() { ... }
  // void _handleWhatsAppBridgeEvent(WhatsAppBridgeEvent event) async { ... }
  // Future<void> _consumePendingWhatsAppAutoPublish() async { ... }
  // void _applyWhatsAppVehicleData(Map<String, String> data) { ... }
  // void _startWhatsAppAutoPublish(Map<String, String> data) { ... }
  // void _openYad2WhenReady(Map<String, String> data, {int attempt = 0}) { ... }
  // bool _openYad2FromWhatsApp(Map<String, String> data) { ... }
  // Map<String, String> _stringMap(Object? value) { ... }
  // List<String> _imagePathsFromVehicleData(Map<String, String> data) { ... }
  // String? _testValue(Map<String, String> data) { ... }
  // String? _gearForForm(String? value) { ... }
  // String? _handToHebrew(String? value) { ... }
  // String _firstNonEmpty(List<String?> values, {String fallback = ''}) { ... }

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
