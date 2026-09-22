import 'package:publication_protocol/publication_protocol.dart';
import '../ui/whatsapp_chat_screen.dart';

/// Legacy history recovery is local and deterministic. Publication status is
/// never inferred from conversational text.
class RemoteLlmService {
  static Future<String?> extractLicensePlate(
    List<ChatMessageItem> messages,
  ) async {
    for (final message in messages.reversed) {
      if (message.sender != ChatSender.user) continue;
      final plate = VehicleSchema.extractPlate(message.text);
      if (plate != null) return plate;
    }
    return null;
  }
}
