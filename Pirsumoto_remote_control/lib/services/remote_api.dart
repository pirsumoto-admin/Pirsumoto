import 'dart:convert';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;

class RemoteApi {
  static const url =
      'https://me-west1-car-publisher.cloudfunctions.net/remoteValidation';
  static Future<Map<String, dynamic>> post(
    String deviceId,
    Map<String, dynamic> body,
  ) async {
    final user = FirebaseAuth.instance.currentUser;
    if (user == null) throw StateError('יש להתחבר מחדש');
    final token = await user.getIdToken();
    final response = await http
        .post(
          Uri.parse(url),
          headers: {
            'Content-Type': 'application/json',
            'Authorization': 'Bearer $token',
          },
          body: jsonEncode({...body, 'deviceId': deviceId}),
        )
        .timeout(const Duration(seconds: 55));
    final data =
        jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
    if (response.statusCode != 200 || data['ok'] != true) {
      throw StateError(data['error']?.toString() ?? 'הבקשה נכשלה; נסה שוב');
    }
    return data;
  }
}
