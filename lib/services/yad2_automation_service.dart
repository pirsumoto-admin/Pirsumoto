import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:audioplayers/audioplayers.dart';
import 'ocr_service.dart';
import 'phase_validator.dart';
import 'ui_context.dart';

// ── Data ─────────────────────────────────────────────────────────────────────

import 'yad2_automation_models.dart';
export 'yad2_automation_models.dart';

// ── Service ───────────────────────────────────────────────────────────────────

class Yad2AutomationService {
  final WebViewController controller;
  final OcrService ocrService;
  final VehiclePublishData formData;
  final double devicePixelRatio;

  /// Returns a combined screenshot + AxTree snapshot for hybrid automation.
  final Future<UIContext?> Function() observeUI;

  final void Function(AutomationPhase phase)? onPhaseComplete;
  final void Function(AutomationPhase phase, String error)? onPhaseError;
  final void Function(bool success)? onAutomationComplete;
  final VoidCallback? onFirstStepDetected;

  /// Called before each tap with CSS coordinates so UI can show a visual marker.
  final void Function(double cssX, double cssY)? onTapPreview;

  /// Optional post-action validator. When set, re-observes after each tap
  /// and retries the phase if the expected outcome is not confirmed.
  final PhaseValidator? validator;

  /// Called any time the service falls back to image-based character recognition (OCR).
  final VoidCallback? onOcrFallback;

  static const int _maxRetries = 3;
  static const int _maxPhase1WaitAttempts = 3;

  int _phaseRetryCount = 0;
  int _phase1WaitAttempts = 0;
  bool _phase1Done = false;
  TextLocation? _phase1TargetLocation;

  Timer? _samplingTimer;
  bool _isSampling = false;

  bool _isPaused = false;
  AutomationPhase? _pausedPhase;

  bool get isPaused => _isPaused;
  AutomationPhase? get pausedPhase => _pausedPhase;

  void pauseAutomation() {
    debugPrint('[Yad2] ⏸️ Pause requested');
    _isPaused = true;
  }

  void resumeAutomation() {
    debugPrint('[Yad2] ▶️ Resume requested');
    if (!_isPaused) return;
    _isPaused = false;
    if (_pausedPhase != null) {
      final phaseToResume = _pausedPhase!;
      _pausedPhase = null;
      _processPhase(phaseToResume);
    }
  }

  void stepBack() {
    final current = _pausedPhase;
    if (current == null) return;
    final currentIndex = current.index;
    if (currentIndex > 0) {
      final prev = AutomationPhase.values[currentIndex - 1];
      debugPrint(
        '[Yad2] ↩️ Stepping back from ${current.name} to ${prev.name}',
      );
      _pausedPhase = prev;
    }
  }

  final void Function(bool visible)? onToggleOverlayVisibility;
  final VoidCallback? onLoginRequired;

  Yad2AutomationService({
    required this.controller,
    required this.ocrService,
    required this.formData,
    required this.devicePixelRatio,
    required this.observeUI,
    this.onPhaseComplete,
    this.onPhaseError,
    this.onAutomationComplete,
    this.onFirstStepDetected,
    this.onLoginRequired,
    this.onTapPreview,
    this.validator,
    this.onOcrFallback,
    this.onToggleOverlayVisibility,
  });

  void startAutomation() {
    debugPrint('[Yad2] 🚀 Starting automation (running pre-check)');
    _isPaused = false;
    _pausedPhase = null;
    _phase1WaitAttempts = 0;
    _phase1Done = false;
    _stopSampling();
    _runPreCheck();
  }

  void _stopSampling() {
    _samplingTimer?.cancel();
    _samplingTimer = null;
    _isSampling = false;
  }

  void dispose() {
    _stopSampling();
  }

  Future<void> _runPreCheck() async {
    debugPrint('[Yad2] 🔍 Observing UI for pre-check...');
    final ctx = await _observeUIWithPopupHandling();
    if (ctx == null) {
      debugPrint('[Yad2] UI context is null, retrying pre-check in 2 seconds');
      Future.delayed(const Duration(seconds: 2), _runPreCheck);
      return;
    }

    final detectedFirstStep = await _detectFirstStepElements(ctx);
    if (detectedFirstStep) {
      debugPrint(
        '[Yad2] 🎉 First step elements detected! Starting automation directly.',
      );
      _stopSampling();
      onFirstStepDetected?.call();
      _processPhase(AutomationPhase.phase1);
      return;
    }

    final isLogin = await _checkIsLoginScreen(ctx);
    if (isLogin) {
      debugPrint('[Yad2] 🔐 Login screen detected. User interaction required.');
    } else {
      debugPrint(
        '[Yad2] ⚠️ First step elements not found, and not login screen. User interaction required.',
      );
    }

    onLoginRequired?.call();
    await _beepUser();

    if (!_isSampling) {
      _isSampling = true;
      debugPrint('[Yad2] ⏱️ Starting 3-second sampling loop...');
      _samplingTimer = Timer.periodic(const Duration(seconds: 3), (
        timer,
      ) async {
        debugPrint('[Yad2] ⏱️ Sampling UI...');
        final sampleCtx = await _observeUIWithPopupHandling();
        if (sampleCtx == null) {
          debugPrint(
            '[Yad2] Sampling: observed UI is null, waiting for next tick',
          );
          return;
        }

        final found = await _detectFirstStepElements(sampleCtx);
        if (found) {
          debugPrint(
            '[Yad2] 🎉 First step elements detected during sampling! Starting automation.',
          );
          _stopSampling();
          onFirstStepDetected?.call();
          _processPhase(AutomationPhase.phase1);
        } else {
          debugPrint(
            '[Yad2] ❌ First step elements not detected yet in sample.',
          );
        }
      });
    }
  }

  Future<bool> _detectFirstStepElements(UIContext ctx) async {
    const targetText = 'פרטיים ומסחריים';

    // 1. AxTree check
    final allMatches = ctx.findAllByLabel(targetText);
    if (allMatches.isNotEmpty) {
      debugPrint('[Yad2] 🌳 First step element found in AxTree: "$targetText"');
      return true;
    }

    // 2. OCR check
    final raw = await ocrService.findMultiWordPhrase(
      ctx.screenshot,
      targetText,
    );
    if (raw != null) {
      debugPrint('[Yad2] 🔍 First step element found via OCR: "$targetText"');
      return true;
    }

    return false;
  }

