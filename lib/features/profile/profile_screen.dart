import 'dart:async';
import 'dart:io';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import '../auth/auth_provider.dart';
import '../../services/db_service.dart';

class ProfileScreen extends ConsumerStatefulWidget {
  const ProfileScreen({super.key});

  @override
  ConsumerState<ProfileScreen> createState() => _ProfileScreenState();
}

class _ProfileScreenState extends ConsumerState<ProfileScreen> {
  final _nameController = TextEditingController();
  final _emailController = TextEditingController();
  final _phoneController = TextEditingController();
  final _companyNumberController = TextEditingController();

  String _selectedLanguage = 'עברית';
  final List<String> _languages = ['עברית', 'العربية', 'русский', 'English'];

  String? _profileImagePath;
  bool _isLoading = true;
  bool _isSaving = false;
  StreamSubscription<DocumentSnapshot>? _profileSubscription;

  final _picker = ImagePicker();

  @override
  void initState() {
    super.initState();
    _loadProfile();
  }

  String? get _currentUserId {
    return ref.read(authStateProvider).value?.uid ??
        FirebaseAuth.instance.currentUser?.uid;
  }

  Future<void> _loadProfile() async {
    final user =
        ref.read(authStateProvider).value ?? FirebaseAuth.instance.currentUser;

    // Load local profile image first if available
    try {
      final dir = await getApplicationDocumentsDirectory();
      final imgFile = File('${dir.path}/profile_image.png');
      if (await imgFile.exists() && mounted) {
        setState(() => _profileImagePath = imgFile.path);
      }
    } catch (e) {
      debugPrint('[ProfileScreen] Error loading local profile image: $e');
    }

    if (user != null) {
      _profileSubscription = FirebaseFirestore.instance
          .collection('users')
          .doc(user.uid)
          .snapshots()
          .listen((doc) {
        if (mounted) {
          final profile = doc.exists ? (doc.data()?['profile'] as Map<String, dynamic>?) : null;
          setState(() {
            if (!_isSaving) { // Avoid overwriting while typing/saving locally
              _nameController.text = profile?['name'] ?? profile?['displayName'] ?? user.displayName ?? '';
              _emailController.text = profile?['email'] ?? user.email ?? '';
              _phoneController.text = profile?['phone'] ?? profile?['phoneNumber'] ?? user.phoneNumber ?? '';
              _companyNumberController.text = profile?['companyNumber'] ?? '';
              _selectedLanguage = profile?['language'] ?? 'עברית';
            }

            final savedPath = profile?['profileImagePath'];
            if (savedPath is String && savedPath.isNotEmpty) {
              if (File(savedPath).existsSync()) {
                _profileImagePath = savedPath;
              }
            }
            if (_isLoading) {
              _isLoading = false;
            }
          });
        }
      }, onError: (e) {
        debugPrint('[ProfileScreen] Error listening to profile from Firestore: $e');
        if (mounted) setState(() => _isLoading = false);
      });
    } else {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _pickProfileImage() async {
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: Container(
          padding: const EdgeInsets.all(24),
          decoration: const BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.only(
              topLeft: Radius.circular(24),
              topRight: Radius.circular(24),
            ),
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _sheetButton(
                'העלאה מגלריה',
                const Color(0xFF3B5BDB),
                () => Navigator.pop(ctx, ImageSource.gallery),
              ),
              const SizedBox(height: 12),
              _sheetButton(
                'צילום תמונה',
                const Color(0xFF3B5BDB),
                () => Navigator.pop(ctx, ImageSource.camera),
              ),
              const SizedBox(height: 12),
              _sheetButton(
                'ביטול',
                const Color(0xFFF1F5F9),
                () => Navigator.pop(ctx),
                textColor: Colors.red.shade700,
              ),
              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
    if (source == null) return;

    final image = await _picker.pickImage(source: source, imageQuality: 80);
    if (image == null) return;

    final dir = await getApplicationDocumentsDirectory();
    final dest = '${dir.path}/profile_image.png';
    await File(image.path).copy(dest);
    if (mounted) setState(() => _profileImagePath = dest);
  }

  Future<void> _removeProfileImage() async {
    if (_profileImagePath != null) {
      final file = File(_profileImagePath!);
      if (await file.exists()) await file.delete();
    }
    if (mounted) setState(() => _profileImagePath = null);
  }

  Future<void> _saveProfile() async {
    final userId = _currentUserId;
    if (userId == null || userId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'שגיאה: משתמש לא מחובר',
            textAlign: TextAlign.right,
          ),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    setState(() => _isSaving = true);
    final db = ref.read(dbServiceProvider);
    final success = await db.saveProfileData(userId, {
      'name': _nameController.text.trim(),
      'email': _emailController.text.trim(),
      'phone': _phoneController.text.trim(),
      'companyNumber': _companyNumberController.text.trim(),
      'language': _selectedLanguage,
      'profileImagePath': _profileImagePath ?? '',
      'updatedAt': DateTime.now().toIso8601String(),
    });

    if (mounted) {
      setState(() => _isSaving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            success ? 'הפרופיל נשמר בהצלחה' : 'שגיאה בשמירת הפרופיל',
            textAlign: TextAlign.right,
          ),
          backgroundColor: success ? Colors.green : Colors.red,
        ),
      );
    }
  }

  @override
  void dispose() {
    _profileSubscription?.cancel();
    _nameController.dispose();
    _emailController.dispose();
    _phoneController.dispose();
    _companyNumberController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        backgroundColor: const Color(0xFFF8FAFC),
        body: _isLoading
            ? const Center(child: CircularProgressIndicator())
            : SingleChildScrollView(
                padding: const EdgeInsets.symmetric(horizontal: 16.0, vertical: 20.0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const SizedBox(height: 12),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Text(
                          'פרופיל',
                          style: TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF1E293B),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Icon(
                          Icons.person_rounded,
                          color: Colors.grey.shade600,
                          size: 28,
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),
                    _buildCompanyLogoCard(),
                    const SizedBox(height: 16),
                    _buildProfileDetailsCard(),
                    const SizedBox(height: 28),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton(
                        onPressed: _isSaving ? null : _saveProfile,
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF3B5BDB),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 16),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                          elevation: 1,
                        ),
                        child: _isSaving
                            ? const SizedBox(
                                width: 20,
                                height: 20,
                                child: CircularProgressIndicator(
                                  color: Colors.white,
                                  strokeWidth: 2.5,
                                ),
                              )
                            : const Text(
                                'שמירה',
                                style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.white,
                                ),
                              ),
                      ),
                    ),
                    const SizedBox(height: 16),
                    OutlinedButton.icon(
                      onPressed: () {
                        ref.read(authControllerProvider.notifier).signOut();
                      },
                      icon: const Icon(Icons.logout_rounded, color: Colors.red),
                      label: const Text(
                        'התנתק',
                        style: TextStyle(
                          color: Colors.red,
                          fontWeight: FontWeight.bold,
                          fontSize: 15,
                        ),
                      ),
                      style: OutlinedButton.styleFrom(
                        backgroundColor: Colors.white,
                        side: const BorderSide(color: Color(0xFFFCA5A5)),
                        padding: const EdgeInsets.symmetric(vertical: 14),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                    ),
                    const SizedBox(height: 24),
                  ],
                ),
              ),
      ),
    );
  }

  Widget _buildCompanyLogoCard() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade200),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'לוגו חברה',
            style: TextStyle(
              color: Color(0xFF1E293B),
              fontSize: 16,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 20),
          Center(
            child: Stack(
              children: [
                GestureDetector(
                  onTap: _pickProfileImage,
                  child: Container(
                    width: 110,
                    height: 110,
                    decoration: BoxDecoration(
                      color: const Color(0xFFF1F5F9),
                      shape: BoxShape.circle,
                      border: Border.all(color: Colors.grey.shade300, width: 2),
                    ),
                    child: ClipOval(
                      child: _profileImagePath != null
                          ? Image.file(
                              File(_profileImagePath!),
                              fit: BoxFit.cover,
                            )
                          : Icon(
                              Icons.business_rounded,
                              color: Colors.grey.shade400,
                              size: 52,
                            ),
                    ),
                  ),
                ),
                if (_profileImagePath != null)
                  Positioned(
                    top: 0,
                    right: 0,
                    child: GestureDetector(
                      onTap: _removeProfileImage,
                      child: Container(
                        width: 28,
                        height: 28,
                        decoration: const BoxDecoration(
                          color: Colors.red,
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.close,
                          size: 16,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
                if (_profileImagePath == null)
                  Positioned(
                    bottom: 2,
                    right: 2,
                    child: GestureDetector(
                      onTap: _pickProfileImage,
                      child: Container(
                        width: 32,
                        height: 32,
                        decoration: const BoxDecoration(
                          color: Color(0xFF3B5BDB),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(
                          Icons.camera_alt,
                          size: 18,
                          color: Colors.white,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Center(
            child: Text(
              'לחץ לשינוי תמונה',
              style: TextStyle(
                fontSize: 12,
                color: Colors.grey.shade600,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildProfileDetailsCard() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade200),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.04),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'פרטי פרופיל',
            style: TextStyle(
              color: Color(0xFF1E293B),
              fontSize: 16,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(height: 20),
          _buildTextField('שם משתמש', _nameController, isRequired: true),
          const SizedBox(height: 16),
          _buildTextField(
            'דוא״ל',
            _emailController,
            isRequired: true,
            keyboardType: TextInputType.emailAddress,
          ),
          const SizedBox(height: 16),
          _buildTextField(
            'טלפון',
            _phoneController,
            isRequired: true,
            keyboardType: TextInputType.phone,
          ),
          const SizedBox(height: 16),
          _buildTextField(
            'ח״פ (מספר חברה)',
            _companyNumberController,
            keyboardType: TextInputType.number,
          ),
          const SizedBox(height: 16),
          // Language selector
          Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'שפה',
                style: TextStyle(
                  color: Color(0xFF1E293B),
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.white,
                  border: Border.all(color: Colors.grey.shade300),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    value: _selectedLanguage,
                    dropdownColor: Colors.white,
                    style: const TextStyle(
                      color: Color(0xFF1E293B),
                      fontSize: 15,
                      fontWeight: FontWeight.w500,
                    ),
                    icon: const Icon(
                      Icons.arrow_drop_down,
                      color: Color(0xFF64748B),
                    ),
                    isExpanded: true,
                    alignment: AlignmentDirectional.centerStart,
                    items: _languages
                        .map(
                          (lang) => DropdownMenuItem(
                            value: lang,
                            child: Align(
                              alignment: AlignmentDirectional.centerStart,
                              child: Text(
                                lang,
                                style: const TextStyle(
                                  color: Color(0xFF1E293B),
                                  fontSize: 15,
                                ),
                              ),
                            ),
                          ),
                        )
                        .toList(),
                    onChanged: (val) {
                      if (val != null) {
                        setState(() => _selectedLanguage = val);
                      }
                    },
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  Widget _buildTextField(
    String label,
    TextEditingController controller, {
    bool isRequired = false,
    TextInputType keyboardType = TextInputType.text,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        RichText(
          text: TextSpan(
            children: [
              if (isRequired)
                const TextSpan(
                  text: '* ',
                  style: TextStyle(
                    color: Colors.red,
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              TextSpan(
                text: label,
                style: const TextStyle(
                  color: Color(0xFF1E293B),
                  fontSize: 14,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        TextField(
          textAlign: TextAlign.right,
          textDirection: TextDirection.rtl,
          controller: controller,
          keyboardType: keyboardType,
          cursorColor: const Color(0xFF3B5BDB),
          style: const TextStyle(
            color: Color(0xFF1E293B),
            fontSize: 15,
            fontWeight: FontWeight.w500,
          ),
          decoration: InputDecoration(
            filled: true,
            fillColor: Colors.white,
            hintStyle: TextStyle(
              color: Colors.grey.shade400,
              fontSize: 14,
            ),
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(color: Colors.grey.shade300),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(color: Colors.grey.shade300),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: const BorderSide(
                color: Color(0xFF3B5BDB),
                width: 1.5,
              ),
            ),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 12,
            ),
          ),
        ),
      ],
    );
  }

  Widget _sheetButton(
    String text,
    Color bg,
    VoidCallback onTap, {
    Color textColor = Colors.white,
  }) {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton(
        onPressed: onTap,
        style: ElevatedButton.styleFrom(
          backgroundColor: bg,
          foregroundColor: textColor,
          elevation: 0,
          padding: const EdgeInsets.symmetric(vertical: 16),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
        child: Text(
          text,
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.bold,
            color: textColor,
          ),
        ),
      ),
    );
  }
}
