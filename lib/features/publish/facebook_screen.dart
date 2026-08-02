import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../../services/yad2_automation_service.dart' show VehiclePublishData;
import '../../services/facebook_automation_service.dart';

// ---------------------------------------------------------------------------
// Facebook Marketplace – Create Vehicle Listing Screen
// ---------------------------------------------------------------------------
// Delegates all automation to FacebookAutomationService, which uses the
// Android AccessibilityService channel (com.pirsumoto/accessibility) with
// a JS shadow-DOM fallback – the same dual-strategy as Yad2Screen.
//
// Automated HTML elements (handled inside FacebookAutomationService):
//   Phase 1  loginGate      – input[type="password"] / "Log in" text detection
//   Phase 2  setViewport    – meta[name=viewport] → width=1280
//   Phase 3  openCategory   – [role="combobox"]:nth(1) click
//   Phase 4  selectVehicle  – [role="option"]:first click ("Vehicles for sale")
//   Phase 5  enterPrice     – input[aria-label*="Price"]
//   Phase 6  enterTitle     – textarea[aria-label*="Description"]
//   Phase 7  selectCondition– [role="radio"] "Used"
//   Phase 8  uploadPhotos   – input[type="file"] via DataTransfer base64
//   Phase 9  publish        – button "Next" → button "Publish"
// ---------------------------------------------------------------------------

const _kFacebookVehicleUrl =
    'https://www.facebook.com/marketplace/create/vehicle';

const _kDesktopUserAgent =
    'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
    '(KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36';

// ---------------------------------------------------------------------------
// Screen
// ---------------------------------------------------------------------------
class FacebookScreen extends StatefulWidget {
  final VehiclePublishData? publishData;

  const FacebookScreen({super.key, this.publishData});

  @override
  State<FacebookScreen> createState() => _FacebookScreenState();
}

class _FacebookScreenState extends State<FacebookScreen> {
  late WebViewController _controller;
  FacebookAutomationService? _service;

  String _statusMessage = 'טוען פייסבוק...';
  bool _automationStarted = false;
  bool _isComplete = false;
  bool _hasError = false;
  bool _isPaused = false;
  bool _showControls = false;
  bool _isLoginRequired = false;

  // Tap marker overlay (logical CSS coordinates)
  double? _tapX;
  double? _tapY;

  @override
  void initState() {
    super.initState();
    WakelockPlus.enable();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

    _controller = WebViewController()
      ..setJavaScriptMode(JavaScriptMode.unrestricted)
      ..setUserAgent(_kDesktopUserAgent)
      ..setNavigationDelegate(
        NavigationDelegate(
          onPageFinished: (url) {
            debugPrint('[FB-Screen] onPageFinished: $url');
            if (!_automationStarted) {
              _automationStarted = true;
              Future.delayed(const Duration(seconds: 2), _startAutomation);
            }
          },
          onWebResourceError: (error) {
            debugPrint('[FB-Screen] WebResourceError: ${error.description}');
          },
        ),
      )
      ..loadRequest(Uri.parse(_kFacebookVehicleUrl));
  }

  @override
  void dispose() {
    _service?.dispose();
    WakelockPlus.disable();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    super.dispose();
  }

  // ── Automation wiring ─────────────────────────────────────────────────────

  Future<void> _startAutomation() async {
    if (!mounted) return;
    setState(() => _statusMessage = 'בודק הרשאת נגישות...');

    // Check if a11y permission is available (Android only)
    final hasPermission = await FacebookAutomationService.checkPermission();
    if (!hasPermission && mounted) {
      _showA11yPermissionDialog();
      return;
    }

    _buildAndStartService();
  }

