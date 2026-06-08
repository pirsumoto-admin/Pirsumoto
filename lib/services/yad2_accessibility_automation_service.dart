import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter/gestures.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:audioplayers/audioplayers.dart';
import 'yad2_automation_service.dart' show VehiclePublishData, AutomationPhase;

import 'package:webview_flutter/webview_flutter.dart';

class Yad2AccessibilityAutomationService {
  final VehiclePublishData formData;
  final WebViewController controller;

  final void Function(AutomationPhase phase)? onPhaseComplete;
  final void Function(AutomationPhase phase, String error)? onPhaseError;
  final void Function(bool success)? onAutomationComplete;
  final VoidCallback? onFirstStepDetected;
  final void Function(double cssX, double cssY)? onTapPreview;

  static const int _maxRetries = 3;
  int _phaseRetryCount = 0;
  bool _isPaused = false;
  AutomationPhase? _pausedPhase;
  AutomationPhase? _currentPhase;

  // The MethodChannel name to communicate with the Android AccessibilityService
  static const MethodChannel _channel = MethodChannel(
    'com.pirsumoto/accessibility',
  );

  static Future<bool> checkPermission() async {
    try {
      if (Platform.isAndroid) {
        final bool? hasPermission = await _channel.invokeMethod<bool>(
          'checkPermission',
        );
        return hasPermission ?? false;
      }
      return true;
    } catch (e) {
      return false;
    }
  }

  static Future<void> openSettings() async {
    try {
      if (Platform.isAndroid) {
        await _channel.invokeMethod('openSettings');
      }
    } catch (e) {
      debugPrint('Error opening settings: $e');
    }
  }

  bool get isPaused => _isPaused;
  AutomationPhase? get pausedPhase => _pausedPhase;

  Yad2AccessibilityAutomationService({
    required this.formData,
    required this.controller,
    this.onPhaseComplete,
    this.onPhaseError,
    this.onAutomationComplete,
    this.onFirstStepDetected,
    this.onTapPreview,
  });

  void dispose() {
    _isPaused = true;
    _currentPhase = null;
    _pausedPhase = null;
  }

  void pauseAutomation() {
    debugPrint('[Yad2-A11y] ⏸️ Pause requested');
    _isPaused = true;
  }

  void resumeAutomation() {
    debugPrint('[Yad2-A11y] ▶️ Resume requested');
    if (!_isPaused) return;
    _isPaused = false;

    final phaseToResume = _pausedPhase ?? _currentPhase;
    if (phaseToResume != null) {
      _pausedPhase = null;
      _processPhase(phaseToResume);
    }
  }

  void stepBack() {
    final current = _pausedPhase ?? _currentPhase;
    if (current == null) return;
    final currentIndex = current.index;
    if (currentIndex > 0) {
      final prev = AutomationPhase.values[currentIndex - 1];
      debugPrint(
        '[Yad2-A11y] ↩️ Stepping back from ${current.name} to ${prev.name}',
      );
      _pausedPhase = prev;
      _currentPhase = prev;
    }
  }

  void startAutomation() {
    debugPrint('[Yad2-A11y] 🚀 Starting Accessibility automation');
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    WakelockPlus.enable();
    _processPhase(AutomationPhase.phase1);
  }

  void _processPhase(AutomationPhase phase) {
    _currentPhase = phase;
    _phaseRetryCount = 0;
    if (_isPaused) {
      _pausedPhase = phase;
      debugPrint('[Yad2-A11y] ⏸️ Automation paused at phase: ${phase.name}');
      return;
    }
    _executePhase(phase);
  }

  Future<void> _executePhase(AutomationPhase phase) async {
    _currentPhase = phase;
    if (_isPaused) {
      _pausedPhase = phase;
      return;
    }
    debugPrint(
      '[Yad2-A11y] ════════════════════════════════════════════════════',
    );
    debugPrint(
      '[Yad2-A11y] ${phase.name.toUpperCase()}  attempt ${_phaseRetryCount + 1}/${_maxRetries + 1}',
    );
    debugPrint(
      '[Yad2-A11y] ════════════════════════════════════════════════════',
    );

    try {
      switch (phase) {
        case AutomationPhase.phase1:
          await _phase1SelectVehicleType();
        case AutomationPhase.phase2:
          await _phase2EnterLicenseAndSearch();
        case AutomationPhase.phase3:
          await _phase3SubmitVehicleLookup();
        case AutomationPhase.phase4:
          await _phase4OpenColorDropdown();
        case AutomationPhase.phase5:
          await _phase5SelectColorShade();
        case AutomationPhase.phase5a:
          await _phase5aOpenMonthDropdown();
        case AutomationPhase.phase5b:
          await _phase5bSelectMonthValue();
        case AutomationPhase.phase5c:
          await _phase5cCheckNoTest();
        case AutomationPhase.phase6:
          await _phase6OpenHandDropdown();
        case AutomationPhase.phase7:
          await _phase7SelectHandValue();
        case AutomationPhase.phase8:
          await _phase8OpenCurrentOwnershipDropdown();
        case AutomationPhase.phase9:
          await _phase9SelectCurrentOwnershipValue();
        case AutomationPhase.phase10:
          await _phase10OpenPreviousOwnershipDropdown();
        case AutomationPhase.phase11:
          await _phase11SelectPreviousOwnershipValue();
        case AutomationPhase.phase12:
          await _phase12EnterKilometers();
        case AutomationPhase.phase13:
          await _phase13Disability();
        case AutomationPhase.phase14:
          await _phase14EnterAdditionalInfo();
        case AutomationPhase.phase15:
          await _phase15SelectCity();
        case AutomationPhase.phase16:
          await _phase16EnterPrice();
        case AutomationPhase.phase17:
          await _phase17();
        case AutomationPhase.complete:
          WakelockPlus.disable();
          _handlePhaseComplete(AutomationPhase.complete);
        default:
          debugPrint('[Yad2-A11y] Ignoring commented out phase: $phase');
          break;
      }
    } catch (e) {
      debugPrint('[Yad2-A11y] Phase execution error: $e');
      await _handleBlockedFlow(phase, e.toString());
    }
  }

