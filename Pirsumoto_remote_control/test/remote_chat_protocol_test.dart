import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirsumoto_remote_control/remote/remote_protocol.dart';
import 'package:pirsumoto_remote_control/ui/whatsapp_chat_screen.dart';

void main() {
  group('RemoteChatProtocol Tests', () {
    test('Encodes and decodes RemoteChatTextMessage', () {
      final msg = RemoteChatTextMessage(
        id: 'msg_1001',
        text: 'מאזדה 3 שנת 2019 יד 2 80000 קמ',
        senderName: 'Controller User',
        timestamp: 1726000000,
      );

      final encoded = msg.encode();
      final decoded = RemoteCommand.decode(encoded);

      expect(decoded, isA<RemoteChatTextMessage>());
      final chatText = decoded as RemoteChatTextMessage;
      expect(chatText.id, equals('msg_1001'));
      expect(chatText.text, equals('מאזדה 3 שנת 2019 יד 2 80000 קמ'));
      expect(chatText.senderName, equals('Controller User'));
      expect(chatText.timestamp, equals(1726000000));
    });

    test('Encodes and decodes RemoteChatReplyMessage', () {
      final reply = RemoteChatReplyMessage(
        id: 'reply_2002',
        replyToId: 'msg_1001',
        text: '🤖 פירסומוטו: זיהיתי מאזדה 3. מה הצבע של הרכב?',
        timestamp: 1726000010,
      );

      final encoded = reply.encode();
      final decoded = RemoteCommand.decode(encoded);

      expect(decoded, isA<RemoteChatReplyMessage>());
      final chatReply = decoded as RemoteChatReplyMessage;
      expect(chatReply.id, equals('reply_2002'));
      expect(chatReply.replyToId, equals('msg_1001'));
      expect(chatReply.text, contains('פירסומוטו'));
      expect(chatReply.timestamp, equals(1726000010));
    });

    test('Encodes and decodes RemoteChatStatusMessage', () {
      final status = RemoteChatStatusMessage(
        status: 'transcribing',
        text: 'מפענח הודעה קולית (Whisper)...',
        timestamp: 1726000020,
      );

      final encoded = status.encode();
      final decoded = RemoteCommand.decode(encoded);

      expect(decoded, isA<RemoteChatStatusMessage>());
      final chatStatus = decoded as RemoteChatStatusMessage;
      expect(chatStatus.status, equals('transcribing'));
      expect(chatStatus.text, equals('מפענח הודעה קולית (Whisper)...'));
    });

    test('Chunk streaming and reassembly of binary payload', () {
      // Simulate binary data of 100KB
      final originalBytes = Uint8List(100 * 1024);
      for (int i = 0; i < originalBytes.length; i++) {
        originalBytes[i] = i % 256;
      }

      const chunkSize = 32 * 1024;
      final totalChunks = (originalBytes.length / chunkSize).ceil();
      final chunks = <RemoteChatMediaChunk>[];

      for (int i = 0; i < totalChunks; i++) {
        final start = i * chunkSize;
        final end = (start + chunkSize < originalBytes.length)
            ? start + chunkSize
            : originalBytes.length;
        final chunkSlice = originalBytes.sublist(start, end);

        final chunkCommand = RemoteChatMediaChunk(
          mediaId: 'media_test_1',
          messageId: 'msg_test_1',
          mediaType: 'image',
          fileName: 'car_photo.jpg',
          chunkIndex: i,
          totalChunks: totalChunks,
          data: base64Encode(chunkSlice),
          caption: i == 0 ? 'תמונת חזית' : null,
          timestamp: 1726000030,
        );

        // Serialize and deserialize over JSON protocol
        final decoded = RemoteCommand.decode(chunkCommand.encode()) as RemoteChatMediaChunk;
        chunks.add(decoded);
      }

      expect(chunks.length, equals(totalChunks));

      // Reassemble chunks
      final reassembledBuilder = BytesBuilder();
      for (final chunk in chunks) {
        reassembledBuilder.add(base64Decode(chunk.data));
      }
      final reassembledBytes = reassembledBuilder.toBytes();

      expect(reassembledBytes.length, equals(originalBytes.length));
      expect(reassembledBytes, equals(originalBytes));
    });
  });

  group('ChatMessageItem Persistence Tests', () {
    test('Serializes and deserializes ChatMessageItem to/from JSON correctly', () {
      final item = ChatMessageItem(
        id: 'msg_persist_1',
        sender: ChatSender.user,
        text: 'שלום, רכב לבדיקה 123-45-678',
        mediaType: 'image',
        localFilePath: '/data/user/0/cache/car.jpg',
        caption: 'תמונה ראשית',
        timestamp: DateTime.fromMillisecondsSinceEpoch(1726001234567),
        audioDuration: const Duration(seconds: 14),
      );

      final json = item.toJson();
      final jsonString = jsonEncode(json);
      final decodedMap = jsonDecode(jsonString) as Map<String, dynamic>;
      final restored = ChatMessageItem.fromJson(decodedMap);

      expect(restored.id, equals('msg_persist_1'));
      expect(restored.sender, equals(ChatSender.user));
      expect(restored.text, equals('שלום, רכב לבדיקה 123-45-678'));
      expect(restored.mediaType, equals('image'));
      expect(restored.localFilePath, equals('/data/user/0/cache/car.jpg'));
      expect(restored.caption, equals('תמונה ראשית'));
      expect(restored.timestamp.millisecondsSinceEpoch, equals(1726001234567));
      expect(restored.audioDuration?.inSeconds, equals(14));
    });
  });
}
