import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'db_service.g.dart';

@riverpod
DBService dbService(Ref ref) {
  return DBService();
}

class DBService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;

  CollectionReference _listingsCol(String userId) =>
      _firestore.collection('users').doc(userId).collection('listings');

  Stream<List<Map<String, dynamic>>> getUserListingsStream(String userId) {
    if (userId.isEmpty) return const Stream.empty();
    return _listingsCol(
      userId,
    ).orderBy('timestamp', descending: true).snapshots().map((snapshot) {
      return snapshot.docs
          .map((doc) => doc.data() as Map<String, dynamic>)
          .toList();
    });
  }

  Future<bool> saveUserListing(
    Map<String, dynamic> listing,
    String userId,
  ) async {
    try {
      if (userId.isEmpty || listing['license'] == null) return false;

      final docRef = _listingsCol(userId).doc(listing['license'].toString());
      final existing = await docRef.get();

      bool isFav = false;
      if (listing.containsKey('isFavorite')) {
        isFav = listing['isFavorite'];
      } else if (existing.exists) {
        final data = existing.data() as Map<String, dynamic>?;
        isFav = data?['isFavorite'] ?? false;
      }

      final listingData = {
        ...listing,
        'timestamp': listing['timestamp'] ?? DateTime.now().toIso8601String(),
        'isFavorite': isFav,
      };

      await docRef.set(listingData, SetOptions(merge: true));
      return true;
    } catch (e) {
      return false;
    }
  }

  Future<bool> toggleFavorite(String licenseNumber, String userId) async {
    try {
      if (licenseNumber.isEmpty || userId.isEmpty) return false;
      final docRef = _listingsCol(userId).doc(licenseNumber);
      final snap = await docRef.get();
      if (!snap.exists) return false;

      final data = snap.data() as Map<String, dynamic>;
      final currentStatus = data['isFavorite'] == true;
      final newStatus = !currentStatus;

      await docRef.set({
        'isFavorite': newStatus,
        'timestamp': data['timestamp'] ?? DateTime.now().toIso8601String(),
      }, SetOptions(merge: true));
      return newStatus;
    } catch (e) {
      return false;
    }
  }

  Future<bool> deleteUserListing(String licenseNumber, String userId) async {
    try {
      await _listingsCol(userId).doc(licenseNumber).delete();
      return true;
    } catch (e) {
      return false;
    }
  }

  Future<List<Map<String, dynamic>>> getListingPlatforms() async {
    try {
      final snapshot =
          await _firestore
              .collection('listingPlatforms')
              .orderBy('priority')
              .where('isActive', isEqualTo: true)
              .get();

      return snapshot.docs.map((doc) => {'id': doc.id, ...doc.data()}).toList();
    } catch (e) {
      return [];
    }
  }

  Future<bool> saveProfileData(
    String userId,
    Map<String, dynamic> profileData,
  ) async {
    try {
      if (userId.isEmpty) return false;
      await _firestore.collection('users').doc(userId).set({
        'profile': profileData,
      }, SetOptions(merge: true));
      return true;
    } catch (e) {
      return false;
    }
  }

  Future<Map<String, dynamic>?> getProfileData(String userId) async {
    try {
      if (userId.isEmpty) return null;
      final userDoc = await _firestore.collection('users').doc(userId).get();
      if (userDoc.exists) {
        final data = userDoc.data();
        return data?['profile'] as Map<String, dynamic>?;
      }
      return null;
    } catch (e) {
      return null;
    }
  }

  Future<bool> saveSettingsData(
    String userId,
    Map<String, dynamic> settingsData,
  ) async {
    try {
      if (userId.isEmpty) return false;
      await _firestore.collection('users').doc(userId).set({
        'settings': settingsData,
      }, SetOptions(merge: true));
      return true;
    } catch (e) {
      return false;
    }
  }

  Future<Map<String, dynamic>?> getSettingsData(String userId) async {
    try {
      if (userId.isEmpty) return null;
      final userDoc = await _firestore.collection('users').doc(userId).get();
      if (userDoc.exists) {
        final data = userDoc.data();
        return data?['settings'] as Map<String, dynamic>?;
      }
      return null;
    } catch (e) {
      return null;
    }
  }
}
