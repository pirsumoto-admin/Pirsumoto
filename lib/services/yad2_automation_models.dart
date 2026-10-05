import 'package:publication_protocol/publication_protocol.dart';

class VehiclePublishData {
  final PublicationIdentity? publicationIdentity;
  final String licenseNumber;
  final String color;
  final String shade;
  final String hand;
  final String currentOwnership;
  final String previousOwnership;
  final String kilometers;
  final String month;
  final String price;
  final String city;
  final bool handicapped;
  final bool noTest;
  final List<String>? images;
  final String maker;
  final String model;
  final String year;
  final String fuelType;
  final String gear;
  final String vehicleCondition;
  final List<String> warranties;
  final Map<String, String> warrantyDurations;
  final List<String> treatments;
  final List<String> services;
  final String description;
  final String highlights;
  final bool cleanTitle;
  final int? expectedImageCount;
  final String? testYear;
  final String? testMonth;
  final bool govIl;
  final bool includeYad2;

  const VehiclePublishData({
    this.publicationIdentity,
    required this.licenseNumber,
    required this.color,
    required this.shade,
    required this.hand,
    required this.currentOwnership,
    required this.previousOwnership,
    required this.kilometers,
    required this.month,
    required this.price,
    required this.handicapped,
    required this.noTest,
    this.city = 'חיפה',
    this.images,
    this.maker = '',
    this.model = '',
    this.year = '',
    this.fuelType = '',
    this.gear = 'הילוכים אוטומטיים',
    this.vehicleCondition = 'טוב',
    this.warranties = const [],
    this.warrantyDurations = const {},
    this.treatments = const [],
    this.services = const [],
    this.description = '',
    this.highlights = '',
    this.cleanTitle = false,
    this.expectedImageCount,
    this.testYear,
    this.testMonth,
    this.govIl = true,
    this.includeYad2 = true,
  });

  VehiclePublishData copyWith({
    String? licenseNumber,
    String? color,
    String? shade,
    String? hand,
    String? currentOwnership,
    String? previousOwnership,
    String? kilometers,
    String? month,
    String? price,
    String? city,
    bool? handicapped,
    bool? noTest,
    List<String>? images,
    String? maker,
    String? model,
    String? year,
    String? fuelType,
    String? gear,
    String? vehicleCondition,
    List<String>? warranties,
    Map<String, String>? warrantyDurations,
    List<String>? treatments,
    List<String>? services,
    String? description,
    String? highlights,
    bool? cleanTitle,
    int? expectedImageCount,
    String? testYear,
    String? testMonth,
    bool? govIl,
    bool? includeYad2,
  }) {
    return VehiclePublishData(
      publicationIdentity: publicationIdentity,
      licenseNumber: licenseNumber ?? this.licenseNumber,
      color: color ?? this.color,
      shade: shade ?? this.shade,
      hand: hand ?? this.hand,
      currentOwnership: currentOwnership ?? this.currentOwnership,
      previousOwnership: previousOwnership ?? this.previousOwnership,
      kilometers: kilometers ?? this.kilometers,
      month: month ?? this.month,
      price: price ?? this.price,
      city: city ?? this.city,
      handicapped: handicapped ?? this.handicapped,
      noTest: noTest ?? this.noTest,
      images: images ?? this.images,
      maker: maker ?? this.maker,
      model: model ?? this.model,
      year: year ?? this.year,
      fuelType: fuelType ?? this.fuelType,
      gear: gear ?? this.gear,
      vehicleCondition: vehicleCondition ?? this.vehicleCondition,
      warranties: warranties ?? this.warranties,
      warrantyDurations: warrantyDurations ?? this.warrantyDurations,
      treatments: treatments ?? this.treatments,
      services: services ?? this.services,
      description: description ?? this.description,
      highlights: highlights ?? this.highlights,
      cleanTitle: cleanTitle ?? this.cleanTitle,
      expectedImageCount: expectedImageCount ?? this.expectedImageCount,
      testYear: testYear ?? this.testYear,
      testMonth: testMonth ?? this.testMonth,
      govIl: govIl ?? this.govIl,
      includeYad2: includeYad2 ?? this.includeYad2,
    );
  }

  String descriptionFromTemplate(String template) {
    final fields = <String, String>{
      'maker': maker,
      'model': model,
      'year': year,
      'color': color,
      'hand': hand,
      'km': kilometers,
      'vehicle_condition': vehicleCondition,
      'highlights': highlights,
      'price': price,
      'license_plate': licenseNumber,
      'city': city,
      'fuel_type': fuelType,
    };
    final rendered = VehicleDescriptionTemplate.render(template, fields);
    final original =
        description.isEmpty
            ? ''
            : VehicleDescriptionTemplate.render(description, fields);
    final freeText =
        highlights.isEmpty
            ? original
            : original.replaceAll('חשוב לדעת: $highlights', '');
    // Keep optional claims and free text without duplicating template highlights.
    final additional = freeText
        .split('\n')
        .where(
          (line) =>
              line.trim().isNotEmpty &&
              !rendered.contains(line.trim()) &&
              line.trim() != 'לרכב זה יש טייטל נקי' &&
              (highlights.isEmpty || line.trim() != 'חשוב לדעת: $highlights'),
        )
        .join('\n');
    return [
      rendered,
      if (additional.isNotEmpty) additional,
      if (cleanTitle || description.contains('לרכב זה יש טייטל נקי'))
        'לרכב זה יש טייטל נקי',
    ].join('\n');
  }

