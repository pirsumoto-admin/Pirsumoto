import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:easy_localization/easy_localization.dart' hide TextDirection;
import '../../services/db_service.dart';
import '../auth/auth_provider.dart';
import 'preset_login_dialog.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  // Template images (up to 5)
  final List<String?> _templateImages = List.filled(5, null);

  // Benefits & Services
  final Set<String> _selectedWarranties = {};
  final Map<String, String> _warrantyDurations = {}; // option -> duration
  final Set<String> _selectedTreatments = {};
  final Set<String> _selectedServices = {};

  static const List<String> _warranties = [
    'על שלדה, מנוע וגיר',
    'מהיבואן',
    'מהסוכנות',
    'על הסוללה',
  ];

  static const List<String> _treatments = [
    'ספר טיפולים מלא',
    'טופל במוסך מורשה בלבד',
    'בדיקה מלאה',
    'תיקון ליקויים לאחר בדיקה',
  ];

  static const List<String> _services = [
    'טרייד אין עתידי',
    'אספקה מיידית',
    'אפשרויות מימון',
    'חבילת הטבות',
    'טסט לשנה',
  ];

  static const List<String> _durationOptions = [
    'לא הוגדר זמן',
    '3 חודשים',
    '6 חודשים',
    '9 חודשים',
    '12 חודשים',
    '18 חודשים',
    '24 חודשים',
    '30 חודשים',
    '36 חודשים',
  ];

  static const List<String> _batteryDurationOptions = [
    'לא הוגדר זמן',
    '1 שנה',
    '2 שנים',
    '3 שנים',
    '4 שנים',
    '5 שנים',
    '6 שנים',
    '7 שנים',
    '8 שנים',
  ];

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
    final user = ref.read(authStateProvider).value;
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

          // Load Benefits & Services
          _selectedWarranties.clear();
          if (settings['warranties'] != null) {
            _selectedWarranties.addAll(
              List<String>.from(settings['warranties']),
            );
          }

          _warrantyDurations.clear();
          if (settings['warrantyDurations'] != null) {
            final Map<String, dynamic> savedDurations =
                Map<String, dynamic>.from(settings['warrantyDurations']);
            savedDurations.forEach((k, v) {
              _warrantyDurations[k] = v.toString();
            });
          }

          _selectedTreatments.clear();
          if (settings['treatments'] != null) {
            _selectedTreatments.addAll(
              List<String>.from(settings['treatments']),
            );
          }

          _selectedServices.clear();
          if (settings['services'] != null) {
            _selectedServices.addAll(List<String>.from(settings['services']));
          }
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
      builder:
          (ctx) => Container(
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
                  const Color(0xFF5B7FFF),
                  () => Navigator.pop(ctx, ImageSource.gallery),
                ),
                const SizedBox(height: 12),
                _sheetButton(
                  'צילום תמונה',
                  const Color(0xFF5B7FFF),
                  () => Navigator.pop(ctx, ImageSource.camera),
                ),
                const SizedBox(height: 12),
                _sheetButton(
                  'ביטול',
                  const Color(0xFFF3F4F6),
                  () => Navigator.pop(ctx),
                  textColor: Colors.red,
                ),
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
    final user = ref.read(authStateProvider).value;
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
      'warranties': _selectedWarranties.toList(),
      'warrantyDurations': _warrantyDurations,
      'treatments': _selectedTreatments.toList(),
      'services': _selectedServices.toList(),
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
      body:
          _isLoading
              ? const Center(child: CircularProgressIndicator())
              : SingleChildScrollView(
                padding: const EdgeInsets.all(16.0),
                child: Column(
                  children: [
                    const SizedBox(height: 16),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          'bottom_nav.settings'.tr(),
                          style: const TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Icon(
                          Icons.settings,
                          color: Colors.grey.shade400,
                          size: 28,
                        ),
                      ],
                    ),
                    const SizedBox(height: 16),
                    _buildPresetLoginButton(),
                    const SizedBox(height: 20),
                    _buildBenefitsAndServicesCard(),
                    const SizedBox(height: 16),
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
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                        child:
                            _isSaving
                                ? const SizedBox(
                                  width: 20,
                                  height: 20,
                                  child: CircularProgressIndicator(
                                    color: Colors.white,
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
                    const SizedBox(height: 32),
                  ],
                ),
              ),
    );
  }

  String _trText(String key, {required String he, required String en}) {
    final isEn = context.locale.languageCode == 'en';
    final fallback = isEn ? en : he;
    final val = tr(key);
    if (val == key || val.isEmpty) return fallback;
    return val;
  }

  Widget _buildPresetLoginButton() {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xFF2B4C7E), Color(0xFF1E3A5F)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(12),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF1E3A5F).withValues(alpha: 0.25),
            blurRadius: 8,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => showPresetLoginDialog(context),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            child: Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.15),
                    shape: BoxShape.circle,
                  ),
                  child: const Icon(
                    Icons.lock_open_rounded,
                    color: Colors.white,
                    size: 22,
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        _trText(
                          'preset_login.button_title',
                          he: 'התחברות מראש לאתרים',
                          en: 'Preset Login to Websites',
                        ),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        _trText(
                          'preset_login.button_subtitle',
                          he: 'אימות שמירת עוגיות והתחברות לאוטומציה',
                          en: 'Validate saved login cookies for automation',
                        ),
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.85),
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                const Icon(
                  Icons.arrow_forward_ios_rounded,
                  color: Colors.white70,
                  size: 16,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBackgroundTemplateCard() {
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          const Text(
            'תבנית רקע לתמונות הרכב',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
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
                  child:
                      imgPath != null
                          ? Stack(
                            fit: StackFit.expand,
                            children: [
                              ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child: Image.file(
                                  File(imgPath),
                                  fit: BoxFit.cover,
                                ),
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
                                    child: const Icon(
                                      Icons.close,
                                      size: 10,
                                      color: Colors.white,
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          )
                          : Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              Icon(
                                Icons.camera_alt,
                                color: Colors.indigo.shade300,
                              ),
                              const SizedBox(height: 2),
                              Text(
                                '${5 - index}',
                                style: const TextStyle(
                                  fontSize: 12,
                                  color: Colors.grey,
                                ),
                              ),
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
          const Text(
            'אפשרויות פרסום',
            style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          ),
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
            Switch(
              value: enabled,
              onChanged: onToggle,
              activeThumbColor: Colors.blue,
            ),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(label, style: const TextStyle(fontSize: 14)),
                if (subLabel != null)
                  Text(
                    subLabel,
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                  ),
              ],
            ),
          ],
        ),
        if (enabled) ...[
          const SizedBox(height: 12),
          _inputField(controller: phoneController, hint: 'טלפון לחזרה'),
          const SizedBox(height: 12),
          _inputField(
            controller: descController,
            hint: 'תבנית לשימוש בתיאור הרכב',
            maxLines: 3,
          ),
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
            color: Colors.black.withValues(alpha: 0.05),
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
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 16,
          vertical: 12,
        ),
      ),
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
          elevation: 0,
          padding: const EdgeInsets.symmetric(vertical: 16),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
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

  Widget _buildBenefitsAndServicesCard() {
    return _card(
      child: Directionality(
        textDirection: TextDirection.rtl,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'הטבות ושירותים',
              style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 12),

            // אחריות
            const Text(
              'אחריות',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.bold,
                color: Colors.black87,
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children:
                  _warranties.map((option) {
                    final isSelected = _selectedWarranties.contains(option);
                    return _buildSelectionChip(
                      label: option,
                      isSelected: isSelected,
                      onTap: () {
                        setState(() {
                          if (isSelected) {
                            _selectedWarranties.remove(option);
                            _warrantyDurations.remove(option);
                          } else {
                            _selectedWarranties.add(option);
                            _warrantyDurations[option] = 'לא הוגדר זמן';
                          }
                        });
                      },
                    );
                  }).toList(),
            ),

            // Dynamic Dropdowns for Selected Warranties
            if (_selectedWarranties.isNotEmpty) ...[
              const SizedBox(height: 16),
              const Text(
                'לאחר בחירה ניתן יהיה להגדיר את משך האחריות',
                style: TextStyle(fontSize: 12, color: Colors.grey),
                textAlign: TextAlign.right,
              ),
              const SizedBox(height: 12),
              ..._warranties
                  .where((opt) => _selectedWarranties.contains(opt))
                  .map((option) {
                    final label =
                        option.startsWith('על')
                            ? 'אחריות ${option.substring(2).trim()}'
                            : 'אחריות $option';
                    final currentValue =
                        _warrantyDurations[option] ?? 'לא הוגדר זמן';
                    final isBattery = option == 'על הסוללה';
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 12.0),
                      child: _buildDropdownField(
                        label: label,
                        value: currentValue,
                        items:
                            isBattery
                                ? _batteryDurationOptions
                                : _durationOptions,
                        onChanged: (newVal) {
                          if (newVal != null) {
                            setState(() {
                              _warrantyDurations[option] = newVal;
                            });
                          }
                        },
                      ),
                    );
                  }),
            ],

            const Divider(height: 32),

            // טיפולים
            const Text(
              'טיפולים',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.bold,
                color: Colors.black87,
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children:
                  _treatments.map((option) {
                    final isSelected = _selectedTreatments.contains(option);
                    return _buildSelectionChip(
                      label: option,
                      isSelected: isSelected,
                      onTap: () {
                        setState(() {
                          if (isSelected) {
                            _selectedTreatments.remove(option);
                          } else {
                            _selectedTreatments.add(option);
                          }
                        });
                      },
                    );
                  }).toList(),
            ),

            const Divider(height: 32),

            // שירות
            const Text(
              'שירות',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.bold,
                color: Colors.black87,
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children:
                  _services.map((option) {
                    final isSelected = _selectedServices.contains(option);
                    return _buildSelectionChip(
                      label: option,
                      isSelected: isSelected,
                      onTap: () {
                        setState(() {
                          if (isSelected) {
                            _selectedServices.remove(option);
                          } else {
                            _selectedServices.add(option);
                          }
                        });
                      },
                    );
                  }).toList(),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildSelectionChip({
    required String label,
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isSelected ? const Color(0xFFFF5722) : Colors.grey.shade300,
            width: isSelected ? 1.5 : 1.0,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: isSelected ? const Color(0xFFFF5722) : Colors.black87,
            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
            fontSize: 14,
          ),
        ),
      ),
    );
  }

  Widget _buildDropdownField({
    required String label,
    required String value,
    required List<String> items,
    required ValueChanged<String?> onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: const TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.bold,
            color: Colors.black87,
          ),
        ),
        const SizedBox(height: 8),
        Theme(
          data: ThemeData.light().copyWith(
            inputDecorationTheme: InputDecorationTheme(
              filled: false,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 12,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide(color: Colors.grey.shade300),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide(color: Colors.grey.shade300),
              ),
            ),
          ),
          child: DropdownButtonFormField<String>(
            initialValue: value,
            alignment: AlignmentDirectional.centerStart,
            dropdownColor: Colors.white,
            isExpanded: true,
            icon: const Icon(Icons.arrow_drop_down, color: Colors.black54),
            items:
                items.map((val) {
                  return DropdownMenuItem<String>(
                    value: val,
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: Text(
                        val,
                        style: const TextStyle(
                          fontSize: 14,
                          color: Colors.black87,
                        ),
                      ),
                    ),
                  );
                }).toList(),
            onChanged: onChanged,
          ),
        ),
      ],
    );
  }
}
