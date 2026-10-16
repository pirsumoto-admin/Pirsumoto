import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:publication_protocol/publication_protocol.dart';
import 'package:pirsumoto_remote_control/ui/whatsapp_chat_screen.dart';

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);

  testWidgets(
    'optional fields are separated, default unchecked and never block saving',
    (tester) async {
      Map<String, String>? saved;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: MissingFieldsInlineForm(
                missingFields: const [],
                currentData: const {
                  'govIl': 'true',
                  'km': '85000',
                  'previous_ownership': 'פרטית',
                  'test_year': '2027',
                  'test_month': '1',
                },
                onSave: (values) async => saved = values,
              ),
            ),
          ),
        ),
      );
      final checkbox = find.byKey(const ValueKey('clean_title_checkbox'));
      expect(tester.widget<CheckboxListTile>(checkbox).value, isFalse);
      final divider = find.byKey(
        const ValueKey('optional_vehicle_data_divider'),
      );
      expect(divider, findsOneWidget);
      expect(find.text('פרטים נוספים (לא חובה)'), findsOneWidget);
      expect(find.text('חוזקות של הרכב שרוצים להדגיש'), findsOneWidget);
      final save = find.widgetWithText(ElevatedButton, 'שמור פרטים');
      expect(tester.widget<ElevatedButton>(save).onPressed, isNotNull);
      await tester.ensureVisible(save);
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(saved!['clean_title'], 'לא');
      expect(saved!['highlights'], '');

      await tester.ensureVisible(checkbox);
      await tester.tap(checkbox);
      await tester.pump();
      final highlights = find.byKey(const ValueKey('missing_field_highlights'));
      await tester.ensureVisible(highlights);
      await tester.enterText(highlights, 'מטופל בזמן\nצמיגים חדשים');
      await tester.ensureVisible(save);
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(saved!['clean_title'], 'כן');
      expect(saved!['highlights'], 'מטופל בזמן\nצמיגים חדשים');
      expect(saved!['km'], '85000');

      await tester.ensureVisible(checkbox);
      await tester.tap(checkbox);
      await tester.pump();
      await tester.enterText(highlights, '');
      await tester.ensureVisible(save);
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(saved!['clean_title'], 'לא');
      expect(saved!['highlights'], '');
    },
  );

  testWidgets('saved clean title and highlights reload into the form', (
    tester,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: MissingFieldsInlineForm(
              missingFields: const [],
              currentData: const {
                'govIl': 'true',
                'km': '85000',
                'previous_ownership': 'פרטית',
                'test_year': '2027',
                'test_month': '1',
                'clean_title': 'כן',
                'highlights': 'מטופל בזמן',
              },
              onSave: (_) async {},
            ),
          ),
        ),
      ),
    );
    expect(
      tester
          .widget<CheckboxListTile>(
            find.byKey(const ValueKey('clean_title_checkbox')),
          )
          .value,
      isTrue,
    );
    expect(find.text('מטופל בזמן'), findsOneWidget);
  });

  test(
    'shared main-app description mapping includes only selected optional claims',
    () {
      expect(
        VehicleListingExtras.description({
          'description': 'רכב שמור',
          'clean_title': 'כן',
          'highlights': 'מטופל בזמן',
        }),
        'רכב שמור\nלרכב זה יש טייטל נקי\nחשוב לדעת: מטופל בזמן',
      );
      expect(
        VehicleListingExtras.description({
          'description': 'רכב שמור',
          'clean_title': 'לא',
          'highlights': '',
        }),
        'רכב שמור',
      );
      expect(VehicleListingExtras.description({}), '');
      const full = 'לרכב זה יש טייטל נקי\nחשוב לדעת: מטופל בזמן';
      expect(
        VehicleListingExtras.description({
          'description': full,
          'clean_title': 'כן',
          'highlights': 'מטופל בזמן',
        }),
        full,
      );
      expect(vehicleEnums['clean_title'], ['כן', 'לא']);
      expect(requiredVehicleFields, isNot(contains('clean_title')));
      expect(requiredVehicleFields, isNot(contains('highlights')));
      expect(VehicleSchema.errors({'clean_title': 'אולי'}), isNotEmpty);
    },
  );
  testWidgets(
    'completed government vehicle can edit populated parameters before republishing',
    (tester) async {
      Map<String, String>? saved;
      const data = {
        'govIl': 'true',
        'license_plate': '1234567',
        'maker': 'Toyota',
        'model': 'Corolla',
        'year': '2020',
        'km': '85000',
        'price': '70000',
        'hand': '2',
        'color': 'לבן',
        'fuel_type': 'בנזין',
        'gear_type': 'אוטומטי',
        'current_ownership': 'פרטית',
        'previous_ownership': 'פרטית',
        'month': '5',
        'vehicle_condition': 'טוב',
        'city': 'חיפה',
        'test_year': '2027',
        'test_month': '1',
      };
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: MissingFieldsInlineForm(
                editAll: true,
                missingFields: const [],
                currentData: data,
                onSave: (values) async => saved = values,
              ),
            ),
          ),
        ),
      );
      final price = find.byKey(const ValueKey('missing_field_price'));
      final km = find.byKey(const ValueKey('missing_field_km'));
      expect(price, findsOneWidget);
      expect(
        find.byKey(const ValueKey('missing_field_license_plate')),
        findsOneWidget,
      );
      expect(tester.widget<TextField>(price).controller!.text, '70000');
      await tester.ensureVisible(price);
      await tester.enterText(price, '65000');
      await tester.ensureVisible(km);
      await tester.enterText(km, '110000');
      final save = find.widgetWithText(ElevatedButton, 'שמור פרטים');
      expect(tester.widget<ElevatedButton>(save).onPressed, isNotNull);
      await tester.ensureVisible(save);
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(saved!['price'], '65000');
      expect(saved!['km'], '110000');
      expect(saved!['license_plate'], '1234567');
      expect(saved!['govIl'], 'true');
      expect(saved!['test_until'], '01/2027');
    },
  );
  testWidgets(
    'form keeps submitted values visible while publishing and unlocks afterward',
    (tester) async {
      Widget form(bool enabled) => MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: MissingFieldsInlineForm(
              enabled: enabled,
              editAll: true,
              missingFields: const [],
              currentData: const {
                'govIl': 'true',
                'price': '65000',
                'km': '110000',
                'previous_ownership': 'פרטית',
                'test_year': '2027',
                'test_month': '1',
              },
              onSave: (_) async {},
            ),
          ),
        ),
      );
      await tester.pumpWidget(form(true));
      final price = find.byKey(const ValueKey('missing_field_price'));
      final save = find.widgetWithText(ElevatedButton, 'שמור פרטים');
      expect(tester.widget<ElevatedButton>(save).onPressed, isNotNull);
      await tester.pumpWidget(form(false));
      expect(price, findsOneWidget);
      expect(tester.widget<TextField>(price).controller!.text, '65000');
      expect(tester.widget<ElevatedButton>(save).onPressed, isNull);
      await tester.pumpWidget(form(true));
      expect(tester.widget<TextField>(price).controller!.text, '65000');
      expect(tester.widget<ElevatedButton>(save).onPressed, isNotNull);
    },
  );
  testWidgets(
    'if data returned from gov.il has a value not in the list like סוחר do not fill it in the input box',
    (tester) async {
      final data = {
        'govIl': 'true',
        'license_plate': '1234567',
        'maker': 'Toyota',
        'model': 'Corolla',
        'year': '2020',
        'km': '85000',
        'price': '70000',
        'hand': '2',
        'color': 'לבן',
        'fuel_type': 'בנזין',
        'gear_type': 'הילוכים אוטומטיים',
        'current_ownership': 'סוחר',
        'previous_ownership': 'פרטית',
        'month': '5',
        'vehicle_condition': 'טוב',
        'city': 'חיפה',
        'test_year': '2027',
        'test_month': '1',
      };
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: MissingFieldsInlineForm(
                missingFields: const ['current_ownership'],
                currentData: data,
                onSave: (_) async {},
              ),
            ),
          ),
        ),
      );
      final dropdowns = tester.widgetList<DropdownButton<String>>(
        find.byType(DropdownButton<String>),
      );
      expect(dropdowns, isNotEmpty);
      for (final dropdown in dropdowns) {
        expect(dropdown.value != 'סוחר', isTrue);
        final itemValues = dropdown.items?.map((i) => i.value).toList() ?? [];
        expect(itemValues.contains('סוחר'), isFalse);
      }
      final save = find.widgetWithText(ElevatedButton, 'שמור פרטים');
      expect(tester.widget<ElevatedButton>(save).onPressed, isNull);
    },
  );

  testWidgets(
    '3-state publish target defaults to both and allows selecting Yad2 or Facebook only',
    (tester) async {
      Map<String, String>? saved;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: MissingFieldsInlineForm(
                missingFields: const [],
                currentData: const {
                  'govIl': 'true',
                  'km': '85000',
                  'previous_ownership': 'פרטית',
                  'test_year': '2027',
                  'test_month': '1',
                },
                onSave: (values) async => saved = values,
              ),
            ),
          ),
        ),
      );

      final bothChip = find.byKey(const ValueKey('publish_target_both'));
      final yad2Chip = find.byKey(const ValueKey('publish_target_yad2'));
      final fbChip = find.byKey(const ValueKey('publish_target_facebook'));

      expect(bothChip, findsOneWidget);
      expect(yad2Chip, findsOneWidget);
      expect(fbChip, findsOneWidget);

      // Default is both
      expect(tester.widget<ChoiceChip>(bothChip).selected, isTrue);
      expect(tester.widget<ChoiceChip>(yad2Chip).selected, isFalse);
      expect(tester.widget<ChoiceChip>(fbChip).selected, isFalse);

      final save = find.widgetWithText(ElevatedButton, 'שמור פרטים');
      await tester.ensureVisible(save);
      await tester.tap(save);
      await tester.pumpAndSettle();

      expect(saved!['publish_target'], 'both');
      expect(saved!['includeYad2'], 'true');
      expect(saved!['includeFacebook'], 'true');

      // Select Yad2 only
      await tester.ensureVisible(yad2Chip);
      await tester.tap(yad2Chip);
      await tester.pumpAndSettle();

      expect(tester.widget<ChoiceChip>(bothChip).selected, isFalse);
      expect(tester.widget<ChoiceChip>(yad2Chip).selected, isTrue);
      expect(tester.widget<ChoiceChip>(fbChip).selected, isFalse);

      await tester.ensureVisible(save);
      await tester.tap(save);
      await tester.pumpAndSettle();

      expect(saved!['publish_target'], 'yad2');
      expect(saved!['includeYad2'], 'true');
      expect(saved!['includeFacebook'], 'false');

      // Select Facebook only
      await tester.ensureVisible(fbChip);
      await tester.tap(fbChip);
      await tester.pumpAndSettle();

      expect(tester.widget<ChoiceChip>(bothChip).selected, isFalse);
      expect(tester.widget<ChoiceChip>(yad2Chip).selected, isFalse);
      expect(tester.widget<ChoiceChip>(fbChip).selected, isTrue);

      await tester.ensureVisible(save);
      await tester.tap(save);
      await tester.pumpAndSettle();

      expect(saved!['publish_target'], 'facebook');
      expect(saved!['includeYad2'], 'false');
      expect(saved!['includeFacebook'], 'true');
    },
  );
}

