/// Optional listing claims supplied by the user, never inferred from government data.
class VehicleListingExtras {
  static String description(Map<String, String> data, {String? description}) {
    final original = (description ?? data['description'] ?? '').trim();
    final highlights = (data['highlights'] ?? '').trim();
    const cleanTitle = 'לרכב זה יש טייטל נקי';
    return [
      if (original.isNotEmpty) original,
      if ({'כן', 'true', '1'}.contains(data['clean_title']) &&
          !original.contains(cleanTitle)) cleanTitle,
      if (highlights.isNotEmpty && !original.contains('חשוב לדעת: $highlights'))
        'חשוב לדעת: $highlights',
    ].join('\n');
  }
}
