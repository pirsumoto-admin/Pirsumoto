import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:publication_protocol/publication_protocol.dart';

void main() {
  test('both apps and backend share required fields and enum constraints', () {
    final schema = jsonDecode(
      File('functions/vehicle-schema.json').readAsStringSync(),
    );
    expect(requiredVehicleFields, schema['required']);
    expect(vehicleEnums, schema['enums']);
  });
  test('invalid vehicle data cannot pass readiness', () {
    expect(
      VehicleSchema.errors({
        'license_plate': 'abc',
        'hand': 'banana',
        'km': '-50',
        'price': '1000oops',
        'fuel_type': 'unknown',
      }),
      hasLength(5),
    );
    expect(
      VehicleSchema.missing({
        'license_plate': '1234567',
        'km': '1',
        'price': '2',
        'hand': '1',
        'color': 'לבן',
      }),
      containsAll(['maker', 'model', 'year', 'gear_type']),
    );
  });
  test(
    'formatted and spoken plates work, prices do not start a new vehicle',
    () {
      expect(VehicleSchema.extractPlate('12-345-67'), '1234567');
      expect(
        VehicleSchema.extractPlate(
          'מספר רכב שבע שמונה שמונה שתיים ארבע שלוש שלוש',
        ),
        '7882433',
      );
      expect(VehicleSchema.extractPlate('מחיר 1234567'), isNull);
      expect(VehicleSchema.normalizeSpeech('שמונה עשרה'), '18');
    },
  );
  test(
    'terminal jobs and canceling jobs cannot be revived by delayed events',
    () {
      for (final state in PublicationState.terminal) {
        expect(PublicationState.canTransition(state, 'publishing'), isFalse);
      }
      expect(PublicationState.canTransition('canceling', 'completed'), isFalse);
      expect(PublicationState.canTransition('canceling', 'canceled'), isTrue);
      expect(PublicationState.canTransition('queued', 'completed'), isFalse);
    },
  );
  test('publication completion requires positive confirmation', () {
    expect(PublicationConfirmation.yad2('המודעה שלך פורסמה בהצלחה'), true);
    expect(PublicationConfirmation.yad2('המודעה שלך לא פורסמה'), false);
    expect(PublicationConfirmation.yad2('המודעה נשלחה לאישור'), false);
    expect(PublicationConfirmation.yad2('לשלב הבא'), false);
    expect(
      PublicationConfirmation.facebook('Your listing has been published', ''),
      true,
    );
    expect(
      PublicationConfirmation.facebook('Your listing has been removed', ''),
      false,
    );
    expect(
      PublicationConfirmation.facebook(
        'Publish listing',
        'https://www.facebook.com/marketplace/create/vehicle',
      ),
      false,
    );
    expect(
      PublicationConfirmation.facebook(
        '',
        'https://www.facebook.com/marketplace/item/123',
      ),
      true,
    );
    expect(
      PublicationConfirmation.facebook(
        '',
        'https://example.com/marketplace/item/123',
      ),
      false,
    );
  });
}
