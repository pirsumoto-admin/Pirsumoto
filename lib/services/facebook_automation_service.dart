import 'publication_description_service.dart';
import 'publication_result_verifier.dart';
import 'automation_task_scheduler.dart';
import 'automation_accessibility_channel.dart';
import 'native_image_upload_request.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'yad2_automation_models.dart' show VehiclePublishData;

// ---------------------------------------------------------------------------
// Facebook Marketplace – Vehicle Listing Automation Service
// ---------------------------------------------------------------------------
// Architecture mirrors Yad2AccessibilityAutomationService:
//   • Uses Android AccessibilityService via MethodChannel for native taps/text
//   • Falls back to shadow-DOM JS click for elements the native tree misses
//   • Phase chain: login gate → viewport → category → price → title → submit
//
// HTML elements automated (from facebook_screen.dart observations):
//   Phase 1  – Login gate       : detect password input / "Log in" text
//   Phase 2  – Set viewport     : meta[name=viewport] width=1280
//   Phase 3  – Open category    : [role="combobox"]:nth(1) → click
//   Phase 4  – Select Vehicle   : [role="option"]:first → click
//   Phase 5  – Enter price      : input[placeholder*="price" / aria-label*="Price"]
//   Phase 6  – Enter title/desc : textarea or contenteditable for listing title
//   Phase 7  – Condition        : [role="radio"] for "Used" vehicle condition
//   Phase 8  – Upload photos    : accessibility tap and Android native file chooser
//   Phase 9  – Publish          : button[text="Publish"|"Next"] click chain
// ---------------------------------------------------------------------------

// ── Phase enum ───────────────────────────────────────────────────────────────

enum FacebookAutomationPhase {
  loginGate('Login gate', 'שער כניסה / התחברות'),
  setViewport('Set viewport', 'הגדרת תצוגה'),
  selectVehicleType('Select vehicle type', 'בחירת סוג רכב'),
  uploadPhotos('Upload photos', 'העלאת תמונות'),
  enterYear('Enter year', 'בחירת שנה'),
  enterMake('Enter make', 'הזנת יצרן'),
  enterModel('Enter model', 'הזנת דגם'),
  enterMileage('Enter mileage', 'הזנת קילומטראז\' / מיילים'),
  enterPrice('Enter price', 'הזנת מחיר'),
  selectBodyStyle('Select body style', 'בחירת סגנון גוף הרכב'),
  selectCleanTitle('Select clean title', 'בחירת טייטל נקי'),
  selectCondition('Select condition', 'בחירת מצב הרכב'),
  selectFuelType('Select fuel type', 'בחירת סוג דלק'),
  selectTransmission('Select transmission', 'בחירת תיבת הילוכים'),
  enterDescription('Enter description', 'הזנת תיאור'),
  publish('Publish listing', 'פרסום המודעה'),
  selectGroups('Select groups', 'בחירת קבוצות'),
  complete('Automation complete', 'האוטומציה הושלמה');

  final String description;
  final String descriptionHe;
  const FacebookAutomationPhase(this.description, this.descriptionHe);
}

// ── Ported Yad2 Execution Architecture ───────────────────────────────────────

typedef _StepAction = Future<_StepActionResult> Function();
typedef _StepValidator = Future<bool> Function();

class _StepActionResult {
  final bool success;
  final String reason;
  final FacebookAutomationPhase? completeAs;

  const _StepActionResult.success({this.completeAs})
    : success = true,
      reason = 'ok';

  const _StepActionResult.failure(this.reason)
    : success = false,
      completeAs = null;
}

class _StepValidation {
  final String? mustContain;
  final String? mustNotContain;
  final String? selectedValue;
  final String? selectedAfterLabel;
  final int selectedAfterOffset;
  final String? nextMarker;
  final Duration timeout;
  final _StepValidator? custom;

  const _StepValidation({
    this.mustContain,
    this.mustNotContain,
    this.selectedValue,
    this.selectedAfterLabel,
    this.selectedAfterOffset = 1,
    this.nextMarker,
    this.timeout = const Duration(seconds: 4),
    this.custom,
  });
}

class _AutomationStepSpec {
  final FacebookAutomationPhase phase;
  final String goal;
  final _StepAction action;
  final _StepValidation? validation;
  final Duration settleDelay;

  const _AutomationStepSpec({
    required this.phase,
    required this.goal,
    required this.action,
    this.validation,
    this.settleDelay = const Duration(milliseconds: 500),
  });
}

// ── Service ───────────────────────────────────────────────────────────────────

class FacebookAutomationService {
  final VehiclePublishData formData;
  final WebViewController controller;

  final void Function(FacebookAutomationPhase phase)? onPhaseComplete;
  final void Function(FacebookAutomationPhase phase, String error)?
  onPhaseError;
  final void Function(bool success)? onAutomationComplete;
  final VoidCallback? onFirstStepDetected;
  final void Function(double cssX, double cssY)? onTapPreview;

  static const int _maxRetries = 3;
  int _phaseRetryCount = 0;
  bool _isPaused = false;
  FacebookAutomationPhase? _pausedPhase;
  FacebookAutomationPhase? _currentPhase;
  Timer? _loginSamplingTimer;
  bool _loginGateTickBusy = false;

  bool _stopped = false;
  bool _started = false;
  bool _actionInterrupted = false;
  bool _publishAttempted = false;
  final Set<String> _completedPhaseActions = {};

  bool get _inputBlocked {
    if (!_stopped && !_isPaused) return false;
    _actionInterrupted = true;
    return true;
  }

  void _savePhase(FacebookAutomationPhase phase) {
    if (_currentPhase != phase) _completedPhaseActions.clear();
    _currentPhase = phase;
    _pausedPhase = _isPaused ? phase : null;
  }

  Future<bool> _runOnce(String key, Future<bool> Function() action) async {
    if (_completedPhaseActions.contains(key)) return true;
    if (_inputBlocked) return false;
    final succeeded = await action();
    if (succeeded && !_actionInterrupted) _completedPhaseActions.add(key);
    return succeeded;
  }

  // MethodChannel – same channel as the existing Accessibility service
  static const MethodChannel _channel = MethodChannel(
    'com.pirsumoto/accessibility',
  );

  // ── Permission helpers ────────────────────────────────────────────────────

  static Future<bool> checkPermission() async {
    try {
      if (Platform.isAndroid) {
        final bool? hasPermission = await _channel.invokeMethod<bool>(
          'checkPermission',
        );
        return hasPermission ?? false;
      }
      return true;
    } catch (_) {
      return false;
    }
  }

  static Future<void> openSettings() async {
    try {
      if (Platform.isAndroid) {
        await _channel.invokeMethod('openSettings');
      }
    } catch (e) {
      debugPrint('[FB-A11y] Error opening settings: $e');
    }
  }

  // ── Public API ────────────────────────────────────────────────────────────

  static FacebookAutomationService? activeInstance;

  static void stopAll() {
    activeInstance?.stop();
    activeInstance = null;
  }

  bool get isPaused => _isPaused;
  FacebookAutomationPhase? get pausedPhase => _pausedPhase;

  FacebookAutomationService({
    required this.formData,
    required this.controller,
    this.onPhaseComplete,
    this.onPhaseError,
    this.onAutomationComplete,
    this.onFirstStepDetected,
    this.onTapPreview,
  }) {
    activeInstance = this;
  }

  final _scheduler = AutomationTaskScheduler();
  late final _automationChannel = AutomationAccessibilityChannel((reason) {
    if (_stopped || _isPaused) return;
    pauseAutomation();
    debugPrint('[Facebook] Interrupted at ${_currentPhase?.name}: $reason');
    onPhaseError?.call(
      _currentPhase ?? FacebookAutomationPhase.loginGate,
      'האוטומציה הושהתה בשלב הנוכחי: $reason. החזר את מסך הפרסום ולחץ המשך.',
    );
  });
  Future<bool> _ensureAutomationWindow() async {
    try {
      return await _automationChannel.invokeMethod<bool>(
            'checkAutomationWindow',
          ) ??
          false;
    } catch (_) {
      return false;
    }
  }

  final Set<Future<void>> _inFlight = {};
  Future<void> pauseAndWait() async {
    pauseAutomation();
    while (_inFlight.isNotEmpty) {
      await Future.wait(
        _inFlight.toList(),
      ).timeout(const Duration(seconds: 45));
    }
  }

  Future<void> stopAndWait() async {
    stop();
    while (_inFlight.isNotEmpty) {
      await Future.wait(
        _inFlight.toList(),
      ).timeout(const Duration(seconds: 45));
    }
  }

  NativeImageUploadRequest? _imageUploadRequest;

  void _cancelImageUpload() {
    _imageUploadRequest?.cancel();
    _imageUploadRequest = null;
  }

  /// Called by AndroidWebViewController's native onShowFileChooser bridge.
  List<String> handleNativeImageChooser({required bool allowMultiple}) {
    if (_inputBlocked) return const [];
    return _imageUploadRequest?.select(allowMultiple: allowMultiple) ??
        const [];
  }

  void stop() {
    _cancelImageUpload();
    _scheduler.invalidate();
    _stopped = true;
    debugPrint('[FB-A11y] 🛑 Stop requested');
    _stopLoginGate();
    _isPaused = true;
    _currentPhase = null;
    _pausedPhase = null;
    try {
      WakelockPlus.disable();
    } catch (_) {}
  }

  void dispose() {
    _cancelImageUpload();
    _scheduler.invalidate();
    _stopped = true;
    stop();
    if (activeInstance == this) {
      activeInstance = null;
    }
  }

  void pauseAutomation() {
    _cancelImageUpload();
    _scheduler.invalidate();
    debugPrint('[FB-A11y] ⏸️ Pause requested');
    _stopLoginGate();
    _isPaused = true;
    _pausedPhase = _currentPhase;
  }

  Future<void> selectResumePhase(FacebookAutomationPhase phase) async {
    await pauseAndWait();
    if (_stopped) return;
    _completedPhaseActions.clear();
    _pausedPhase = phase;
    _currentPhase = phase;
  }

  void resumeAutomation() {
    if (_stopped || !_isPaused) return;
    _scheduler.invalidate();
    final generation = _scheduler.generation;
    if (_inFlight.isNotEmpty) {
      Future.wait(_inFlight.toList())
          .then((_) {
            if (!_stopped && generation == _scheduler.generation)
              resumeAutomation();
          })
          .catchError((Object e) {
            debugPrint('[Facebook] Cannot resume before phase drains: $e');
          });
      return;
    }
    _stopLoginGate();
    _isPaused = false;
    final phase =
        _pausedPhase ?? _currentPhase ?? FacebookAutomationPhase.loginGate;
    _pausedPhase = null;
    _processPhase(phase);
  }

  void stepBack() {
    final current = _pausedPhase ?? _currentPhase;
    if (current == null) return;
    final idx = current.index;
    if (idx > 0) {
      final prev = FacebookAutomationPhase.values[idx - 1];
      debugPrint(
        '[FB-A11y] ↩️ Stepping back from ${current.name} to ${prev.name}',
      );
      _pausedPhase = prev;
      _currentPhase = prev;
    }
  }

