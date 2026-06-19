import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:permission_handler/permission_handler.dart';
import '../../services/ocr_service.dart';
import '../../services/ui_context.dart';
import '../../services/yad2_automation_service.dart';
import '../../services/yad2_automation_gemma_service.dart';
import '../../services/yad2_accessibility_automation_service.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:image_picker/image_picker.dart';

// Shadow AxTree extractor injected into the WebView on each observe() call.
// Uses webview_flutter's JS channel: window.updateShadowTree.postMessage(json).
const _kShadowExtractorJs = '''
(function() {
  var seen = {};
  var tree = [];

  function getAllElements(root) {
    var all = [];
    if (!root) return all;
    var elements = root.querySelectorAll('*');
    for (var i = 0; i < elements.length; i++) {
      var el = elements[i];
      all.push(el);
      if (el.shadowRoot) {
        all = all.concat(getAllElements(el.shadowRoot));
      }
    }
    return all;
  }

  var all = getAllElements(document);

  for (var i = 0; i < all.length; i++) {
    var el = all[i];
    var rect = el.getBoundingClientRect();
    if (rect.width === 0 || rect.height === 0) continue;

    // Detect interactivity: semantic tags + tabindex + cursor:pointer (React)
    var tag = el.tagName.toLowerCase();
    var role = el.getAttribute('role') || '';
    var isSemanticTag = tag === 'button' || tag === 'input' || tag === 'select'
                     || tag === 'a'      || tag === 'textarea';
    var isAriaRole = role === 'button' || role === 'option' || role === 'menuitem'
                  || role === 'tab'    || role === 'checkbox' || role === 'radio'
                  || role === 'textbox' || role === 'combobox' || role === 'search';
    var hasTabIndex = el.getAttribute('tabindex') !== null;
    var isPointer   = window.getComputedStyle(el).cursor === 'pointer';

    if (!isSemanticTag && !isAriaRole && !hasTabIndex && !isPointer) continue;

    // Prefer aria-label > placeholder > title > innerText (normalise whitespace)
    var raw = el.getAttribute('aria-label')
            || el.getAttribute('placeholder')
            || el.placeholder
            || el.getAttribute('title')
            || (el.innerText || '');
    var label = raw.trim().replace(/\\s+/g, ' ').substring(0, 50);
    
    if (!label) {
      if (isSemanticTag) {
        label = el.placeholder || el.name || el.id || '';
      } else {
        continue;
      }
    }

    var valText = el.value || '';
    if (!valText && el.innerText) {
      var inner = el.innerText.trim().replace(/\\s+/g, ' ');
      if (inner !== label) {
        valText = inner;
      }
    }

    // Deduplicate by label+position
    var key = label + '|' + Math.round(rect.left) + '|' + Math.round(rect.top);
    if (seen[key]) continue;
    seen[key] = true;

    tree.push({
      id: el.id || null,
      role: role || el.type || tag,
      label: label,
      value: valText || null,
      x: Math.round(rect.left + rect.width / 2),
      y: Math.round(rect.top + rect.height / 2),
      visible: rect.bottom > 0 && rect.top < window.innerHeight
            && rect.right > 0 && rect.left < window.innerWidth
    });
  }

  window.updateShadowTree.postMessage(JSON.stringify({
    elements: tree,
    scrollX: window.scrollX,
    scrollY: window.scrollY,
    scale: window.devicePixelRatio
  }));
})();
''';

class Yad2Screen extends StatefulWidget {
  final VehiclePublishData publishData;
  final bool useGemmaAutomation;

  const Yad2Screen({
    super.key,
    required this.publishData,
    this.useGemmaAutomation = false,
  });

  @override
  State<Yad2Screen> createState() => _Yad2ScreenState();
}

class _Yad2ScreenState extends State<Yad2Screen> {
  late WebViewController _controller;
  final GlobalKey _webViewKey = GlobalKey();
  dynamic
  _automationService; // Can be Yad2AutomationService or Yad2AccessibilityAutomationService
  String _statusMessage = 'טוען...';
  bool _automationStarted = false;
  bool _automationComplete = false;
  bool _automationError = false;
  bool _showPauseButton = false;
  bool _isPaused = false;

  // Tap preview marker — CSS coordinates, null when hidden
  double? _tapMarkerX;
  double? _tapMarkerY;

  // Shadow AxTree — completed by the JS channel on each observe() call
  Completer<Map<String, dynamic>>? _axTreeCompleter;

