import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'firebase_options.dart';
import 'services/chat_notification_service.dart';
import 'ui/app_theme.dart';
import 'ui/device_select_screen.dart';
import 'ui/login_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
    FirebaseMessaging.onBackgroundMessage(publicationPushBackground);
    await ChatNotificationService.instance.initialize();
  } catch (e) {
    debugPrint(
      '[RemoteControlApp] Firebase/Notification initialization note: $e',
    );
  }

  runApp(const PirsumotoRemoteControlApp());
}

class PirsumotoRemoteControlApp extends StatefulWidget {
  const PirsumotoRemoteControlApp({super.key});

  @override
  State<PirsumotoRemoteControlApp> createState() =>
      _PirsumotoRemoteControlAppState();
}

class _PirsumotoRemoteControlAppState extends State<PirsumotoRemoteControlApp>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => ChatNotificationService.instance.navigatePending(),
    );
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    }
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      navigatorKey: remoteControlNavigatorKey,
      title: 'שלט לפרסומוטו',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.lightTheme,
      builder: (context, child) {
        return Directionality(
          textDirection: TextDirection.rtl,
          child: child ?? const SizedBox.shrink(),
        );
      },
      home: StreamBuilder<User?>(
        stream: FirebaseAuth.instance.authStateChanges(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Scaffold(
              backgroundColor: AppColors.neutral,
              body: Center(
                child: CircularProgressIndicator(
                  color: AppColors.primaryAction,
                ),
              ),
            );
          }

          if (snapshot.hasData && snapshot.data != null) {
            return const DeviceSelectScreen();
          }

          return const LoginScreen();
        },
      ),
    );
  }
}
