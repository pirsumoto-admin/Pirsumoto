import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import '../../services/automation_webview_session.dart';
import '../../services/yad2_automation_service.dart' show VehiclePublishData;
import '../../services/facebook_automation_service.dart';
// [WHATSAPP-DISABLED] WhatsApp text validation import disabled in facebook_screen.
// import '../../services/whatsapp_text_validation_service.dart';
import '../../services/db_service.dart';
import '../settings/preset_login_dialog.dart';
import '../../remote_control/firebase_chat_receiver.dart';

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
//   Phase 8  uploadPhotos   – accessibility tap and Android native file chooser
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
  // [WHATSAPP-DISABLED] startedFromWhatsApp and whatsAppSenderKey disabled.
  // final bool startedFromWhatsApp;
  // final String? whatsAppSenderKey;

  const FacebookScreen({
    super.key,
    this.publishData,
    // this.startedFromWhatsApp = false,
    // this.whatsAppSenderKey,
  });

  @override
  State<FacebookScreen> createState() => _FacebookScreenState();
}

class _FacebookScreenState extends State<FacebookScreen> {
  late WebViewController _controller;
  AutomationWebViewSession? _browserSession;
  bool _webViewVisible = false;
  bool _webViewClosed = false;
  Future<void>? _browserInitialization;
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

  bool _publicationStopped = false;
  bool _publicationPaused = false;
  bool _finishing = false;

  @override
  void initState() {
    super.initState();
    FirebaseChatReceiver.bindControls(
      widget.publishData?.publicationIdentity,
      this,
      pause: () async {
        _publicationPaused = true;
        await _service?.pauseAndWait();
        if (mounted) setState(() => _isPaused = true);
      },
      resume: () {
        _publicationPaused = false;
        if (_publicationStopped || _webViewClosed) return;
        _service?.resumeAutomation();
        if (mounted) setState(() => _isPaused = false);
      },
      stop: () async {
        _publicationStopped = true;
        await _closeBrowser();
        if (mounted)
          setState(() {
            _isPaused = true;
            _statusMessage = 'הפרסום בוטל';
          });
      },
    );
    WakelockPlus.enable();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);

