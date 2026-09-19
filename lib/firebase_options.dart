import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;

/// Default [FirebaseOptions] for use with your Firebase apps.
/// Connects to the 'car-publisher' Firebase project.
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
        return macos;
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
    apiKey: 'AIzaSyAJndnuTu4nCktGpOWm9JhpUR56PB6k8Bk',
    appId: '1:265879971574:ios:184903005661370b1aaed7',
    messagingSenderId: '265879971574',
    projectId: 'car-publisher',
    storageBucket: 'car-publisher.firebasestorage.app',
    iosBundleId: 'com.pirsumoto.app',
  );

  static const FirebaseOptions macos = FirebaseOptions(
    apiKey: 'AIzaSyAJndnuTu4nCktGpOWm9JhpUR56PB6k8Bk',
    appId: '1:265879971574:ios:184903005661370b1aaed7',
    messagingSenderId: '265879971574',
    projectId: 'car-publisher',
    storageBucket: 'car-publisher.firebasestorage.app',
    iosBundleId: 'com.pirsumoto.app',
  );

  static const FirebaseOptions web = FirebaseOptions(
    apiKey: 'AIzaSyAJndnuTu4nCktGpOWm9JhpUR56PB6k8Bk',
    appId: '1:265879971574:web:92ee7b76d2636b8d1aaed7',
    messagingSenderId: '265879971574',
    projectId: 'car-publisher',
    storageBucket: 'car-publisher.firebasestorage.app',
  );
}
