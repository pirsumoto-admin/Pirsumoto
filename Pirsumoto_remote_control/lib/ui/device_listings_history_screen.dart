import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:google_fonts/google_fonts.dart';
import 'app_theme.dart';
import 'remote_listing_details_screen.dart';

class DeviceListingsHistoryScreen extends StatefulWidget {
  final String deviceId;
  final String deviceName;
  final String ownerUid;

  const DeviceListingsHistoryScreen({
    super.key,
    required this.deviceId,
    required this.deviceName,
    required this.ownerUid,
  });

  @override
  State<DeviceListingsHistoryScreen> createState() =>
      _DeviceListingsHistoryScreenState();
}

class _DeviceListingsHistoryScreenState
    extends State<DeviceListingsHistoryScreen> {
  final TextEditingController _searchController = TextEditingController();
  bool _onlyFavorites = false;
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    _searchController.addListener(() {
      setState(() {
        _searchQuery = _searchController.text.trim().toLowerCase();
      });
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _toggleFavorite(String licenseNumber, bool currentStatus) async {
    if (licenseNumber.isEmpty || widget.ownerUid.isEmpty) return;
    try {
      await FirebaseFirestore.instance
          .collection('users')
          .doc(widget.ownerUid)
          .collection('listings')
          .doc(licenseNumber)
          .set({'isFavorite': !currentStatus}, SetOptions(merge: true));
    } catch (e) {
      debugPrint('Error toggling favorite: $e');
    }
  }

  Future<void> _confirmDelete(String licenseNumber) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: AppColors.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: const BorderSide(color: AppColors.border),
        ),
        title: Text(
          'מחיקת מודעה',
          textAlign: TextAlign.right,
          style: GoogleFonts.heebo(
            fontWeight: FontWeight.bold,
            color: AppColors.onSurface,
          ),
        ),
        content: Text(
          'האם אתה בטוח שברצונך למחוק מודעה זו מהמערכת?',
          textAlign: TextAlign.right,
          style: GoogleFonts.heebo(color: AppColors.secondary),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: Text(
              'ביטול',
              style: GoogleFonts.heebo(color: AppColors.secondary),
            ),
          ),
          ElevatedButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: ElevatedButton.styleFrom(
              backgroundColor: AppColors.error,
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(10),
              ),
            ),
            child: Text(
              'מחיקה',
              style: GoogleFonts.heebo(fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );

    if (confirm == true) {
      try {
        await FirebaseFirestore.instance
            .collection('users')
            .doc(widget.ownerUid)
            .collection('listings')
            .doc(licenseNumber)
            .delete();
      } catch (e) {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'שגיאה במחיקת מודעה: $e',
                textAlign: TextAlign.right,
                style: GoogleFonts.heebo(),
              ),
              backgroundColor: AppColors.error,
            ),
          );
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final stream = FirebaseFirestore.instance
        .collection('users')
        .doc(widget.ownerUid)
        .collection('listings')
        .orderBy('timestamp', descending: true)
        .snapshots();

    return Scaffold(
      backgroundColor: AppColors.neutral,
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: true,
        title: Column(
          children: [
            Text(
              'היסטוריית מודעות ופרסומים',
              style: GoogleFonts.heebo(
                color: AppColors.onSurface,
                fontSize: 17,
                fontWeight: FontWeight.bold,
              ),
            ),
            Text(
              widget.deviceName,
              style: GoogleFonts.heebo(
                color: AppColors.secondary,
                fontSize: 12,
              ),
            ),
          ],
        ),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1.0),
          child: Container(color: AppColors.border, height: 1.0),
        ),
        leading: IconButton(
          icon: const Icon(
            Icons.arrow_back_ios_new_rounded,
            color: AppColors.primaryAction,
            size: 20,
          ),
          onPressed: () => Navigator.pop(context),
        ),
      ),
      body: Column(
        children: [
          // Filter and Search Header
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 12.0),
            child: Column(
              children: [
                // Search Input
                Container(
                  height: 44,
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: AppColors.border),
                  ),
                  child: TextField(
                    controller: _searchController,
                    textDirection: TextDirection.rtl,
                    style: GoogleFonts.heebo(fontSize: 14, color: AppColors.onSurface),
                    decoration: InputDecoration(
                      hintText: 'חיפוש לפי רישוי, יצרן או דגם...',
                      hintTextDirection: TextDirection.rtl,
                      hintStyle: GoogleFonts.heebo(
                        color: AppColors.secondary.withValues(alpha: 0.7),
                        fontSize: 13,
                      ),
                      prefixIcon: const Icon(
                        Icons.search_rounded,
                        color: AppColors.secondary,
                        size: 20,
                      ),
                      suffixIcon: _searchQuery.isNotEmpty
                          ? IconButton(
                              icon: const Icon(Icons.clear, size: 16, color: AppColors.secondary),
                              onPressed: () => _searchController.clear(),
                            )
                          : null,
                      border: InputBorder.none,
                      contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                    ),
                  ),
                ),
                const SizedBox(height: 10),

                // Filter Pill (Favorites only)
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    InkWell(
                      onTap: () => setState(() => _onlyFavorites = !_onlyFavorites),
                      borderRadius: BorderRadius.circular(20),
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                        decoration: BoxDecoration(
                          color: _onlyFavorites ? AppColors.primarySoft : AppColors.surface,
                          border: Border.all(
                            color: _onlyFavorites ? AppColors.primaryAction : AppColors.border,
                          ),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: Row(
                          children: [
                            Text(
                              'מועדפים בלבד',
                              style: GoogleFonts.heebo(
                                color: _onlyFavorites
                                    ? AppColors.primaryAction
                                    : AppColors.secondary,
                                fontWeight: FontWeight.bold,
                                fontSize: 12.5,
                              ),
                            ),
                            const SizedBox(width: 5),
                            Icon(
                              _onlyFavorites ? Icons.favorite : Icons.favorite_border,
                              color: _onlyFavorites
                                  ? AppColors.primaryAction
                                  : AppColors.secondary,
                              size: 16,
                            ),
                          ],
                        ),
                      ),
                    ),
                    // Counter text
                    Text(
                      'מודעות שנשמרו בחשבון',
                      style: GoogleFonts.heebo(
                        color: AppColors.secondary,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),

          // Main Listings Stream
          Expanded(
            child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: stream,
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(
                    child: CircularProgressIndicator(
                      strokeWidth: 2.5,
                      color: AppColors.primaryAction,
                    ),
                  );
                }

                if (snapshot.hasError) {
                  return Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24.0),
                      child: Text(
                        'שגיאה בטעינת המודעות: ${snapshot.error}',
                        textAlign: TextAlign.center,
                        style: GoogleFonts.heebo(color: AppColors.error),
                      ),
                    ),
                  );
                }

                final allDocs = snapshot.data?.docs ?? [];
                final filtered = allDocs.where((doc) {
                  final data = doc.data();
                  if (_onlyFavorites && data['isFavorite'] != true) {
                    return false;
                  }
                  if (_searchQuery.isNotEmpty) {
                    final license = (data['license'] ?? '').toString().toLowerCase();
                    final maker = (data['maker'] ?? '').toString().toLowerCase();
                    final model = (data['model'] ?? '').toString().toLowerCase();
                    final year = (data['year'] ?? '').toString().toLowerCase();
                    final desc = (data['description'] ?? '').toString().toLowerCase();
                    final fullText = '$license $maker $model $year $desc';
                    if (!fullText.contains(_searchQuery)) {
                      return false;
                    }
                  }
                  return true;
                }).toList();

                return Column(
                  children: [
                    // Item count row
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 4.0),
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: Text(
                          '${filtered.length} מודעות נמצאו',
                          style: GoogleFonts.heebo(
                            color: AppColors.secondary,
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 6),

                    if (filtered.isEmpty)
                      Expanded(
                        child: Center(
                          child: Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              const Icon(
                                Icons.directions_car_outlined,
                                size: 54,
                                color: AppColors.secondary,
                              ),
                              const SizedBox(height: 12),
                              Text(
                                _searchQuery.isNotEmpty || _onlyFavorites
                                    ? 'לא נמצאו מודעות התואמות לסינון'
                                    : 'אין היסטוריית פרסומים שמורה למכשיר זה',
                                style: GoogleFonts.heebo(
                                  color: AppColors.onSurface,
                                  fontSize: 16,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                'כל מודעה שתפורסם באפליקציה תישמר כאן אוטומטית.',
                                style: GoogleFonts.heebo(
                                  color: AppColors.secondary,
                                  fontSize: 13,
                                ),
                              ),
                            ],
                          ),
                        ),
                      )
                    else
                      Expanded(
                        child: ListView.builder(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 8,
                          ),
                          itemCount: filtered.length,
                          itemBuilder: (context, index) {
                            final listing = filtered[index].data();
                            return _buildListingCard(listing);
                          },
                        ),
                      ),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildListingCard(Map<String, dynamic> listing) {
    final license = listing['license'] ?? 'ללא רישוי';
    final price = listing['price'] ?? '';
    final hand = listing['hand'] ?? '';
    final ownership = listing['ownership'] ?? '';
    final km = listing['km'] ?? '';
    final maker = (listing['maker'] ?? '').toString().trim();
    final model = (listing['model'] ?? '').toString().trim();
    final year = (listing['year'] ?? '').toString().trim();
    final gear = (listing['gear'] ?? '').toString().trim();
    final vehicleTitle = [maker, model, year].where((s) => s.isNotEmpty).join(' ');
    final isFavorite = listing['isFavorite'] == true;

    dynamic firstImage;
    if (listing['images'] != null && (listing['images'] as List).isNotEmpty) {
      firstImage = (listing['images'] as List).first;
    }

    String imageUrl = '';
    if (firstImage is String) {
      imageUrl = firstImage;
    } else if (firstImage is Map) {
      imageUrl = (firstImage['url'] ?? firstImage['path'] ?? '').toString();
    }

    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      decoration: BoxDecoration(
        color: AppColors.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: AppColors.border),
        boxShadow: [
          BoxShadow(
            color: AppColors.onSurface.withValues(alpha: 0.035),
            blurRadius: 8,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: InkWell(
        onTap: () {
          Navigator.push(
            context,
            MaterialPageRoute(
              builder: (context) => RemoteListingDetailsScreen(
                listing: listing,
                ownerUid: widget.ownerUid,
              ),
            ),
          );
        },
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              // Left Actions Column
              Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SizedBox(
                    width: 72,
                    height: 34,
                    child: ElevatedButton(
                      onPressed: () {
                        Navigator.push(
                          context,
                          MaterialPageRoute(
                            builder: (context) => RemoteListingDetailsScreen(
                              listing: listing,
                              ownerUid: widget.ownerUid,
                            ),
                          ),
                        );
                      },
                      style: ElevatedButton.styleFrom(
                        backgroundColor: AppColors.primarySoft,
                        foregroundColor: AppColors.primaryAction,
                        padding: EdgeInsets.zero,
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                      child: Text(
                        'פרטים',
                        style: GoogleFonts.heebo(
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    width: 72,
                    height: 34,
                    child: OutlinedButton(
                      onPressed: () => _confirmDelete(license.toString()),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: AppColors.error,
                        side: const BorderSide(color: AppColors.error, width: 1),
                        padding: EdgeInsets.zero,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                      child: Text(
                        'מחיקה',
                        style: GoogleFonts.heebo(
                          fontWeight: FontWeight.bold,
                          fontSize: 13,
                        ),
                      ),
                    ),
                  ),
                ],
              ),

              const SizedBox(width: 10),

              // Center Vehicle Details
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    if (vehicleTitle.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 2.0),
                        child: Text(
                          vehicleTitle,
                          style: GoogleFonts.heebo(
                            color: AppColors.primaryAction,
                            fontSize: 15,
                            fontWeight: FontWeight.bold,
                          ),
                          textAlign: TextAlign.right,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    RichText(
                      textAlign: TextAlign.right,
                      text: TextSpan(
                        style: GoogleFonts.heebo(
                          color: AppColors.onSurface,
                          fontSize: 14.5,
                        ),
                        children: [
                          TextSpan(
                            text: '$license ',
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                          const TextSpan(
                            text: ':מספר רישוי',
                            style: TextStyle(fontWeight: FontWeight.w600),
                          ),
                        ],
                      ),
                    ),
                    if (price.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(
                        'מחיר: ₪ $price',
                        textAlign: TextAlign.right,
                        style: GoogleFonts.heebo(
                          color: AppColors.onSurface,
                          fontSize: 13.5,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                    const SizedBox(height: 2),
                    Text(
                      'יד: $hand | בעלות: $ownership',
                      textAlign: TextAlign.right,
                      style: GoogleFonts.heebo(
                        color: AppColors.secondary,
                        fontSize: 12,
                      ),
                    ),
                    if (km.isNotEmpty || gear.isNotEmpty) ...[
                      const SizedBox(height: 2),
                      Text(
                        'ק"מ: $km${gear.isNotEmpty ? ' | $gear' : ''}',
                        textAlign: TextAlign.right,
                        style: GoogleFonts.heebo(
                          color: AppColors.secondary,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ],
                ),
              ),

              const SizedBox(width: 10),

              // Right Vehicle Image
              Stack(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: imageUrl.isNotEmpty
                        ? Image.network(
                            imageUrl,
                            width: 90,
                            height: 105,
                            fit: BoxFit.cover,
                            errorBuilder: (_, _, _) => Container(
                              width: 90,
                              height: 105,
                              color: AppColors.surfaceSubtle,
                              child: const Icon(
                                Icons.directions_car_rounded,
                                color: AppColors.secondary,
                                size: 36,
                              ),
                            ),
                          )
                        : Container(
                            width: 90,
                            height: 105,
                            color: AppColors.surfaceSubtle,
                            child: const Icon(
                              Icons.directions_car_rounded,
                              color: AppColors.secondary,
                              size: 36,
                            ),
                          ),
                  ),
                  Positioned(
                    top: 4,
                    left: 4,
                    child: GestureDetector(
                      onTap: () => _toggleFavorite(license.toString(), isFavorite),
                      child: Container(
                        padding: const EdgeInsets.all(4),
                        decoration: BoxDecoration(
                          color: AppColors.surface.withValues(alpha: 0.9),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          isFavorite ? Icons.favorite : Icons.favorite_border,
                          size: 16,
                          color: isFavorite ? AppColors.primaryAction : AppColors.secondary,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}