  Future<bool> _checkIsLoginScreen(UIContext ctx) async {
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
        debugPrint('[Yad2] 🔐 Login screen detected via JS');
        return true;
      }
    } catch (e) {
      debugPrint('[Yad2] JS login detection failed: $e');
    }

    final loginKeywords = [
      'התחברות',
      'כניסה לאזור',
      'דוא',
      'סיסמה',
      'הרשמה',
      'כניסה',
      'התחבר',
      'login',
      'sign in',
    ];
    for (final word in loginKeywords) {
      final matches = ctx.findAllByLabel(word);
      if (matches.isNotEmpty) {
        debugPrint(
          '[Yad2] 🔐 Login screen detected via AxTree with keyword: "$word"',
        );
        return true;
      }
    }

    for (final word in loginKeywords) {
      final raw = await ocrService.findTextLocation(ctx.screenshot, word);
      if (raw != null) {
        debugPrint(
          '[Yad2] 🔐 Login screen detected via OCR with keyword: "$word"',
        );
        return true;
      }
    }

    return false;
  }

  Future<void> _beepUser() async {
    debugPrint('[Yad2] 🔔 Beeping user for manual interaction');
    bool assetPlayed = false;

    // 1. Try playing custom offline assets (beep.mp3 / beep.wav / alert.mp3 / alert.wav)
    try {
      final player = AudioPlayer();
      final candidates = ['beep.mp3', 'beep.wav', 'alert.mp3', 'alert.wav'];
      for (final asset in candidates) {
        try {
          await player
              .play(AssetSource(asset))
              .timeout(const Duration(seconds: 2));
          assetPlayed = true;
          debugPrint('[Yad2] Played assets/$asset successfully');
          break;
        } catch (_) {}
      }
    } catch (e) {
      debugPrint('[Yad2] Local asset play failed: $e');
    }

    // 2. Fallback to system chirps and vibration if no asset was successfully played
    if (!assetPlayed) {
      try {
        // Perform 3 quick system chirps for high-visibility tactile/auditory feedback offline
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

  // ── Phase dispatcher ───────────────────────────────────────────────────────

  void _processPhase(AutomationPhase phase) {
    _phaseRetryCount = 0;
    if (phase == AutomationPhase.phase1) _phase1WaitAttempts = 0;
    if (_isPaused) {
      _pausedPhase = phase;
      debugPrint('[Yad2] ⏸️ Automation paused at phase: ${phase.name}');
      return;
    }
    _executePhase(phase);
  }

  Future<void> _executePhase(AutomationPhase phase) async {
    if (_isPaused) {
      _pausedPhase = phase;
      debugPrint(
        '[Yad2] ⏸️ Automation paused before executing phase: ${phase.name}',
      );
      return;
    }
    debugPrint('[Yad2] ════════════════════════════════════════════════════');
    debugPrint(
      '[Yad2] ${phase.name.toUpperCase()}  attempt ${_phaseRetryCount + 1}/${_maxRetries + 1}',
    );
    debugPrint('[Yad2] ════════════════════════════════════════════════════');
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
        _handlePhaseComplete(AutomationPhase.phase5c);
      case AutomationPhase.phase5c1:
        _handlePhaseComplete(AutomationPhase.phase5c1);
      case AutomationPhase.phase5c2:
        _handlePhaseComplete(AutomationPhase.phase5c2);
      case AutomationPhase.phase5c3:
        _handlePhaseComplete(AutomationPhase.phase5c3);
      case AutomationPhase.phase5c4:
        _handlePhaseComplete(AutomationPhase.phase5c4);
      case AutomationPhase.phase5d:
        _handlePhaseComplete(AutomationPhase.phase5d);
      case AutomationPhase.phase5e:
        _handlePhaseComplete(AutomationPhase.phase5e);
      case AutomationPhase.phase5f:
        _handlePhaseComplete(AutomationPhase.phase5f);

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
        await _phase13ScrollToTop();
      case AutomationPhase.phase14:
        await _phase14EnterAdditionalInfo();
      case AutomationPhase.phase15:
        await _phase15EnterPrice();
      case AutomationPhase.phase16:
        await _phase16SelectCity();
      case AutomationPhase.phase17:
        await _phase17UploadPhotos();
      case AutomationPhase.phase18:
        _handlePhaseComplete(AutomationPhase.phase18);
      case AutomationPhase.phase19:
        _handlePhaseComplete(AutomationPhase.phase19);
      case AutomationPhase.complete:
        _handlePhaseComplete(AutomationPhase.complete);
    }
  }

  // ── Step logger helpers ────────────────────────────────────────────────────

  void _step(String phase, String desc) => debugPrint('[Yad2] $phase  $desc');

  Future<void> _wait(String phase, String reason, int ms) async {
    debugPrint('[Yad2] $phase  ⏳ ${ms}ms — $reason');
    await Future.delayed(Duration(milliseconds: ms));
  }

  // ── Phase 1 — Select vehicle type ─────────────────────────────────────────
  // Goal: tap "פרטיים ומסחריים" to enter the private/commercial vehicles flow.

  Future<void> _phase1SelectVehicleType() async {
    const p = 'P1';

    // If we already tapped this before (post-reset popup return), reuse location.
    if (_phase1Done && _phase1TargetLocation != null) {
      _step(p, '♻️  Reusing cached location (returning after reset popup)');
      await _tapLocation(_phase1TargetLocation!, 0);
      _handlePhaseComplete(AutomationPhase.phase1);
      return;
    }

    _step(p, '📸 Observing UI (screenshot + AxTree)');
    final ctx = await _observeUIWithPopupHandling();
    if (ctx == null) {
      _handleRetry(AutomationPhase.phase1, 'observeUI returned null');
      return;
    }

    _step(p, '🔍 Searching for "פרטיים ומסחריים" (vehicles entry button)');
    final target = await _findTarget(ctx, 'פרטיים ומסחריים');
    if (target == null) {
      if (_phase1WaitAttempts < _maxPhase1WaitAttempts) {
        _phase1WaitAttempts++;
        _step(
          p,
          '⏳ Page still loading — attempt $_phase1WaitAttempts/$_maxPhase1WaitAttempts',
        );
        await _wait(p, 'wait for page load', 2000);
        _executePhase(AutomationPhase.phase1);
        return;
      }
      _handleRetry(
        AutomationPhase.phase1,
        '"פרטיים ומסחריים" not found after $_maxPhase1WaitAttempts waits',
      );
      return;
    }

    _step(
      p,
      '👆 Tap "פרטיים ומסחריים" at CSS (${_px(target.centerX)}, ${_px(target.centerY)}) [${_src(target)}]',
    );
    await _tapLocation(target, 0);

    _phase1Done = true;
    _phase1TargetLocation = target;
    _handlePhaseComplete(AutomationPhase.phase1);
  }

  // ── Phase 2 — Enter license number and search ──────────────────────────────
  // Goal: detect optional reset popup → tap license input → type number → tap search.

  Future<void> _phase2EnterLicenseAndSearch() async {
    const p = 'P2';

    _step(p, '📸 Observing UI (screenshot + AxTree)');
    final ctx = await _observeUIWithPopupHandling();
    if (ctx == null) {
      _handleRetry(AutomationPhase.phase2, 'observeUI returned null');
      return;
    }

    _step(p, '🔍 Checking for reset popup "התחלה מחדש"');
    final resetPhrase = await ocrService.findMultiWordPhrase(
      ctx.screenshot,
      'התחלה מחדש',
    );
    if (resetPhrase != null) {
      _step(p, '⚠️  Reset popup found — tapping "מחדש" to dismiss');
      final btn = await _ocrFindCss(ctx.screenshot, 'מחדש', 1);
      if (btn != null) {
        _step(
          p,
          '👆 Tap "מחדש" at CSS (${_px(btn.centerX)}, ${_px(btn.centerY)}) [OCR]',
        );
        await _tapLocation(btn, 0);
        await _wait(p, 'page reload after reset', 2300);
        _processPhase(AutomationPhase.phase1);
        return;
      }
    }

    _step(p, '🔍 Finding license input field "00-000-00"');
    final licenseField = await _findTarget(ctx, '00-000-00');
    if (licenseField == null) {
      _handleRetry(AutomationPhase.phase2, 'License input field not found');
      return;
    }

    _step(p, '🔍 Finding search button (2nd instance of "חיפוש")');
    final searchBtn = await _ocrFindCss(ctx.screenshot, 'חיפוש', 2);
    if (searchBtn == null) {
      _handleError(AutomationPhase.phase2, 'Search button "חיפוש" not found');
      return;
    }

    _step(
      p,
      '👆 Tap license input at CSS (${_px(licenseField.centerX)}, ${_px(licenseField.centerY)}) [${_src(licenseField)}]',
    );
    await _tapAt(licenseField.centerX, licenseField.centerY);
    await _wait(p, 'keyboard to appear', 300);

    final licenseText =
        formData.licenseNumber.isNotEmpty ? formData.licenseNumber : '5211639';
    _step(
      p,
      '⌨️  Typing license number: "$licenseText" (${licenseText.length} chars)',
    );
    await _enterTextAtFocused(licenseText);

    final typingMs = licenseText.length * 200 + 100;
    await _wait(p, 'text input to settle', typingMs);
    await _dismissSoftKeyboard(p);
    await _wait(p, 'keyboard dismiss animation', 300);

    _step(
      p,
      '👆 Tap search button at CSS (${_px(searchBtn.centerX)}, ${_px(searchBtn.centerY)}) [OCR]',
    );
    await _tapAt(searchBtn.centerX, searchBtn.centerY);
    _handlePhaseComplete(AutomationPhase.phase2);
  }

  // ── Phase 3 — Submit vehicle lookup ───────────────────────────────────────
  // Goal: tap "לשלב" to proceed to the vehicle details form.

  Future<void> _phase3SubmitVehicleLookup() async {
    const p = 'P3';
    _step(p, '📸 Observing UI');
    final ctx = await _observeUIWithPopupHandling();
    if (ctx == null) {
      _handleRetry(AutomationPhase.phase3, 'observeUI returned null');
      return;
    }

    _step(p, '🔍 Searching for submit button "לשלב"');
    final target = await _findTarget(ctx, 'לשלב');
    if (target == null) {
      _handleRetry(AutomationPhase.phase3, '"לשלב" not found');
      return;
    }

    _step(
      p,
      '👆 Tap "לשלב" at CSS (${_px(target.centerX)}, ${_px(target.centerY)}) [${_src(target)}]',
    );
    await _tapLocation(target, 0);
    _handlePhaseComplete(AutomationPhase.phase3);
  }

  // ── Phase 4 — Open color dropdown ─────────────────────────────────────────
  // Goal: tap the color field to open the color picker dropdown.
  // Note: OCR returns the label position (above the control) so we shift up by
  //       70/devicePixelRatio. AxTree returns the element center — no shift needed.

  Future<void> _phase4OpenColorDropdown() async {
    const p = 'P4';

    _step(p, '📸 Observing UI');
    final ctx = await _observeUIWithPopupHandling();
    if (ctx == null) {
      _handleRetry(AutomationPhase.phase4, 'observeUI returned null');
      return;
    }

    // Dump every AxTree element whose label contains the color name so we can
    // see whether the circle swatch element is detected vs. the text label.
    final colorLower = formData.color.toLowerCase().replaceAll(
      RegExp(r'\s+'),
      '',
    );

    final colorMatches =
        ctx.axTree.where((el) {
          final norm = el.label.toLowerCase().replaceAll(RegExp(r'\s+'), '');
          return norm.contains(colorLower);
        }).toList();

    if (colorMatches.isEmpty) {
      _step(p, '🟡 AxTree: no elements matching "${formData.color}" found');
    } else {
      final buf = StringBuffer(
        '🎨 AxTree candidates for "${formData.color}" (${colorMatches.length} found):\n',
      );
      for (int i = 0; i < colorMatches.length; i++) {
        final el = colorMatches[i];
        buf.write(
          '  [$i] role=${el.role.padRight(10)} visible=${el.visible}'
          '  center=(${_px(el.x)}, ${_px(el.y)})'
          '  id="${el.id ?? "–"}"'
          '  label="${el.label}"\n',
        );
      }
      _step(p, buf.toString());
    }

    _step(
      p,
      '🔍 Searching for color "${formData.color}" (1st instance = dropdown label)',
    );
    final target = await _findTarget(ctx, formData.color);
    if (target == null) {
      _handleRetry(AutomationPhase.phase4, '"${formData.color}" not found');
      return;
    }

    // Log full bounding box so we can tell if the element wraps the circle or just the text.
    _step(
      p,
      '🎯 Resolved target:'
      ' source=${_src(target)}'
      ' bbox=[${_px(target.minX)},${_px(target.minY)} → ${_px(target.maxX)},${_px(target.maxY)}]'
      ' center=(${_px(target.centerX)}, ${_px(target.centerY)})'
      ' size=${_px(target.maxX - target.minX)}×${_px(target.maxY - target.minY)}px',
    );

    final yAdj = target.fromAxTree ? 0.0 : -(70 / devicePixelRatio);
    final tapY = target.centerY + yAdj - 2; // Added 5px down for click area
    _step(
      p,
      '👆 Tap color circle at CSS $yAdj _ ${target.centerY} (${_px(target.centerX)}, ${_px(tapY)}) [${_src(target)}${yAdj != 0 ? ", OCR y-adj ${_px(yAdj)}" : ""}]',
    );
    await _tapAt(target.centerX, tapY);
    _handlePhaseComplete(AutomationPhase.phase4);
  }

  // ── Phase 5 — Select color shade ──────────────────────────────────────────
  // Goal: tap the specific shade inside the now-open color dropdown, then scroll down.

  Future<void> _phase5SelectColorShade() async {
    const p = 'P5';

    await _scrollDown(0.25);

    _step(p, '📸 Observing UI (dropdown should be open)');
    final ctx = await _observeUIWithPopupHandling();
    if (ctx == null) {
      _handleRetry(AutomationPhase.phase5, 'observeUI returned null');
      return;
    }

    _step(p, '🔍 Searching for visual instances of shade "${formData.color}"');
    final allMatches = ctx.findAllByLabel(formData.color);

    // Deduplicate elements that are at virtually the same visual position (e.g. adjacent div/p tags)
    final uniqueMatches = <AxElement>[];
    for (final el in allMatches) {
      final isDuplicate = uniqueMatches.any(
        (u) => (u.y - el.y).abs() < 25 && (u.x - el.x).abs() < 25,
      );
      if (!isDuplicate) {
        uniqueMatches.add(el);
      }
    }

    TextLocation? target;
    if (uniqueMatches.length >= 2) {
      final targetElement =
          uniqueMatches[1]; // Click the second visual instance!
      _step(
        p,
        '🎯 Selected the second visual instance of "${formData.color}" from AxTree at (${_px(targetElement.x)}, ${_px(targetElement.y)})',
      );
      target = TextLocation(
        text: formData.color,
        minX: targetElement.x - 1,
        minY: targetElement.y - 1,
        maxX: targetElement.x + 1,
        maxY: targetElement.y + 1,
        confidence: 100,
        fromAxTree: true,
      );
    } else {
      _step(
        p,
        '⚠️ Fewer than 2 unique matches in AxTree. Attempting OCR to find 2nd instance of "${formData.color}"...',
      );
      target = await _ocrFindCss(ctx.screenshot, formData.color, 2);
      if (target != null) {
        _step(
          p,
          '🎯 Found second instance of "${formData.color}" via OCR at center (${_px(target.centerX)}, ${_px(target.centerY)})',
        );
      } else if (uniqueMatches.isNotEmpty) {
        final targetElement = uniqueMatches.first;
        _step(
          p,
          '⚠️ OCR second instance failed. Falling back to the first AxTree match at (${_px(targetElement.x)}, ${_px(targetElement.y)})',
        );
        target = TextLocation(
          text: formData.color,
          minX: targetElement.x - 1,
          minY: targetElement.y - 1,
          maxX: targetElement.x + 1,
          maxY: targetElement.y + 1,
          confidence: 100,
          fromAxTree: true,
        );
      }
    }

    if (target == null) {
      _handleRetry(
        AutomationPhase.phase5,
        '"${formData.color}" shade option not found',
      );
      return;
    }

    final yAdj = target.fromAxTree ? 0.0 : -(70 / devicePixelRatio);
    final tapY = target.centerY + yAdj - 2; // Added 10px down for click area
    _step(
      p,
      '👆 Tap shade option at CSS (${_px(target.centerX)}, ${_px(tapY)}) [${_src(target)}${yAdj != 0 ? ", OCR y-adj ${_px(yAdj)}" : ""}]',
    );
    await _tapAt(target.centerX, tapY);

    await _wait(p, 'dropdown close animation', 500);
    await _scrollDown(0.25);
    _handlePhaseComplete(AutomationPhase.phase5);
  }

  // ── Phase 5a — Open month dropdown ──────────────────────────────────────────
  // Goal: tap "חודש עלייה לכביש" label to open the month-selection dropdown.

  Future<void> _phase5aOpenMonthDropdown() async {
    const p = 'P5a';
    _step(p, '📸 Observing UI');
    final ctx = await _observeUIWithPopupHandling();
    if (ctx == null) {
      _handleRetry(AutomationPhase.phase5a, 'observeUI returned null');
      return;
    }

    _step(
      p,
      '🔍 Checking if month field already has a value in the shadow tree...',
    );
    final months = [
      'ינואר',
      'פברואר',
      'מרץ',
      'אפריל',
      'מאי',
      'יוני',
      'יולי',
      'אוגוסט',
      'ספטמבר',
      'אוקטובר',
      'נובמבר',
      'דצמבר',
    ];
    bool isMonthSet = false;
    for (final el in ctx.axTree) {
      if (el.visible) {
        final labelNorm = el.label.trim();
        final valueNorm = el.value?.trim() ?? '';
        final roleLower = el.role.toLowerCase();
        final idLower = (el.id ?? '').toLowerCase();

        // 1. Skip test validity fields (like testMonth/testDate) to prevent false-positive matches
        if (idLower == 'testmonth' || idLower.contains('test')) {
          continue;
        }

        // 2. Skip option list items to avoid hidden dropdown options matching
        if (roleLower == 'option' ||
            roleLower == 'listitem' ||
            roleLower == 'menuitem') {
          continue;
        }

        // 2. Check if the element itself is the month field and has a month value
        final isMonthFieldLabel =
            labelNorm.contains('חודש') ||
            labelNorm.contains('עלייה') ||
            labelNorm.contains('עליה');

        if (isMonthFieldLabel && months.contains(valueNorm)) {
          isMonthSet = true;
          _step(
            p,
            '🎯 Detected selected month "$valueNorm" in month dropdown (label="$labelNorm", role=${el.role})',
          );
          break;
        }

        // 3. Fallback: if placeholder was replaced, the element's label/value is the month name itself.
        // It must be an input control (not a static label or list option).
        if (months.contains(labelNorm) || months.contains(valueNorm)) {
          const inputRoles = {
            'text',
            'input',
            'select',
            'textbox',
            'combobox',
            'button',
          };
          if (inputRoles.contains(roleLower) ||
              roleLower.contains('input') ||
              roleLower.contains('select')) {
            isMonthSet = true;
            _step(
              p,
              '🎯 Detected selected month in input control: label="$labelNorm", value="$valueNorm" (role=${el.role})',
            );
            break;
          }
        }
      }
    }

    if (isMonthSet) {
      _step(
        p,
        '⏭️ Month value is already set in the shadow tree. Skipping month selection steps.',
      );
      _handlePhaseComplete(AutomationPhase.phase5b);
      return;
    }

    _step(p, '🔍 Searching for month dropdown label "חודש עלייה לכביש"');
    final target = await _findTarget(
      ctx,
      'חודש עלייה לכביש|חודש עליה לכביש|חודש עלייה|חודש עליה',
    );
    if (target == null) {
      _handleRetry(
        AutomationPhase.phase5a,
        '"חודש עלייה לכביש" dropdown label not found',
      );
      return;
    }

    _step(
      p,
      '👆 Tap "חודש עלייה לכביש" dropdown at CSS (${_px(target.centerX)}, ${_px(target.centerY)}) [${_src(target)}]',
    );
    await _tapLocation(target, 10);
    _handlePhaseComplete(AutomationPhase.phase5a);
  }

  // ── Phase 5b — Select month value ───────────────────────────────────────────
  // Goal: tap the specific month option inside the now-open month dropdown.

  Future<void> _phase5bSelectMonthValue() async {
    const p = 'P5b';
    final monthHebrew = VehiclePublishData.monthToHebrew(formData.month);
    final monthSearch =
        monthHebrew != formData.month.trim()
            ? '$monthHebrew|${formData.month.trim()}'
            : monthHebrew;

    _step(p, '📸 Observing UI (month dropdown should be open)');
    final ctx = await _observeUIWithPopupHandling();
    if (ctx == null) {
      _handleRetry(AutomationPhase.phase5b, 'observeUI returned null');
      return;
    }

    _step(p, '🔍 Searching for month option "$monthSearch"');
    final target = await _findTarget(ctx, monthSearch);
    if (target == null) {
      _handleRetry(AutomationPhase.phase5b, '"$monthSearch" option not found');
      return;
    }

    _step(
      p,
      '👆 Tap month option at CSS (${_px(target.centerX)}, ${_px(target.centerY)}) [${_src(target)}]',
    );
    await _tapLocation(target, 10);

    await _wait(p, 'dropdown close animation', 500);
    _step(p, '📜 Scrolling down 3/4 screen to reveal hand/ownership fields');

    _handlePhaseComplete(AutomationPhase.phase5b);
  }

  // ── Phase 6 — Open hand dropdown ──────────────────────────────────────────
  // Goal: tap "בחירת יד" label to open the hand-selection dropdown.

  Future<void> _phase6OpenHandDropdown() async {
    await _scrollDown(0.25);
    const p = 'P6';
    _step(p, '📸 Observing UI');
    final ctx = await _observeUIWithPopupHandling();
    if (ctx == null) {
      _handleRetry(AutomationPhase.phase6, 'observeUI returned null');
      return;
    }

    _step(p, '🔍 Searching for hand dropdown label "בחירת יד"');
    final target = await _findTarget(ctx, 'בחירת יד');
    if (target == null) {
      _handleRetry(AutomationPhase.phase6, '"בחירת יד" not found');
      return;
    }

    _step(
      p,
      '👆 Tap "בחירת יד" at CSS (${_px(target.centerX)}, ${_px(target.centerY)}) [${_src(target)}]',
    );

    await _tapLocation(target, 10);
    _handlePhaseComplete(AutomationPhase.phase6);
  }

  // ── Phase 7 — Select hand value ───────────────────────────────────────────
  // Goal: tap the specific "יד X" option inside the now-open hand dropdown.

  Future<void> _phase7SelectHandValue() async {
    const p = 'P7';
    final handFull =
        formData.hand.startsWith('יד') ? formData.hand : 'יד ${formData.hand}';
    final handParts = handFull.split(' ');
    final handSearch =
        handParts.length > 1 ? '$handFull|${handParts.last}' : handFull;

    _step(p, '📸 Observing UI (hand dropdown should be open)');
    final ctx = await _observeUIWithPopupHandling();
    if (ctx == null) {
      _handleRetry(AutomationPhase.phase7, 'observeUI returned null');
      return;
    }

    _step(p, '🔍 Searching for hand option "$handSearch"');
    final target = await _findTarget(ctx, handSearch);
    if (target == null) {
      _handleRetry(AutomationPhase.phase7, '"$handSearch" not found');
      return;
    }

    _step(
      p,
      '👆 Tap hand option at CSS (${_px(target.centerX)}, ${_px(target.centerY)}) [${_src(target)}]',
    );
    await _tapLocation(target, 10);
    _handlePhaseComplete(AutomationPhase.phase7);
  }

  // ── Phase 8 — Open current-ownership dropdown ─────────────────────────────
  // Goal: tap "בעלות נוכחית" label to open the current ownership dropdown.

  Future<void> _phase8OpenCurrentOwnershipDropdown() async {
    await _scrollDown(0.25);
    const p = 'P8';
    _step(p, '📸 Observing UI');
    final ctx = await _observeUIWithPopupHandling();
    if (ctx == null) {
      _handleRetry(AutomationPhase.phase8, 'observeUI returned null');
      return;
    }

    _step(p, '🔍 Searching for ownership label "בעלות נוכחית"');
    final target = await _findTarget(ctx, 'בעלות נוכחית');
    if (target == null) {
      _handleRetry(AutomationPhase.phase8, '"בעלות נוכחית" not found');
      return;
    }

    _step(
      p,
      '👆 Tap "בעלות נוכחית" at CSS (${_px(target.centerX)}, ${_px(target.centerY)}) [${_src(target)}]',
    );
    await _tapLocation(target, 10);
    _handlePhaseComplete(AutomationPhase.phase8);
  }

  // ── Phase 9 — Select current-ownership value ──────────────────────────────
  // Goal: tap the ownership option (e.g. "פרטית") inside the now-open dropdown.

  Future<void> _phase9SelectCurrentOwnershipValue() async {
    const p = 'P9';
    _step(p, '📸 Observing UI (ownership dropdown should be open)');
    final ctx = await _observeUIWithPopupHandling();
    if (ctx == null) {
      _handleRetry(AutomationPhase.phase9, 'observeUI returned null');
      return;
    }

    _step(
      p,
      '🔍 Searching for current ownership value "${formData.currentOwnership}"',
    );
    final target = await _findTarget(ctx, formData.currentOwnership);
    if (target == null) {
      _handleRetry(
        AutomationPhase.phase9,
        '"${formData.currentOwnership}" not found',
      );
      return;
    }

    _step(
      p,
      '👆 Tap "${formData.currentOwnership}" at CSS (${_px(target.centerX)}, ${_px(target.centerY)}) [${_src(target)}]',
    );
    await _tapLocation(target, 0);
    _handlePhaseComplete(AutomationPhase.phase9);
  }

  // ── Phase 10 — Open previous-ownership dropdown ───────────────────────────
  // Goal: tap "בעלות מקורית" label (skipped entirely for יד ראשונה).

  Future<void> _phase10OpenPreviousOwnershipDropdown() async {
    await _scrollDown(0.25);
    const p = 'P10';
    final handTrimmed = formData.hand.trim();
    final isFirstHand =
        handTrimmed == 'ראשונה' ||
        handTrimmed == 'יד ראשונה' ||
        handTrimmed == '1' ||
        handTrimmed == 'יד 1' ||
        handTrimmed == 'ראשון';

    if (isFirstHand) {
      _step(p, '⏭️ Skipping previous ownership dropdown for first hand');
      _handlePhaseComplete(AutomationPhase.phase10);
      return;
    }

    _step(p, '📸 Observing UI');
    final ctx = await _observeUIWithPopupHandling();
    if (ctx == null) {
      _handleRetry(AutomationPhase.phase10, 'observeUI returned null');
      return;
    }

    _step(p, '🔍 Searching for previous ownership label "בעלות מקורית"');
    final target = await _findTarget(ctx, 'בעלות מקורית');
    if (target == null) {
      _handleRetry(AutomationPhase.phase10, '"בעלות מקורית" not found');
      return;
    }

    _step(
      p,
      '👆 Tap "בעלות מקורית" at CSS (${_px(target.centerX)}, ${_px(target.centerY)}) [${_src(target)}]',
    );
    await _tapLocation(target, 0);
    _handlePhaseComplete(AutomationPhase.phase10);
  }

  // ── Phase 11 — Select previous-ownership value ────────────────────────────
  // Goal: tap the previous ownership option inside the now-open dropdown.

  Future<void> _phase11SelectPreviousOwnershipValue() async {
    const p = 'P11';
    final handTrimmed = formData.hand.trim();
    final isFirstHand =
        handTrimmed == 'ראשונה' ||
        handTrimmed == 'יד ראשונה' ||
        handTrimmed == '1' ||
        handTrimmed == 'יד 1' ||
        handTrimmed == 'ראשון';

    if (isFirstHand) {
      _step(p, '⏭️ Skipping previous ownership selection for first hand');
      _handlePhaseComplete(AutomationPhase.phase11);
      return;
    }

    _step(p, '📸 Observing UI (previous-ownership dropdown should be open)');
    final ctx = await _observeUIWithPopupHandling();
    if (ctx == null) {
      _handleRetry(AutomationPhase.phase11, 'observeUI returned null');
      return;
    }

    _step(
      p,
      '🔍 Searching for previous ownership value "${formData.previousOwnership}"',
    );
    final target = await _findTarget(ctx, formData.previousOwnership);
    if (target == null) {
      _handleRetry(
        AutomationPhase.phase11,
        '"${formData.previousOwnership}" not found',
      );
      return;
    }

    _step(
      p,
      '👆 Tap "${formData.previousOwnership}" at CSS (${_px(target.centerX)}, ${_px(target.centerY)}) [${_src(target)}]',
    );
    await _tapLocation(target, 10);
    _handlePhaseComplete(AutomationPhase.phase11);
  }

  // ── Phase 12 — Enter kilometers ───────────────────────────────────────────
  // Goal: tap the km field, clear it, and type the mileage.

  Future<void> _phase12EnterKilometers() async {
    const p = 'P12';
    _step(p, '📸 Observing UI');
    final ctx = await _observeUIWithPopupHandling();
    if (ctx == null) {
      _handleRetry(AutomationPhase.phase12, 'observeUI returned null');
      return;
    }

    _step(p, '🔍 Searching for km field "קילומטראז"');
    final target = await _findTarget(ctx, 'קילומטראז');
    if (target == null) {
      _handleRetry(AutomationPhase.phase12, '"קילומטראז" not found');
      return;
    }

    _step(
      p,
      '👆 Tap km field at CSS (${_px(target.centerX)}, ${_px(target.centerY)}) [${_src(target)}]',
    );
    await _tapLocation(target, 10);
    await _wait(p, 'keyboard to appear', 300);

    _step(
      p,
      '⌨️  Typing kilometers: "${formData.kilometers}" (${formData.kilometers.length} chars)',
    );
    await _enterTextAtFocused(formData.kilometers);

    final typingMs = formData.kilometers.length * 200 + 100;
    await _wait(p, 'text input to settle', typingMs);
    await _dismissSoftKeyboard(p);
    await _wait(p, 'keyboard dismiss animation', 300);
    _handlePhaseComplete(AutomationPhase.phase12);
  }

  // ── Phase 13 — Scroll to top ───────────────────────────────────────────────
  // Goal: scroll back to top so the submit button is visible.

  Future<void> _phase13ScrollToTop() async {
    const p = 'P13';
    _step(p, '📜 Scrolling down to bring additional info field into view');
    await _scrollDown(0.25);
    await _wait(p, 'wait for scroll to settle', 800);
    _handlePhaseComplete(AutomationPhase.phase13);
  }

  Future<void> _phase14EnterAdditionalInfo() async {
    const p = 'P14';
    _step(p, '📸 Observing UI');
    final ctx = await _observeUIWithPopupHandling();
    if (ctx == null) {
      _handleRetry(AutomationPhase.phase14, 'observeUI returned null');
      return;
    }

    // _step(
    //   p,
    //   '🔍 Searching for additional info field label "מה חשוב לך שידעו" or placeholder "זה המקום"',
    // );
    // final target = await _findTarget(
    //   ctx,
    //   'מה חשוב לך שידעו|חשוב לך שידעו|זה המקום לתאר את הפרטים הבולטים|תאר את הפרטים|שידעו',
    // );

    // _step(p, '🎯 Focusing textarea via precise JS...');
    // final focused = await controller.runJavaScriptReturningResult('''
    //   (function() {
    //     // 1. Proximity search by label content
    //     var tags = document.querySelectorAll('*');
    //     for (var i = 0; i < tags.length; i++) {
    //       var tag = tags[i];
    //       if (tag.children.length === 0 && (tag.textContent.includes('חשוב') || tag.textContent.includes('שידעו'))) {
    //         var parent = tag.parentElement;
    //         for (var depth = 0; depth < 5; depth++) {
    //           if (!parent || parent === document.body) break;
    //           var input = parent.querySelector('textarea, input[type="text"]');
    //           if (input) {
    //             input.focus();
    //             input.click();
    //             return true;
    //           }
    //           parent = parent.parentElement;
    //         }
    //       }
    //     }
    //     // 2. Standard CSS selectors fallback
    //     var el = document.querySelector('textarea[placeholder*="זה המקום"]')
    //           || document.querySelector('textarea[placeholder*="פרטים"]')
    //           || document.querySelector('textarea[id^="text-area-"]')
    //           || document.querySelector('textarea');
    //     if (el) {
    //       el.focus();
    //       el.click();
    //       return true;
    //     }
    //     return false;
    //   })()
    // ''');

    // if (focused != true && focused != 'true') {
    //   if (target != null) {
    //     final text = target.text.toLowerCase();
    //     final isLabel =
    //         text.contains('חשוב') ||
    //         text.contains('מה') ||
    //         text.contains('שידעו');
    //     final deltaY = isLabel ? 45 : 0;
    //     _step(
    //       p,
    //       '⚠️ JS focus failed, tapping directly at target center with deltaY=$deltaY...',
    //     );
    //     await _tapLocation(target, deltaY);
    //   } else {
    //     _handleRetry(AutomationPhase.phase14, 'Textarea element not found');
    //     return;
    //   }
    // } else {
    //   _step(p, '⌨️ Textarea focused via JS');
    // }

    // await _wait(p, 'keyboard to appear', 300);

    // const txtValue = 'אין מה להוסיף מעבר לרשום';
    // _step(p, '⌨️ Typing additional info: "$txtValue"');
    // await _enterTextAtFocused(txtValue);

    // final typingMs = txtValue.length * 150 + 100;
    // await _wait(p, 'text input to settle', typingMs);
    // await _dismissSoftKeyboard(p);
    // await _wait(p, 'keyboard dismiss', 300);

    // Scroll down to counter any automatic keyboard-dismiss scroll up
    _step(
      p,
      '📜 Scroll down 0.5 screen after text entry to prevent scrolling up',
    );
    await _scrollDown(0.5);

    _step(p, '📸 Observing UI for "עדכנתי, בואו נמשיך" popup');
    final popupCtx = await _observeUIWithPopupHandling();
    if (popupCtx != null) {
      final popupTarget = await _findTarget(
        popupCtx,
        'עדכנתי בואו נמשיך|עדכנתי|בואו נמשיך',
      );
      if (popupTarget != null) {
        _step(p, '👆 Tapping "עדכנתי בואו נמשיך" popup button...');
        await _tapLocation(popupTarget, 0);
        await _wait(p, 'popup dismiss transition', 1200);

        // Clicking the popup might scroll the page back to the top.
        // Scroll down to keep the submit button in range!
        _step(
          p,
          '📜 Scrolling down post-popup to bring submit button back into view',
        );
        await _scrollDown(0.75);
      } else {
        _step(p, '🔍 "עדכנתי בואו נמשיך" popup not found, continuing...');
      }
    }

    _step(p, '📜 Scrolling down 3/4 screen to bring submit button into view');
    await _scrollDown(0.75);

    _step(p, '📸 Observing UI after scroll');
    final postScrollCtx = await _observeUIWithPopupHandling();
    if (postScrollCtx == null) {
      _handleError(
        AutomationPhase.phase14,
        'observeUI after scroll returned null',
      );
      return;
    }

    _step(p, '🔍 Searching for "לשלב הבא" submit button');
    final submitTarget = await _findTarget(
      postScrollCtx,
      'לשלב הבא|שלב הבא|לשלב',
    );
    if (submitTarget == null) {
      _handleError(
        AutomationPhase.phase14,
        'Submit button "לשלב הבא" not found',
      );
      return;
    }

    _step(p, '👆 Tapping "לשלב הבא" submit button');
    await _tapLocation(submitTarget, 0);

    await _wait(p, 'wait for submit click transition', 800);
    _step(p, '📸 Observing UI post-submit for "עדכנתי, בואו נמשיך" popup');
    final postSubmitCtx = await _observeUIWithPopupHandling();
    if (postSubmitCtx != null) {
      final popupTarget = await _findTarget(
        postSubmitCtx,
        'עדכנתי בואו נמשיך|עדכנתי|בואו נמשיך',
      );
      if (popupTarget != null) {
        _step(p, '👆 Tapping "עדכנתי בואו נמשיך" popup button post-submit...');
        await _tapLocation(popupTarget, 0);
        await _wait(p, 'popup dismiss transition', 1200);

        // Clicking the popup might scroll the page back to the top.
        // Scroll down to bring the "לשלב הבא" submit button back into view!
        _step(p, '📜 Scrolling down post-popup to find "לשלב הבא"');
        await _scrollDown(0.75);
        await _scrollDown(0.5);

        // After tapping "עדכנתי בואו נמשיך" post-submit, tap "לשלב הבא" again if we are still on this step
        _step(p, '📸 Re-observing UI after dismissing post-submit popup');
        final postPopupCtx = await _observeUIWithPopupHandling();
        if (postPopupCtx != null) {
          final resubmitTarget = await _findTarget(
            postPopupCtx,
            'לשלב הבא|שלב הבא|לשלב',
          );
          if (resubmitTarget != null) {
            _step(p, '👆 Tapping "לשלב הבא" submit button again...');
            await _tapLocation(resubmitTarget, 0);
            await _wait(p, 'wait for second submit click transition', 800);
          }
        }
      } else {
        _step(
          p,
          '🔍 "עדכנתי בואו נמשיך" popup not found post-submit, continuing...',
        );
      }
    }

    _handlePhaseComplete(AutomationPhase.phase14);
  }

  Future<void> _phase15EnterPrice() async {
    const p = 'P15';
    _step(p, '📸 Observing UI');
    final ctx = await _observeUIWithPopupHandling();
    if (ctx == null) {
      _handleRetry(AutomationPhase.phase15, 'observeUI returned null');
      return;
    }

    _step(p, '🔍 Searching for price input in shadow tree...');
    var priceTarget =
        ctx.findInput(id: 'price') ??
        ctx.findInput(placeholder: 'מחיר') ??
        ctx.findInput(placeholder: 'סכום');

    if (priceTarget == null) {
      // Fallback: search for elements with label "מחיר" or containing "מחיר"
      final matches = ctx.findAllByLabel('מחיר|סכום מינימלי|סכום');
      if (matches.isNotEmpty) {
        final match = matches.first;
        final deltaY =
            match.role == 'StaticText' || match.role == 'Label'
                ? (45 / devicePixelRatio)
                : 0.0;
        priceTarget = AxElement(
          id: match.id,
          role: match.role,
          label: match.label,
          x: match.x,
          y: match.y + deltaY,
          visible: match.visible,
        );
      }
    }

    if (priceTarget == null) {
      _handleRetry(
        AutomationPhase.phase15,
        'Price input element not found in shadow tree',
      );
      return;
    }

    _step(
      p,
      '👆 Tap price input at CSS (${_px(priceTarget.x)}, ${_px(priceTarget.y)}) [${priceTarget.id ?? "shadow tree"}]',
    );
    await _tapAt(priceTarget.x, priceTarget.y);
    await _wait(p, 'keyboard to appear', 300);

    final priceText = formData.price.isNotEmpty ? formData.price : '80000';
    _step(p, '⌨️ Typing price: "$priceText"');
    await _enterTextAtFocused(priceText);

    final typingMs = priceText.length * 150 + 100;
    await _wait(p, 'text input to settle', typingMs);
    await _dismissSoftKeyboard(p);
    await _wait(p, 'keyboard dismiss', 300);

    _handlePhaseComplete(AutomationPhase.phase15);
  }

  Future<void> _phase16SelectCity() async {
    await _scrollDown(0.4);
    const p = 'P16';
    _step(p, '📸 Observing UI');
    final ctx = await _observeUIWithPopupHandling();
    if (ctx == null) {
      _handleRetry(AutomationPhase.phase16, 'observeUI returned null');
      return;
    }

    _step(p, '🔍 Searching for city input in shadow tree...');
    var cityTarget =
        ctx.findInput(placeholder: 'ישוב') ??
        ctx.findInput(placeholder: 'יישוב') ??
        ctx.findInput(placeholder: 'הזינו טקסט') ??
        ctx.findInput(placeholder: 'הזינן טקסט') ??
        ctx.findInput(placeholder: 'הזינו') ??
        ctx.findInput(placeholder: 'הזינן') ??
        ctx.findInput(placeholder: 'טקסט') ??
        ctx.findInput(id: 'city');

    if (cityTarget == null) {
      // Fallback 1: search for elements with label "ישוב" or "יישוב" or "ישוב*" in axTree
      final matches = ctx.findAllByLabel('ישוב|יישוב|ישוב*|ישוב *|city');
      if (matches.isNotEmpty) {
        final match = matches.first;
        const inputRoles = {
          'text',
          'input',
          'textarea',
          'search',
          'number',
          'tel',
          'textbox',
          'combobox',
        };
        final isInput = inputRoles.contains(match.role.toLowerCase());
        final deltaY = !isInput ? (45 / devicePixelRatio) : 0.0;
        cityTarget = AxElement(
          id: match.id,
          role: match.role,
          label: match.label,
          x: match.x,
          y: match.y + deltaY,
          visible: match.visible,
        );
      }
    }

    if (cityTarget == null) {
      // Fallback 2: OCR search
      _step(
        p,
        '🔍 Shadow tree miss — falling back to OCR to find city input field...',
      );
      final ocrLoc = await _findTarget(ctx, 'ישוב*|ישוב|הזינו טקסט|הזינן טקסט');
      if (ocrLoc != null) {
        final deltaY =
            ocrLoc.text.contains('ישוב') ? (45 / devicePixelRatio) : 0.0;
        cityTarget = AxElement(
          id: null,
          role: 'ocr',
          label: ocrLoc.text,
          x: ocrLoc.centerX,
          y: ocrLoc.centerY + deltaY,
          visible: true,
        );
      }
    }

    if (cityTarget == null) {
      _handleRetry(AutomationPhase.phase16, 'City input element not found');
      return;
    }

    _step(
      p,
      '👆 Tap city input at CSS (${_px(cityTarget.x)}, ${_px(cityTarget.y)}) [${cityTarget.id ?? "shadow tree"}]',
    );
    await _tapAt(cityTarget.x, cityTarget.y);
    await _wait(p, 'keyboard to appear', 300);

    final cityVal = formData.city.isNotEmpty ? formData.city : 'חיפה';
    // Substring to enter all characters apart from the last one
    final typedVal =
        cityVal.length > 1 ? cityVal.substring(0, cityVal.length - 1) : cityVal;

    _step(p, '⌨️ Typing city prefix: "$typedVal" (full city is "$cityVal")');
    await _enterTextAtFocused(typedVal);

    final typingMs = typedVal.length * 150 + 100;
    await _wait(p, 'text input to settle', typingMs);

    _step(p, '📸 Observing UI to locate dropdown suggestion for "$cityVal"');
    final dropdownCtx = await _observeUIWithPopupHandling();
    if (dropdownCtx != null) {
      var suggestionTarget = await _findTarget(dropdownCtx, cityVal);

      // Shadow tree fallback if direct city text target wasn't found
      if (suggestionTarget == null) {
        _step(
          p,
          '⚠️ suggestion text not found on screen, searching shadow tree for list options...',
        );
        for (final el in dropdownCtx.axTree) {
          if (el.visible &&
              (el.role == 'option' ||
                  el.role == 'listitem' ||
                  el.role == 'menuitem')) {
            _step(
              p,
              '🎯 Found option element in shadow tree: "${el.label}" at (${el.x}, ${el.y})',
            );
            suggestionTarget = TextLocation(
              text: el.label,
              minX: el.x - 1,
              minY: el.y - 1,
              maxX: el.x + 1,
              maxY: el.y + 1,
              confidence: 100,
              fromAxTree: true,
            );
            break;
          }
        }
      }

      if (suggestionTarget != null) {
        _step(
          p,
          '👆 Tapping suggestion at CSS (${_px(suggestionTarget.centerX)}, ${_px(suggestionTarget.centerY)}) [${_src(suggestionTarget)}]',
        );
        await _tapLocation(suggestionTarget, 0);
        await _wait(p, 'dropdown selection settle', 1000);

        // Ensure soft keyboard is closed before searching for submit button
        await _dismissSoftKeyboard(p);
        await _wait(p, 'keyboard dismiss', 500);

        final submitted = await _clickSubmitButton(p, AutomationPhase.phase16);
        if (submitted) {
          _handlePhaseComplete(AutomationPhase.phase16);
          return;
        }
      }
    }

    _handleRetry(
      AutomationPhase.phase16,
      'Could not select "$cityVal" from dropdown suggestion list',
    );
  }

  Future<void> _phase17UploadPhotos() async {
    const p = 'P17';
    _step(p, '📸 Observing UI');
    final ctx = await _observeUIWithPopupHandling();
    if (ctx == null) {
      _handleRetry(AutomationPhase.phase17, 'observeUI returned null');
      return;
    }

    // Convert local images to base64 and upload them
    final images = formData.images;
    if (images == null || images.isEmpty) {
      _step(p, '⚠️ No images selected, proceeding directly to next step...');
    } else {
      _step(p, '⏳ Converting ${images.length} images to base64 for upload...');
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
          debugPrint('[Yad2] Error converting image $path to base64: $e');
        }
      }

      if (base64Files.isNotEmpty) {
        _step(
          p,
          '📤 Injecting ${base64Files.length} images into WebView file input...',
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
        _step(p, '✅ JS upload execution result: $result');

        // Wait for upload to complete on server/UI (e.g. 5 seconds)
        await _wait(
          p,
          'waiting for images to upload and previews to render',
          5000,
        );
      } else {
        _step(p, '⚠️ No valid local image files found to upload');
      }
    }

    _step(p, '📜 Scrolling down to bring next button into view');
    await _scrollDown(0.75);

    _step(p, '📸 Observing UI after scroll');
    final postScrollCtx = await _observeUIWithPopupHandling();
    if (postScrollCtx == null) {
      _handleRetry(AutomationPhase.phase17, 'observeUI returned null');
      return;
    }

    _step(p, '🔍 Searching for "לשלב הבא" or "המשך" submit button');
    final submitTarget = await _findTarget(
      postScrollCtx,
      'לשלב הבא|שלב הבא|המשך|לשלב',
    );
    if (submitTarget == null) {
      _handleRetry(
        AutomationPhase.phase17,
        'Submit button "לשלב הבא" or "המשך" not found on photos page',
      );
      return;
    }

    _step(p, '👆 Tapping submit button');
    await _tapLocation(submitTarget, 0);

    _handlePhaseComplete(AutomationPhase.phase17);
  }

  Future<bool> _clickSubmitButton(String p, AutomationPhase phase) async {
    _step(p, '📜 Scrolling down 3/4 screen to bring submit button into view');
    await _scrollDown(0.75);

    _step(p, '📸 Observing UI after scroll');
    final postScrollCtx = await _observeUIWithPopupHandling();
    if (postScrollCtx == null) {
      _handleError(phase, 'observeUI after scroll returned null');
      return false;
    }

    _step(p, '🔍 Searching for "לשלב הבא" submit button');
    final submitTarget = await _findTarget(
      postScrollCtx,
      'לשלב הבא|שלב הבא|לשלב',
    );
    if (submitTarget == null) {
      _handleError(phase, 'Submit button "לשלב הבא" not found');
      return false;
    }

    _step(p, '👆 Tapping "לשלב הבא" submit button');
    await _tapLocation(submitTarget, 0);
    return true;
  }

  Future<UIContext?> _observeUIWithPopupHandling() async {
    final ctx = await observeUI();
    if (ctx == null) return null;

    final dismissed = await _dismissGotItPopup(ctx);
    if (dismissed) {
      debugPrint('[Yad2] 🔄 Re-observing UI after dismissing popup');
      return observeUI();
    }

    return ctx;
  }

  Future<bool> _dismissGotItPopup(UIContext ctx) async {
    const targetText = 'הבנתי';

    // 1. AxTree check
    final allMatches = ctx.findAllByLabel(targetText);
    if (allMatches.isNotEmpty) {
      final el = allMatches.first;
      debugPrint(
        '[Yad2] 💡 Detected popup dismiss button "הבנתי" in AxTree at CSS (${el.x}, ${el.y})',
      );
      await _tapAt(el.x, el.y);
      await _wait('Popup Dismiss', 'Waiting for popup to dismiss', 1500);
      return true;
    }

    // 2. OCR check
    final raw = await ocrService.findTextLocation(ctx.screenshot, targetText);
    if (raw != null) {
      final loc = _toCssLocation(raw);
      debugPrint(
        '[Yad2] 💡 Detected popup dismiss button "הבנתי" via OCR at CSS (${loc.centerX}, ${loc.centerY})',
      );
      await _tapAt(loc.centerX, loc.centerY);
      await _wait('Popup Dismiss', 'Waiting for popup to dismiss', 1500);
      return true;
    }

    return false;
  }

  // ── Hybrid target finder ───────────────────────────────────────────────────

  /// Tries the AxTree first; falls back to OCR (with CSS scaling) if not found.
  /// Always returns CSS coordinates.
  Future<TextLocation?> _findTarget(
    UIContext context,
    String targetText, {
    int targetInstance = 1,
  }) async {
    // Dump full AxTree so misses can be diagnosed
    if (context.axTree.isEmpty) {
      debugPrint('[Yad2] 🌳 AxTree is EMPTY');
    } else {
      final buf = StringBuffer(
        '[Yad2] 🌳 AxTree dump (${context.axTree.length} elements):\n',
      );
      for (int i = 0; i < context.axTree.length; i++) {
        final el = context.axTree[i];
        buf.write(
          '  [$i] role=${el.role.padRight(10)} visible=${el.visible} '
          'x=${el.x.toStringAsFixed(0).padLeft(4)} y=${el.y.toStringAsFixed(0).padLeft(4)} '
          'id="${el.id ?? ""}" label="${el.label}"\n',
        );
      }
      debugPrint(buf.toString());
    }

    // AxTree lookup — supports any instance (exact matches ranked before substrings)
    final allMatches = context.findAllByLabel(targetText);
    if (allMatches.length >= targetInstance) {
      final el = allMatches[targetInstance - 1];
      debugPrint(
        '[Yad2] 🌳 AxTree hit (instance $targetInstance/${allMatches.length}): "${el.label}" role=${el.role} at CSS (${el.x}, ${el.y})',
      );
      return TextLocation(
        text: targetText,
        minX: el.x - 1,
        minY: el.y - 1,
        maxX: el.x + 1,
        maxY: el.y + 1,
        confidence: 100,
        fromAxTree: true,
      );
    }

    debugPrint(
      '[Yad2] 🔍 AxTree miss for "$targetText" (need instance $targetInstance, found ${allMatches.length}) — falling back to OCR',
    );
    return _ocrFindCss(context.screenshot, targetText, targetInstance);
  }

  /// OCR search that returns coordinates already scaled to CSS pixels.
  Future<TextLocation?> _ocrFindCss(
    Uint8List screenshot,
    String searchText,
    int targetInstance,
  ) async {
    onOcrFallback?.call();
    final isMultiWord = searchText.contains(' ') && !searchText.contains('|');
    final raw =
        isMultiWord
            ? await ocrService.findMultiWordPhrase(
              screenshot,
              searchText,
              targetInstance: targetInstance,
            )
            : await ocrService.findTextLocation(
              screenshot,
              searchText,
              targetInstance: targetInstance,
            );
    return raw != null ? _toCssLocation(raw) : null;
  }

  // ── Coordinate / source label helpers ─────────────────────────────────────

  String _px(double v) => v.toStringAsFixed(0);
  String _src(TextLocation loc) => loc.fromAxTree ? 'AxTree' : 'OCR';

  // ── Phase transitions ─────────────────────────────────────────────────────

  void _handlePhaseComplete(AutomationPhase phase) {
    debugPrint('[Yad2] ✅ Phase complete: ${phase.description}');
    onPhaseComplete?.call(phase);

    AutomationPhase? next;
    int delayMs = 1000;

    switch (phase) {
      case AutomationPhase.phase1:
        next = AutomationPhase.phase2;
        delayMs = 1500;
      case AutomationPhase.phase2:
        next = AutomationPhase.phase3;
        delayMs = 2500; // wait for car lookup API response
      case AutomationPhase.phase3:
        next = AutomationPhase.phase4;
        delayMs = 3000; // wait for vehicle detail page to load
      case AutomationPhase.phase4:
        next = AutomationPhase.phase5;
      case AutomationPhase.phase5:
        next = AutomationPhase.phase5a;
        delayMs = 1500; // wait for scroll animation to complete
      case AutomationPhase.phase5a:
        next = AutomationPhase.phase5b;
        delayMs = 1500; // wait for month dropdown to open
      case AutomationPhase.phase5b:
        next = AutomationPhase.phase5c;
        delayMs = 1000; // wait for month to settle
      case AutomationPhase.phase5c:
        next = (!formData.govIl && !formData.noTest)
            ? AutomationPhase.phase5c1
            : AutomationPhase.phase5d;
        delayMs = 500;
      case AutomationPhase.phase5c1:
        next = AutomationPhase.phase5c2;
        delayMs = 1500;
      case AutomationPhase.phase5c2:
        next = AutomationPhase.phase5c3;
        delayMs = 1500;
      case AutomationPhase.phase5c3:
        next = AutomationPhase.phase5c4;
        delayMs = 1500;
      case AutomationPhase.phase5c4:
        next = AutomationPhase.phase5d;
        delayMs = 1000;
      case AutomationPhase.phase5d:
        next = AutomationPhase.phase5e;
        delayMs = 500;
      case AutomationPhase.phase5e:
        next = AutomationPhase.phase5f;
        delayMs = 500;
      case AutomationPhase.phase5f:
        next = AutomationPhase.phase6;
        delayMs = 500;
      case AutomationPhase.phase6:
        next = AutomationPhase.phase7;
        delayMs = 1500; // wait for hand dropdown to open
      case AutomationPhase.phase7:
        next = AutomationPhase.phase8;
        delayMs = 1000; // wait for ownership dropdown to appear
      case AutomationPhase.phase8:
        next = AutomationPhase.phase9;
        delayMs = 1500; // wait for ownership dropdown to open
      case AutomationPhase.phase9:
        // Conditional: skip phases 10/11 if first hand
        final handTrimmed = formData.hand.trim();
        final isFirstHand =
            handTrimmed == 'ראשונה' ||
            handTrimmed == 'יד ראשונה' ||
            handTrimmed == '1' ||
            handTrimmed == 'יד 1' ||
            handTrimmed == 'ראשון';
        next = isFirstHand ? AutomationPhase.phase12 : AutomationPhase.phase10;
      case AutomationPhase.phase10:
        next = AutomationPhase.phase11;
      case AutomationPhase.phase11:
        next = AutomationPhase.phase12;
      case AutomationPhase.phase12:
        next = AutomationPhase.phase13;
      case AutomationPhase.phase13:
        next = AutomationPhase.phase14;
        delayMs = 2500;
      case AutomationPhase.phase14:
        next = AutomationPhase.phase15;
        delayMs = 3000;
      case AutomationPhase.phase15:
        next = AutomationPhase.phase16;
        delayMs = 2500;
      case AutomationPhase.phase16:
        next = AutomationPhase.phase17;
        delayMs = 3000;
      case AutomationPhase.phase17:
        next = AutomationPhase.phase18;
        delayMs = 2000;
      case AutomationPhase.phase18:
        next = AutomationPhase.phase19;
        delayMs = 2000;
      case AutomationPhase.phase19:
        next = AutomationPhase.complete;
        delayMs = 1500;
      case AutomationPhase.complete:
        _stopSampling();
        onAutomationComplete?.call(true);
        return;
    }

    Future.delayed(Duration(milliseconds: delayMs), () {
      _processPhase(next!);
    });
  }

  Future<void> _handleError(AutomationPhase phase, String error) async {
    debugPrint(
      '[Yad2] ❌ Phase error: ${phase.description} — $error (Self-pausing automation)',
    );
    _isPaused = true;
    _pausedPhase = phase;
    _phaseRetryCount = 0; // reset retry counter so resume gets fresh attempts
    _stopSampling();
    try {
      await _beepUser();
    } catch (e) {
      debugPrint('[Yad2] Error playing error beep: $e');
    }
    onPhaseError?.call(phase, error);
  }

  void _handleRetry(AutomationPhase phase, String reason) {
    if (_isPaused) {
      _pausedPhase = phase;
      debugPrint(
        '[Yad2] ⏸️ Automation paused during retry of phase: ${phase.name}',
      );
      return;
    }
    if (_phaseRetryCount < _maxRetries) {
      _phaseRetryCount++;
      debugPrint(
        '[Yad2] 🔄 Retrying phase $_phaseRetryCount/$_maxRetries — $reason',
      );
      Future.delayed(const Duration(milliseconds: 1000), () {
        _executePhase(phase);
      });
    } else {
      _handleError(phase, reason);
    }
  }

  // ── JS helpers ─────────────────────────────────────────────────────────────

  /// Simulates a finger tap using every known technique in order:
  ///   1. TouchEvent  (Android WebView primary path)
  ///   2. PointerEvent (W3C standard)
  ///   3. MouseEvent   (desktop React fallback)
  ///   4. el.click()   (DOM native)
  ///   5. React-fiber  (direct synthetic event via __reactFiber props)
  ///   6. Ancestor walk (retry each parent up to 4 levels)
  Future<void> _tapAt(double cssX, double cssY) async {
    debugPrint('[Yad2] 🖱️  Tap at CSS ($cssX, $cssY)');
    try {
      final elInfo = await controller.runJavaScriptReturningResult('''
        (function() {
          var el = document.elementFromPoint($cssX, $cssY);
          if (!el) return "null";
          return el.tagName + "|class=" + (el.className||"") + "|text=" + (el.textContent||"").trim().substring(0,60);
        })()
      ''');
      debugPrint('[Yad2] 🎯  Element at ($cssX, $cssY): $elInfo');
    } catch (e) {
      debugPrint('[Yad2] ⚠️  Could not inspect element: $e');
    }
    onTapPreview?.call(cssX, cssY);
    await Future.delayed(const Duration(milliseconds: 300));
    await controller.runJavaScript('''
      (function() {
        var x = $cssX, y = $cssY;
        var el = document.elementFromPoint(x, y);
        if (!el) return;
        if (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA') el.focus();

        var eOpts = { bubbles: true, cancelable: true, composed: true,
                      clientX: x, clientY: y, screenX: x, screenY: y };

        // ── 1. TouchEvent ──────────────────────────────────────────────────────
        try {
          var t = new Touch({ identifier: Date.now(), target: el,
            clientX: x, clientY: y, screenX: x, screenY: y,
            pageX: x + window.scrollX, pageY: y + window.scrollY,
            radiusX: 11.5, radiusY: 11.5, rotationAngle: 0, force: 1 });
          var tl = [t];
          el.dispatchEvent(new TouchEvent('touchstart', { bubbles:true, cancelable:true, composed:true,
            touches:tl, targetTouches:tl, changedTouches:tl }));
          el.dispatchEvent(new TouchEvent('touchend',   { bubbles:true, cancelable:true, composed:true,
            touches:[], targetTouches:[], changedTouches:tl }));
        } catch(e) {}

        // ── 2. PointerEvent ────────────────────────────────────────────────────
        try {
          el.dispatchEvent(new PointerEvent('pointerdown', eOpts));
          el.dispatchEvent(new PointerEvent('pointerup',   eOpts));
        } catch(e) {}

        // ── 3. MouseEvent ──────────────────────────────────────────────────────
        try {
          el.dispatchEvent(new MouseEvent('mousedown', eOpts));
          el.dispatchEvent(new MouseEvent('mouseup',   eOpts));
          el.dispatchEvent(new MouseEvent('click',     eOpts));
        } catch(e) {}

        // ── 4. Native DOM click ────────────────────────────────────────────────
        try { el.click(); } catch(e) {}

        // ── 5. React-fiber synthetic onClick ──────────────────────────────────
        try {
          var fiberKey = Object.keys(el).find(function(k) {
            return k.startsWith('__reactFiber') || k.startsWith('__reactInternalInstance');
          });
          if (fiberKey) {
            var fiber = el[fiberKey];
            while (fiber) {
              var props = fiber.memoizedProps || fiber.pendingProps;
              if (props && typeof props.onClick === 'function') {
                props.onClick({ type:'click', target:el, currentTarget:el,
                  clientX:x, clientY:y, bubbles:true, preventDefault:function(){},
                  stopPropagation:function(){} });
                break;
              }
              fiber = fiber.return;
            }
          }
        } catch(e) {}

        // ── 6. Ancestor walk (for delegated handlers) ─────────────────────────
        try {
          var walk = el.parentElement;
          for (var i = 0; i < 4; i++) {
            if (!walk || walk === document.body) break;
            walk.dispatchEvent(new TouchEvent('touchstart', { bubbles:true, cancelable:true, composed:true,
              touches:[new Touch({identifier:Date.now()+i+1, target:walk,
                clientX:x, clientY:y, screenX:x, screenY:y,
                pageX:x+window.scrollX, pageY:y+window.scrollY,
                radiusX:11.5,radiusY:11.5,rotationAngle:0,force:1})],
              targetTouches:[], changedTouches:[] }));
            walk.dispatchEvent(new TouchEvent('touchend', { bubbles:true, cancelable:true, composed:true,
              touches:[], targetTouches:[], changedTouches:[] }));
            walk.dispatchEvent(new MouseEvent('click', eOpts));
            walk = walk.parentElement;
          }
        } catch(e) {}

        // ── 7. Force-close open dropdowns ────────────────────────────────────
        // React dropdowns close via a document-level "mousedown outside" handler.
        // Skip for input/textarea so we don't steal focus before text entry.
        try {
          var tag = el.tagName;
          var isInput = tag === 'INPUT' || tag === 'TEXTAREA';
          if (!isInput) {
            el.blur();
            var safeX = x < 10 ? x + 5 : x - 5;
            var safeY = y < 10 ? y + 5 : y - 5;
            var outsideOpts = { bubbles: true, cancelable: true,
              clientX: safeX, clientY: safeY,
              screenX: safeX, screenY: safeY };
            document.dispatchEvent(new MouseEvent('mousedown', outsideOpts));
            document.dispatchEvent(new MouseEvent('mouseup',   outsideOpts));
            document.dispatchEvent(new MouseEvent('click',     outsideOpts));
            // Also try Escape — closes modal-style dropdowns
            document.dispatchEvent(new KeyboardEvent('keydown', {
              key:'Escape', code:'Escape', keyCode:27, which:27,
              bubbles:true, cancelable:true
            }));
          }
        } catch(e) {}
      })();
    ''');
  }

  Future<void> _tapLocation(TextLocation loc, int deltaY) =>
      _tapAt(loc.centerX, loc.centerY + deltaY);

  /// Blurs the active WebView input element so Android hides the soft keyboard.
  Future<void> _dismissSoftKeyboard(String phaseLabel) async {
    debugPrint('[Yad2] $phaseLabel  ⌨️↓ Dismissing soft keyboard');
    await controller.runJavaScript('''
      (function() {
        var el = document.activeElement;
        if (el) el.blur();
      })();
    ''');
  }

  Future<void> _enterTextAtFocused(String text) async {
    final escaped = text.replaceAll("'", "\\'");
    debugPrint('[Yad2] ⌨️  Entering text: "$text"');
    await controller.runJavaScript('''
      (function() {
        var el = document.activeElement;
        if (!el || (el.tagName !== 'INPUT' && el.tagName !== 'TEXTAREA')) return;
        el.focus();
        // Try execCommand first (works with React controlled inputs)
        try {
          el.select();
          var ok = document.execCommand('insertText', false, '$escaped');
          if (ok) return;
        } catch(e) {}
        // Fallback: native setter + dispatch events (also triggers React)
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

  Future<void> _scrollDown(double percent) async {
    debugPrint('[Yad2] 📜 Scroll down 3/4 screen');
    await controller.runJavaScript('''
      (function() {
        var scrollAmt = window.innerHeight * $percent;
        window.scrollBy({ top: scrollAmt, behavior: 'smooth' });
      })();
    ''');
    await Future.delayed(Duration(milliseconds: 1000));
  }

  // ── Coordinate scaling (physical px → CSS px) ─────────────────────────────

  TextLocation _toCssLocation(TextLocation loc) => TextLocation(
    text: loc.text,
    minX: loc.minX / devicePixelRatio,
    minY: loc.minY / devicePixelRatio,
    maxX: loc.maxX / devicePixelRatio,
    maxY: loc.maxY / devicePixelRatio,
    confidence: loc.confidence,
  );
}