  // ── Function Tools for Accessibility API ─────────────────────────────────

  /// Generic function tool: Ask Android AccessibilityService to find node and tap
  Future<bool> toolFindElementAndTap(
    String targetText, {
    int targetInstance = 1,
    double deltaY = 0, // In case we need relative tapping, handled by dart side
  }) async {
    debugPrint(
      '[Yad2-A11y] Tool: toolFindElementAndTap("$targetText", instance=$targetInstance, deltaY=$deltaY)',
    );
    try {
      final bounds = await _channel.invokeMapMethod<String, dynamic>(
        'findAndGetBounds',
        {'target': targetText, 'targetInstance': targetInstance},
      );

      if (bounds != null) {
        final physicalX = (bounds['x'] as num).toDouble();
        final physicalY = (bounds['y'] as num).toDouble() + deltaY;

        // Convert from physical Android screen pixels to Flutter logical pixels
        final pixelRatio =
            WidgetsBinding
                .instance
                .platformDispatcher
                .views
                .first
                .devicePixelRatio;
        final logicalX = physicalX / pixelRatio;
        final logicalY = physicalY / pixelRatio;

        debugPrint(
          '[Yad2-A11y] Found target "$targetText". Physical ($physicalX, $physicalY). Logical ($logicalX, $logicalY)',
        );

        onTapPreview?.call(logicalX, logicalY);

        // Dispatch an immutable hardware tap via Android native AccessibilityService
        await toolTapScreen(physicalX, physicalY);
        return true;
      } else {
        return false;
      }
    } catch (e) {
      debugPrint('[Yad2-A11y] PlatformException in findAndTap: $e');
      return false;
    }
  }

  /// Generic function tool: Ask Android AccessibilityService to find node and enter text
  Future<bool> toolEnterText(
    String targetText,
    String value, {
    int targetInstance = 1,
  }) async {
    debugPrint(
      '[Yad2-A11y] Tool: toolEnterText("$targetText", value="$value")',
    );
    try {
      final bounds = await _channel.invokeMapMethod<String, dynamic>(
        'findAndGetBounds',
        {'target': targetText, 'targetInstance': targetInstance},
      );

      if (bounds != null) {
        final physicalX = (bounds['x'] as num).toDouble();
        final physicalY = (bounds['y'] as num).toDouble();

        // 1. Tap to focus the input natively
        await toolTapScreen(physicalX, physicalY);
        await Future.delayed(const Duration(milliseconds: 650));

        // 2. Direct text entry via AccessibilityService (ACTION_SET_TEXT)
        bool success = await toolEnterTextAtFocused(value);

        // 3. Fallback to JS Injection if native Accessibility text entry fails
        if (!success) {
          debugPrint(
            '[Yad2-A11y] Native text entry failed, falling back to JS injection.',
          );
          await toolEnterTextAtFocusedJs(value);
          success = true;
        }
        return success;
      }
      return false;
    } on PlatformException catch (e) {
      debugPrint('[Yad2-A11y] PlatformException in enterText: ${e.message}');
      return false;
    }
  }

  /// Generic function tool: Ask Android AccessibilityService to find the input BEFORE a specific node and enter text
  Future<bool> toolEnterTextBefore(String targetText, String value) async {
    debugPrint(
      '[Yad2-A11y] Tool: toolEnterTextBefore("$targetText", value="$value")',
    );
    try {
      final bounds = await _channel.invokeMapMethod<String, dynamic>(
        'findInputBeforeAndGetBounds',
        {'target': targetText},
      );

      if (bounds != null) {
        final physicalX = (bounds['x'] as num).toDouble();
        final physicalY = (bounds['y'] as num).toDouble();

        // 1. Tap to focus the input natively
        await toolTapScreen(physicalX, physicalY);
        await Future.delayed(const Duration(milliseconds: 650));

        // 2. Direct text entry via AccessibilityService (ACTION_SET_TEXT)
        bool success = await toolEnterTextAtFocused(value);

        // 3. Fallback to JS Injection if native Accessibility text entry fails
        if (!success) {
          debugPrint(
            '[Yad2-A11y] Native text entry failed, falling back to JS injection.',
          );
          await toolEnterTextAtFocusedJs(value);
          success = true;
        }
        return success;
      }
      return false;
    } on PlatformException catch (e) {
      debugPrint(
        '[Yad2-A11y] PlatformException in enterTextBefore: ${e.message}',
      );
      return false;
    }
  }

  /// Generic function tool: Ask Android AccessibilityService to find the node BEFORE a specific node and tap it
  Future<bool> toolTapNodeBefore(
    String targetText, {
    int targetInstance = 1,
    double deltaY = 0,
  }) async {
    debugPrint(
      '[Yad2-A11y] Tool: toolTapNodeBefore("$targetText", instance=$targetInstance, deltaY=$deltaY)',
    );
    try {
      final bounds = await _channel.invokeMapMethod<String, dynamic>(
        'findNodeBeforeAndGetBounds',
        {'target': targetText, 'targetInstance': targetInstance},
      );

      if (bounds != null) {
        final physicalX = (bounds['x'] as num).toDouble();
        final physicalY = (bounds['y'] as num).toDouble() + deltaY;

        final pixelRatio =
            WidgetsBinding
                .instance
                .platformDispatcher
                .views
                .first
                .devicePixelRatio;
        final logicalX = physicalX / pixelRatio;
        final logicalY = physicalY / pixelRatio;

        debugPrint(
          '[Yad2-A11y] Found node before "$targetText". Physical ($physicalX, $physicalY). Logical ($logicalX, $logicalY)',
        );

        onTapPreview?.call(logicalX, logicalY);

        await toolTapScreen(physicalX, physicalY);
        return true;
      }
      return false;
    } on PlatformException catch (e) {
      debugPrint(
        '[Yad2-A11y] PlatformException in toolTapNodeBefore: ${e.message}',
      );
      return false;
    }
  }