  void startAutomation() {
    if (_stopped) return;
    _scheduler.invalidate();
    debugPrint('[FB-A11y] 🚀 Starting Facebook automation');
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    try {
      WakelockPlus.enable();
    } catch (_) {}
    _processPhase(FacebookAutomationPhase.loginGate);
  }

  // ── Phase dispatcher ──────────────────────────────────────────────────────

  void _processPhase(FacebookAutomationPhase phase) {
    if (_stopped) return;
    _savePhase(phase);
    _phaseRetryCount = 0;
    if (_isPaused) {
      _pausedPhase = phase;
      debugPrint('[FB-A11y] ⏸️ Paused at: ${phase.name}');
      return;
    }
    _executePhase(phase);
  }

  Future<void> _executePhase(FacebookAutomationPhase phase) async {
    if (_stopped) return;
    final work = _scheduler.run(() async {
      try {
        await _executePhaseTracked(phase);
      } catch (e, st) {
        debugPrint('[FB-A11y] Phase failed: $e\n$st');
        if (!_stopped && !_isPaused) {
          _handleRetry(phase, e.toString());
        }
      }
    });
    _inFlight.add(work);
    try {
      await work;
    } finally {
      _inFlight.remove(work);
    }
  }

  Future<void> _executePhaseTracked(FacebookAutomationPhase phase) async {
    _currentPhase = phase;
    if (_isPaused) {
      _pausedPhase = phase;
      return;
    }

    if (!await _ensureAutomationWindow() || _stopped || _isPaused) return;

    debugPrint('[FB-A11y] ════════════════════════════════════════');
    debugPrint(
      '[FB-A11y] ${phase.name.toUpperCase()}  attempt ${_phaseRetryCount + 1}/${_maxRetries + 1}',
    );
    debugPrint('[FB-A11y] ════════════════════════════════════════');

    if (phase == FacebookAutomationPhase.complete) {
      bool confirmed = false;
      try {
        confirmed = await _retryUntil(
          () => publicationIsConfirmed(controller, 'facebook'),
          timeout: const Duration(seconds: 20),
        );
      } catch (_) {}
      if (_stopped || _isPaused) return;
      if (!confirmed) {
        _handleError(
          phase,
          'לא התקבל אישור פרסום מפייסבוק. יש לבדוק את האתר לפני ניסיון נוסף.',
        );
        return;
      }
      WakelockPlus.disable();
      _handlePhaseComplete(FacebookAutomationPhase.complete);
      return;
    }

    final spec = _buildStepSpec(phase);
    if (spec == null) {
      _handleRetry(phase, 'No optimized step spec is registered.');
      return;
    }

    _StepActionResult result;
    try {
      _actionInterrupted = false;
      result = await spec.action();
      if (_stopped || _actionInterrupted) return;
    } catch (e, st) {
      debugPrint('[FB-A11y] Phase exception: $e\n$st');
      await _failOrRecover(spec, e.toString());
      return;
    }

    if (!result.success) {
      await _failOrRecover(spec, result.reason);
      return;
    }

    final completedPhase = result.completeAs ?? phase;
    _savePhase(
      _nextPhaseAfter(completedPhase) ?? FacebookAutomationPhase.complete,
    );
    if (_isPaused) return;

    try {
      await _waitForUiSettle(spec.settleDelay);
      if (_stopped || _isPaused) return;

      if (spec.validation != null) {
        final validationPassed = await _validateStep(spec);
        if (!validationPassed) {
          debugPrint(
            '[FB-A11y] ⚠️ Soft validation miss for ${phase.name} '
            '(a11y tree did not confirm "${spec.goal}") — proceeding on '
            'action success.',
          );
        }
      }
    } catch (e) {
      debugPrint('[FB-A11y] Advisory verification failed: $e');
    }

    if (_stopped || _isPaused) return;
    _phaseRetryCount = 0;
    _handlePhaseComplete(completedPhase);
  }

  _AutomationStepSpec? _buildStepSpec(FacebookAutomationPhase phase) {
    switch (phase) {
      case FacebookAutomationPhase.loginGate:
        return _AutomationStepSpec(
          phase: phase,
          goal: 'Login Gate',
          action: () async {
            return await _phaseLoginGate();
          },
        );
      case FacebookAutomationPhase.setViewport:
        return _AutomationStepSpec(
          phase: phase,
          goal: 'Set Viewport',
          action: () async {
            return await _phaseSetViewport();
          },
        );
      case FacebookAutomationPhase.selectVehicleType:
        return _AutomationStepSpec(
          phase: phase,
          goal: 'Select Vehicle Type',
          action: () async {
            return await _phaseSelectVehicleType();
          },
        );
      case FacebookAutomationPhase.uploadPhotos:
        return _AutomationStepSpec(
          phase: phase,
          goal: 'Upload Photos',
          action: () async {
            return await _phaseUploadPhotos();
          },
        );
      case FacebookAutomationPhase.enterYear:
        return _AutomationStepSpec(
          phase: phase,
          goal: 'Enter Year',
          action: () async {
            return await _phaseEnterYear();
          },
        );
      case FacebookAutomationPhase.enterMake:
        return _AutomationStepSpec(
          phase: phase,
          goal: 'Enter Make',
          action: () async {
            return await _phaseEnterMake();
          },
        );
      case FacebookAutomationPhase.enterModel:
        return _AutomationStepSpec(
          phase: phase,
          goal: 'Enter Model',
          action: () async {
            return await _phaseEnterModel();
          },
        );
      case FacebookAutomationPhase.enterMileage:
        return _AutomationStepSpec(
          phase: phase,
          goal: 'Enter Mileage',
          action: () async {
            return await _phaseEnterMileage();
          },
        );
      case FacebookAutomationPhase.enterPrice:
        return _AutomationStepSpec(
          phase: phase,
          goal: 'Enter Price',
          action: () async {
            return await _phaseEnterPrice();
          },
        );
      case FacebookAutomationPhase.selectBodyStyle:
        return _AutomationStepSpec(
          phase: phase,
          goal: 'Select Body Style',
          action: () async {
            return await _phaseSelectBodyStyle();
          },
        );
      case FacebookAutomationPhase.selectCleanTitle:
        return _AutomationStepSpec(
          phase: phase,
          goal: 'Select Clean Title',
          action: () async {
            return await _phaseSelectCleanTitle();
          },
        );
      case FacebookAutomationPhase.selectCondition:
        return _AutomationStepSpec(
          phase: phase,
          goal: 'Select Condition',
          action: () async {
            return await _phaseSelectCondition();
          },
        );
      case FacebookAutomationPhase.selectFuelType:
        return _AutomationStepSpec(
          phase: phase,
          goal: 'Select Fuel Type',
          action: () async {
            return await _phaseSelectFuelType();
          },
        );
      case FacebookAutomationPhase.selectTransmission:
        return _AutomationStepSpec(
          phase: phase,
          goal: 'Select Transmission',
          action: () async {
            return await _phaseSelectTransmission();
          },
        );
      case FacebookAutomationPhase.enterDescription:
        return _AutomationStepSpec(
          phase: phase,
          goal: 'Enter Description',
          action: () async {
            return await _phaseEnterDescription();
          },
        );
      case FacebookAutomationPhase.publish:
        return _AutomationStepSpec(
          phase: phase,
          goal: 'Publish Listing',
          action: () async {
            return await _phasePublish();
          },
        );
      case FacebookAutomationPhase.selectGroups:
        return _AutomationStepSpec(
          phase: phase,
          goal: 'Select Groups',
          action: () async {
            return await _phaseSelectGroups();
          },
        );
      case FacebookAutomationPhase.complete:
        return null;
    }
  }

  Future<void> _failOrRecover(_AutomationStepSpec spec, String reason) async {
    if (_stopped || _isPaused) return;

    if (_phaseRetryCount < _maxRetries) {
      _phaseRetryCount++;
      final backoffMs = 900 * _phaseRetryCount;
      debugPrint(
        '[FB-A11y] Retry $_phaseRetryCount/$_maxRetries in ${backoffMs}ms: $reason',
      );
      _scheduler.schedule(Duration(milliseconds: backoffMs), () {
        if (!_isPaused) unawaited(_executePhase(spec.phase));
      });
      return;
    }

    // We don't have the LLM recovery planner for FB yet, so fallback to handleError
    _handleRetry(spec.phase, 'Stuck at ${spec.phase.description}: $reason');
  }

  Future<bool> _validateStep(_AutomationStepSpec spec) async {
    final rule = spec.validation;
    if (rule == null) return true;

    if (rule.custom != null && !await rule.custom!()) return false;

    if (rule.mustContain != null &&
        !await _waitForPresent(rule.mustContain!, timeout: rule.timeout)) {
      debugPrint('[FB-A11y] Validation miss: ${rule.mustContain}');
      return false;
    }

    if (rule.nextMarker != null &&
        !await _waitForPresent(rule.nextMarker!, timeout: rule.timeout)) {
      debugPrint('[FB-A11y] Next marker not found: ${rule.nextMarker}');
      return false;
    }

    if (rule.selectedValue != null) {
      if (rule.selectedAfterLabel != null) {
        final after = await toolGetNodeTextAfter(
          rule.selectedAfterLabel!,
          offset: rule.selectedAfterOffset,
        );
        if (_matchesAny(after, rule.selectedValue!)) return true;
      }
      final present = await _waitForPresent(
        rule.selectedValue!,
        timeout: rule.timeout,
      );
      if (!present) {
        debugPrint(
          '[FB-A11y] Selected value not visible: ${rule.selectedValue}',
        );
        return false;
      }
    }

    if (rule.mustNotContain != null &&
        await _isTextVisibleAnySource(rule.mustNotContain!)) {
      debugPrint(
        '[FB-A11y] Forbidden text still visible: ${rule.mustNotContain}',
      );
      return false;
    }

    return true;
  }

  Future<String?> toolGetNodeTextAfter(
    String targetText, {
    int targetInstance = 1,
    double threshold = 0.82,
    int offset = 1,
  }) async {
    try {
      return await _automationChannel
          .invokeMethod<String>('findNodeTextAfterTarget', {
            'target': targetText,
            'targetInstance': targetInstance,
            'threshold': threshold,
            'offset': offset,
          });
    } catch (e) {
      debugPrint('[FB-A11y] getNodeTextAfter failed: $e');
      return null;
    }
  }

