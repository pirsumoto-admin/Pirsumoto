import 'package:firebase_auth/firebase_auth.dart';
import 'package:publication_protocol/publication_protocol.dart';
import '../remote_control/firebase_chat_receiver.dart';
import 'db_service.dart';
import 'yad2_automation_models.dart';

class PublicationDescriptionService {
  static Future<String> load(
    VehiclePublishData data, {
    Future<Map<String, dynamic>?> Function()? settingsLoader,
  }) async {
    Map<String, dynamic>? settings;
    if (settingsLoader != null) {
      settings = await settingsLoader();
    } else {
      final uid =
          FirebaseChatReceiver.activeOwnerUid ??
          FirebaseAuth.instance.currentUser?.uid;
      if (uid != null) settings = await DBService().getSettingsData(uid);
    }
    return data.descriptionFromTemplate(
      VehicleDescriptionTemplate.setting(settings?['yad2Desc']),
    );
  }
}
