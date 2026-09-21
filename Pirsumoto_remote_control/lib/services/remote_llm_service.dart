import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import '../ui/whatsapp_chat_screen.dart';
import 'remote_validation_service.dart';

class RemoteLlmService {
  /// Extracts the license plate from the chat history using regex and the secure backend Cloud Function.
  static Future<String?> extractLicensePlate(List<ChatMessageItem> messages) async {
    if (messages.isEmpty) return null;

    final historyText = messages.map((m) => '${m.sender.name}: ${m.text}').join('\n');
    
    // Fast regex check first
    final plateMatch = RegExp(r'\b\d{7,8}\b').firstMatch(historyText);
    if (plateMatch != null) return plateMatch.group(0);

    // Secure backend Cloud Function proxy (no API key on client device)
    try {
      final response = await http.post(
        Uri.parse(RemoteValidationService.cloudFunctionUrl),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'action': 'extract_license_plate',
          'chatHistoryText': historyText,
        }),
      ).timeout(const Duration(seconds: 15));

      if (response.statusCode == 200) {
        final data = jsonDecode(utf8.decode(response.bodyBytes)) as Map<String, dynamic>;
        if (data['ok'] == true && data['licensePlate'] != null) {
          return data['licensePlate'].toString();
        }
      }
    } catch (e) {
      debugPrint('[RemoteLlmService] Cloud extractLicensePlate error: $e');
    }
    return null;
  }

  /// Checks if a message indicates successful publication on both Facebook and Yad2.
  static bool checkIfPublicationDone(String messageText) {
    final text = messageText.toLowerCase();
    final mentionsBoth = (text.contains('יד2') || text.contains('yad2')) && 
                         (text.contains('פייסבוק') || text.contains('facebook'));
    final mentionsSuccess = text.contains('הצלחה') || text.contains('פורסם') || text.contains('מוכנה');
    
    return mentionsBoth && mentionsSuccess;
  }
}