    _browserInitialization = _initializeBrowser();
  }

  Future<void> _initializeBrowser() async {
    try {
      _browserSession = await AutomationWebViewSession.open(
        isCurrent:
            () =>
                mounted &&
                !_publicationStopped &&
                !_webViewClosed &&
                FirebaseChatReceiver.isCurrent(
                  widget.publishData?.publicationIdentity,
                ),
        stop: _stopBrowserAutomation,
        detach: _detachBrowser,
        configure: _configureBrowser,
      );
      if (mounted && _browserSession != null && !_webViewClosed) {
        setState(() => _webViewVisible = true);
      }
    } catch (error) {
      debugPrint('[AutomationWebView] Startup failed: $error');
      if (mounted) {
        setState(() {
          _hasError = true;
          _statusMessage =
              'לא ניתן לפתוח דפדפן חדש. יש לסגור את מסך הפרסום ולנסות שוב.';
        });
      }
    }
  }

  Future<void> _stopBrowserAutomation() async {
    _webViewClosed = true;
    await _service?.stopAndWait();
    _service?.dispose();
  }

  Future<void> _detachBrowser() async {
    if (mounted) {
      setState(() {
        _webViewVisible = false;
        _showControls = false;
        _isLoginRequired = false;
      });
    }
    // Let Flutter remove the platform view before native WebView.destroy().
    await WidgetsBinding.instance.endOfFrame;
  }

  Future<void> _closeBrowser() async {
    _webViewClosed = true;
    await _browserInitialization;
    await _browserSession?.close();
  }

  Future<void> _configureBrowser(WebViewController controller) async {
    _controller = controller;
    await _controller.setUserAgent(_kDesktopUserAgent);
    await _controller.setNavigationDelegate(
      NavigationDelegate(
        onPageFinished: (url) {
          if (!mounted ||
              _webViewClosed ||
              _publicationStopped ||
              url == 'about:blank') {
            return;
          }
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
    );
    // Install before navigation: a native tap opens WebChromeClient's chooser,
    // which must return the automation's file URIs to the page.
    final platform = _controller.platform;
    if (platform is AndroidWebViewController) {
      await platform.setOnShowFileSelector((params) async {
        if (_webViewClosed || _publicationStopped || _publicationPaused) {
          return const <String>[];
        }
        debugPrint('[FB-Screen] Native file chooser requested: ${params.mode}');
        return _service?.handleNativeImageChooser(
              allowMultiple: params.mode == FileSelectorMode.openMultiple,
            ) ??
            const <String>[];
      });
    }
    await _controller.loadRequest(Uri.parse(_kFacebookVehicleUrl));
  }

  @override
  void dispose() {
    _webViewClosed = true;
    FirebaseChatReceiver.unbindControls(this);
    _browserSession?.closeInBackground();
    _service?.dispose();
    WakelockPlus.disable();
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    super.dispose();
  }

  // ── Automation wiring ─────────────────────────────────────────────────────

  Future<void> _startAutomation() async {
    if (!mounted ||
        _webViewClosed ||
        _publicationStopped ||
        !FirebaseChatReceiver.isCurrent(
          widget.publishData?.publicationIdentity,
        ))
      return;
    setState(() => _statusMessage = 'בודק הרשאת נגישות...');

    // Check if a11y permission is available (Android only)
    final hasPermission = await FacebookAutomationService.checkPermission();
    if (!mounted || _webViewClosed || _publicationStopped) return;
    if (!hasPermission && mounted) {
      FirebaseChatReceiver.reportAutomationStatus(
        identity: widget.publishData?.publicationIdentity,
        statusType: 'stuck',
        text: 'נדרשת הרשאת נגישות',
      );
      _showA11yPermissionDialog();
      return;
    }

    _buildAndStartService();
  }

  void _buildAndStartService() {
    if (!mounted ||
        _webViewClosed ||
        _publicationStopped ||
        !FirebaseChatReceiver.isCurrent(
          widget.publishData?.publicationIdentity,
        ))
      return;
    final data =
        widget.publishData ??
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
        FirebaseChatReceiver.reportAutomationStatus(
          identity: widget.publishData?.publicationIdentity,
          statusType: 'stuck',
          text:
              '⚠️ האוטומציה בפייסבוק נתקעה בשלב "${phase.descriptionHe}": $error',
        );
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
      onAutomationComplete: _finishAutomation,
    );

    setState(() => _statusMessage = 'מתחיל אוטומציה...');
    FirebaseChatReceiver.reportAutomationStatus(
      identity: widget.publishData?.publicationIdentity,
      statusType: 'step',
      text: '🚀 מתחיל פרסום בפייסבוק מרקטפלייס...',
    );
    if (_publicationPaused) _service!.pauseAutomation();
    _service!.startAutomation();
  }

  Future<void> _finishAutomation(bool success) async {
    if (_finishing) return;
    _finishing = true;
    await _closeBrowser();
    if (success && widget.publishData != null) {
      unawaited(DBService().saveListingFromPublishData(
        widget.publishData!, platform: 'facebook',
      ));
    }
    if (mounted) {
      setState(() {
        _isComplete = true;
        _hasError = !success;
        _statusMessage = success ? '✓ המודעה פורסמה בהצלחה!' : 'האוטומציה נכשלה';
      });
      // Commit PopScope before navigating, and navigate before reporting the
      // terminal status, which can immediately launch the next queued vehicle.
      await WidgetsBinding.instance.endOfFrame;
      if (mounted) {
        Navigator.of(context).popUntil((route) => route.isFirst);
      }
    }
    await FirebaseChatReceiver.reportAutomationStatus(
      identity: widget.publishData?.publicationIdentity,
      statusType: success ? 'platform_completed' : 'stuck',
      platform: success ? 'facebook' : null,
      text: success
          ? '🎉 הפרסום בפייסבוק מרקטפלייס הושלם בהצלחה!'
          : '⚠️ האוטומציה בפייסבוק נכשלה',
    );
  }

  void _showA11yPermissionDialog() {
    if (!mounted) return;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder:
          (ctx) => AlertDialog(
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
                        content: Text(
                          'עדיין לא ניתנה הרשאה',
                          textAlign: TextAlign.right,
                        ),
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
      if (mounted)
        setState(() {
          _tapX = null;
          _tapY = null;
        });
    });
  }

  // ── Build ─────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: _isComplete || _hasError,
      onPopInvokedWithResult: (didPop, result) {
        if (didPop) return;
        debugPrint(
          '[FB-Screen] Back navigation prevented during active automation',
        );
      },
      child: Scaffold(
        body: Stack(
          children: [
            // WebView
            if (_webViewVisible) WebViewWidget(controller: _controller),

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
                        color: const Color(0xFF1877F2),
                        width: 2.5,
                      ),
                    ),
                    child: const Icon(
                      Icons.touch_app,
                      color: Color(0xFF1877F2),
                      size: 22,
                    ),
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
                    backgroundColor:
                        _isPaused
                            ? const Color(0xFF1B5E20)
                            : const Color(0xFFE65100),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 18,
                      vertical: 12,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(30),
                    ),
                    elevation: 6,
                  ),
                  onPressed: () async {
                    final identity = widget.publishData?.publicationIdentity;
                    if (identity != null) {
                      await FirebaseChatReceiver.setLocalPaused(
                        identity,
                        !_isPaused,
                      );
                      return;
                    }
                    if (_isPaused) {
                      _service?.resumeAutomation();
                      setState(() {
                        _isPaused = false;
                        _statusMessage = 'ממשיך אוטומציה...';
                      });
                      FirebaseChatReceiver.reportAutomationStatus(
                        identity: widget.publishData?.publicationIdentity,
                        statusType: 'publishing',
                        text: '▶️ ממשיך אוטומציה בפייסבוק...',
                      );
                    } else {
                      _service?.pauseAutomation();
                      setState(() {
                        _isPaused = true;
                        _statusMessage = 'אוטומציה מושהית — לחץ המשך';
                      });
                      FirebaseChatReceiver.reportAutomationStatus(
                        identity: widget.publishData?.publicationIdentity,
                        statusType: 'paused',
                        text:
                            '🛑 האוטומציה בפייסבוק הופסקה (הושהתה) על ידי המשתמש',
                      );
                    }
                  },
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        _isPaused ? Icons.play_arrow : Icons.pause,
                        size: 18,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        _isPaused ? 'המשך' : 'הפסק',
                        style: const TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 15,
                        ),
                      ),
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
                          horizontal: 18,
                          vertical: 12,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(30),
                        ),
                        elevation: 6,
                      ),
                      onPressed:
                          () =>
                              Navigator.of(context).popUntil((r) => r.isFirst),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.home, size: 18),
                          SizedBox(width: 8),
                          Text(
                            'סיים',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 15,
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF1877F2),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 18,
                          vertical: 12,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(30),
                        ),
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
                          Text(
                            'צעד אחורה',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              fontSize: 15,
                            ),
                          ),
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
                      backgroundColor:
                          _hasError
                              ? const Color(0xFFC62828)
                              : const Color(0xFF1877F2),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 32,
                        vertical: 14,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(30),
                      ),
                      elevation: 6,
                    ),
                    onPressed:
                        () => Navigator.of(context).popUntil((r) => r.isFirst),
                  ),
                ),
              ),
            // Floating Button to Setup Credentials / Preset Login Dialog
            if (_isLoginRequired && !_isComplete && !_hasError)
              Positioned(
                bottom: 24,
                left: 20,
                right: 20,
                child: SafeArea(
                  child: Center(
                    child: Container(
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          colors: [Color(0xFF1877F2), Color(0xFF3B5BDB)],
                          begin: Alignment.topLeft,
                          end: Alignment.bottomRight,
                        ),
                        borderRadius: BorderRadius.circular(30),
                        boxShadow: [
                          BoxShadow(
                            color: const Color(
                              0xFF1877F2,
                            ).withValues(alpha: 0.45),
                            blurRadius: 14,
                            offset: const Offset(0, 4),
                          ),
                        ],
                      ),
                      child: Material(
                        color: Colors.transparent,
                        child: InkWell(
                          borderRadius: BorderRadius.circular(30),
                          onTap: () async {
                            final shouldReload = await showPresetLoginDialog(
                              context,
                              isFromWebView: true,
                            );
                            if (mounted &&
                                !_webViewClosed &&
                                shouldReload == true) {
                              try {
                                await _controller.reload();
                              } catch (_) {}
                            }
                          },
                          child: const Padding(
                            padding: EdgeInsets.symmetric(
                              horizontal: 22,
                              vertical: 13,
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Icon(
                                  Icons.vpn_key_rounded,
                                  color: Colors.white,
                                  size: 20,
                                ),
                                SizedBox(width: 10),
                                Text(
                                  'התחברות מראש לאתרים',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 15,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
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
      child: IgnorePointer(
        ignoring: !_isComplete && !_hasError,
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
                  style: const TextStyle(color: Colors.white, fontSize: 14),
                  textAlign: TextAlign.right,
                ),
              ),
              if (_isComplete || _hasError)
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: const Text(
                    'סגור',
                    style: TextStyle(color: Colors.white),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
