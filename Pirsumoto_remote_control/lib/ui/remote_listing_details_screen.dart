import 'package:flutter/material.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:intl/intl.dart';
import 'app_theme.dart';

class RemoteListingDetailsScreen extends StatefulWidget {
  final Map<String, dynamic> listing;
  final String ownerUid;

  const RemoteListingDetailsScreen({
    super.key,
    required this.listing,
    required this.ownerUid,
  });

  @override
  State<RemoteListingDetailsScreen> createState() =>
      _RemoteListingDetailsScreenState();
}

class _RemoteListingDetailsScreenState
    extends State<RemoteListingDetailsScreen> {
  int _currentImageIndex = 0;
  late PageController _pageController;
  late bool _isFavorite;
  bool _isDeleting = false;

  @override
  void initState() {
    super.initState();
    _pageController = PageController();
    _isFavorite = widget.listing['isFavorite'] == true;
  }

  @override
  void dispose() {
    _pageController.dispose();
    super.dispose();
  }

  List<String> get _images {
    final raw = widget.listing['images'];
    if (raw == null || raw is! List || raw.isEmpty) return [];
    return raw
        .map((img) {
          if (img is String) return img;
          if (img is Map) return (img['url'] ?? img['path'] ?? '').toString();
          return '';
        })
        .where((s) => s.isNotEmpty)
        .toList();
  }

  Future<void> _toggleFavorite() async {
    final license = widget.listing['license']?.toString() ?? '';
    if (license.isEmpty || widget.ownerUid.isEmpty) return;

    final newStatus = !_isFavorite;
    setState(() => _isFavorite = newStatus);

    try {
      await FirebaseFirestore.instance
          .collection('users')
          .doc(widget.ownerUid)
          .collection('listings')
          .doc(license)
          .set({'isFavorite': newStatus}, SetOptions(merge: true));
    } catch (e) {
      if (mounted) {
        setState(() => _isFavorite = !newStatus);
      }
    }
  }

  Future<void> _deleteListing() async {
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

    if (confirm != true) return;

    setState(() => _isDeleting = true);
    try {
      final license = widget.listing['license']?.toString() ?? '';
      if (license.isNotEmpty && widget.ownerUid.isNotEmpty) {
        await FirebaseFirestore.instance
            .collection('users')
            .doc(widget.ownerUid)
            .collection('listings')
            .doc(license)
            .delete();
      }
      if (mounted) {
        Navigator.pop(context, true);
      }
    } catch (e) {
      if (mounted) {
        setState(() => _isDeleting = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              'שגיאה במחיקת המודעה: $e',
              textAlign: TextAlign.right,
              style: GoogleFonts.heebo(),
            ),
            backgroundColor: AppColors.error,
          ),
        );
      }
    }
  }

  String _formatTimestamp(dynamic ts) {
    if (ts == null) return '';
    if (ts is Timestamp) {
      return DateFormat('dd/MM/yyyy HH:mm').format(ts.toDate());
    }
    if (ts is String) {
      final dt = DateTime.tryParse(ts);
      if (dt != null) {
        return DateFormat('dd/MM/yyyy HH:mm').format(dt);
      }
      return ts;
    }
    return '';
  }

  @override
  Widget build(BuildContext context) {
    final listing = widget.listing;
    final license = listing['license'] ?? '';
    final maker = (listing['maker'] ?? '').toString().trim();
    final model = (listing['model'] ?? '').toString().trim();
    final year = (listing['year'] ?? '').toString().trim();
    final month = (listing['month'] ?? '').toString().trim();
    final testUntil = (listing['test'] ?? listing['testUntil'] ?? '').toString().trim();
    final noTest = listing['noTest'] == true;
    final hand = (listing['hand'] ?? '').toString().trim();
    final ownership = (listing['ownership'] ?? '').toString().trim();
    final prevOwnership = (listing['prevOwnership'] ?? '').toString().trim();
    final km = (listing['km'] ?? '').toString().trim();
    final price = (listing['price'] ?? '').toString().trim();
    final gear = (listing['gear'] ?? '').toString().trim();
    final fuelType = (listing['fuelType'] ?? '').toString().trim();
    final vehicleCondition = (listing['vehicleCondition'] ?? '').toString().trim();
    final color = (listing['color'] ?? '').toString().trim();
    final city = (listing['city'] ?? '').toString().trim();
    final handicapped = (listing['handicapped'] ?? '').toString().trim();
    final description = (listing['description'] ?? '').toString().trim();
    final lastPlatform = (listing['lastPlatform'] ?? '').toString().trim();
    final publishedDateStr = _formatTimestamp(listing['timestamp'] ?? listing['lastPublishedAt']);
    final images = _images;

    final vehicleTitle = [maker, model, year].where((s) => s.isNotEmpty).join(' ');

    return Scaffold(
      backgroundColor: AppColors.neutral,
      appBar: AppBar(
        backgroundColor: AppColors.surface,
        elevation: 0,
        scrolledUnderElevation: 0,
        centerTitle: true,
        title: Text(
          'פרטי המודעה',
          style: GoogleFonts.heebo(
            color: AppColors.onSurface,
            fontSize: 18,
            fontWeight: FontWeight.bold,
          ),
        ),
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1.0),
          child: Container(color: AppColors.border, height: 1.0),
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios_new_rounded, color: AppColors.primaryAction, size: 20),
          onPressed: () => Navigator.pop(context),
        ),
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: GestureDetector(
              onTap: _toggleFavorite,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: BoxDecoration(
                  border: Border.all(
                    color: _isFavorite ? AppColors.primaryAction : AppColors.border,
                  ),
                  borderRadius: BorderRadius.circular(16),
                  color: _isFavorite ? AppColors.primarySoft : AppColors.surface,
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      'מועדף',
                      style: GoogleFonts.heebo(
                        color: _isFavorite ? AppColors.primaryAction : AppColors.secondary,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Icon(
                      _isFavorite ? Icons.favorite : Icons.favorite_border,
                      color: _isFavorite ? AppColors.primaryAction : AppColors.secondary,
                      size: 16,
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
      body: _isDeleting
          ? const Center(
              child: CircularProgressIndicator(
                strokeWidth: 2.5,
                color: AppColors.primaryAction,
              ),
            )
          : Column(
              children: [
                Expanded(
                  child: SingleChildScrollView(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // Image Gallery
                        if (images.isNotEmpty) ...[
                          Stack(
                            children: [
                              SizedBox(
                                height: 260,
                                child: PageView.builder(
                                  controller: _pageController,
                                  itemCount: images.length,
                                  onPageChanged: (i) =>
                                      setState(() => _currentImageIndex = i),
                                  itemBuilder: (context, i) {
                                    return Image.network(
                                      images[i],
                                      width: double.infinity,
                                      height: 260,
                                      fit: BoxFit.cover,
                                      errorBuilder: (_, _, _) => Container(
                                        color: AppColors.surfaceSubtle,
                                        child: const Icon(
                                          Icons.directions_car_rounded,
                                          color: AppColors.secondary,
                                          size: 70,
                                        ),
                                      ),
                                    );
                                  },
                                ),
                              ),
                              if (images.length > 1) ...[
                                // Left arrow
                                Positioned(
                                  left: 12,
                                  top: 0,
                                  bottom: 0,
                                  child: Center(
                                    child: GestureDetector(
                                      onTap: () {
                                        if (_currentImageIndex > 0) {
                                          _pageController.previousPage(
                                            duration: const Duration(milliseconds: 300),
                                            curve: Curves.easeInOut,
                                          );
                                        }
                                      },
                                      child: Container(
                                        padding: const EdgeInsets.all(8),
                                        decoration: BoxDecoration(
                                          color: Colors.black.withValues(alpha: 0.45),
                                          shape: BoxShape.circle,
                                        ),
                                        child: const Icon(Icons.chevron_left, color: Colors.white, size: 22),
                                      ),
                                    ),
                                  ),
                                ),
                                // Right arrow
                                Positioned(
                                  right: 12,
                                  top: 0,
                                  bottom: 0,
                                  child: Center(
                                    child: GestureDetector(
                                      onTap: () {
                                        if (_currentImageIndex < images.length - 1) {
                                          _pageController.nextPage(
                                            duration: const Duration(milliseconds: 300),
                                            curve: Curves.easeInOut,
                                          );
                                        }
                                      },
                                      child: Container(
                                        padding: const EdgeInsets.all(8),
                                        decoration: BoxDecoration(
                                          color: Colors.black.withValues(alpha: 0.45),
                                          shape: BoxShape.circle,
                                        ),
                                        child: const Icon(Icons.chevron_right, color: Colors.white, size: 22),
                                      ),
                                    ),
                                  ),
                                ),
                                // Counter
                                Positioned(
                                  bottom: 12,
                                  left: 0,
                                  right: 0,
                                  child: Center(
                                    child: Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                                      decoration: BoxDecoration(
                                        color: Colors.black.withValues(alpha: 0.6),
                                        borderRadius: BorderRadius.circular(12),
                                      ),
                                      child: Text(
                                        '${_currentImageIndex + 1} / ${images.length}',
                                        style: GoogleFonts.heebo(
                                          color: Colors.white,
                                          fontSize: 12,
                                          fontWeight: FontWeight.w600,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                          // Thumbnail strip
                          if (images.length > 1)
                            Container(
                              height: 64,
                              color: AppColors.surfaceSubtle,
                              child: ListView.builder(
                                scrollDirection: Axis.horizontal,
                                padding: const EdgeInsets.all(8),
                                itemCount: images.length,
                                itemBuilder: (context, i) {
                                  return GestureDetector(
                                    onTap: () => _pageController.animateToPage(
                                      i,
                                      duration: const Duration(milliseconds: 300),
                                      curve: Curves.easeInOut,
                                    ),
                                    child: Container(
                                      margin: const EdgeInsets.only(right: 8),
                                      width: 52,
                                      decoration: BoxDecoration(
                                        borderRadius: BorderRadius.circular(8),
                                        border: Border.all(
                                          color: i == _currentImageIndex
                                              ? AppColors.primaryAction
                                              : Colors.transparent,
                                          width: 2,
                                        ),
                                      ),
                                      child: ClipRRect(
                                        borderRadius: BorderRadius.circular(6),
                                        child: Image.network(
                                          images[i],
                                          fit: BoxFit.cover,
                                        ),
                                      ),
                                    ),
                                  );
                                },
                              ),
                            ),
                        ] else
                          Container(
                            width: double.infinity,
                            height: 180,
                            color: AppColors.surfaceSubtle,
                            child: const Icon(
                              Icons.directions_car_rounded,
                              color: AppColors.secondary,
                              size: 64,
                            ),
                          ),

                        // Main Vehicle Card & Details
                        Padding(
                          padding: const EdgeInsets.all(16.0),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              // Vehicle Header Badge
                              Container(
                                padding: const EdgeInsets.all(16),
                                decoration: BoxDecoration(
                                  color: AppColors.surface,
                                  borderRadius: BorderRadius.circular(16),
                                  border: Border.all(color: AppColors.border),
                                  boxShadow: [
                                    BoxShadow(
                                      color: AppColors.onSurface.withValues(alpha: 0.03),
                                      blurRadius: 8,
                                      offset: const Offset(0, 2),
                                    ),
                                  ],
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.end,
                                  children: [
                                    if (vehicleTitle.isNotEmpty) ...[
                                      Text(
                                        vehicleTitle,
                                        textAlign: TextAlign.right,
                                        style: GoogleFonts.heebo(
                                          fontSize: 20,
                                          fontWeight: FontWeight.bold,
                                          color: AppColors.onSurface,
                                        ),
                                      ),
                                      const SizedBox(height: 4),
                                    ],
                                    Row(
                                      mainAxisAlignment: MainAxisAlignment.spaceBetween,
                                      children: [
                                        if (price.isNotEmpty)
                                          Text(
                                            '₪ $price',
                                            style: GoogleFonts.heebo(
                                              fontSize: 20,
                                              fontWeight: FontWeight.bold,
                                              color: AppColors.primaryAction,
                                            ),
                                          ),
                                        Text(
                                          'מספר רישוי: $license',
                                          style: GoogleFonts.heebo(
                                            fontSize: 15,
                                            fontWeight: FontWeight.w600,
                                            color: AppColors.secondary,
                                          ),
                                        ),
                                      ],
                                    ),
                                    if (publishedDateStr.isNotEmpty) ...[
                                      const SizedBox(height: 6),
                                      Text(
                                        'פורסם בתאריך: $publishedDateStr',
                                        style: GoogleFonts.heebo(
                                          fontSize: 12,
                                          color: AppColors.secondary.withValues(alpha: 0.8),
                                        ),
                                      ),
                                    ],
                                    if (lastPlatform.isNotEmpty) ...[
                                      const SizedBox(height: 4),
                                      Container(
                                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                        decoration: BoxDecoration(
                                          color: AppColors.primarySoft,
                                          borderRadius: BorderRadius.circular(6),
                                        ),
                                        child: Text(
                                          'ערוץ פרסום: $lastPlatform',
                                          style: GoogleFonts.heebo(
                                            fontSize: 11.5,
                                            fontWeight: FontWeight.w600,
                                            color: AppColors.primaryAction,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ),

                              const SizedBox(height: 14),

                              // Specs Table Container
                              Container(
                                padding: const EdgeInsets.all(16),
                                decoration: BoxDecoration(
                                  color: AppColors.surface,
                                  borderRadius: BorderRadius.circular(16),
                                  border: Border.all(color: AppColors.border),
                                ),
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.stretch,
                                  children: [
                                    Text(
                                      'מפרט הרכב',
                                      textAlign: TextAlign.right,
                                      style: GoogleFonts.heebo(
                                        fontSize: 16,
                                        fontWeight: FontWeight.bold,
                                        color: AppColors.onSurface,
                                      ),
                                    ),
                                    const SizedBox(height: 8),
                                    _buildDetailRow('מספר רישוי:', license.toString(), isBold: true),
                                    if (maker.isNotEmpty) ...[
                                      const Divider(color: AppColors.border),
                                      _buildDetailRow('יצרן:', maker),
                                    ],
                                    if (model.isNotEmpty) ...[
                                      const Divider(color: AppColors.border),
                                      _buildDetailRow('דגם:', model),
                                    ],
                                    if (year.isNotEmpty) ...[
                                      const Divider(color: AppColors.border),
                                      _buildDetailRow('שנת יצור:', year),
                                    ],
                                    if (month.isNotEmpty) ...[
                                      const Divider(color: AppColors.border),
                                      _buildDetailRow('חודש עליה לכביש:', month),
                                    ],
                                    if (testUntil.isNotEmpty || noTest) ...[
                                      const Divider(color: AppColors.border),
                                      _buildDetailRow(
                                        'טסט עד:',
                                        noTest ? 'ללא טסט' : testUntil,
                                      ),
                                    ],
                                    if (hand.isNotEmpty) ...[
                                      const Divider(color: AppColors.border),
                                      _buildDetailRow('יד:', hand),
                                    ],
                                    if (gear.isNotEmpty) ...[
                                      const Divider(color: AppColors.border),
                                      _buildDetailRow('תיבת הילוכים:', gear),
                                    ],
                                    if (fuelType.isNotEmpty) ...[
                                      const Divider(color: AppColors.border),
                                      _buildDetailRow('סוג דלק:', fuelType),
                                    ],
                                    if (vehicleCondition.isNotEmpty) ...[
                                      const Divider(color: AppColors.border),
                                      _buildDetailRow('מצב הרכב:', vehicleCondition),
                                    ],
                                    if (color.isNotEmpty) ...[
                                      const Divider(color: AppColors.border),
                                      _buildDetailRow('צבע:', color),
                                    ],
                                    if (city.isNotEmpty) ...[
                                      const Divider(color: AppColors.border),
                                      _buildDetailRow('עיר:', city),
                                    ],
                                    if (ownership.isNotEmpty) ...[
                                      const Divider(color: AppColors.border),
                                      _buildDetailRow('בעלות נוכחית:', ownership),
                                    ],
                                    if (prevOwnership.isNotEmpty) ...[
                                      const Divider(color: AppColors.border),
                                      _buildDetailRow('בעלות מקורית:', prevOwnership),
                                    ],
                                    if (km.isNotEmpty) ...[
                                      const Divider(color: AppColors.border),
                                      _buildDetailRow('ק"מ:', km),
                                    ],
                                    if (price.isNotEmpty) ...[
                                      const Divider(color: AppColors.border),
                                      _buildDetailRow('מחיר:', '₪ $price'),
                                    ],
                                    if (handicapped.isNotEmpty) ...[
                                      const Divider(color: AppColors.border),
                                      _buildDetailRow('נכה:', handicapped),
                                    ],
                                  ],
                                ),
                              ),

                              // Description Box
                              if (description.isNotEmpty) ...[
                                const SizedBox(height: 14),
                                Container(
                                  padding: const EdgeInsets.all(16),
                                  decoration: BoxDecoration(
                                    color: AppColors.surface,
                                    borderRadius: BorderRadius.circular(16),
                                    border: Border.all(color: AppColors.border),
                                  ),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.end,
                                    children: [
                                      Text(
                                        'תיאור המודעה',
                                        style: GoogleFonts.heebo(
                                          fontSize: 16,
                                          fontWeight: FontWeight.bold,
                                          color: AppColors.onSurface,
                                        ),
                                      ),
                                      const SizedBox(height: 8),
                                      Text(
                                        description,
                                        textAlign: TextAlign.right,
                                        style: GoogleFonts.heebo(
                                          fontSize: 14,
                                          color: AppColors.onSurface,
                                          height: 1.4,
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],

                              // Benefits & Services Section
                              if ((listing['warranties'] != null && (listing['warranties'] as List).isNotEmpty) ||
                                  (listing['treatments'] != null && (listing['treatments'] as List).isNotEmpty) ||
                                  (listing['services'] != null && (listing['services'] as List).isNotEmpty)) ...[
                                const SizedBox(height: 14),
                                Container(
                                  padding: const EdgeInsets.all(16),
                                  decoration: BoxDecoration(
                                    color: AppColors.surface,
                                    borderRadius: BorderRadius.circular(16),
                                    border: Border.all(color: AppColors.border),
                                  ),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.end,
                                    children: [
                                      Text(
                                        'הטבות ושירותים',
                                        style: GoogleFonts.heebo(
                                          fontSize: 16,
                                          fontWeight: FontWeight.bold,
                                          color: AppColors.onSurface,
                                        ),
                                      ),
                                      const SizedBox(height: 8),
                                      if (listing['warranties'] != null && (listing['warranties'] as List).isNotEmpty) ...[
                                        Text(
                                          'אחריות:',
                                          style: GoogleFonts.heebo(
                                            fontSize: 13.5,
                                            fontWeight: FontWeight.bold,
                                            color: AppColors.secondary,
                                          ),
                                        ),
                                        const SizedBox(height: 4),
                                        ...(listing['warranties'] as List).map((w) {
                                          final duration = (listing['warrantyDurations'] as Map?)?[w] ?? 'לא הוגדר זמן';
                                          return Padding(
                                            padding: const EdgeInsets.symmetric(vertical: 2.0),
                                            child: Text(
                                              '• $w ($duration)',
                                              style: GoogleFonts.heebo(fontSize: 13.5),
                                              textAlign: TextAlign.right,
                                            ),
                                          );
                                        }),
                                        const SizedBox(height: 8),
                                      ],
                                      if (listing['treatments'] != null && (listing['treatments'] as List).isNotEmpty) ...[
                                        Text(
                                          'טיפולים:',
                                          style: GoogleFonts.heebo(
                                            fontSize: 13.5,
                                            fontWeight: FontWeight.bold,
                                            color: AppColors.secondary,
                                          ),
                                        ),
                                        const SizedBox(height: 4),
                                        ...(listing['treatments'] as List).map((t) => Padding(
                                          padding: const EdgeInsets.symmetric(vertical: 2.0),
                                          child: Text(
                                            '• $t',
                                            style: GoogleFonts.heebo(fontSize: 13.5),
                                            textAlign: TextAlign.right,
                                          ),
                                        )),
                                        const SizedBox(height: 8),
                                      ],
                                      if (listing['services'] != null && (listing['services'] as List).isNotEmpty) ...[
                                        Text(
                                          'שירותים נלווים:',
                                          style: GoogleFonts.heebo(
                                            fontSize: 13.5,
                                            fontWeight: FontWeight.bold,
                                            color: AppColors.secondary,
                                          ),
                                        ),
                                        const SizedBox(height: 4),
                                        ...(listing['services'] as List).map((s) => Padding(
                                          padding: const EdgeInsets.symmetric(vertical: 2.0),
                                          child: Text(
                                            '• $s',
                                            style: GoogleFonts.heebo(fontSize: 13.5),
                                            textAlign: TextAlign.right,
                                          ),
                                        )),
                                      ],
                                    ],
                                  ),
                                ),
                              ],
                              const SizedBox(height: 24),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

                // Bottom Action Bar
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: AppColors.surface,
                    border: const Border(top: BorderSide(color: AppColors.border)),
                    boxShadow: [
                      BoxShadow(
                        color: AppColors.onSurface.withValues(alpha: 0.04),
                        blurRadius: 10,
                        offset: const Offset(0, -4),
                      ),
                    ],
                  ),
                  child: Row(
                    children: [
                      Expanded(
                        child: SizedBox(
                          height: 48,
                          child: OutlinedButton.icon(
                            onPressed: _deleteListing,
                            style: OutlinedButton.styleFrom(
                              foregroundColor: AppColors.error,
                              side: const BorderSide(color: AppColors.error, width: 1.2),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                            icon: const Icon(Icons.delete_outline_rounded, size: 20),
                            label: Text(
                              'מחיקת מודעה',
                              style: GoogleFonts.heebo(
                                fontSize: 15,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: SizedBox(
                          height: 48,
                          child: ElevatedButton(
                            onPressed: () => Navigator.pop(context),
                            style: ElevatedButton.styleFrom(
                              backgroundColor: AppColors.primaryAction,
                              foregroundColor: Colors.white,
                              elevation: 0,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(12),
                              ),
                            ),
                            child: Text(
                              'סגור',
                              style: GoogleFonts.heebo(
                                fontSize: 15,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
    );
  }

  Widget _buildDetailRow(String label, String value, {bool isBold = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            child: Text(
              value,
              textAlign: TextAlign.left,
              style: GoogleFonts.heebo(
                fontSize: 14.5,
                fontWeight: isBold ? FontWeight.bold : FontWeight.normal,
                color: AppColors.onSurface,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Text(
            label,
            textAlign: TextAlign.right,
            style: GoogleFonts.heebo(
              fontSize: 14.5,
              fontWeight: isBold ? FontWeight.bold : FontWeight.w500,
              color: isBold ? AppColors.onSurface : AppColors.secondary,
            ),
          ),
        ],
      ),
    );
  }
}
