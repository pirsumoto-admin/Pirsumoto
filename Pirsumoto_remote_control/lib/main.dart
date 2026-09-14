import 'package:flutter/material.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:google_fonts/google_fonts.dart';
import 'firebase_options.dart';
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
      title: 'פרסומוטו Remote Control',
      debugShowCheckedModeBanner: false,
      theme: ThemeData.dark().copyWith(
        scaffoldBackgroundColor: const Color(0xFF0A0E17),
        colorScheme: const ColorScheme.dark(
          primary: Color(0xFF238636),
          secondary: Color(0xFF2EA043),
          surface: Color(0xFF161B22),
        ),
        textTheme: GoogleFonts.interTextTheme(ThemeData.dark().textTheme),
      ),
      home: StreamBuilder<User?>(
        stream: FirebaseAuth.instance.authStateChanges(),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Scaffold(
              backgroundColor: Color(0xFF0D1117),
              body: Center(
                child: CircularProgressIndicator(
                  color: Color(0xFF238636),
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
