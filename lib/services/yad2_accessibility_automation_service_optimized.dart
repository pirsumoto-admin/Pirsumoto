import 'automation_task_scheduler.dart';
import 'automation_accessibility_channel.dart';
import 'native_image_upload_request.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart' hide Source;
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';

import 'ocr_service.dart';
import 'ui_context.dart';
// [WHATSAPP-DISABLED] WhatsApp text validation import disabled in yad2 optimized service.
// import 'whatsapp_text_validation_service.dart';
import 'yad2_automation_models.dart' show AutomationPhase, VehiclePublishData;

typedef Yad2RecoveryPlanner =
    Future<Yad2RecoveryPlan?> Function(Yad2RecoveryRequest request);

typedef _StepAction = Future<_StepActionResult> Function();
typedef _StepValidator = Future<bool> Function();

enum Yad2RecoveryClassification {
  retryable,
  unknownPopup,
  missingElement,
  ambiguousElement,
  pageChanged,
  loginRequired,
  captchaOrBlock,
  manualRequired,
}

enum Yad2ToolName {
  tapElement,
  tapNodeAfter,
  tapNodeBefore,
  enterTextNear,
  enterTextBefore,
  selectDropdown,
  dismissPopup,
  scrollDown,
  pressBack,
  validatePhase,
  logTree,
}

class Yad2ToolCall {
  final Yad2ToolName tool;
  final Map<String, dynamic> args;

  const Yad2ToolCall({required this.tool, this.args = const {}});

  factory Yad2ToolCall.fromJson(Map<String, dynamic> json) {
    final rawTool = (json['tool'] as String? ?? '').trim();
    final tool = Yad2ToolName.values.firstWhere(
      (candidate) => candidate.name == rawTool,
      orElse: () => Yad2ToolName.validatePhase,
    );
    return Yad2ToolCall(
      tool: tool,
      args: Map<String, dynamic>.from(json['args'] as Map? ?? const {}),
    );
  }

  Map<String, dynamic> toJson() => {'tool': tool.name, 'args': args};
}

class Yad2RecoveryPlan {
  final Yad2RecoveryClassification classification;
  final String reason;
  final List<Yad2ToolCall> toolCalls;
  final String expectedResult;
  final double confidence;
  final bool resumeGreenPath;

  const Yad2RecoveryPlan({
    required this.classification,
    required this.reason,
    required this.toolCalls,
    required this.expectedResult,
    required this.confidence,
    this.resumeGreenPath = true,
  });

  factory Yad2RecoveryPlan.fromJson(Map<String, dynamic> json) {
    final raw = (json['classification'] as String? ?? '').trim();
    final classification = Yad2RecoveryClassification.values.firstWhere(
      (candidate) => candidate.name == raw,
      orElse: () => Yad2RecoveryClassification.manualRequired,
    );
    final calls =
        (json['tool_calls'] as List? ?? const [])
            .whereType<Map>()
            .map(
              (item) => Yad2ToolCall.fromJson(Map<String, dynamic>.from(item)),
            )
            .toList();
    return Yad2RecoveryPlan(
      classification: classification,
      reason: (json['reason'] as String? ?? '').trim(),
      toolCalls: calls,
      expectedResult: (json['expected_result'] as String? ?? '').trim(),
      confidence: (json['confidence'] as num?)?.toDouble() ?? 0,
      resumeGreenPath: json['resume_green_path'] as bool? ?? true,
    );
  }

  Map<String, dynamic> toJson() => {
    'classification': classification.name,
    'reason': reason,
    'tool_calls': toolCalls.map((call) => call.toJson()).toList(),
    'expected_result': expectedResult,
    'confidence': confidence,
    'resume_green_path': resumeGreenPath,
  };
}

class Yad2RecoveryRequest {
  final AutomationPhase phase;
  final String goal;
  final String failure;
  final VehiclePublishData formData;
  final Map<String, dynamic> observation;
  final List<String> availableTools;

  const Yad2RecoveryRequest({
    required this.phase,
    required this.goal,
    required this.failure,
    required this.formData,
    required this.observation,
    required this.availableTools,
  });

  Map<String, dynamic> toJson() => {
    'phase': phase.name,
    'phase_description': phase.description,
    'goal': goal,
    'failure': failure,
    'form_data': {
      'licenseNumber': formData.licenseNumber,
      'color': formData.color,
      'shade': formData.shade,
      'hand': formData.hand,
      'currentOwnership': formData.currentOwnership,
      'previousOwnership': formData.previousOwnership,
      'kilometers': formData.kilometers,
      'month': formData.month,
      'price': formData.price,
      'city': formData.city,
      'handicapped': formData.handicapped,
      'noTest': formData.noTest,
      'warranties': formData.warranties,
      'warrantyDurations': formData.warrantyDurations,
      'treatments': formData.treatments,
      'services': formData.services,
    },
    'observation': observation,
    'available_tools': availableTools,
    'required_response_schema': {
      'classification':
          'retryable | unknownPopup | missingElement | ambiguousElement | pageChanged | loginRequired | captchaOrBlock | manualRequired',
      'reason': 'short explanation',
      'tool_calls': [
        {
          'tool':
              'tapElement | tapNodeAfter | tapNodeBefore | enterTextNear | enterTextBefore | selectDropdown | dismissPopup | scrollDown | pressBack | validatePhase | logTree',
          'args': {},
        },
      ],
      'expected_result': 'what should become true after the tool calls',
      'confidence': 0.0,
      'resume_green_path': true,
    },
  };

  String toPrompt() =>
      'You are recovering a deterministic Yad2 form automation. '
      'Use only the listed tools. Do not invent raw coordinates. '
      'Return JSON matching required_response_schema only.\n'
      '${const JsonEncoder.withIndent('  ').convert(toJson())}';
}

class Yad2ToolResult {
  final bool success;
  final String reason;

  const Yad2ToolResult(this.success, this.reason);
}

class _StepActionResult {
  final bool success;
  final String reason;
  final AutomationPhase? completeAs;

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
    this.timeout = const Duration(seconds: 2),
    this.custom,
  });
}

class _AutomationStepSpec {
  final AutomationPhase phase;
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

class _ScreenSnapshot {
  final UIContext? ui;
  final String? nativeTree;
  final String? bodyText;
  final String? url;

  const _ScreenSnapshot({this.ui, this.nativeTree, this.bodyText, this.url});

  Map<String, dynamic> toJson() {
    final elements =
        ui?.axTree
            .where((el) => el.visible)
            .take(90)
            .map(
              (el) => {
                'role': el.role,
                'label': el.label,
                'value': el.value,
                'x': el.x,
                'y': el.y,
                'id': el.id,
              },
            )
            .toList() ??
        const [];
    final nativeLines = nativeTree?.split('\n').take(180).join('\n');
    return {
      'url': url,
      'bodyTextPreview': bodyText == null ? null : _clip(bodyText!, 1600),
      'shadowAxElements': elements,
      'nativeAccessibilityTreePreview': nativeLines,
      'hasScreenshot': ui?.screenshot.isNotEmpty ?? false,
    };
  }
}

class Yad2AccessibilityAutomationService {
  final VehiclePublishData formData;
  final WebViewController controller;
  final Future<UIContext?> Function()? observeUI;
  final OcrService? ocrService;
  final Yad2RecoveryPlanner? recoveryPlanner;
  final bool enableLlmRecovery;
  final bool allowOcrFallback;
  final Duration phaseTimeout;

  final void Function(AutomationPhase phase)? onPhaseChanged;
  final void Function(AutomationPhase phase)? onPhaseComplete;
  final void Function(AutomationPhase phase, String error)? onPhaseError;
  final void Function(bool success)? onAutomationComplete;
  final void Function(String source, String target)? onAutomationFallback;
  final VoidCallback? onFirstStepDetected;
  final void Function(double cssX, double cssY)? onTapPreview;

  static const int _maxRetries = 3;
  static const MethodChannel _channel = MethodChannel(
    'com.pirsumoto/accessibility',
  );

  int _phaseRetryCount = 0;
  bool _recoveryAttempted = false;
  bool _isPaused = false;
  AutomationPhase? _pausedPhase;
  AutomationPhase? _currentPhase;
  final Set<String> _completedPhaseActions = {};

  bool _settingsFetched = false;
  List<String> _warranties = [];
  Map<String, String> _warrantyDurations = {};
  List<String> _treatments = [];
  List<String> _services = [];

  int? _ocrFrameId;
  final Map<String, TextLocation?> _ocrCache = {};

  // [WHATSAPP-DISABLED] startedFromWhatsApp and whatsAppSenderKey disabled.
  // final bool startedFromWhatsApp;
  // final String? whatsAppSenderKey;

  final void Function(bool visible)? onToggleOverlayVisibility;
  final VoidCallback? onLoginRequired;
  String? extractedDescription;
  static String? lastExtractedDescription;

  Yad2AccessibilityAutomationService({
    required this.formData,
    required this.controller,
    this.observeUI,
    this.ocrService,
    this.recoveryPlanner,
    this.enableLlmRecovery = true,
    this.allowOcrFallback = true,
    this.phaseTimeout = const Duration(minutes: 2),
    this.onPhaseChanged,
    // [WHATSAPP-DISABLED] startedFromWhatsApp and whatsAppSenderKey disabled.
    // this.startedFromWhatsApp = false,
    // this.whatsAppSenderKey,
    this.onPhaseComplete,
    this.onPhaseError,
    this.onAutomationComplete,
    this.onAutomationFallback,
    this.onFirstStepDetected,
    this.onLoginRequired,
    this.onTapPreview,
    this.onToggleOverlayVisibility,
  }) {
    activeInstance = this;
  }

  static Yad2AccessibilityAutomationService? activeInstance;

  static void stopAll() {
    activeInstance?.stop();
    activeInstance = null;
  }

  static Future<bool> checkPermission() async {
    try {
      if (!Platform.isAndroid) return true;
      final hasPermission = await _channel.invokeMethod<bool>(
        'checkPermission',
      );
      return hasPermission ?? false;
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
      debugPrint('[Yad2-A11y] Error opening accessibility settings: $e');
    }
  }

  static Future<void> showToast(
    String message, {
    int chunkDelayMs = 3500,
  }) async {
    try {
      if (Platform.isAndroid) {
        final cleanMsg = message.trim();
        if (cleanMsg.isEmpty) return;

        // If short enough and single line, show directly
        if (cleanMsg.length <= 70 && !cleanMsg.contains('\n')) {
          await _channel.invokeMethod('showToast', {'message': cleanMsg});
          return;
        }

        final chunks = _splitIntoToastChunks(cleanMsg, maxChunkSize: 70);
        for (int i = 0; i < chunks.length; i++) {
          final prefix =
              chunks.length > 1 ? '(${i + 1}/${chunks.length}) ' : '';
          await _channel.invokeMethod('showToast', {
            'message': '$prefix${chunks[i]}',
          });
          if (i < chunks.length - 1) {
            await Future.delayed(Duration(milliseconds: chunkDelayMs));
          }
        }
      }
    } catch (e) {
      debugPrint('[Yad2-A11y] Error showing toast: $e');
    }
  }

  static List<String> _splitIntoToastChunks(
    String text, {
    int maxChunkSize = 70,
  }) {
    final List<String> chunks = [];
    final lines = text.split('\n');
    String currentChunk = '';

    for (final rawLine in lines) {
      final line = rawLine.trim();
      if (line.isEmpty) continue;

      final words = line.split(RegExp(r'\s+'));
      for (final word in words) {
        if (word.isEmpty) continue;

        if (word.length > maxChunkSize) {
          if (currentChunk.isNotEmpty) {
            chunks.add(currentChunk);
            currentChunk = '';
          }
          for (int i = 0; i < word.length; i += maxChunkSize) {
            final end =
                (i + maxChunkSize < word.length)
                    ? i + maxChunkSize
                    : word.length;
            chunks.add(word.substring(i, end));
          }
          continue;
        }

        if (currentChunk.isEmpty) {
          currentChunk = word;
        } else if ((currentChunk.length + 1 + word.length) <= maxChunkSize) {
          currentChunk += ' $word';
        } else {
          chunks.add(currentChunk);
          currentChunk = word;
        }
      }

      if (currentChunk.isNotEmpty) {
        chunks.add(currentChunk);
        currentChunk = '';
      }
    }

    if (currentChunk.isNotEmpty) {
      chunks.add(currentChunk);
    }

    return chunks.isEmpty ? [text] : chunks;
  }

  bool get isPaused => _isPaused;
  AutomationPhase? get pausedPhase => _pausedPhase;
  AutomationPhase? get currentPhase => _currentPhase;

  void _savePhase(AutomationPhase phase) {
    if (_currentPhase != phase) _completedPhaseActions.clear();
    _currentPhase = phase;
    _pausedPhase = _isPaused ? phase : null;
    onPhaseChanged?.call(phase);
  }

  void dispose() {
    _cancelImageUpload();
    _scheduler.invalidate();
    _stopped = true;
    _isPaused = true;
    _currentPhase = null;
    _pausedPhase = null;
    if (identical(activeInstance, this)) activeInstance = null;
    // [WHATSAPP-DISABLED] _updateWhatsAppPublishingFlag disabled.
    // unawaited(_updateWhatsAppPublishingFlag(false));
  }

