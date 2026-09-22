import 'package:flutter_test/flutter_test.dart';
import 'package:pirsumoto_remote_control/services/remote_validation_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('RemoteValidationService Tests', () {
    test('Calculates missing fields accurately', () {
      final incomplete = {
        'license_plate': '1234567',
        'maker': 'Toyota',
        'model': 'Corolla',
        'year': '2020',
      };
      final missing = RemoteValidationService.getMissingFields(incomplete);
      expect(missing, containsAll(['km', 'price', 'hand', 'color']));

      final complete = {
        'license_plate': '1234567',
        'maker': 'Toyota',
        'model': 'Corolla',
        'year': '2020',
        'km': '100000',
        'price': '45000',
        'hand': '1',
        'color': 'לבן',
        'fuel_type': 'בנזין',
        'gear_type': 'אוטומטי',
        'current_ownership': 'פרטית',
        'previous_ownership': 'פרטית',
        'month': '5',
        'vehicle_condition': 'טוב',
        'city': 'חיפה',
        'handicapped': 'לא',
        'no_test': 'לא',
      };
      final missingComplete = RemoteValidationService.getMissingFields(
        complete,
      );
      expect(missingComplete, isEmpty);
    });

    test('Validates numeric fields properly', () {
      final invalid = {'km': '-50', 'price': '0'};
      final errors = RemoteValidationService.validateValues(invalid);
      expect(errors, isNotEmpty);

      final valid = {'km': '120000', 'price': '45000'};
      final validErrors = RemoteValidationService.validateValues(valid);
      expect(validErrors, isEmpty);
    });

    test('Normalizes Hebrew speech to digits', () {
      final raw = 'מספר רכב שבע שמונה שמונה שתיים ארבע שלוש שלוש';
      final normalized = RemoteValidationService.normalizeTranscribedText(raw);
      expect(normalized, contains('7'));
      expect(normalized, contains('8'));
      expect(normalized, contains('2'));
    });
  });
}
