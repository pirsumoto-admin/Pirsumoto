import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../services/db_service.dart';
import '../auth/auth_provider.dart';
import 'listing_details_screen.dart';

class ListingsScreen extends ConsumerWidget {
  final void Function(Map<String, dynamic> listing)? onEditListing;

  const ListingsScreen({super.key, this.onEditListing});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final user = ref.watch(authStateProvider).value;
    if (user == null) return const SizedBox.shrink();

    final listingsStream = ref
        .watch(dbServiceProvider)
        .getUserListingsStream(user.uid);

    return Scaffold(
      backgroundColor: Colors.white,
      appBar: AppBar(
        title: const Text(
          'מודעות שלי',
          style: TextStyle(
            color: Colors.black,
            fontSize: 18,
            fontWeight: FontWeight.bold,
          ),
        ),
        backgroundColor: Colors.white,
        elevation: 0,
        centerTitle: true,
        bottom: PreferredSize(
          preferredSize: const Size.fromHeight(1.0),
          child: Container(color: Colors.grey.shade300, height: 1.0),
        ),
      ),
      body: Column(
        children: [
          // Filter Bar
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: 16.0,
              vertical: 12.0,
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 6,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white,
                    border: Border.all(color: Colors.pink.shade100),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: Row(
                    children: [
                      const Text(
                        'מועדפים בלבד',
                        style: TextStyle(
                          color: Colors.grey,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(width: 4),
                      Icon(
                        Icons.favorite,
                        color: Colors.pink.shade400,
                        size: 16,
                      ),
                    ],
                  ),
                ),
                TextButton.icon(
                  onPressed: () {},
                  icon: const Icon(Icons.search, color: Color(0xFF3B5BDB)),
                  label: const Text(
                    'הצג סינון',
                    style: TextStyle(
                      color: Color(0xFF3B5BDB),
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                  style: TextButton.styleFrom(padding: EdgeInsets.zero),
                ),
              ],
            ),
          ),

          Expanded(
            child: StreamBuilder<List<Map<String, dynamic>>>(
              stream: listingsStream,
              builder: (context, snapshot) {
                if (snapshot.connectionState == ConnectionState.waiting) {
                  return const Center(child: CircularProgressIndicator());
                }

                if (snapshot.hasError) {
                  return Center(
                    child: Text(
                      'Error: ${snapshot.error}',
                      style: const TextStyle(color: Colors.red),
                    ),
                  );
                }

                final listings = snapshot.data ?? [];

                return Column(
                  children: [
                    // Item Count
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16.0),
                      child: Align(
                        alignment: Alignment.centerRight,
                        child: Text(
                          '${listings.length} מודעות',
                          style: const TextStyle(
                            color: Colors.grey,
                            fontSize: 14,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),

                    if (listings.isEmpty)
                      const Expanded(
                        child: Center(
                          child: Text(
                            'No listings found.',
                            style: TextStyle(color: Colors.grey, fontSize: 18),
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
                          itemCount: listings.length,
                          itemBuilder: (context, index) {
                            final listing = listings[index];
                            return _buildListingCard(
                              context,
                              ref,
                              user.uid,
                              listing,
                              onEdit: onEditListing,
                            );
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

  Future<void> _confirmDelete(
    BuildContext context,
    WidgetRef ref,
    String uid,
    String license,
  ) async {
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
            child:
                const Text('מחיקה', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (confirm == true) {
      await ref.read(dbServiceProvider).deleteUserListing(license, uid);
    }
  }

  Widget _buildListingCard(
    BuildContext context,
    WidgetRef ref,
    String uid,
    Map<String, dynamic> listing, {
    void Function(Map<String, dynamic>)? onEdit,
  }) {
    // Generate placeholder data if real ones are missing for design accuracy
    final license = listing['license'] ?? '1746171';
    final price = listing['price'] ?? '89,500';
    final hand = listing['hand'] ?? '1';
    final ownership = listing['ownership'] ?? 'חברה';
    final km = listing['km'] ?? '124,550';
    final isFavorite = listing['isFavorite'] == true;
    dynamic firstImage;
    if (listing['images'] != null && (listing['images'] as List).isNotEmpty) {
      firstImage = (listing['images'] as List).first;
    }
    
    String imageUrl = 'https://via.placeholder.com/150';
    if (firstImage is String) {
      imageUrl = firstImage;
    } else if (firstImage is Map<String, dynamic>) {
      imageUrl = firstImage['url'] ?? firstImage['path'] ?? 'https://via.placeholder.com/150';
    }

    return GestureDetector(
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => ListingDetailsScreen(
              listing: listing,
              onEdit: onEdit != null ? () => onEdit(listing) : null,
            ),
          ),
        );
      },
      child: Container(
        margin: const EdgeInsets.only(bottom: 16),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: Colors.grey.shade300),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.05),
              blurRadius: 8,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: IntrinsicHeight(
         child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // Left Action Buttons
            Padding(
              padding: const EdgeInsets.all(12.0),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  SizedBox(
                    width: 70,
                    height: 36,
                    child: ElevatedButton(
                      onPressed: onEdit != null ? () => onEdit(listing) : null,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF5B7FFF),
                        padding: EdgeInsets.zero,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(6),
                        ),
                      ),
                      child: const Text(
                        'עריכה',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 12),
                  SizedBox(
                    width: 70,
                    height: 36,
                    child: ElevatedButton(
                      onPressed: () => _confirmDelete(
                          context, ref, uid, listing['license'].toString()),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFFF5252),
                        padding: EdgeInsets.zero,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(6),
                        ),
                      ),
                      child: const Text(
                        'מחיקה',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.bold,
                          fontSize: 14,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),

            // Center Details
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  vertical: 12.0,
                  horizontal: 8.0,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    RichText(
                      text: TextSpan(
                        style: const TextStyle(
                          color: Colors.black,
                          fontSize: 16,
                        ),
                        children: [
                          TextSpan(
                            text: '$license ',
                            style: const TextStyle(fontWeight: FontWeight.bold),
                          ),
                          const TextSpan(
                            text: ':מספר רישוי',
                            style: TextStyle(fontWeight: FontWeight.bold),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'מחיר: ₪ $price',
                      style: const TextStyle(color: Colors.grey, fontSize: 14),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'יד: $hand',
                      style: const TextStyle(color: Colors.grey, fontSize: 14),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'בעלות: $ownership',
                      style: const TextStyle(color: Colors.grey, fontSize: 14),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'ק"מ: $km',
                      style: const TextStyle(color: Colors.grey, fontSize: 14),
                    ),
                  ],
                ),
              ),
            ),

            // Right Image
            Padding(
              padding: const EdgeInsets.all(8.0),
              child: Stack(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: Image.network(
                      imageUrl,
                      width: 100,
                      height: 120,
                      fit: BoxFit.cover,
                      errorBuilder:
                          (_, __, ___) => Container(
                            width: 100,
                            height: 120,
                            color: Colors.grey.shade200,
                            child: const Icon(
                              Icons.directions_car,
                              color: Colors.grey,
                            ),
                          ),
                    ),
                  ),
                  Positioned(
                    top: 4,
                    left: 4,
                    child: GestureDetector(
                      onTap: () {
                        // Toggle favorite logic
                        ref
                            .read(dbServiceProvider)
                            .toggleFavorite(listing['license'].toString(), uid);
                      },
                      child: Container(
                        padding: const EdgeInsets.all(4),
                        decoration: BoxDecoration(
                          color: Colors.white.withOpacity(0.8),
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          isFavorite ? Icons.favorite : Icons.favorite_border,
                          size: 20,
                          color: Colors.pink.shade300,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        ),
      ),
    );
  }
}