  /// Generic function tool: Ask Android AccessibilityService to find the node AFTER a specific node and tap it
  Future<bool> toolTapNodeAfter(
    String targetText, {
    int targetInstance = 1,
    double threshold = 0.82,
    double deltaX = 0.0,
    double deltaY = 0.0,
    int offset = 1,
  }) async {
    debugPrint(
      '[Yad2-A11y] Tool: toolTapNodeAfter("$targetText", instance=$targetInstance, deltaX=$deltaX, deltaY=$deltaY, offset=$offset)',
    );
    try {
      final bounds = await _channel
          .invokeMapMethod<String, dynamic>('findNodeAfterAndGetBounds', {
            'target': targetText,
            'targetInstance': targetInstance,
            'threshold': threshold,
            'offset': offset,
          });

      if (bounds != null) {
        final physicalX = (bounds['x'] as num).toDouble() + deltaX;
        final physicalY = (bounds['y'] as num).toDouble() + deltaY;

        final pixelRatio =
            WidgetsBinding
                .instance
                .platformDispatcher
                .views
                .first
                .devicePixelRatio;
        final logicalX = physicalX / pixelRatio;
        final logicalY = physicalY / pixelRatio;

        debugPrint(
          '[Yad2-A11y] Found node after "$targetText". Physical ($physicalX, $physicalY). Logical ($logicalX, $logicalY)',
        );

        onTapPreview?.call(logicalX, logicalY);

        await toolTapScreen(physicalX, physicalY);
        return true;
      }
      return false;
    } on PlatformException catch (e) {
      debugPrint(
        '[Yad2-A11y] PlatformException in toolTapNodeAfter: ${e.message}',
      );
      return false;
    }
  }

  Future<void> toolLogTree() async {
    debugPrint('[Yad2-A11y] Tool: toolLogTree');
    try {
      final String? treeStr = await _channel.invokeMethod<String>('logTree');
      if (treeStr != null) {
        final lines = treeStr.split('\n');
        for (var line in lines) {
          debugPrint(line);
        }
      }
    } catch (e) {
      debugPrint('[Yad2-A11y] Error logging tree: $e');
    }
  }

  Future<void> _scrollDown(double percent) async {
    debugPrint('[Yad2-A11y] Tool: _scrollDown ($percent)');
    try {
      await _channel.invokeMethod('scrollNode', {
        'direction': 'down',
        'percent': percent,
      });
    } catch (e) {
      debugPrint('[Yad2-A11y] Scroll error: $e');
    }
    await Future.delayed(const Duration(milliseconds: 1000));
  }

  Future<void> toolTapScreen(double x, double y) async {
    debugPrint('[Yad2-A11y] Tool: toolTapScreen($x, $y)');
    try {
      await _channel.invokeMethod('tapScreen', {'x': x, 'y': y});
    } catch (e) {
      debugPrint('[Yad2-A11y] TapScreen error: $e');
    }
  }

  /// Generic function tool: Ask Android AccessibilityService to simulate a global back button press
  Future<bool> toolPressBack() async {
    debugPrint('[Yad2-A11y] Tool: toolPressBack');
    try {
      final pressed = await _channel.invokeMethod<bool>('pressBack');
      return pressed ?? false;
    } on PlatformException catch (e) {
      debugPrint('[Yad2-A11y] PlatformException in pressBack: ${e.message}');
      return false;
    }
  }

  /// Inject text natively using Android MethodChannel (Instrumentation / input shell fallback)
  Future<void> toolInjectTextNative(String text) async {
    debugPrint('[Yad2-A11y] Tool: toolInjectTextNative($text)');
    for (int i = 0; i < text.length; i++) {
      try {
        await _channel.invokeMethod<bool>('injectTextNative', {
          'value': text[i],
        });
        await Future.delayed(const Duration(milliseconds: 150));
      } catch (e) {
        debugPrint('[Yad2-A11y] Error injecting native text "${text[i]}": $e');
      }
    }
  }

  /// Inject text natively using ACTION_SET_TEXT exactly on the currently focused field
  Future<bool> toolEnterTextAtFocused(String text) async {
    debugPrint('[Yad2-A11y] Tool: toolEnterTextAtFocused($text)');
    try {
      final success = await _channel.invokeMethod<bool>('enterTextAtFocused', {
        'value': text,
      });
      debugPrint('[Yad2-A11y] enterTextAtFocused($text) returned $success');
      return success ?? false;
    } on PlatformException catch (e) {
      debugPrint(
        '[Yad2-A11y] PlatformException in enterTextAtFocused: ${e.message}',
      );
      return false;
    }
  }

  Future<void> toolEnterTextAtFocusedJs(String text) async {
    debugPrint('[Yad2-A11y] Tool: toolEnterTextAtFocusedJs($text)');
    final escaped = text.replaceAll("'", "\\'");
    await controller.runJavaScript('''
      (function() {
        var el = document.activeElement;
        
        if (!el || (el.tagName !== 'INPUT' && el.tagName !== 'TEXTAREA')) {
          var possibleInputs = document.querySelectorAll('input:not([type="hidden"]):not([type="checkbox"]):not([type="radio"])');
          for (var i = 0; i < possibleInputs.length; i++) {
            var rect = possibleInputs[i].getBoundingClientRect();
            if (rect.width > 0 && rect.height > 0 && rect.top >= 0 && rect.bottom <= (window.innerHeight || document.documentElement.clientHeight)) {
              el = possibleInputs[i];
              break;
            }
          }
        }
        
        if (!el || (el.tagName !== 'INPUT' && el.tagName !== 'TEXTAREA')) return;
        
        el.focus();
        var nativeSetter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value')
                        || Object.getOwnPropertyDescriptor(window.HTMLTextAreaElement.prototype, 'value');
        if (nativeSetter && nativeSetter.set) {
          nativeSetter.set.call(el, '$escaped');
        } else {
          el.value = '$escaped';
        }
        el.dispatchEvent(new InputEvent('input', { bubbles: true, data: '$escaped', inputType: 'insertText' }));
        el.dispatchEvent(new Event('change', { bubbles: true }));
      })();
    ''');
  }