  @override
  void initState() {
    super.initState();
    // Hide status bar + Android soft navigation bar for a full-screen WebView.
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    _controller =
        WebViewController()
          ..setJavaScriptMode(JavaScriptMode.unrestricted)
          ..addJavaScriptChannel(
            'updateShadowTree',
            onMessageReceived: (JavaScriptMessage msg) {
              try {
                final data = jsonDecode(msg.message) as Map<String, dynamic>;
                final completer = _axTreeCompleter;
                if (completer != null && !completer.isCompleted) {
                  completer.complete(data);
                }
              } catch (e) {
                debugPrint('[Yad2Screen] AxTree parse error: $e');
              }
            },
          )
          ..setNavigationDelegate(
            NavigationDelegate(
              onPageFinished: (url) {
                if (!_automationStarted) {
                  _automationStarted = true;
                  Future.delayed(const Duration(seconds: 2), _startAutomation);
                }
              },
            ),
          )
          ..loadRequest(
            //Uri.parse('https://www.yad2.co.il/publish-ad?cat=vehicles'),
            Uri.parse(
              'https://plus.yad2.co.il/publish-ad?cat=vehicles&subCat=cars&isTrader=true&skipCache=true',
            ),
          );

    if (_controller.platform is AndroidWebViewController) {
      (_controller.platform as AndroidWebViewController).setOnShowFileSelector((
        FileSelectorParams params,
      ) async {
        debugPrint(
          '[Yad2Screen] WebView requested file selector: ${params.mode}',
        );
        final picker = ImagePicker();

        if (params.mode == FileSelectorMode.openMultiple) {
          final List<XFile> images = await picker.pickMultiImage();
          return images.map((e) => Uri.file(e.path).toString()).toList();
        } else {
          final XFile? image = await picker.pickImage(
            source: ImageSource.gallery,
          );
          if (image != null) {
            return [Uri.file(image.path).toString()];
          }
        }
        return [];
      });
    }
  }

  @override
  void dispose() {
    _automationService?.dispose();
    WakelockPlus.disable(); // Ensure screen can sleep when leaving the automation screen
    // Restore normal system UI when navigating away.
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    super.dispose();
  }

  Future<Uint8List?> _captureWebViewScreenshot() async {
    try {
      final boundary =
          _webViewKey.currentContext?.findRenderObject()
              as RenderRepaintBoundary?;
      if (boundary == null) return null;

      final image = await boundary.toImage(
        pixelRatio: MediaQuery.of(context).devicePixelRatio,
      );
      final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
      return byteData?.buffer.asUint8List();
    } catch (e) {
      debugPrint('[Yad2Screen] Screenshot error: $e');
      return null;
    }
  }

  /// Captures a screenshot + injects the Shadow AxTree extractor concurrently,
  /// returning a [UIContext] with both pieces of data for the automation service.
  Future<UIContext?> _observeUI() async {
    // Set up the completer before injecting JS so the callback can never beat us.
    _axTreeCompleter = Completer<Map<String, dynamic>>();

    // Fire both operations in parallel.
    final screenshotFuture = _captureWebViewScreenshot();
    await _controller.runJavaScript(_kShadowExtractorJs);

    // Wait for ax tree (2 s timeout — graceful degradation to OCR-only).
    Map<String, dynamic>? axData;
    try {
      axData = await _axTreeCompleter!.future.timeout(
        const Duration(seconds: 2),
      );
    } catch (_) {
      debugPrint('[Yad2Screen] AxTree timeout — continuing without ax tree');
    }
    _axTreeCompleter = null;

    final screenshot = await screenshotFuture;
    if (screenshot == null) return null;

    final elements =
        (axData?['elements'] as List? ?? [])
            .map((e) => AxElement.fromJson(e as Map<String, dynamic>))
            .toList();

    debugPrint('[Yad2Screen] 🌳 AxTree: ${elements.length} elements captured');

    return UIContext(
      screenshot: screenshot,
      axTree: elements,
      viewport: ViewportState(
        scrollX: (axData?['scrollX'] as num?)?.toDouble() ?? 0,
        scrollY: (axData?['scrollY'] as num?)?.toDouble() ?? 0,
        scale: (axData?['scale'] as num?)?.toDouble() ?? 1,
      ),
    );
  }

