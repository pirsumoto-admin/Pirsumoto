import 'dart:async';
import 'dart:io';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path_provider/path_provider.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  // Template images (up to 5)
  final List<String?> _templateImages = List.filled(5, null);

  // Benefits & Services
  final Set<String> _selectedWarranties = {};
  final Map<String, String> _warrantyDurations = {}; // option -> duration
  final Set<String> _selectedTreatments = {};
  final Set<String> _selectedServices = {};

  bool _isBenefitsExpanded = false;

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

  // Platform description templates
  final _yad2DescController = TextEditingController();
  final _fbAutoPostDescController = TextEditingController();
  final _fbGroupXxxDescController = TextEditingController();
  final _fbGroupYyyDescController = TextEditingController();
  final _carWizDescController = TextEditingController();

  bool _isSaving = false;
  bool _isLoading = true;
  StreamSubscription<DocumentSnapshot>? _settingsSubscription;

  final _picker = ImagePicker();

  @override
  void initState() {
    super.initState();
    _loadSettings();
  }

  String? get _currentUserId {
    return FirebaseAuth.instance.currentUser?.uid;
  }

  Future<void> _loadSettings() async {
    final userId = _currentUserId;
    if (userId != null && userId.isNotEmpty) {
      _settingsSubscription = FirebaseFirestore.instance
          .collection('users')
          .doc(userId)
          .snapshots()
          .listen((doc) {
        if (mounted) {
          final settings = doc.exists ? (doc.data()?['settings'] as Map<String, dynamic>?) : null;
          if (settings != null) {
            setState(() {
              if (!_isSaving) { // Avoid overwriting while typing/saving locally
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
              }
            });
          }
          if (_isLoading) {
            setState(() => _isLoading = false);
          }
        }
      }, onError: (e) {
        debugPrint('[SettingsScreen] Error listening to settings: $e');
        if (mounted) setState(() => _isLoading = false);
      });
    } else {
      if (mounted) setState(() => _isLoading = false);
    }
    // Load template images from local storage
    await _loadTemplateImages();
  }

  Future<void> _loadTemplateImages() async {
    try {
      final dir = await getApplicationDocumentsDirectory();
      for (int i = 0; i < 5; i++) {
        final file = File('${dir.path}/stage_template_${i + 1}.png');
        if (await file.exists() && mounted) {
          setState(() => _templateImages[i] = file.path);
        }
      }
    } catch (e) {
      debugPrint('[SettingsScreen] Error loading template images: $e');
    }
  }

  Future<void> _pickTemplateImage(int index) async {
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
    final userId = _currentUserId;
    if (userId == null || userId.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('שגיאה: משתמש לא מחובר', textAlign: TextAlign.right),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    setState(() => _isSaving = true);

    try {
      await FirebaseFirestore.instance.collection('users').doc(userId).set({
        'settings': {
          'yad2Desc': _yad2DescController.text.trim(),
          'fbAutoPostDesc': _fbAutoPostDescController.text.trim(),
          'fbGroupXxxDesc': _fbGroupXxxDescController.text.trim(),
          'fbGroupYyyDesc': _fbGroupYyyDescController.text.trim(),
          'carWizDesc': _carWizDescController.text.trim(),
          'warranties': _selectedWarranties.toList(),
          'warrantyDurations': _warrantyDurations,
          'treatments': _selectedTreatments.toList(),
          'services': _selectedServices.toList(),
          'updatedAt': DateTime.now().toIso8601String(),
        }
      }, SetOptions(merge: true));

      if (mounted) {
        setState(() => _isSaving = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'ההגדרות נשמרו בהצלחה',
              textAlign: TextAlign.right,
            ),
            backgroundColor: Colors.green,
          ),
        );
      }
    } catch(e) {
      if (mounted) {
        setState(() => _isSaving = false);
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'שגיאה בשמירת ההגדרות',
              textAlign: TextAlign.right,
            ),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  @override
  void dispose() {
    _settingsSubscription?.cancel();
    _yad2DescController.dispose();
    _fbAutoPostDescController.dispose();
    _fbGroupXxxDescController.dispose();
    _fbGroupYyyDescController.dispose();
    _carWizDescController.dispose();
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
                padding: const EdgeInsets.symmetric(
                  horizontal: 16.0,
                  vertical: 20.0,
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    const SizedBox(height: 32),
                    Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Text(
                          'הגדרות',
                          style: TextStyle(
                            fontSize: 24,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFF1E293B),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Icon(
                          Icons.settings_rounded,
                          color: Colors.grey.shade600,
                          size: 28,
                        ),
                      ],
                    ),
                    const SizedBox(height: 24),
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
                    const SizedBox(height: 32),
                  ],
                ),
              ),
      ),
    );
  }

  Widget _buildBenefitsAndServicesCard() {
    return _card(
      child: Theme(
        data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
        child: ExpansionTile(
          initiallyExpanded: _isBenefitsExpanded,
          onExpansionChanged: (expanded) {
            setState(() {
              _isBenefitsExpanded = expanded;
            });
          },
          tilePadding: EdgeInsets.zero,
          title: const Text(
            'הטבות ושירותים',
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.bold,
              color: Color(0xFF1E293B),
            ),
          ),
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const SizedBox(height: 14),
                // אחריות
                const Text(
                  'אחריות',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF1E293B),
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: _warranties.map((option) {
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
                  const SizedBox(height: 14),
                  Text(
                    'לאחר בחירה ניתן להגדיר את משך האחריות:',
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade600),
                  ),
                  const SizedBox(height: 10),
                  ..._warranties
                      .where((opt) => _selectedWarranties.contains(opt))
                      .map((option) {
                    final label = option.startsWith('על')
                        ? 'אחריות ${option.substring(2).trim()}'
                        : 'אחריות $option';
                    final currentValue =
                        _warrantyDurations[option] ?? 'לא הוגדר זמן';
                    final isBattery = option == 'על הסוללה';
                    return Padding(
                      padding: const EdgeInsets.only(bottom: 10.0),
                      child: _buildDropdownField(
                        label: label,
                        value: currentValue,
                        items: isBattery
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

                const Divider(height: 28),

                // טיפולים
                const Text(
                  'טיפולים',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF1E293B),
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: _treatments.map((option) {
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

                const Divider(height: 28),

                // שירות
                const Text(
                  'שירות',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF1E293B),
                  ),
                ),
                const SizedBox(height: 8),
                Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: _services.map((option) {
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
            )
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
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: isSelected ? const Color(0xFFEEF2FF) : Colors.white,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isSelected ? const Color(0xFF3B5BDB) : Colors.grey.shade300,
            width: isSelected ? 1.5 : 1.0,
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: isSelected ? const Color(0xFF3B5BDB) : const Color(0xFF1E293B),
            fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
            fontSize: 13,
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
            fontSize: 13,
            fontWeight: FontWeight.bold,
            color: Color(0xFF1E293B),
          ),
        ),
        const SizedBox(height: 6),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
          decoration: BoxDecoration(
            color: Colors.white,
            border: Border.all(color: Colors.grey.shade300),
            borderRadius: BorderRadius.circular(8),
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              value: items.contains(value) ? value : items.first,
              dropdownColor: Colors.white,
              isExpanded: true,
              alignment: AlignmentDirectional.centerStart,
              icon: const Icon(
                Icons.arrow_drop_down,
                color: Color(0xFF64748B),
              ),
              items: items.map((val) {
                return DropdownMenuItem<String>(
                  value: val,
                  child: Align(
                    alignment: AlignmentDirectional.centerStart,
                    child: Text(
                      val,
                      style: const TextStyle(
                        fontSize: 14,
                        color: Color(0xFF1E293B),
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                );
              }).toList(),
              onChanged: onChanged,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildBackgroundTemplateCard() {
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'תבנית רקע לתמונות הרכב',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: Color(0xFF1E293B),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'העלה תמונות שישמשו כתבניות קבועות לפרסומים שלך',
            style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
          ),
          const SizedBox(height: 16),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.start,
              children: List.generate(5, (index) {
                final imgPath = _templateImages[index];
                return GestureDetector(
                  onTap: () => _pickTemplateImage(index),
                  child: Container(
                    margin: const EdgeInsets.only(left: 8),
                    width: 58,
                    height: 58,
                    decoration: BoxDecoration(
                      color: const Color(0xFFF8FAFC),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(color: Colors.grey.shade300),
                    ),
                    child: imgPath != null
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
                                      size: 12,
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
                                Icons.camera_alt_rounded,
                                color: const Color(0xFF3B5BDB).withOpacity(0.7),
                                size: 22,
                              ),
                              const SizedBox(height: 2),
                              Text(
                                '${index + 1}',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.grey.shade500,
                                ),
                              ),
                            ],
                          ),
                  ),
                );
              }),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPublishOptionsCard() {
    return _card(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'אפשרויות פרסום',
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.bold,
              color: Color(0xFF1E293B),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'תבנית לשימוש בתיאור הרכב',
            style: TextStyle(fontSize: 13, color: Colors.grey.shade600),
          ),
          const SizedBox(height: 20),
          _inputField(
            controller: _yad2DescController,
            hint: 'הזן תבנית טקסט לתיאור הרכב',
            maxLines: 3,
          ),
        ],
      ),
    );
  }

  Widget _card({required Widget child}) {
    return Container(
      padding: const EdgeInsets.all(18),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.grey.shade200),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withOpacity(0.04),
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
      textDirection: TextDirection.rtl,
      maxLines: maxLines,
      cursorColor: const Color(0xFF3B5BDB),
      style: const TextStyle(
        color: Color(0xFF1E293B),
        fontSize: 14,
        fontWeight: FontWeight.w500,
      ),
      decoration: InputDecoration(
        filled: true,
        fillColor: Colors.white,
        hintText: hint,
        hintStyle: TextStyle(
          color: Colors.grey.shade400,
          fontSize: 13,
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
          horizontal: 14,
          vertical: 11,
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