  /// Uses the Shadow HTML DOM logic to find an element by exact text and dispatches native React/JS click events
  Future<bool> toolFindAndTapJs(String targetText) async {
    debugPrint('[Yad2-A11y] Tool: toolFindAndTapJs($targetText)');
    final escaped = targetText.replaceAll("'", "\\'");
    final js = '''
      (function() {
        var all = [];
        function getAllElements(root) {
          if (!root) return;
          var elements = root.querySelectorAll('*');
          for (var i = 0; i < elements.length; i++) {
            all.push(elements[i]);
            if (elements[i].shadowRoot) getAllElements(elements[i].shadowRoot);
          }
        }
        getAllElements(document);
        
        var targetEl = null;
        var targetRect = null;
        for (var i = 0; i < all.length; i++) {
          var el = all[i];
          var rect = el.getBoundingClientRect();
          if (rect.width === 0 || rect.height === 0) continue;
          
          var text = (el.innerText || '').trim();
          if (text === '$escaped') {
            targetEl = el;
            targetRect = rect;
            break;
          }
        }
        
        if (!targetEl) return false;
        
        var x = targetRect.left + targetRect.width / 2;
        var y = targetRect.top + targetRect.height / 2;
        
        var eOpts = { bubbles:true, cancelable:true, clientX:x, clientY:y, screenX:x, screenY:y };
        var touch = new Touch({ identifier: Date.now(), target: targetEl, clientX: x, clientY: y, screenX: x, screenY: y, pageX: x + window.scrollX, pageY: y + window.scrollY });

        targetEl.dispatchEvent(new TouchEvent('touchstart', { bubbles: true, cancelable: true, touches: [touch], targetTouches: [touch], changedTouches: [touch] }));
        targetEl.dispatchEvent(new MouseEvent('mousedown', eOpts));
        
        targetEl.dispatchEvent(new TouchEvent('touchend', { bubbles: true, cancelable: true, changedTouches: [touch] }));
        targetEl.dispatchEvent(new MouseEvent('mouseup', eOpts));
        targetEl.dispatchEvent(new MouseEvent('click', eOpts));
        try { targetEl.click(); } catch(e) {}
        
        try {
          var fiberKey = Object.keys(targetEl).find(function(k) { return k.startsWith('__reactFiber') || k.startsWith('__reactInternalInstance'); });
          if (fiberKey) {
            var fiber = targetEl[fiberKey];
            while (fiber) {
              var props = fiber.memoizedProps || fiber.pendingProps;
              if (props && typeof props.onClick === 'function') {
                props.onClick({ type:'click', target:targetEl, currentTarget:targetEl, clientX:x, clientY:y, bubbles:true, preventDefault:function(){}, stopPropagation:function(){} });
                break;
              }
              fiber = fiber.return;
            }
          }
        } catch(e) {}
        
        return true;
      })();
    ''';

    final result = await controller.runJavaScriptReturningResult(js);
    return result == true || result == 'true';
  }

  // ── Helper Tools ────────────────────────────────────────────────────────

  Future<void> toolLogAccessibilityTree() async {
    debugPrint('[Yad2-A11y] Tool: toolLogAccessibilityTree');
    try {
      final String? treeStr = await _channel.invokeMethod<String>('logTree');
      if (treeStr != null) {
        final lines = treeStr.split('\n');
        for (var line in lines) {
          debugPrint(line);
        }
      }
    } catch (e) {
      debugPrint('[Yad2-A11y] Failed to log tree: $e');
    }
  }

  Future<bool> _dismissMaybeLaterPopup() async {
    const popupTexts = ['אולי אחר כך', 'אולי אחר כך', 'אולי אחר כך'];
    for (var text in popupTexts) {
      if (await toolFindElementAndTap(text, deltaY: -15)) {
        // Often needs a slight upward adjustment
        debugPrint('[Yad2-A11y] 🔄 Dismissed popup: $text');
        await Future.delayed(const Duration(milliseconds: 1500));
        return true;
      }
    }
    return false;
  }

  Future<bool> _dismissGotItPopup() async {
    const popupTexts = [
      'הבנתי',
      'עדכנתי, בואו נמשיך',
      'עדכנתי, בוא נמשיך',
      'עדכנתי בואו נמשיך',
    ];
    for (var text in popupTexts) {
      if (await toolFindElementAndTap(text, deltaY: -15)) {
        // Often needs a slight upward adjustment
        debugPrint('[Yad2-A11y] 🔄 Dismissed popup: $text');
        await Future.delayed(const Duration(milliseconds: 1500));
        return true;
      }
    }
    return false;
  }

  Future<void> _handleBlockedFlow(
    AutomationPhase phase,
    String errorContext,
  ) async {
    debugPrint('[Yad2-A11y] Tool: _handleBlockedFlow (Phase: ${phase.name})');
    WakelockPlus.disable();
    await toolLogTree(); // Dump the tree to see why it got stuck
    await _handleError(
      phase,
      'Stuck: $errorContext. Please check accessibility tree and screen.',
    );
  }

  Future<bool> _performWithPopupHandling(Future<bool> Function() action) async {
    bool result = await action();
    if (!result) {
      final dismissed = await _dismissGotItPopup();
      if (dismissed) {
        debugPrint('[Yad2-A11y] 🔄 Re-trying action after dismissing popup');
        result = await action();
      }
    }
    return result;
  }