  void _showTapMarker(double cssX, double cssY) {
    if (!mounted) return;
    // CSS px → physical screen px (multiply by devicePixelRatio, then divide
    // back for Flutter logical pixels — net result is identity since Flutter
    // layout uses logical px which equals CSS px on Android WebView)
    setState(() {
      _tapMarkerX = cssX;
      _tapMarkerY = cssY;
    });
    // Auto-hide after 700ms (200ms after the actual click fires)
    Future.delayed(const Duration(milliseconds: 700), () {
      if (mounted)
        setState(() {
          _tapMarkerX = null;
          _tapMarkerY = null;
        });
    });
  }

  Future<void> _startAutomation() async {
    setState(() => _statusMessage = 'בודק הרשאות שמע...');
    try {
      if (await Permission.notification.status.isDenied) {
        await Permission.notification.request();
      }
      if (Platform.isAndroid) {
        if (await Permission.audio.status.isDenied) {
          await Permission.audio.request();
        }
      }
    } catch (e) {
      debugPrint('[Yad2Screen] Error requesting audio permissions: $e');
    }

    final ocrService = OcrService();
    final devicePixelRatio = MediaQuery.of(context).devicePixelRatio;

    if (widget.useGemmaAutomation) {
      if (Platform.isAndroid) {
        await _checkA11yAndStart(devicePixelRatio, ocrService);
      } else {
        _startAutomationService(devicePixelRatio, ocrService);
      }
    } else {
      _startAutomationService(devicePixelRatio, ocrService);
    }
  }

