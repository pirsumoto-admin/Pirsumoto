import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../services/db_service.dart';
import '../auth/auth_provider.dart';

class ListingDetailsScreen extends ConsumerStatefulWidget {
  final Map<String, dynamic> listing;
  final VoidCallback? onEdit;

  const ListingDetailsScreen({
    super.key,
    required this.listing,
    this.onEdit,
  });

  @override
  ConsumerState<ListingDetailsScreen> createState() =>
      _ListingDetailsScreenState();
}

class _ListingDetailsScreenState extends ConsumerState<ListingDetailsScreen> {
  int _currentImageIndex = 0;
  late PageController _pageController;
  late bool _isFavorite;

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
    return raw.map((img) {
      if (img is String) return img;
      if (img is Map) return (img['url'] ?? '').toString();
      return '';
    }).where((s) => s.isNotEmpty).toList();
  }

  Future<void> _deleteListing() async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('מחיקת מודעה', textAlign: TextAlign.right),
        content: const Text('האם אתה בטוח שברצונך למחוק מודעה זו?',
            textAlign: TextAlign.right),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('ביטול'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('מחיקה', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirm != true) return;

    final user = ref.read(authStateProvider).value;
    if (user == null) return;
    final license = widget.listing['license']?.toString() ?? '';
    await ref.read(dbServiceProvider).deleteUserListing(license, user.uid);
    if (mounted) Navigator.pop(context);
  }

  @override
  Widget build(BuildContext context) {
    final listing = widget.listing;
    final license = listing['license'] ?? '';
    final month = listing['month'] ?? '';
    final testUntil = listing['test'] ?? listing['testUntil'] ?? '';
    final hand = listing['hand'] ?? '';
    final ownership = listing['ownership'] ?? '';
    final prevOwnership = listing['prevOwnership'] ?? '';
    final km = listing['km'] ?? '';
    final price = listing['price'] ?? '';
    final handicapped = listing['handicapped'] ?? '';
    final description = listing['description'] ?? '';
    final images = _images;
    final user = ref.watch(authStateProvider).value;

    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        automaticallyImplyLeading: false,
        backgroundColor: Colors.white,
        elevation: 0,
        title: const Text(
          'פרטי המודעה',
          style: TextStyle(
            color: Colors.black,
            fontSize: 18,
            fontWeight: FontWeight.bold,
          ),
        ),
        centerTitle: true,
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1.0),
          child: Container(color: Colors.grey.shade300, height: 1.0),
        ),
        leadingWidth: 140,
        leading: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text(
                'סגור',
                style: TextStyle(
                  color: Color(0xFF3B5BDB),
                  fontSize: 16,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
            GestureDetector(
              onTap: () {
                if (user != null) {
                  setState(() => _isFavorite = !_isFavorite);
                  ref
                      .read(dbServiceProvider)
                      .toggleFavorite(license.toString(), user.uid);
                }
              },
              child: Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.pink.shade200),
                  borderRadius: BorderRadius.circular(16),
                  color: Colors.white,
                ),
                child: Row(
                  children: [
                    const Text('מועדף',
                        style: TextStyle(color: Colors.pink)),
                    const SizedBox(width: 4),
                    Icon(
                      _isFavorite
                          ? Icons.favorite
                          : Icons.favorite_border,
                      color: Colors.pink.shade300,
                      size: 16,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
      body: Column(
        children: [
          Expanded(
            child: SingleChildScrollView(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  // Image Gallery
                  if (images.isNotEmpty) ...[
                    Stack(
                      children: [
                        SizedBox(
                          height: 250,
                          child: PageView.builder(
                            controller: _pageController,
                            itemCount: images.length,
                            onPageChanged: (i) =>
                                setState(() => _currentImageIndex = i),
                            itemBuilder: (context, i) {
                              return Image.network(
                                images[i],
                                width: double.infinity,
                                height: 250,
                                fit: BoxFit.cover,
                                errorBuilder: (_, __, ___) => Container(
                                  color: Colors.grey.shade200,
                                  child: const Icon(Icons.directions_car,
                                      color: Colors.grey, size: 80),
                                ),
                              );
                            },
                          ),
                        ),
                        if (images.length > 1) ...[
                          // Left arrow
                          Positioned(
                            left: 8,
                            top: 0,
                            bottom: 0,
                            child: Center(
                              child: GestureDetector(
                                onTap: () {
                                  if (_currentImageIndex > 0) {
                                    _pageController.previousPage(
                                      duration:
                                          const Duration(milliseconds: 300),
                                      curve: Curves.easeInOut,
                                    );
                                  }
                                },
                                child: Container(
                                  padding: const EdgeInsets.all(6),
                                  decoration: BoxDecoration(
                                    color: Colors.black.withOpacity(0.4),
                                    shape: BoxShape.circle,
                                  ),
                                  child: const Icon(Icons.chevron_left,
                                      color: Colors.white),
                                ),
                              ),
                            ),
                          ),
                          // Right arrow
                          Positioned(
                            right: 8,
                            top: 0,
                            bottom: 0,
                            child: Center(
                              child: GestureDetector(
                                onTap: () {
                                  if (_currentImageIndex < images.length - 1) {
                                    _pageController.nextPage(
                                      duration:
                                          const Duration(milliseconds: 300),
                                      curve: Curves.easeInOut,
                                    );
                                  }
                                },
                                child: Container(
                                  padding: const EdgeInsets.all(6),
                                  decoration: BoxDecoration(
                                    color: Colors.black.withOpacity(0.4),
                                    shape: BoxShape.circle,
                                  ),
                                  child: const Icon(Icons.chevron_right,
                                      color: Colors.white),
                                ),
                              ),
                            ),
                          ),
                          // Counter
                          Positioned(
                            bottom: 8,
                            left: 0,
                            right: 0,
                            child: Center(
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                    horizontal: 10, vertical: 4),
                                decoration: BoxDecoration(
                                  color: Colors.black.withOpacity(0.5),
                                  borderRadius: BorderRadius.circular(12),
                                ),
                                child: Text(
                                  '${_currentImageIndex + 1} / ${images.length}',
                                  style: const TextStyle(
                                      color: Colors.white, fontSize: 12),
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
                        height: 60,
                        color: Colors.grey.shade100,
                        child: ListView.builder(
                          scrollDirection: Axis.horizontal,
                          padding: const EdgeInsets.all(6),
                          itemCount: images.length,
                          itemBuilder: (context, i) {
                            return GestureDetector(
                              onTap: () =>
                                  _pageController.animateToPage(i,
                                      duration:
                                          const Duration(milliseconds: 300),
                                      curve: Curves.easeInOut),
                              child: Container(
                                margin: const EdgeInsets.only(right: 6),
                                width: 50,
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(6),
                                  border: Border.all(
                                    color: i == _currentImageIndex
                                        ? const Color(0xFF3B5BDB)
                                        : Colors.transparent,
                                    width: 2,
                                  ),
                                ),
                                child: ClipRRect(
                                  borderRadius: BorderRadius.circular(4),
                                  child: Image.network(images[i],
                                      fit: BoxFit.cover),
                                ),
                              ),
                            );
                          },
                        ),
                      ),
                  ] else
                    Container(
                      width: double.infinity,
                      height: 250,
                      color: Colors.grey.shade200,
                      child: const Icon(Icons.directions_car,
                          color: Colors.grey, size: 80),
                    ),

                  // Details Section
                  Padding(
                    padding: const EdgeInsets.all(16.0),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        const Text(
                          'פרטי הרכב',
                          style: TextStyle(
                            fontSize: 18,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(height: 12),
                        const Divider(),
                        _buildDetailRow('מספר רישוי:', license.toString(),
                            isBold: true),
                        if (month.isNotEmpty) ...[
                          const Divider(),
                          _buildDetailRow('חודש עליה לכביש:', month.toString()),
                        ],
                        if (testUntil.isNotEmpty) ...[
                          const Divider(),
                          _buildDetailRow('טסט עד:', testUntil.toString()),
                        ],
                        if (hand.isNotEmpty) ...[
                          const Divider(),
                          _buildDetailRow('יד:', hand.toString()),
                        ],
                        if (ownership.isNotEmpty) ...[
                          const Divider(),
                          _buildDetailRow('בעלות נוכחית:', ownership.toString()),
                        ],
                        if (prevOwnership.isNotEmpty) ...[
                          const Divider(),
                          _buildDetailRow(
                              'בעלות מקורית:', prevOwnership.toString()),
                        ],
                        if (km.isNotEmpty) ...[
                          const Divider(),
                          _buildDetailRow('ק"מ:', km.toString()),
                        ],
                        if (price.isNotEmpty) ...[
                          const Divider(),
                          _buildDetailRow('מחיר:', '₪ ${price.toString()}'),
                        ],
                        if (handicapped.isNotEmpty) ...[
                          const Divider(),
                          _buildDetailRow('נכה:', handicapped.toString()),
                        ],
                        if (description.isNotEmpty) ...[
                          const Divider(),
                          Padding(
                            padding:
                                const EdgeInsets.symmetric(vertical: 12.0),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                const Text('תיאור:',
                                    style: TextStyle(
                                        fontSize: 16,
                                        fontWeight: FontWeight.bold)),
                                const SizedBox(height: 4),
                                Text(description.toString(),
                                    textAlign: TextAlign.right,
                                    style: const TextStyle(fontSize: 16)),
                              ],
                            ),
                          ),
                        ],
                        // Benefits & Services Section
                        if ((listing['warranties'] != null && (listing['warranties'] as List).isNotEmpty) ||
                            (listing['treatments'] != null && (listing['treatments'] as List).isNotEmpty) ||
                            (listing['services'] != null && (listing['services'] as List).isNotEmpty)) ...[
                          const Divider(),
                          Padding(
                            padding: const EdgeInsets.symmetric(vertical: 12.0),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.end,
                              children: [
                                const Text(
                                  'הטבות ושירותים:',
                                  style: TextStyle(
                                    fontSize: 16,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                const SizedBox(height: 8),
                                if (listing['warranties'] != null && (listing['warranties'] as List).isNotEmpty) ...[
                                  const Text(
                                    'אחריות:',
                                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.black54),
                                  ),
                                  const SizedBox(height: 4),
                                  ...(listing['warranties'] as List).map((w) {
                                    final duration = (listing['warrantyDurations'] as Map?)?[w] ?? 'לא הוגדר זמן';
                                    return Text(
                                      '• $w ($duration)',
                                      style: const TextStyle(fontSize: 14),
                                      textAlign: TextAlign.right,
                                    );
                                  }),
                                  const SizedBox(height: 8),
                                ],
                                if (listing['treatments'] != null && (listing['treatments'] as List).isNotEmpty) ...[
                                  const Text(
                                    'טיפולים:',
                                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.black54),
                                  ),
                                  const SizedBox(height: 4),
                                  ...(listing['treatments'] as List).map((t) => Text(
                                    '• $t',
                                    style: const TextStyle(fontSize: 14),
                                    textAlign: TextAlign.right,
                                  )),
                                  const SizedBox(height: 8),
                                ],
                                if (listing['services'] != null && (listing['services'] as List).isNotEmpty) ...[
                                  const Text(
                                    'שירות:',
                                    style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold, color: Colors.black54),
                                  ),
                                  const SizedBox(height: 4),
                                  ...(listing['services'] as List).map((s) => Text(
                                    '• $s',
                                    style: const TextStyle(fontSize: 14),
                                    textAlign: TextAlign.right,
                                  )),
                                ],
                              ],
                            ),
                          ),
                        ],
                        const Divider(),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),

          // Fixed Bottom Actions Row
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 60,
                  child: ElevatedButton(
                    onPressed: _deleteListing,
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFFF5252),
                      shape: const RoundedRectangleBorder(
                          borderRadius: BorderRadius.zero),
                      elevation: 0,
                    ),
                    child: const Text(
                      'מחיקה',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 18,
                      ),
                    ),
                  ),
                ),
              ),
              Expanded(
                child: SizedBox(
                  height: 60,
                  child: ElevatedButton(
                    onPressed: () {
                      Navigator.pop(context);
                      widget.onEdit?.call();
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF5B7FFF),
                      shape: const RoundedRectangleBorder(
                          borderRadius: BorderRadius.zero),
                      elevation: 0,
                    ),
                    child: const Text(
                      'עריכה',
                      style: TextStyle(
                        color: Colors.white,
                        fontWeight: FontWeight.bold,
                        fontSize: 18,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildDetailRow(String label, String value, {bool isBold = false}) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(value, style: const TextStyle(fontSize: 16)),
          Text(
            label,
            style: TextStyle(
              fontSize: 16,
              fontWeight: isBold ? FontWeight.bold : FontWeight.normal,
            ),
          ),
        ],
      ),
    );
  }
}
