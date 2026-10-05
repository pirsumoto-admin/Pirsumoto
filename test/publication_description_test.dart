import 'package:flutter_test/flutter_test.dart';
import 'package:publication_protocol/publication_protocol.dart';
import 'package:pirsumoto/services/yad2_automation_models.dart';
import 'package:pirsumoto/services/publication_description_service.dart';

const vehicle = VehiclePublishData(
  licenseNumber: '1234567',
  color: 'לבן',
  shade: 'לבן',
  hand: '2',
  currentOwnership: 'פרטית',
  previousOwnership: 'פרטית',
  kilometers: '80000',
  month: '5',
  price: '70000',
  handicapped: false,
  noTest: false,
  maker: 'טויוטה',
  model: 'קורולה',
  year: '2021',
  vehicleCondition: 'מצוין',
  highlights: 'טופל במוסך מורשה',
  cleanTitle: true,
);

void main() {
  test(
    'shared default template resolves actual car fields and optional claims',
    () {
      expect(
        vehicle.descriptionFromTemplate(VehicleDescriptionTemplate.defaultText),
        'רכב: טויוטה קורולה שנת 2021 בצבע לבן\n'
        'יד: 2 | ק"מ: 80000\nבמצב: מצוין\n'
        'חוזקות הרכב: טופל במוסך מורשה\nלרכב זה יש טייטל נקי',
      );
    },
  );
  test(
    'publishers load the shared saved template and preserve it through copies',
    () async {
      final copy = vehicle.copyWith(description: 'חשוב לדעת: טופל במוסך מורשה');
      final rendered = await PublicationDescriptionService.load(
        copy,
        settingsLoader: () async => {'yad2Desc': '{יצרן}: {חוזקות} ({מחיר})'},
      );
      expect(
        rendered,
        'טויוטה: טופל במוסך מורשה (70000)\nלרכב זה יש טייטל נקי',
      );
    },
  );
  test(
    'missing or empty saved templates use the default and zero values survive',
    () {
      expect(
        VehicleDescriptionTemplate.setting(null),
        VehicleDescriptionTemplate.defaultText,
      );
      expect(
        VehicleDescriptionTemplate.setting(' '),
        VehicleDescriptionTemplate.defaultText,
      );
      expect(
        VehicleDescriptionTemplate.render('{קילומטרים}/{חוזקות}', {'km': '0'}),
        '0/',
      );
      expect(
        VehicleDescriptionTemplate.render('{יצרן}', {'maker': '{דגם}'}),
        '{דגם}',
      );
    },
  );
}