  void _startAutomationService(double devicePixelRatio, OcrService ocrService) {
    if (widget.useGemmaAutomation) {
      _automationService = Yad2AccessibilityAutomationService(
        formData: widget.publishData,
        controller: _controller,
        onTapPreview: _showTapMarker,
        onPhaseComplete: (phase) {
          if (mounted) setState(() => _statusMessage = phase.description);
        },
        onPhaseError: (phase, error) {
          if (mounted) {
            setState(() {
              _isPaused = true;
              _showPauseButton = false;
              _statusMessage = 'שגיאה: $error';
            });
            Future.delayed(const Duration(seconds: 5), () {
              if (mounted) {
                setState(() {
                  _statusMessage = '';
                  _showPauseButton = true;
                });
              }
            });
          }
        },
        onAutomationComplete: (success) {
          if (mounted) {
            setState(() {
              _automationComplete = true;
              _automationError = !success;
              _statusMessage =
                  success ? 'האוטומציה הושלמה בהצלחה!' : 'האוטומציה נכשלה';
            });
          }
        },
        onFirstStepDetected: () {
          if (mounted) {
            setState(() {
              _showPauseButton = true;
            });
          }
        },
      );
    } else {
      _automationService = Yad2AutomationService(
        controller: _controller,
        ocrService: ocrService,
        formData: widget.publishData,
        devicePixelRatio: devicePixelRatio,
        observeUI: _observeUI,
        onTapPreview: _showTapMarker,
        onPhaseComplete: (phase) {
          if (mounted) setState(() => _statusMessage = phase.description);
        },
        onOcrFallback: () {
          if (mounted) {
            ScaffoldMessenger.of(context).hideCurrentSnackBar();
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text(
                  '🔄 שים לב: המערכת משתמשת בזיהוי תמונה (OCR) לשלב זה',
                  textAlign: TextAlign.right,
                  style: TextStyle(
                    fontFamily: 'Inter',
                    fontWeight: FontWeight.bold,
                  ),
                ),
                backgroundColor: Colors.orange,
                duration: Duration(seconds: 2),
              ),
            );
          }
        },
        onPhaseError: (phase, error) {
          if (mounted) {
            setState(() {
              _isPaused = true;
              _showPauseButton = false;
              _statusMessage = 'שגיאה: $error';
            });
            Future.delayed(const Duration(seconds: 5), () {
              if (mounted) {
                setState(() {
                  _statusMessage = '';
                  _showPauseButton = true;
                });
              }
            });
          }
        },
        onAutomationComplete: (success) {
          if (mounted) {
            setState(() {
              _automationComplete = true;
              _automationError = !success;
              _statusMessage =
                  success ? 'האוטומציה הושלמה בהצלחה!' : 'האוטומציה נכשלה';
            });
          }
        },
        onFirstStepDetected: () {
          if (mounted) {
            setState(() {
              _showPauseButton = true;
            });
          }
        },
      );
    }
    setState(() => _statusMessage = 'מתחיל אוטומציה...');
    _automationService!.startAutomation();
  }

  Future<void> _checkA11yAndStart(
    double devicePixelRatio,
    OcrService ocrService,
  ) async {
    final hasPermission =
        await Yad2AccessibilityAutomationService.checkPermission();
    if (!hasPermission) {
      if (!mounted) return;
      showDialog(
        context: context,
        barrierDismissible: false,
        builder:
            (ctx) => AlertDialog(
              title: const Text(
                'נדרשת הרשאת נגישות',
                textAlign: TextAlign.right,
              ),
              content: const Text(
                'כדי שהאוטומציה תפעל, עליך לאפשר הרשאת נגישות (Accessibility) לאפליקציה במסך ההגדרות של המכשיר. לאחר מתן ההרשאה חזור לכאן ולחץ על "אישרתי".',
                textAlign: TextAlign.right,
              ),
              actions: [
                TextButton(
                  onPressed: () {
                    Navigator.of(ctx).pop();
                    Navigator.of(context).pop(); // Exit screen
                  },
                  child: const Text('ביטול'),
                ),
                TextButton(
                  onPressed: () {
                    Yad2AccessibilityAutomationService.openSettings();
                  },
                  child: const Text('פתח הגדרות'),
                ),
                ElevatedButton(
                  onPressed: () async {
                    final checkAgain =
                        await Yad2AccessibilityAutomationService.checkPermission();
                    if (checkAgain) {
                      Navigator.of(ctx).pop();
                      _startAutomationService(devicePixelRatio, ocrService);
                    } else {
                      ScaffoldMessenger.of(ctx).showSnackBar(
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
    } else {
      _startAutomationService(devicePixelRatio, ocrService);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: Stack(
        children: [
          RepaintBoundary(
            key: _webViewKey,
            child: WebViewWidget(controller: _controller),
          ),
          _buildStatusOverlay(),
          // Tap preview marker
          if (_tapMarkerX != null && _tapMarkerY != null)
            Positioned(
              left: _tapMarkerX! - 24,
              top: _tapMarkerY! - 24,
              child: IgnorePointer(
                child: Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: Colors.red.withAlpha(80),
                    border: Border.all(color: Colors.red, width: 2.5),
                  ),
                  child: const Icon(
                    Icons.touch_app,
                    color: Colors.red,
                    size: 22,
                  ),
                ),
              ),
            ),
          if (_showPauseButton)
            Positioned(
              top: MediaQuery.of(context).padding.top + 4,
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
                onPressed: () {
                  if (_isPaused) {
                    _automationService?.resumeAutomation();
                    setState(() {
                      _isPaused = false;
                      _statusMessage = 'ממשיך אוטומציה...';
                    });
                  } else {
                    _automationService?.pauseAutomation();
                    setState(() {
                      _isPaused = true;
                      _statusMessage =
                          'האוטומציה מושהית. לחץ על המשך כדי לחזור';
                    });
                  }
                },
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(_isPaused ? Icons.play_arrow : Icons.pause, size: 18),
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
          if (_showPauseButton && _isPaused)
            Positioned(
              top: MediaQuery.of(context).padding.top + 4,
              right: 16,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ElevatedButton(
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(
                        0xFFC62828,
                      ), // Premium red color for exit
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
                      Navigator.of(context).popUntil((route) => route.isFirst);
                    },
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
                      backgroundColor: const Color(
                        0xFF3B5BDB,
                      ), // Premium brand blue
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
                      _automationService?.stepBack();
                      _automationService?.resumeAutomation();
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
        ],
      ),
    );
  }

  Widget _buildStatusOverlay() {
    if (_statusMessage.isEmpty) {
      return const SizedBox.shrink();
    }

    Color bgColor = const Color(0xCC1E293B);
    IconData icon = Icons.autorenew;
    Color iconColor = Colors.white;

    if (_automationComplete && !_automationError) {
      bgColor = const Color(0xCC1B5E20);
      icon = Icons.check_circle;
      iconColor = Colors.greenAccent;
    } else if (_automationError) {
      bgColor = const Color(0xCCB71C1C);
      icon = Icons.error;
      iconColor = Colors.redAccent;
    }

    return Positioned(
      top: 0,
      left: 0,
      right: 0,
      child: Container(
        padding: EdgeInsets.fromLTRB(
          12,
          MediaQuery.of(context).padding.top + 6,
          12,
          6,
        ),
        color: bgColor,
        child: Row(
          children: [
            if (_automationComplete)
              Icon(icon, color: iconColor, size: 16)
            else
              const SizedBox(width: 16, height: 16),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                _statusMessage,
                style: const TextStyle(color: Colors.white, fontSize: 12),
                textAlign: TextAlign.right,
              ),
            ),
            if (_automationComplete)
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
    );
  }
}
