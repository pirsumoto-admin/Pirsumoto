import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'firebase_options.dart';
import 'ui/app_theme.dart';
import 'ui/device_select_screen.dart';
import 'ui/login_screen.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();
  try {
    await Firebase.initializeApp(
      options: DefaultFirebaseOptions.currentPlatform,
    );
  } catch (e) {
    debugPrint('[RemoteControlApp] Firebase initialization note: $e');
  }

  runApp(const PirsumotoRemoteControlApp());
}

class PirsumotoRemoteControlApp extends StatelessWidget {
  const PirsumotoRemoteControlApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Pirsumoto Relay',
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