  /// Maps a numeric or plain hand value to Hebrew text for Yad2.
  static String handToHebrew(String hand) {
    if (hand.startsWith('יד')) return hand;
    switch (hand.trim()) {
      case '1':
        return 'יד ראשונה';
      case '2':
        return 'יד שניה';
      case '3':
        return 'יד שלישית';
      case '4':
        return 'יד רביעית';
      default:
        return 'יד $hand';
    }
  }

  /// Maps a numeric month value to Hebrew month name for Yad2.
  static String monthToHebrew(String month) {
    switch (month.trim()) {
      case '1':
      case '01':
        return 'ינואר';
      case '2':
      case '02':
        return 'פברואר';
      case '3':
      case '03':
        return 'מרץ';
      case '4':
      case '04':
        return 'אפריל';
      case '5':
      case '05':
        return 'מאי';
      case '6':
      case '06':
        return 'יוני';
      case '7':
      case '07':
        return 'יולי';
      case '8':
      case '08':
        return 'אוגוסט';
      case '9':
      case '09':
        return 'ספטמבר';
      case '10':
        return 'אוקטובר';
      case '11':
        return 'נובמבר';
      case '12':
        return 'דצמבר';
      default:
        return month.trim();
    }
  }
}

enum AutomationPhase {
  phase1('Initial Screen', 'פרטיים ומסחריים', 1),
  phase2('Form Entry or Reset', '00-000-00', 1),
  phase3('Submission', 'לשלב', 1),
  phase4('Color Selection - First', 'אדום', 1),
  phase5('Color Selection - Second', 'אדום', 2),
  phase5a('Month Dropdown Open', 'חודש עלייה לכביש', 1),
  phase5b('Month Selection', null, 1),
  phase5c('No Test Check', 'ללא טסט', 1),
  phase5c1('Test Year Dropdown Open', 'שנה', 1),
  phase5c2('Test Year Selection', null, 1),
  phase5c3('Test Month Dropdown Open', 'טסט עד', 1),
  phase5c4('Test Month Selection', null, 1),
  phase5d('Warranties Selection', null, 1),
  phase5e('Treatments Selection', null, 1),
  phase5f('Services Selection', null, 1),
  phase6('Hand Selection', 'בחירת יד', 1),
  phase7('Second Hand Selection', 'יד שניה', 1),
  phase8('Current Ownership Label', 'בעלות נוכחית', 1),
  phase9('Current Ownership Value', null, 1),
  phase10('Previous Ownership Label', 'בעלות מקורית', 1),
  phase11('Previous Ownership Value', null, 1),
  phase12('Kilometers Field', 'קילומטראז', 1),
  phase13('Scroll After Kilometers', null, 1),
  phase14('Additional Info Text', 'מה חשוב לך שידעו', 1),
  phase15('Price Input', 'מחיר', 1),
  phase16('City Selection', 'חיפה', 1),
  phase17(
    'Photo Upload',
    'תמונות|העלאת תמונות|הוספת תמונות|תמונות הרכב|העלו תמונות|המשך',
    1,
  ),
  phase18('Terms Agreement', 'קראתי ואישרתי את התקנון', 1),
  phase19('Promotional Screen Dismiss', 'X|x|✕|✖|×|סגור|סגירה|close|Close', 1),
  complete('Automation Complete', null, 1);

  final String description;
  final String? targetText;
  final int targetInstance;

  const AutomationPhase(this.description, this.targetText, this.targetInstance);

  String get resumeLabel =>
      const <AutomationPhase, String>{
        AutomationPhase.phase1: 'פתיחת מסך הפרסום',
        AutomationPhase.phase2: 'מספר רישוי וחיפוש הרכב',
        AutomationPhase.phase3: 'המשך מפרטי הרכב',
        AutomationPhase.phase4: 'פתיחת בחירת צבע',
        AutomationPhase.phase5: 'בחירת צבע',
        AutomationPhase.phase5a: 'פתיחת חודש עלייה לכביש',
        AutomationPhase.phase5b: 'בחירת חודש עלייה לכביש',
        AutomationPhase.phase5c: 'ללא טסט',
        AutomationPhase.phase5c1: 'פתיחת שנת טסט',
        AutomationPhase.phase5c2: 'בחירת שנת טסט',
        AutomationPhase.phase5c3: 'פתיחת חודש טסט',
        AutomationPhase.phase5c4: 'בחירת חודש טסט',
        AutomationPhase.phase5d: 'אחריות',
        AutomationPhase.phase5e: 'טיפולים',
        AutomationPhase.phase5f: 'שירותים',
        AutomationPhase.phase6: 'פתיחת בחירת יד',
        AutomationPhase.phase7: 'בחירת מספר היד',
        AutomationPhase.phase8: 'פתיחת בעלות נוכחית',
        AutomationPhase.phase9: 'בחירת בעלות נוכחית',
        AutomationPhase.phase10: 'פתיחת בעלות קודמת',
        AutomationPhase.phase11: 'בחירת בעלות קודמת',
        AutomationPhase.phase12: 'קילומטראז׳',
        AutomationPhase.phase13: 'התאמה לנכים',
        AutomationPhase.phase14: 'מלל ופרטים נוספים',
        AutomationPhase.phase15: 'בחירת עיר',
        AutomationPhase.phase16: 'מחיר והמשך',
        AutomationPhase.phase17: 'תמונות והמשך',
        AutomationPhase.phase18: 'אישור התקנון והמשך',
        AutomationPhase.phase19: 'סגירת מסך קידום',
        AutomationPhase.complete: 'בדיקת אישור הפרסום',
      }[this]!;
}