  void _buildAndStartService() {
    final data = widget.publishData ??
        const VehiclePublishData(
          licenseNumber: '',
          color: '',
          shade: '',
          hand: '',
          currentOwnership: '',
          previousOwnership: '',
          kilometers: '',
          month: '',
          price: '0',
          handicapped: false,
          noTest: false,
          gear: '',
          vehicleCondition: 'טוב',
        );

    _service = FacebookAutomationService(
      formData: data,
      controller: _controller,
      onTapPreview: _showTapMarker,
      onFirstStepDetected: () {
        if (mounted) setState(() => _showControls = true);
      },
      onPhaseComplete: (phase) {
        if (!mounted) return;
        setState(() {
          _statusMessage = phase.descriptionHe;
          _isLoginRequired = false;
          if (phase == FacebookAutomationPhase.loginGate &&
              _service?.isPaused == true) {
            _isLoginRequired = true;
            _statusMessage = 'נא להתחבר לפייסבוק — האוטומציה תמשיך לאחר כניסה';
          }
        });
      },
      onPhaseError: (phase, error) {
        if (!mounted) return;
        setState(() {
          _isPaused = true;
          _showControls = true;
          _statusMessage = 'שגיאה: $error';
        });
        // After 5s collapse the error text and show controls
        Future.delayed(const Duration(seconds: 5), () {
          if (mounted) setState(() => _statusMessage = '');
        });
      },
      onAutomationComplete: (success) {
        if (!mounted) return;
        setState(() {
          _isComplete = true;
          _hasError = !success;
          _statusMessage =
              success ? '✓ המודעה פורסמה בהצלחה!' : 'האוטומציה נכשלה';
        });
      },
    );

    setState(() => _statusMessage = 'מתחיל אוטומציה...');
    _service!.startAutomation();
  }

