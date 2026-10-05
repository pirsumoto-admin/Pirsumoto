class VehicleDescriptionTemplate {
  static const defaultText =
      'רכב: {יצרן} {דגם} שנת {שנה} בצבע {צבע}\n'
      'יד: {יד} | ק"מ: {קילומטרים}\n'
      'במצב: {מצב הרכב}\n'
      'חוזקות הרכב: {חוזקות}';

  static String setting(Object? value) =>
      value is String && value.trim().isNotEmpty ? value : defaultText;

  static String render(String template, Map<String, String> fields) {
    const keys = {
      'יצרן': 'maker',
      'דגם': 'model',
      'שנה': 'year',
      'צבע': 'color',
      'יד': 'hand',
      'קילומטרים': 'km',
      'מצב הרכב': 'vehicle_condition',
      'חוזקות': 'highlights',
      'מחיר': 'price',
      'מספר רישוי': 'license_plate',
      'עיר': 'city',
      'סוג דלק': 'fuel_type',
      'רמת גימור': 'trim',
    };
    return setting(template).replaceAllMapped(RegExp(r'\{([^{}]+)\}'), (match) {
      final key = keys[match[1]];
      return key == null ? match[0]! : fields[key] ?? '';
    });
  }
}