  Future<bool> _waitForPresent(
    String target, {
    Duration timeout = const Duration(seconds: 4),
  }) async {
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (_stopped || _isPaused) return false;
      if (await _isElementPresent(target)) return true;
      await Future.delayed(const Duration(milliseconds: 300));
    }
    return false;
  }

  Future<bool> _isTextVisibleAnySource(String text) async {
    return await _isElementPresent(text);
  }

  bool _matchesAny(String? value, String targetText) {
    if (value == null) return false;
    final lower = value.toLowerCase().trim();
    for (final alt in targetText.split('|')) {
      if (lower == alt.trim().toLowerCase()) return true;
    }
    return false;
  }

  Future<void> _waitForUiSettle(Duration delay) async {
    if (delay > Duration.zero) await Future.delayed(delay);
  }

  // ── Low-level tool: stable bounds via Accessibility ───────────────────────

  Future<Map<String, dynamic>?> _getStableBounds(
    String method,
    Map<String, dynamic> args, {
    int maxReads = 4,
  }) async {
    Map<String, dynamic>? previous;
    for (int i = 0; i < maxReads; i++) {
      final bounds = await _automationChannel.invokeMapMethod<String, dynamic>(
        method,
        args,
      );
      if (bounds == null) return null;
      if (previous != null) {
        final dx = ((bounds['x'] as num) - (previous['x'] as num)).abs();
        final dy = ((bounds['y'] as num) - (previous['y'] as num)).abs();
        if (dx < 2 && dy < 2) return bounds;
        debugPrint('[FB-A11y] ⏳ Bounds still moving (Δx=$dx, Δy=$dy)');
      }
      previous = bounds;
      await Future.delayed(const Duration(milliseconds: 250));
    }
    return previous;
  }

  // ── Tool: native accessibility tap & preview ─────────────────────────────

  double get _devicePixelRatio =>
      WidgetsBinding.instance.platformDispatcher.views.first.devicePixelRatio;

  Future<void> _tapBounds(
    Map<String, dynamic> bounds, {
    double deltaX = 0,
    double deltaY = 0,
  }) async {
    final physicalX = (bounds['x'] as num).toDouble() + deltaX;
    final physicalY = (bounds['y'] as num).toDouble() + deltaY;
    onTapPreview?.call(
      physicalX / _devicePixelRatio,
      physicalY / _devicePixelRatio,
    );
    await toolTapScreen(physicalX, physicalY);
  }

  Future<void> toolTapScreen(double x, double y) async {
    if (_inputBlocked) throw StateError('Automation paused before tap');
    debugPrint('[FB-A11y] 🖱️ toolTapScreen($x, $y)');
    final tapped = await _automationChannel.invokeMethod<bool>('tapScreen', {
      'x': x,
      'y': y,
    });
    if (tapped != true) throw StateError('Native tap was not completed');
  }

  Future<bool> toolFindElementAndTap(
    String targetText, {
    int targetInstance = 1,
    double deltaY = 0,
    double threshold = 0.82,
    bool preferEditable = false,
    bool preferClickable = false,
  }) async {
    if (_stopped || _isPaused) return false;
    debugPrint(
      '[FB-A11y] 🔍 toolFindElementAndTap("$targetText", instance=$targetInstance, preferEditable=$preferEditable)',
    );
    try {
      final bounds = await _getStableBounds(
        preferClickable ? 'findClickableAndGetBounds' : 'findAndGetBounds',
        {
          'target': targetText,
          'targetInstance': targetInstance,
          'threshold': threshold,
          'preferEditable': preferEditable,
        },
      );
      if (bounds != null) {
        await _tapBounds(bounds, deltaX: 0, deltaY: deltaY);
        return true;
      }
      return false;
    } catch (e) {
      debugPrint('[FB-A11y] toolFindElementAndTap error: $e');
      return false;
    }
  }

  Future<bool> toolTapNodeAfter(
    String targetText, {
    int targetInstance = 1,
    double threshold = 0.82,
    double deltaX = 0.0,
    double deltaY = 0.0,
    int offset = 1,
    String? matchClassName,
  }) async {
    if (_stopped || _isPaused) return false;
    debugPrint('[FB-A11y] 🔍 toolTapNodeAfter("$targetText")');
    try {
      final bounds = await _getStableBounds('findNodeAfterAndGetBounds', {
        'target': targetText,
        'targetInstance': targetInstance,
        'threshold': threshold,
        'offset': offset,
        if (matchClassName != null) 'matchClassName': matchClassName,
      });
      if (bounds != null) {
        await _tapBounds(bounds, deltaX: deltaX, deltaY: deltaY);
        return true;
      }
      return false;
    } catch (e) {
      debugPrint('[FB-A11y] toolTapNodeAfter error: $e');
      return false;
    }
  }

  Future<bool> toolTapNodeBefore(
    String targetText, {
    int targetInstance = 1,
    double deltaY = 0,
    double threshold = 0.82,
  }) async {
    if (_stopped || _isPaused) return false;
    debugPrint('[FB-A11y] 🔍 toolTapNodeBefore("$targetText")');
    try {
      final bounds = await _getStableBounds('findNodeBeforeAndGetBounds', {
        'target': targetText,
        'targetInstance': targetInstance,
        'threshold': threshold,
      });
      if (bounds != null) {
        await _tapBounds(bounds, deltaX: 0, deltaY: deltaY);
        return true;
      }
      return false;
    } catch (e) {
      debugPrint('[FB-A11y] toolTapNodeBefore error: $e');
      return false;
    }
  }

  // ── Tool: text entry ──────────────────────────────────────────────────────

  Future<bool> toolEnterTextAtFocused(String text) async {
    if (_inputBlocked) return false;
    debugPrint('[FB-A11y] ⌨️ toolEnterTextAtFocused ("$text")');
    try {
      final success = await _automationChannel.invokeMethod<bool>(
        'enterTextAtFocused',
        {'value': text},
      );
      return success ?? false;
    } on PlatformException catch (e) {
      debugPrint('[FB-A11y] enterTextAtFocused native error: ${e.message}');
    } catch (e) {
      debugPrint('[FB-A11y] enterTextAtFocused error: $e');
    }
    return false;
  }

  Future<bool> toolReplaceFocusedWebViewText(String value) async {
    if (_inputBlocked) return false;
    final platform = controller.platform;
    if (platform is! AndroidWebViewController) return false;
    return await _automationChannel.invokeMethod<bool>(
          'replaceFocusedWebViewText',
          {'identifier': platform.webViewIdentifier, 'value': value},
        ) ??
        false;
  }

  Future<bool> _verifyInputAfter(
    String label,
    String expected, {
    int offset = 1,
  }) async {
    String normalize(String value) {
      if (RegExp(r'^\d+$').hasMatch(expected)) {
        return value.replaceAll(RegExp(r'[^\d]'), '');
      }
      return value.replaceAll(RegExp(r'[,\s\₪]'), '');
    }

    for (var attempt = 0; attempt < 4; attempt++) {
      await Future.delayed(const Duration(milliseconds: 150));
      if (_inputBlocked) return false;
      final actual = await toolGetNodeTextAfter(label, offset: offset);
      if (actual != null && normalize(actual) == normalize(expected)) {
        return true;
      }
    }
    return false;
  }

  /*
  Future<void> toolEnterTextAtFocusedJs(String text) async {
    if (_stopped || _isPaused) return;
    debugPrint('[FB-A11y] ⌨️ toolEnterTextAtFocusedJs("$text")');
    final encoded = jsonEncode(text);
    await controller.runJavaScript('''
      (function(value) {
        var el = document.activeElement;
        var isEditable = el && (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA' || el.getAttribute('contenteditable') === 'true' || el.getAttribute('role') === 'textbox');
        if (!isEditable) {
          var inputs = document.querySelectorAll(
            'input:not([type="hidden"]):not([type="checkbox"]):not([type="radio"]), textarea, [contenteditable="true"], [role="textbox"]'
          );
          for (var i = 0; i < inputs.length; i++) {
            var rect = inputs[i].getBoundingClientRect();
            if (rect.width > 0 && rect.height > 0 && rect.top >= 0 && rect.bottom <= window.innerHeight) {
              el = inputs[i];
              break;
            }
          }
        }
        if (!el) return false;
        el.focus();
        if (el.tagName === 'TEXTAREA' || el.tagName === 'INPUT') {
          var proto = el.tagName === 'TEXTAREA' ? window.HTMLTextAreaElement.prototype : window.HTMLInputElement.prototype;
          var setter = Object.getOwnPropertyDescriptor(proto, 'value') && Object.getOwnPropertyDescriptor(proto, 'value').set;
          if (setter) setter.call(el, value);
          else el.value = value;
        } else {
          try {
            document.execCommand('selectAll', false, null);
            document.execCommand('insertText', false, value);
          } catch(e) {}
          if (!el.innerText || el.innerText.trim().length === 0) {
            el.innerText = value;
          }
        }
        el.dispatchEvent(new InputEvent('input', { bubbles: true, data: value, inputType: 'insertText' }));
        el.dispatchEvent(new Event('change', { bubbles: true }));
        return true;
      })(\$encoded);
    ''');
  }
  */

  Future<bool> toolEnterTextNear(String label, String value) async {
    if (_inputBlocked) return false;
    final tapped = await toolTapNodeAfter(label) || await tapSmart(label);
    if (!tapped) return false;
    await Future.delayed(const Duration(milliseconds: 200));
    final native = await toolEnterTextAtFocused(value);
    if (native) return true;
    return false;
  }

  Future<bool> toolEnterTextBefore(String targetText, String value) async {
    if (_inputBlocked) return false;
    try {
      final bounds = await _getStableBounds('findInputBeforeAndGetBounds', {
        'target': targetText,
      });
      if (bounds == null) return false;
      await _tapBounds(bounds);
      await Future.delayed(const Duration(milliseconds: 200));
      return await toolEnterTextAtFocused(value);
    } catch (e) {
      debugPrint('[FB-A11y] enterTextBefore failed: $e');
      return false;
    }
  }

  Future<bool> toolEnterText(
    String targetText,
    String value, {
    int targetInstance = 1,
    double threshold = 0.82,
  }) async {
    if (_inputBlocked) return false;
    debugPrint('[FB-A11y] ⌨️ toolEnterText("$targetText", value="$value")');
    try {
      final bounds = await _getStableBounds('findAndGetBounds', {
        'target': targetText,
        'targetInstance': targetInstance,
        'threshold': threshold,
      });
      if (bounds != null) {
        await _tapBounds(bounds);
        await Future.delayed(const Duration(milliseconds: 200));
        return await toolEnterTextAtFocused(value);
      }
      return false;
    } catch (e) {
      debugPrint('[FB-A11y] toolEnterText error: $e');
      return false;
    }
  }

  // ── Tool: JS shadow-DOM click (Facebook uses React shadow tree heavily) ────

  /// Finds an element by EXACT inner-text match across the full shadow DOM
  /// and fires touch + mouse + React-synthetic click events, matching how
  /// facebook_screen.dart dispatches clicks on [role="option"] elements.
  /*
  Future<bool> toolFindAndTapJs(String targetText) async {
    if (_stopped || _isPaused) return false;
    debugPrint('[FB-A11y] 🕸️ toolFindAndTapJs("\$targetText")');
    final escaped = targetText.replaceAll("'", "\\'");
    final js = '''
      (function(){
        function getAllElements(root){
          var all=[];
          if(!root) return all;
          var els=root.querySelectorAll('*');
          for(var i=0;i<els.length;i++){
            all.push(els[i]);
            if(els[i].shadowRoot) all=all.concat(getAllElements(els[i].shadowRoot));
          }
          return all;
        }
        var all=getAllElements(document);
        var target=null, rect=null;
        // Priority 1: exact role="option" match (category dropdown from facebook_screen)
        var opts=document.querySelectorAll('[role="option"]');
        for(var o=0;o<opts.length;o++){
          var t=(opts[o].innerText||'').trim();
          if(t==='\$escaped'||t.startsWith('\$escaped')){target=opts[o];break;}
        }
        // Priority 2: any element with exact inner-text
        if(!target){
          for(var i=0;i<all.length;i++){
            var el=all[i];
            var r=el.getBoundingClientRect();
            if(r.width===0||r.height===0) continue;
            if((el.innerText||'').trim()==='\$escaped'){target=el;rect=r;break;}
          }
        }
        if(!target) return false;
        rect=target.getBoundingClientRect();
        var x=rect.left+rect.width/2, y=rect.top+rect.height/2;
        var eOpts={bubbles:true,cancelable:true,clientX:x,clientY:y,screenX:x,screenY:y};
        try{
          var touch=new Touch({identifier:Date.now(),target:target,
            clientX:x,clientY:y,screenX:x,screenY:y,
            pageX:x+window.scrollX,pageY:y+window.scrollY});
          target.dispatchEvent(new TouchEvent('touchstart',
            {bubbles:true,cancelable:true,touches:[touch],targetTouches:[touch],changedTouches:[touch]}));
        }catch(e){}
        target.dispatchEvent(new MouseEvent('mousedown',eOpts));
        try{
          target.dispatchEvent(new TouchEvent('touchend',
            {bubbles:true,cancelable:true,changedTouches:[touch]}));
        }catch(e){}
        target.dispatchEvent(new MouseEvent('mouseup',eOpts));
        target.dispatchEvent(new MouseEvent('click',eOpts));
        try{ target.click(); }catch(e){}
        // Fire React synthetic onClick if present
        try{
          var fk=Object.keys(target).find(function(k){
            return k.startsWith('__reactFiber')||k.startsWith('__reactInternalInstance');
          });
          if(fk){
            var fiber=target[fk];
            while(fiber){
              var props=fiber.memoizedProps||fiber.pendingProps;
              if(props&&typeof props.onClick==='function'){
                props.onClick({type:'click',target:target,currentTarget:target,
                  clientX:x,clientY:y,bubbles:true,
                  preventDefault:function(){},stopPropagation:function(){}});
                break;
              }
              fiber=fiber.return;
            }
          }
        }catch(e){}
        return true;
      })()
    ''';
    try {
      final result = await controller.runJavaScriptReturningResult(js);
      return result == true || result.toString() == 'true';
    } catch (e) {
      debugPrint('[FB-A11y] toolFindAndTapJs error: \$e');
      return false;
    }
  }
  */

  // ── Tool: JS click the Nth combobox (as in facebook_screen.dart Phase 3) ──

  /// Clicks `document.querySelectorAll('[role="combobox"]')[index]`
  /// and returns the CSS center coords as "ok:x,y" or "not_found:N".
  /*
  Future<String?> toolClickComboboxByIndex(int index) async {
    debugPrint('[FB-A11y] 🕸️ toolClickComboboxByIndex(\$index)');
    final js = '''
      (function(){
        var combos=document.querySelectorAll('[role="combobox"]');
        if(combos.length<=\$index) return 'not_found:'+combos.length;
        var el=combos[\$index];
        el.scrollIntoView({block:'center',inline:'center'});
        var rect=el.getBoundingClientRect();
        el.click();
        el.dispatchEvent(new MouseEvent('click',{bubbles:true,cancelable:true,view:window}));
        return 'ok:'+Math.round(rect.left+rect.width/2)+','+Math.round(rect.top+rect.height/2);
      })()
    ''';
    try {
      return (await controller.runJavaScriptReturningResult(js)).toString();
    } catch (e) {
      debugPrint('[FB-A11y] toolClickComboboxByIndex error: \$e');
      return null;
    }
  }
  */

  /// Clicks the Nth [role="option"] element (first option = vehicle category).
  /*
  Future<String?> toolClickOptionByIndex(int index) async {
    debugPrint('[FB-A11y] 🕸️ toolClickOptionByIndex(\$index)');
    final js = '''
      (function(){
        var opts=document.querySelectorAll('[role="option"]');
        if(opts.length<=\$index) return 'not_found';
        var el=opts[\$index];
        el.scrollIntoView({block:'center',inline:'center'});
        var rect=el.getBoundingClientRect();
        el.click();
        el.dispatchEvent(new MouseEvent('click',{bubbles:true,cancelable:true,view:window}));
        return 'ok:'+Math.round(rect.left+rect.width/2)+','+Math.round(rect.top+rect.height/2)
              +':'+el.innerText.trim().substring(0,40);
      })()
    ''';
    try {
      return (await controller.runJavaScriptReturningResult(js)).toString();
    } catch (e) {
      debugPrint('[FB-A11y] toolClickOptionByIndex error: \$e');
      return null;
    }
  }
  */

  // ── Tool: JS text input for price / title fields ─────────────────────────

  /// Finds an input/textarea by aria-label, placeholder, or data-testid
  /// and sets its value via React's native setter + Input event.
  /*
  Future<bool> toolFillInputByLabel(String label, String value) async {
    if (_stopped || _isPaused) return false;
    debugPrint('[FB-A11y] ⌨️ toolFillInputByLabel("\$label", "\$value")');
    final escapedLabel = label.replaceAll("'", "\\'");
    final escapedValue = value.replaceAll("'", "\\'");
    final js = '''
      (function(){
        var selectors=[
          '[aria-label*="\$escapedLabel"]',
          '[placeholder*="\$escapedLabel"]',
          '[data-testid*="\${escapedLabel.toLowerCase()}"]',
        ];
        var el=null;
        for(var s of selectors){
          el=document.querySelector(s);
          if(el) break;
        }
        if(!el) return false;
        el.scrollIntoView({block:'center'});
        el.focus();
        var rect=el.getBoundingClientRect();
        // Tap to focus via events
        el.dispatchEvent(new MouseEvent('click',{bubbles:true,cancelable:true,
          clientX:rect.left+rect.width/2, clientY:rect.top+rect.height/2}));
        // Set value via React native setter
        var ns=Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype,'value')
            || Object.getOwnPropertyDescriptor(window.HTMLTextAreaElement.prototype,'value');
        if(ns&&ns.set){ ns.set.call(el,'\$escapedValue'); }
        else { el.value='\$escapedValue'; }
        el.dispatchEvent(new InputEvent('input',{bubbles:true,data:'\$escapedValue',inputType:'insertText'}));
        el.dispatchEvent(new Event('change',{bubbles:true}));
        return true;
      })()
    ''';
    try {
      final r = await controller.runJavaScriptReturningResult(js);
      return r == true || r.toString() == 'true';
    } catch (e) {
      debugPrint('[FB-A11y] toolFillInputByLabel error: \$e');
      return false;
    }
  }
  */

  // ── Tool: scroll helpers ──────────────────────────────────────────────────

  Future<void> _scrollDown(
    double percent, {
    bool accessibilityOnly = false,
  }) async {
    if (_inputBlocked) return;
    try {
      await _automationChannel.invokeMethod('scrollNode', {
        'direction': 'down',
        'percent': percent,
      });
    } catch (e) {
      debugPrint('[FB-A11y] Scroll failed: $e');
    }
    if (accessibilityOnly) {
      await _waitForUiSettle(const Duration(milliseconds: 700));
    } else {
      await _waitForScrollSettle();
    }
  }

  Future<void> _scrollUp(
    double percent, {
    bool accessibilityOnly = false,
  }) async {
    if (_inputBlocked) return;
    try {
      await _automationChannel.invokeMethod('scrollNode', {
        'direction': 'up',
        'percent': percent,
      });
    } catch (e) {
      debugPrint('[FB-A11y] Scroll up failed: $e');
    }
    if (accessibilityOnly) {
      await _waitForUiSettle(const Duration(milliseconds: 700));
    } else {
      await _waitForScrollSettle();
    }
  }

  Future<void> _waitForScrollSettle({
    Duration timeout = const Duration(seconds: 3),
  }) async {
    // For pure A11y, we just rely on time since JS polling is prohibited.
    await Future.delayed(const Duration(milliseconds: 800));
  }

  // ── Tool: pure presence check (no side-effect) ───────────────────────────

  Future<bool> _isElementPresent(
    String target, {
    int targetInstance = 1,
  }) async {
    try {
      final bounds = await _automationChannel.invokeMapMethod<String, dynamic>(
        'findAndGetBounds',
        {'target': target, 'targetInstance': targetInstance},
      );
      return bounds != null;
    } catch (_) {
      return false;
    }
  }

  // ── Tool: retry-until helper ──────────────────────────────────────────────

  Future<bool> _retryUntil(
    Future<bool> Function() action, {
    Duration timeout = const Duration(seconds: 8),
    Duration pollInterval = const Duration(milliseconds: 400),
  }) async {
    final deadline = DateTime.now().add(timeout);
    do {
      if (_isPaused) return false;
      if (await action()) return true;
      await Future.delayed(pollInterval);
    } while (DateTime.now().isBefore(deadline));
    return false;
  }

  // ── Tool: smart tap (native a11y first, JS shadow-DOM fallback) ──────────

  List<String> _splitAlternatives(String value) =>
      value
          .split('|')
          .map((item) => item.trim())
          .where((item) => item.isNotEmpty)
          .toList();

  Future<bool> tapSmart(
    String targetText, {
    int targetInstance = 1,
    double deltaY = 0,
    bool allowJsFallback = true,
  }) async {
    if (_stopped || _isPaused) return false;
    final alternatives = _splitAlternatives(targetText);
    for (final alt in alternatives) {
      if (await toolFindElementAndTap(
        alt,
        targetInstance: targetInstance,
        deltaY: deltaY,
      )) {
        return true;
      }
    }

    return false;
  }

  // ── Tool: press back ─────────────────────────────────────────────────────

  Future<bool> toolPressBack() async {
    if (_stopped || _isPaused) return false;
    try {
      final pressed = await _automationChannel.invokeMethod<bool>('pressBack');
      return pressed ?? false;
    } on PlatformException catch (e) {
      debugPrint('[FB-A11y] pressBack error: ${e.message}');
      return false;
    }
  }

  Future<void> toolBlurActiveElement() async {
    if (_stopped || _isPaused) return;
    try {
      final cleared = await _automationChannel.invokeMethod<bool>('clearFocus');
      if (cleared == true) {
        debugPrint('[Yad2-A11y] Successfully cleared focus natively.');
      }
    } catch (e) {
      debugPrint('[Yad2-A11y] Error calling clearFocus: $e');
    }
    await Future.delayed(const Duration(milliseconds: 500));
  }

  bool isKeyboardVisible() {
    try {
      final view = WidgetsBinding.instance.platformDispatcher.views.first;
      final bottomInset = view.viewInsets.bottom;
      debugPrint('[FB-A11y] Keyboard bottom inset: $bottomInset');
      return bottomInset > 0;
    } catch (e) {
      debugPrint('[FB-A11y] Error checking keyboard visibility: $e');
      return false;
    }
  }

  Future<void> toolDismissKeyboardAndBlur() async {
    if (_stopped || _isPaused) return;
    await toolBlurActiveElement();
    try {
      await SystemChannels.textInput.invokeMethod('TextInput.hide');
    } catch (_) {}
    FocusManager.instance.primaryFocus?.unfocus();
    await Future.delayed(const Duration(milliseconds: 300));
  }

  // ── Login gate helpers ────────────────────────────────────────────────────

  void _stopLoginGate() {
    _loginSamplingTimer?.cancel();
    _loginSamplingTimer = null;
  }

  /// Checks if Facebook is showing a login wall by looking for:
  ///   - password input in DOM (JS)
  ///   - "Log in" / "התחבר" text in accessibility tree
  Future<bool> _checkIsLoginScreen() async {
    // Pure accessibility tree check
    const loginKeywords = [
      'Log in',
      'Log In',
      'התחבר',
      'Email or phone number',
      'Create new account',
      'כתובת אימייל',
      'שם משתמש',
      'סיסמה',
      'Password',
      'מספר נייד או אימייל',
    ];
    for (final kw in loginKeywords) {
      if (await _isElementPresent(kw)) {
        debugPrint('[FB-A11y] 🔐 Login detected via A11y: "$kw"');
        return true;
      }
    }
    return false;
  }

  /// Detects that the user has successfully logged in by checking for
  /// the presence of the category combobox (Facebook Marketplace create form).
  Future<bool> _isLoggedInAndOnForm() async {
    // Check for the combobox that facebook_screen.dart clicks as Phase 3
    try {
      final res = await controller.runJavaScriptReturningResult('''
        (function(){
          var combos=document.querySelectorAll('[role="combobox"]');
          return combos.length>=2 ? 'true' : 'false';
        })()
      ''');
      if (res.toString() == 'true') return true;
    } catch (_) {}

    // Fallback: Marketplace-specific label visible in accessibility tree
    return await _isElementPresent('Marketplace') ||
        await _isElementPresent('Category') ||
        await _isElementPresent('Price') ||
        await _isElementPresent('Vehicles for sale');
  }

  /// Beeps the user to prompt for manual login, then polls every 3s
  /// until the form is detected and auto-resumes.
  void _startLoginGate() {
    if (_loginSamplingTimer != null) return;
    _scheduler.invalidate();
    debugPrint('[FB-A11y] 🔐 Login gate active — waiting for user login');
    _isPaused = true;
    _pausedPhase = FacebookAutomationPhase.setViewport; // resume from viewport
    unawaited(_beepUser());

    final generation = _scheduler.generation;
    _loginSamplingTimer = Timer.periodic(const Duration(seconds: 1), (
      timer,
    ) async {
      if (_loginGateTickBusy) return;
      _loginGateTickBusy = true;
      try {
        if (!await _ensureAutomationWindow()) return;
        if (!await _isLoggedInAndOnForm()) return;
        if (_stopped ||
            generation != _scheduler.generation ||
            _loginSamplingTimer != timer)
          return;
        debugPrint('[FB-A11y] 🎉 Login complete — resuming');
        timer.cancel();
        _loginSamplingTimer = null;
        _isPaused = false;
        _pausedPhase = null;
        _processPhase(FacebookAutomationPhase.setViewport);
      } finally {
        _loginGateTickBusy = false;
      }
    });
  }

  // ── Phase implementations ─────────────────────────────────────────────────

  // Phase 1 — Login gate
  // HTML: input[type="password"], "Log in" button, "Create new account" link
  // A11y: checks accessibility tree for login keywords, then starts gate timer

  Future<_StepActionResult> _phaseLoginGate() async {
    return await _runOnce('fb_login_gate', () async {
          await Future.delayed(const Duration(milliseconds: 300));
          await _applyDesktopViewport();

          bool loginDetected = false;
          final settled = await _retryUntil(
            () async {
              if (await _isLoggedInAndOnForm()) return true;
              if (await _checkIsLoginScreen()) {
                loginDetected = true;
                return true;
              }
              return false;
            },
            timeout: const Duration(seconds: 12),
            pollInterval: const Duration(milliseconds: 300),
          );

          if (loginDetected) {
            onFirstStepDetected?.call();
            _startLoginGate();
            return false;
          }
          if (!settled) return false;

          onFirstStepDetected?.call();
          return true;
        })
        ? const _StepActionResult.success()
        : const _StepActionResult.failure('Login gate check failed');
  }

  Future<_StepActionResult> _phaseSetViewport() async {
    return await _runOnce('fb_set_viewport', () async {
          await _applyDesktopViewport();
          await Future.delayed(const Duration(milliseconds: 300));
          return true;
        })
        ? const _StepActionResult.success()
        : const _StepActionResult.failure('Failed to set viewport');
  }

  Future<void> _applyDesktopViewport() async {
    try {
      await controller.runJavaScript('''
        (function(){
          var m=document.querySelector('meta[name=viewport]');
          if(!m){m=document.createElement('meta');m.name='viewport';document.head.appendChild(m);}
          m.setAttribute('content','width=1280, initial-scale=1.0');
        })();
      ''');
    } catch (e) {
      debugPrint('[FB-A11y] Viewport injection error: $e');
    }
  }

  // Phase 4a — Select "Vehicle Type"
  // A11y: find dropdown labeled "Vehicle Type" or "Vehical Type" or "סוג רכב",
  //   tap to open it, and then select the first option from the dropdown list.
  Future<_StepActionResult> _phaseSelectVehicleType() async {
    return await _runOnce('fb_select_vehicle_type', () async {
          await Future.delayed(const Duration(seconds: 1));
          const dropdownLabels = ['Vehicle type', 'סוג רכב'];

          bool opened = await _retryUntil(() async {
            for (final label in dropdownLabels) {
              if (await toolFindElementAndTap(label)) return true;
              if (await toolTapNodeAfter(label)) return true;
            }
            return false;
          }, timeout: const Duration(seconds: 6));

          if (!opened) return false;

          await Future.delayed(const Duration(milliseconds: 800));

          const optionLabels = ['Car/Truck', 'מכונית/משאית', 'Car', 'Truck'];
          bool optionSelected = await _retryUntil(() async {
            for (final label in optionLabels) {
              if (await toolFindElementAndTap(label)) return true;
            }
            return false;
          }, timeout: const Duration(seconds: 8));

          return optionSelected;
        })
        ? const _StepActionResult.success()
        : const _StepActionResult.failure('Failed to select vehicle type');
  }

  Future<void> toolLogAccessibilityTree({
    String tag = 'FB-A11y-Tree',
    bool force = false,
  }) async {
    if (!force && !const bool.fromEnvironment('PIRSUMOTO_AUTOMATION_TRACE'))
      return;
    debugPrint('[$tag] ════════ ACCESSIBILITY TREE DUMP ════════');
    try {
      final String? treeStr = await _automationChannel.invokeMethod<String>(
        'logTree',
      );
      if (treeStr != null) {
        final lines = treeStr.split('\n');
        for (var line in lines) {
          if (line.trim().isNotEmpty) {
            debugPrint('[$tag] $line');
          }
        }
      } else {
        debugPrint('[$tag] (rootNode is null or service unbound)');
      }
    } catch (e) {
      debugPrint('[$tag] Failed to log accessibility tree: $e');
    }
    debugPrint('[$tag] ════════ END ACCESSIBILITY TREE ════════');
  }

  /// Dumps all interactive form elements from the WebView DOM into debugPrint
  Future<void> toolLogDomFormElements({String tag = 'FB-DOM-Dump'}) async {
    if (!const bool.fromEnvironment('PIRSUMOTO_AUTOMATION_TRACE')) return;
    debugPrint('[$tag] ════════ DOM FORM ELEMENTS DUMP ════════');
    try {
      final raw = await controller.runJavaScriptReturningResult('''
        (function() {
          var items = document.querySelectorAll('input, select, textarea, [role="combobox"], [role="listbox"], [role="button"], label, [aria-label]');
          var out = [];
          for (var i = 0; i < items.length; i++) {
            var el = items[i];
            var rect = el.getBoundingClientRect();
            var ariaLabel = el.getAttribute('aria-label') || '';
            var placeholder = el.getAttribute('placeholder') || '';
            var role = el.getAttribute('role') || '';
            var tag = el.tagName.toLowerCase();
            var type = el.getAttribute('type') || '';
            var value = el.value || '';
            var text = (el.innerText || el.textContent || '').trim().substring(0, 40);
            
            if (ariaLabel || placeholder || role || tag === 'input' || tag === 'select' || tag === 'textarea' || (tag === 'label' && text.length > 0)) {
              out.push({
                tag: tag,
                type: type,
                role: role,
                aria: ariaLabel,
                ph: placeholder,
                val: value,
                txt: text,
                x: Math.round(rect.left),
                y: Math.round(rect.top),
                w: Math.round(rect.width),
                h: Math.round(rect.height)
              });
            }
          }
          return JSON.stringify(out);
        })()
      ''');
      var str = raw.toString();
      if (str.startsWith('"') && str.endsWith('"')) {
        str = jsonDecode(str);
      }
      final list = jsonDecode(str);
      if (list is List) {
        debugPrint('[$tag] Found ${list.length} interactive elements:');
        for (var item in list) {
          debugPrint(
            '[$tag] <${item['tag']} type="${item['type']}" role="${item['role']}"> '
            'aria="${item['aria']}" ph="${item['ph']}" val="${item['val']}" '
            'text="${item['txt']}" bounds=(${item['x']},${item['y']},${item['w']},${item['h']})',
          );
        }
      }
    } catch (e) {
      debugPrint('[$tag] Error logging DOM elements: $e');
    }
    debugPrint('[$tag] ════════ END DOM FORM ELEMENTS ════════');
  }

  /*
  /// Scrolls an element into view using DOM inspection
  Future<bool> toolScrollElementIntoViewViaDom(List<String> keywords) async {
    // ... preserved for fallback ...
    return false;
  }

  /// Enters text directly into an input matching selectors or aria-label/placeholder in the DOM
  Future<bool> toolEnterTextInputViaDom({
    required List<String> selectors,
    required String text,
  }) async {
    // ... preserved for fallback ...
    return false;
  }

  /// Enters price specifically into the DOM, checking direct inputs, label containers,
  /// and aria-labelledby references to avoid clicking static text labels.
  Future<bool> toolEnterPriceViaDom(String price) async {
    // ... preserved for fallback ...
    return false;
  }
  */

  // Phase 5 — Upload photos
  Future<_StepActionResult> _phaseUploadPhotos() async {
    return await _runOnce('fb_upload_photos', () async {
          var images = formData.images;
          final expectedCount = formData.expectedImageCount;
          if (expectedCount == 0) return true;
          if (images == null || images.isEmpty) {
            return expectedCount == null || expectedCount <= 0;
          }
          if (expectedCount != null && expectedCount > 0) {
            if (images.length < expectedCount) return false;
            images = images.sublist(images.length - expectedCount.toInt());
          }
          if (!Platform.isAndroid || _inputBlocked) return false;

          for (final path in images) {
            try {
              if (path.isEmpty ||
                  !await File(path).exists() ||
                  await File(path).length() == 0) {
                return false;
              }
            } catch (e) {
              debugPrint('[FB-A11y] Image unavailable: $e');
              return false;
            }
          }
          if (_inputBlocked) return false;

          final request = NativeImageUploadRequest(images);
          _imageUploadRequest = request;
          try {
            // Confirmed on-device: the drop zone is an android.widget.Button with
            // this combined label. "העלאת תמונה" is a non-clickable heading.
            const uploadLabels =
                'הוסף תמונות או לגרור ולשחרר|'
                'הוסף תמונה|הוסף תמונות|הוספת תמונות|או לגרור ולשחרר|'
                'Add photo|Add photos|Add Photos|or drag and drop';
            // The upload area is already near the top of the form. Wait for React
            // to expose it, without moving the viewport. Target its clickable
            // container when the label itself is only a static text child.
            final tapped = await _retryUntil(() async {
              if (await toolFindElementAndTap(
                uploadLabels,
                threshold: 1.0,
                preferClickable: true,
              )) {
                return true;
              }
              // WebView may merge the button and drag/drop hint into one label.
              return toolFindElementAndTap(
                uploadLabels,
                threshold: 0.90,
                preferClickable: true,
              );
            }, timeout: const Duration(seconds: 4));
            if (!tapped && !_inputBlocked) {
              await toolLogAccessibilityTree(
                tag: 'FB-Upload-NotFound',
                force: true,
              );
            }

            if (!tapped || _inputBlocked) return false;
            final selected = await request.wait();
            if (!selected || _inputBlocked) return false;
            debugPrint(
              '[FB-A11y] Images returned through Android file chooser',
            );
            await Future<void>.delayed(const Duration(seconds: 5));

            debugPrint(
              '[FB-A11y] Native image selection completed. Logging state:',
            );
            await toolLogAccessibilityTree(tag: 'FB-PostUpload-A11y');

            return !_inputBlocked;
          } catch (e) {
            debugPrint('[FB-A11y] Native image upload failed: $e');
            return false;
          } finally {
            request.cancel();
            if (identical(_imageUploadRequest, request))
              _imageUploadRequest = null;
          }
        })
        ? const _StepActionResult.success()
        : const _StepActionResult.failure('Failed to upload photos natively');
  }

  // Phase 6 — Enter year
  Future<_StepActionResult> _phaseEnterYear() async {
    return await _runOnce('fb_enter_year', () async {
          final yearVal = formData.year;
          if (yearVal.isEmpty) return true;

          await _scrollDown(0.45);

          bool opened = await _retryUntil(() async {
            if (await toolTapNodeAfter('שנה|שנת|Year', offset: 1)) return true;
            if (await tapSmart('שנה|שנת ייצור|Year', allowJsFallback: false))
              return true;
            return false;
          }, timeout: const Duration(seconds: 4));

          if (!opened) return false;
          await Future.delayed(const Duration(milliseconds: 800));

          final parsedYear = int.tryParse(yearVal);
          if (parsedYear != null && parsedYear < 2016) {
            await _scrollDown(0.3);
            if (parsedYear < 2010) {
              await _scrollDown(0.3);
            }
            await Future.delayed(const Duration(milliseconds: 800));

            final String? treeStr = await _automationChannel
                .invokeMethod<String>('logTree');
            if (treeStr != null) {
              final regex = RegExp(
                r'\[(.*?)\] text="(.*?)" desc="(.*?)" clickable=(true|false) bounds=Rect\((-?\d+), (-?\d+) - (-?\d+), (-?\d+)\)',
              );
              final matches = regex.allMatches(treeStr);
              bool tappedFromTree = false;
              for (final match in matches) {
                final text = match.group(2) ?? '';
                final desc = match.group(3) ?? '';
                if (text == yearVal || desc == yearVal) {
                  final left = double.tryParse(match.group(5) ?? '0') ?? 0;
                  final top = double.tryParse(match.group(6) ?? '0') ?? 0;
                  final right = double.tryParse(match.group(7) ?? '0') ?? 0;
                  final bottom = double.tryParse(match.group(8) ?? '0') ?? 0;

                  final centerX = left + (right - left) / 2;
                  final centerY = top + (bottom - top) / 2;

                  debugPrint(
                    '[FB-A11y] Tapping year $yearVal from fresh tree at $centerX, $centerY',
                  );
                  await toolTapScreen(centerX, centerY);
                  tappedFromTree = true;
                  break;
                }
              }
              if (tappedFromTree) {
                return true;
              }
            }
          }

          bool selected = await _retryUntil(() async {
            return await tapSmart(yearVal, allowJsFallback: false);
          }, timeout: const Duration(seconds: 4));

          return selected;
        })
        ? const _StepActionResult.success()
        : const _StepActionResult.failure('Failed to enter year');
  }

  // Phase 7 — Enter make (Manufacturer - Free Text Field)
  Future<_StepActionResult> _phaseEnterMake() async {
    return await _runOnce('fb_enter_make', () async {
          final makeVal = formData.maker;
          if (makeVal.isEmpty) return true;

          await _scrollDown(0.2);

          bool tapped = await _retryUntil(() async {
            if (await toolTapNodeAfter('יצרן|Make|Manufacturer', offset: 1))
              return true;
            if (await tapSmart(
              'יצרן|Make|Manufacturer',
              allowJsFallback: false,
            ))
              return true;
            return false;
          }, timeout: const Duration(seconds: 4));

          if (!tapped) return false;

          await Future.delayed(const Duration(milliseconds: 200));
          await toolEnterTextAtFocused(makeVal);
          final makeLabel = 'יצרן|Make|Manufacturer';
          if (!(await _verifyInputAfter(makeLabel, makeVal))) {
            if (_inputBlocked) return false;
            debugPrint(
              '[FB-A11y] Text readback failed; trying native WebView input.',
            );
            final nativeSuccess = await toolReplaceFocusedWebViewText(makeVal);
            if (!nativeSuccess &&
                !(await _verifyInputAfter(makeLabel, makeVal))) {
              return false;
            }
          }

          await Future.delayed(const Duration(milliseconds: 800));
          try {
            await _retryUntil(() async {
              return await tapSmart(
                makeVal,
                targetInstance: 2,
                allowJsFallback: false,
              );
            }, timeout: const Duration(milliseconds: 1500));
          } catch (_) {}

          await toolDismissKeyboardAndBlur();
          return true;
        })
        ? const _StepActionResult.success()
        : const _StepActionResult.failure('Failed to enter make');
  }

  // Phase 8 — Enter model (Free Text Field)
  Future<_StepActionResult> _phaseEnterModel() async {
    return await _runOnce('fb_enter_model', () async {
          final modelVal = formData.model;
          if (modelVal.isEmpty) return true;

          bool tapped = await _retryUntil(() async {
            if (await toolTapNodeAfter('דגם|Model', offset: 1)) return true;
            if (await tapSmart('דגם|Model', allowJsFallback: false))
              return true;
            return false;
          }, timeout: const Duration(seconds: 4));

          if (!tapped) return false;

          await Future.delayed(const Duration(milliseconds: 200));
          await toolEnterTextAtFocused(modelVal);
          final modelLabel = 'דגם|Model';
          if (!(await _verifyInputAfter(modelLabel, modelVal))) {
            if (_inputBlocked) return false;
            debugPrint(
              '[FB-A11y] Text readback failed; trying native WebView input.',
            );
            final nativeSuccess = await toolReplaceFocusedWebViewText(modelVal);
            if (!nativeSuccess &&
                !(await _verifyInputAfter(modelLabel, modelVal))) {
              return false;
            }
          }

          await Future.delayed(const Duration(milliseconds: 800));
          try {
            await _retryUntil(() async {
              return await tapSmart(
                modelVal,
                targetInstance: 2,
                allowJsFallback: false,
              );
            }, timeout: const Duration(milliseconds: 1000));
          } catch (_) {}

          await toolDismissKeyboardAndBlur();
          return true;
        })
        ? const _StepActionResult.success()
        : const _StepActionResult.failure('Failed to enter model');
  }

  // Phase 9 — Enter mileage
  Future<_StepActionResult> _phaseEnterMileage() async {
    return await _runOnce('fb_enter_mileage', () async {
          final km = formData.kilometers;
          if (km.isEmpty) return true;

          await _scrollDown(0.2);

          bool tapped = await _retryUntil(() async {
            if (await tapSmart(
              'קילומטראז׳|קילומטראז|ק״מ|ק"מ|קילומטרים|קמ|מיילס|מיילים|מייל|Mileage|Miles',
              targetInstance: 2,
              allowJsFallback: false,
            ))
              return true;
            if (await toolTapNodeAfter(
              'קילומטראז׳|קילומטראז|ק״מ|ק"מ|קילומטרים|קמ|מיילס|מיילים|מייל|Mileage|Miles',
              offset: 1,
            ))
              return true;
            return false;
          }, timeout: const Duration(seconds: 4));

          if (!tapped) return false;

          await Future.delayed(const Duration(milliseconds: 200));
          await toolEnterTextAtFocused(km);
          final verifyLabel =
              'קילומטראז׳|קילומטראז|ק״מ|ק"מ|קילומטרים|קמ|מיילס|מיילים|מייל|Mileage|Miles';
          if (!(await _verifyInputAfter(verifyLabel, km))) {
            if (_inputBlocked) return false;
            debugPrint(
              '[FB-A11y] Text readback failed; trying native WebView input.',
            );
            final nativeSuccess = await toolReplaceFocusedWebViewText(km);
            if (!nativeSuccess && !(await _verifyInputAfter(verifyLabel, km))) {
              return false;
            }
          }

          // await Future.delayed(const Duration(milliseconds: 500));
          await toolDismissKeyboardAndBlur();
          return true;
        })
        ? const _StepActionResult.success()
        : const _StepActionResult.failure('Failed to enter mileage');
  }

  // Phase 10 — Enter price
  Future<_StepActionResult> _phaseEnterPrice() async {
    return await _runOnce('fb_enter_price', () async {
          final priceText = formData.price;
          if (priceText.isEmpty) return true;

          // await _scrollDown(0.2);

          bool tapped = await _retryUntil(() async {
            if (await toolFindElementAndTap(
              'מחיר|Price',
              targetInstance: 2,
              preferEditable: true,
            ))
              return true;
            if (await tapSmart(
              'מחיר|Price',
              targetInstance: 2,
              allowJsFallback: false,
            ))
              return true;
            if (await toolTapNodeAfter('מחיר|Price', offset: 1)) return true;
            return false;
          }, timeout: const Duration(seconds: 4));

          if (!tapped) return false;

          await Future.delayed(const Duration(milliseconds: 200));
          await toolEnterTextAtFocused(priceText);
          final priceLabel = 'מחיר|Price';
          if (!(await _verifyInputAfter(priceLabel, priceText))) {
            if (_inputBlocked) return false;
            debugPrint(
              '[FB-A11y] Text readback failed; trying native WebView input.',
            );
            final nativeSuccess = await toolReplaceFocusedWebViewText(
              priceText,
            );
            if (!nativeSuccess &&
                !(await _verifyInputAfter(priceLabel, priceText))) {
              return false;
            }
          }

          // await Future.delayed(const Duration(milliseconds: 500));
          await toolDismissKeyboardAndBlur();
          return true;
        })
        ? const _StepActionResult.success()
        : const _StepActionResult.failure('Failed to enter price');
  }

  // Phase 11 — Select body style
  Future<_StepActionResult> _phaseSelectBodyStyle() async {
    return await _runOnce('fb_select_body_style', () async {
          await _scrollDown(0.22);
          bool opened = await _retryUntil(() async {
            if (await toolFindElementAndTap('סגנון גוף הרכב')) return true;
            if (await toolFindElementAndTap('Body style')) return true;
            if (await toolFindElementAndTap('Body Style')) return true;
            return false;
          }, timeout: const Duration(seconds: 8));

          if (!opened) return true; // skipping
          await Future.delayed(const Duration(milliseconds: 800));

          const bodyStyleLabels = ['אחרים', 'Other', 'אחר'];
          bool selected = await _retryUntil(() async {
            for (final label in bodyStyleLabels) {
              if (await toolFindElementAndTap(label)) return true;
            }
            return false;
          }, timeout: const Duration(seconds: 6));

          return true;
        })
        ? const _StepActionResult.success()
        : const _StepActionResult.failure('Failed body style');
  }

  // Phase 11.5 — Select Clean Title
  Future<_StepActionResult> _phaseSelectCleanTitle() async {
    if (!formData.cleanTitle) {
      return const _StepActionResult.success();
    }
    return await _runOnce('fb_select_clean_title', () async {
          await _scrollDown(0.1);
          bool clicked = await _retryUntil(() async {
            if (await toolTapNodeAfter(
              'לרכב זה יש טייטל נקי.',
              matchClassName: 'android.widget.CheckBox',
            ))
              return true;
            if (await toolTapNodeAfter(
              'לרכב זה יש טייטל נקי',
              matchClassName: 'android.widget.CheckBox',
            ))
              return true;
            if (await toolTapNodeAfter(
              'This vehicle has a clean title.',
              matchClassName: 'android.widget.CheckBox',
            ))
              return true;
            if (await toolTapNodeAfter(
              'This vehicle has a clean title',
              matchClassName: 'android.widget.CheckBox',
            ))
              return true;

            await _scrollDown(0.15);
            return false;
          }, timeout: const Duration(seconds: 6));

          return clicked;
        })
        ? const _StepActionResult.success()
        : const _StepActionResult.failure('Failed to select clean title');
  }

  // Phase 12 — Select condition
  Future<_StepActionResult> _phaseSelectCondition() async {
    return await _runOnce('fb_select_condition', () async {
          await _scrollDown(0.2);
          bool opened = await _retryUntil(() async {
            if (await toolFindElementAndTap('מצב הרכב')) return true;
            if (await toolFindElementAndTap('Vehicle condition')) return true;
            if (await toolFindElementAndTap('Condition')) return true;
            return false;
          }, timeout: const Duration(seconds: 8));

          if (!opened) return true;
          await Future.delayed(const Duration(milliseconds: 800));

          final cond = formData.vehicleCondition;
          final List<String> conditionLabels = [];
          if (cond == 'מצוין' || cond == 'מצויין') {
            conditionLabels.addAll([
              'מצויין',
              'מצוין',
              'משומש - כחדש',
              'Like New',
              'Used - Like New',
              'Excellent',
            ]);
          } else if (cond == 'טוב מאוד') {
            conditionLabels.addAll([
              'טוב מאוד',
              'משומש - במצב טוב מאוד',
              'Very Good',
              'Used - Very Good',
              'משומש - כחדש',
              'משומש - במצב טוב',
            ]);
          } else if (cond == 'טוב') {
            conditionLabels.addAll([
              'טוב',
              'משומש - במצב טוב',
              'Good',
              'Used - Good',
            ]);
          } else if (cond == 'סביר') {
            conditionLabels.addAll([
              'סביר',
              'משומש - במצב סביר',
              'Fair',
              'Used - Fair',
            ]);
          } else if (cond == 'גרוע') {
            conditionLabels.addAll([
              'גרוע',
              'משומש - במצב גרוע',
              'Poor',
              'Used - Poor',
              'משומש - במצב סביר',
            ]);
          } else {
            conditionLabels.addAll([
              'טוב',
              'משומש - במצב טוב',
              'Good',
              'Used - Good',
            ]);
          }
          // General fallback
          conditionLabels.addAll([
            'Used - Good',
            'Used - Like New',
            'Used - Fair',
            'משומש - במצב טוב',
            'משומש - כחדש',
            'משומש - במצב סביר',
            'Used',
            'משומש',
          ]);

          bool selectedCond = await _retryUntil(() async {
            for (final label in conditionLabels) {
              if (await toolFindElementAndTap(label)) return true;
            }
            return false;
          }, timeout: const Duration(seconds: 6));

          return true;
        })
        ? const _StepActionResult.success()
        : const _StepActionResult.failure('Failed condition');
  }

  // Phase 13 — Select fuel type
  Future<_StepActionResult> _phaseSelectFuelType() async {
    return await _runOnce('fb_select_fuel_type', () async {
          await _scrollDown(0.3);
          final fuel = formData.fuelType;
          if (fuel.isEmpty) return true;

          bool opened = await _retryUntil(() async {
            if (await toolFindElementAndTap('סוג דלק')) return true;
            if (await toolFindElementAndTap('Fuel type')) return true;
            if (await toolFindElementAndTap('Fuel Type')) return true;
            return false;
          }, timeout: const Duration(seconds: 8));

          if (!opened) return true;
          await Future.delayed(const Duration(milliseconds: 800));

          final alts = <String>[fuel];
          if (fuel == 'בנזין') alts.addAll(['Gasoline', 'Petrol', 'דלק']);
          if (fuel == 'דיזל') alts.addAll(['Diesel', 'דיזל']);
          if (fuel == 'חשמל') alts.addAll(['Electric', 'חשמלי', 'חשמל']);
          if (fuel.contains('היבריד')) alts.addAll(['Hybrid', 'היברידי']);

          bool selected = await _retryUntil(() async {
            for (final alt in alts) {
              if (await toolFindElementAndTap(alt)) return true;
            }
            return false;
          }, timeout: const Duration(seconds: 6));

          return true;
        })
        ? const _StepActionResult.success()
        : const _StepActionResult.failure('Failed fuel type');
  }

  // Phase 14 — Select transmission
  Future<_StepActionResult> _phaseSelectTransmission() async {
    return await _runOnce('fb_select_transmission', () async {
          final String gearVal =
              formData.gear.isNotEmpty ? formData.gear : 'הילוכים אוטומטיים';

          if (gearVal == 'הילוכים אוטומטיים' ||
              gearVal == 'Automatic' ||
              gearVal == 'אוטומטי') {
            debugPrint(
              '[FB-A11y] Skipping transmission selection as automatic is default',
            );
            return true;
          }

          bool opened = await _retryUntil(() async {
            if (await toolFindElementAndTap('תיבת הילוכים')) return true;
            if (await toolFindElementAndTap('Transmission')) return true;
            return false;
          }, timeout: const Duration(seconds: 8));

          if (!opened) return true;
          await Future.delayed(const Duration(milliseconds: 800));

          final transLabels = <String>[];
          if (gearVal == 'שידור ידני' || gearVal == 'ידני') {
            transLabels.addAll(['Manual', 'שידור ידני', 'ידני']);
          } else {
            transLabels.addAll(['Automatic', 'הילוכים אוטומטיים', 'אוטומטי']);
          }

          bool selected = await _retryUntil(() async {
            for (final label in transLabels) {
              if (await toolFindElementAndTap(label)) return true;
            }
            return false;
          }, timeout: const Duration(seconds: 6));

          return true;
        })
        ? const _StepActionResult.success()
        : const _StepActionResult.failure('Failed transmission');
  }

  // Phase 15 — Enter description
  Future<_StepActionResult> _phaseEnterDescription() async {
    return await _runOnce('fb_enter_description', () async {
          final descriptionText = await PublicationDescriptionService.load(
            formData,
          );

          await _scrollDown(0.25);
          await Future.delayed(const Duration(milliseconds: 200));

          bool tapped =
              await toolTapNodeAfter('תיאור', offset: 3) ||
              await toolTapNodeAfter('Description', offset: 3) ||
              await toolFindElementAndTap(
                'תיאור|Description',
                preferEditable: true,
              );

          if (tapped) {
            await Future.delayed(const Duration(milliseconds: 200));
            await toolEnterTextAtFocused(descriptionText);
            final descLabel = 'תיאור|Description';
            if (!(await _verifyInputAfter(
              descLabel,
              descriptionText,
              offset: 3,
            ))) {
              if (_inputBlocked) return false;
              debugPrint(
                '[FB-A11y] Text readback failed; trying native WebView input.',
              );
              final nativeSuccess = await toolReplaceFocusedWebViewText(
                descriptionText,
              );
              if (!nativeSuccess &&
                  !(await _verifyInputAfter(
                    descLabel,
                    descriptionText,
                    offset: 3,
                  ))) {
                return false;
              }
            }
          } else {
            return false;
          }

          // await Future.delayed(const Duration(milliseconds: 500));
          await toolDismissKeyboardAndBlur();
          return true;
        })
        ? const _StepActionResult.success()
        : const _StepActionResult.failure('Failed to enter description');
  }

  /*
  Future<bool> _enterDescriptionViaDom(String text) async {
    // ... preserved for fallback ...
    return false;
  }
  */

  // Phase 16 — Publish
  Future<_StepActionResult> _phasePublish() async {
    return await _runOnce('fb_publish', () async {
          if (!_publishAttempted) {
            await _scrollDown(0.3);
            final tapped = await _retryUntil(
              () => tapSmart('Next|Continue|הבא|המשך', allowJsFallback: false),
              timeout: const Duration(seconds: 6),
            );
            if (tapped) {
              await Future.delayed(const Duration(seconds: 2));
              await _scrollDown(0.3);
            }
            _publishAttempted = true;
            await tapSmart(
              'Publish|Publish listing|פרסם|פרסם מודעה',
              allowJsFallback: false,
            );
          }
          return true;
        })
        ? const _StepActionResult.success()
        : const _StepActionResult.failure('Failed to publish');
  }

  // Phase 17 — Select Groups
  Future<_StepActionResult> _phaseSelectGroups() async {
    return await _runOnce('fb_select_groups', () async {
          final found = await _retryUntil(
            () => _isElementPresent('פרסום בקבוצות שלך'),
            timeout: const Duration(seconds: 8),
          );

          if (found) {
            debugPrint(
              '[FB-A11y] Found "פרסום בקבוצות שלך", selecting groups...',
            );
            await Future.delayed(const Duration(seconds: 1));

            // 1. Scroll to the top
            for (int i = 0; i < 5; i++) {
              await _scrollUp(0.8);
            }

            final Set<String> seenCheckboxes = {};
            int totalTapped = 0;
            const int maxGroupsToSelect = 20; // Facebook maximum

            // Loop until reaching the end of the page
            while (true) {
              final String? treeStr = await _automationChannel
                  .invokeMethod<String>('logTree');
              if (treeStr == null) {
                debugPrint('[FB-A11y] logTree returned null, stopping.');
                break;
              }

              // Groups: 1=class 2=text 3=desc 4=clickable 5=checked 6=left 7=top 8=right 9=bottom
              final regex = RegExp(
                r'\[(.*?)\] text="(.*?)" desc="(.*?)" clickable=(true|false) checked=(true|false) bounds=Rect\((-?\d+), (-?\d+) - (-?\d+), (-?\d+)\)',
              );
              final matches = regex.allMatches(treeStr).toList();

              // Collect only NEW (unseen) checkboxes visible on screen
              final List<RegExpMatch> newCheckboxes = [];
              for (final match in matches) {
                final className = match.group(1) ?? '';
                if (!className.contains('CheckBox')) continue;

                final text = match.group(2) ?? '';
                final desc = match.group(3) ?? '';
                final contentKey = '$text|$desc'; // stable across scrolls

                if (!seenCheckboxes.contains(contentKey)) {
                  newCheckboxes.add(match);
                }
              }

              debugPrint(
                '[FB-A11y] New checkboxes visible this scroll: ${newCheckboxes.length}',
              );

              // If no new checkboxes found, we've reached the bottom
              if (newCheckboxes.isEmpty) {
                debugPrint(
                  '[FB-A11y] No new checkboxes found — reached end of page.',
                );
                break;
              }

              // Process up to 5 new checkboxes this scroll batch
              final batch = newCheckboxes.take(5).toList();
              final keywords = ['רכב', 'רכבים', 'רכבי', 'הרכב', 'הרכבים'];
              bool hitMax = false;

              for (final match in batch) {
                final text = match.group(2) ?? '';
                final desc = match.group(3) ?? '';
                final isChecked = match.group(5) == 'true';
                final left = int.tryParse(match.group(6) ?? '0') ?? 0;
                final top = int.tryParse(match.group(7) ?? '0') ?? 0;
                final right = int.tryParse(match.group(8) ?? '0') ?? 0;
                final bottom = int.tryParse(match.group(9) ?? '0') ?? 0;
                final contentKey = '$text|$desc'; // stable across scrolls
                final centerX = left + (right - left) / 2.0;
                final centerY = top + (bottom - top) / 2.0;

                // Mark as seen by name — stable across scrolls
                seenCheckboxes.add(contentKey);

                final bool shouldBeChecked = keywords.any(
                  (k) => text.contains(k) || desc.contains(k),
                );

                debugPrint(
                  '[FB-A11y] Checkbox text="$text" desc="$desc" isChecked=$isChecked shouldBeChecked=$shouldBeChecked',
                );

                if (shouldBeChecked && !isChecked) {
                  if (totalTapped >= maxGroupsToSelect) {
                    debugPrint(
                      '[FB-A11y] 🛑 Reached Facebook maximum of $maxGroupsToSelect groups, stopping.',
                    );
                    hitMax = true;
                    break;
                  }
                  // Needs to be checked — tap and verify
                  debugPrint(
                    '[FB-A11y] ✅ Checking group at ($centerX, $centerY)',
                  );
                  await toolTapScreen(centerX, centerY);
                  await Future.delayed(const Duration(milliseconds: 700));

                  // Verify it got checked; retry once if not
                  final String? treeAfter = await _automationChannel
                      .invokeMethod<String>('logTree');
                  if (treeAfter != null) {
                    final verifyPattern = RegExp(
                      r'\[([^\]]*CheckBox[^\]]*)\] text="[^"]*" desc="[^"]*" clickable=(true|false) checked=(true|false) bounds=Rect\(' +
                          '$left, $top - $right, $bottom' +
                          r'\)',
                    );
                    final vm = verifyPattern.firstMatch(treeAfter);
                    final nowChecked = vm?.group(3) == 'true';
                    if (!nowChecked) {
                      debugPrint('[FB-A11y] ⚠️ Still unchecked — retrying tap');
                      await toolTapScreen(centerX, centerY);
                      await Future.delayed(const Duration(milliseconds: 900));
                    } else {
                      totalTapped++;
                      debugPrint(
                        '[FB-A11y] ✔ Verified checked ($totalTapped/$maxGroupsToSelect)',
                      );
                    }
                  }
                } else if (!shouldBeChecked && isChecked) {
                  // Needs to be unchecked
                  debugPrint(
                    '[FB-A11y] ☑→☐ Unchecking non-car group at ($centerX, $centerY)',
                  );
                  await toolTapScreen(centerX, centerY);
                  await Future.delayed(const Duration(milliseconds: 700));
                } else {
                  debugPrint(
                    '[FB-A11y] ⏭ No action (shouldBe=$shouldBeChecked already=$isChecked)',
                  );
                }
              }

              if (hitMax) {
                // Scroll all the way to the bottom so פרסום button is reachable
                debugPrint(
                  '[FB-A11y] 🏁 Reached max — scrolling to bottom to wait.',
                );
                for (int i = 0; i < 8; i++) {
                  await _scrollDown(0.9);
                  await Future.delayed(const Duration(milliseconds: 400));
                }
                debugPrint(
                  '[FB-A11y] ⏳ At bottom — waiting for פרסום button step.',
                );
                break;
              }

              // Adaptive scroll: push the LAST processed row up to the top 1/3
              // of the screen. This keeps the already-seen anchor visible at the
              // top while exposing a full 2/3 screen of fresh rows below.
              // estScreenH is conservative for 1080p–1440p Android devices.
              const int estScreenH = 2400;
              final lastInBatch = batch.last;
              final lastSeenBottom =
                  int.tryParse(lastInBatch.group(9) ?? '0') ?? 0;
              // Target: last seen row sits at y ≈ screenH/3 (top third)
              final targetY = estScreenH ~/ 3;
              final scrollPx = (lastSeenBottom - targetY).clamp(
                80,
                estScreenH - targetY,
              );
              final scrollFraction = (scrollPx / estScreenH).clamp(0.05, 0.55);
              debugPrint(
                '[FB-A11y] Scroll: last seen bottom=$lastSeenBottom → push to y=$targetY, fraction=$scrollFraction',
              );
              await _scrollDown(scrollFraction);
              await Future.delayed(const Duration(milliseconds: 1800));
            }
          } else {
            debugPrint(
              '[FB-A11y] "פרסום בקבוצות שלך" not found, skipping groups',
            );
          }

          debugPrint(
            '[FB-A11y] Finished selecting groups. Tapping פרסום button.',
          );
          await toolFindElementAndTap('פרסום', preferClickable: true);
          await Future.delayed(const Duration(milliseconds: 1500));

          _completedPhaseActions.add('fb_select_groups');
          debugPrint('[FB-A11y] fb_select_groups phase complete.');
          return true;
        })
        ? const _StepActionResult.success()
        : const _StepActionResult.failure('Failed to complete group selection');
  }

  // ── Phase chain controller ────────────────────────────────────────────────

  void _handlePhaseComplete(FacebookAutomationPhase phase) {
    debugPrint('[FB-A11y] ✅ Phase complete: ${phase.descriptionHe}');
    if (_stopped) return;
    onPhaseComplete?.call(phase);

    final next = _nextPhaseAfter(phase);
    if (next == null) {
      stop();
      onAutomationComplete?.call(true);
      return;
    }

    _currentPhase = next;
    _pausedPhase = next;
    _scheduler.schedule(_delayAfter(phase), () {
      if (!_isPaused) {
        _processPhase(next);
      }
    });
  }

  FacebookAutomationPhase? _nextPhaseAfter(FacebookAutomationPhase phase) {
    switch (phase) {
      case FacebookAutomationPhase.loginGate:
        return FacebookAutomationPhase.setViewport;
      case FacebookAutomationPhase.setViewport:
        return FacebookAutomationPhase.selectVehicleType;
      case FacebookAutomationPhase.selectVehicleType:
        return FacebookAutomationPhase.uploadPhotos;
      case FacebookAutomationPhase.uploadPhotos:
        return FacebookAutomationPhase.enterYear;
      case FacebookAutomationPhase.enterYear:
        return FacebookAutomationPhase.enterMake;
      case FacebookAutomationPhase.enterMake:
        return FacebookAutomationPhase.enterModel;
      case FacebookAutomationPhase.enterModel:
        return FacebookAutomationPhase.enterMileage;
      case FacebookAutomationPhase.enterMileage:
        return FacebookAutomationPhase.enterPrice;
      case FacebookAutomationPhase.enterPrice:
        return FacebookAutomationPhase.selectBodyStyle;
      case FacebookAutomationPhase.selectBodyStyle:
        return FacebookAutomationPhase.selectCleanTitle;
      case FacebookAutomationPhase.selectCleanTitle:
        return FacebookAutomationPhase.selectCondition;
      case FacebookAutomationPhase.selectCondition:
        return FacebookAutomationPhase.selectFuelType;
      case FacebookAutomationPhase.selectFuelType:
        return FacebookAutomationPhase.selectTransmission;
      case FacebookAutomationPhase.selectTransmission:
        return FacebookAutomationPhase.enterDescription;
      case FacebookAutomationPhase.enterDescription:
        return FacebookAutomationPhase.publish;
      case FacebookAutomationPhase.publish:
        return FacebookAutomationPhase.selectGroups;
      case FacebookAutomationPhase.selectGroups:
        return FacebookAutomationPhase.complete;
      case FacebookAutomationPhase.complete:
        return null;
    }
  }

  Duration _delayAfter(FacebookAutomationPhase phase) {
    switch (phase) {
      case FacebookAutomationPhase.loginGate:
        return const Duration(milliseconds: 500);
      case FacebookAutomationPhase.setViewport:
      case FacebookAutomationPhase.selectVehicleType:
      case FacebookAutomationPhase.uploadPhotos:
      case FacebookAutomationPhase.enterYear:
      case FacebookAutomationPhase.enterMake:
      case FacebookAutomationPhase.enterModel:
      case FacebookAutomationPhase.enterMileage:
      case FacebookAutomationPhase.enterPrice:
      case FacebookAutomationPhase.selectBodyStyle:
      case FacebookAutomationPhase.selectCleanTitle:
      case FacebookAutomationPhase.selectCondition:
      case FacebookAutomationPhase.selectFuelType:
      case FacebookAutomationPhase.selectTransmission:
      case FacebookAutomationPhase.enterDescription:
      case FacebookAutomationPhase.publish:
      case FacebookAutomationPhase.selectGroups:
        return const Duration(milliseconds: 1000);
      case FacebookAutomationPhase.complete:
        return const Duration(milliseconds: 700);
    }
  }

  void _handleRetry(FacebookAutomationPhase phase, String reason) {
    if (_isPaused) {
      _pausedPhase = phase;
      return;
    }
    if (_phaseRetryCount < _maxRetries) {
      _phaseRetryCount++;
      final backoffMs = 1000 * _phaseRetryCount;
      debugPrint(
        '[FB-A11y] 🔄 Retry $_phaseRetryCount/$_maxRetries in ${backoffMs}ms — $reason',
      );
      _scheduler.schedule(Duration(milliseconds: backoffMs), () {
        _executePhase(phase);
      });
    } else {
      _handleError(phase, reason);
    }
  }

  Future<void> _handleError(FacebookAutomationPhase phase, String error) async {
    debugPrint('[FB-A11y] ❌ Error at ${phase.descriptionHe}: $error');
    pauseAutomation();
    _pausedPhase = phase;
    _phaseRetryCount = 0;
    onPhaseError?.call(phase, error);
    // Report the pause immediately; audio initialization must not delay the
    // remote heads-up notification or the local Resume controls.
    unawaited(_beepUser().catchError((Object _) {}));
  }

  // ── Alerts ────────────────────────────────────────────────────────────────

  Future<void> _beepUser() async {
    bool assetPlayed = false;
    try {
      final player = AudioPlayer();
      for (final asset in ['beep.mp3', 'beep.wav', 'alert.mp3', 'alert.wav']) {
        try {
          await player
              .play(AssetSource(asset))
              .timeout(const Duration(seconds: 2));
          assetPlayed = true;
          break;
        } catch (_) {}
      }
    } catch (_) {}
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
