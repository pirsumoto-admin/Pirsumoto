import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;

/// Default [FirebaseOptions] for use with your Firebase apps.
/// Connects to the same 'car-publisher' Firebase project as Pirsumoto.
class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    if (kIsWeb) {
      return web;
    }
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return android;
      case TargetPlatform.iOS:
        return ios;
      case TargetPlatform.macOS:
        return ios;
      default:
        return android;
    }
  }

  static const FirebaseOptions android = FirebaseOptions(
    apiKey: 'AIzaSyAJndnuTu4nCktGpOWm9JhpUR56PB6k8Bk',
    appId: '1:265879971574:android:92ee7b76d2636b8d1aaed7',
    messagingSenderId: '265879971574',
    projectId: 'car-publisher',
    storageBucket: 'car-publisher.firebasestorage.app',
  );

  static const FirebaseOptions ios = FirebaseOptions(
    apiKey: 'AIzaSyD1Ul7RaTfbrk1Yjvq07VZMPBTlLQPH1Sw',
    appId: '1:265879971574:ios:6ed1e4ff94cbfad81aaed7',
    messagingSenderId: '265879971574',
    projectId: 'car-publisher',
    storageBucket: 'car-publisher.firebasestorage.app',
    iosBundleId: 'com.pirsumoto.remote.pirsumotoRemoteControl',
  );

  static const FirebaseOptions web = FirebaseOptions(
    apiKey: 'AIzaSyAJndnuTu4nCktGpOWm9JhpUR56PB6k8Bk',
    appId: '1:265879971574:web:92ee7b76d2636b8d1aaed7',
    messagingSenderId: '265879971574',
    projectId: 'car-publisher',
    storageBucket: 'car-publisher.firebasestorage.app',
  );
}