  Future<bool> _checkIsLoginScreen() async {
    try {
      final res = await controller.runJavaScriptReturningResult('''
        (function() {
          var hasPassword = document.querySelector('input[type="password"]') !== null;
          if (hasPassword) return true;
          var text = document.body ? document.body.innerText : '';
          if (text.includes('התחברות') || text.includes('כניסה לאזור האישי') || text.includes('אימייל/מספר טלפון')) {
            return true;
          }
          return false;
        })()
      ''');
      if (res == true || res == 'true') {
        debugPrint('[Yad2-A11y] 🔐 Login screen detected via JS');
        return true;
      }
    } catch (e) {
      debugPrint('[Yad2-A11y] JS login detection failed: $e');
    }

    final loginKeywords = [
      'התחברות',
      'כניסה לאזור',
      'דוא"ל',
      'סיסמה',
      'הרשמה',
      'כניסה',
      'התחבר',
    ];
    for (final word in loginKeywords) {
      try {
        final bounds = await _channel.invokeMapMethod<String, dynamic>(
          'findAndGetBounds',
          {'target': word, 'targetInstance': 1},
        );
        if (bounds != null) {
          debugPrint(
            '[Yad2-A11y] 🔐 Login screen detected via A11y with keyword: "$word"',
          );
          return true;
        }
      } catch (_) {}
    }
    return false;
  }

  // ── Phase Implementations ────────────────────────────────────────────────

  Future<void> _phase1SelectVehicleType() async {
    // Wait for initial load
    await Future.delayed(const Duration(milliseconds: 650));

    if (await _checkIsLoginScreen()) {
      _handleError(
        AutomationPhase.phase1,
        'Login screen detected. Please log in manually.',
      );
      return;
    }

    // Dismiss the "Got it" popup first explicitly (in case it blocks taps but elements are still found)
    await Future.delayed(const Duration(milliseconds: 800));
    final dismissed = await _dismissGotItPopup();
    if (dismissed) {
      debugPrint(
        '[Yad2-A11y] 🔄 Dismissed popup in phase 1, waiting before proceeding',
      );
      await Future.delayed(const Duration(milliseconds: 800));
    }

    // Dismiss the "Maybe later Install the app" first explicitly (in case it blocks taps but elements are still found)
    await Future.delayed(const Duration(milliseconds: 800));
    final dismissedLater = await _dismissMaybeLaterPopup();
    if (dismissedLater) {
      debugPrint(
        '[Yad2-A11y] 🔄 Dismissed maybe later in phase 1, waiting before proceeding',
      );
      await Future.delayed(const Duration(milliseconds: 800));
    }

    // Log the entire accessibility tree so you can inspect what the service actually sees
    // await toolLogAccessibilityTree();

    // The text is at the bottom of the card. A deltaY of -180 taps exactly the center of the car image.
    final success = await _performWithPopupHandling(
      () => toolFindElementAndTap('פרטיים ומסחריים', deltaY: -180),
    );
    if (success) {
      onFirstStepDetected?.call();
      _handlePhaseComplete(AutomationPhase.phase1);
    } else {
      _handleRetry(
        AutomationPhase.phase1,
        'Could not find vehicle type button',
      );
    }
  }

  Future<void> _phase2EnterLicenseAndSearch() async {
    // Log the entire accessibility tree to inspect the UI at phase 2
    // await toolLogTree();

    // Handle reset popup ("resume existing publication" popup)
    if (await toolFindElementAndTap('התחלה מחדש|מחדש')) {
      debugPrint(
        '[Yad2-A11y] ⚠️ Reset popup found — tapped "מחדש" to start over.',
      );
      await Future.delayed(const Duration(milliseconds: 800));
      _processPhase(AutomationPhase.phase1);
      return;
    }

    final licenseText =
        formData.licenseNumber.isNotEmpty ? formData.licenseNumber : '5211639';
    final entered = await _performWithPopupHandling(
      () => toolEnterTextBefore('חיפוש', licenseText),
    );
    if (!entered) {
      _handleRetry(AutomationPhase.phase2, 'License input field not found');
      return;
    }

    if (!await toolFindElementAndTap('חיפוש', targetInstance: 1)) {
      _handleRetry(AutomationPhase.phase2, 'Search button not found');
      return;
    }

    await Future.delayed(const Duration(milliseconds: 1200));

    _handlePhaseComplete(AutomationPhase.phase2);
  }

  Future<void> _phase3SubmitVehicleLookup() async {
    if (!await _performWithPopupHandling(
      () => toolFindElementAndTap('לשלב הבא|שלב הבא'),
    )) {
      _handleRetry(AutomationPhase.phase3, 'Submit button לשלב not found');
      return;
    }
    _handlePhaseComplete(AutomationPhase.phase3);
  }

  Future<void> _phase4OpenColorDropdown() async {
    await Future.delayed(const Duration(milliseconds: 800));
    await toolLogTree();
    if (await _performWithPopupHandling(
      () => toolTapNodeBefore(formData.color),
    )) {
      await Future.delayed(const Duration(milliseconds: 400));
      _handlePhaseComplete(AutomationPhase.phase4);
      return;
    }
    _handleRetry(AutomationPhase.phase4, 'Color dropdown failed to open');
  }

  Future<void> _phase5SelectColorShade() async {
    await _scrollDown(0.25);
    if (await _performWithPopupHandling(
      () => toolTapNodeBefore(formData.color, targetInstance: 2),
    )) {
      await Future.delayed(const Duration(milliseconds: 400));
      _handlePhaseComplete(AutomationPhase.phase5);
      return;
    }
    _handleRetry(AutomationPhase.phase5, 'Color shade option failed to click');
  }

  Future<void> _phase5aOpenMonthDropdown() async {
    await _scrollDown(0.35);

    for (int i = 0; i < 3; i++) {
      if (await _performWithPopupHandling(
        () => toolTapNodeAfter('חודש עלייה לכביש'),
      )) {
        await Future.delayed(const Duration(milliseconds: 700));
        _handlePhaseComplete(AutomationPhase.phase5a);
        return;
      }
    }
    _handleRetry(AutomationPhase.phase5a, 'Month dropdown failed to open');
  }

