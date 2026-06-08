import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import '../../services/db_service.dart';
import '../auth/auth_provider.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  // Template images (up to 5)
  final List<String?> _templateImages = List.filled(5, null);

  // Platform toggles
  bool _yad2Enabled = true;
  bool _fbAutoPostEnabled = false;
  bool _fbGroupXxxEnabled = false;
  bool _fbGroupYyyEnabled = false;
  bool _carWizEnabled = false;

  // Platform phone numbers
  final _yad2PhoneController = TextEditingController();
  final _fbAutoPostPhoneController = TextEditingController();
  final _fbGroupXxxPhoneController = TextEditingController();
  final _fbGroupYyyPhoneController = TextEditingController();
  final _carWizPhoneController = TextEditingController();

  // Platform description templates
  final _yad2DescController = TextEditingController();
  final _fbAutoPostDescController = TextEditingController();
  final _fbGroupXxxDescController = TextEditingController();
  final _fbGroupYyyDescController = TextEditingController();
  final _carWizDescController = TextEditingController();

  bool _isSaving = false;
  bool _isLoading = true;

  final _picker = ImagePicker();

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  Future<void> _loadSettings() async {
    final user = ref.read(authStateProvider).valueOrNull;
    if (user != null) {
      final db = ref.read(dbServiceProvider);
      final settings = await db.getSettingsData(user.uid);
      if (settings != null && mounted) {
        setState(() {
          _yad2Enabled = settings['yad2Enabled'] ?? true;
          _fbAutoPostEnabled = settings['fbAutoPostEnabled'] ?? false;
          _fbGroupXxxEnabled = settings['fbGroupXxxEnabled'] ?? false;
          _fbGroupYyyEnabled = settings['fbGroupYyyEnabled'] ?? false;
          _carWizEnabled = settings['carWizEnabled'] ?? false;

          _yad2PhoneController.text = settings['yad2Phone'] ?? '';
          _fbAutoPostPhoneController.text = settings['fbAutoPostPhone'] ?? '';
          _fbGroupXxxPhoneController.text = settings['fbGroupXxxPhone'] ?? '';
          _fbGroupYyyPhoneController.text = settings['fbGroupYyyPhone'] ?? '';
          _carWizPhoneController.text = settings['carWizPhone'] ?? '';

          _yad2DescController.text = settings['yad2Desc'] ?? '';
          _fbAutoPostDescController.text = settings['fbAutoPostDesc'] ?? '';
          _fbGroupXxxDescController.text = settings['fbGroupXxxDesc'] ?? '';
          _fbGroupYyyDescController.text = settings['fbGroupYyyDesc'] ?? '';
          _carWizDescController.text = settings['carWizDesc'] ?? '';
        });
      }
    }
    // Load template images from local storage
    await _loadTemplateImages();
    if (mounted) setState(() => _isLoading = false);
  }

  Future<void> _loadTemplateImages() async {
    final dir = await getApplicationDocumentsDirectory();
    for (int i = 0; i < 5; i++) {
      final file = File('${dir.path}/stage_template_${i + 1}.png');
      if (await file.exists() && mounted) {
        setState(() => _templateImages[i] = file.path);
      }
    }
  }

  Future<void> _pickTemplateImage(int index) async {
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
    final dest = '${dir.path}/stage_template_${index + 1}.png';
    await File(image.path).copy(dest);
    if (mounted) setState(() => _templateImages[index] = dest);
  }

  Future<void> _removeTemplateImage(int index) async {
    final path = _templateImages[index];
    if (path != null) {
      final file = File(path);
      if (await file.exists()) await file.delete();
    }
    if (mounted) setState(() => _templateImages[index] = null);
  }

  Future<void> _saveSettings() async {
    final user = ref.read(authStateProvider).valueOrNull;
    if (user == null) return;
    setState(() => _isSaving = true);

    final db = ref.read(dbServiceProvider);
    await db.saveSettingsData(user.uid, {
      'yad2Enabled': _yad2Enabled,
      'fbAutoPostEnabled': _fbAutoPostEnabled,
      'fbGroupXxxEnabled': _fbGroupXxxEnabled,
      'fbGroupYyyEnabled': _fbGroupYyyEnabled,
      'carWizEnabled': _carWizEnabled,
      'yad2Phone': _yad2PhoneController.text,
      'fbAutoPostPhone': _fbAutoPostPhoneController.text,
      'fbGroupXxxPhone': _fbGroupXxxPhoneController.text,
      'fbGroupYyyPhone': _fbGroupYyyPhoneController.text,
      'carWizPhone': _carWizPhoneController.text,
      'yad2Desc': _yad2DescController.text,
      'fbAutoPostDesc': _fbAutoPostDescController.text,
      'fbGroupXxxDesc': _fbGroupXxxDescController.text,
      'fbGroupYyyDesc': _fbGroupYyyDescController.text,
      'carWizDesc': _carWizDescController.text,
    });

    if (mounted) {
      setState(() => _isSaving = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('הגדרות נשמרו בהצלחה', textAlign: TextAlign.right),
          backgroundColor: Colors.green,
        ),
      );
    }
  }

  @override
  void dispose() {
    _yad2PhoneController.dispose();
    _fbAutoPostPhoneController.dispose();
    _fbGroupXxxPhoneController.dispose();
    _fbGroupYyyPhoneController.dispose();
    _carWizPhoneController.dispose();
    _yad2DescController.dispose();
    _fbAutoPostDescController.dispose();
    _fbGroupXxxDescController.dispose();
    _fbGroupYyyDescController.dispose();
    _carWizDescController.dispose();
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
                        'הגדרות',
                        style: TextStyle(
                            fontSize: 24, fontWeight: FontWeight.bold),
                      ),
                      const SizedBox(width: 8),
                      Icon(Icons.settings,
                          color: Colors.grey.shade400, size: 28),
                    ],
                  ),
                  const SizedBox(height: 24),
                  _buildBackgroundTemplateCard(),
                  const SizedBox(height: 16),
                  _buildPublishOptionsCard(),
                  const SizedBox(height: 24),
                  SizedBox(
                    width: double.infinity,
                    child: ElevatedButton(
                      onPressed: _isSaving ? null : _saveSettings,
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
                  const SizedBox(height: 32),
                ],
              ),
            ),
    );
  }

  Widget _buildBackgroundTemplateCard() {
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          const Text('תבנית רקע לתמונות הרכב',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          const Text(
            'העלה תמונות שישמשו כתבניות קבועות לפרסומים שלך',
            style: TextStyle(fontSize: 14, color: Colors.grey),
            textAlign: TextAlign.right,
          ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: List.generate(5, (index) {
              final imgPath = _templateImages[index];
              return GestureDetector(
                onTap: () => _pickTemplateImage(index),
                child: Container(
                  margin: const EdgeInsets.only(left: 8),
                  width: 60,
                  height: 60,
                  decoration: BoxDecoration(
                    color: Colors.grey.shade50,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.grey.shade300),
                  ),
                  child: imgPath != null
                      ? Stack(
                          fit: StackFit.expand,
                          children: [
                            ClipRRect(
                              borderRadius: BorderRadius.circular(8),
                              child: Image.file(File(imgPath),
                                  fit: BoxFit.cover),
                            ),
                            Positioned(
                              top: 2,
                              right: 2,
                              child: GestureDetector(
                                onTap: () => _removeTemplateImage(index),
                                child: Container(
                                  padding: const EdgeInsets.all(2),
                                  decoration: const BoxDecoration(
                                    color: Colors.red,
                                    shape: BoxShape.circle,
                                  ),
                                  child: const Icon(Icons.close,
                                      size: 10, color: Colors.white),
                                ),
                              ),
                            ),
                          ],
                        )
                      : Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.camera_alt,
                                color: Colors.indigo.shade300),
                            const SizedBox(height: 2),
                            Text('${5 - index}',
                                style: const TextStyle(
                                    fontSize: 12, color: Colors.grey)),
                          ],
                        ),
                ),
              );
            }),
          ),
        ],
      ),
    );
  }

  Widget _buildPublishOptionsCard() {
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          const Text('אפשרויות פרסום',
              style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold)),
          const SizedBox(height: 8),
          const Text(
            'בחר לאילו פלטפורמות לפרסם את המודעות שלך',
            style: TextStyle(fontSize: 14, color: Colors.grey),
            textAlign: TextAlign.right,
          ),
          const SizedBox(height: 24),
          _buildPlatformSection(
            label: 'Yad2',
            subLabel: '(ברירת מחדל)',
            enabled: _yad2Enabled,
            onToggle: (v) => setState(() => _yad2Enabled = v),
            phoneController: _yad2PhoneController,
            descController: _yad2DescController,
          ),
          const Divider(height: 32),
          _buildPlatformSection(
            label: 'Facebook AutoPost Group',
            enabled: _fbAutoPostEnabled,
            onToggle: (v) => setState(() => _fbAutoPostEnabled = v),
            phoneController: _fbAutoPostPhoneController,
            descController: _fbAutoPostDescController,
          ),
          const Divider(height: 32),
          _buildPlatformSection(
            label: 'Facebook קבוצה א\'',
            enabled: _fbGroupXxxEnabled,
            onToggle: (v) => setState(() => _fbGroupXxxEnabled = v),
            phoneController: _fbGroupXxxPhoneController,
            descController: _fbGroupXxxDescController,
          ),
          const Divider(height: 32),
          _buildPlatformSection(
            label: 'Facebook קבוצה ב\'',
            enabled: _fbGroupYyyEnabled,
            onToggle: (v) => setState(() => _fbGroupYyyEnabled = v),
            phoneController: _fbGroupYyyPhoneController,
            descController: _fbGroupYyyDescController,
          ),
          const Divider(height: 32),
          _buildPlatformSection(
            label: 'CarWiz',
            enabled: _carWizEnabled,
            onToggle: (v) => setState(() => _carWizEnabled = v),
            phoneController: _carWizPhoneController,
            descController: _carWizDescController,
          ),
        ],
      ),
    );
  }

  Widget _buildPlatformSection({
    required String label,
    String? subLabel,
    required bool enabled,
    required ValueChanged<bool> onToggle,
    required TextEditingController phoneController,
    required TextEditingController descController,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Switch(value: enabled, onChanged: onToggle,
                activeThumbColor: Colors.blue),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(label, style: const TextStyle(fontSize: 14)),
                if (subLabel != null)
                  Text(subLabel,
                      style:
                          const TextStyle(fontSize: 12, color: Colors.grey)),
              ],
            ),
          ],
        ),
        if (enabled) ...[
          const SizedBox(height: 12),
          _inputField(
              controller: phoneController, hint: 'טלפון לחזרה'),
          const SizedBox(height: 12),
          _inputField(
              controller: descController,
              hint: 'תבנית לשימוש בתיאור הרכב',
              maxLines: 3),
        ],
      ],
    );
  }

  Widget _card({required Widget child}) {
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
      child: child,
    );
  }

  Widget _inputField({
    required TextEditingController controller,
    required String hint,
    int maxLines = 1,
  }) {
    return TextField(
      controller: controller,
      textAlign: TextAlign.right,
      maxLines: maxLines,
      decoration: InputDecoration(
        hintText: hint,
        hintStyle: TextStyle(color: Colors.grey.shade400),
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
