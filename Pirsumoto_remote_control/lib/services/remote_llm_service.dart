import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:http/http.dart' as http;
import '../ui/whatsapp_chat_screen.dart';

class RemoteLlmService {
  static const String _anthropicApiUrl = 'https://api.anthropic.com/v1/messages';
  
  static Future<String?> _getApiKey() async {
    try {
      final doc = await FirebaseFirestore.instance.collection('agent_config').doc('global').get();
      if (doc.exists) {
        return doc.data()?['anthropic_api_key'] as String?;
      }
    } catch (e) {
      debugPrint('Error fetching API key: $e');
    }
    return null;
  }

  /// Extracts the license plate from the chat history using the LLM.
  static Future<String?> extractLicensePlate(List<ChatMessageItem> messages) async {
    if (messages.isEmpty) return null;
    
    final apiKey = await _getApiKey();
    if (apiKey == null || apiKey.isEmpty) return null;

    final historyText = messages.map((m) => '${m.sender.name}: ${m.text}').join('\n');
    
    final prompt = '''
You are an AI assistant helping a car selling automation system.
Your task is to find the 7 or 8 digit Israeli license plate number mentioned by the user in this chat history.
If you find it, output ONLY the 7 or 8 digits. Do not include spaces, dashes, or any other text.
If no license plate is mentioned, output exactly "NONE".

Chat history:
$historyText
''';

    try {
      final response = await http.post(
        Uri.parse(_anthropicApiUrl),
        headers: {
          'Content-Type': 'application/json',
          'x-api-key': apiKey,
          'anthropic-version': '2023-06-01',
        },
        body: jsonEncode({
          'model': 'claude-3-haiku-20240307', // Using haiku for fast, cheap extraction
          'max_tokens': 50,
          'messages': [
            {'role': 'user', 'content': prompt}
          ],
        }),
      ).timeout(const Duration(seconds: 15));

      if (response.statusCode == 200) {
        final decoded = jsonDecode(utf8.decode(response.bodyBytes));
        final content = decoded['content']?[0]?['text']?.toString().trim() ?? '';
        
        if (content == 'NONE') return null;
        
        final digitsOnly = content.replaceAll(RegExp(r'\D'), '');
        if (digitsOnly.length == 7 || digitsOnly.length == 8) {
          return digitsOnly;
        }
      }
    } catch (e) {
      debugPrint('Error extracting license plate via LLM: $e');
    }
    return null;
  }

  /// Checks if a message indicates successful publication on both Facebook and Yad2.
  static bool checkIfPublicationDone(String messageText) {
    // We can just use keyword heuristics for speed, or call the LLM if needed.
    // The prompt says "when the llm sends a response that publication succeeded for both facebook and Yad2"
    // Since this is a boolean check, regex/keyword matching on the bot's known Hebrew response is much faster and more reliable than a remote LLM call.
    final text = messageText.toLowerCase();
    final mentionsBoth = (text.contains('יד2') || text.contains('yad2')) && 
                         (text.contains('פייסבוק') || text.contains('facebook'));
    final mentionsSuccess = text.contains('הצלחה') || text.contains('פורסם') || text.contains('מוכנה');
    
    return mentionsBoth && mentionsSuccess;
  }
}
