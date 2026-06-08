import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
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

  final _picker = ImagePicker();

  @override
  void initState() {
    super.initState();
    _loadProfile();
  }

  Future<void> _loadProfile() async {
    // Load local profile image
    final dir = await getApplicationDocumentsDirectory();
    final imgFile = File('${dir.path}/profile_image.png');
    if (await imgFile.exists() && mounted) {
      setState(() => _profileImagePath = imgFile.path);
    }

    final user = ref.read(authStateProvider).valueOrNull;
    if (user != null) {
      final db = ref.read(dbServiceProvider);
      final profile = await db.getProfileData(user.uid);
      if (profile != null && mounted) {
        setState(() {
          _nameController.text = profile['name'] ?? '';
          _emailController.text = profile['email'] ?? '';
          _phoneController.text = profile['phone'] ?? '';
          _companyNumberController.text = profile['companyNumber'] ?? '';
          _selectedLanguage = profile['language'] ?? 'עברית';
        });
      }
    }
    if (mounted) setState(() => _isLoading = false);
  }

  Future<void> _pickProfileImage() async {
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      backgroundColor: Colors.transparent,
      builder: (ctx) => Container(
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
            _sheetButton('העלאה מגלריה', const Color(0xFF5B7FFF),
                () => Navigator.pop(ctx, ImageSource.gallery)),
            const SizedBox(height: 12),
            _sheetButton('צילום תמונה', const Color(0xFF5B7FFF),
                () => Navigator.pop(ctx, ImageSource.camera)),
            const SizedBox(height: 12),
            _sheetButton('ביטול', const Color(0xFFF3F4F6),
                () => Navigator.pop(ctx), textColor: Colors.red),
            const SizedBox(height: 16),
          ],
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
    final user = ref.read(authStateProvider).valueOrNull;
    if (user != null) {
      setState(() => _isSaving = true);
      final db = ref.read(dbServiceProvider);
      final success = await db.saveProfileData(user.uid, {
        'name': _nameController.text,
        'email': _emailController.text,
        'phone': _phoneController.text,
        'companyNumber': _companyNumberController.text,
        'language': _selectedLanguage,
        'profileImagePath': _profileImagePath ?? '',
      });
      if (mounted) {
        setState(() => _isSaving = false);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              success ? 'נשמר בהצלחה' : 'שגיאה בשמירה',
              textAlign: TextAlign.right,
            ),
          ),
        );
      }
    }
  }

  @override
  void dispose() {
    _nameController.dispose();
    _emailController.dispose();
    _phoneController.dispose();
    _companyNumberController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.white,
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(16.0),
              child: Column(
                children: [
                  const SizedBox(height: 16),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const Text(
                        'פרופיל',
                        style: TextStyle(
                            fontSize: 24, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(width: 8),
                      Icon(Icons.person,
                          color: Colors.grey.shade500, size: 28),
                    ],
                  ),
                  const SizedBox(height: 24),
                  _buildCompanyLogoCard(),
                  const SizedBox(height: 16),
                  _buildProfileDetailsCard(),
                  const SizedBox(height: 32),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: _isSaving ? null : _saveProfile,
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF3B5BDB),
                        padding: const EdgeInsets.symmetric(vertical: 16),
                        shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(8)),
                      ),
                      child: _isSaving
                          ? const SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                  color: Colors.white))
                          : const Text(
                              'שמירה',
                              style: TextStyle(
                                  fontSize: 16,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.white),
                            ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  ElevatedButton.icon(
                    onPressed: () {
                      ref
                          .read(authControllerProvider.notifier)
                          .signOut();
                    },
                    icon: const Icon(Icons.logout),
                    label: const Text('התנתק'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.white,
                      foregroundColor: Colors.red,
                      elevation: 0,
                      side: const BorderSide(color: Colors.red),
                    ),
                  ),
                ],
              ),
            ),
    );
  }

  Widget _buildCompanyLogoCard() {
    return Container(
      padding: const EdgeInsets.all(24),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade200),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          const Text(
            'לוגו חברה',
            style: TextStyle(
                color: Colors.black87,
                fontSize: 16,
                fontWeight: FontWeight.bold),
          ),
          const SizedBox(height: 24),
          Center(
            child: Stack(
              children: [
                GestureDetector(
                  onTap: _pickProfileImage,
                  child: Container(
                    width: 120,
                    height: 120,
                    decoration: const BoxDecoration(
                      color: Colors.black12,
                      shape: BoxShape.circle,
                    ),
                    child: ClipOval(
                      child: _profileImagePath != null
                          ? Image.file(File(_profileImagePath!),
                              fit: BoxFit.cover)
                          : const Icon(Icons.business,
                              color: Colors.grey, size: 50),
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
                        child: const Icon(Icons.close,
                            size: 16, color: Colors.white),
                      ),
                    ),
                  ),
                if (_profileImagePath == null)
                  Positioned(
                    bottom: 0,
                    right: 0,
                    child: GestureDetector(
                      onTap: _pickProfileImage,
                      child: Container(
                        width: 32,
                        height: 32,
                        decoration: const BoxDecoration(
                          color: Color(0xFF3B5BDB),
                          shape: BoxShape.circle,
                        ),
                        child: const Icon(Icons.camera_alt,
                            size: 18, color: Colors.white),
                      ),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          const Center(
            child: Text(
              'לחץ לשינוי תמונה',
              style: TextStyle(fontSize: 12, color: Colors.grey),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildProfileDetailsCard() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade200),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.05),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          const Text('פרטי פרופיל',
              style:
                  TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          const SizedBox(height: 24),
          _buildTextField('שם משתמש', _nameController, isRequired: true),
          const SizedBox(height: 16),
          _buildTextField('דוא״ל', _emailController, isRequired: true,
              keyboardType: TextInputType.emailAddress),
          const SizedBox(height: 16),
          _buildTextField('טלפון', _phoneController, isRequired: true,
              keyboardType: TextInputType.phone),
          const SizedBox(height: 16),
          _buildTextField('ח״פ (מספר חברה)', _companyNumberController,
              keyboardType: TextInputType.number),
          const SizedBox(height: 16),
          // Language selector
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              const Text(
                'שפה',
                style: TextStyle(
                    color: Colors.black87,
                    fontSize: 14,
                    fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
                decoration: BoxDecoration(
                  border: Border.all(color: Colors.grey.shade300),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    value: _selectedLanguage,
                    isExpanded: true,
                    alignment: Alignment.centerRight,
                    items: _languages
                        .map((lang) => DropdownMenuItem(
                              value: lang,
                              child: Text(lang,
                                  textAlign: TextAlign.right),
                            ))
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
          const SizedBox(height: 16),
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
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        RichText(
          text: TextSpan(
            children: [
              if (isRequired)
                const TextSpan(
                    text: '* ',
                    style: TextStyle(color: Colors.red, fontSize: 14)),
              TextSpan(
                text: label,
                style: const TextStyle(
                    color: Colors.black87,
                    fontSize: 14,
                    fontWeight: FontWeight.bold),
              ),
            ],
          ),
        ),
        const SizedBox(height: 8),
        TextField(
          textAlign: TextAlign.right,
          controller: controller,
          keyboardType: keyboardType,
          decoration: InputDecoration(
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(color: Colors.grey.shade300),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(color: Colors.grey.shade300),
            ),
            contentPadding:
                const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          ),
        ),
      ],
    );
  }

  Widget _sheetButton(String text, Color bg, VoidCallback onTap,
      {Color textColor = Colors.white}) {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton(
        onPressed: onTap,
        style: ElevatedButton.styleFrom(
          backgroundColor: bg,
          elevation: 0,
          padding: const EdgeInsets.symmetric(vertical: 16),
          shape:
              RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
        child: Text(text,
            style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: textColor)),
      ),
    );
  }
}
