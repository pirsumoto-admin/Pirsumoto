import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'dart:typed_data';
import 'package:easy_localization/easy_localization.dart' hide TextDirection;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import '../form/form_provider.dart' as fp;
import '../../services/db_service.dart';
import '../../services/audio_service.dart';
import '../../services/vehicle_data_service.dart';
import '../auth/auth_provider.dart';
import '../listings/listings_screen.dart';
import '../profile/profile_screen.dart';
import '../settings/settings_screen.dart';
import '../publish/yad2_screen.dart';
import '../../services/yad2_automation_service.dart';
// import 'package:flutter_gemma/flutter_gemma.dart';
// import '../../services/gemma_service.dart';

// ---------------------------------------------------------------------------
// Home shell – bottom nav + top tabs
// ---------------------------------------------------------------------------
class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  // 0=Add  1=Listings  2=Profile  3=Settings
  // In RTL the first item appears on the RIGHT → Add is the primary right-side action
  int _currentIndex = 0;
  final GlobalKey _screenshotKey = GlobalKey();

  void _editListing(Map<String, dynamic> listing) {
    ref.read(fp.formControllerProvider.notifier).loadFromListing(listing);
    setState(() => _currentIndex = 0);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // _checkGemmaModel();
    });
  }

  Future<void> _checkGemmaModel() async {
    /*
    if (kIsWeb) return;
    try {
      final isInstalled = await FlutterGemma.isModelInstalled(
        'gemma-4-E4B-it.litertlm',
      );
      if (!isInstalled && mounted) {
        showDialog(
          context: context,
          barrierDismissible: false,
          builder: (context) => const _GemmaDownloadDialog(),
        );
      }
    } catch (e) {
      debugPrint('Error checking Gemma model: $e');
    }
    */
  }

  Future<void> _takeScreenshotAndAnalyze() async {
    /*
    try {
      // 1. Capture screenshot FIRST (before dirtying the tree with a dialog)
      final boundary =
          _screenshotKey.currentContext?.findRenderObject()
              as RenderRepaintBoundary?;
      if (boundary == null) return;

      // If it still needs a paint, we wait for the next frame (though capturing before dialog avoids this usually)
      if (boundary.debugNeedsPaint) {
        await Future.delayed(const Duration(milliseconds: 20));
      }

      // Dynamically calculate pixelRatio so the max dimension is ~896px.
      // This prevents the image from having too many patches, reducing
      // the prefill time from 30 seconds down to ~2 seconds, and prevents SIGSEGV.
      final double width = boundary.size.width;
      final double height = boundary.size.height;
      final double maxDimension = width > height ? width : height;
      double targetRatio = 896.0 / maxDimension;
      if (targetRatio > 2.0) targetRatio = 2.0;

      final ui.Image image = await boundary.toImage(pixelRatio: targetRatio);
      final ByteData? byteData = await image.toByteData(
        format: ui.ImageByteFormat.png,
      );
      final Uint8List pngBytes = byteData!.buffer.asUint8List();

      // 2. Show loading dialog
      if (!mounted) return;
      showDialog(
        context: context,
        barrierDismissible: false,
        builder: (ctx) => const Center(child: CircularProgressIndicator()),
      );

      // 3. Send to Gemma
      final result = await GemmaService().askGemmaAboutImage(
        pngBytes,
        "What text is visible in this image? Please list it clearly.",
      );

      // 4. Close loading and show result
      if (mounted) {
        Navigator.of(context).pop(); // close loading dialog
        showDialog(
          context: context,
          builder:
              (ctx) => AlertDialog(
                title: const Text(
                  'תוצאת הניתוח (Gemma)',
                  textAlign: TextAlign.right,
                ),
                content: SingleChildScrollView(
                  child: Text(
                    result ?? 'לא זוהה טקסט / שגיאה',
                    textAlign: TextAlign.right,
                  ),
                ),
                actions: [
                  TextButton(
                    onPressed: () => Navigator.of(ctx).pop(),
                    child: const Text('סגור'),
                  ),
                ],
              ),
        );
      }
    } catch (e) {
      if (mounted) {
        // Try to pop loading if it's up, but since we didn't track if it's up, this is risky.
        // It's just a test function, so it's fine.
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Error: $e')));
      }
    }
    */
  }

  @override
  Widget build(BuildContext context) {
    final screens = [
      const _HomeFormTab(), // 0 – Add
      ListingsScreen(onEditListing: _editListing), // 1 – Listings
      const ProfileScreen(), // 2 – Profile
      const SettingsScreen(), // 3 – Settings
    ];

    final bottomNav = BottomNavigationBar(
      type: BottomNavigationBarType.fixed,
      backgroundColor: Colors.white,
      selectedItemColor: const Color(0xFF3B5BDB),
      unselectedItemColor: Colors.grey,
      elevation: 0,
      currentIndex: _currentIndex,
      onTap: (i) => setState(() => _currentIndex = i),
      // In RTL: item[0] → far RIGHT, item[3] → far LEFT
      items: [
        BottomNavigationBarItem(
          icon: const Icon(Icons.add, size: 28),
          label: 'bottom_nav.add'.tr(),
        ),
        BottomNavigationBarItem(
          icon: const Icon(Icons.list_alt),
          label: 'bottom_nav.listings'.tr(),
        ),
        BottomNavigationBarItem(
          icon: const Icon(Icons.person),
          label: 'bottom_nav.profile'.tr(),
        ),
        BottomNavigationBarItem(
          icon: const Icon(Icons.settings),
          label: 'bottom_nav.settings'.tr(),
        ),
      ],
    );

    return RepaintBoundary(
      key: _screenshotKey,
      child: Scaffold(
        backgroundColor: Colors.white,
        body: Column(
          children: [
            _buildGlobalTopTabs(),
            Expanded(
              child: IndexedStack(index: _currentIndex, children: screens),
            ),
          ],
        ),
        /*
        floatingActionButton: FloatingActionButton(
          onPressed: _takeScreenshotAndAnalyze,
          backgroundColor: const Color(0xFF3B5BDB),
          child: const Icon(Icons.document_scanner, color: Colors.white),
          tooltip: 'נתח מסך עם Gemma',
        ),
        */
        bottomNavigationBar: Container(
          decoration: const BoxDecoration(
            border: Border(top: BorderSide(color: Color(0xFFEEEEEE), width: 1)),
          ),
          child: bottomNav,
        ),
      ),
    );
  }

  Widget _buildGlobalTopTabs() {
    final isHome = _currentIndex == 0;
    final isListings = _currentIndex == 1;

    return Container(
      decoration: const BoxDecoration(
        color: Colors.white,
        border: Border(bottom: BorderSide(color: Color(0xFFEEEEEE), width: 1)),
      ),
      child: SafeArea(
        bottom: false,
        child: Row(
          // In RTL: first child (הוספת רכב) appears on RIGHT, second on LEFT
          children: [
            Expanded(
              child: GestureDetector(
                onTap: () => setState(() => _currentIndex = 0),
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  decoration: BoxDecoration(
                    border: Border(
                      bottom: BorderSide(
                        color:
                            isHome
                                ? const Color(0xFF3B5BDB)
                                : Colors.transparent,
                        width: 2,
                      ),
                    ),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    'הוספת רכב',
                    style: TextStyle(
                      color: isHome ? const Color(0xFF3B5BDB) : Colors.grey,
                      fontSize: 16,
                      fontWeight: isHome ? FontWeight.bold : FontWeight.w500,
                    ),
                  ),
                ),
              ),
            ),
            Expanded(
              child: GestureDetector(
                onTap: () => setState(() => _currentIndex = 1),
                child: Container(
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  decoration: BoxDecoration(
                    border: Border(
                      bottom: BorderSide(
                        color:
                            isListings
                                ? const Color(0xFF3B5BDB)
                                : Colors.transparent,
                        width: 2,
                      ),
                    ),
                  ),
                  alignment: Alignment.center,
                  child: Text(
                    'מודעות שלי',
                    style: TextStyle(
                      color: isListings ? const Color(0xFF3B5BDB) : Colors.grey,
                      fontSize: 16,
                      fontWeight:
                          isListings ? FontWeight.bold : FontWeight.w500,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Add-car form tab
// ---------------------------------------------------------------------------
class _HomeFormTab extends ConsumerStatefulWidget {
  const _HomeFormTab();

  @override
  ConsumerState<_HomeFormTab> createState() => _HomeFormTabState();
}

class _HomeFormTabState extends ConsumerState<_HomeFormTab> {
  final _licenseController = TextEditingController();
  final _colorController = TextEditingController();
  final List<String> _colors = [
    'אדום',
    'כחול',
    'צהוב',
    'אפור',
    'לבן',
    'שחור',
    'סגול',
    'ורוד',
    'חום',
    'ירוק',
    'כתום',
  ];
  final _monthController = TextEditingController();
  final _testMonthController = TextEditingController();
  final _testYearController = TextEditingController();
  final _handController = TextEditingController();
  final _ownershipController = TextEditingController();
  final _prevOwnershipController = TextEditingController();
  final _kmController = TextEditingController();
  final _priceController = TextEditingController();
  final _handicappedController = ValueNotifier<bool>(false);
  final _noTestController = ValueNotifier<bool>(false);

  final List<String> _months = List.generate(12, (i) => (i + 1).toString());
  final List<String> _years = List.generate(
    2030 - 1990 + 1,
    (i) => (1990 + i).toString(),
  );
  final List<String> _hands = [
    'יד ראשונה',
    'יד שנייה',
    'יד שלישית',
    'יד רביעית',
    'יד חמישית',
    'יד שישית',
    'יד שביעית',
    'יד שמינית',
    'יד תשיעית',
    'יד עשירית',
  ];
  final List<String> _ownerships = [
    'פרטית',
    'חברה',
    'השכרה',
    'ליסינג',
    'מונית',
    'לימוד נהיגה',
    'ייבוא אישי',
    'ייבוא מקביל',
    'ממשלתי',
    'או״ם',
    'השכרה / החכר',
  ];
  final List<String> _yesNo = ['לא', 'כן'];

  final ImagePicker _picker = ImagePicker();

  /// Tracks whether the user has explicitly chosen an input mode
  bool _modeSelected = false;
  bool _isPublishing = false;
  bool _isFetchingVehicle = false;
  bool _useGemmaAutomation = true; // Use Gemma Automation for testing

  @override
  void initState() {
    super.initState();
    _testMonthController.text = DateTime.now().month.toString();
    _testYearController.text = (DateTime.now().year + 1).toString();
    _handicappedController.value = false;
    _noTestController.value = false;
  }

  @override
  void dispose() {
    _licenseController.dispose();
    _colorController.dispose();
    _monthController.dispose();
    _testMonthController.dispose();
    _testYearController.dispose();
    _handController.dispose();
    _ownershipController.dispose();
    _prevOwnershipController.dispose();
    _kmController.dispose();
    _priceController.dispose();
    _handicappedController.dispose();
    _noTestController.dispose();
    super.dispose();
  }

  // ── Controller sync ───────────────────────────────────────────────────────

  void _syncControllers(fp.FormState s) {
    _licenseController.text = s.license;
    _monthController.text = s.month;
    if (s.test.contains(',')) {
      final parts = s.test.split(',');
      if (parts.length == 2) {
        _testMonthController.text = parts[0];
        _testYearController.text = parts[1];
      }
    }
    _handController.text = s.hand;
    _ownershipController.text = s.ownership;
    _prevOwnershipController.text = s.prevOwnership;
    _kmController.text = s.km;
    _priceController.text = s.price;
    _handicappedController.value = s.handicapped == 'כן';
  }

  void _syncControllersFromAIData(Map<String, dynamic> data) {
    if (data['license'] != null) {
      _licenseController.text = data['license'].toString();
    }
    if (data['color'] != null) {
      _colorController.text = data['color'].toString();
    }
    if (data['month'] != null) {
      _monthController.text = data['month'].toString();
    }
    if (data['test'] != null) {
      final testStr = data['test'].toString();
      if (testStr.contains(',')) {
        final parts = testStr.split(',');
        if (parts.length == 2) {
          _testMonthController.text = parts[0];
          _testYearController.text = parts[1];
        }
      }
    }
    if (data['hand'] != null) {
      _handController.text = data['hand'].toString();
    }
    if (data['ownership'] != null) {
      _ownershipController.text = data['ownership'].toString();
    }
    if (data['prevOwnership'] != null) {
      _prevOwnershipController.text = data['prevOwnership'].toString();
    }
    if (data['km'] != null) {
      _kmController.text = data['km'].toString();
    }
    if (data['price'] != null) {
      _priceController.text = data['price'].toString();
    }
    if (data['handicapped'] != null) {
      _handicappedController.value = data['handicapped'].toString() == 'כן';
    }
  }

  // ── License plate lookup ──────────────────────────────────────────────────

  Future<void> _onLicenseSubmitted(
    String license,
    fp.FormController notifier,
  ) async {
    if (license.length < 7) return;
    setState(() => _isFetchingVehicle = true);
    final data = await VehicleDataService.fetchVehicleData(license);
    if (data != null && mounted) {
      notifier.updateField('maker', data['maker'] ?? '');
      notifier.updateField('model', data['model'] ?? '');
      notifier.updateField('year', data['year'] ?? '');
      notifier.updateField('ownership', data['ownership'] ?? '');
      if ((data['testExpiry'] ?? '').isNotEmpty) {
        final testExpiry = data['testExpiry']!;
        notifier.updateField('test', testExpiry);
        if (testExpiry.contains(',')) {
          final parts = testExpiry.split(',');
          if (parts.length == 2) {
            _testMonthController.text = parts[0];
            _testYearController.text = parts[1];
          }
        }
      }
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            'נמצא: ${data['maker']} ${data['model']} ${data['year']}',
            textAlign: TextAlign.right,
          ),
          backgroundColor: Colors.green,
          duration: const Duration(seconds: 2),
        ),
      );
    }
    if (mounted) setState(() => _isFetchingVehicle = false);
  }

  // ── Image picker ──────────────────────────────────────────────────────────

  Future<void> _pickImage(ImageSource source) async {
    try {
      final XFile? img = await _picker.pickImage(source: source);
      if (img != null) {
        ref.read(fp.formControllerProvider.notifier).addImage(img.path);
      }
    } catch (e) {
      debugPrint('Error picking image: $e');
    }
  }

  // ── Recording flow ────────────────────────────────────────────────────────

  Future<void> _onRecordTapped() async {
    if (!mounted) return;

    final audioService = ref.read(audioServiceProvider);

    // Push the full-screen recording UI
    final didStop = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => _RecordingScreen(audioService: audioService),
      ),
    );

    final notifier = ref.read(fp.formControllerProvider.notifier);
    notifier.setRecording(false);

    // Always stop the audio capture on return
    final path = await audioService.stopRecording();

    if (didStop == true && mounted) {
      setState(() => _modeSelected = true);
      notifier.setProcessing(true);

      if (path != null) {
        final data = await audioService.processAudio(path);
        if (data != null && mounted) {
          notifier.updateFromAI(data); // also sets isTypingMode = true
          _syncControllersFromAIData(data);
        }
      } else {
        // Recording failed – fall back to empty typing mode
        notifier.updateFromAI({});
      }

      if (mounted) notifier.setProcessing(false);
    }
    // If cancelled: recording stopped, _modeSelected stays false → no card highlighted
  }

  // ── Publish ───────────────────────────────────────────────────────────────

  Future<void> _publishListing() async {
    final formState = ref.read(fp.formControllerProvider);
    final user = ref.read(authStateProvider).valueOrNull;

    if (user == null || _licenseController.text.length < 7) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'נא להזין מספר רישוי מינימום 7 ספרות',
            textAlign: TextAlign.right,
          ),
        ),
      );
      return;
    }

    setState(() => _isPublishing = true);

    final listingData = {
      'license': _licenseController.text,
      'color': _colorController.text,
      'maker': formState.maker,
      'model': formState.model,
      'year': formState.year,
      'month': _monthController.text,
      'test': '${_testMonthController.text},${_testYearController.text}',
      'hand': _handController.text,
      'ownership': _ownershipController.text,
      'prevOwnership': _prevOwnershipController.text,
      'km': _kmController.text,
      'price': _priceController.text,
      'handicapped': _handicappedController.value ? 'כן' : 'לא',
      'noTest': _noTestController.value,
      'description': formState.description,
      'images': formState.images.map((p) => {'url': p}).toList(),
    };

    final db = ref.read(dbServiceProvider);
    final success = await db.saveUserListing(listingData, user.uid);
    setState(() => _isPublishing = false);

    if (!mounted) return;

    if (!success) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('שגיאה בפרסום המודעה', textAlign: TextAlign.right),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    // Navigate to Yad2 automation
    final publishData = VehiclePublishData(
      licenseNumber: _licenseController.text,
      color: _colorController.text,
      shade: _colorController.text,
      hand: _handController.text,
      currentOwnership: _ownershipController.text,
      previousOwnership: _prevOwnershipController.text,
      kilometers: _kmController.text,
      month: _monthController.text,
      price: _priceController.text,
      handicapped: _handicappedController.value,
      noTest: _noTestController.value,
      images: formState.images,
    );

    Navigator.of(context).push(
      MaterialPageRoute(
        builder:
            (_) => Yad2Screen(
              publishData: publishData,
              useGemmaAutomation: _useGemmaAutomation,
            ),
      ),
    );
  }

  void _fillTestData() {
    _licenseController.text = '79674102';
    _colorController.text = 'כחול';
    _monthController.text = '11';
    _handController.text = 'יד שנייה';
    _ownershipController.text = 'פרטית';
    _prevOwnershipController.text = 'חברה';
    _kmController.text = '50000';
    _priceController.text = '80000';
    _testMonthController.text = '11';
    _testYearController.text = '2027';
    _handicappedController.value = false;
    _noTestController.value = false;

    ref.read(fp.formControllerProvider.notifier).updateFromAI({
      'license': '79674102',
      'color': 'כחול',
      'month': '11',
      'hand': 'יד שנייה',
      'ownership': 'פרטית',
      'prevOwnership': 'פרטית',
      'km': 50000,
      'price': 80000,
      'test': '11,2027',
      'handicapped': 'לא',
      'description': 'גוף נקי, ללא תאונות',
    });
    setState(() => _modeSelected = true);
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final formState = ref.watch(fp.formControllerProvider);
    final notifier = ref.read(fp.formControllerProvider.notifier);

    // When loadFromListing sets isTypingMode=true, auto-activate typing mode
    ref.listen<fp.FormState>(fp.formControllerProvider, (prev, next) {
      if ((prev?.isTypingMode ?? false) == false &&
          next.isTypingMode == true &&
          !next.isProcessing) {
        // Sync controllers (e.g. after edit-listing tap)
        _syncControllers(next);
        if (!_modeSelected) setState(() => _modeSelected = true);
      }
    });

    final effectiveModeSelected = _modeSelected || formState.isTypingMode;
    final currentStep =
        formState.isTypingMode ? (formState.images.isNotEmpty ? 3 : 2) : 1;

    return Stack(
      children: [
        Scaffold(
          backgroundColor: Colors.white,
          body: Column(
            children: [
              const SizedBox(height: 24),
              _buildProgressBar(currentStep),
              const SizedBox(height: 24),
              _buildInputToggles(formState, notifier),
              const SizedBox(height: 16),
              Expanded(
                child:
                    effectiveModeSelected && formState.isTypingMode
                        ? _buildFormContent(formState, notifier)
                        : const SizedBox.shrink(),
              ),
            ],
          ),
        ),

        // Processing overlay shown while transcribing
        if (formState.isProcessing)
          Container(
            color: const Color(0x66000000),
            child: const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(color: Colors.white),
                  SizedBox(height: 16),
                  Text(
                    'מעבד הקלטה...',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 18,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  // ── Progress bar ──────────────────────────────────────────────────────────

  Widget _buildProgressBar(int currentStep) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          _buildStep(1, 'בחירה', currentStep),
          _buildLine(1, currentStep),
          _buildStep(2, 'פרטים', currentStep),
          _buildLine(2, currentStep),
          _buildStep(3, 'תמונות', currentStep),
          _buildLine(3, currentStep),
          _buildStep(4, 'סיום', currentStep),
        ],
      ),
    );
  }

  Widget _buildStep(int stepIndex, String title, int currentStep) {
    final isCompleted = stepIndex < currentStep;
    final isActive = stepIndex == currentStep;

    final Widget circleContent;
    final Color circleColor;
    final Color textColor;

    if (isCompleted) {
      circleContent = const Icon(Icons.check, color: Colors.white, size: 16);
      circleColor = const Color(0xFF4CAF50);
      textColor = circleColor;
    } else if (isActive) {
      circleContent = Text(
        stepIndex.toString(),
        style: const TextStyle(
          color: Colors.white,
          fontWeight: FontWeight.bold,
        ),
      );
      circleColor = const Color(0xFF3B5BDB);
      textColor = circleColor;
    } else {
      circleContent = Text(
        stepIndex.toString(),
        style: const TextStyle(color: Colors.grey, fontWeight: FontWeight.bold),
      );
      circleColor = Colors.white;
      textColor = Colors.grey;
    }

    return Column(
      children: [
        Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            color: circleColor,
            border: Border.all(
              color:
                  isActive || isCompleted ? circleColor : Colors.grey.shade300,
              width: 1,
            ),
          ),
          alignment: Alignment.center,
          child: circleContent,
        ),
        const SizedBox(height: 8),
        Text(
          title,
          style: TextStyle(
            color: textColor,
            fontSize: 12,
            fontWeight:
                isActive || isCompleted ? FontWeight.bold : FontWeight.normal,
          ),
        ),
      ],
    );
  }

  Widget _buildLine(int stepIndex, int currentStep) {
    return Expanded(
      child: Container(
        margin: const EdgeInsets.only(bottom: 24),
        height: 2,
        color:
            stepIndex < currentStep
                ? const Color(0xFF3B5BDB)
                : Colors.grey.shade300,
      ),
    );
  }

  // ── Input-mode toggles ────────────────────────────────────────────────────

  Widget _buildInputToggles(
    fp.FormState formState,
    fp.FormController notifier,
  ) {
    final effectiveModeSelected = _modeSelected || formState.isTypingMode;
    final isTyping = formState.isTypingMode;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16.0),
      child: Row(
        children: [
          // Record card (mic) — navigates to RecordingScreen, never stays "active"
          Expanded(
            child: _buildToggleCard(
              title: 'add_car.tab_record'.tr(),
              icon: Icons.mic,
              isActive: false,
              onTap: _onRecordTapped,
            ),
          ),
          const SizedBox(width: 16),
          // Type card (keyboard) — shows form inline
          Expanded(
            child: _buildToggleCard(
              title: 'add_car.tab_type'.tr(),
              icon: Icons.keyboard,
              isActive: effectiveModeSelected && isTyping,
              onTap: () {
                setState(() => _modeSelected = true);
                if (!formState.isTypingMode) notifier.toggleTypingMode();
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildToggleCard({
    required String title,
    required IconData icon,
    required bool isActive,
    required VoidCallback onTap,
  }) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 24),
        decoration: BoxDecoration(
          color: isActive ? const Color(0xFFF4F6FF) : Colors.white,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isActive ? const Color(0xFF3B5BDB) : Colors.grey.shade300,
            width: isActive ? 1.5 : 1,
          ),
        ),
        child: Column(
          children: [
            Icon(
              icon,
              color: isActive ? Colors.black54 : Colors.grey.shade400,
              size: 32,
            ),
            const SizedBox(height: 12),
            Text(
              title,
              style: const TextStyle(
                color: Colors.black87,
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Form content ──────────────────────────────────────────────────────────

  Widget _buildFormContent(fp.FormState formState, fp.FormController notifier) {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildTextField(
            'add_car.license'.tr(),
            _licenseController,
            (v) => notifier.updateField('license', v),
            isRequired: true,
            hintText: 'add_car.license_hint'.tr(),
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
            maxLength: 8,
            onSubmitted: (v) => _onLicenseSubmitted(v, notifier),
            suffixIcon:
                _isFetchingVehicle
                    ? const SizedBox(
                      width: 20,
                      height: 20,
                      child: Padding(
                        padding: EdgeInsets.all(12),
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                    )
                    : IconButton(
                      icon: const Icon(Icons.search, color: Color(0xFF3B5BDB)),
                      onPressed:
                          () => _onLicenseSubmitted(
                            _licenseController.text,
                            notifier,
                          ),
                    ),
          ),
          _buildDropdownField(
            'צבע',
            _colorController,
            _colors,
            isRequired: true,
          ),
          _buildDropdownField(
            'add_car.month_on_road'.tr(),
            _monthController,
            _months,
            isRequired: true,
          ),
          _buildToggleField('ללא טסט', _noTestController),
          ValueListenableBuilder<bool>(
            valueListenable: _noTestController,
            builder: (context, noTestVal, child) {
              return Padding(
                padding: const EdgeInsets.only(bottom: 16.0),
                child: Row(
                  children: [
                    Expanded(
                      child: _buildDropdownField(
                        'טסט עד (חודש)',
                        _testMonthController,
                        _months,
                        isRequired: !noTestVal,
                        isCompact: true,
                        isEnabled: !noTestVal,
                      ),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: _buildDropdownField(
                        'טסט עד (שנה)',
                        _testYearController,
                        _years,
                        isRequired: !noTestVal,
                        isCompact: true,
                        isEnabled: !noTestVal,
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
          _buildDropdownField(
            'add_car.hand'.tr(),
            _handController,
            _hands,
            isRequired: true,
          ),
          _buildDropdownField(
            'add_car.current_ownership'.tr(),
            _ownershipController,
            _ownerships,
            isRequired: true,
          ),
          _buildDropdownField(
            'add_car.previous_ownership'.tr(),
            _prevOwnershipController,
            _ownerships,
          ),
          _buildTextField(
            'add_car.km'.tr(),
            _kmController,
            (v) => notifier.updateField('km', v),
            isRequired: true,
            hintText: 'add_car.km_hint'.tr(),
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          ),
          _buildTextField(
            'add_car.price'.tr(),
            _priceController,
            (v) => notifier.updateField('price', v),
            isRequired: true,
            hintText: 'add_car.price_hint'.tr(),
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          ),
          _buildToggleField('add_car.handicapped'.tr(), _handicappedController),

          const SizedBox(height: 24),

          // Images section
          RichText(
            text: TextSpan(
              children: [
                const TextSpan(
                  text: '* ',
                  style: TextStyle(color: Colors.red, fontSize: 16),
                ),
                TextSpan(
                  text: 'add_car.images_title'.tr(),
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    color: Colors.black87,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'add_car.images_subtitle'.tr(),
            style: const TextStyle(fontSize: 12, color: Colors.grey),
          ),
          const SizedBox(height: 12),

          SizedBox(
            height: 80,
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: 5,
              itemBuilder: (context, index) {
                final hasImg = index < formState.images.length;
                return Container(
                  width: 80,
                  margin: const EdgeInsets.only(left: 8),
                  decoration: BoxDecoration(
                    color: Colors.grey.shade50,
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: Colors.grey.shade300),
                  ),
                  child:
                      hasImg
                          ? Stack(
                            fit: StackFit.expand,
                            children: [
                              ClipRRect(
                                borderRadius: BorderRadius.circular(8),
                                child:
                                    kIsWeb ||
                                            formState.images[index].startsWith(
                                              'http',
                                            )
                                        ? Image.network(
                                          formState.images[index],
                                          fit: BoxFit.cover,
                                          errorBuilder:
                                              (_, __, ___) => const Icon(
                                                Icons.image,
                                                color: Colors.grey,
                                              ),
                                        )
                                        : Image.file(
                                          File(formState.images[index]),
                                          fit: BoxFit.cover,
                                          errorBuilder:
                                              (_, __, ___) => const Icon(
                                                Icons.image,
                                                color: Colors.grey,
                                              ),
                                        ),
                              ),
                              Positioned(
                                top: 4,
                                right: 4,
                                child: GestureDetector(
                                  onTap:
                                      () => ref
                                          .read(
                                            fp.formControllerProvider.notifier,
                                          )
                                          .removeImage(index),
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
                          : GestureDetector(
                            onTap: () => _showImagePicker(context),
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                const Icon(
                                  Icons.camera_alt,
                                  color: Colors.grey,
                                ),
                                Text(
                                  '${index + 1}',
                                  style: const TextStyle(
                                    color: Colors.grey,
                                    fontSize: 12,
                                  ),
                                ),
                              ],
                            ),
                          ),
                );
              },
            ),
          ),

          const SizedBox(height: 32),

          // Test data preset button
          SizedBox(
            width: double.infinity,
            child: OutlinedButton(
              onPressed: _fillTestData,
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: Color(0xFF9C27B0)),
                padding: const EdgeInsets.symmetric(vertical: 12),
                foregroundColor: const Color(0xFF9C27B0),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              child: const Text(
                'מילוי נתוני בדיקה',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.bold),
              ),
            ),
          ),
          const SizedBox(height: 12),

          // Publish button
          SizedBox(
            width: double.infinity,
            child: ElevatedButton(
              onPressed: _isPublishing ? null : _publishListing,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFF4CAF50),
                padding: const EdgeInsets.symmetric(vertical: 16),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              child:
                  _isPublishing
                      ? const SizedBox(
                        width: 20,
                        height: 20,
                        child: CircularProgressIndicator(color: Colors.white),
                      )
                      : Text(
                        'add_car.publish'.tr(),
                        style: const TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.bold,
                          color: Colors.white,
                        ),
                      ),
            ),
          ),
          const SizedBox(height: 12),

          // Update button (same logic, labelled differently)
          SizedBox(
            width: double.infinity,
            child: OutlinedButton(
              onPressed: _isPublishing ? null : _publishListing,
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: Color(0xFF3B5BDB)),
                padding: const EdgeInsets.symmetric(vertical: 16),
                foregroundColor: const Color(0xFF3B5BDB),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              child: const Text(
                'עידכון',
                style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
            ),
          ),
          const SizedBox(height: 12),

          // Clear all
          SizedBox(
            width: double.infinity,
            child: OutlinedButton(
              onPressed: () {
                ref.read(fp.formControllerProvider.notifier).clearForm();
                _licenseController.clear();
                _monthController.clear();
                _testMonthController.text = DateTime.now().month.toString();
                _testYearController.text = (DateTime.now().year + 1).toString();
                _handController.clear();
                _ownershipController.clear();
                _prevOwnershipController.clear();
                _kmController.clear();
                _priceController.clear();
                _handicappedController.value = false;
                _noTestController.value = false;
                setState(() => _modeSelected = false);
              },
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: Colors.red),
                padding: const EdgeInsets.symmetric(vertical: 16),
                foregroundColor: Colors.red,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
              ),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(
                    'add_car.clear_all'.tr(),
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(width: 8),
                  const Icon(Icons.cleaning_services, size: 20),
                ],
              ),
            ),
          ),
          const SizedBox(height: 32),
        ],
      ),
    );
  }

  void _showImagePicker(BuildContext context) {
    showModalBottomSheet(
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
                _sheetBtn(
                  ctx,
                  'העלאה מגלריה',
                  const Color(0xFF5B7FFF),
                  () => _pickImage(ImageSource.gallery),
                ),
                const SizedBox(height: 12),
                _sheetBtn(
                  ctx,
                  'צילום תמונה',
                  const Color(0xFF5B7FFF),
                  () => _pickImage(ImageSource.camera),
                ),
                const SizedBox(height: 12),
                _sheetBtn(
                  ctx,
                  'ביטול',
                  const Color(0xFFF3F4F6),
                  () {},
                  textColor: Colors.red,
                ),
                const SizedBox(height: 16),
              ],
            ),
          ),
    );
  }

  Widget _sheetBtn(
    BuildContext ctx,
    String label,
    Color bg,
    VoidCallback action, {
    Color textColor = Colors.white,
  }) {
    return SizedBox(
      width: double.infinity,
      child: ElevatedButton(
        onPressed: () {
          Navigator.pop(ctx);
          action();
        },
        style: ElevatedButton.styleFrom(
          backgroundColor: bg,
          elevation: 0,
          padding: const EdgeInsets.symmetric(vertical: 16),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 16,
            fontWeight: FontWeight.bold,
            color: textColor,
          ),
        ),
      ),
    );
  }

  Widget _buildTextField(
    String label,
    TextEditingController controller,
    Function(String) onChanged, {
    bool isRequired = false,
    int maxLines = 1,
    String? hintText,
    Function(String)? onSubmitted,
    Widget? suffixIcon,
    TextInputType? keyboardType,
    List<TextInputFormatter>? inputFormatters,
    int? maxLength,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          RichText(
            text: TextSpan(
              children: [
                if (isRequired)
                  const TextSpan(
                    text: '* ',
                    style: TextStyle(color: Colors.red, fontSize: 14),
                  ),
                TextSpan(
                  text: label,
                  style: const TextStyle(
                    color: Colors.black87,
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: controller,
            maxLines: maxLines,
            maxLength: maxLength,
            keyboardType: keyboardType,
            inputFormatters: inputFormatters,
            style: const TextStyle(color: Colors.black),
            textAlign: TextAlign.right,
            onSubmitted: onSubmitted,
            decoration: InputDecoration(
              counterText: '',
              filled: true,
              fillColor: Colors.white,
              hintText: hintText,
              hintStyle: const TextStyle(color: Colors.grey),
              suffixIcon: suffixIcon,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 12,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide(
                  color: isRequired ? Colors.red : Colors.grey.shade300,
                  width: 1,
                ),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide(
                  color: isRequired ? Colors.red : Colors.grey.shade300,
                  width: 1,
                ),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(
                  color: Color(0xFF3B5BDB),
                  width: 1.5,
                ),
              ),
            ),
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }

  Widget _buildDropdownField(
    String label,
    TextEditingController controller,
    List<String> items, {
    bool isRequired = false,
    bool isCompact = false,
    bool isEnabled = true,
  }) {
    return Padding(
      padding: EdgeInsets.only(bottom: isCompact ? 0.0 : 16.0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          RichText(
            text: TextSpan(
              children: [
                if (isRequired)
                  const TextSpan(
                    text: '* ',
                    style: TextStyle(color: Colors.red, fontSize: 14),
                  ),
                TextSpan(
                  text: label,
                  style: const TextStyle(
                    color: Colors.black87,
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          DropdownButtonFormField<String>(
            initialValue:
                items.contains(controller.text) ? controller.text : items.first,
            style: const TextStyle(color: Colors.black),
            dropdownColor: Colors.white,
            decoration: InputDecoration(
              filled: true,
              fillColor: Colors.white,
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 16,
                vertical: 12,
              ),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide(
                  color: isRequired ? Colors.red : Colors.grey.shade300,
                  width: 1,
                ),
              ),
              enabledBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: BorderSide(
                  color: isRequired ? Colors.red : Colors.grey.shade300,
                  width: 1,
                ),
              ),
              focusedBorder: OutlineInputBorder(
                borderRadius: BorderRadius.circular(8),
                borderSide: const BorderSide(
                  color: Color(0xFF3B5BDB),
                  width: 1.5,
                ),
              ),
            ),
            items:
                items.map((String item) {
                  return DropdownMenuItem<String>(
                    value: item,
                    child: Align(
                      alignment: Alignment.centerRight,
                      child: Text(
                        item,
                        style: TextStyle(
                          color: isEnabled ? Colors.black : Colors.grey,
                        ),
                      ),
                    ),
                  );
                }).toList(),
            onChanged:
                isEnabled
                    ? (String? value) {
                      if (value != null) {
                        controller.text = value;
                      }
                    }
                    : null,
          ),
        ],
      ),
    );
  }

  Widget _buildToggleField(
    String label,
    ValueNotifier<bool> controller, {
    bool isRequired = false,
  }) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 16.0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          RichText(
            text: TextSpan(
              children: [
                if (isRequired)
                  const TextSpan(
                    text: '* ',
                    style: TextStyle(color: Colors.red, fontSize: 14),
                  ),
                TextSpan(
                  text: label,
                  style: const TextStyle(
                    color: Colors.black87,
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ],
            ),
          ),
          ValueListenableBuilder<bool>(
            valueListenable: controller,
            builder: (context, value, child) {
              return Switch(
                value: value,
                activeColor: const Color(0xFF3B5BDB),
                onChanged: (bool newVal) {
                  controller.value = newVal;
                },
              );
            },
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Recording screen (full-page, pushed via Navigator)
// ---------------------------------------------------------------------------
class _RecordingScreen extends ConsumerStatefulWidget {
  final AudioService audioService;
  const _RecordingScreen({required this.audioService});

  @override
  ConsumerState<_RecordingScreen> createState() => _RecordingScreenState();
}

class _RecordingScreenState extends ConsumerState<_RecordingScreen>
    with TickerProviderStateMixin {
  int _seconds = 0;
  Timer? _timer;
  bool _isRecording = false;

  late final AnimationController _wave1;
  late final AnimationController _wave2;
  late final AnimationController _wave3;
  late final Animation<double> _scale1;
  late final Animation<double> _scale2;
  late final Animation<double> _scale3;

  @override
  void initState() {
    super.initState();

    _wave1 = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    );
    _wave2 = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1900),
    );
    _wave3 = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2300),
    );

    _scale1 = Tween<double>(
      begin: 1.0,
      end: 1.3,
    ).animate(CurvedAnimation(parent: _wave1, curve: Curves.easeInOut));
    _scale2 = Tween<double>(
      begin: 0.9,
      end: 1.2,
    ).animate(CurvedAnimation(parent: _wave2, curve: Curves.easeInOut));
    _scale3 = Tween<double>(
      begin: 0.8,
      end: 1.1,
    ).animate(CurvedAnimation(parent: _wave3, curve: Curves.easeInOut));
  }

  void _startRecording() async {
    final audioService = widget.audioService;
    final notifier = ref.read(fp.formControllerProvider.notifier);

    notifier.setRecording(true);
    final path = await audioService.startRecording();
    if (path == null) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'אין הרשאה למיקרופון או שגיאה בהפעלת הקלטה',
              textAlign: TextAlign.right,
            ),
            backgroundColor: Colors.red,
          ),
        );
      }
      return;
    }

    if (!mounted) return;

    setState(() {
      _isRecording = true;
    });

    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) {
        setState(() {
          _seconds++;
        });
      }
    });

    _wave1.repeat(reverse: true);
    _wave2.repeat(reverse: true);
    _wave3.repeat(reverse: true);
  }

  @override
  void dispose() {
    _timer?.cancel();
    _wave1.dispose();
    _wave2.dispose();
    _wave3.dispose();
    super.dispose();
  }

  String get _formatted {
    final m = _seconds ~/ 60;
    final s = _seconds % 60;
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        backgroundColor: Colors.white,
        appBar: AppBar(
          title: Text(
            'add_car.title_record'.tr(),
            style: const TextStyle(
              fontWeight: FontWeight.bold,
              color: Colors.black87,
            ),
          ),
          backgroundColor: Colors.white,
          elevation: 0,
          leading: IconButton(
            icon: const Icon(Icons.arrow_forward, color: Colors.black87),
            onPressed: () => Navigator.of(context).pop(false),
          ),
        ),
        body: SafeArea(
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20.0),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                const SizedBox(height: 8),

                // Instruction header
                Text(
                  'add_car.record_instructions'.tr(),
                  textAlign: TextAlign.right,
                  style: const TextStyle(
                    fontSize: 14,
                    color: Color(0xFF555555),
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 8),

                // Fields list
                Align(
                  alignment: Alignment.centerRight,
                  child: Text(
                    'add_car.fields_list'.tr(),
                    textAlign: TextAlign.right,
                    style: const TextStyle(
                      fontSize: 15,
                      color: Color(0xFF333333),
                      height: 1.8,
                    ),
                  ),
                ),

                // Animated waves + mic
                Expanded(
                  child: Center(
                    child: SizedBox(
                      width: 200,
                      height: 200,
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          // Outer wave
                          ScaleTransition(
                            scale: _scale3,
                            child: Container(
                              width: 200,
                              height: 200,
                              decoration: const BoxDecoration(
                                shape: BoxShape.circle,
                                color: Color(0x1AFA5252), // ~10% opacity
                              ),
                            ),
                          ),
                          // Middle wave
                          ScaleTransition(
                            scale: _scale2,
                            child: Container(
                              width: 160,
                              height: 160,
                              decoration: const BoxDecoration(
                                shape: BoxShape.circle,
                                color: Color(0x26FA5252), // ~15% opacity
                              ),
                            ),
                          ),
                          // Inner wave
                          ScaleTransition(
                            scale: _scale1,
                            child: Container(
                              width: 130,
                              height: 130,
                              decoration: const BoxDecoration(
                                shape: BoxShape.circle,
                                color: Color(0x33FA5252), // ~20% opacity
                              ),
                            ),
                          ),
                          // Mic button
                          GestureDetector(
                            onTap: () {
                              if (_isRecording) {
                                Navigator.of(context).pop(true);
                              } else {
                                _startRecording();
                              }
                            },
                            child: Container(
                              width: 100,
                              height: 100,
                              decoration: BoxDecoration(
                                shape: BoxShape.circle,
                                color:
                                    _isRecording
                                        ? const Color(0xFFFA5252)
                                        : const Color(0xFF3B5BDB),
                                boxShadow: [
                                  BoxShadow(
                                    color:
                                        _isRecording
                                            ? const Color(0x44FA5252)
                                            : const Color(0x443B5BDB),
                                    blurRadius: 15,
                                    spreadRadius: 5,
                                  ),
                                ],
                              ),
                              child: const Icon(
                                Icons.mic,
                                size: 50,
                                color: Colors.white,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),

                // Status + timer
                Center(
                  child: Column(
                    children: [
                      Text(
                        _isRecording
                            ? 'add_car.recording'.tr()
                            : 'לחץ על המיקרופון כדי להתחיל להקליט',
                        style: const TextStyle(
                          fontSize: 16,
                          color: Color(0xFF555555),
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        _formatted,
                        style: TextStyle(
                          fontSize: 32,
                          fontWeight: FontWeight.bold,
                          color:
                              _isRecording
                                  ? const Color(0xFFFA5252)
                                  : Colors.grey,
                        ),
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 24),

                // Stop recording / Start recording
                ElevatedButton(
                  onPressed:
                      _isRecording
                          ? () => Navigator.of(context).pop(true)
                          : _startRecording,
                  style: ElevatedButton.styleFrom(
                    backgroundColor:
                        _isRecording
                            ? const Color(0xFFFA5252)
                            : const Color(0xFF3B5BDB),
                    padding: const EdgeInsets.symmetric(vertical: 16),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  child: Text(
                    _isRecording ? 'add_car.stop_recording'.tr() : 'התחל הקלטה',
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                ),
                const SizedBox(height: 12),

                // Cancel
                TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: Text(
                    'add_car.cancel'.tr(),
                    style: const TextStyle(
                      fontSize: 16,
                      color: Color(0xFF555555),
                    ),
                  ),
                ),
                const SizedBox(height: 16),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/*
class _GemmaDownloadDialog extends StatefulWidget {
  const _GemmaDownloadDialog();
  @override
  State<_GemmaDownloadDialog> createState() => _GemmaDownloadDialogState();
}

class _GemmaDownloadDialogState extends State<_GemmaDownloadDialog> {
  int _progress = 0;
  bool _isDownloading = false;

  void _startDownload() async {
    setState(() => _isDownloading = true);
    try {
      await GemmaService().downloadGemmaModel(
        onProgress: (p) {
          if (mounted) setState(() => _progress = p);
        },
      );
      if (mounted) Navigator.of(context).pop();
    } catch (e) {
      if (mounted) {
        Navigator.of(context).pop();
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('שגיאה בהורדת המודל: $e', textAlign: TextAlign.right),
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('הורדת מודל AI מקומי', textAlign: TextAlign.right),
      content:
          _isDownloading
              ? Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  LinearProgressIndicator(value: _progress / 100),
                  const SizedBox(height: 16),
                  Text('$_progress%'),
                ],
              )
              : const Text(
                'כדי להשתמש בפיצ׳ר ה-AI, יש להוריד את המודל לטלפון (פעולה חד פעמית).',
                textAlign: TextAlign.right,
              ),
      actions:
          _isDownloading
              ? []
              : [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text('מאוחר יותר'),
                ),
                ElevatedButton(
                  onPressed: _startDownload,
                  child: const Text('הורד עכשיו'),
                ),
              ],
    );
  }
}
*/
