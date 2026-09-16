import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_storage/firebase_storage.dart';
import 'package:flutter/foundation.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';
import 'yad2_automation_models.dart' show VehiclePublishData;

part 'db_service.g.dart';

@riverpod
DBService dbService(Ref ref) {
  return DBService();
}

class DBService {
  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final FirebaseStorage _storage = FirebaseStorage.instance;

  CollectionReference _listingsCol(String userId) =>
      _firestore.collection('users').doc(userId).collection('listings');

  /// Uploads up to 10 car images to Firebase Storage under:
  /// car_images/{userEmail}/{licenseNumber}/image_{1..10}.jpg
  /// Returns a list of Firebase Storage download URLs (or existing URLs).
  Future<List<String>> uploadListingImages({
    required String licenseNumber,
    required List<dynamic> images,
    String? userEmail,
  }) async {
    final cleanLicense = licenseNumber.trim();
    if (cleanLicense.isEmpty || images.isEmpty) return [];

    final email = (userEmail != null && userEmail.trim().isNotEmpty)
        ? userEmail.trim().toLowerCase()
        : (FirebaseAuth.instance.currentUser?.email?.trim().toLowerCase() ??
            FirebaseAuth.instance.currentUser?.uid ??
            'unknown_user');

    final List<String> uploadedUrls = [];
    final limitedImages = images.take(10).toList();

    for (int i = 0; i < limitedImages.length; i++) {
      final img = limitedImages[i];
      String path = '';
      if (img is String) {
        path = img.trim();
      } else if (img is Map) {
        path = (img['url'] ?? img['path'] ?? '').toString().trim();
      }

      if (path.isEmpty) continue;

      // If already a remote web / cloud storage URL, keep it
      if (path.startsWith('http://') || path.startsWith('https://')) {
        uploadedUrls.add(path);
        continue;
      }

      // If it's a local file, upload to Firebase Storage
      try {
        final cleanPath = path.startsWith('file://')
            ? path.replaceFirst('file://', '')
            : path;
        final file = File(cleanPath);

        if (await file.exists()) {
          final storageRef = _storage
              .ref()
              .child('car_images')
              .child(email)
              .child(cleanLicense)
              .child('image_${i + 1}.jpg');

          final uploadTask = await storageRef.putFile(
            file,
            SettableMetadata(
              contentType: 'image/jpeg',
              customMetadata: {
                'license': cleanLicense,
                'uploadedBy': email,
                'index': '${i + 1}',
              },
            ),
          );

          final downloadUrl = await uploadTask.ref.getDownloadURL();
          uploadedUrls.add(downloadUrl);
        } else {
          // File does not exist locally; keep original path string as fallback
          uploadedUrls.add(path);
        }
      } catch (e) {
        debugPrint('[DBService] Error uploading image $i to Firebase Storage: $e');
        // Fallback to local path on upload failure so publication data is not lost
        uploadedUrls.add(path);
      }
    }

    return uploadedUrls;
  }

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

  Future<bool> saveListingFromPublishData(
    VehiclePublishData data, {
    String? userId,
    String? platform,
    bool isSuccess = true,
  }) async {
    try {
      final uid = (userId != null && userId.isNotEmpty)
          ? userId
          : FirebaseAuth.instance.currentUser?.uid;
      if (uid == null || uid.isEmpty) return false;
      if (data.licenseNumber.isEmpty) return false;

      // Upload local images to Firebase Storage if needed
      List<String> finalImageUrls = [];
      if (data.images != null && data.images!.isNotEmpty) {
        finalImageUrls = await uploadListingImages(
          licenseNumber: data.licenseNumber,
          images: data.images!,
        );
      }

      final listingMap = {
        'license': data.licenseNumber,
        'color': data.color,
        'shade': data.shade,
        'maker': data.maker,
        'model': data.model,
        'year': data.year,
        'month': data.month,
        'hand': data.hand,
        'ownership': data.currentOwnership,
        'prevOwnership': data.previousOwnership,
        'km': data.kilometers,
        'price': data.price,
        'city': data.city,
        'handicapped': data.handicapped ? 'כן' : 'לא',
        'noTest': data.noTest,
        'vehicleCondition': data.vehicleCondition,
        'gear': data.gear,
        'fuelType': data.fuelType,
        'description': data.description,
        'images': finalImageUrls.map((p) => {'url': p}).toList(),
        'warranties': data.warranties,
        'warrantyDurations': data.warrantyDurations,
        'treatments': data.treatments,
        'services': data.services,
        'lastPublishedAt': DateTime.now().toIso8601String(),
        if (platform != null) 'lastPlatform': platform,
      };

      return await saveUserListing(listingMap, uid);
    } catch (e) {
      debugPrint('[DBService] Error saving listing from publish data: $e');
      return false;
    }
  }

  Future<bool> saveUserListing(
    Map<String, dynamic> listing,
    String userId,
  ) async {
    try {
      final uid = userId.isNotEmpty
          ? userId
          : (FirebaseAuth.instance.currentUser?.uid ?? '');
      if (uid.isEmpty || listing['license'] == null) return false;

      final licenseKey = listing['license'].toString().trim();
      if (licenseKey.isEmpty) return false;

      // Upload any local images to Firebase Storage if not already remote URLs
      final rawImages = listing['images'];
      List<Map<String, dynamic>> processedImages = [];
      if (rawImages is List && rawImages.isNotEmpty) {
        final uploadedUrls = await uploadListingImages(
          licenseNumber: licenseKey,
          images: rawImages,
        );
        processedImages = uploadedUrls.map((u) => {'url': u}).toList();
      }

      final docRef = _listingsCol(uid).doc(licenseKey);
      final existing = await docRef.get();

      bool isFav = false;
      if (listing.containsKey('isFavorite')) {
        isFav = listing['isFavorite'] == true;
      } else if (existing.exists) {
        final data = existing.data() as Map<String, dynamic>?;
        isFav = data?['isFavorite'] == true;
      }

      final listingData = {
        ...listing,
        if (processedImages.isNotEmpty) 'images': processedImages,
        'timestamp': listing['timestamp'] ?? DateTime.now().toIso8601String(),
        'isFavorite': isFav,
      };

      await docRef.set(listingData, SetOptions(merge: true));
      return true;
    } catch (e) {
      debugPrint('[DBService] Error saving user listing: $e');
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
