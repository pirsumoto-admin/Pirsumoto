import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:pirsumoto_remote_control/firebase_options.dart';

void main() {
  test(
    'native Android Firebase config matches the controller and Dart config',
    () {
      final appGradle = File('android/app/build.gradle.kts').readAsStringSync();
      final settings = File('android/settings.gradle.kts').readAsStringSync();
      expect(appGradle, contains('id("com.google.gms.google-services")'));
      expect(
        settings,
        contains('id("com.google.gms.google-services") version'),
      );
      final packageName = RegExp(
        r'applicationId\s*=\s*"([^"]+)"',
      ).firstMatch(appGradle)!.group(1);
      final config =
          jsonDecode(
                File('android/app/google-services.json').readAsStringSync(),
              )
              as Map<String, dynamic>;
      final clients = (config['client'] as List).where(
        (client) =>
            client['client_info']['android_client_info']['package_name'] ==
            packageName,
      );
      expect(
        clients,
        hasLength(1),
        reason:
            'FCM must initialize natively before Flutter starts. Download the '
            'Firebase configuration for the controller package, not the main app.',
      );
      final client = clients.single;
      final options = DefaultFirebaseOptions.android;
      expect(client['client_info']['mobilesdk_app_id'], options.appId);
      expect(
        client['api_key'].map((key) => key['current_key']),
        contains(options.apiKey),
      );
      expect(config['project_info']['project_id'], options.projectId);
      expect(
        config['project_info']['project_number'],
        options.messagingSenderId,
      );
    },
  );
}