  Future<void> _phase5bSelectMonthValue() async {
    final monthHebrew = VehiclePublishData.monthToHebrew(formData.month);
    final monthSearch =
        monthHebrew != formData.month.trim()
            ? '$monthHebrew|${formData.month.trim()}'
            : monthHebrew;

    if (await _performWithPopupHandling(
      () => toolFindElementAndTap(monthSearch),
    )) {
      await Future.delayed(const Duration(milliseconds: 300));
      _handlePhaseComplete(AutomationPhase.phase5b);
      return;
    }

    _handleRetry(AutomationPhase.phase5b, 'Month value option not found');
  }

  Future<void> _phase5cCheckNoTest() async {
    if (formData.noTest) {
      await toolFindElementAndTap('ללא טסט');
      await Future.delayed(const Duration(milliseconds: 650));
    }
    _handlePhaseComplete(AutomationPhase.phase5c);
  }

  Future<void> _phase6OpenHandDropdown() async {
    await _scrollDown(0.35);
    for (int i = 0; i < 3; i++) {
      if (await _performWithPopupHandling(() => toolTapNodeAfter('יד*'))) {
        await Future.delayed(const Duration(milliseconds: 650));
        _handlePhaseComplete(AutomationPhase.phase6);
        return;
      }
    }
    _handleRetry(AutomationPhase.phase6, 'Hand dropdown label not found');
  }

  Future<void> _phase7SelectHandValue() async {
    final handFull =
        formData.hand.startsWith('יד') ? formData.hand : 'יד ${formData.hand}';
    final handParts = handFull.split(' ');
    final handSearch =
        handParts.length > 1 ? '$handFull|${handParts.last}' : handFull;

    for (int i = 0; i < 3; i++) {
      if (await _performWithPopupHandling(
        () => toolFindElementAndTap(handSearch),
      )) {
        await Future.delayed(const Duration(milliseconds: 650));
        _handlePhaseComplete(AutomationPhase.phase7);
        return;
      }
    }
    _handleRetry(AutomationPhase.phase7, 'Hand value option not found');
  }

  Future<void> _phase8OpenCurrentOwnershipDropdown() async {
    for (int i = 0; i < 3; i++) {
      if (await _performWithPopupHandling(
        () => toolTapNodeAfter('בעלות נוכחית'),
      )) {
        await Future.delayed(const Duration(milliseconds: 650));
        _handlePhaseComplete(AutomationPhase.phase8);
        return;
      }
    }
    _handleRetry(
      AutomationPhase.phase8,
      'Current ownership dropdown label not found',
    );
  }

  Future<void> _phase9SelectCurrentOwnershipValue() async {
    for (int i = 0; i < 3; i++) {
      if (await _performWithPopupHandling(
        () => toolFindElementAndTap(formData.currentOwnership),
      )) {
        await Future.delayed(const Duration(milliseconds: 650));
        _handlePhaseComplete(AutomationPhase.phase9);
        return;
      }
    }
    _handleRetry(
      AutomationPhase.phase9,
      'Current ownership value option not found',
    );
  }

  Future<void> _phase10OpenPreviousOwnershipDropdown() async {
    for (int i = 0; i < 3; i++) {
      if (await _performWithPopupHandling(
        () => toolTapNodeAfter('בעלות מקורית'),
      )) {
        await Future.delayed(const Duration(milliseconds: 650));
        _handlePhaseComplete(AutomationPhase.phase10);
        return;
      }
    }
    _handleRetry(
      AutomationPhase.phase10,
      'Previous ownership dropdown label not found',
    );
  }

  Future<void> _phase11SelectPreviousOwnershipValue() async {
    for (int i = 0; i < 3; i++) {
      if (await _performWithPopupHandling(
        () => toolFindElementAndTap(formData.previousOwnership),
      )) {
        await Future.delayed(const Duration(milliseconds: 650));
        _handlePhaseComplete(AutomationPhase.phase11);
        return;
      }
    }
    _handleRetry(
      AutomationPhase.phase11,
      'Previous ownership value option not found',
    );
  }

  Future<void> _phase12EnterKilometers() async {
    await _scrollDown(0.2);
    if (!await _performWithPopupHandling(() async {
      if (await toolTapNodeAfter('קילומטראז')) {
        await Future.delayed(const Duration(milliseconds: 650));
        // Use JS injection to avoid native paste doubling issues on masked fields
        await toolEnterTextAtFocusedJs(formData.kilometers);
        return true;
      }
      return false;
    })) {
      _handleRetry(AutomationPhase.phase12, 'Kilometers input field not found');
      return;
    }
    // Close the keyboard
    await Future.delayed(const Duration(milliseconds: 650));
    await toolPressBack();
    await Future.delayed(const Duration(milliseconds: 650));

    _handlePhaseComplete(AutomationPhase.phase12);
  }

  Future<void> _phase13Disability() async {
    if (formData.handicapped) {
      toolFindElementAndTap('מותאם לנכים');
    }

    _handlePhaseComplete(AutomationPhase.phase13);
  }

