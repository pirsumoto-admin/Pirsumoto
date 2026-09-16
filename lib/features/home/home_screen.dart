import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'dart:typed_data';
import 'package:http/http.dart' as http;
import 'package:easy_localization/easy_localization.dart' hide TextDirection;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../form/form_provider.dart' as fp;
import '../../services/db_service.dart';
import '../../services/audio_service.dart';
import '../../services/vehicle_data_service.dart';
import '../../services/whatsapp_text_validation_service.dart';
import '../../services/whatsapp_message_bridge_service.dart';
import '../../services/agent_config_service.dart';
import '../auth/auth_provider.dart';
import '../listings/listings_screen.dart';
import '../profile/profile_screen.dart';
import '../settings/settings_screen.dart';
import '../publish/yad2_screen.dart';
import '../publish/facebook_screen.dart';
import '../../services/yad2_automation_service.dart';
// import 'package:flutter_gemma/flutter_gemma.dart';
// import '../../services/gemma_service.dart';

// ---------------------------------------------------------------------------
// Home shell – bottom nav + top tabs
// ---------------------------------------------------------------------------
class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  // ===========================================================================
  // DEBUG PARAMETERS
  // ===========================================================================
  /// Debug flag to disable the WhatsApp listener and background bridge.
  /// Set to true to disable WhatsApp listening, false to enable.
  static bool debugDisableWhatsAppListener = false;

  /// Debug flag to select the target platform for the "פרסום" (Publish) button:
  /// true  => Facebook automation directly (FacebookScreen)
  /// false => Start in Yad2 and immediately chain to Facebook when done (Yad2Screen -> FacebookScreen)
  static bool debugMapPublishToFacebook = false;

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
    if (HomeScreen.debugDisableWhatsAppListener) {
      WhatsAppMessageBridgeService.instance.setListenerDisabled(true);
    }
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

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        if (_currentIndex != 0) {
          setState(() => _currentIndex = 0);
        }
      },
      child: RepaintBoundary(
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
          bottomNavigationBar: Container(
            decoration: const BoxDecoration(
              border: Border(top: BorderSide(color: Color(0xFFEEEEEE), width: 1)),
            ),
            child: bottomNav,
          ),
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
  List<String> get _colors => AgentConfigService.instance.allowedColors;
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
  final _vehicleConditionController = TextEditingController();
  final _makerController = TextEditingController();
  final _modelController = TextEditingController();
  final _yearController = TextEditingController();
  final _fuelTypeController = TextEditingController();
  final _gearController = TextEditingController();
  List<String> get _conditions => AgentConfigService.instance.allowedConditions;
  int? _kilometerTestAharon;

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
  List<String> get _ownerships => AgentConfigService.instance.allowedOwnerships;
  final List<String> _yesNo = ['לא', 'כן'];

  final ImagePicker _picker = ImagePicker();

  /// Tracks whether the user has explicitly chosen an input mode
  bool _modeSelected = false;
  bool _isProcessing = false;
  bool _isFetchingVehicle = false;
  bool _hasSearchedSuccessfully = false;
  bool _isPublishing = false;
  bool _useGemmaAutomation = true; // Use Gemma Automation for testing

  /// Debug parameters (initialized from HomeScreen static defaults, dynamically toggleable)
  late bool _disableWhatsAppListener = HomeScreen.debugDisableWhatsAppListener;
  late bool _mapPublishToFacebook = HomeScreen.debugMapPublishToFacebook;

  @override
  void initState() {
    super.initState();
    _testMonthController.text = DateTime.now().month.toString();
    _testYearController.text = (DateTime.now().year + 1).toString();
    _handicappedController.value = false;
    _noTestController.value = false;
    _vehicleConditionController.text = 'טוב';

    if (_disableWhatsAppListener) {
      WhatsAppMessageBridgeService.instance.setListenerDisabled(true);
    }
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
    _vehicleConditionController.dispose();
    _makerController.dispose();
    _modelController.dispose();
    _yearController.dispose();
    _fuelTypeController.dispose();
    _gearController.dispose();
    super.dispose();
  }

  // ── Controller sync ───────────────────────────────────────────────────────

  void _syncControllers(fp.FormState s) {
    _licenseController.text = s.license;
    _colorController.text = s.color;
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
    _vehicleConditionController.text =
        s.vehicleCondition.isNotEmpty ? s.vehicleCondition : 'טוב';
    _makerController.text = s.maker;
    _modelController.text = s.model;
    _yearController.text = s.year;
    _fuelTypeController.text = s.fuelType;
    _gearController.text = s.gear;
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
    if (data['vehicleCondition'] != null) {
      _vehicleConditionController.text = data['vehicleCondition'].toString();
    }
  }

  // ── License plate lookup ──────────────────────────────────────────────────

  Future<void> _onLicenseSubmitted(
    String license,
    fp.FormController notifier,
  ) async {
    if (license.length < 7) return;

    setState(() {
      _hasSearchedSuccessfully = false;
    });

    // Clear form except license
    notifier.clearForm();
    notifier.updateField('license', license);
    notifier.toggleTypingMode();

    _colorController.clear();
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
    _vehicleConditionController.text = 'טוב';
    _makerController.clear();
    _modelController.clear();
    _yearController.clear();
    _fuelTypeController.clear();
    _gearController.clear();

    setState(() => _isFetchingVehicle = true);

    try {
      final cleanLicense = license.replaceAll(RegExp(r'[^0-9]'), '');
      await _sendWhatsAppProgress(
        'מבצע שליפת נתוני רכב כלליים משרת הממשלה עבור מספר רישוי $license...',
      );

      final url =
          'https://data.gov.il/api/3/action/datastore_search?resource_id=053cea08-09bc-40ec-8f7a-156f0677aff3&filters=%7B%22mispar_rechev%22%3A%5B$cleanLicense%5D%7D';
      debugPrint('[LicenseLookup] Requesting URL: $url');
      final response = await http.get(Uri.parse(url));
      debugPrint('[LicenseLookup] HTTP Status: ${response.statusCode}');
      debugPrint('[LicenseLookup] Response Body: ${response.body}');

      if (response.statusCode == 200) {
        final decoded = jsonDecode(response.body);
        final result = decoded['result'];
        final records =
            result != null && result['records'] is List
                ? result['records'] as List
                : [];

        if (records.isNotEmpty) {
          final data = records.first;

          final maker = data['tozeret_nm']?.toString() ?? '';
          final model =
              data['kinuy_mishari']?.toString() ??
              data['degem_nm']?.toString() ??
              '';
          final year = data['shnat_yitzur']?.toString() ?? '';
          final fuelType = data['sug_delek_nm']?.toString() ?? '';
          _makerController.text = maker;
          _modelController.text = model;
          _yearController.text = year;
          _fuelTypeController.text = fuelType;
          notifier.updateField('maker', maker);
          notifier.updateField('model', model);
          notifier.updateField('year', year);
          notifier.updateField('fuelType', fuelType);

          // Fetch gear if available from model details dataset
          final tozeret = data['tozeret_cd'];
          final degemcd = data['degem_cd'];
          final sug = data['sug_degem']?.toString() ?? '';
          final degemNm = data['degem_nm']?.toString() ?? '';

          final filtersObj = {
            if (degemNm.isNotEmpty) 'degem_nm': degemNm,
            if (tozeret != null) 'tozeret_cd': tozeret,
            if (degemcd != null) 'degem_cd': degemcd,
            if (sug.isNotEmpty) 'sug_degem': sug,
            if (year.isNotEmpty) 'shnat_yitzur': int.tryParse(year) ?? year,
          };

          final urlGear =
              'https://data.gov.il/api/3/action/datastore_search?resource_id=142afde2-6228-49f9-8a29-9b6c3a0cbe40&filters=${Uri.encodeComponent(jsonEncode(filtersObj))}';
          try {
            final responseGear = await http.get(Uri.parse(urlGear));
            if (responseGear.statusCode == 200) {
              final decodedGear = jsonDecode(responseGear.body);
              final resultGear = decodedGear['result'];
              final recordsGear =
                  resultGear != null && resultGear['records'] is List
                      ? resultGear['records'] as List
                      : [];
              if (recordsGear.isNotEmpty) {
                final dataGear = recordsGear.first;
                final automatic = dataGear['automatic_ind'];
                final gearVal =
                    (automatic == 0 || automatic == "0")
                        ? "שידור ידני"
                        : "הילוכים אוטומטיים";
                _gearController.text = gearVal;
                notifier.updateField('gear', gearVal);
              } else {
                _gearController.text = 'הילוכים אוטומטיים';
                notifier.updateField('gear', 'הילוכים אוטומטיים');
              }
            } else {
              _gearController.text = 'הילוכים אוטומטיים';
              notifier.updateField('gear', 'הילוכים אוטומטיים');
            }
          } catch (_) {
            _gearController.text = 'הילוכים אוטומטיים';
            notifier.updateField('gear', 'הילוכים אוטומטיים');
          }

          final fullColor = (data['tzeva_rechev']?.toString() ?? '').trim();
          if (fullColor.isNotEmpty) {
            String matchedColor = '';
            if (_colors.contains(fullColor)) {
              matchedColor = fullColor;
            } else {
              final colorPart = fullColor.split(' ').first.trim();
              if (_colors.contains(colorPart)) {
                matchedColor = colorPart;
              } else {
                await _sendWhatsAppProgress(
                  'הצבע שנשלף משרת הממשלה ("$fullColor") אינו ברשימת הצבעים המורשים. מבצע התאמת צבע באמצעות AI...',
                );
                matchedColor = await _matchColorWithLlm(fullColor, _colors);
              }
            }
            if (matchedColor.isNotEmpty) {
              _colorController.text = matchedColor;
              notifier.updateField('color', matchedColor);
            }
          }

          final moed = data['moed_aliya_lakvish']?.toString() ?? '';
          if (moed.contains('-')) {
            final monthStr = moed.split('-').last;
            _monthController.text =
                int.tryParse(monthStr)?.toString() ?? monthStr;
          }

          final tokef = data['tokef_dt']?.toString() ?? '';
          if (tokef.contains('-')) {
            final parts = tokef.split('-');
            if (parts.length >= 2) {
              final testY = parts[0];
              final testM = int.tryParse(parts[1])?.toString() ?? parts[1];
              notifier.updateField('test', '$testM,$testY');
              _testMonthController.text = testM;
              _testYearController.text = testY;
            }
          }

          var baalut = data['baalut']?.toString() ?? '';
          if (baalut == 'פרטי') baalut = 'פרטית';
          if (_ownerships.contains(baalut)) {
            _ownershipController.text = baalut;
            notifier.updateField('ownership', baalut);
          }

          try {
            await _sendWhatsAppProgress(
              'מבצע שליפת נתוני קילומטראז\' וטסט משרת הממשלה עבור מספר רישוי $license...',
            );

            final url3 =
                'https://data.gov.il/api/3/action/datastore_search?resource_id=56063a99-8a3e-4ff4-912e-5966c0279bad&q=$cleanLicense&offset=0';
            debugPrint('[LicenseLookup-KM] Requesting URL: $url3');
            final response3 = await http.get(Uri.parse(url3));
            debugPrint(
              '[LicenseLookup-KM] HTTP Status: ${response3.statusCode}',
            );
            debugPrint('[LicenseLookup-KM] Response Body: ${response3.body}');
            if (response3.statusCode == 200) {
              final decoded3 = jsonDecode(response3.body);
              final result3 = decoded3['result'];
              final records3 =
                  result3 != null && result3['records'] is List
                      ? result3['records'] as List
                      : [];
              if (records3.isNotEmpty) {
                final data3 = records3.first;
                final kmVal = data3['kilometer_test_aharon'];
                if (kmVal != null) {
                  _kilometerTestAharon = int.tryParse(kmVal.toString());
                  if (_kilometerTestAharon != null) {
                    final estimatedKm = _calculateEstimatedKm(
                      rawKm: _kilometerTestAharon!,
                      vehicleData:
                          data is Map ? Map<String, dynamic>.from(data) : null,
                    );
                    final kmStr = estimatedKm.toString();
                    _kmController.text = kmStr;
                    notifier.updateField('km', kmStr);
                  }
                }
              }
            } else {
              debugPrint(
                '[LicenseLookup-KM] Error response (${response3.statusCode}): ${response3.body}',
              );
            }
          } catch (e, stackTrace) {
            debugPrint(
              '[LicenseLookup-KM] Error fetching kilometer_test_aharon: $e\n$stackTrace',
            );
          }

          if (mounted) {
            setState(() {
              _hasSearchedSuccessfully = true;
            });
            ScaffoldMessenger.of(context).showSnackBar(
              SnackBar(
                content: Text(
                  'נמצא: $maker $model $year',
                  textAlign: TextAlign.right,
                ),
                backgroundColor: Colors.green,
                duration: const Duration(seconds: 2),
              ),
            );
          }
        } else if (mounted) {
          debugPrint(
            '[LicenseLookup] No records returned for license "$cleanLicense" (raw: "$license"). Response body: ${response.body}',
          );
          setState(() {
            _hasSearchedSuccessfully = false;
          });
          _showLicenseNotFoundDialog();
        }
      } else {
        debugPrint(
          '[LicenseLookup] HTTP GET failed with status ${response.statusCode}: ${response.body}',
        );
        throw Exception(
          'Failed to fetch data: HTTP ${response.statusCode} - ${response.body}',
        );
      }
    } catch (e, stackTrace) {
      debugPrint(
        '[LicenseLookup] Error fetching vehicle data for license "$license": $e',
      );
      debugPrint('[LicenseLookup] StackTrace: $stackTrace');
      if (mounted) {
        _showLicenseNotFoundDialog();
      }
    }

    if (mounted) setState(() => _isFetchingVehicle = false);
  }

  int _calculateEstimatedKm({
    required int rawKm,
    Map<String, dynamic>? vehicleData,
  }) {
    return WhatsAppTextValidationService.calculateEstimatedKm(
      rawKm: rawKm,
      lastTestDate: vehicleData?['mivchan_acharon_dt'],
      tokefDt: vehicleData?['tokef_dt'],
      testMonth: _testMonthController.text,
      testYear: _testYearController.text,
      moedAliya: vehicleData?['moed_aliya_lakvish'],
      shnatYitzur: vehicleData?['shnat_yitzur'] ?? _yearController.text,
      registrationMonth: _monthController.text,
    );
  }

  Future<void> _sendWhatsAppProgress(String message) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      String? senderKey;
      final keys = prefs.getKeys();
      for (final key in keys) {
        if (key.startsWith('wa_state_')) {
          final jsonStr = prefs.getString(key);
          if (jsonStr != null && jsonStr.isNotEmpty) {
            try {
              final map = jsonDecode(jsonStr) as Map<String, dynamic>;
              final k = map['whatsapp_sender_key']?.toString();
              if (k != null && k.isNotEmpty) {
                senderKey = k;
                break;
              }
            } catch (_) {}
          }
        }
      }
      if (senderKey != null && senderKey.isNotEmpty) {
        await WhatsAppMessageBridgeService.instance.sendReplyToWhatsApp(
          senderKey: senderKey,
          message: message,
        );
      }
    } catch (e) {
      debugPrint('[HomeScreen] Error sending WhatsApp progress: $e');
    }
  }

  Future<String> _matchColorWithLlm(
    String rawColor,
    List<String> allowedColors,
  ) async {
    try {
      await AgentConfigService.instance.checkAndUpdateConfigIfNeeded();
      final prefs = await SharedPreferences.getInstance();
      final apiKey =
          prefs.getString('anthropic_api_key') ??
          const String.fromEnvironment('ANTHROPIC_API_KEY', defaultValue: '');

      if (apiKey.isEmpty) {
        return _fallbackColorMatch(rawColor, allowedColors);
      }

      final prompt = AgentConfigService.instance.getColorMatchingPrompt(
        rawColor,
        allowedColors,
      );

      final body = jsonEncode({
        'model': 'gpt-5.6-luna',
        'max_completion_tokens': 512,
        'reasoning_effort': 'low',
        'messages': [
          {'role': 'user', 'content': prompt},
        ],
      });

      final response = await http.post(
        Uri.parse('https://api.openai.com/v1/chat/completions'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $apiKey',
        },
        body: body,
      );

      if (response.statusCode == 200) {
        final decoded = jsonDecode(response.body) as Map<String, dynamic>;
        final contentText =
            (decoded['content'] as List?)
                ?.whereType<Map>()
                .where((c) => c['type'] == 'text')
                .map((c) => c['text'] as String)
                .join(' ')
                .trim() ??
            '';

        final cleanResult = contentText.trim().replaceAll(
          RegExp(r'[^\u0590-\u05FF]'),
          '',
        );
        for (final allowed in allowedColors) {
          if (cleanResult == allowed ||
              allowed.contains(cleanResult) ||
              cleanResult.contains(allowed)) {
            return allowed;
          }
        }
      }
    } catch (e) {
      debugPrint('[HomeScreen] LLM color matching error: $e');
    }

    return _fallbackColorMatch(rawColor, allowedColors);
  }

  String _fallbackColorMatch(String rawColor, List<String> allowedColors) {
    final norm = rawColor.toLowerCase();
    if (norm.contains('כסף') ||
        norm.contains('אפור') ||
        norm.contains('עכבר')) {
      return 'אפור';
    }
    if (norm.contains('זהב') ||
        norm.contains('צהוב') ||
        norm.contains('נחושת')) {
      return 'צהוב';
    }
    if (norm.contains('פנינה') ||
        norm.contains('שנהב') ||
        norm.contains('שמנת') ||
        norm.contains('קרם')) {
      return 'לבן';
    }
    if (norm.contains('תכלת') ||
        norm.contains('כחול') ||
        norm.contains('טורקיז')) {
      return 'כחול';
    }
    if (norm.contains('בורדו') || norm.contains('אדום')) return 'אדום';
    if (norm.contains('חום') || norm.contains('בז')) return 'חום';
    if (norm.contains('ירוק')) return 'ירוק';
    if (norm.contains('כתום')) return 'כתום';
    if (norm.contains('סגול')) return 'סגול';
    if (norm.contains('ורוד')) return 'ורוד';
    if (norm.contains('שחור')) return 'שחור';
    return allowedColors.first;
  }

  void _showLicenseNotFoundDialog() {
    if (!mounted) return;
    showDialog(
      context: context,
      builder:
          (ctx) => AlertDialog(
            title: const Text('מספר רישוי לא נמצא', textAlign: TextAlign.right),
            content: const Text(
              'מספר הרישוי לא נמצא. אנא נסה מספר אחר או היכנס לאפליקציה למלא את סוג הרכב והדגם ולחץ על המשך.',
              textAlign: TextAlign.right,
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('אישור'),
              ),
            ],
          ),
    );
  }

  void _showQuickPublishDialog() {
    final quickLicenseCtrl = TextEditingController();
    final quickKmCtrl = TextEditingController();
    final quickPriceCtrl = TextEditingController();
    bool isProcessing = false;
    String errorText = '';
    List<String?> quickImages = [null, null, null];
    String selectedCondition = 'טוב';

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            return AlertDialog(
              insetPadding: const EdgeInsets.symmetric(horizontal: 16),
              title: const Text('פרסום מהיר', textAlign: TextAlign.right),
              content: SizedBox(
                width: MediaQuery.of(context).size.width,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      if (errorText.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 8.0),
                          child: Text(
                            errorText,
                            style: const TextStyle(color: Colors.red),
                            textAlign: TextAlign.right,
                          ),
                        ),
                      TextField(
                        controller: quickLicenseCtrl,
                        decoration: InputDecoration(
                          labelText: 'מספר רישוי',
                          alignLabelWithHint: true,
                          counterText: '',
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 18,
                          ),
                        ),
                        keyboardType: TextInputType.number,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                        ],
                        maxLength: 8,
                        textAlign: TextAlign.right,
                      ),
                      const SizedBox(height: 16),
                      TextField(
                        controller: quickKmCtrl,
                        decoration: InputDecoration(
                          labelText: 'שעון (ק"מ)',
                          alignLabelWithHint: true,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 18,
                          ),
                        ),
                        keyboardType: TextInputType.number,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                        ],
                        textAlign: TextAlign.right,
                      ),
                      const SizedBox(height: 16),
                      TextField(
                        controller: quickPriceCtrl,
                        decoration: InputDecoration(
                          labelText: 'מחיר (₪)',
                          alignLabelWithHint: true,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 18,
                          ),
                        ),
                        keyboardType: TextInputType.number,
                        inputFormatters: [
                          FilteringTextInputFormatter.digitsOnly,
                        ],
                        textAlign: TextAlign.right,
                      ),
                      const SizedBox(height: 16),
                      DropdownButtonFormField<String>(
                        value: selectedCondition,
                        decoration: InputDecoration(
                          labelText: 'מצב הרכב',
                          alignLabelWithHint: true,
                          border: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                          ),
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 18,
                          ),
                        ),
                        dropdownColor: Colors.white,
                        items:
                            ['מצוין', 'טוב מאוד', 'טוב', 'סביר', 'גרוע'].map((
                              String item,
                            ) {
                              return DropdownMenuItem<String>(
                                value: item,
                                child: Align(
                                  alignment: Alignment.centerRight,
                                  child: Text(
                                    item,
                                    style: const TextStyle(color: Colors.black),
                                  ),
                                ),
                              );
                            }).toList(),
                        onChanged: (String? val) {
                          if (val != null) {
                            setDialogState(() {
                              selectedCondition = val;
                            });
                          }
                        },
                      ),
                      const SizedBox(height: 16),
                      const Text(
                        'תמונות (עד 3)',
                        textAlign: TextAlign.right,
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          color: Colors.black87,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children:
                            List.generate(3, (i) {
                              return Expanded(
                                child: GestureDetector(
                                  onTap: () async {
                                    try {
                                      final img = await _picker.pickImage(
                                        source: ImageSource.gallery,
                                      );
                                      if (img != null) {
                                        setDialogState(() {
                                          quickImages[i] = img.path;
                                        });
                                      }
                                    } catch (e) {
                                      debugPrint('Error picking image: $e');
                                    }
                                  },
                                  child: Container(
                                    margin: EdgeInsets.only(
                                      left: i < 2 ? 8.0 : 0,
                                    ),
                                    height: 80,
                                    decoration: BoxDecoration(
                                      border: Border.all(
                                        color: Colors.grey.shade400,
                                      ),
                                      borderRadius: BorderRadius.circular(8),
                                      image:
                                          quickImages[i] != null
                                              ? DecorationImage(
                                                image: FileImage(
                                                  File(quickImages[i]!),
                                                ),
                                                fit: BoxFit.cover,
                                              )
                                              : null,
                                    ),
                                    child:
                                        quickImages[i] == null
                                            ? const Icon(
                                              Icons.add_a_photo,
                                              color: Colors.grey,
                                            )
                                            : null,
                                  ),
                                ),
                              );
                            }).reversed.toList(),
                      ),
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: isProcessing ? null : () => Navigator.pop(ctx),
                  child: const Text('ביטול'),
                ),
                ElevatedButton(
                  onPressed:
                      isProcessing
                          ? null
                          : () async {
                            final license = quickLicenseCtrl.text;
                            final km = quickKmCtrl.text;
                            final price = quickPriceCtrl.text;

                            if (license.length < 7 || license.length > 8) {
                              setDialogState(
                                () =>
                                    errorText =
                                        'מספר רישוי חייב להיות 7 או 8 ספרות',
                              );
                              return;
                            }
                            if (km.isEmpty) {
                              setDialogState(
                                () => errorText = 'נא להזין קילומטראז׳',
                              );
                              return;
                            }
                            if (price.isEmpty) {
                              setDialogState(() => errorText = 'נא להזין מחיר');
                              return;
                            }

                            setDialogState(() {
                              errorText = '';
                              isProcessing = true;
                            });

                            final notifier = ref.read(
                              fp.formControllerProvider.notifier,
                            );
                            await _onLicenseSubmitted(license, notifier);

                            if (!mounted) return;

                            if (_hasSearchedSuccessfully) {
                              _kmController.text = km;
                              _priceController.text = price;
                              _vehicleConditionController.text =
                                  selectedCondition;
                              notifier.updateField('km', km);
                              notifier.updateField('price', price);
                              notifier.updateField(
                                'vehicleCondition',
                                selectedCondition,
                              );

                              for (final img in quickImages) {
                                if (img != null) notifier.addImage(img);
                              }

                              Navigator.pop(ctx);
                              await _publishListing(skipImagePrompt: false);
                            } else {
                              Navigator.pop(ctx);

                              setState(() {
                                _modeSelected = true;
                              });
                              if (!ref
                                  .read(fp.formControllerProvider)
                                  .isTypingMode) {
                                notifier.toggleTypingMode();
                              }

                              _licenseController.text = license;
                              _kmController.text = km;
                              _priceController.text = price;
                              _vehicleConditionController.text =
                                  selectedCondition;
                              notifier.updateField('km', km);
                              notifier.updateField('price', price);
                              notifier.updateField(
                                'vehicleCondition',
                                selectedCondition,
                              );

                              for (final img in quickImages) {
                                if (img != null) notifier.addImage(img);
                              }
                            }
                          },
                  child:
                      isProcessing
                          ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                          : const Text('פרסום'),
                ),
              ],
            );
          },
        );
      },
    );
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

  // ── Facebook automation test ─────────────────────────────────────────────
  // TEST ONLY: launches the Facebook Marketplace automation screen.
  // Does NOT change any recording logic — _onRecordTapped() is untouched.
  Future<void> _onFacebookTestTapped() async {
    if (!mounted) return;
    final license = _licenseController.text.trim();
    if (license.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'נא להזין מספר רישוי תחילה',
            textAlign: TextAlign.right,
          ),
          backgroundColor: Colors.orange,
        ),
      );
      return;
    }

    setState(() => _isFetchingVehicle = true);

    String maker = ref.read(fp.formControllerProvider).maker;
    String model = ref.read(fp.formControllerProvider).model;
    String year = ref.read(fp.formControllerProvider).year;
    String fuelType = ref.read(fp.formControllerProvider).fuelType;

    try {
      final url =
          //'https://data.gov.il/api/3/action/datastore_search?resource_id=053cea08-09bc-40ec-8f7a-156f0677aff3&filters=%7B%22mispar_rechev%22%3A%5B$license%5D%7D';
          'https://data.gov.il/api/3/action/datastore_search?resource_id=053cea08-09bc-40ec-8f7a-156f0677aff3&filters={%22mispar_rechev%22:[$license]}';
      final response = await http.get(Uri.parse(url));

      if (response.statusCode == 200) {
        final decoded = jsonDecode(response.body);
        final result = decoded['result'];
        final records = result['records'] as List;

        if (records.isNotEmpty) {
          final data = records.first;
          maker = data['tozeret_nm']?.toString() ?? '';
          model =
              data['kinuy_mishari']?.toString() ??
              data['degem_nm']?.toString() ??
              '';
          year = data['shnat_yitzur']?.toString() ?? '';
          fuelType = data['sug_delek_nm']?.toString() ?? '';

          final tozeret = data['tozeret_cd'];
          final degemcd = data['degem_cd'];
          final sug = data['sug_degem']?.toString() ?? '';
          final degemNm = data['degem_nm']?.toString() ?? '';

          final filtersObj = {
            if (degemNm.isNotEmpty) 'degem_nm': degemNm,
            if (tozeret != null) 'tozeret_cd': tozeret,
            if (degemcd != null) 'degem_cd': degemcd,
            if (sug.isNotEmpty) 'sug_degem': sug,
            if (year.isNotEmpty) 'shnat_yitzur': int.tryParse(year) ?? year,
          };

          final url2 =
              'https://data.gov.il/api/3/action/datastore_search?resource_id=142afde2-6228-49f9-8a29-9b6c3a0cbe40&filters=${Uri.encodeComponent(jsonEncode(filtersObj))}';

          final notifier = ref.read(fp.formControllerProvider.notifier);
          notifier.updateField('maker', maker);
          notifier.updateField('model', model);
          notifier.updateField('year', year);
          notifier.updateField('fuelType', fuelType);

          try {
            final response2 = await http.get(Uri.parse(url2));
            if (response2.statusCode == 200) {
              final decoded2 = jsonDecode(response2.body);
              final result2 = decoded2['result'];
              final records2 = result2['records'] as List;
              if (records2.isNotEmpty) {
                final data2 = records2.first;
                final automatic = data2['automatic_ind'];
                final gear =
                    (automatic == 0 || automatic == "0")
                        ? "שידור ידני"
                        : "הילוכים אוטומטיים";
                notifier.updateField('gear', gear);
              }
            }
          } catch (e) {
            debugPrint('Error fetching automatic_ind from url2: $e');
          }

          final url3 =
              'https://data.gov.il/api/3/action/datastore_search?resource_id=56063a99-8a3e-4ff4-912e-5966c0279bad&q=$license&offset=0';

          try {
            final response3 = await http.get(Uri.parse(url3));
            if (response3.statusCode == 200) {
              final decoded3 = jsonDecode(response3.body);
              final result3 = decoded3['result'];
              final records3 = result3['records'] as List;
              if (records3.isNotEmpty) {
                final data3 = records3.first;
                final kmVal = data3['kilometer_test_aharon'];
                if (kmVal != null) {
                  _kilometerTestAharon = int.tryParse(kmVal.toString());
                  if (_kilometerTestAharon != null) {
                    final estimatedKm = _calculateEstimatedKm(
                      rawKm: _kilometerTestAharon!,
                      vehicleData:
                          data is Map ? Map<String, dynamic>.from(data) : null,
                    );
                    final kmStr = estimatedKm.toString();
                    _kmController.text = kmStr;
                    notifier.updateField('km', kmStr);
                  }
                }
              }
            }
          } catch (e) {
            debugPrint('Error fetching kilometer_test_aharon from url3: $e');
          }
        }
      }
    } catch (e) {
      debugPrint('Error fetching vehicle data for FB: $e');
    } finally {
      if (mounted) {
        setState(() => _isFetchingVehicle = false);
      }
    }

    final formState = ref.read(fp.formControllerProvider);
    final publishData = VehiclePublishData(
      licenseNumber: license,
      color: _colorController.text.isNotEmpty ? _colorController.text : 'כחול',
      shade: _colorController.text.isNotEmpty ? _colorController.text : 'כחול',
      hand: _handController.text.isNotEmpty ? _handController.text : 'יד שנייה',
      currentOwnership:
          _ownershipController.text.isNotEmpty
              ? _ownershipController.text
              : 'פרטית',
      previousOwnership:
          _prevOwnershipController.text.isNotEmpty
              ? _prevOwnershipController.text
              : 'פרטית',
      kilometers: _kmController.text,
      month: _monthController.text,
      price: _priceController.text,
      handicapped: _handicappedController.value,
      noTest: _noTestController.value,
      images: formState.images,
      maker: maker.isNotEmpty ? maker : formState.maker,
      model: model.isNotEmpty ? model : formState.model,
      year: year.isNotEmpty ? year : formState.year,
      fuelType: fuelType.isNotEmpty ? fuelType : formState.fuelType,
      gear: formState.gear.isNotEmpty ? formState.gear : 'הילוכים אוטומטיים',
      vehicleCondition:
          _vehicleConditionController.text.isNotEmpty
              ? _vehicleConditionController.text
              : 'טוב',
      warranties: formState.warranties,
      warrantyDurations: formState.warrantyDurations,
      treatments: formState.treatments,
      services: formState.services,
    );

    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => FacebookScreen(publishData: publishData),
      ),
    );
  }

  // ── Publish ───────────────────────────────────────────────────────────────

  Future<void> _publishListing({bool skipImagePrompt = false}) async {
    // Check Firestore for updated agent prompt and rules before starting publication session
    await AgentConfigService.instance.checkAndUpdateConfigIfNeeded();

    final formState = ref.read(fp.formControllerProvider);
    final user = ref.read(authStateProvider).value;

    if (user == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('נא להתחבר למערכת', textAlign: TextAlign.right),
        ),
      );
      return;
    }

    final finalColor =
        _colorController.text.isNotEmpty
            ? _colorController.text
            : _colors.first;
    final finalMonth =
        _monthController.text.isNotEmpty
            ? _monthController.text
            : _months.first;
    final finalHand =
        _handController.text.isNotEmpty ? _handController.text : _hands.first;
    final finalOwnership =
        _ownershipController.text.isNotEmpty
            ? _ownershipController.text
            : _ownerships.first;
    final finalPrevOwnership =
        _prevOwnershipController.text.isNotEmpty
            ? _prevOwnershipController.text
            : _ownerships.first;
    final finalTestMonth =
        _testMonthController.text.isNotEmpty
            ? _testMonthController.text
            : DateTime.now().month.toString();
    final finalTestYear =
        _testYearController.text.isNotEmpty
            ? _testYearController.text
            : (DateTime.now().year + 1).toString();

    final validationService = const WhatsAppTextValidationService();
    final formVal = await validationService.validateFormFields({
      'license': _licenseController.text,
      'km': _kmController.text,
      'price': _priceController.text,
      'hand': _handController.text,
      'vehicleCondition': _vehicleConditionController.text,
    }, kilometerTestAharon: _kilometerTestAharon);

    if (!formVal.isValid) {
      final errorText = formVal.errors.join('\n');
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(errorText, textAlign: TextAlign.right),
          backgroundColor: Colors.red,
        ),
      );
      return;
    }

    if (!skipImagePrompt && formState.images.isEmpty) {
      final shouldContinue = await showDialog<bool>(
        context: context,
        builder:
            (ctx) => AlertDialog(
              title: const Text('לא הועלו תמונות', textAlign: TextAlign.right),
              content: const Text(
                'לא הועלתה אף תמונה, להמשיך?',
                textAlign: TextAlign.right,
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(false),
                  child: const Text('לא'),
                ),
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(true),
                  child: const Text('כן'),
                ),
              ],
            ),
      );

      if (shouldContinue != true) {
        return;
      }
    }

    setState(() => _isPublishing = true);

    final db = ref.read(dbServiceProvider);
    Map<String, dynamic>? settings;
    try {
      settings = await db.getSettingsData(user.uid);
    } catch (e) {
      debugPrint('Error loading settings for listing: $e');
    }

    final List<String> warranties;
    final Map<String, String> warrantyDurations;
    final List<String> treatments;
    final List<String> services;

    if (formState.warranties.isNotEmpty ||
        formState.treatments.isNotEmpty ||
        formState.services.isNotEmpty) {
      warranties = formState.warranties;
      warrantyDurations = formState.warrantyDurations;
      treatments = formState.treatments;
      services = formState.services;
    } else {
      warranties =
          settings?['warranties'] != null
              ? List<String>.from(settings!['warranties'])
              : <String>[];
      warrantyDurations =
          settings?['warrantyDurations'] != null
              ? Map<String, String>.from(settings!['warrantyDurations'])
              : <String, String>{};
      treatments =
          settings?['treatments'] != null
              ? List<String>.from(settings!['treatments'])
              : <String>[];
      services =
          settings?['services'] != null
              ? List<String>.from(settings!['services'])
              : <String>[];
    }

    final finalMaker = _makerController.text.isNotEmpty
        ? _makerController.text
        : formState.maker;
    final finalModel = _modelController.text.isNotEmpty
        ? _modelController.text
        : formState.model;
    final finalYear = _yearController.text.isNotEmpty
        ? _yearController.text
        : formState.year;
    final finalFuelType = _fuelTypeController.text.isNotEmpty
        ? _fuelTypeController.text
        : formState.fuelType;
    final finalGear = _gearController.text.isNotEmpty
        ? _gearController.text
        : (formState.gear.isNotEmpty ? formState.gear : 'הילוכים אוטומטיים');
    final finalVehicleCondition = _vehicleConditionController.text.isNotEmpty
        ? _vehicleConditionController.text
        : (formState.vehicleCondition.isNotEmpty
            ? formState.vehicleCondition
            : 'טוב');

    final listingData = {
      'license': _licenseController.text,
      'color': finalColor,
      'maker': finalMaker,
      'model': finalModel,
      'year': finalYear,
      'month': finalMonth,
      'test': '$finalTestMonth,$finalTestYear',
      'hand': finalHand,
      'ownership': finalOwnership,
      'prevOwnership': finalPrevOwnership,
      'km': _kmController.text,
      'price': _priceController.text,
      'handicapped': _handicappedController.value ? 'כן' : 'לא',
      'vehicleCondition': finalVehicleCondition,
      'gear': finalGear,
      'fuelType': finalFuelType,
      'noTest': _noTestController.value,
      'description': formState.description,
      'images': formState.images.map((p) => {'url': p}).toList(),
      'warranties': warranties,
      'warrantyDurations': warrantyDurations,
      'treatments': treatments,
      'services': services,
    };

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
      color: finalColor,
      shade: finalColor,
      hand: finalHand,
      currentOwnership: finalOwnership,
      previousOwnership: finalPrevOwnership,
      kilometers: _kmController.text,
      month: finalMonth,
      price: _priceController.text,
      handicapped: _handicappedController.value,
      noTest: _noTestController.value,
      images: formState.images,
      maker:
          _makerController.text.isNotEmpty
              ? _makerController.text
              : formState.maker,
      model:
          _modelController.text.isNotEmpty
              ? _modelController.text
              : formState.model,
      year:
          _yearController.text.isNotEmpty
              ? _yearController.text
              : formState.year,
      fuelType:
          _fuelTypeController.text.isNotEmpty
              ? _fuelTypeController.text
              : formState.fuelType,
      gear:
          _gearController.text.isNotEmpty
              ? _gearController.text
              : (formState.gear.isNotEmpty
                  ? formState.gear
                  : 'הילוכים אוטומטיים'),
      vehicleCondition:
          _vehicleConditionController.text.isNotEmpty
              ? _vehicleConditionController.text
              : 'טוב',
      warranties: warranties,
      warrantyDurations: warrantyDurations,
      treatments: treatments,
      services: services,
    );

    // Route to Facebook or Yad2 automation based on debug parameter
    if (_mapPublishToFacebook) {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => FacebookScreen(publishData: publishData),
        ),
      );
    } else {
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
  }

  void _fillTestData() {
    _licenseController.text = '79674102';
    _colorController.text = 'כחול';
    _monthController.text = '11';
    _handController.text = 'יד שנייה';
    _ownershipController.text = 'פרטית';
    _prevOwnershipController.text = 'פרטית';
    _kmController.text = '50000';
    _priceController.text = '80000';
    _testMonthController.text = '11';
    _testYearController.text = '2027';
    _handicappedController.value = false;
    _noTestController.value = false;
    _vehicleConditionController.text = 'טוב';

    // Populate user-requested test values
    _makerController.text = 'ג׳ילי';
    _modelController.text = 'גיאומטרי סי';
    _yearController.text = '2022';
    _fuelTypeController.text = 'חשמלי';
    _gearController.text = 'הילוכים אוטומטיים';

    final notifier = ref.read(fp.formControllerProvider.notifier);
    notifier.updateFromAI({
      'license': '79674102',
      'maker': 'ג׳ילי',
      'model': 'גיאומטרי סי',
      'year': '2022',
      'fuelType': 'חשמלי',
      'gear': 'הילוכים אוטומטיים',
      'color': 'כחול',
      'month': '11',
      'hand': 'יד שנייה',
      'ownership': 'פרטית',
      'prevOwnership': 'פרטית',
      'km': 50000,
      'price': 80000,
      'test': '11,2027',
      'handicapped': 'לא',
      'vehicleCondition': 'טוב',
      'description': 'גוף נקי, ללא תאונות',
    });
    notifier.updateField('maker', 'ג׳ילי');
    notifier.updateField('model', 'גיאומטרי סי');
    notifier.updateField('year', '2022');
    notifier.updateField('fuelType', 'חשמלי');
    notifier.updateField('gear', 'הילוכים אוטומטיים');
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

        // Processing overlay shown while transcribing or fetching
        if (formState.isProcessing || _isFetchingVehicle)
          Container(
            color: const Color(0x66000000),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const CircularProgressIndicator(color: Colors.white),
                  const SizedBox(height: 16),
                  Text(
                    _isFetchingVehicle ? 'מחפש רכב...' : 'מעבד הקלטה...',
                    style: const TextStyle(
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
          Expanded(
            child: _buildToggleCard(
              title: 'פרסום מהיר',
              icon: Icons.flash_on,
              isActive: false,
              onTap: _showQuickPublishDialog,
            ),
          ),
          const SizedBox(width: 8),
          // Record card (mic) — TEST: launches Facebook automation.
          // Original recording logic (_onRecordTapped) is untouched; swap back
          // by replacing _onFacebookTestTapped with _onRecordTapped below.
          Expanded(
            child: _buildToggleCard(
              title: 'add_car.tab_record'.tr(),
              icon: Icons.mic,
              isActive: false,
              onTap:
                  _onFacebookTestTapped, // 🧪 TEST: swap with _onRecordTapped to restore
            ),
          ),
          const SizedBox(width: 8),
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
        padding: const EdgeInsets.symmetric(vertical: 16),
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
              size: 28,
            ),
            const SizedBox(height: 8),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(
                color: Colors.black87,
                fontSize: 14,
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
          _buildDropdownField(
            'מצב הרכב',
            _vehicleConditionController,
            _conditions,
            onChanged: (val) => notifier.updateField('vehicleCondition', val),
          ),
          _buildTextField(
            'יצרן',
            _makerController,
            (v) => notifier.updateField('maker', v),
            hintText: 'לדוגמה: ג׳ילי',
          ),
          _buildTextField(
            'דגם',
            _modelController,
            (v) => notifier.updateField('model', v),
            hintText: 'לדוגמה: גיאומטרי סי',
          ),
          _buildTextField(
            'שנת ייצור',
            _yearController,
            (v) => notifier.updateField('year', v),
            hintText: 'לדוגמה: 2022',
            keyboardType: TextInputType.number,
            inputFormatters: [FilteringTextInputFormatter.digitsOnly],
          ),
          _buildTextField(
            'סוג דלק',
            _fuelTypeController,
            (v) => notifier.updateField('fuelType', v),
            hintText: 'לדוגמה: חשמלי, בנזין',
          ),
          _buildTextField(
            'תיבת הילוכים',
            _gearController,
            (v) => notifier.updateField('gear', v),
            hintText: 'לדוגמה: הילוכים אוטומטיים, שידור ידני',
          ),

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

          // Debug Parameters Card
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Colors.purple.withValues(alpha: 0.05),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: Colors.purple.withValues(alpha: 0.3)),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(
                      Icons.bug_report,
                      size: 18,
                      color: Colors.purple,
                    ),
                    const SizedBox(width: 8),
                    const Text(
                      'פרמטרי בדיקה (Debug Parameters)',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.bold,
                        color: Colors.purple,
                      ),
                    ),
                  ],
                ),
                const Divider(height: 16),
                // WhatsApp Listener Switch
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: const Text(
                    'השבתת מאזין וואטסאפ (Disable WhatsApp)',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
                  ),
                  subtitle: Text(
                    _disableWhatsAppListener
                        ? 'מאזין וואטסאפ מושבת'
                        : 'מאזין וואטסאפ פעיל',
                    style: TextStyle(
                      fontSize: 11,
                      color:
                          _disableWhatsAppListener ? Colors.red : Colors.green,
                    ),
                  ),
                  value: _disableWhatsAppListener,
                  onChanged: (val) {
                    setState(() {
                      _disableWhatsAppListener = val;
                      HomeScreen.debugDisableWhatsAppListener = val;
                    });
                    WhatsAppMessageBridgeService.instance.setListenerDisabled(
                      val,
                    );
                  },
                ),
                // Publish Target Switch
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  dense: true,
                  title: const Text(
                    'יעד כפתור הפרסום (Publish Target)',
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500),
                  ),
                  subtitle: Text(
                    _mapPublishToFacebook ? 'פייסבוק (Facebook)' : 'יד2 (Yad2)',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color:
                          _mapPublishToFacebook
                              ? const Color(0xFF1877F2)
                              : const Color(0xFFFF7700),
                    ),
                  ),
                  value: _mapPublishToFacebook,
                  activeThumbColor: const Color(0xFF1877F2),
                  activeTrackColor: const Color(0xFF90CAF9),
                  inactiveThumbColor: const Color(0xFFFF7700),
                  inactiveTrackColor: const Color(0xFFFFCC80),
                  onChanged: (val) {
                    setState(() {
                      _mapPublishToFacebook = val;
                      HomeScreen.debugMapPublishToFacebook = val;
                    });
                  },
                ),
              ],
            ),
          ),

          const SizedBox(height: 16),

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
                backgroundColor:
                    _mapPublishToFacebook
                        ? const Color(0xFF1877F2)
                        : const Color(0xFF4CAF50),
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
                      : Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            _mapPublishToFacebook ? Icons.share : Icons.publish,
                            color: Colors.white,
                            size: 20,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            _mapPublishToFacebook
                                ? '${'add_car.publish'.tr()} (פייסבוק)'
                                : '${'add_car.publish'.tr()} (יד2)',
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                            ),
                          ),
                        ],
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
                _makerController.clear();
                _modelController.clear();
                _yearController.clear();
                _fuelTypeController.clear();
                _gearController.clear();
                setState(() {
                  _modeSelected = false;
                  _hasSearchedSuccessfully = false;
                });
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
    ValueChanged<String>? onChanged,
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
            value:
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
                    ? (String? val) {
                      if (val != null) {
                        setState(() {
                          controller.text = val;
                        });
                        onChanged?.call(val);
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
