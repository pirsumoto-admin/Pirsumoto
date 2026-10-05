export 'vehicle_description_template.dart';
export 'vehicle_schema.dart';
export 'vehicle_listing_extras.dart';
export 'publication_notification.dart';

/// Immutable correlation carried through both platform screens and callbacks.
class PublicationIdentity {
  final String deviceId;
  final String requestId;
  final String attemptId;
  const PublicationIdentity(this.deviceId, this.requestId, this.attemptId);
  Map<String, String> toJson() => {
    'deviceId': deviceId,
    'requestId': requestId,
    'attemptId': attemptId,
  };
  bool matches(PublicationIdentity? other) =>
      other != null &&
      deviceId == other.deviceId &&
      requestId == other.requestId &&
      attemptId == other.attemptId;
}

class PublicationState {
  static const terminal = {'completed', 'canceled', 'failed'};
  static const occupied = {
    'preparing',
    'publishing',
    'paused',
    'stuck',
    'canceling',
  };
  static bool canTransition(String from, String to) {
    if (terminal.contains(from)) return false;
    if (from == 'canceling') return to == 'canceled';
    if (to == 'completed')
      return {'publishing', 'paused', 'stuck'}.contains(from);
    if (from == 'queued') return {'preparing', 'canceled'}.contains(to);
    if (to == 'publishing')
      return {'preparing', 'paused', 'stuck', 'publishing'}.contains(from);
    return occupied.contains(from) &&
        {'paused', 'stuck', 'canceling', 'canceled', 'failed'}.contains(to);
  }
}

/// Only dedicated page headings/status messages count as confirmation, never
/// editable vehicle descriptions or the mere presence of a Publish button.
class PublicationConfirmation {
  static bool yad2(String statusText) =>
      RegExp(r'המודעה(?: שלך)? פורסמה|פורסמה בהצלחה').hasMatch(statusText);

  static bool facebook(String statusText, String url) {
    final parsed = Uri.tryParse(url);
    final path = parsed?.path ?? '';
    final host = parsed?.host ?? '';
    final listingPage =
        (host == 'facebook.com' || host.endsWith('.facebook.com')) &&
        (path.startsWith('/marketplace/you/selling') ||
            path.startsWith('/marketplace/item/'));
    return listingPage ||
        RegExp(
          r'your listing (?:is now|has been) (?:published|listed|live)|listing published|המודעה(?: שלך)? פורסמה',
          caseSensitive: false,
        ).hasMatch(statusText);
  }
}
