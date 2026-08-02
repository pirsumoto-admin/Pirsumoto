class VehiclePublishData {
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

  const VehiclePublishData({
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
  });

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
  phase18(
    'Terms Agreement',
    'קראתי ואישרתי את התקנון',
    1,
  ),
  phase19(
    'Promotional Screen Dismiss',
    'X|x|✕|✖|×|סגור|סגירה|close|Close',
    1,
  ),
  complete('Automation Complete', null, 1);

  final String description;
  final String? targetText;
  final int targetInstance;

  const AutomationPhase(this.description, this.targetText, this.targetInstance);
}