  final _scheduler = AutomationTaskScheduler();
  late final _automationChannel = AutomationAccessibilityChannel((reason) {
    if (_stopped || _isPaused) return;
    unawaited(
      _handleError(
        _currentPhase ?? AutomationPhase.phase1,
        '$reason. החזר את מסך הפרסום ולחץ המשך.',
      ),
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

  bool _stopped = false;
  bool _started = false;
  bool _actionInterrupted = false;

  bool get _inputBlocked {
    if (!_stopped && !_isPaused) return false;
    _actionInterrupted = true;
    return true;
  }

  // Multi-action phases retain successful selections across pause/retry, so
  // resuming cannot uncheck an option or close an already-open dropdown.
  Future<bool> _runOnce(String key, Future<bool> Function() action) async {
    if (_completedPhaseActions.contains(key)) return true;
    if (_inputBlocked) return false;
    final succeeded = await action();
    if (succeeded && !_actionInterrupted) _completedPhaseActions.add(key);
    return succeeded;
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

  void stop() {
    _cancelImageUpload();
    _scheduler.invalidate();
    _stopped = true;
    debugPrint('[Yad2-A11y] Stop requested');
    _isPaused = true;
    _currentPhase = null;
    _pausedPhase = null;
    // [WHATSAPP-DISABLED] _updateWhatsAppPublishingFlag disabled.
    // unawaited(_updateWhatsAppPublishingFlag(false));
    try {
      WakelockPlus.disable();
    } catch (_) {}
  }

  void pauseAutomation() {
    if (_stopped) return;
    _cancelImageUpload();
    _scheduler.invalidate();
    debugPrint('[Yad2-A11y] Pause requested');
    _isPaused = true;
    _pausedPhase = _currentPhase ?? AutomationPhase.phase1;
    onToggleOverlayVisibility?.call(true);
  }

  void resumeAutomation() {
    if (_stopped || !_isPaused) return;
    _scheduler.invalidate();
    final generation = _scheduler.generation;
    if (_inFlight.isNotEmpty) {
      Future.wait(_inFlight.toList())
          .timeout(const Duration(seconds: 45))
          .then((_) {
            if (!_stopped && generation == _scheduler.generation) {
              resumeAutomation();
            }
          })
          .catchError((Object e) {
            debugPrint('[Yad2] Cannot resume before phase drains: $e');
            if (!_stopped && generation == _scheduler.generation) {
              unawaited(
                _handleError(
                  _pausedPhase ?? _currentPhase ?? AutomationPhase.phase1,
                  'הפעולה הקודמת עדיין מסתיימת. נסה שוב להמשיך לאחר סיומה.',
                ),
              );
            }
          });
      return;
    }
    _isPaused = false;
    final phase = _pausedPhase ?? _currentPhase ?? AutomationPhase.phase1;
    _pausedPhase = null;
    _processPhase(phase);
  }

  Future<void> stepBack() async {
    if (_stopped || !_isPaused) return;
    await pauseAndWait();
    if (_stopped) return;
    final current = _pausedPhase ?? _currentPhase;
    if (current == null) return;
    final currentIndex = current.index;
    if (currentIndex <= 0) return;
    final prev = AutomationPhase.values[currentIndex - 1];
    debugPrint(
      '[Yad2-A11y] Stepping back from ${current.name} to ${prev.name}',
    );
    _savePhase(prev);
  }

  // [WHATSAPP-DISABLED] _hasNotifiedCompletion field disabled.
  // bool _hasNotifiedCompletion = false;

  void startAutomation() {
    if (_stopped || _started) return;
    _started = true;
    _scheduler.invalidate();
    debugPrint('[Yad2-A11y] Starting optimized Accessibility automation');
    onFirstStepDetected?.call();
    onToggleOverlayVisibility?.call(true);
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    WakelockPlus.enable();
    // [WHATSAPP-DISABLED] _updateWhatsAppPublishingFlag disabled.
    // unawaited(_updateWhatsAppPublishingFlag(true));
    _processPhase(AutomationPhase.phase1);
  }

  void _processPhase(AutomationPhase phase) {
    if (_stopped) return;
    _savePhase(phase);
    _phaseRetryCount = 0;
    _recoveryAttempted = false;
    if (_isPaused) {
      _pausedPhase = phase;
      debugPrint('[Yad2-A11y] Automation paused at phase: ${phase.name}');
      return;
    }
    unawaited(_executePhase(phase));
  }

  Future<void> _executePhase(AutomationPhase phase) async {
    if (_stopped) return;
    final work = _scheduler.run(() async {
      // A watchdog requests a cooperative pause; the running platform call is
      // still drained before resume or remote takeover can issue another input.
      final watchdog = Timer(phaseTimeout, () {
        if (!_stopped && !_isPaused) {
          unawaited(
            _handleError(
              _currentPhase ?? phase,
              'השלב לא התקדם בזמן הצפוי. ניתן לבדוק את המסך ולהמשיך.',
            ),
          );
        }
      });
      try {
        await _executePhaseTracked(phase);
      } catch (e, st) {
        debugPrint('[Yad2-A11y] Phase failed: $e\n$st');
        if (!_stopped && !_isPaused) {
          await _handleError(_currentPhase ?? phase, e.toString());
        }
      } finally {
        watchdog.cancel();
      }
    });
    _inFlight.add(work);
    try {
      await work;
    } finally {
      _inFlight.remove(work);
    }
  }

  Future<void> _executePhaseTracked(AutomationPhase phase) async {
    _currentPhase = phase;
    if (_isPaused) {
      _pausedPhase = phase;
      return;
    }

    final windowReady = await _ensureAutomationWindow();
    if (_stopped || _isPaused) return;
    if (!windowReady) {
      await _handleError(phase, 'מסך הפרסום אינו זמין לאוטומציה.');
      return;
    }

    // [WHATSAPP-DISABLED] _updateWhatsAppPublishingFlag disabled.
    // unawaited(_updateWhatsAppPublishingFlag(true));

    debugPrint(
      '[Yad2-A11y] === ${phase.name} attempt '
      '${_phaseRetryCount + 1}/${_maxRetries + 1} ===',
    );

    if (phase == AutomationPhase.complete) {
      try {
        // final confirmed = await _retryUntil(() async {
        //   final text =
        //       (await controller.runJavaScriptReturningResult(
        //         "Array.from(document.querySelectorAll('h1,h2,[role=status],[role=alert]')).map(e=>e.innerText).join(' ')",
        //       )).toString();
        //   return PublicationConfirmation.yad2(text);
        // }, timeout: const Duration(seconds: 20));
        if (_stopped || _isPaused) return;
        // if (!confirmed) {
        //   await _handleError(
        //     phase,
        //     'לא התקבל אישור פרסום מיד2. יש לבדוק את האתר. המשך יבדוק אישור בלבד, ללא פרסום חוזר.',
        //   );
        //   return;
        // }
        WakelockPlus.disable();
        _handlePhaseComplete(AutomationPhase.complete);
      } catch (_) {
        if (!_stopped) {
          await _handleError(phase, 'לא ניתן לאמת את תוצאת הפרסום ביד2');
        }
      }
      return;
    }

    final spec = _buildStepSpec(phase);
    if (spec == null) {
      await _handleError(phase, 'No optimized step spec is registered.');
      return;
    }

    _StepActionResult result;
    try {
      _actionInterrupted = false;
      result = await spec.action();
      if (_stopped || _actionInterrupted) return;
    } catch (e, st) {
      debugPrint('[Yad2-A11y] Phase exception: $e\n$st');
      await _failOrRecover(spec, e.toString());
      return;
    }
    if (!result.success) {
      await _failOrRecover(spec, result.reason);
      return;
    }

    // Commit successful actions before any settling/verification await. A
    // pause here must resume at the next action, never repeat a successful tap.
    final completedPhase = result.completeAs ?? phase;
    _savePhase(_nextPhaseAfter(completedPhase) ?? AutomationPhase.complete);
    if (_isPaused) return;
    try {
      await _waitForUiSettle(spec.settleDelay);
      if (_stopped || _isPaused) return;

      // Advisory verification only. The action's own tap/lookup success is the
      // authoritative gate (mirrors the proven sequential flow). A validation
      // miss is logged but NEVER re-runs a destructive action — re-running
      // already-applied taps (license search, "next step", dropdowns) is what
      // corrupted the form state in the previous version and broke the flow.
      if (spec.validation != null) {
        final validationPassed = await _validateStep(spec);
        if (!validationPassed) {
          debugPrint(
            '[Yad2-A11y] ⚠️ Soft validation miss for ${phase.name} '
            '(a11y tree did not confirm "${spec.goal}") — proceeding on '
            'action success.',
          );
        }
      }
    } catch (e) {
      // Verification is advisory; an exception cannot undo a completed action.
      debugPrint('[Yad2-A11y] Advisory verification failed: $e');
    }
    if (_stopped || _isPaused) return;
    _phaseRetryCount = 0;
    _handlePhaseComplete(completedPhase);
  }

  _AutomationStepSpec? _buildStepSpec(AutomationPhase phase) {
    switch (phase) {
      case AutomationPhase.phase1:
        return _AutomationStepSpec(
          phase: phase,
          goal: 'Detect the Yad2 vehicle publication entry form.',
          action: _actionDetectEntryForm,
          settleDelay: Duration(milliseconds: 500),
        );
      case AutomationPhase.phase2:
        return _AutomationStepSpec(
          phase: phase,
          goal: 'Enter license number and run vehicle lookup.',
          action: _actionEnterLicenseAndSearch,
          validation: const _StepValidation(
            nextMarker: 'לשלב הבא|שלב הבא|לשלב',
            timeout: Duration(seconds: 10),
          ),
        );
      case AutomationPhase.phase3:
        return _AutomationStepSpec(
          phase: phase,
          goal: 'Submit the vehicle lookup result.',
          action: () => _tapRequired('לשלב הבא|שלב הבא|לשלב'),
          validation: const _StepValidation(
            mustContain: 'צבע|צבע*|צבע הרכב|צבע הרכב*',
            timeout: Duration(seconds: 10),
          ),
        );
      case AutomationPhase.phase4:
        return _AutomationStepSpec(
          phase: phase,
          goal: 'Open the color dropdown.',
          action:
              () => _openDropdownByLabel(
                'צבע*|צבע|צבע הרכב*|צבע הרכב',
                skipToPhase:
                    AutomationPhase
                        .phase5, // Treat phase5 as complete, next is phase5a
              ),
          validation: _StepValidation(
            mustContain: _nonEmpty(formData.color, fallback: 'כחול'),
          ),
        );
      case AutomationPhase.phase5:
        return _AutomationStepSpec(
          phase: phase,
          goal: 'Select vehicle color and shade.',
          action: _actionSelectColorAndShade,
          validation: _StepValidation(
            selectedValue: _nonEmpty(formData.shade, fallback: formData.color),
            timeout: const Duration(seconds: 6),
          ),
        );
      case AutomationPhase.phase5a:
        return _AutomationStepSpec(
          phase: phase,
          goal: 'Open road-month dropdown.',
          action:
              () => _openDropdownByLabel(
                'חודש עלייה לכביש|חודש עליה לכביש',
                skipToPhase:
                    AutomationPhase
                        .phase5b, // Treat phase5b as complete, next is phase5c
              ),
          validation: _StepValidation(
            mustContain: VehiclePublishData.monthToHebrew(formData.month),
          ),
        );
      case AutomationPhase.phase5b:
        final month = VehiclePublishData.monthToHebrew(formData.month);
        final search = _variants(month, formData.month);
        return _AutomationStepSpec(
          phase: phase,
          goal: 'Select road month.',
          action: () => _selectOpenOption(search, selectedValue: month),
          validation: _StepValidation(
            selectedValue: month,
            selectedAfterLabel: 'חודש עלייה לכביש|חודש עליה לכביש',
            selectedAfterOffset: 1,
            mustNotContain: null,
            custom: null,
            timeout: const Duration(seconds: 6),
          ),
        );
      case AutomationPhase.phase5c:
        return _AutomationStepSpec(
          phase: phase,
          goal: 'Apply no-test checkbox when requested.',
          action: _actionNoTest,
          validation: const _StepValidation(),
        );
      case AutomationPhase.phase5c1:
        return _AutomationStepSpec(
          phase: phase,
          goal: 'Open test-month dropdown.',
          action:
              () => _openDropdownByLabel(
                'טסט עד',
                skipToPhase: AutomationPhase.phase5c3,
              ),
          validation: _StepValidation(
            mustContain: VehiclePublishData.monthToHebrew(
              formData.testMonth ?? '',
            ),
          ),
        );
      case AutomationPhase.phase5c2:
        return _AutomationStepSpec(
          phase: phase,
          goal: 'Open test-year dropdown.',
          action: () => _openDropdownByLabel('שנה'),
          validation: _StepValidation(mustContain: formData.testYear),
        );
      case AutomationPhase.phase5c3:
        return _AutomationStepSpec(
          phase: phase,
          goal: 'Select test date.',
          action: _actionTestDate,
          validation: const _StepValidation(),
        );
      case AutomationPhase.phase5d:
        return _AutomationStepSpec(
          phase: phase,
          goal: 'Select warranty checkboxes and their durations.',
          action: _actionWarranties,
          validation: const _StepValidation(),
        );
      case AutomationPhase.phase5e:
        return _AutomationStepSpec(
          phase: phase,
          goal: 'Select treatment options.',
          action: () async {
            await _fetchSettingsIfNeeded();
            return _tapListValues(_treatments);
          },
          validation: const _StepValidation(),
        );
      case AutomationPhase.phase5f:
        return _AutomationStepSpec(
          phase: phase,
          goal: 'Select service options.',
          action: () async {
            await _fetchSettingsIfNeeded();
            return _tapListValues(_services);
          },
          validation: const _StepValidation(),
        );
      case AutomationPhase.phase6:
        return _AutomationStepSpec(
          phase: phase,
          goal: 'Open hand dropdown unless hand is already filled.',
          action: _actionOpenHandDropdown,
          validation: const _StepValidation(mustContain: 'יד'),
        );
      case AutomationPhase.phase7:
        final hand = _handSearchValue(formData.hand);
        return _AutomationStepSpec(
          phase: phase,
          goal: 'Select hand value.',
          action:
              () =>
                  _selectOpenOption(hand, selectedValue: hand.split('|').first),
          validation: _StepValidation(
            selectedValue: hand.split('|').first,
            selectedAfterLabel: 'יד*|יד',
          ),
        );
      case AutomationPhase.phase8:
        return _AutomationStepSpec(
          phase: phase,
          goal: 'Open current ownership dropdown.',
          action: () async {
            await _scrollDown(0.22, accessibilityOnly: true);
            return _openDropdownByLabel(
              'בעלות נוכחית',
              skipToPhase:
                  AutomationPhase
                      .phase9, // Treat phase9 as complete, next is phase10
            );
          },
          validation: _StepValidation(
            mustContain: _nonEmpty(
              formData.currentOwnership,
              fallback: 'פרטית',
            ),
          ),
        );
      case AutomationPhase.phase9:
        final ownership = _valueWithLastWordVariant(formData.currentOwnership);
        return _AutomationStepSpec(
          phase: phase,
          goal: 'Select current ownership value.',
          action:
              () => _selectOpenOption(
                ownership,
                selectedValue: formData.currentOwnership.trim(),
              ),
          validation: _StepValidation(
            selectedValue: formData.currentOwnership.trim(),
            selectedAfterLabel: 'בעלות נוכחית',
          ),
        );
      case AutomationPhase.phase10:
        return _AutomationStepSpec(
          phase: phase,
          goal: 'Open previous ownership dropdown.',
          action:
              () => _openDropdownByLabel(
                'בעלות מקורית|בעלות קודמת',
                skipToPhase:
                    AutomationPhase
                        .phase11, // Treat phase11 as complete, next is phase12
              ),
          validation: _StepValidation(
            mustContain: _nonEmpty(
              formData.previousOwnership,
              fallback: 'פרטית',
            ),
          ),
        );
      case AutomationPhase.phase11:
        toolLogTree();
        final ownership = _valueWithLastWordVariant(formData.previousOwnership);
        final currentTrimmed = formData.currentOwnership.trim();
        final previousTrimmed = formData.previousOwnership.trim();
        return _AutomationStepSpec(
          phase: phase,
          goal: 'Select previous ownership value.',
          action: () async {
            int targetInstance =
                (currentTrimmed == previousTrimmed && currentTrimmed.isNotEmpty)
                    ? 2
                    : 1;
            if (targetInstance == 1 &&
                await _isElementPresent(ownership, targetInstance: 2)) {
              targetInstance = 2;
            }
            return _selectOpenOption(
              ownership,
              selectedValue: formData.previousOwnership.trim(),
              targetInstance: targetInstance,
            );
          },
          validation: _StepValidation(
            selectedValue: formData.previousOwnership.trim(),
            selectedAfterLabel: 'בעלות מקורית|בעלות קודמת',
          ),
        );
      case AutomationPhase.phase12:
        return _AutomationStepSpec(
          phase: phase,
          goal: 'Enter kilometers.',
          action: _actionEnterKilometers,
          validation: _StepValidation(
            mustContain: _nonEmpty(formData.kilometers, fallback: 'קילומטראז'),
          ),
        );
      case AutomationPhase.phase13:
        return _AutomationStepSpec(
          phase: phase,
          goal: 'Apply disability accessibility option when requested.',
          action: _actionDisability,
          validation: const _StepValidation(),
        );
      case AutomationPhase.phase14:
        return _AutomationStepSpec(
          phase: phase,
          goal: 'Generate, save and submit the vehicle description.',
          action: _actionSubmitAdditionalInfo,
          validation: _StepValidation(
            custom: () => _isElementPresent('מחיר|סכום מינימלי|סכום'),
          ),
        );
      case AutomationPhase.phase15:
        return _AutomationStepSpec(
          phase: phase,
          goal: 'Select city autocomplete value.',
          action: _actionSelectCity,
          validation: _StepValidation(custom: () => _isElementPresent(_city)),
        );
      case AutomationPhase.phase16:
        return _AutomationStepSpec(
          phase: phase,
          goal: 'Enter price and submit price section.',
          action: _actionEnterPrice,
          validation: _StepValidation(
            custom:
                () => _isElementPresent(
                  'תמונות|העלאת תמונות|הוספת תמונות|תמונות הרכב',
                ),
          ),
        );
      case AutomationPhase.phase17:
        return _AutomationStepSpec(
          phase: phase,
          goal: 'Upload photos when available and continue.',
          action: _actionUploadPhotosAndContinue,
          validation: _StepValidation(
            custom: () => _isElementPresent(_termsLabel),
          ),
        );
      case AutomationPhase.phase18:
        return _AutomationStepSpec(
          phase: phase,
          goal: 'Detect terms checkbox and click "לשלב הבא" button.',
          action: _actionTermsAgreement,
          validation: const _StepValidation(
            nextMarker: 'סגור|X|סגירה|ביטול|לשלב הבא|סיום|המודעה',
            timeout: Duration(seconds: 8),
          ),
        );
      case AutomationPhase.phase19:
        return _AutomationStepSpec(
          phase: phase,
          goal:
              'Dismiss promotional screen using X close button in accessibility tree.',
          action: _actionDismissPromotionalScreen,
          validation: const _StepValidation(timeout: Duration(seconds: 5)),
        );
      case AutomationPhase.complete:
        return null;
    }
  }

  Future<_StepActionResult> _actionDetectEntryForm() async {
    // Show the "הפסק" button and overlay before starting detection
    onFirstStepDetected?.call();
    onToggleOverlayVisibility?.call(true);

    bool loginDetected = false;
    const resetTargets = 'התחלה מחדש|להתחיל מחדש|התחל מחדש';

    // 5 attempts is the stop condition if neither license input nor התחלה מחדש is found
    for (int attempt = 1; attempt <= 5; attempt++) {
      if (_inputBlocked) {
        return const _StepActionResult.failure('Action cancelled.');
      }

      debugPrint(
        '[Yad2-A11y] Inspecting entry form & initial popups (attempt $attempt/5)...',
      );

      // 1. Check for login screen
      if (await _checkIsLoginScreen()) {
        loginDetected = true;
        break;
      }

      // 2. Check Option A: Is the license plate input (000-00-000 or input before חיפוש) found?
      // If found -> immediately exit the 5 tries and continue to license filling logic!
      final hasLicenseInput = await _isLicenseInputPresent();
      if (hasLicenseInput) {
        debugPrint(
          '[Yad2-A11y] ✅ License plate input detected — no popup exists, exiting 5 tries and starting license filling.',
        );
        return const _StepActionResult.success();
      }

      // 3. Check Option B: Is "התחלה מחדש" popup found?
      // If found -> immediately exit the 5 tries, click on "התחלה מחדש", wait for reset, and continue to license filling!
      final hasResetPopup = await _isElementPresent(resetTargets);
      if (hasResetPopup) {
        debugPrint(
          '[Yad2-A11y] ⚠️ Detected "$resetTargets" popup — clicking to reset and proceeding to license filling.',
        );

        bool dismissed = await toolFindElementAndTap(resetTargets);
        if (dismissed) {
          debugPrint(
            '[Yad2-A11y] Reset popup clicked — waiting for page reset and starting license filling...',
          );

          await _waitForUiSettle(const Duration(milliseconds: 1500));
          return const _StepActionResult.success();
        }
      }

      // 4. Check for any other known info popups (e.g. 'הבנתי', 'עדכנתי', etc.)
      if (await _dismissKnownPopups()) {
        await _waitForUiSettle(const Duration(milliseconds: 1000));
        if (await _isLicenseInputPresent()) {
          return const _StepActionResult.success();
        }
      }

      if (attempt < 5) {
        await Future.delayed(const Duration(seconds: 1));
      }
    }

    if (loginDetected) {
      _startLoginGate();
      return const _StepActionResult.failure('Login required.');
    }

    // Stop condition reached after 5 attempts where none of the 2 options were found

    return const _StepActionResult.failure('Yad2 entry form not found.');
  }

  Future<_StepActionResult> _actionEnterLicenseAndSearch() async {
    await Future.delayed(const Duration(milliseconds: 800));
    // Best-effort reset-popup dismissal — check Accessibility tree first, JS fallback as last resort
    const resetTarget = 'התחלה מחדש|מחדש|להתחיל מחדש|התחל מחדש';
    bool dismissedReset = await toolFindElementAndTap(resetTarget);
    if (dismissedReset) {
      debugPrint('[Yad2-A11y] Reset popup found — tapped start-over.');
      await _waitForUiSettle(const Duration(milliseconds: 1200));
    }
    final license = _nonEmpty(formData.licenseNumber, fallback: '5211639');
    final entered = await _retryUntil(
      () => _performWithPopupHandling(
        () => toolEnterTextBefore('חיפוש', license),
      ),
      timeout: const Duration(seconds: 8),
    );
    if (!entered) {
      return const _StepActionResult.failure(
        'Could not enter and verify the license number.',
      );
    }
    final searched = await _performWithPopupHandling(() => tapSmart('חיפוש'));
    return searched
        ? const _StepActionResult.success()
        : const _StepActionResult.failure('Search button not found.');
  }

  Future<_StepActionResult> _tapRequired(String text) async {
    final tapped = await _retryUntil(
      () => _performWithPopupHandling(() => tapSmart(text)),
      timeout: const Duration(seconds: 10),
    );
    return tapped
        ? const _StepActionResult.success()
        : _StepActionResult.failure('Could not tap "$text".');
  }

  Future<_StepActionResult> _openDropdownByLabel(
    String label, {
    AutomationPhase? skipToPhase,
    int checkOffset = 2,
  }) async {
    final existingText = await toolGetNodeTextAfter(label, offset: checkOffset);

    if (label.contains('חודש')) {
      final t1 = await toolGetNodeTextAfter(label, offset: 1);
      final t2 = await toolGetNodeTextAfter(label, offset: 2);
      final t3 = await toolGetNodeTextAfter(label, offset: 3);
      debugPrint(
        '[Yad2-A11y] _openDropdownByLabel DEBUG "$label" -> offsets: [1: "${t1 ?? 'null'}"], [2: "${t2 ?? 'null'}"], [3: "${t3 ?? 'null'}"]',
      );
    }

    if (skipToPhase != null) {
      if (existingText != null && existingText.trim().isNotEmpty) {
        final lower = existingText.toLowerCase();
        if (!lower.contains('בחיר') &&
            !lower.contains('בחר') &&
            !lower.contains('הזן')) {
          debugPrint(
            '[Yad2-A11y] Dropdown "$label" already filled with: "$existingText". Treating as complete: ${skipToPhase.name}.',
          );
          return _StepActionResult.success(completeAs: skipToPhase);
        }
      }
    }

    final opened = await _runOnce(
      'dropdown:$label',
      () => _retryUntil(
        () => _performWithPopupHandling(() async {
          if (await toolTapNodeAfter(label)) return true;
          return tapSmart(label);
        }),
        timeout: const Duration(seconds: 8),
      ),
    );
    return opened
        ? const _StepActionResult.success()
        : _StepActionResult.failure('Dropdown "$label" did not open.');
  }

  Future<_StepActionResult> _actionSelectColorAndShade() async {
    await _scrollDown(0.2, accessibilityOnly: true);
    final color = _nonEmpty(formData.color, fallback: 'כחול');
    final shade = _nonEmpty(formData.shade, fallback: color);
    final colorSelected = await _selectOpenOption(color, selectedValue: color);
    if (!colorSelected.success) return colorSelected;

    await Future.delayed(const Duration(milliseconds: 800));
    final shadeOpened = await _openDropdownByLabel('גוון*|גוון');
    if (!shadeOpened.success) return shadeOpened;

    int shadeInstance =
        (color.trim() == shade.trim() && color.trim().isNotEmpty) ? 2 : 1;
    if (shadeInstance == 1 &&
        await _isElementPresent(shade, targetInstance: 2)) {
      shadeInstance = 2;
    }
    await Future.delayed(const Duration(milliseconds: 800));
    return _selectOpenOption(
      shade,
      selectedValue: shade,
      targetInstance: shadeInstance,
    );
  }

  Future<_StepActionResult> _selectOpenOption(
    String option, {
    required String selectedValue,
    int targetInstance = 1,
    bool closeAfterSelect = false,
  }) async {
    final tapped = await _runOnce(
      'option:$option:$targetInstance',
      () => _retryUntil(
        () => _performWithPopupHandling(() async {
          int instanceToUse = targetInstance;
          if (instanceToUse > 1 &&
              !await _isElementPresent(option, targetInstance: instanceToUse)) {
            instanceToUse = 1;
          }
          return tapSmart(option, targetInstance: instanceToUse);
        }),
        timeout: const Duration(seconds: 2),
      ),
    );
    if (!tapped) {
      return _StepActionResult.failure('Option "$option" was not found.');
    }
    await _waitForUiSettle(const Duration(milliseconds: 600));
    if (closeAfterSelect) {
      await _closeDropdownIfNeeded();
    }
    // Match the original flow exactly: a successful tap IS success. Confirming
    // the chosen value back in the a11y tree is advisory only — Hebrew dropdowns
    // frequently don't re-expose the selected value, and gating on it here would
    // re-run (re-tap) the whole step and corrupt the form.
    if (selectedValue.trim().isNotEmpty &&
        !await _isElementPresent(selectedValue)) {
      debugPrint(
        '[Yad2-A11y] ⚠️ Selected "$selectedValue" not confirmed in tree — '
        'proceeding (original tap-and-continue behavior).',
      );
    }
    return const _StepActionResult.success();
  }

  Future<_StepActionResult> _actionNoTest() async {
    if (!formData.govIl && formData.noTest) {
      await _retryUntil(
        () => _performWithPopupHandling(() => tapSmart('ללא טסט')),
        timeout: const Duration(seconds: 4),
      );
    }
    return const _StepActionResult.success();
  }

  Future<_StepActionResult> _actionTestDate() async {
    if (!formData.govIl && !formData.noTest) {
      if (formData.testMonth != null && formData.testMonth!.isNotEmpty) {
        final monthHebrew = VehiclePublishData.monthToHebrew(formData.testMonth!);
        await _selectOpenOption(
          _variants(monthHebrew, formData.testMonth!),
          selectedValue: monthHebrew,
        );
      }
      if (formData.testYear != null && formData.testYear!.isNotEmpty) {
        // Open year dropdown and select
        await _openDropdownByLabel('שנה');
        await _selectOpenOption(formData.testYear!, selectedValue: formData.testYear!);
      }
    }
    return const _StepActionResult.success();
  }

  Future<_StepActionResult> _actionWarranties() async {
    await _fetchSettingsIfNeeded();
    if (_warranties.isEmpty) {
      await _scrollDown(0.3, accessibilityOnly: true);
      return const _StepActionResult.success();
    }
    final durationCounts = <String, int>{};
    final battery =
        _warranties.where((warranty) => warranty.contains('סוללה')).toList();
    final others =
        _warranties.where((warranty) => !warranty.contains('סוללה')).toList();

    Future<bool> process(List<String> warranties) async {
      for (final warranty in warranties) {
        final checked = await _runOnce(
          'warranty:$warranty',
          () => toolEnsureBenefitSelected(warranty),
        );
        if (!checked) return false;
        await Future.delayed(const Duration(milliseconds: 800));

        final duration = _warrantyDurations[warranty]?.trim();
        if (duration == null || duration.isEmpty) continue;
        final instance = (durationCounts[duration] ?? 0) + 1;
        durationCounts[duration] = instance;
        await _scrollDown(0.1, accessibilityOnly: true);

        final selected = await selectDropdownSmart(
          label: _getWarrantyDropdownLabel(warranty),
          value: duration,
          valueInstance: instance,
        );
        if (!selected) return false;
      }
      return true;
    }

    final ok = await process(battery) && await process(others);
    return ok
        ? const _StepActionResult.success()
        : const _StepActionResult.failure(
          'Warranty duration selection failed.',
        );
  }

  Future<_StepActionResult> _tapListValues(List<String> values) async {
    if (values.isEmpty) {
      await _scrollDown(0.3, accessibilityOnly: true);
      return const _StepActionResult.success();
    }
    for (final value in values) {
      final tapped = await _runOnce(
        'list:$value',
        () => toolEnsureBenefitSelected(value),
      );
      if (!tapped) {
        return _StepActionResult.failure('Could not select "$value".');
      }
    }
    return const _StepActionResult.success();
  }

  /// ToggleButton on Xiaomi, checkbox on some WebViews. A tap is not proof
  /// of selection, and retrying an already-selected toggle would turn it off.
  Future<bool> toolEnsureBenefitSelected(String value) async {
    final shortLabel = value.replaceFirst(RegExp(r'^אחריות\s+'), '').trim();
    final target = <String>{
      value.trim(),
      shortLabel,
      if (value.contains('שלדה')) 'על שלדה, מנוע וגיר',
      if (value.contains('יבואן')) 'מהיבואן',
      if (value.contains('סוכנות')) 'מהסוכנות',
      if (value.contains('סוללה')) 'על הסוללה',
    }.join('|');
    var useGesture = false;
    try {
      for (var attempt = 0; attempt < 8; attempt++) {
        if (_inputBlocked) return false;
        final state = await _automationChannel.invokeMethod<String>(
          'ensureCheckableChecked',
          {'target': target, 'gesture': useGesture},
        );
        if (state == 'checked') return true;
        if (state == 'disabled' || state == 'failed' || state == null)
          return false;
        if (state == 'clicked') {
          for (var read = 0; read < 5; read++) {
            await Future.delayed(const Duration(milliseconds: 200));
            if (_inputBlocked) return false;
            final verified = await _automationChannel.invokeMethod<String>(
              'ensureCheckableChecked',
              {'target': target, 'readOnly': true},
            );
            if (verified == 'checked') return true;
          }
          useGesture = true;
        } else {
          await _waitForUiSettle(const Duration(milliseconds: 500));
          // First let ACTION_SHOW_ON_SCREEN reveal the exact control. Use
          // small bounded scrolls only when the WebView ignores that action.
          if (state == 'missing' || attempt.isOdd) {
            if (_inputBlocked) return false;
            await _automationChannel.invokeMethod('scrollNode', {
              'direction': state == 'above' ? 'up' : 'down',
              'percent': 0.18,
            });
            await _waitForUiSettle(const Duration(milliseconds: 700));
          }
        }
      }
    } catch (e) {
      debugPrint('[Yad2-A11y] Benefit selection failed for "$value": $e');
    }
    debugPrint('[Yad2-A11y] Benefit was not confirmed checked: "$value"');
    return false;
  }

  Future<_StepActionResult> _actionOpenHandDropdown() async {
    await _scrollDown(0.2, accessibilityOnly: true);
    final existing = await toolGetNodeTextAfter('יד*|יד', offset: 2);
    if (existing != null && existing.trim().isNotEmpty) {
      debugPrint('[Yad2-A11y] Hand is already filled: $existing');
      return const _StepActionResult.success(
        completeAs: AutomationPhase.phase11,
      );
    }
    return _openDropdownByLabel('יד*|יד|בחירת יד');
  }

  Future<_StepActionResult> _actionEnterKilometers() async {
    await _scrollDown(0.1, accessibilityOnly: true);
    final km = _nonEmpty(formData.kilometers, fallback: '0');
    final entered = await _retryUntil(
      () => _performWithPopupHandling(() async {
        if (!await toolTapNodeAfter('קילומטראז|קילומטר|נסועה')) return false;
        await Future.delayed(const Duration(milliseconds: 500));
        await toolEnterTextAtFocused(km);
        if (await _verifyInputAfter('קילומטראז|קילומטר|נסועה', km)) return true;
        if (_inputBlocked) return false;
        debugPrint(
          '[Yad2-A11y] Text readback failed; trying native WebView input.',
        );
        final nativeSuccess = await toolReplaceFocusedWebViewText(km);
        if (nativeSuccess) return true;
        return await _verifyInputAfter('קילומטראז|קילומטר|נסועה', km);
      }),
      timeout: const Duration(seconds: 3),
    );
    if (!entered) {
      return const _StepActionResult.failure('Kilometers field not found.');
    }
    await _dismissKeyboard();
    await _scrollDown(0.3, accessibilityOnly: true);

    return const _StepActionResult.success();
  }

  Future<_StepActionResult> _actionDisability() async {
    if (!formData.handicapped) return const _StepActionResult.success();
    await _retryUntil(
      () => toolFindElementAndTap('מותאם לנכים|נכים|נכה'),
      timeout: const Duration(seconds: 4),
    );

    return const _StepActionResult.success();
  }

  static bool isValidExtractedDescription(String? text) {
    if (text == null) return false;
    final trimmed = text.trim();
    if (trimmed.length < 10) return false;
    // Reject strings that are purely digits, slashes, dashes, colons or dots (e.g. "0412", "0/400", "04/12")
    if (RegExp(r'^[\d\s\/\-\:\.,]+$').hasMatch(trimmed)) return false;
    // Must contain letters (Hebrew or English)
    if (!RegExp(r'[\u0590-\u05FFa-zA-Z]').hasMatch(trimmed)) return false;
    // Reject location / address strings
    if (trimmed.startsWith('אזור ') ||
        trimmed.startsWith('איזור ') ||
        trimmed.contains('והסביבה')) {
      return false;
    }
    // Reject UI button labels and static prompt headers
    const uiExcludedLabels = {
      'עדכנתי',
      'בואו נמשיך',
      'עדכנתי, בואו נמשיך',
      'עדכנתי, בוא נמשיך',
      'עדכנתי בואו נמשיך',
      'לשלב הבא',
      'שלב הבא',
      'סגור',
      'ביטול',
      'סוג הרכב',
      'פרטי הרכב',
      'פרטים חשובים על הרכב',
      'מה חשוב לך שידעו על הרכב',
      'מה חשוב לך שידעו על הרכב?',
      'מה חשוב לך שידעו',
      'מה חשוב לך שידעו?',
      'זה המקום לתאר את הרכב',
      'זה המקום לתאר את היתרונות של הרכב',
      'זה המקום לתאר',
      'ספר/י קצת על הרכב שלך',
      'ספר לנו על הרכב',
      'טיפים למילוי תיאור מוצלח',
      'הוספת תיאור לרכב',
    };
    if (uiExcludedLabels.contains(trimmed) ||
        trimmed.startsWith('זה המקום לתאר')) {
      return false;
    }
    return true;
  }

  String _saveAndReturnDescription(String val) {
    final clean = val.trim();
    if (isValidExtractedDescription(clean)) {
      extractedDescription = clean;
      lastExtractedDescription = clean;
      debugPrint('====================================================');
      debugPrint('📝 [Yad2-Extracted-Description SAVED]: "$clean"');
      debugPrint('====================================================');
    }
    return clean;
  }

  static const _descriptionMarkers = [
    'פרטים חשובים על הרכב',
    'זה המקום לתאר',
    'מה חשוב לך שידעו',
    'תיאור הרכב',
  ];
  static const _nextStepLabel = 'לשלב הבא|שלב הבא';
  static const _priceLabel = 'מחיר|סכום מינימלי|סכום';

  static bool _isDescriptionMarker(_A11yTreeNode node) =>
      _descriptionMarkers.any(
        (label) =>
            node.text.trim().startsWith(label) ||
            node.desc.trim().startsWith(label),
      );

  // Only read the editable description beside its label. Vehicle summaries,
  // hints, city values and arbitrary long page text are not descriptions.
  @visibleForTesting
  static String descriptionFromAccessibilityTree(String tree) {
    final nodes = _parseA11yTree(tree);
    var inDescription = false;
    for (final node in nodes) {
      if (_isDescriptionMarker(node)) inDescription = true;
      if (!inDescription) continue;
      if (_splitAlternatives(_nextStepLabel).contains(node.text.trim()) ||
          _splitAlternatives(_nextStepLabel).contains(node.desc.trim())) {
        break;
      }
      final className = node.className.toLowerCase();
      if (!className.contains('edittext') && !className.contains('textarea')) {
        continue;
      }
      // The text is the field value; contentDescription may be its prompt.
      return isValidExtractedDescription(node.text) ? node.text.trim() : '';
    }
    return '';
  }

  Future<bool> _isDescriptionStep() async {
    final tree = await _readTreeString();
    return tree != null && _parseA11yTree(tree).any(_isDescriptionMarker);
  }

  Future<String> _extractVehicleDescriptionText() async {
    final tree = await _readTreeString();
    await _scrollDown(0.35, accessibilityOnly: true);
    final text = tree == null ? '' : descriptionFromAccessibilityTree(tree);
    return _saveAndReturnDescription(text);
  }

  Future<_StepActionResult> _actionSubmitAdditionalInfo() async {
    // A successful submit is retained across a pause/retry. Never let this
    // action use the price page's identically named next button.
    await _dismissKnownPopups();
    await Future.delayed(const Duration(milliseconds: 500));

    if (_completedPhaseActions.contains('description:submit')) {
      return const _StepActionResult.success();
    }
    // if (!await _isDescriptionStep() && await _isElementPresent(_priceLabel)) {
    //   return isValidExtractedDescription(extractedDescription)
    //       ? const _StepActionResult.success()
    //       : const _StepActionResult.failure(
    //         'Already on price step without a captured vehicle description.',
    //       );
    // }

    await Future<void>.delayed(const Duration(seconds: 5));

    await _extractVehicleDescriptionText();

    await _scrollDown(0.35, accessibilityOnly: true);

    await toolFindElementAndTap(_nextStepLabel);

    final submitted = await _runOnce(
      'description:submit',
      () => _retryUntil(() async {
        if (!await _isDescriptionStep()) {
          debugPrint('Description step label not found.');
          await _scrollDown(0.05, accessibilityOnly: true);
          return _isElementPresent(_priceLabel);
        }
        return toolFindElementAndTap(_nextStepLabel);
      }),
    );

    return submitted
        ? const _StepActionResult.success()
        : const _StepActionResult.failure('Description submit not found.');
  }

  Future<_StepActionResult> _actionSelectCity() async {
    await _scrollDown(0.1, accessibilityOnly: true);
    final city = _city;
    final typed = city.length > 1 ? city.substring(0, city.length - 1) : city;
    final label = 'ישוב*|יישוב|ישוב|עיר';

    final existingText = await toolGetNodeTextAfter(label, offset: 2);
    if (existingText != null && existingText.trim().isNotEmpty) {
      final lower = existingText.toLowerCase();
      if (!lower.contains('בחיר') &&
          !lower.contains('בחר') &&
          !lower.contains('הזן')) {
        debugPrint(
          '[Yad2-A11y] City input "$label" already filled with: "$existingText". Skipping city selection (phase15).',
        );
        return const _StepActionResult.success();
      }
    }

    final fieldTapped = await _retryUntil(
      () => toolTapNodeAfter(label),
      timeout: const Duration(seconds: 8),
    );
    if (!fieldTapped) {
      return const _StepActionResult.failure('City input label not found.');
    }

    var current = '';
    for (final rune in typed.runes) {
      current += String.fromCharCode(rune);
      if (!await toolEnterTextAtFocused(current)) {
        return const _StepActionResult.failure('City text entry failed.');
      }
      await Future.delayed(const Duration(milliseconds: 280));
    }

    final picked = await _retryUntil(
      () => toolFindElementAndTap(city),
      timeout: const Duration(seconds: 8),
    );
    if (!picked) {
      return _StepActionResult.failure('City option "$city" not found.');
    }
    // Original does not close a dropdown after the city pick — selecting the
    // autocomplete suggestion already dismisses the list.
    return const _StepActionResult.success();
  }

  Future<_StepActionResult> _actionEnterPrice() async {
    if (_completedPhaseActions.contains('price:submit')) {
      return const _StepActionResult.success();
    }
    final price = _nonEmpty(formData.price, fallback: '80000');
    final entered = await _runOnce(
      'price:enter',
      () => _retryUntil(() async {
        if (await _isDescriptionStep()) return false;
        if (!await toolTapNodeAfter(_priceLabel)) return false;
        await Future<void>.delayed(const Duration(milliseconds: 500));
        await toolEnterTextAtFocused(price);
        if (await _verifyInputAfter(_priceLabel, price)) return true;
        if (_inputBlocked) return false;
        debugPrint(
          '[Yad2-A11y] Text readback failed; trying native WebView input.',
        );
        final nativeSuccess = await toolReplaceFocusedWebViewText(price);
        if (nativeSuccess) return true;
        return await _verifyInputAfter(_priceLabel, price);
      }),
    );
    if (!entered) {
      return const _StepActionResult.failure(
        'Price field could not be filled.',
      );
    }

    // Retrying a missing next button must not send Back again after the
    // keyboard has already closed.
    await _runOnce('price:dismiss-keyboard', () async {
      await _dismissKeyboard();
      return true;
    });
    await _scrollDown(0.5, accessibilityOnly: true);
    final submitted = await _runOnce(
      'price:submit',
      () => _retryUntil(() => toolFindElementAndTap(_nextStepLabel)),
    );
    return submitted
        ? const _StepActionResult.success()
        : const _StepActionResult.failure(
          'Submit button after price not found.',
        );
  }

  Future<_StepActionResult> _actionUploadPhotosAndContinue() async {
    if (_completedPhaseActions.contains('photos:submit')) {
      return const _StepActionResult.success();
    }
    final uploaded = await _runOnce('upload-images', _injectImagesIfAny);
    if (!uploaded) {
      return const _StepActionResult.failure(
        'Native image selection failed. Check the upload control and image files.',
      );
    }
    await _scrollDown(0.75, accessibilityOnly: true);
    final submitted = await _runOnce(
      'photos:submit',
      () => _retryUntil(
        () => toolFindElementAndTap(_nextStepLabel),
        timeout: const Duration(seconds: 10),
      ),
    );
    return submitted
        ? const _StepActionResult.success()
        : const _StepActionResult.failure('Photos-page submit not found.');
  }

  Future<bool> selectDropdownSmart({
    required String label,
    required String value,
    int valueInstance = 1,
    int labelOffset = 1,
    bool closeAfterSelect = false,
  }) async {
    final opened = await _runOnce(
      'dropdown:$label',
      () => _retryUntil(
        () => _performWithPopupHandling(() async {
          if (await toolTapNodeAfter(label, offset: labelOffset)) return true;
          if (await tapSmart(label)) return true;
          return false;
        }),
        timeout: const Duration(seconds: 4),
      ),
    );
    if (!opened) return false;
    await _waitForUiSettle(const Duration(milliseconds: 500));

    final selected = await _runOnce(
      'selection:$label:$value:$valueInstance',
      () => _retryUntil(
        () => _performWithPopupHandling(
          () => tapSmart(value, targetInstance: valueInstance),
        ),
        timeout: const Duration(seconds: 4),
      ),
    );
    if (!selected) return false;

    await _waitForUiSettle(const Duration(milliseconds: 700));
    if (closeAfterSelect) {
      await _closeDropdownIfNeeded();
    }
    // A successful tap is success (matches original). No presence gate here.
    return true;
  }

  static const _termsLabel = 'יצירת איש קשר חדש';

  bool _termsSubmitted = false;
  bool _termsCheckboxAttempted = false;
  Future<_StepActionResult> _actionTermsAgreement() async {
    if (_termsSubmitted) return const _StepActionResult.success();
    const primaryMarker = 'יצירת איש קשר חדש';
    const fallbackMarker = 'פרטים ליצירת קשר';

    await Future.delayed(const Duration(milliseconds: 1800));
    final tappedCheckbox =
        !_termsCheckboxAttempted &&
        await _performWithPopupHandling(() async {
          final treeStr = await _readTreeString();
          if (treeStr != null && treeStr.isNotEmpty) {
            final hasPrimary = treeStr.contains(primaryMarker);
            final hasFallback = treeStr.contains(fallbackMarker);
            debugPrint(
              '[Yad2-A11y] terms check: hasPrimary($primaryMarker)=$hasPrimary, hasFallback($fallbackMarker)=$hasFallback',
            );

            if (hasPrimary || hasFallback) {
              final nodes = _parseA11yTree(treeStr);
              final allCheckboxes =
                  nodes
                      .cast<_A11yTreeNode?>()
                      .where(
                        (node) =>
                            node != null &&
                            (node.className == 'android.widget.CheckBox' ||
                                node.className.endsWith('.CheckBox') ||
                                node.className.contains('CheckBox')),
                      )
                      .toList();

              // await showToast('Terms Check: Found ${allCheckboxes.length} CheckBoxes');

              if (allCheckboxes.isNotEmpty) {
                debugPrint('[Yad2-A11y] Tapping CheckBoxes via native ACTION_CLICK.');
                final clickedCount = await _automationChannel.invokeMethod<int>('clickCheckboxes');
                debugPrint('[Yad2-A11y] Native ACTION_CLICK clicked $clickedCount checkboxes.');
                await Future.delayed(const Duration(milliseconds: 600));
                _termsCheckboxAttempted = true;
                return true;
              } else {
                debugPrint(
                  '[Yad2-A11y] NO CHECKBOX FOUND IN TREE. Dumping up to 30 nodes:',
                );
                for (var n in nodes.take(30)) {
                  debugPrint(
                    '[Yad2-A11y] Node class: ${n.className} | text: ${n.text} | desc: ${n.desc}',
                  );
                }
              }
            } else {
              final previewLength = treeStr.length < 500 ? treeStr.length : 500;
              debugPrint(
                '[Yad2-A11y] Marker texts NOT found in tree. Tree preview: ${treeStr.substring(0, previewLength)}',
              );
            }
          } else {
            debugPrint('[Yad2-A11y] terms check: treeStr is null or empty');
          }
          return false;
        });

    if (tappedCheckbox) {
      debugPrint('[Yad2-A11y] Tapped terms agreement checkbox.');
      await Future.delayed(const Duration(milliseconds: 700));
    } else {
      debugPrint(
        '[Yad2-A11y] ⚠️ Terms checkbox not explicitly found; proceeding to next button.',
      );
    }

    // 2. Click the button below it of "לשלב הבא"
    if (_inputBlocked) return const _StepActionResult.failure('Paused');
    final clickedNext = await tapSmart('לשלב הבא|שלב הבא|לשלב');
    _termsSubmitted = clickedNext;

    return clickedNext
        ? const _StepActionResult.success()
        : const _StepActionResult.failure(
          'Failed to click "לשלב הבא" after terms checkbox',
        );
  }

  Future<_StepActionResult> _actionDismissPromotionalScreen() async {
    const closeTargets = 'X|x|✕|✖|×|סגור|סגירה|close|Close|dismiss';

    // Hide app's overlay before this step so the "הפסק" button overlay doesn't cover the X close button
    onToggleOverlayVisibility?.call(false);
    await Future.delayed(const Duration(milliseconds: 400));

    try {
      final closed = await _performWithPopupHandling(() async {
        if (await tapSmart(closeTargets)) return true;
        return _dismissKnownPopups();
      });

      if (closed) {
        debugPrint(
          '[Yad2-A11y] Promotional screen closed via X / close button.',
        );
        await Future.delayed(const Duration(milliseconds: 1000));
      } else {
        debugPrint(
          '[Yad2-A11y] ⚠️ Promotional screen X close button not found or screen auto-closed.',
        );
      }
    } finally {
      // Restore app's overlay after attempting to close the promotional screen
      onToggleOverlayVisibility?.call(true);
    }

    return const _StepActionResult.success();
  }

  Future<bool> tapSmart(
    String targetText, {
    int targetInstance = 1,
    double deltaY = 0,
    bool allowJsFallback = true,
    bool allowOcrFallbackOverride = true,
    int a11yRetries = 2,
  }) async {
    if (_inputBlocked) return false;
    // 1. Accessibility Tree first (with retry)
    for (var i = 0; i < a11yRetries; i++) {
      if (await toolFindElementAndTap(
        targetText,
        targetInstance: targetInstance,
        deltaY: deltaY,
      )) {
        return true;
      }
      if (i < a11yRetries - 1) {
        await Future.delayed(const Duration(milliseconds: 300));
      }
    }

    // 3. OCR fallback only if explicitly enabled
    if (allowOcrFallbackOverride &&
        allowOcrFallback &&
        ocrService != null &&
        observeUI != null) {
      for (final alt in _splitAlternatives(targetText)) {
        if (await toolOcrFindAndTap(alt, targetInstance: targetInstance)) {
          debugPrint('[Yad2-A11y] OCR fallback tapped "$alt"');
          return true;
        }
      }
    }

    return false;
  }

  Future<bool> toolFindElementAndTap(
    String targetText, {
    int targetInstance = 1,
    double deltaY = 0,
    double threshold = 0.82,
    int maxReads = 4,
  }) async {
    if (_inputBlocked) return false;
    debugPrint(
      '[Yad2-A11y] Tool tapElement("$targetText", instance=$targetInstance)',
    );
    try {
      final bounds = await _getStableBounds('findAndGetBounds', {
        'target': targetText,
        'targetInstance': targetInstance,
        'threshold': threshold,
      }, maxReads: maxReads);

      if (bounds != null) {
        debugPrint('[aric] Found bounds: $bounds');
        await _tapBounds(bounds, deltaX: 0, deltaY: deltaY);
        return true;
      }
      return false;
    } catch (e) {
      debugPrint('[Yad2-A11y] tapElement failed: $e');
      return false;
    }
  }

  Future<bool> toolTapNodeBefore(
    String targetText, {
    int targetInstance = 1,
    double deltaY = 0,
  }) async {
    if (_inputBlocked) return false;
    try {
      final bounds = await _getStableBounds('findNodeBeforeAndGetBounds', {
        'target': targetText,
        'targetInstance': targetInstance,
      });
      if (bounds == null) return false;
      await _tapBounds(bounds, deltaX: 0, deltaY: deltaY);
      return true;
    } catch (e) {
      debugPrint('[Yad2-A11y] tapNodeBefore failed: $e');
      return false;
    }
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
      debugPrint('[Yad2-A11y] getNodeTextAfter failed: $e');
      return null;
    }
  }

  Future<bool> toolTapNodeAfter(
    String targetText, {
    int targetInstance = 1,
    double threshold = 0.82,
    double deltaX = 0,
    double deltaY = 0,
    int offset = 1,
  }) async {
    if (_inputBlocked) return false;
    try {
      final bounds = await _getStableBounds('findNodeAfterAndGetBounds', {
        'target': targetText,
        'targetInstance': targetInstance,
        'threshold': threshold,
        'offset': offset,
      });
      if (bounds == null) return false;
      await _tapBounds(bounds, deltaX: deltaX, deltaY: deltaY);
      return true;
    } catch (e) {
      debugPrint('[Yad2-A11y] tapNodeAfter failed: $e');
      return false;
    }
  }

  Future<bool> toolEnterTextBefore(String targetText, String value) async {
    if (_inputBlocked) return false;
    try {
      final bounds = await _getStableBounds('findInputBeforeAndGetBounds', {
        'target': targetText,
      });
      if (bounds == null) return false;
      await _tapBounds(bounds);
      await Future.delayed(const Duration(milliseconds: 500));
      if (_inputBlocked) return false;
      // Resolve the actual input again after keyboard layout/focus changes.
      // Some WebViews expose their wrapper as FOCUS_INPUT instead of the HTML input.
      await _automationChannel.invokeMethod<bool>('setTextBeforeTarget', {
        'target': targetText,
        'value': value,
      });
      if (await _verifyInputBefore(targetText, value)) return true;
      if (_inputBlocked) return false;
      debugPrint(
        '[Yad2-A11y] Text readback failed; trying native WebView input.',
      );
      await toolReplaceFocusedWebViewText(value);
      return await _verifyInputBefore(targetText, value);
    } catch (e) {
      debugPrint('[Yad2-A11y] enterTextBefore failed: $e');
      return false;
    }
  }

  Future<bool> _verifyInputBefore(String targetText, String expected) async {
    String normalize(String value) {
      // Yad2 can display a plate with hyphens and RTL direction marks.
      if (targetText == 'חיפוש' && RegExp(r'^\d+$').hasMatch(expected)) {
        return value.replaceAll(
          RegExp(r'[\s\-\u200e\u200f\u202a-\u202e\u2066-\u2069]'),
          '',
        );
      }
      return value;
    }

    for (var attempt = 0; attempt < 4; attempt++) {
      await Future.delayed(const Duration(milliseconds: 150));
      if (_inputBlocked) return false;
      final actual = await _automationChannel.invokeMethod<String>(
        'getInputTextBeforeTarget',
        {'target': targetText},
      );
      if (actual != null && normalize(actual) == normalize(expected)) {
        return true;
      }
    }
    return false;
  }

  Future<bool> _verifyInputAfter(String label, String expected) async {
    String normalize(String value) {
      return value.replaceAll(RegExp(r'[,\s\₪]'), '');
    }

    for (var attempt = 0; attempt < 4; attempt++) {
      await Future.delayed(const Duration(milliseconds: 150));
      if (_inputBlocked) return false;
      final actual = await toolGetNodeTextAfter(label);
      if (actual != null && normalize(actual) == normalize(expected)) {
        return true;
      }
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

  Future<bool> toolPasteTextBefore(String targetText, String value) async {
    if (_inputBlocked) return false;
    try {
      final bounds = await _getStableBounds('findInputBeforeAndGetBounds', {
        'target': targetText,
      });
      if (bounds == null) return false;
      await _tapBounds(bounds);
      await Future.delayed(const Duration(milliseconds: 500));
      return await toolPasteTextAtFocused(value);
    } catch (e) {
      debugPrint('[Yad2-A11y] pasteTextBefore failed: $e');
      return false;
    }
  }

  Future<bool> toolEnterTextNear(String label, String value) async {
    if (_inputBlocked) return false;
    final tapped = await toolTapNodeAfter(label) || await tapSmart(label);
    if (!tapped) return false;
    await Future.delayed(const Duration(milliseconds: 500));
    return await toolEnterTextAtFocused(value);
  }

  Future<void> toolTapScreen(double x, double y) async {
    if (_inputBlocked) throw StateError('Automation paused before tap');
    final tapped = await _automationChannel.invokeMethod<bool>('tapScreen', {
      'x': x,
      'y': y,
    });
    if (tapped != true) throw StateError('Tap was not completed');
  }

  Future<bool> toolPressBack() async {
    if (_inputBlocked) return false;
    try {
      final pressed = await _automationChannel.invokeMethod<bool>('pressBack');
      return pressed ?? false;
    } catch (e) {
      debugPrint('[Yad2-A11y] pressBack failed: $e');
      return false;
    }
  }

  Future<bool> toolEnterTextAtFocused(String text) async {
    if (_inputBlocked) return false;
    try {
      final success = await _automationChannel.invokeMethod<bool>(
        'enterTextAtFocused',
        {'value': text},
      );
      return success ?? false;
    } catch (e) {
      debugPrint('[Yad2-A11y] enterTextAtFocused failed: $e');
      return false;
    }
  }

  Future<bool> toolPasteTextAtFocused(String text) async {
    if (_inputBlocked) return false;
    try {
      await Clipboard.setData(ClipboardData(text: text));
      await Future.delayed(const Duration(milliseconds: 300));
      final success = await _automationChannel.invokeMethod<bool>('pasteText');
      return success ?? false;
    } catch (e) {
      debugPrint('[Yad2-A11y] pasteTextAtFocused failed: $e');
      return false;
    }
  }

  Future<bool> toolOcrFindAndTap(
    String targetText, {
    int targetInstance = 1,
    double deltaY = 0,
  }) async {
    if (_inputBlocked) return false;
    if (ocrService == null || observeUI == null) return false;
    final ctx = await _observeUIFresh();
    if (ctx == null) return false;
    final loc = await _findOcr(ctx, targetText, targetInstance);
    if (loc == null) return false;
    final cssX = loc.centerX / _devicePixelRatio;
    final cssY = (loc.centerY + deltaY) / _devicePixelRatio;
    onTapPreview?.call(cssX, cssY);
    onAutomationFallback?.call('OCR', targetText);
    await toolTapScreen(loc.centerX, loc.centerY + deltaY);
    return true;
  }

  Future<void> toolLogTree() async {
    if (!const bool.fromEnvironment('PIRSUMOTO_AUTOMATION_TRACE')) return;
    final tree = await _readTreeString();
    if (tree == null) return;
    for (final line in tree.split('\n')) {
      debugPrint(line);
    }
  }

  Future<Yad2ToolResult> executeRecoveryTool(Yad2ToolCall call) async {
    try {
      switch (call.tool) {
        case Yad2ToolName.tapElement:
          final ok = await tapSmart(
            call.args['text'] as String? ?? '',
            targetInstance: call.args['instance'] as int? ?? 1,
            deltaY: (call.args['deltaY'] as num?)?.toDouble() ?? 0,
          );
          return Yad2ToolResult(ok, ok ? 'tapped' : 'tap failed');
        case Yad2ToolName.tapNodeAfter:
          final ok = await toolTapNodeAfter(
            call.args['label'] as String? ?? call.args['text'] as String? ?? '',
            offset: call.args['offset'] as int? ?? 1,
            targetInstance: call.args['instance'] as int? ?? 1,
            deltaY: (call.args['deltaY'] as num?)?.toDouble() ?? 0,
            deltaX: (call.args['deltaX'] as num?)?.toDouble() ?? 0,
          );
          return Yad2ToolResult(ok, ok ? 'tapped node after' : 'tap failed');
        case Yad2ToolName.tapNodeBefore:
          final ok = await toolTapNodeBefore(
            call.args['label'] as String? ?? call.args['text'] as String? ?? '',
            targetInstance: call.args['instance'] as int? ?? 1,
            deltaY: (call.args['deltaY'] as num?)?.toDouble() ?? 0,
          );
          return Yad2ToolResult(ok, ok ? 'tapped node before' : 'tap failed');
        case Yad2ToolName.enterTextNear:
          final ok = await toolEnterTextNear(
            call.args['label'] as String? ?? '',
            call.args['value']?.toString() ?? '',
          );
          return Yad2ToolResult(ok, ok ? 'entered text' : 'enter failed');
        case Yad2ToolName.enterTextBefore:
          final ok = await toolEnterTextBefore(
            call.args['label'] as String? ?? '',
            call.args['value']?.toString() ?? '',
          );
          return Yad2ToolResult(
            ok,
            ok ? 'entered text before' : 'enter failed',
          );
        case Yad2ToolName.selectDropdown:
          final ok = await selectDropdownSmart(
            label: call.args['label'] as String? ?? '',
            value: call.args['value']?.toString() ?? '',
            valueInstance: call.args['instance'] as int? ?? 1,
            labelOffset: call.args['offset'] as int? ?? 1,
            closeAfterSelect: call.args['closeAfterSelect'] == true,
          );
          return Yad2ToolResult(ok, ok ? 'dropdown selected' : 'select failed');
        case Yad2ToolName.dismissPopup:
          final ok = await _dismissKnownPopups();
          return Yad2ToolResult(ok, ok ? 'popup dismissed' : 'no popup');
        case Yad2ToolName.scrollDown:
          await _scrollDown(
            (call.args['percent'] as num?)?.toDouble() ?? 0.5,
            accessibilityOnly: true,
          );
          return const Yad2ToolResult(true, 'scrolled');
        case Yad2ToolName.pressBack:
          final ok = await toolPressBack();
          return Yad2ToolResult(ok, ok ? 'back pressed' : 'back failed');
        case Yad2ToolName.validatePhase:
          final spec =
              _currentPhase == null ? null : _buildStepSpec(_currentPhase!);
          final ok = spec == null ? false : await _validateStep(spec);
          return Yad2ToolResult(ok, ok ? 'validated' : 'validation failed');
        case Yad2ToolName.logTree:
          await toolLogTree();
          return const Yad2ToolResult(true, 'tree logged');
      }
    } catch (e) {
      return Yad2ToolResult(false, e.toString());
    }
  }

  Future<bool> _validateStep(_AutomationStepSpec spec) async {
    final rule = spec.validation;
    if (rule == null) return true;

    if (rule.custom != null && !await rule.custom!()) return false;

    if (rule.mustContain != null &&
        !await _waitForPresent(rule.mustContain!, timeout: rule.timeout)) {
      debugPrint('[Yad2-A11y] Validation miss: ${rule.mustContain}');
      return false;
    }

    if (rule.nextMarker != null &&
        !await _waitForPresent(rule.nextMarker!, timeout: rule.timeout)) {
      debugPrint('[Yad2-A11y] Next marker not found: ${rule.nextMarker}');
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
          '[Yad2-A11y] Selected value not visible: ${rule.selectedValue}',
        );
        return false;
      }
    }

    if (rule.mustNotContain != null &&
        await _isTextVisibleAnySource(rule.mustNotContain!)) {
      debugPrint(
        '[Yad2-A11y] Forbidden text still visible: ${rule.mustNotContain}',
      );
      return false;
    }

    return true;
  }

  Future<void> _failOrRecover(_AutomationStepSpec spec, String reason) async {
    if (_stopped || _isPaused) return;

    if (_phaseRetryCount < _maxRetries) {
      _phaseRetryCount++;
      final backoffMs = 900 * _phaseRetryCount;
      debugPrint(
        '[Yad2-A11y] Retry $_phaseRetryCount/$_maxRetries in ${backoffMs}ms: $reason',
      );
      _scheduler.schedule(Duration(milliseconds: backoffMs), () {
        if (!_isPaused) unawaited(_executePhase(spec.phase));
      });
      return;
    }

    var recovered = false;
    if (!_recoveryAttempted) {
      _recoveryAttempted = true;
      recovered = await _tryRecovery(spec, reason);
    }
    if (_stopped || _isPaused) return;
    if (recovered) {
      _phaseRetryCount = 0;
      _scheduler.schedule(
        Duration.zero,
        () => unawaited(_executePhase(spec.phase)),
      );
      return;
    }

    await _handleError(
      spec.phase,
      'Stuck at ${spec.phase.description}: $reason',
    );
  }

  Future<bool> _tryRecovery(_AutomationStepSpec spec, String reason) async {
    debugPrint('[Yad2-A11y] Recovery gate for ${spec.phase.name}: $reason');

    // These steps own their next-button ordering. Generic recovery could
    // bypass description capture, price entry, or the required terms checkbox.
    if (spec.phase == AutomationPhase.phase14 ||
        spec.phase == AutomationPhase.phase15 ||
        spec.phase == AutomationPhase.phase16 ||
        spec.phase == AutomationPhase.phase17 ||
        spec.phase == AutomationPhase.phase18) {
      return false;
    }

    if (await _dismissKnownPopups()) return true;

    if (await _checkIsLoginScreen()) {
      // [WHATSAPP-DISABLED] _notifyLoginRequired disabled.
      // await _notifyLoginRequired();
      _startLoginGate();
      return true;
    }

    if (!enableLlmRecovery || recoveryPlanner == null) return false;

    final snapshot = await _snapshotForRecovery();
    final request = Yad2RecoveryRequest(
      phase: spec.phase,
      goal: spec.goal,
      failure: reason,
      formData: formData,
      observation: snapshot.toJson(),
      availableTools: Yad2ToolName.values.map((tool) => tool.name).toList(),
    );

    final plan = await recoveryPlanner!(request);
    if (plan == null) return false;

    debugPrint('[Yad2-A11y] Recovery plan: ${jsonEncode(plan.toJson())}');

    if (plan.classification == Yad2RecoveryClassification.manualRequired ||
        plan.classification == Yad2RecoveryClassification.captchaOrBlock) {
      return false;
    }

    if (plan.confidence < 0.45) {
      debugPrint('[Yad2-A11y] Recovery confidence too low: ${plan.confidence}');
      return false;
    }

    for (final call in plan.toolCalls.take(5)) {
      final result = await executeRecoveryTool(call);
      debugPrint(
        '[Yad2-A11y] Recovery tool ${call.tool.name}: ${result.success} ${result.reason}',
      );
      if (!result.success &&
          call.tool != Yad2ToolName.dismissPopup &&
          call.tool != Yad2ToolName.validatePhase) {
        return false;
      }
      await _waitForUiSettle(const Duration(milliseconds: 600));
    }

    if (!plan.resumeGreenPath) return false;
    return _validateStep(spec);
  }

  Future<_ScreenSnapshot> _snapshotForRecovery() async {
    final ui = await _observeUIFresh();
    final nativeTree = await _readTreeString();
    String? bodyText;
    String? url;
    try {
      bodyText =
          (await controller.runJavaScriptReturningResult(
            'document.body ? document.body.innerText : ""',
          )).toString();
      url =
          (await controller.runJavaScriptReturningResult(
            'location.href',
          )).toString();
    } catch (_) {}
    return _ScreenSnapshot(
      ui: ui,
      nativeTree: nativeTree,
      bodyText: bodyText,
      url: url,
    );
  }

  Future<bool> _waitForPresent(
    String text, {
    Duration timeout = const Duration(seconds: 4),
  }) {
    return _retryUntil(
      () => _isTextVisibleAnySource(text),
      timeout: timeout,
      pollInterval: const Duration(milliseconds: 350),
    );
  }

  Future<bool> _isTextVisibleAnySource(String text) async {
    if (text.trim().isEmpty) return true;
    if (await _isElementPresent(text)) return true;

    final ctx = await _observeUIFresh();
    if (ctx != null && ctx.findByLabel(text, visibleOnly: true) != null) {
      return true;
    }

    if (allowOcrFallback && ocrService != null && ctx != null) {
      for (final alt in _splitAlternatives(text)) {
        if (await _findOcr(ctx, alt, 1) != null) return true;
      }
    }
    return false;
  }

  Future<UIContext?> _observeUIFresh() async {
    if (observeUI == null) return null;
    final ctx = await observeUI!();
    if (ctx != null && identityHashCode(ctx.screenshot) != _ocrFrameId) {
      _ocrFrameId = identityHashCode(ctx.screenshot);
      _ocrCache.clear();
    }
    return ctx;
  }

  Future<TextLocation?> _findOcr(
    UIContext ctx,
    String text,
    int targetInstance,
  ) async {
    if (ocrService == null) return null;
    final key = '${identityHashCode(ctx.screenshot)}|$text|$targetInstance';
    if (_ocrCache.containsKey(key)) return _ocrCache[key];
    final isMultiWord = text.contains(' ') && !text.contains('|');
    final loc =
        isMultiWord
            ? await ocrService!.findMultiWordPhrase(
              ctx.screenshot,
              text,
              targetInstance: targetInstance,
            )
            : await ocrService!.findTextLocation(
              ctx.screenshot,
              text,
              targetInstance: targetInstance,
            );
    _ocrCache[key] = loc;
    return loc;
  }

  Future<bool> _isLicenseInputPresent() async {
    // 1. Check if placeholder text is in tree
    if (await _isElementPresent(
      '00-000-00|000-00-000|0000000|00000000|מספר רכב',
    )) {
      return true;
    }
    // 2. Check if an editable input exists directly before the "חיפוש" button
    try {
      final bounds = await _automationChannel.invokeMapMethod<String, dynamic>(
        'findInputBeforeAndGetBounds',
        {'target': 'חיפוש'},
      );
      return bounds != null;
    } catch (_) {
      return false;
    }
  }

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

  Future<bool> _performWithPopupHandling(Future<bool> Function() action) async {
    var result = await action();
    if (result) return true;
    if (await _dismissKnownPopups()) {
      await _waitForUiSettle(const Duration(milliseconds: 600));
      result = await action();
    }
    return result;
  }

  Future<bool> _dismissKnownPopups() async {
    const popupPattern =
        'הבנתי|התחלה מחדש|להתחיל מחדש|התחל מחדש|עדכנתי, בואו נמשיך|'
        'עדכנתי, בוא נמשיך|עדכנתי בואו נמשיך|בואו נמשיך|אולי אחר כך|'
        'סגור|סגירה|ביטול|סגירת חלון';

    // Single fast 1-read check to avoid waiting if no popup is displayed
    if (await toolFindElementAndTap(popupPattern, maxReads: 1)) {
      debugPrint('[Yad2-A11y] Dismissed popup via Accessibility tree');
      await Future.delayed(const Duration(milliseconds: 600));
      return true;
    }
    return false;
  }

  Future<void> _closeDropdownIfNeeded() async {
    await Future.delayed(const Duration(milliseconds: 500));
    final closed = await _retryUntil(
      () => tapSmart('סגירת חלון'),
      timeout: const Duration(seconds: 3),
    );
    if (closed) {
      debugPrint('[Yad2-A11y] Manually closed dropdown using "סגירת חלון"');
      await _waitForUiSettle(const Duration(milliseconds: 500));
    } else {
      debugPrint(
        '[Yad2-A11y] "סגירת חלון" not found; assuming dropdown is already closed',
      );
    }
  }

  Future<bool> _retryUntil(
    Future<bool> Function() action, {
    Duration timeout = const Duration(seconds: 8),
    Duration pollInterval = const Duration(milliseconds: 400),
  }) async {
    final deadline = DateTime.now().add(timeout);
    do {
      if (_inputBlocked) return false;
      if (await action()) return true;
      await Future.delayed(pollInterval);
    } while (DateTime.now().isBefore(deadline));
    return false;
  }

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
      debugPrint('[Yad2-A11y] Scroll failed: $e');
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
    await Future.delayed(const Duration(milliseconds: 450));
    final deadline = DateTime.now().add(timeout);
    double? last;
    while (DateTime.now().isBefore(deadline)) {
      double? current;
      try {
        final res = await controller.runJavaScriptReturningResult(
          '(window.scrollY || document.documentElement.scrollTop || 0)',
        );
        current = double.tryParse(res.toString());
      } catch (_) {}
      if (current != null && last != null && (current - last).abs() < 1) {
        break;
      }
      last = current;
      await Future.delayed(const Duration(milliseconds: 220));
    }
    await Future.delayed(const Duration(milliseconds: 250));
  }

  /// Lightweight settle between steps. Deliberately does NOT poll the WebView
  /// via JS on every action: during a page transition that JS call can throw or
  /// return stale data and adds a round-trip per step. Scroll-driven settling
  /// is handled explicitly inside [_scrollDown]/[_waitForScrollSettle].
  Future<void> _waitForUiSettle(Duration delay) async {
    if (delay > Duration.zero) await Future.delayed(delay);
  }

  Future<Map<String, dynamic>?> _getStableBounds(
    String method,
    Map<String, dynamic> args, {
    int maxReads = 4,
  }) async {
    Map<String, dynamic>? previous;
    for (var i = 0; i < maxReads; i++) {
      final bounds = await _automationChannel.invokeMapMethod<String, dynamic>(
        method,
        args,
      );
      if (bounds == null) {
        if (i < maxReads - 1) {
          await Future.delayed(const Duration(milliseconds: 250));
          continue;
        }
        return null;
      }
      if (previous != null) {
        final dx = ((bounds['x'] as num) - (previous['x'] as num)).abs();
        final dy = ((bounds['y'] as num) - (previous['y'] as num)).abs();
        if (dx < 2 && dy < 2) return bounds;
      }
      previous = bounds;
      await Future.delayed(const Duration(milliseconds: 220));
    }
    return previous;
  }

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

  Future<String?> _readTreeString() async {
    try {
      return await _automationChannel.invokeMethod<String>('logTree');
    } catch (_) {
      return null;
    }
  }

  Future<void> _dismissKeyboard() async {
    // Attempt to clear focus natively using AccessibilityService
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

  Future<bool> _checkIsLoginScreen() async {
    const keywords = [
      'התחברות',
      'כניסה לאזור',
      'כניסה לאזור האישי',
      'כניסה באמצעות',
      'דוא"ל',
      'סיסמה',
      'הרשמה',
      'כניסה',
      'התחבר',
      'אימייל/מספר טלפון',
      'שם משתמש',
      'Password',
      'מספר נייד או אימייל',
    ];
    for (final keyword in keywords) {
      if (await _isElementPresent(keyword)) return true;
    }
    return false;
  }

  // [WHATSAPP-DISABLED] _lastDeadlockNotified field disabled.
  // DateTime? _lastDeadlockNotified;

  // Future<void> _notifyDeadlockInterventionRequired(String stepName, String details) async {
  //   final senderKey = whatsAppSenderKey?.trim();
  //   if (senderKey == null || senderKey.isEmpty) return;
  //
  //   final now = DateTime.now();
  //   if (_lastDeadlockNotified != null &&
  //       now.difference(_lastDeadlockNotified!) < const Duration(seconds: 15)) {
  //     return; // Debounce notifications
  //   }
  //   _lastDeadlockNotified = now;
  //
  //   try {
  //     final bool isP2p = senderKey.startsWith('p2p_');
  //     final String remoteNotice = isP2p
  //         ? 'נא ללחוץ על כפתור השליטה מרחוק (Remote Control) במסך זה כדי להשתלט על המכשיר ולסייע בהמשך הפרסום.'
  //         : 'נא להתחבר באמצעות פיצ׳ר השליטה מרחוק (Remote Control) באפליקציית השלט של פירסומוטו כדי לסייע ולהמשיך את הפרסום.';
  //
  //     final message =
  //         '⚠️ האוטומציה נתקעה ונדרשת התערבותך!\n'
  //         'שלב: $stepName\n'
  //         'פירוט: $details\n\n'
  //         '$remoteNotice';
  //
  //     await WhatsAppTextValidationService.dispatchReplyToSender(
  //       senderKey: senderKey,
  //       message: message,
  //     );
  //     debugPrint('[Yad2-A11y] Dispatched deadlock notification to $senderKey');
  //   } catch (e) {
  //     debugPrint('[Yad2-A11y] Failed to dispatch deadlock notification: $e');
  //   }
  // }

  // Future<void> _notifyLoginRequired() async {
  //   final senderKey = whatsAppSenderKey?.trim();
  //   if (senderKey == null || senderKey.isEmpty) {
  //     return;
  //   }
  //   try {
  //     final bool isP2p = senderKey.startsWith('p2p_');
  //     final String remoteNotice = isP2p
  //         ? 'נא ללחוץ על כפתור השליטה מרחוק (Remote Control) במסך זה כדי להזין את פרטי ההתחברות לחשבון יד2.'
  //         : 'נא להתחבר באמצעות פיצ׳ר השליטה מרחוק (Remote Control) באפליקציית השלט של פירסומוטו כדי להזין את פרטי ההתחברות לחשבון יד2.';
  //
  //     final message =
  //         '⚠️ נדרשת התחברות לחשבון יד2!\n'
  //         'האוטומציה הגיעה למסך כניסה וממתינה להתחברות שלך.\n\n'
  //         '$remoteNotice';
  //
  //     final success = await WhatsAppTextValidationService.dispatchReplyToSender(
  //       senderKey: senderKey,
  //       message: message,
  //     );
  //     debugPrint('[Yad2-A11y] Sent login prompt: $success');
  //   } catch (e) {
  //     debugPrint('[Yad2-A11y] Failed to send login prompt: $e');
  //   }
  // }

  void _startLoginGate() {
    if (_stopped || _isPaused) return;
    // Login is manual intervention in the existing run, not a new publication.
    unawaited(
      _handleError(
        _currentPhase ?? AutomationPhase.phase1,
        'נדרשת התחברות לחשבון יד2. לאחר ההתחברות חזור למסך הפרסום ולחץ המשך.',
      ),
    );
    onLoginRequired?.call();
  }

  Future<void> _fetchSettingsIfNeeded() async {
    if (_settingsFetched) return;
    _warranties = formData.warranties;
    _warrantyDurations = formData.warrantyDurations;
    _treatments = formData.treatments;
    _services = formData.services;

    if (_warranties.isEmpty && _treatments.isEmpty && _services.isEmpty) {
      try {
        final user = FirebaseAuth.instance.currentUser;
        if (user == null) {
          throw StateError('Cannot load benefits without a signed-in account.');
        }
        if (user != null) {
          final doc = await FirebaseFirestore.instance
              .collection('users')
              .doc(user.uid)
              .get(const GetOptions(source: Source.server))
              .timeout(const Duration(seconds: 10));
          final settings = doc.data()?['settings'] as Map<String, dynamic>?;
          if (settings != null) {
            _warranties = List<String>.from(settings['warranties'] ?? const []);
            _warrantyDurations = Map<String, String>.from(
              settings['warrantyDurations'] ?? const {},
            );
            _treatments = List<String>.from(settings['treatments'] ?? const []);
            _services = List<String>.from(settings['services'] ?? const []);
          }
        }
      } catch (e) {
        debugPrint('[Yad2-A11y] Settings fetch failed: $e');
        // A transient network/auth failure is not an empty configuration.
        // Leave this uncached so the phase retry can load the selections.
        rethrow;
      }
    }
    debugPrint(
      '[Yad2-A11y] Loaded benefits: ${_warranties.length} warranties, '
      '${_treatments.length} treatments, ${_services.length} services.',
    );
    _settingsFetched = true;
  }

  String _getWarrantyDropdownLabel(String warranty) {
    if (warranty.contains('שלדה')) return 'אחריות שלדה, מנוע וגיר';
    if (warranty.contains('יבואן')) return 'אחריות מהיבואן';
    if (warranty.contains('סוכנות')) return 'אחריות מהסוכנות';
    if (warranty.contains('סוללה')) {
      return 'אחריות על הסוללה|אחריות על סוללה|אחירות על סוללה';
    }
    return warranty;
  }

  NativeImageUploadRequest? _imageUploadRequest;

  void _cancelImageUpload() {
    _imageUploadRequest?.cancel();
    _imageUploadRequest = null;
  }

  /// Called by AndroidWebViewController's native onShowFileChooser bridge.
  /// Empty responses cancel unsolicited, expired, or paused chooser requests.
  List<String> handleNativeImageChooser({required bool allowMultiple}) {
    if (_inputBlocked) return const [];
    return _imageUploadRequest?.select(allowMultiple: allowMultiple) ??
        const [];
  }

  Future<bool> _injectImagesIfAny() async {
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

    // The native WebView reads local files itself; no base64 or DOM injection.
    for (final path in images) {
      try {
        if (path.isEmpty ||
            !await File(path).exists() ||
            await File(path).length() == 0) {
          return false;
        }
      } catch (e) {
        debugPrint('[Yad2-A11y] Image unavailable: $e');
        return false;
      }
    }
    if (_inputBlocked) return false;
    final request = NativeImageUploadRequest(images);
    _imageUploadRequest = request;
    try {
      // Arm before tapping: onShowFileChooser may fire before the tap returns.
      // Match the actual upload control, not a similar photos-section heading.
      const uploadLabels = 'לחיצה להעלאת תמונה|העלאת תמונה';
      var tapped = await toolFindElementAndTap(
        uploadLabels,
        threshold: 1.0,
        maxReads: 2,
      );
      if (!tapped && !_inputBlocked) {
        await _scrollDown(0.5, accessibilityOnly: true);
        tapped = await toolFindElementAndTap(
          uploadLabels,
          threshold: 1.0,
          maxReads: 2,
        );
      }
      if (!tapped || _inputBlocked) return false;
      final selected = await request.wait();
      if (!selected || _inputBlocked) return false;
      debugPrint('[Yad2-A11y] Images returned through Android file chooser');
      // Allow the site's normal upload handler to process the native selection.
      await Future<void>.delayed(const Duration(seconds: 3));
      return !_inputBlocked;
    } catch (e) {
      debugPrint('[Yad2-A11y] Native image upload failed: $e');
      return false;
    } finally {
      request.cancel();
      if (identical(_imageUploadRequest, request)) _imageUploadRequest = null;
    }
  }

  // [WHATSAPP-DISABLED] _notifyAutomationComplete sent WA message on completion. Disabled.
  /*
  Future<void> _notifyAutomationComplete() async {
    if (_hasNotifiedCompletion) return;
    _hasNotifiedCompletion = true;

    final senderKey = whatsAppSenderKey?.trim();
    if (senderKey == null || senderKey.isEmpty) {
      return;
    }
    try {
      final success = await WhatsAppTextValidationService.dispatchReplyToSender(
        senderKey: senderKey,
        message: 'תהליך העלאת מודעה ליד2 הסתיים בהצלחה ✅',
      );
      debugPrint('[Yad2-A11y] Sent completion message: $success');
    } catch (e) {
      debugPrint('[Yad2-A11y] Failed to send completion message: $e');
    }
  }
  */

  // [WHATSAPP-DISABLED] _updateWhatsAppPublishingFlag disabled — WA SharedPrefs update removed.
  // Future<void> _updateWhatsAppPublishingFlag(bool running) async { ... }

  void _handlePhaseComplete(AutomationPhase phase) {
    debugPrint('[Yad2-A11y] Phase complete: ${phase.description}');
    if (_stopped) return;
    onPhaseComplete?.call(phase);

    final next = _nextPhaseAfter(phase);
    if (next == null) {
      stop();
      // [WHATSAPP-DISABLED] _notifyAutomationComplete disabled.
      onAutomationComplete?.call(true);
      return;
    }

    if (_currentPhase != next) _savePhase(next);
    if (_stopped || _isPaused) return;
    _scheduler.schedule(_delayAfter(phase), () {
      if (!_isPaused) _processPhase(next);
    });
  }

  AutomationPhase? _nextPhaseAfter(AutomationPhase phase) {
    switch (phase) {
      case AutomationPhase.phase1:
        return AutomationPhase.phase2;
      case AutomationPhase.phase2:
        return AutomationPhase.phase3;
      case AutomationPhase.phase3:
        return AutomationPhase.phase4;
      case AutomationPhase.phase4:
        return AutomationPhase.phase5;
      case AutomationPhase.phase5:
        return AutomationPhase.phase5a;
      case AutomationPhase.phase5a:
        return AutomationPhase.phase5b;
      case AutomationPhase.phase5b:
        return AutomationPhase.phase5c;
      case AutomationPhase.phase5c:
        return (!formData.govIl && !formData.noTest)
            ? AutomationPhase.phase5c1
            : AutomationPhase.phase5d;
      case AutomationPhase.phase5c1:
        return AutomationPhase.phase5c2;
      case AutomationPhase.phase5c2:
        return AutomationPhase.phase5c3;
      case AutomationPhase.phase5c3:
        return AutomationPhase.phase5d;
      case AutomationPhase.phase5d:
        return AutomationPhase.phase5e;
      case AutomationPhase.phase5e:
        return AutomationPhase.phase5f;
      case AutomationPhase.phase5f:
        return AutomationPhase.phase6;
      case AutomationPhase.phase6:
        return AutomationPhase.phase7;
      case AutomationPhase.phase7:
        return AutomationPhase.phase8;
      case AutomationPhase.phase8:
        return AutomationPhase.phase9;
      case AutomationPhase.phase9:
        return _isFirstHand ? AutomationPhase.phase12 : AutomationPhase.phase10;
      case AutomationPhase.phase10:
        return AutomationPhase.phase11;
      case AutomationPhase.phase11:
        return AutomationPhase.phase12;
      case AutomationPhase.phase12:
        return AutomationPhase.phase13;
      case AutomationPhase.phase13:
        return AutomationPhase.phase14;
      case AutomationPhase.phase14:
        return AutomationPhase.phase15;
      case AutomationPhase.phase15:
        return AutomationPhase.phase16;
      case AutomationPhase.phase16:
        return AutomationPhase.phase17;
      case AutomationPhase.phase17:
        return AutomationPhase.phase18;
      case AutomationPhase.phase18:
        return AutomationPhase.phase19;
      case AutomationPhase.phase19:
        return AutomationPhase.complete;
      case AutomationPhase.complete:
        return null;
    }
  }

  /// Inter-phase delay before processing the next phase. Mirrors the original
  /// service's per-phase schedule exactly so pacing matches the proven flow.
  Duration _delayAfter(AutomationPhase phase) {
    switch (phase) {
      case AutomationPhase.phase1:
      case AutomationPhase.phase2:
      case AutomationPhase.phase5b:
      case AutomationPhase.phase7:
        return const Duration(milliseconds: 500);
      case AutomationPhase.phase5:
      case AutomationPhase.phase5a:
      case AutomationPhase.phase5c:
      case AutomationPhase.phase5d:
      case AutomationPhase.phase5e:
      case AutomationPhase.phase5f:
      case AutomationPhase.phase6:
      case AutomationPhase.phase8:
      case AutomationPhase.phase17:
      case AutomationPhase.phase18:
      case AutomationPhase.phase19:
        return const Duration(milliseconds: 700);
      default:
        // phase3, phase4, phase9–phase16 → 1000ms (original default).
        return const Duration(milliseconds: 700);
    }
  }

  Future<void> _handleError(AutomationPhase phase, String error) async {
    if (_stopped) return;
    debugPrint('[Yad2-A11y] Phase error: ${phase.description} - $error');
    pauseAutomation();
    _savePhase(phase);
    _phaseRetryCount = 0;
    // [WHATSAPP-DISABLED] _notifyDeadlockInterventionRequired disabled.
    // unawaited(_notifyDeadlockInterventionRequired(phase.description, error));
    onPhaseError?.call(
      phase,
      'האוטומציה מושהית בשלב ${phase.name}: ${phase.description}.\n'
      '$error\nניתן לקחת שליטה ידנית או מרחוק, לתקן את המסך וללחוץ המשך מאותו שלב.',
    );
    // Surface Resume immediately, even if the audio plugin is unavailable.
    unawaited(_beepUser().catchError((Object _) {}));
  }

  Future<void> _beepUser() async {
    var assetPlayed = false;
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
      for (var i = 0; i < 3; i++) {
        await SystemSound.play(SystemSoundType.click);
        await Future.delayed(const Duration(milliseconds: 100));
      }
    }
    try {
      await HapticFeedback.vibrate();
    } catch (_) {}
  }

  bool get _isFirstHand {
    final hand = formData.hand.trim();
    return const {'ראשונה', 'יד ראשונה', '1', 'יד 1', 'ראשון'}.contains(hand);
  }

  String get _city => _nonEmpty(formData.city, fallback: 'חיפה');

  double get _devicePixelRatio =>
      WidgetsBinding.instance.platformDispatcher.views.first.devicePixelRatio;
}

List<String> _splitAlternatives(String value) =>
    value
        .split('|')
        .map((item) => item.trim())
        .where((item) => item.isNotEmpty)
        .toList();

String _variants(String preferred, String raw) {
  final values = <String>{};
  if (preferred.trim().isNotEmpty) values.add(preferred.trim());
  if (raw.trim().isNotEmpty) {
    values.add(raw.trim());
    values.add(raw.trim().replaceFirst(RegExp(r'^0+'), ''));
  }
  return values.where((value) => value.isNotEmpty).join('|');
}

String _handSearchValue(String value) {
  final normalized = value.trim();
  final full = normalized.startsWith('יד') ? normalized : 'יד $normalized';
  final values = <String>{full};
  final parts = full.split(RegExp(r'\s+'));
  if (parts.isNotEmpty) values.add(parts.last);
  values.add(full.replaceAll('שנייה', 'שניה'));
  values.add(full.replaceAll('שניה', 'שנייה'));
  return values.where((item) => item.trim().isNotEmpty).join('|');
}

String _valueWithLastWordVariant(String value) {
  final trimmed = value.trim();
  if (trimmed.isEmpty) return trimmed;
  final parts = trimmed.split(RegExp(r'\s+'));
  if (parts.length <= 1) return trimmed;
  return '$trimmed|${parts.last}';
}

String _nonEmpty(String value, {required String fallback}) {
  final trimmed = value.trim();
  return trimmed.isEmpty ? fallback : trimmed;
}

bool _matchesAny(String? actual, String expected) {
  if (actual == null || actual.trim().isEmpty) return false;
  final actualNorm = actual.replaceAll(RegExp(r'\s+'), '').toLowerCase();
  return _splitAlternatives(expected).any((option) {
    final expectedNorm = option.replaceAll(RegExp(r'\s+'), '').toLowerCase();
    return expectedNorm.isNotEmpty &&
        (actualNorm == expectedNorm || actualNorm.contains(expectedNorm));
  });
}

String _clip(String value, int maxChars) =>
    value.length <= maxChars ? value : value.substring(0, maxChars);

class _A11yTreeNode {
  final String className;
  final String text;
  final String desc;
  final bool isClickable;
  final double? centerX;
  final double? centerY;

  const _A11yTreeNode({
    required this.className,
    required this.text,
    required this.desc,
    required this.isClickable,
    this.centerX,
    this.centerY,
  });
}

List<_A11yTreeNode> _parseA11yTree(String treeStr) {
  final nodes = <_A11yTreeNode>[];
  final regex = RegExp(
    r'\[([^\]]+)\]\s+text="([\s\S]*?)"\s+desc="([\s\S]*?)"\s+clickable=(true|false)(?:\s+bounds=Rect\((-?\d+(?:\.\d+)?),\s*(-?\d+(?:\.\d+)?)\s*-\s*(-?\d+(?:\.\d+)?),\s*(-?\d+(?:\.\d+)?)\))?',
  );
  for (final match in regex.allMatches(treeStr)) {
    double? cx;
    double? cy;
    final leftStr = match.group(5);
    final topStr = match.group(6);
    final rightStr = match.group(7);
    final bottomStr = match.group(8);
    if (leftStr != null &&
        topStr != null &&
        rightStr != null &&
        bottomStr != null) {
      final left = double.tryParse(leftStr);
      final top = double.tryParse(topStr);
      final right = double.tryParse(rightStr);
      final bottom = double.tryParse(bottomStr);
      if (left != null && top != null && right != null && bottom != null) {
        cx = (left + right) / 2.0;
        cy = (top + bottom) / 2.0;
      }
    }

    nodes.add(
      _A11yTreeNode(
        className: match.group(1) ?? '',
        text: match.group(2) ?? '',
        desc: match.group(3) ?? '',
        isClickable: match.group(4) == 'true',
        centerX: cx,
        centerY: cy,
      ),
    );
  }
  return nodes;
}