  void _showA11yPermissionDialog() {
    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('נדרשת הרשאת נגישות', textAlign: TextAlign.right),
        content: const Text(
          'האוטומציה של פייסבוק דורשת הרשאת Accessibility Service. '
          'פתח את ההגדרות, אפשר את ההרשאה לאפליקציה וחזור.',
          textAlign: TextAlign.right,
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              Navigator.of(context).pop();
            },
            child: const Text('ביטול'),
          ),
          TextButton(
            onPressed: () => FacebookAutomationService.openSettings(),
            child: const Text('פתח הגדרות'),
          ),
          ElevatedButton(
            onPressed: () async {
              final navigator = Navigator.of(ctx);
              final messenger = ScaffoldMessenger.of(ctx);
              final ok = await FacebookAutomationService.checkPermission();
              if (ok) {
                navigator.pop();
                _buildAndStartService();
              } else {
                messenger.showSnackBar(
                  const SnackBar(
                    content: Text('עדיין לא ניתנה הרשאה',
                        textAlign: TextAlign.right),
                  ),
                );
              }
            },
            child: const Text('אישרתי'),
          ),
        ],
      ),
    );
  }

  // ── Tap preview marker ────────────────────────────────────────────────────

  void _showTapMarker(double cssX, double cssY) {
    if (!mounted) return;
    setState(() {
      _tapX = cssX;
      _tapY = cssY;
    });
    Future.delayed(const Duration(milliseconds: 700), () {
      if (mounted) setState(() { _tapX = null; _tapY = null; });
    });
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          // WebView
          WebViewWidget(controller: _controller),

          // Status bar overlay
          _buildStatusBar(),

          // Tap preview marker
          if (_tapX != null && _tapY != null)
            Positioned(
              left: _tapX! - 24,
              top: _tapY! - 24,
              child: IgnorePointer(
                child: Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: const Color(0x501877F2),
                    border: Border.all(
                        color: const Color(0xFF1877F2), width: 2.5),
                  ),
                  child: const Icon(Icons.touch_app,
                      color: Color(0xFF1877F2), size: 22),
                ),
              ),
            ),

          // Pause / Resume control button
          if (_showControls && !_isComplete && !_hasError)
            Positioned(
              top: MediaQuery.of(context).padding.top + 16,
              left: 16,
              child: ElevatedButton(
                style: ElevatedButton.styleFrom(
                  backgroundColor: _isPaused
                      ? const Color(0xFF1B5E20)
                      : const Color(0xFFE65100),
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(
                      horizontal: 18, vertical: 12),
                  shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(30)),
                  elevation: 6,
                ),
                onPressed: () {
                  if (_isPaused) {
                    _service?.resumeAutomation();
                    setState(() {
                      _isPaused = false;
                      _statusMessage = 'ממשיך אוטומציה...';
                    });
                  } else {
                    _service?.pauseAutomation();
                    setState(() {
                      _isPaused = true;
                      _statusMessage = 'אוטומציה מושהית — לחץ המשך';
                    });
                  }
                },
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(_isPaused ? Icons.play_arrow : Icons.pause, size: 18),
                    const SizedBox(width: 8),
                    Text(_isPaused ? 'המשך' : 'הפסק',
                        style: const TextStyle(
                            fontWeight: FontWeight.bold, fontSize: 15)),
                  ],
                ),
              ),
            ),

          // Step-back + Exit buttons when paused
          if (_showControls && _isPaused && !_isComplete)
            Positioned(
              top: MediaQuery.of(context).padding.top + 16,
              right: 16,
              child: Row(
                children: [
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFC62828),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 18, vertical: 12),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(30)),
                      elevation: 6,
                    ),
                    onPressed: () =>
                        Navigator.of(context).popUntil((r) => r.isFirst),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.home, size: 18),
                        SizedBox(width: 8),
                        Text('סיים',
                            style: TextStyle(
                                fontWeight: FontWeight.bold, fontSize: 15)),
                      ],
                    ),
                  ),
                  const SizedBox(width: 12),
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF1877F2),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                          horizontal: 18, vertical: 12),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(30)),
                      elevation: 6,
                    ),
                    onPressed: () {
                      _service?.stepBack();
                      _service?.resumeAutomation();
                      setState(() {
                        _isPaused = false;
                        _statusMessage = 'ממשיך אוטומציה...';
                      });
                    },
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.replay, size: 18),
                        SizedBox(width: 8),
                        Text('צעד אחורה',
                            style: TextStyle(
                                fontWeight: FontWeight.bold, fontSize: 15)),
                      ],
                    ),
                  ),
                ],
              ),
            ),

          // Done / Error home button
          if (_isComplete || _hasError)
            Positioned(
              bottom: MediaQuery.of(context).padding.bottom + 24,
              left: 0,
              right: 0,
              child: Center(
                child: ElevatedButton.icon(
                  icon: const Icon(Icons.home),
                  label: const Text('חזור לדף הבית'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: _hasError
                        ? const Color(0xFFC62828)
                        : const Color(0xFF1877F2),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(
                        horizontal: 32, vertical: 14),
                    shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(30)),
                    elevation: 6,
                  ),
                  onPressed: () =>
                      Navigator.of(context).popUntil((r) => r.isFirst),
                ),
              ),
            ),
        ],
      ),
    );
  }

  // ── Status bar ────────────────────────────────────────────────────────────

  Widget _buildStatusBar() {
    if (_statusMessage.isEmpty) return const SizedBox.shrink();

    Color bg;
    IconData icon;
    if (_isComplete && !_hasError) {
      bg = const Color(0xCC1B5E20);
      icon = Icons.check_circle;
    } else if (_hasError) {
      bg = const Color(0xCCB71C1C);
      icon = Icons.error;
    } else if (_isLoginRequired) {
      bg = const Color(0xCCE65100);
      icon = Icons.lock;
    } else if (_isPaused) {
      bg = const Color(0xCC37474F);
      icon = Icons.pause_circle;
    } else {
      bg = const Color(0xCC1877F2); // Facebook blue
      icon = Icons.autorenew;
    }

    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: Container(
        padding: EdgeInsets.fromLTRB(
          16,
          MediaQuery.of(context).padding.top + 12,
          16,
          12,
        ),
        color: bg,
        child: Row(
          children: [
            Icon(icon, color: Colors.white, size: 20),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                _statusMessage,
                style:
                    const TextStyle(color: Colors.white, fontSize: 14),
                textAlign: TextAlign.right,
              ),
            ),
            if (_isComplete || _hasError)
              TextButton(
                onPressed: () => Navigator.of(context).pop(),
                child: const Text('סגור',
                    style: TextStyle(color: Colors.white)),
              ),
          ],
        ),
      ),
    );
  }
}
