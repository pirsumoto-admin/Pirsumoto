import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:pirsumoto_remote_control/services/audio_vehicle_form.dart';
import 'package:pirsumoto_remote_control/ui/audio_plate_dialog.dart';
import 'package:pirsumoto_remote_control/ui/whatsapp_chat_screen.dart';

void main() {
  setUpAll(() => GoogleFonts.config.allowRuntimeFetching = false);

  testWidgets('ambiguous plate options require selection and remain editable', (
    tester,
  ) async {
    String? approved;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                approved = await showDialog<String>(
                  context: context,
                  builder: (_) => const AudioPlateDialog(
                    candidates: ['35634678', '5211639'],
                  ),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byType(ChoiceChip), findsNWidgets(2));
    final field = find.byKey(const ValueKey('audio_license_plate'));
    expect(tester.widget<TextFormField>(field).controller!.text, isEmpty);
    await tester.tap(find.text('אישור והמשך'));
    await tester.pump();
    expect(find.text('יש להזין מספר רישוי בן 7 או 8 ספרות'), findsOneWidget);
    await tester.tap(find.text('35634678'));
    await tester.pump();
    expect(tester.widget<TextFormField>(field).controller!.text, '35634678');
    await tester.enterText(field, '0782433');
    await tester.tap(find.text('אישור והמשך'));
    await tester.pumpAndSettle();
    expect(approved, '0782433');
  });

  testWidgets('audio progress labels transcription and government lookup', (
    tester,
  ) async {
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: AudioProcessingIndicator(fetchingGovernment: false),
        ),
      ),
    );
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('מתמלל את ההקלטה ומזהה את פרטי הרכב…'), findsOneWidget);
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(
          body: AudioProcessingIndicator(fetchingGovernment: true),
        ),
      ),
    );
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('מאחזר נתוני רכב מ־gov.il…'), findsOneWidget);
    expect(find.text('מתמלל את ההקלטה ומזהה את פרטי הרכב…'), findsNothing);
  });

  Future<void> openPlate(
    WidgetTester tester,
    String initial,
    void Function(String?) onResult,
  ) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async {
                onResult(
                  await showDialog<String>(
                    context: context,
                    builder: (_) => AudioPlateDialog(plate: initial),
                  ),
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
  }

  testWidgets(
    'audio popup contains only the plate and returns the edited identifier',
    (tester) async {
      String? result;
      await openPlate(tester, '9999999', (plate) => result = plate);
      expect(find.byType(TextFormField), findsOneWidget);
      expect(find.text('אישור מספר רישוי'), findsOneWidget);
      expect(find.text('יצרן'), findsNothing);
      await tester.enterText(
        find.byKey(const ValueKey('audio_license_plate')),
        '078-24-33',
      );
      await tester.tap(find.text('אישור והמשך'));
      await tester.pumpAndSettle();
      expect(result, '0782433');
    },
  );

  testWidgets('invalid plate blocks confirmation and cancel returns nothing', (
    tester,
  ) async {
    var completed = false;
    String? result;
    await openPlate(tester, '123', (plate) {
      completed = true;
      result = plate;
    });
    expect(
      tester
          .widget<TextFormField>(
            find.byKey(const ValueKey('audio_license_plate')),
          )
          .controller!
          .text,
      '123',
    );
    await tester.tap(find.text('אישור והמשך'));
    await tester.pumpAndSettle();
    expect(completed, isFalse);
    expect(find.text('יש להזין מספר רישוי בן 7 או 8 ספרות'), findsOneWidget);
    await tester.tap(find.text('ביטול'));
    await tester.pumpAndSettle();
    expect(completed, isTrue);
    expect(result, isNull);
  });

  testWidgets(
    'partial digits are prefilled without separators and can be completed',
    (tester) async {
      String? approved;
      await openPlate(tester, '17, / 7237', (plate) => approved = plate);
      final field = find.byKey(const ValueKey('audio_license_plate'));
      expect(tester.widget<TextFormField>(field).controller!.text, '177237');
      await tester.enterText(field, '1772379');
      await tester.tap(find.text('אישור והמשך'));
      await tester.pumpAndSettle();
      expect(approved, '1772379');
    },
  );

  const mergedData = {
    'license_plate': '1234567',
    'govIl': 'true',
    'maker': 'מאזדה',
    'model': '3',
    'year': '2020',
    'price': '45000',
    'km': '85000',
    'previous_ownership': 'פרטית',
    'test_year': '2027',
    'test_month': '1',
  };

  Widget form(
    Map<String, String> data,
    void Function(Map<String, String>) save,
  ) => MaterialApp(
    home: Scaffold(
      body: SingleChildScrollView(
        child: MissingFieldsInlineForm(
          key: const ValueKey('audio_form'),
          missingFields: const [],
          currentData: AudioVehicleForm.markForReview(data),
          onSave: (values) async => save(values),
        ),
      ),
    ),
  );

  testWidgets(
    'merged government and recorded fields are filled even for a government-matched car',
    (tester) async {
      await tester.pumpWidget(form(mergedData, (_) {}));
      expect(find.text('מאזדה'), findsOneWidget);
      expect(find.text('45000'), findsOneWidget);
      expect(find.text('85000'), findsOneWidget);
      expect(find.text('2020'), findsOneWidget);
      expect(find.byKey(const ValueKey('missing_field_maker')), findsOneWidget);
      expect(find.byKey(const ValueKey('missing_field_price')), findsOneWidget);
      expect(
        tester
            .widget<ElevatedButton>(
              find.widgetWithText(ElevatedButton, 'שמור פרטים'),
            )
            .onPressed,
        isNotNull,
      );
    },
  );

  testWidgets(
    'later recorded corrections refresh the existing form and keep unrelated unsaved edits',
    (tester) async {
      Map<String, String>? saved;
      await tester.pumpWidget(form(mergedData, (values) => saved = values));
      final km = find.byKey(const ValueKey('missing_field_km'));
      await tester.ensureVisible(km);
      await tester.enterText(km, '90000');
      await tester.pumpWidget(
        form({...mergedData, 'price': '40000'}, (values) => saved = values),
      );
      expect(find.text('40000'), findsOneWidget);
      expect(find.text('45000'), findsNothing);
      expect(find.text('90000'), findsOneWidget);
      final save = find.widgetWithText(ElevatedButton, 'שמור פרטים');
      await tester.ensureVisible(save);
      await tester.tap(save);
      await tester.pumpAndSettle();
      expect(saved!['price'], '40000');
      expect(saved!['km'], '90000');
    },
  );

  testWidgets(
    'recorded zero mileage is kept and invalid extracted amounts are editable',
    (tester) async {
      await tester.pumpWidget(
        form({...mergedData, 'km': '0', 'estimatedKm': '85000'}, (_) {}),
      );
      expect(
        tester
            .widget<TextField>(find.byKey(const ValueKey('missing_field_km')))
            .controller!
            .text,
        '0',
      );
      expect(
        tester
            .widget<ElevatedButton>(
              find.widgetWithText(ElevatedButton, 'שמור פרטים'),
            )
            .onPressed,
        isNotNull,
      );
      await tester.pumpWidget(form({...mergedData, 'price': 'oops'}, (_) {}));
      expect(find.text('מחיר מבוקש: ערך לא תקין'), findsOneWidget);
      expect(
        tester
            .widget<ElevatedButton>(
              find.widgetWithText(ElevatedButton, 'שמור פרטים'),
            )
            .onPressed,
        isNull,
      );
    },
  );

  test(
    'corrections reuse the confirmed car unless a different plate was spoken',
    () {
      expect(AudioVehicleForm.needsPlateConfirmation(null, ''), isTrue);
      expect(AudioVehicleForm.needsPlateConfirmation(null, '1234567'), isFalse);
      expect(
        AudioVehicleForm.needsPlateConfirmation('1234567', '1234567'),
        isFalse,
      );
      expect(
        AudioVehicleForm.needsPlateConfirmation('9999999', '1234567'),
        isTrue,
      );
    },
  );
  test(
    'supplemental government history fills gaps without replacing recorded values',
    () {
      final data = {...mergedData, 'price': '40000', 'km': '0'};
      AudioVehicleForm.enrichGovernment(data, {
        'license_plate': '1234567',
        'maker': 'טויוטה',
        'hand': '2',
        'km': '90000',
        'estimatedKm': '90000',
        'history_records': '[]',
      });
      expect(data['maker'], 'מאזדה');
      expect(data['price'], '40000');
      expect(data['km'], '0');
      expect(data['hand'], '2');
      expect(data['history_records'], '[]');
      expect(
        AudioVehicleForm.markForReview(data)['audio_form_fields'],
        contains('hand'),
      );
      AudioVehicleForm.enrichGovernment(data, {
        'license_plate': '9999999',
        'city': 'חיפה',
      });
      expect(data['city'], isNull);
    },
  );
  testWidgets(
    'the editable form can move to the latest bot bubble without losing other edits',
    (tester) async {
      final formKey = GlobalKey();
      Widget bubbles(Map<String, String> data, int lastBubble) => MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: Column(
              children: [
                for (var i = 0; i < 2; i++)
                  Container(
                    key: ValueKey('bubble_$i'),
                    child: i == lastBubble
                        ? MissingFieldsInlineForm(
                            key: formKey,
                            missingFields: const [],
                            currentData: AudioVehicleForm.markForReview(data),
                            onSave: (_) async {},
                          )
                        : const SizedBox(),
                  ),
              ],
            ),
          ),
        ),
      );
      await tester.pumpWidget(bubbles(mergedData, 0));
      final km = find.byKey(const ValueKey('missing_field_km'));
      await tester.ensureVisible(km);
      await tester.enterText(km, '90000');
      await tester.pumpWidget(bubbles({...mergedData, 'price': '40000'}, 1));
      expect(find.text('90000'), findsOneWidget);
      expect(find.text('40000'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );
}
