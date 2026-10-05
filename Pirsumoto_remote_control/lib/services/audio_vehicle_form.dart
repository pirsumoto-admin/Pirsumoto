import 'package:publication_protocol/publication_protocol.dart';

class AudioVehicleForm {
  static const fields = [
    'maker',
    'trim',
    'model',
    'year',
    'fuel_type',
    'gear_type',
    'month',
    'price',
    'km',
    'hand',
    'previous_ownership',
    'current_ownership',
    'color',
    'test_year',
    'test_month',
    'engine_capacity',
    'phone',
    'city',
    'area',
    'contact_name',
    'vehicle_condition',
    'description',
  ];

  /// In an audio draft the user reviews supplied values as well as missing ones.
  static Map<String, String> markForReview(Map<String, String> data) => {
    ...data,
    'audio_form_fields': fields
        .where((key) => (data[key] ?? '').trim().isNotEmpty)
        .join(','),
  };

  /// Preserve spoken values and expose the supplemental history/test metadata.
  /// Historical mileage stays metadata instead of becoming a current odometer.
  static void enrichGovernment(
    Map<String, String> data,
    Map<String, dynamic> government,
  ) {
    final governmentPlate = government['license_plate']?.toString();
    if (governmentPlate != null && governmentPlate != data['license_plate']) {
      return;
    }
    data['govIl'] = 'true';
    for (final entry in government.entries) {
      if (entry.key == 'km') continue;
      final value = entry.value?.toString().trim() ?? '';
      if (value.isNotEmpty && (data[entry.key] ?? '').isEmpty) {
        data[entry.key] = value;
      }
    }
  }

  static bool needsPlateConfirmation(
    String? spokenPlate,
    String currentPlate,
  ) =>
      !RegExp(r'^\d{7,8}$').hasMatch(currentPlate) ||
      (spokenPlate != null &&
          spokenPlate.isNotEmpty &&
          spokenPlate != currentPlate);

  static String? error(String key, String value) {
    final errors = VehicleSchema.errors({key: value});
    return errors.isEmpty ? null : errors.first;
  }
}