  Future<void> _phase14EnterAdditionalInfo() async {
    await _scrollDown(0.4);
    // 1. Check for PRE-submit popup
    if (await toolFindElementAndTap(
      'עדכנתי, בוא נמשיך|עדכנתי|בוא נמשיך',
      deltaY: -15,
    )) {
      debugPrint(
        '[Yad2-A11y] 👆 Tapped "עדכנתי בוא נמשיך" popup button before submit...',
      );
      await Future.delayed(const Duration(milliseconds: 800));
      await _scrollDown(0.75);
    } else {
      await _scrollDown(0.75);
    }

    if (!await toolFindElementAndTap('לשלב הבא|שלב הבא')) {
      _handleRetry(AutomationPhase.phase14, 'Submit button לשלב הבא not found');
      return;
    }

    await Future.delayed(const Duration(milliseconds: 1500));

    // 3. Check for POST-submit popup
    if (await toolFindElementAndTap(
      'עדכנתי, בואו נמשיך|עדכנתי, בוא נמשיך',
      deltaY: -15,
    )) {
      debugPrint(
        '[Yad2-A11y] 👆 Tapped "עדכנתי בואו נמשיך" popup button post-submit...',
      );
      await Future.delayed(const Duration(milliseconds: 1500));
      await _scrollDown(0.75);
      await Future.delayed(const Duration(milliseconds: 650));

      if (await toolFindElementAndTap('לשלב הבא|שלב הבא')) {
        debugPrint('[Yad2-A11y] 👆 Tapped "לשלב הבא" submit button again...');
        await Future.delayed(const Duration(milliseconds: 1200));
      }
    }

    _handlePhaseComplete(AutomationPhase.phase14);
  }

  Future<void> _phase15SelectCity() async {
    await _scrollDown(0.1);
    final cityVal = formData.city.isNotEmpty ? formData.city : 'חיפה';
    final typedVal =
        cityVal.length > 1 ? cityVal.substring(0, cityVal.length - 1) : cityVal;

    // 1. Tap the initial city field to open the autocomplete search UI
    if (!await _performWithPopupHandling(() => toolTapNodeAfter('ישוב*'))) {
      _handleRetry(AutomationPhase.phase15, 'City input label not found');
      return;
    }

    // 3. Type letter by letter to trigger autocomplete logic
    String currentText = "";
    for (int i = 0; i < typedVal.length; i++) {
      currentText += typedVal[i];

      // Use JS injection on the active element to guarantee we don't lose focus
      await toolEnterTextAtFocusedJs(currentText);
      await Future.delayed(const Duration(milliseconds: 300));
    }

    // Wait for the autocomplete API to fetch and render the list below
    await Future.delayed(const Duration(milliseconds: 650));

    // Dump the accessibility tree to log so we can inspect it
    // await toolLogAccessibilityTree();

    // 4. Tap the dropdown item (the user found it's the 4th/5th meaningful element after the label)
    if (await toolFindElementAndTap(cityVal)) {
      await Future.delayed(const Duration(milliseconds: 650));
      _handlePhaseComplete(AutomationPhase.phase15);
      return;
    }

    //_handleRetry(AutomationPhase.phase15, 'City value option not found');
  }

  Future<void> _phase16EnterPrice() async {
    debugPrint('[Yad2-A11y] Entered Price logic');
    final priceText = formData.price.isNotEmpty ? formData.price : '80000';
    if (!await _performWithPopupHandling(() async {
      if (await toolTapNodeAfter('מחיר', offset: 1)) {
        await Future.delayed(const Duration(milliseconds: 650));
        await toolEnterTextAtFocusedJs(priceText);
        return true;
      }
      return false;
    })) {
      _handleRetry(AutomationPhase.phase16, 'Price input field not found');
      return;
    }
    // Close the keyboard
    await Future.delayed(const Duration(milliseconds: 650));
    await toolPressBack();
    await Future.delayed(const Duration(milliseconds: 650));

    await _scrollDown(0.5);

    if (await toolFindElementAndTap('לשלב הבא|שלב הבא|לשלב')) {
      await Future.delayed(const Duration(milliseconds: 1500));
      _handlePhaseComplete(AutomationPhase.phase16);
      return;
    }
  }

  Future<void> _phase17() async {
    debugPrint(
      '[Yad2-A11y] Upload Photos phase reached. Proceeding to submit.',
    );

    // Convert local images to base64 and upload them via JS injection
    final images = formData.images;
    if (images == null || images.isEmpty) {
      debugPrint(
        '[Yad2-A11y] ⚠️ No images selected, proceeding directly to next step...',
      );
    } else {
      debugPrint(
        '[Yad2-A11y] ⏳ Converting ${images.length} images to base64 for upload...',
      );
      final List<Map<String, String>> base64Files = [];
      for (int i = 0; i < images.length; i++) {
        final path = images[i];
        if (path.isEmpty) continue;
        try {
          final file = File(path);
          if (await file.exists()) {
            final bytes = await file.readAsBytes();
            final base64String = base64Encode(bytes);
            final ext = path.split('.').last.toLowerCase();
            final mimeType =
                (ext == 'jpg' || ext == 'jpeg') ? 'image/jpeg' : 'image/png';
            base64Files.add({
              'base64': 'data:$mimeType;base64,$base64String',
              'filename': 'photo_${i + 1}.$ext',
              'contentType': mimeType,
            });
          }
        } catch (e) {
          debugPrint('[Yad2-A11y] Error converting image $path to base64: $e');
        }
      }

      if (base64Files.isNotEmpty) {
        debugPrint(
          '[Yad2-A11y] 📤 Injecting ${base64Files.length} images into WebView file input...',
        );
        final jsonFiles = jsonEncode(base64Files);
        final jsScript = '''
          (function() {
            var filesArray = $jsonFiles;
            var fileInput = document.querySelector('input[type="file"]') 
                         || document.querySelector('input[accept*="image"]')
                         || document.querySelector('input[name*="file"]')
                         || document.querySelector('input[id*="file"]');
            if (!fileInput) {
              console.error('File input not found');
              return 'no_input';
            }

            var container = new DataTransfer();
            for (var k = 0; k < filesArray.length; k++) {
              var item = filesArray[k];
              var base64Data = item.base64;
              var filename = item.filename;
              var contentType = item.contentType;

              var byteString = atob(base64Data.split(',')[1] || base64Data);
              var ab = new ArrayBuffer(byteString.length);
              var ia = new Uint8Array(ab);
              for (var i = 0; i < byteString.length; i++) {
                ia[i] = byteString.charCodeAt(i);
              }
              var blob = new Blob([ab], {type: contentType});
              var file = new File([blob], filename, {type: contentType});
              container.items.add(file);
            }

            fileInput.files = container.files;
            var event = new Event('change', { bubbles: true });
            fileInput.dispatchEvent(event);
            return 'ok';
          })()
        ''';

        final result = await controller.runJavaScriptReturningResult(jsScript);
        debugPrint('[Yad2-A11y] ✅ JS upload execution result: $result');

        // Wait for upload to complete on server/UI
        await Future.delayed(const Duration(milliseconds: 3000));
      } else {
        debugPrint('[Yad2-A11y] ⚠️ No valid local image files found to upload');
      }
    }

    await _scrollDown(0.75);
    await Future.delayed(const Duration(milliseconds: 650));

    if (!await _performWithPopupHandling(
      () => toolFindElementAndTap('לשלב הבא|שלב הבא|המשך|לשלב'),
    )) {
      _handleRetry(
        AutomationPhase.phase17,
        'Submit button not found on photos page',
      );
      return;
    }
    _handlePhaseComplete(AutomationPhase.phase17);
  }

