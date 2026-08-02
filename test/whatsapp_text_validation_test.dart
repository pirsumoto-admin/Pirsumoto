import 'package:flutter_test/flutter_test.dart';
import 'package:pirsumoto/services/whatsapp_text_validation_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  group('WhatsAppTextValidationService License Plate Extraction Tests', () {
    const service = WhatsAppTextValidationService();

    test('should extract 8-digit license plate with no spaces or dashes', () {
      final result = service.extractFieldsFromText('12345678');
      expect(result['license_plate'], equals('12345678'));
    });

    test('should extract 7-digit license plate with no spaces or dashes', () {
      final result = service.extractFieldsFromText('1234567');
      expect(result['license_plate'], equals('1234567'));
    });

    test('should extract 8-digit license plate with dashes', () {
      final result = service.extractFieldsFromText('123-45-678');
      expect(result['license_plate'], equals('12345678'));
    });

    test('should extract 7-digit license plate with dashes', () {
      final result = service.extractFieldsFromText('12-345-67');
      expect(result['license_plate'], equals('1234567'));
    });

    test('should extract license plate when prefixed with hebrew text', () {
      final result = service.extractFieldsFromText('היי, מספר הרכב שלי הוא 12-345-67');
      expect(result['license_plate'], equals('1234567'));
    });

    test('should ignore non-license plate numbers of other lengths', () {
      final result = service.extractFieldsFromText('12345');
      expect(result['license_plate'], isNull);
    });
  });

  group('WhatsAppTextValidationService Strict Required Fields Validation Tests', () {
    const service = WhatsAppTextValidationService();

    test('should identify missing fields when only plate, km, and price are present', () async {
      final state = {
        'license_plate': '12345678',
        'km': '10000',
        'price': '50000',
      };
      final result = await service.validateWhatsAppTextMessage(
        text: 'some message',
        existingState: state,
      );
      expect(result.readyToPublish, isFalse);
      expect(result.missingFields, contains('maker'));
      expect(result.missingFields, contains('model'));
      expect(result.missingFields, contains('year'));
      expect(result.missingFields, contains('color'));
      expect(result.missingFields, contains('hand'));
      expect(result.missingFields, contains('test_month'));
      expect(result.missingFields, contains('test_year'));
      expect(result.missingFields, contains('current_ownership'));
    });

    test('should be ready to publish when all required fields are present', () async {
      final state = {
        'license_plate': '12345678',
        'km': '10000',
        'price': '50000',
        'maker': 'מאזדה',
        'model': '3',
        'year': '2018',
        'color': 'כחול',
        'gear_type': 'אוטומטי',
        'hand': '2',
        'test_month': '5',
        'test_year': '2026',
        'current_ownership': 'פרטית',
      };
      final result = await service.validateWhatsAppTextMessage(
        text: 'some message',
        existingState: state,
      );
      expect(result.readyToPublish, isTrue);
      expect(result.missingFields, isEmpty);
      expect(result.validationErrors, isEmpty);
    });
  });

  group('WhatsAppTextValidationService Km and Price Extraction Tests', () {
    const service = WhatsAppTextValidationService();

    test('should extract km in various formats', () {
      expect(service.extractFieldsFromText('נסע 120,000 ק״מ')['km'], equals('120000'));
      expect(service.extractFieldsFromText('שעון 95000')['km'], equals('95000'));
      expect(service.extractFieldsFromText('קילומטראז׳ 80 אלף')['km'], equals('80000'));
      expect(service.extractFieldsFromText('150000 קילומטרים')['km'], equals('150000'));
    });

    test('should extract price in various formats', () {
      expect(service.extractFieldsFromText('מבקש 45,000 ש״ח')['price'], equals('45000'));
      expect(service.extractFieldsFromText('דורש 50000 ₪')['price'], equals('50000'));
      expect(service.extractFieldsFromText('רוצה 35 אלף שח')['price'], equals('35000'));
      expect(service.extractFieldsFromText('מחיר: 60000')['price'], equals('60000'));
    });
  });

  group('WhatsAppTextValidationService Hand Normalization Tests', () {
    const service = WhatsAppTextValidationService();

    test('should successfully validate form when hand is a Hebrew string like "יד שנייה"', () async {
      final fields = {
        'license_plate': '12345678',
        'km': '100000',
        'price': '40000',
        'hand': 'יד שנייה',
      };
      final result = await service.validateFormFields(fields);
      expect(result.isValid, isTrue);
      expect(result.errors, isEmpty);
    });

    test('should successfully validate form when hand is "שלישית"', () async {
      final fields = {
        'license_plate': '12345678',
        'km': '100000',
        'price': '40000',
        'hand': 'שלישית',
      };
      final result = await service.validateFormFields(fields);
      expect(result.isValid, isTrue);
      expect(result.errors, isEmpty);
    });

    test('should fail validation when hand is invalid text', () async {
      final fields = {
        'license_plate': '12345678',
        'km': '100000',
        'price': '40000',
        'hand': 'לא ידוע',
      };
      final result = await service.validateFormFields(fields);
      expect(result.isValid, isFalse);
      expect(result.errors, contains('מספר יד חייב להיות בין 1 ל-15'));
    });

    test('should merge hand when session is active and user sends only hand', () async {
      final existing = {
        'license_plate': '12345678',
        'maker': 'מאזדה',
        'model': '3',
        'year': '2018',
        'color': 'כחול',
      };
      final result = await service.validateWhatsAppTextMessage(
        text: 'יד שניה',
        existingState: existing,
      );
      
      expect(result.extractedFields['hand'], equals('2'));
    });
  });

  group('WhatsAppTextValidationService Session Management & Historical Filtering Tests', () {
    const service = WhatsAppTextValidationService();

    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test('should ignore messages with timestamp before session start timestamp', () async {
      final state1 = await service.handleIncomingTextMessage(
        text: '5211639',
        senderKey: 'test_sender',
        timestamp: 1000,
      );
      expect(state1?['session_start_timestamp'], equals('1000'));

      final state2 = await service.handleIncomingTextMessage(
        text: 'שעון 88000',
        senderKey: 'test_sender',
        timestamp: 900,
      );
      expect(state2?['km'], isNull);

      final state3 = await service.handleIncomingTextMessage(
        text: 'שעון 88000',
        senderKey: 'test_sender',
        timestamp: 1100,
      );
      expect(state3?['km'], equals('88000'));
    });

    test('should clear history when a new license plate is received to start a new session', () async {
      final initial = await service.handleIncomingTextMessage(
        text: '5211639 שעון 88000 מחיר 20000',
        senderKey: 'test_sender',
        timestamp: 1000,
      );
      expect(initial?['km'], equals('88000'));
      expect(initial?['price'], equals('20000'));

      final state2 = await service.handleIncomingTextMessage(
        text: '12345678',
        senderKey: 'test_sender',
        timestamp: 2000,
      );
      expect(state2?['license_plate'], equals('12345678'));
      expect(state2?['km'], isNull);
      expect(state2?['price'], isNull);
      expect(state2?['session_start_timestamp'], equals('2000'));
    });
  });
}
