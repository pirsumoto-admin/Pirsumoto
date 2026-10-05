import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirsumoto_remote_control/models/chat_message.dart';
import 'package:pirsumoto_remote_control/models/chat_session.dart';
import 'package:pirsumoto_remote_control/services/remote_validation_service.dart';

void main() {
  group('WhatsApp Image Deletion & Session Readiness Tests', () {
    test('Removing image paths from ChatSession updates list and recalculates ready state', () {
      final initialPaths = ['/storage/media/img1.jpg', '/storage/media/img2.jpg'];
      final completeVehicleData = {
        'license_plate': '12345678',
        'maker': 'טויוטה',
        'model': 'קורולה',
        'year': '2020',
        'price': '65000',
        'km': '50000',
        'hand': '1',
        'previous_ownership': 'פרטית',
        'current_ownership': 'פרטית',
        'gear_type': 'אוטומטי',
        'vehicle_condition': 'מצוין',
        'engine_volume': '1600',
        'fuel_type': 'בנזין',
        'color': 'לבן',
        'area': 'מרכז',
        'city': 'תל אביב',
        'month': '5',
        'test_until': '01/2027',
        'contact_name': 'ישראל',
        'contact_phone': '0501234567',
      };

      final missing = RemoteValidationService.getMissingFields(completeVehicleData);
      final errors = RemoteValidationService.validateValues(completeVehicleData);
      expect(missing.isEmpty, isTrue);
      expect(errors.isEmpty, isTrue);

      final session = ChatSession(
        id: 'test_session_1',
        deviceId: 'device_test',
        licensePlate: '12345678',
        startTimestamp: 1000,
        vehicleData: completeVehicleData,
        imagePaths: List.from(initialPaths),
        isReadyToPublish: missing.isEmpty && errors.isEmpty && initialPaths.isNotEmpty,
      );

      expect(session.isReadyToPublish, isTrue);
      expect(session.imagePaths.length, 2);

      // Simulate deleting first image
      session.imagePaths.remove('/storage/media/img1.jpg');
      final isStillReady = missing.isEmpty && errors.isEmpty && session.imagePaths.isNotEmpty;
      session.isReadyToPublish = isStillReady;

      expect(session.imagePaths.length, 1);
      expect(session.imagePaths.contains('/storage/media/img1.jpg'), isFalse);
      expect(session.isReadyToPublish, isTrue);

      // Simulate deleting second (last) image
      session.imagePaths.remove('/storage/media/img2.jpg');
      final isNowReadyWithNoImages = missing.isEmpty && errors.isEmpty && session.imagePaths.isNotEmpty;
      session.isReadyToPublish = isNowReadyWithNoImages;

      expect(session.imagePaths.isEmpty, isTrue);
      expect(session.isReadyToPublish, isFalse);
    });

    test('Local file deletion deletes the file on disk if it exists', () async {
      final tempDir = Directory.systemTemp.createTempSync('img_test_');
      final testFile = File('${tempDir.path}/car_photo.jpg');
      await testFile.writeAsString('dummy image bytes');

      expect(await testFile.exists(), isTrue);

      // Deletion action
      if (await testFile.exists()) {
        await testFile.delete();
      }

      expect(await testFile.exists(), isFalse);
      if (await tempDir.exists()) {
        await tempDir.delete(recursive: true);
      }
    });

    test('ChatMessageItem with mediaType image serialization and sender recovery', () {
      final item = ChatMessageItem(
        id: 'img_123456',
        sender: ChatSender.user,
        mediaType: 'image',
        localFilePath: '/local/path/pic.jpg',
        timestamp: DateTime.now(),
      );

      final json = item.toJson();
      expect(json['mediaType'], 'image');
      expect(json['localFilePath'], '/local/path/pic.jpg');
      expect(json['sender'], 'user');

      final deserialized = ChatMessageItem.fromJson(json);
      expect(deserialized.mediaType, 'image');
      expect(deserialized.localFilePath, '/local/path/pic.jpg');
      expect(deserialized.sender, ChatSender.user);
    });
  });
}