  // ── Flow Controllers ──────────────────────────────────────────────────────

  void _handlePhaseComplete(AutomationPhase phase) {
    debugPrint('[Yad2-A11y] ✅ Phase complete: ${phase.description}');
    onPhaseComplete?.call(phase);

    AutomationPhase? next;
    int delayMs = 1000;

    switch (phase) {
      case AutomationPhase.phase1:
        next = AutomationPhase.phase2;
        delayMs = 500;
        break;
      case AutomationPhase.phase2:
        next = AutomationPhase.phase3;
        delayMs = 500;
        break;
      case AutomationPhase.phase3:
        next = AutomationPhase.phase4;
        delayMs = 1000;
        break;
      case AutomationPhase.phase4:
        next = AutomationPhase.phase5;
        break;
      case AutomationPhase.phase5:
        next = AutomationPhase.phase5a;
        delayMs = 700;
        break;
      case AutomationPhase.phase5a:
        next = AutomationPhase.phase5b;
        delayMs = 700;
        break;
      case AutomationPhase.phase5b:
        next = AutomationPhase.phase5c;
        delayMs = 500;
        break;
      case AutomationPhase.phase5c:
        next = AutomationPhase.phase6;
        delayMs = 700;
        break;
      case AutomationPhase.phase6:
        next = AutomationPhase.phase7;
        delayMs = 700;
        break;
      case AutomationPhase.phase7:
        next = AutomationPhase.phase8;
        delayMs = 500;
        break;
      case AutomationPhase.phase8:
        next = AutomationPhase.phase9;
        delayMs = 700;
        break;
      case AutomationPhase.phase9:
        final handTrimmed = formData.hand.trim();
        final isFirstHand = [
          'ראשונה',
          'יד ראשונה',
          '1',
          'יד 1',
          'ראשון',
        ].contains(handTrimmed);
        next = isFirstHand ? AutomationPhase.phase12 : AutomationPhase.phase10;
        break;
      case AutomationPhase.phase10:
        next = AutomationPhase.phase11;
        break;
      case AutomationPhase.phase11:
        next = AutomationPhase.phase12;
        break;
      case AutomationPhase.phase12:
        next = AutomationPhase.phase13;
        break;
      case AutomationPhase.phase13:
        next = AutomationPhase.phase14;
        delayMs = 1000;
        break;
      case AutomationPhase.phase14:
        next = AutomationPhase.phase15;
        delayMs = 1000;
        break;
      case AutomationPhase.phase15:
        next = AutomationPhase.phase16;
        delayMs = 1000;
        break;
      case AutomationPhase.phase16:
        next = AutomationPhase.phase17;
        delayMs = 1000;
        break;
      case AutomationPhase.phase17:
        next = AutomationPhase.complete;
        delayMs = 700;
        break;
      case AutomationPhase.complete:
        onAutomationComplete?.call(true);
        return;
    }

    Future.delayed(Duration(milliseconds: delayMs), () {
      _processPhase(next!);
    });
  }

  Future<void> _handleError(AutomationPhase phase, String error) async {
    debugPrint('[Yad2-A11y] ❌ Phase error: ${phase.description} — $error');
    _isPaused = true;
    _pausedPhase = phase;
    _phaseRetryCount = 0;
    try {
      await _beepUser();
    } catch (e) {
      debugPrint('[Yad2-A11y] Error playing error beep: $e');
    }
    onPhaseError?.call(phase, error);
  }

  void _handleRetry(AutomationPhase phase, String reason) {
    if (_isPaused) {
      _pausedPhase = phase;
      return;
    }
    if (_phaseRetryCount < _maxRetries) {
      _phaseRetryCount++;
      debugPrint(
        '[Yad2-A11y] 🔄 Retrying phase $_phaseRetryCount/$_maxRetries — $reason',
      );
      Future.delayed(const Duration(milliseconds: 1000), () {
        _executePhase(phase);
      });
    } else {
      _handleError(phase, reason);
    }
  }

  Future<void> _beepUser() async {
    debugPrint('[Yad2-A11y] 🔔 Beeping user for manual interaction');
    bool assetPlayed = false;
    try {
      final player = AudioPlayer();
      final candidates = ['beep.mp3', 'beep.wav', 'alert.mp3', 'alert.wav'];
      for (final asset in candidates) {
        try {
          await player
              .play(AssetSource(asset))
              .timeout(const Duration(seconds: 2));
          assetPlayed = true;
          break;
        } catch (_) {}
      }
    } catch (e) {}

    if (!assetPlayed) {
      try {
        for (int i = 0; i < 3; i++) {
          await SystemSound.play(SystemSoundType.click);
          await Future.delayed(const Duration(milliseconds: 100));
        }
      } catch (_) {}
    }
    try {
      await HapticFeedback.vibrate();
    } catch (_) {}
  }
}
