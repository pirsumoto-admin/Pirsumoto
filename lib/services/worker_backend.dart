import 'dart:convert';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:http/http.dart' as http;

/// Provider credentials and prompts are owned by the authenticated backend.
class WorkerBackend {
  static Future<Map<String, dynamic>> post(Map<String, dynamic> payload) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) throw StateError('Authentication required');
    final deviceId = (await SharedPreferences.getInstance()).getString(
      'remote_control_device_id',
    );
    if (deviceId == null) throw StateError('Device registration required');
    final response = await http
        .post(
          Uri.parse(
            'https://me-west1-car-publisher.cloudfunctions.net/remoteValidation',
          ),
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer ${await user.getIdToken()}',
          },
          body: jsonEncode({...payload, 'deviceId': deviceId}),
        )
        .timeout(const Duration(seconds: 55));
    if (response.statusCode != 200)
      throw StateError('Backend request failed (${response.statusCode})');
    return Map<String, dynamic>.from(
      jsonDecode(utf8.decode(response.bodyBytes)) as Map,
    );
  }
}
