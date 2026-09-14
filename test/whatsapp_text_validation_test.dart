import 'dart:convert';
import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:pirsumoto/services/whatsapp_text_validation_service.dart';
import 'package:pirsumoto/services/yad2_accessibility_automation_service_optimized.dart';
import 'package:shared_preferences/shared_preferences.dart';

WhatsAppTextValidationService _buildService({
  String rawColor = 'כחול',
  int? lastTestKilometer,
  List<String>? replies,
  void Function()? onVehicleLookup,
  void Function()? onStop,
}) {
  return WhatsAppTextValidationService(
    vehicleDataFetcher: (license) async {
      onVehicleLookup?.call();
      return {
        'maker': 'מאזדה',
        'model': '3',
        'year': '2018',
        'color': rawColor,
        'fuelType': 'בנזין',
        'ownership': 'פרטי',
        'registrationMonth': '5',
        'testExpiry': '6,2027',
      };
    },
    kilometerHistoryFetcher: (_) async => lastTestKilometer,
    replySender: ({required senderKey, required message}) async {
      replies?.add(message);
      return true;
    },
    autoPublishLauncher: (_) async => true,
    automationStopper: onStop ?? () {},
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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
      final result = service.extractFieldsFromText(
        'היי, מספר הרכב שלי הוא 12-345-67',
      );
      expect(result['license_plate'], equals('1234567'));
    });

    test('should ignore non-license plate numbers of other lengths', () {
      final result = service.extractFieldsFromText('12345');
      expect(result['license_plate'], isNull);
    });

    test(
      'should not start a session from a 7-digit price or kilometer value',
      () {
        expect(
          service.extractFieldsFromText('מחיר 1234567')['license_plate'],
          isNull,
        );
        expect(
          service.extractFieldsFromText('ק״מ 1234567')['license_plate'],
          isNull,
        );
      },
    );
  });

  group(
    'WhatsAppTextValidationService Strict Required Fields Validation Tests',
    () {
      const service = WhatsAppTextValidationService();

      test(
        'should identify missing fields when only plate, km, and price are present',
        () async {
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
          expect(result.missingFields, contains('month'));
          expect(result.missingFields, contains('previous_ownership'));
        },
      );

      test(
        'should be ready to publish when all required fields are present',
        () async {
          final state = {
            'license_plate': '12345678',
            'km': '10000',
            'price': '50000',
            'maker': 'מאזדה',
            'model': '3',
            'year': '2018',
            'color': 'כחול',
            'month': '5',
            'gear_type': 'אוטומטי',
            'hand': '2',
            'test_month': '5',
            'test_year': '2026',
            'current_ownership': 'פרטית',
            'previous_ownership': 'פרטית',
          };
          final result = await service.validateWhatsAppTextMessage(
            text: 'some message',
            existingState: state,
          );
          expect(result.readyToPublish, isTrue);
          expect(result.missingFields, isEmpty);
          expect(result.validationErrors, isEmpty);
        },
      );

      test('should reject present but invalid Yad2 values', () async {
        final state = {
          'license_plate': '12345678',
          'km': '10000',
          'price': '50000',
          'maker': 'מאזדה',
          'model': '3',
          'year': '2018',
          'color': 'כסוף מטאלי',
          'month': '15',
          'hand': '2',
          'test_month': '5',
          'test_year': '2026',
          'current_ownership': 'פרטית',
          'previous_ownership': 'פרטית',
        };

        final result = await service.validateWhatsAppTextMessage(
          text: 'nothing new',
          existingState: state,
        );

        expect(result.readyToPublish, isFalse);
        expect(result.validationErrors, contains(contains('הצבע')));
        expect(result.validationErrors, contains(contains('חודש עלייה')));
      });
    },
  );

  group('WhatsAppTextValidationService Km and Price Extraction Tests', () {
    const service = WhatsAppTextValidationService();

    test('should extract km in various formats', () {
      expect(
        service.extractFieldsFromText('נסע 120,000 ק״מ')['km'],
        equals('120000'),
      );
      expect(
        service.extractFieldsFromText('120.000 קמ')['km'],
        equals('120000'),
      );
      expect(
        service.extractFieldsFromText('שעון 95000')['km'],
        equals('95000'),
      );
      expect(
        service.extractFieldsFromText('על השעון 88,000')['km'],
        equals('88000'),
      );
      expect(
        service.extractFieldsFromText('קילומטראז׳ 80 אלף')['km'],
        equals('80000'),
      );
      expect(
        service.extractFieldsFromText('150000 קילומטרים')['km'],
        equals('150000'),
      );
      expect(
        service.extractFieldsFromText('50,000 מייל')['km'],
        equals('80467'),
      );
      expect(
        service.extractFieldsFromText('60000 miles')['km'],
        equals('96560'),
      );
    });

    test('should extract price in various formats', () {
      expect(
        service.extractFieldsFromText('מבקש 45,000 ש״ח')['price'],
        equals('45000'),
      );
      expect(
        service.extractFieldsFromText('דורש 50000 ₪')['price'],
        equals('50000'),
      );
      expect(
        service.extractFieldsFromText('רוצה 35 אלף שח')['price'],
        equals('35000'),
      );
      expect(
        service.extractFieldsFromText('מחיר: 60000')['price'],
        equals('60000'),
      );
    });
  });

  group('WhatsAppTextValidationService Hand Normalization Tests', () {
    const service = WhatsAppTextValidationService();

    test(
      'should successfully validate form when hand is a Hebrew string like "יד שנייה"',
      () async {
        final fields = {
          'license_plate': '12345678',
          'km': '100000',
          'price': '40000',
          'hand': 'יד שנייה',
        };
        final result = await service.validateFormFields(fields);
        expect(result.isValid, isTrue);
        expect(result.errors, isEmpty);
      },
    );

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

    test(
      'should merge hand when session is active and user sends only hand',
      () async {
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
      },
    );
  });

  group(
    'WhatsAppTextValidationService Session Management & Historical Filtering Tests',
    () {
      late WhatsAppTextValidationService service;

      setUp(() {
        SharedPreferences.setMockInitialValues({});
        service = _buildService();
      });

      test(
        'should ignore messages with timestamp before session start timestamp',
        () async {
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
        },
      );

      test(
        'should clear history when a new license plate is received to start a new session',
        () async {
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
        },
      );
    },
  );

  group(
    'WhatsAppTextValidationService Positional Answers, Chat History, and Explicit Demands',
    () {
      late WhatsAppTextValidationService service;

      setUp(() {
        SharedPreferences.setMockInitialValues({});
        service = _buildService();
      });

      test(
        'should extract positional answers in missing details order (price, km)',
        () async {
          final existingState = {
            'license_plate': '12345678',
            'maker': 'מאזדה',
            'model': '3',
            'year': '2018',
            'color': 'כחול',
            'month': '5',
            'hand': '2',
            'test_month': '5',
            'test_year': '2026',
            'current_ownership': 'פרטית',
            'previous_ownership': 'פרטית',
          };
          // Missing fields in order: price, km
          final result = await service.validateWhatsAppTextMessage(
            text: '22000\n150000',
            existingState: existingState,
          );

          expect(result.extractedFields['price'], equals('22000'));
          expect(result.extractedFields['km'], equals('150000'));
          expect(result.readyToPublish, isTrue);
        },
      );

      test(
        'should extract 3 missing fields when user responds with 3 comma-separated values in exact order',
        () async {
          final existingState = {
            'license_plate': '12345678',
            'maker': 'מאזדה',
            'model': '3',
            'year': '2018',
            'color': 'כחול',
            'month': '5',
            'test_month': '5',
            'test_year': '2026',
            'current_ownership': 'פרטית',
            'previous_ownership': 'פרטית',
          };
          // Missing fields in order: hand, price, km
          final result = await service.validateWhatsAppTextMessage(
            text: '2, 35000, 110000',
            existingState: existingState,
          );

          expect(result.extractedFields['hand'], equals('2'));
          expect(result.extractedFields['price'], equals('35000'));
          expect(result.extractedFields['km'], equals('110000'));
          expect(result.readyToPublish, isTrue);
        },
      );

      test(
        'should extract valid fields and prompt for invalid input when one of 3 fields does not make sense',
        () async {
          final existingState = {
            'license_plate': '12345678',
            'maker': 'מאזדה',
            'model': '3',
            'year': '2018',
            'color': 'כחול',
            'month': '5',
            'test_month': '5',
            'test_year': '2026',
            'current_ownership': 'פרטית',
            'previous_ownership': 'פרטית',
          };
          // Missing fields in order: hand, price, km
          // First is hand (invalid text), second is price, third is km
          final result = await service.validateWhatsAppTextMessage(
            text: 'לא-ידוע\n35000\n110000',
            existingState: existingState,
          );

          expect(result.readyToPublish, isFalse);
          expect(result.extractedFields['price'], equals('35000'));
          expect(result.extractedFields['km'], equals('110000'));
          expect(result.extractedFields['hand'], isNull);
          expect(result.missingFields, contains('hand'));
        },
      );

      test(
        'should extract single number input 158990 as km when km is the only missing field',
        () async {
          final existingState = {
            'license_plate': '12345678',
            'maker': 'מאזדה',
            'model': '3',
            'year': '2018',
            'color': 'כחול',
            'month': '5',
            'hand': '2',
            'price': '35000',
            'test_month': '5',
            'test_year': '2026',
            'current_ownership': 'פרטית',
            'previous_ownership': 'פרטית',
            'last_requested_fields': '["km"]',
          };
          final result = await service.validateWhatsAppTextMessage(
            text: '158990',
            existingState: existingState,
          );

          expect(result.extractedFields['km'], equals('158990'));
          expect(result.readyToPublish, isTrue);
        },
      );

      test(
        'should extract 155880 as km even when both price and km are missing',
        () async {
          final existingState = {
            'license_plate': '12345678',
            'maker': 'מאזדה',
            'model': '3',
            'year': '2018',
            'color': 'כחול',
            'month': '5',
            'hand': '2',
            'test_month': '5',
            'test_year': '2026',
            'current_ownership': 'פרטית',
            'previous_ownership': 'פרטית',
            'last_requested_fields': '["price", "km"]',
          };
          final result = await service.validateWhatsAppTextMessage(
            text: '155880',
            existingState: existingState,
          );

          expect(result.extractedFields['km'], equals('155880'));
          expect(result.extractedFields['price'], isNull);
        },
      );

      test(
        'should correct previous invalid km with single number input 155990',
        () async {
          // Turn 1: user sent 123000 which is less than kilometer_test_aharon (155260)
          final state1 = {
            'license_plate': '5211639',
            'maker': 'סיטרואן',
            'model': 'C4 CACTUS',
            'year': '2016',
            'color': 'לבן',
            'month': '5',
            'hand': '1',
            'price': '22000',
            'km': '123000',
            'test_month': '5',
            'test_year': '2026',
            'current_ownership': 'פרטית',
            'previous_ownership': 'פרטית',
            'kilometer_test_aharon': '155260',
            'last_requested_fields': '["km"]',
          };
          // Turn 2: user enters single number 155990 to correct the invalid km
          final result = await service.validateWhatsAppTextMessage(
            text: '155990',
            existingState: state1,
            kilometerTestAharon: 155260,
          );

          expect(result.extractedFields['km'], equals('155990'));
          expect(result.validationErrors, isEmpty);
          expect(result.readyToPublish, isTrue);
        },
      );

      test(
        'should extract positional answers with english "good" for vehicle condition',
        () async {
          final existingState = {
            'license_plate': '12345678',
            'maker': 'מאזדה',
            'model': '3',
            'year': '2018',
            'color': 'כחול',
            'month': '5',
            'hand': '2',
            'test_month': '5',
            'test_year': '2026',
            'current_ownership': 'פרטית',
            'previous_ownership': 'פרטית',
            'vehicle_condition': '',
          };
          final result = await service.validateWhatsAppTextMessage(
            text: '22000\n150000\ngood',
            existingState: existingState,
          );

          expect(result.extractedFields['price'], equals('22000'));
          expect(result.extractedFields['km'], equals('150000'));
          expect(result.extractedFields['vehicle_condition'], equals('טוב'));
        },
      );

      test(
        'should record chat_history in state across session turns and reset on new session',
        () async {
          final state1 = await service.handleIncomingTextMessage(
            text: '12345678',
            senderKey: 'history_sender',
            timestamp: 1000,
          );

          expect(state1?['chat_history'], isNotNull);
          expect(state1!['chat_history']!, contains('12345678'));

          final state2 = await service.handleIncomingTextMessage(
            text: '25000\n120000',
            senderKey: 'history_sender',
            timestamp: 1050,
          );

          expect(state2!['price'], equals('25000'));
          expect(state2['km'], equals('120000'));
          expect(state2['chat_history']!, contains('25000'));

          // Send new license plate -> session resets, chat_history cleared and restarted
          final state3 = await service.handleIncomingTextMessage(
            text: '87654321',
            senderKey: 'history_sender',
            timestamp: 2000,
          );

          expect(state3!['license_plate'], equals('87654321'));
          expect(state3['price'], isNull);
          expect(state3['chat_history']!, contains('87654321'));
          expect(state3['chat_history']!, isNot(contains('12345678')));
        },
      );

      test(
        'should compose explicit demand when user sends irrelevant message while fields missing',
        () async {
          final existingState = {
            'license_plate': '12345678',
            'maker': 'מאזדה',
            'model': '3',
            'year': '2018',
          };
          final result = await service.validateWhatsAppTextMessage(
            text: 'מה המצב אחי',
            existingState: existingState,
          );

          expect(result.readyToPublish, isFalse);
          expect(result.replyHebrew, contains('חסרים עדיין הנתונים הבאים'));
          expect(result.replyHebrew, contains('שלח את הערכים עם שם השדה'));
        },
      );

      test(
        'should map a government color missing from Yad2 to the closest allowed color',
        () async {
          service = _buildService(rawColor: 'כסוף מטאלי');
          final state = await service.handleIncomingTextMessage(
            text: '5211639',
            senderKey: 'color_test_sender',
            timestamp: 1000,
          );

          expect(state, isNotNull);
          expect(state!['color'], isNotNull);
          expect(state['gov_raw_color'], equals('כסוף מטאלי'));
          expect(state['color'], equals('אפור'));
        },
      );
    },
  );

  group('WhatsAppTextValidationService Lifecycle and Status Updates', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test(
      'runs government lookup once and sends single searching status then asks for missing details',
      () async {
        var vehicleLookups = 0;
        final replies = <String>[];
        final service = _buildService(
          replies: replies,
          onVehicleLookup: () => vehicleLookups++,
        );

        final initial = await service.handleIncomingTextMessage(
          text: '12345678',
          senderKey: 'single_lookup_sender',
          timestamp: 1000,
        );

        expect(vehicleLookups, 1);
        expect(initial?['km'], isNull);
        expect(initial?['kilometer_test_aharon'], isNull);
        expect(replies.length, equals(2));
        expect(replies[0], contains('מחפש את פרטי הרכב ב-gov.il'));
        expect(replies[1], contains('מצאתי את הרכב: מאזדה 3 2018'));
        expect(replies[1], contains('אנא השלם את הפרטים החסרים'));

        final afterHand = await service.handleIncomingTextMessage(
          text: '2',
          senderKey: 'single_lookup_sender',
          timestamp: 1100,
        );

        expect(vehicleLookups, 1);
        expect(afterHand?['hand'], '2');
        expect(afterHand?['image_expected_count'], isNull);
      },
    );

    test(
      'asks to enter full details when vehicle is not found in gov.il',
      () async {
        final replies = <String>[];
        final service = WhatsAppTextValidationService(
          vehicleDataFetcher: (_) async => null,
          kilometerHistoryFetcher: (_) async => null,
          replySender: ({required senderKey, required message}) async {
            replies.add(message);
            return true;
          },
        );

        final result = await service.handleIncomingTextMessage(
          text: '99999999',
          senderKey: 'not_found_sender',
          timestamp: 1000,
        );

        expect(result?['license_not_found_gov'], equals('true'));
        expect(replies.length, equals(2));
        expect(replies[0], contains('מחפש את פרטי הרכב ב-gov.il'));
        expect(replies[1], contains('לא נמצאו פרטי רכב במאגר gov.il'));
        expect(replies[1], contains('אנא הזן את כל פרטי הרכב הנדרשים'));
        expect(replies[1], contains('יצרן'));
        expect(replies[1], contains('דגם'));
        expect(replies[1], contains('שנת ייצור'));
      },
    );

    test('recognizes לבטל and clears all active session state', () async {
      var stopCalls = 0;
      final replies = <String>[];
      final service = _buildService(
        replies: replies,
        onStop: () => stopCalls++,
      );

      await service.handleIncomingTextMessage(
        text: '12345678',
        senderKey: 'cancel_sender',
        timestamp: 1000,
      );
      final result = await service.handleIncomingTextMessage(
        text: 'לבטל',
        senderKey: 'cancel_sender',
        timestamp: 1100,
      );

      expect(result, isEmpty);
      expect(await service.loadSenderState('cancel_sender'), isEmpty);
      expect(stopCalls, 2);
      expect(replies.last, contains('הסשן נסגר'));
    });

    test(
      'a license plate supersedes a session even while publishing',
      () async {
        var stopCalls = 0;
        final service = _buildService(onStop: () => stopCalls++);
        final first = await service.handleIncomingTextMessage(
          text: '12345678',
          senderKey: 'publishing_sender',
          timestamp: 1000,
        );
        first!['auto_publish_started'] = 'true';
        first['session_status'] = 'publishing';
        await service.saveSenderState('publishing_sender', first);

        final second = await service.handleIncomingTextMessage(
          text: '87654321',
          senderKey: 'publishing_sender',
          timestamp: 2000,
        );

        expect(second?['license_plate'], '87654321');
        expect(second?['session_status'], 'collecting_details');
        expect(second?['auto_publish_started'], isNull);
        expect(second?['session_start_timestamp'], '2000');
        expect(stopCalls, 2);
      },
    );

    test(
      'requires a license plate before accepting conversation details',
      () async {
        final replies = <String>[];
        final service = _buildService(replies: replies);

        final state = await service.handleIncomingTextMessage(
          text: 'מחיר 50000',
          senderKey: 'no_session_sender',
          timestamp: 1000,
        );

        expect(state, isEmpty);
        expect(replies.single, contains('שלח תחילה מספר רישוי'));
      },
    );
  });

  group('Agentic Assistant, Continuous Persistence, and Republishing Tests', () {
    test(
      'continuously saves user vehicle input and preserves it across cancellation',
      () async {
        final replies = <String>[];
        final service = _buildService(replies: replies);
        const sender = 'persist_sender_1';

        // 1. Start session with license plate
        await service.handleIncomingTextMessage(
          text: '12345678',
          senderKey: sender,
          timestamp: 1000,
        );

        // Check that last_vehicle already has license plate and gov data
        var lastVehicle = await service.loadLastVehicle(sender);
        expect(lastVehicle['license_plate'], equals('12345678'));
        expect(lastVehicle['maker'], equals('מאזדה'));

        // 2. User inputs km and price
        await service.handleIncomingTextMessage(
          text: 'ק"מ 105000, מחיר 48000, יד 1',
          senderKey: sender,
          timestamp: 2000,
        );

        lastVehicle = await service.loadLastVehicle(sender);
        expect(lastVehicle['km'], equals('105000'));
        expect(lastVehicle['price'], equals('48000'));
        expect(lastVehicle['hand'], equals('1'));

        // 3. User cancels the session
        await service.handleIncomingTextMessage(
          text: 'ביטול',
          senderKey: sender,
          timestamp: 3000,
        );

        // Active session state must be wiped
        final activeState = await service.loadSenderState(sender);
        expect(activeState, isEmpty);

        // BUT last_vehicle must still be intact with all saved inputs
        final preservedVehicle = await service.loadLastVehicle(sender);
        expect(preservedVehicle['license_plate'], equals('12345678'));
        expect(preservedVehicle['km'], equals('105000'));
        expect(preservedVehicle['price'], equals('48000'));
        expect(preservedVehicle['hand'], equals('1'));
        expect(preservedVehicle['maker'], equals('מאזדה'));
      },
    );

    test(
      'republishes saved car using literal command when session is idle',
      () async {
        final replies = <String>[];
        final service = _buildService(replies: replies);
        const sender = 'republish_sender_1';

        // Pre-seed a saved vehicle with all Yad2 required fields
        await service.saveLastVehicle(sender, {
          'license_plate': '12345678',
          'maker': 'מאזדה',
          'model': '3',
          'year': '2018',
          'color': 'כחול',
          'km': '110000',
          'price': '50000',
          'hand': '1',
          'month': '5',
          'test_month': '6',
          'test_year': '2027',
          'current_ownership': 'פרטי',
          'previous_ownership': 'פרטי',
        });

        // Ensure session is idle
        await service.clearSenderState(sender);
        expect(await service.loadSenderState(sender), isEmpty);

        // Send literal republish command
        final restoredState = await service.handleIncomingTextMessage(
          text: 'פרסם שוב',
          senderKey: sender,
          timestamp: 5000,
        );

        expect(restoredState, isNotNull);
        expect(restoredState?['license_plate'], equals('12345678'));
        expect(restoredState?['km'], equals('110000'));
        expect(restoredState?['price'], equals('50000'));
        expect(restoredState?['session_status'], equals('ready_for_images'));
        expect(replies.last, contains('שחזרתי את פרטי הרכב'));
      },
    );

    test(
      'agentic AI restores saved car and overrides updated price when user asks to republish',
      () async {
        final replies = <String>[];
        const sender = 'agentic_republish_sender';

        final service = WhatsAppTextValidationService(
          vehicleDataFetcher: (license) async => {
            'maker': 'מאזדה',
            'model': '3',
            'year': '2018',
            'color': 'כחול',
          },
          kilometerHistoryFetcher: (_) async => 90000,
          replySender: ({required senderKey, required message}) async {
            replies.add(message);
            return true;
          },
          aiTurnProcessor: (requestData) async {
            final msg = requestData['current_message']?.toString() ?? '';
            if (msg.contains('republish') || msg.contains('שוב')) {
              return const AiTurnResult(
                intent: 'republish_last',
                shouldRepublish: true,
                extractedFields: {'price': '42000'},
                assistantReply:
                    'שחזרתי את פרטי הרכב שלך ועדכנתי את המחיר ל-42,000 ש"ח! אפשר לשלוח תמונות כדי לפרסם.',
              );
            }
            return null;
          },
        );

        // Pre-seed saved vehicle
        await service.saveLastVehicle(sender, {
          'license_plate': '12345678',
          'maker': 'מאזדה',
          'model': '3',
          'year': '2018',
          'color': 'כחול',
          'km': '110000',
          'price': '50000',
          'hand': '1',
          'current_ownership': 'פרטי',
        });
        await service.clearSenderState(sender);

        // User asks to republish using agentic phrase
        final newState = await service.handleIncomingTextMessage(
          text: 'use my last updated data to republish a car with price 42000',
          senderKey: sender,
          timestamp: 6000,
        );

        expect(newState, isNotNull);
        expect(newState?['license_plate'], equals('12345678'));
        expect(newState?['price'], equals('42000')); // Overridden!
        expect(newState?['km'], equals('110000'));
        expect(
          replies.last,
          contains('שחזרתי את פרטי הרכב שלך ועדכנתי את המחיר ל-42,000 ש"ח!'),
        );
      },
    );

    test(
      'provides conversational guidance for greeting when idle and no car saved',
      () async {
        final replies = <String>[];
        const sender = 'greeting_sender';

        final service = WhatsAppTextValidationService(
          replySender: ({required senderKey, required message}) async {
            replies.add(message);
            return true;
          },
          aiTurnProcessor: (requestData) async {
            return const AiTurnResult(
              intent: 'greeting_or_help',
              assistantReply:
                  'שלום! אני כאן לעזור לך לפרסם את הרכב ביד2 ובפייסבוק. שלח לי את מספר הרישוי כדי שנתחיל.',
            );
          },
        );

        await service.clearSenderState(sender);
        await service.clearLastVehicle(sender);

        final state = await service.handleIncomingTextMessage(
          text: 'שלום איך זה עובד?',
          senderKey: sender,
          timestamp: 7000,
        );

        expect(state, isEmpty);
        expect(
          replies.last,
          contains(
            'שלום! אני כאן לעזור לך לפרסם את הרכב ביד2 ובפייסבוק. שלח לי את מספר הרישוי כדי שנתחיל.',
          ),
        );
      },
    );

    test(
      'provides conversational assistant guidance during active session turns',
      () async {
        final replies = <String>[];
        const sender = 'conversational_sender';

        final service = WhatsAppTextValidationService(
          vehicleDataFetcher: (license) async => {
            'maker': 'מאזדה',
            'model': '3',
            'year': '2018',
            'color': 'כחול',
          },
          kilometerHistoryFetcher: (_) async => 90000,
          replySender: ({required senderKey, required message}) async {
            replies.add(message);
            return true;
          },
          aiTurnProcessor: (requestData) async {
            final msg = requestData['current_message']?.toString() ?? '';
            if (msg.contains('120000')) {
              return const AiTurnResult(
                intent: 'update_details',
                extractedFields: {'km': '120000'},
                assistantReply:
                    'קלטתי 120,000 ק"מ! מה המחיר המבוקש עבור הרכב?',
              );
            }
            return null;
          },
        );

        // Start session
        await service.handleIncomingTextMessage(
          text: '12345678',
          senderKey: sender,
          timestamp: 8000,
        );

        // User enters km
        final updatedState = await service.handleIncomingTextMessage(
          text: 'נסע בערך 120000',
          senderKey: sender,
          timestamp: 8500,
        );

        expect(updatedState?['km'], equals('120000'));
        expect(
          replies.last,
          contains('קלטתי 120,000 ק"מ! מה המחיר המבוקש עבור הרכב?'),
        );
      },
    );

    test(
      'informs user politely when republish is requested but no saved car exists in storage',
      () async {
        final prefs = await SharedPreferences.getInstance();
        await prefs.clear();

        final replies = <String>[];
        final service = _buildService(replies: replies);
        const sender = 'republish_no_saved_sender';

        await service.clearSenderState(sender);
        await service.clearLastVehicle(sender);

        final state = await service.handleIncomingTextMessage(
          text: 'תוכל לחזור על הפרסום הקודם',
          senderKey: sender,
          timestamp: 9000,
        );

        expect(state, isEmpty);
        expect(
          replies.last,
          contains('לא נמצאו פרטי רכב שמורים מהעבר. שלח מספר רישוי'),
        );
      },
    );

    test(
      'resumes interrupted publication after cancellation when user asks to continue from where they stopped',
      () async {
        final prefs = await SharedPreferences.getInstance();
        await prefs.clear();

        final replies = <String>[];
        final service = _buildService(replies: replies);
        const sender = 'resume_after_cancel_sender';

        // 1. Initial vehicle setup
        await service.saveLastVehicle(sender, {
          'license_plate': '5211639',
          'maker': 'סיטרואן',
          'model': 'C4 CACTUS',
          'year': '2016',
          'km': '90000',
          'price': '18000',
          'color': 'חום',
          'month': '11',
          'test_month': '11',
          'test_year': '2026',
          'hand': '2',
          'current_ownership': 'פרטי',
          'previous_ownership': 'פרטי',
          'vehicle_condition': 'טוב',
        });

        // 2. User sends the exact Hebrew phrase from WhatsApp chat
        final restoredState = await service.handleIncomingTextMessage(
          text: 'תוכל לחזור להמשיך פרסום מהיכן שהפסקתי פעם קודמת',
          senderKey: sender,
          timestamp: 9500,
        );

        expect(restoredState, isNotNull);
        expect(restoredState!['license_plate'], equals('5211639'));
        expect(restoredState['km'], equals('90000'));
        expect(restoredState['price'], equals('18000'));
        expect(restoredState['session_status'], equals('ready_for_images'));
        expect(
          replies.last,
          contains('שחזרתי את פרטי הרכב (סיטרואן C4 CACTUS 2016, רישוי 5211639)'),
        );
      },
    );

    test(
      'strictly enforces image count: blocks when fewer images, caps when more images',
      () async {
        final prefs = await SharedPreferences.getInstance();
        await prefs.clear();

        final replies = <String>[];
        final service = _buildService(replies: replies);
        const sender = 'image_constraint_sender';

        // 1. Ready vehicle with 2 expected images
        await service.saveSenderState(sender, {
          'license_plate': '5211639',
          'maker': 'סיטרואן',
          'model': 'C4 CACTUS',
          'year': '2016',
          'km': '95000',
          'price': '18000',
          'color': 'חום',
          'month': '11',
          'test_month': '11',
          'test_year': '2026',
          'hand': '2',
          'current_ownership': 'פרטית',
          'previous_ownership': 'פרטית',
          'vehicle_condition': 'טוב',
          'image_expected_count': '2',
          'session_status': 'waiting_for_images',
          'image_paths': jsonEncode(['/path/photo1.jpg']),
          'image_received_count': '1',
        });

        // 2. User attempts to trigger publish with 0 when only 1 of 2 images provided
        final stateUnder = await service.handleIncomingTextMessage(
          text: '0',
          senderKey: sender,
          timestamp: 10000,
        );

        expect(stateUnder?['session_status'], equals('waiting_for_images'));
        expect(replies.last, contains('עדיין חסרות 1 תמונות'));
        expect(replies.last, contains('חובה להעלות בדיוק 2 תמונות'));

        // 3. Four images arrive for a target of 2
        await service.saveSenderState(sender, {
          ...?stateUnder,
          'image_paths': jsonEncode([
            '/path/photo1.jpg',
            '/path/photo2.jpg',
            '/path/photo3.jpg',
            '/path/photo4.jpg',
          ]),
          'image_received_count': '4',
        });

        // 4. Trigger publish
        final stateCapped = await service.handleIncomingTextMessage(
          text: '0',
          senderKey: sender,
          timestamp: 11000,
        );

        expect(stateCapped?['session_status'], equals('publishing'));
        final paths = List<String>.from(jsonDecode(stateCapped!['image_paths']!));
        expect(paths.length, equals(2));
        expect(paths, equals(['/path/photo3.jpg', '/path/photo4.jpg']));
      },
    );
  });

  group('MOE Missing Data Validation & Description Tests', () {
    const service = WhatsAppTextValidationService();

    test('should reject invalid description numbers like 0412 or 0/400 and accept valid description', () {
      expect(Yad2AccessibilityAutomationService.isValidExtractedDescription('0412'), isFalse);
      expect(Yad2AccessibilityAutomationService.isValidExtractedDescription('0/400'), isFalse);
      expect(Yad2AccessibilityAutomationService.isValidExtractedDescription('04/12'), isFalse);
      expect(Yad2AccessibilityAutomationService.isValidExtractedDescription('1234567'), isFalse);
      expect(Yad2AccessibilityAutomationService.isValidExtractedDescription('עדכנתי, בואו נמשיך'), isFalse);
      expect(Yad2AccessibilityAutomationService.isValidExtractedDescription(''), isFalse);
      expect(Yad2AccessibilityAutomationService.isValidExtractedDescription('קצר'), isFalse);
      expect(
        Yad2AccessibilityAutomationService.isValidExtractedDescription(
          'רכב שמור ומטופל במוסך מורשה, ללא תאונות, טסט לשנה מלאה',
        ),
        isTrue,
      );
    });

    test('should extract fuel_type from text', () {
      final benzine = service.extractFieldsFromText('רכב במצב מעולה דלק בנזין');
      expect(benzine['fuel_type'], equals('בנזין'));

      final diesel = service.extractFieldsFromText('מנוע דיזל סולר יד ראשונה');
      expect(diesel['fuel_type'], equals('דיזל'));

      final hybrid = service.extractFieldsFromText('היברידי 2020 במצב חדש');
      expect(hybrid['fuel_type'], equals('היברידי'));

      final electric = service.extractFieldsFromText('רכב חשמלי טסלה');
      expect(electric['fuel_type'], equals('חשמל'));
    });

    test('when data was NOT fetched from MOE, maker, model, fuel_type, and year are strictly required', () async {
      final fieldsMissingGov = {
        'license_plate': '12345678',
        'license_not_found_gov': 'true',
        'gov_vehicle_lookup_status': 'not_found',
        'km': '90000',
        'price': '35000',
        'hand': '1',
      };

      final validation = await service.validateFormFields(fieldsMissingGov);
      expect(validation.isValid, isFalse);
      expect(validation.fieldErrors.containsKey('maker'), isTrue);
      expect(validation.fieldErrors.containsKey('model'), isTrue);
      expect(validation.fieldErrors.containsKey('fuel_type'), isTrue);
      expect(validation.fieldErrors.containsKey('year'), isTrue);

      // Now fill the required fields
      final fieldsCompleteGov = {
        ...fieldsMissingGov,
        'maker': 'טויוטה',
        'model': 'קורולה',
        'fuel_type': 'בנזין',
        'year': '2019',
      };

      final validationComplete = await service.validateFormFields(fieldsCompleteGov);
      expect(validationComplete.fieldErrors.containsKey('maker'), isFalse);
      expect(validationComplete.fieldErrors.containsKey('model'), isFalse);
      expect(validationComplete.fieldErrors.containsKey('fuel_type'), isFalse);
      expect(validationComplete.fieldErrors.containsKey('year'), isFalse);
    });

    test('when data WAS fetched from MOE, maker, model, and fuel_type are not marked as error in basic check', () async {
      final fieldsWithGov = {
        'license_plate': '12345678',
        'license_not_found_gov': 'false',
        'gov_vehicle_lookup_status': 'succeeded',
        'km': '90000',
        'price': '35000',
        'hand': '1',
      };

      final validation = await service.validateFormFields(fieldsWithGov);
      expect(validation.fieldErrors.containsKey('fuel_type'), isFalse);
      expect(validation.fieldErrors.containsKey('maker'), isFalse);
      expect(validation.fieldErrors.containsKey('model'), isFalse);
    });
  });

  group('WhatsAppTextValidationService Last Test Kilometers & Estimation Logic', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    test(
      'when API returns last test kilometers, calculates estimated km, sets km in state, and does not require user to enter km',
      () async {
        final replies = <String>[];
        final service = WhatsAppTextValidationService(
          vehicleDataFetcher: (_) async => {
            'maker': 'מאזדה',
            'model': '3',
            'year': '2021',
            'color': 'כחול',
            'fuelType': 'בנזין',
            'ownership': 'פרטי',
            'registrationMonth': '1',
            'lastTestDate': '2026-03-01',
            'testExpiry': '3,2027',
          },
          kilometerHistoryFetcher: (_) async => 62000,
          replySender: ({required senderKey, required message}) async {
            replies.add(message);
            return true;
          },
        );

        final state = await service.handleIncomingTextMessage(
          text: '12345678',
          senderKey: 'km_exists_sender',
          timestamp: 1000,
        );

        // Raw test km is saved
        expect(state?['kilometer_test_aharon'], equals('62000'));
        // Estimated km is calculated and populated
        expect(state?['km'], isNotNull);
        final calculatedKm = int.parse(state!['km']!);
        expect(calculatedKm, greaterThan(62000));

        // The user should not be asked for km
        final missingList = jsonDecode(state['last_requested_fields'] ?? '[]') as List;
        expect(missingList.contains('km'), isFalse);

        expect(replies.length, equals(2));
        expect(replies.last, isNot(contains('קילומטראז\'')));
      },
    );

    test(
      'when API does NOT return test data, km remains missing and is required from the user',
      () async {
        final replies = <String>[];
        final service = WhatsAppTextValidationService(
          vehicleDataFetcher: (_) async => {
            'maker': 'מאזדה',
            'model': '3',
            'year': '2021',
            'color': 'כחול',
            'fuelType': 'בנזין',
            'ownership': 'פרטי',
            'registrationMonth': '1',
            'testExpiry': '3,2027',
          },
          kilometerHistoryFetcher: (_) async => null,
          replySender: ({required senderKey, required message}) async {
            replies.add(message);
            return true;
          },
        );

        final state = await service.handleIncomingTextMessage(
          text: '12345678',
          senderKey: 'km_missing_sender',
          timestamp: 1000,
        );

        expect(state?['kilometer_test_aharon'], isNull);
        expect(state?['km'], isNull);

        // km must be requested as a required field
        final missingList = jsonDecode(state?['last_requested_fields'] ?? '[]') as List;
        expect(missingList.contains('km'), isTrue);

        expect(replies.length, equals(2));
        expect(replies.last, contains('קילומטראז\''));
      },
    );

    test(
      'Multi-image upload: accepts several images at once, debounces confirmation, and publishes with all images',
      () async {
        final replies = <String>[];
        final launchedVehicles = <Map<String, String>>[];
        final service = WhatsAppTextValidationService(
          replySender: ({required senderKey, required message}) async {
            replies.add(message);
            return true;
          },
          autoPublishLauncher: (data) async {
            launchedVehicles.add(data);
            return true;
          },
        );

        final sender = 'multi_img_sender_test';
        await service.saveSenderState(sender, {
          'license_plate': '12345678',
          'maker': 'מאזדה',
          'model': '3',
          'year': '2020',
          'color': 'לבן',
          'fuel_type': 'בנזין',
          'gear_type': 'אוטומטית',
          'km': '50000',
          'price': '75000',
          'month': '5',
          'test_month': '11',
          'test_year': '2026',
          'hand': '2',
          'current_ownership': 'פרטית',
          'previous_ownership': 'פרטית',
          'vehicle_condition': 'טוב',
          'session_status': 'ready_for_images',
        });

        // Create 3 temp test image files
        final tempDir = await Directory.systemTemp.createTemp('multi_img_test_');
        final img1 = File('${tempDir.path}/img1.jpg')..writeAsBytesSync([1, 2, 3]);
        final img2 = File('${tempDir.path}/img2.jpg')..writeAsBytesSync([4, 5, 6]);
        final img3 = File('${tempDir.path}/img3.jpg')..writeAsBytesSync([7, 8, 9]);

        // Upload 3 images rapidly
        await service.handleIncomingImage(
          imageFilePath: img1.path,
          senderKey: sender,
        );
        await service.handleIncomingImage(
          imageFilePath: img2.path,
          senderKey: sender,
        );
        final stateAfter3 = await service.handleIncomingImage(
          imageFilePath: img3.path,
          senderKey: sender,
        );

        expect(stateAfter3?['session_status'], equals('ready_to_publish'));
        expect(stateAfter3?['image_received_count'], equals('3'));
        expect(stateAfter3?['image_expected_count'], equals('3'));

        // Wait for debounce timer to fire
        await Future.delayed(const Duration(milliseconds: 1600));

        expect(replies.length, equals(1));
        expect(replies.first, contains('התקבלו 3 תמונות בהצלחה!'));
        expect(replies.first, contains('לפרסום שלח 0'));

        // Send 0 to publish
        final statePublish = await service.handleIncomingTextMessage(
          text: '0',
          senderKey: sender,
        );

        expect(statePublish?['session_status'], equals('publishing'));
        expect(launchedVehicles.length, equals(1));
        final launchedPaths =
            List<String>.from(jsonDecode(launchedVehicles.first['image_paths']!));
        expect(launchedPaths.length, equals(3));
        expect(launchedPaths, contains(img1.path));
        expect(launchedPaths, contains(img2.path));
        expect(launchedPaths, contains(img3.path));

        // Cleanup
        tempDir.deleteSync(recursive: true);
      },
    );
  });
}
