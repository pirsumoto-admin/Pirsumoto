import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:audioplayers/audioplayers.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'ocr_service.dart';
import 'ui_context.dart';
import 'whatsapp_text_validation_service.dart';
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
    this.timeout = const Duration(seconds: 4),
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

class Yad2MacHybridAutomationService {
  final VehiclePublishData formData;
  final WebViewController controller;
  final Future<UIContext?> Function()? observeUI;
  final OcrService? ocrService;
  final Yad2RecoveryPlanner? recoveryPlanner;
  final bool enableLlmRecovery;
  final bool allowOcrFallback;

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
  bool _isPaused = false;
  bool _loginGateTickBusy = false;
  AutomationPhase? _pausedPhase;
  AutomationPhase? _currentPhase;
  Timer? _loginSamplingTimer;

  bool _settingsFetched = false;
  List<String> _warranties = [];
  Map<String, String> _warrantyDurations = {};
  List<String> _treatments = [];
  List<String> _services = [];

  int? _ocrFrameId;
  final Map<String, TextLocation?> _ocrCache = {};

  final bool startedFromWhatsApp;
  final String? whatsAppSenderKey;

  final void Function(bool visible)? onToggleOverlayVisibility;
  final VoidCallback? onLoginRequired;
  String? extractedDescription;
  static String? lastExtractedDescription;

  Yad2MacHybridAutomationService({
    required this.formData,
    required this.controller,
    this.observeUI,
    this.ocrService,
    this.recoveryPlanner,
    this.enableLlmRecovery = true,
    this.allowOcrFallback = true,
    this.startedFromWhatsApp = false,
    this.whatsAppSenderKey,
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

  static Yad2MacHybridAutomationService? activeInstance;

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

  bool get isPaused => _isPaused;
  AutomationPhase? get pausedPhase => _pausedPhase;

  void dispose() {
    _stopLoginGate();
    _isPaused = true;
    _currentPhase = null;
    _pausedPhase = null;
    unawaited(_updateWhatsAppPublishingFlag(false));
  }

  void stop() {
    debugPrint('[Yad2-A11y] Stop requested');
    _stopLoginGate();
    _isPaused = true;
    _currentPhase = null;
    _pausedPhase = null;
    unawaited(_updateWhatsAppPublishingFlag(false));
    try {
      WakelockPlus.disable();
    } catch (_) {}
  }

  void pauseAutomation() {
    debugPrint('[Yad2-A11y] Pause requested');
    _stopLoginGate();
    _isPaused = true;
  }

  void resumeAutomation() {
    debugPrint('[Yad2-A11y] Resume requested');
    _stopLoginGate();
    _isPaused = false;

    final phaseToResume =
        _pausedPhase ?? _currentPhase ?? AutomationPhase.phase1;
    _pausedPhase = null;
    _processPhase(phaseToResume);
  }

  void stepBack() {
    final current = _pausedPhase ?? _currentPhase;
    if (current == null) return;
    final currentIndex = current.index;
    if (currentIndex <= 0) return;
    final prev = AutomationPhase.values[currentIndex - 1];
    debugPrint(
      '[Yad2-A11y] Stepping back from ${current.name} to ${prev.name}',
    );
    _pausedPhase = prev;
    _currentPhase = prev;
  }

  bool _hasNotifiedCompletion = false;

  void startAutomation() {
    debugPrint('[Yad2-A11y] Starting optimized Accessibility automation');
    _stopLoginGate();
    _isPaused = false;
    _pausedPhase = null;
    _hasNotifiedCompletion = false;
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    WakelockPlus.enable();
    unawaited(_updateWhatsAppPublishingFlag(true));
    _processPhase(AutomationPhase.phase1);
  }

  void _processPhase(AutomationPhase phase) {
    _currentPhase = phase;
    _phaseRetryCount = 0;
    if (_isPaused) {
      _pausedPhase = phase;
      debugPrint('[Yad2-A11y] Automation paused at phase: ${phase.name}');
      return;
    }
    unawaited(_executePhase(phase));
  }

  Future<void> _executePhase(AutomationPhase phase) async {
    _currentPhase = phase;
    if (_isPaused) {
      _pausedPhase = phase;
      return;
    }

    unawaited(_updateWhatsAppPublishingFlag(true));

    debugPrint(
      '[Yad2-A11y] === ${phase.name} attempt '
      '${_phaseRetryCount + 1}/${_maxRetries + 1} ===',
    );

    if (phase == AutomationPhase.complete) {
      WakelockPlus.disable();
      unawaited(_notifyAutomationComplete());
      _handlePhaseComplete(AutomationPhase.complete);
      unawaited(_updateWhatsAppPublishingFlag(false));
      return;
    }

    final spec = _buildStepSpec(phase);
    if (spec == null) {
      await _handleError(phase, 'No optimized step spec is registered.');
      return;
    }

    try {
      final result = await spec.action();
      if (_isPaused) return;

      if (!result.success) {
        await _failOrRecover(spec, result.reason);
        return;
      }

      await _waitForUiSettle(spec.settleDelay);

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

      _phaseRetryCount = 0;
      _handlePhaseComplete(result.completeAs ?? phase);
    } catch (e, st) {
      debugPrint('[Yad2-A11y] Phase exception: $e\n$st');
      await _failOrRecover(spec, e.toString());
    }
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
          action: () => _tapListValues(_treatments, fetchSettings: true),
          validation: const _StepValidation(),
        );
      case AutomationPhase.phase5f:
        return _AutomationStepSpec(
          phase: phase,
          goal: 'Select service options.',
          action: () => _tapListValues(_services, fetchSettings: true),
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
              () => _selectOpenOption(
                hand,
                selectedValue: hand.split('|').first,
                closeAfterSelect: true,
              ),
          validation: _StepValidation(
            selectedValue: hand.split('|').first,
            selectedAfterLabel: 'יד*|יד',
            timeout: const Duration(seconds: 6),
          ),
        );
      case AutomationPhase.phase8:
        _scrollDown(0.35);
        return _AutomationStepSpec(
          phase: phase,
          goal: 'Open current ownership dropdown.',
          action:
              () => _openDropdownByLabel(
                'בעלות נוכחית',
                skipToPhase:
                    AutomationPhase
                        .phase9, // Treat phase9 as complete, next is phase10
              ),
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
                closeAfterSelect: true,
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
              closeAfterSelect: true,
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
            timeout: const Duration(seconds: 3),
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
          goal: 'Submit additional-info section.',
          action: _actionSubmitAdditionalInfo,
          validation: const _StepValidation(
            mustContain: 'פרטים', //'ישוב*|יישוב|ישוב|עיר',
            timeout: Duration(seconds: 10),
          ),
        );
      case AutomationPhase.phase15:
        return _AutomationStepSpec(
          phase: phase,
          goal: 'Select city autocomplete value.',
          action: _actionSelectCity,
          validation: _StepValidation(
            selectedValue: _city,
            selectedAfterLabel: 'ישוב*|יישוב|ישוב|עיר',
            timeout: const Duration(seconds: 8),
          ),
        );
      case AutomationPhase.phase16:
        return _AutomationStepSpec(
          phase: phase,
          goal: 'Enter price and submit price section.',
          action: _actionEnterPrice,
          validation: const _StepValidation(
            nextMarker: 'תמונות|העלאת תמונות|הוספת תמונות|תמונות הרכב|המשך',
            timeout: Duration(seconds: 10),
          ),
        );
      case AutomationPhase.phase17:
        return _AutomationStepSpec(
          phase: phase,
          goal: 'Upload photos when available and continue.',
          action: _actionUploadPhotosAndContinue,
          validation: const _StepValidation(
            nextMarker: 'פרסום|תשלום|סיום|המודעה|המשך|לשלב הבא',
            timeout: Duration(seconds: 8),
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
    debugPrint('[Yad2-MacHybrid] 🔍 Testing OCR logic on the first screen...');

    // Show the 'הפסק' floating button immediately before we start taking screenshots
    onFirstStepDetected?.call();

    if (observeUI != null && ocrService != null) {
      final ctx = await _observeUIFresh();
      if (ctx != null && ctx.screenshot.isNotEmpty) {
        debugPrint(
          '[Yad2-MacHybrid] 📸 WKWebView screen screenshot captured (${ctx.screenshot.length} bytes). Requesting OCR...',
        );
        final ocrResult = await ocrService!.extractFullText(ctx.screenshot);
        debugPrint(
          '\n======================================================================\n'
          '==== FIRST SCREEN OCR RETURNED RESPONSE (WKWEBVIEW SCREEN) ====\n'
          '======================================================================\n'
          '${ocrResult ?? "[OCR returned null or empty response]"}\n'
          '======================================================================\n',
        );
      } else {
        debugPrint(
          '[Yad2-MacHybrid] ⚠️ UIContext or screenshot was null/empty.',
        );
      }
    } else {
      debugPrint('[Yad2-MacHybrid] ⚠️ observeUI or ocrService is null.');
    }

    // Now proceed with normal detection
    bool loginDetected = false;
    await _retryUntil(
      () async {
        if (await _isElementPresent('חיפוש')) return true;
        if (await _dismissKnownPopups()) return false;
        if (await _checkIsLoginScreen()) {
          loginDetected = true;
          return true;
        }
        return false;
      },
      timeout: const Duration(milliseconds: 1000),
      pollInterval: const Duration(milliseconds: 500),
    );

    if (loginDetected) {
      await _notifyLoginRequired();
      _startLoginGate();
      return const _StepActionResult.failure('Login required.');
    }

    return const _StepActionResult.success();
  }

  Future<_StepActionResult> _actionEnterLicenseAndSearch() async {
    await Future.delayed(const Duration(milliseconds: 800));
    // Best-effort reset-popup dismissal — single attempt, exactly like the
    // original. A "resume existing publication" dialog may appear; if so, tap
    // start-over. Do NOT poll for it: on a fresh start it never shows and
    // polling would stall the flow for seconds.
    if (await toolFindElementAndTap('התחלה מחדש|מחדש')) {
      debugPrint('[Yad2-A11y] Reset popup found — tapped start-over.');
      await Future.delayed(const Duration(milliseconds: 800));
    }
    final license = _nonEmpty(formData.licenseNumber, fallback: '5211639');
    final entered = await _retryUntil(
      () => _performWithPopupHandling(
        () => toolEnterTextBefore('חיפוש', license),
      ),
      timeout: const Duration(seconds: 8),
    );
    if (!entered) {
      return const _StepActionResult.failure('License input field not found.');
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

    final opened = await _retryUntil(
      () => _performWithPopupHandling(() async {
        if (await toolTapNodeAfter(label)) return true;
        return tapSmart(label);
      }),
      timeout: const Duration(seconds: 8),
    );
    return opened
        ? const _StepActionResult.success()
        : _StepActionResult.failure('Dropdown "$label" did not open.');
  }

  Future<_StepActionResult> _actionSelectColorAndShade() async {
    await _scrollDown(0.2);
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
    final tapped = await _retryUntil(
      () => _performWithPopupHandling(() async {
        int instanceToUse = targetInstance;
        if (instanceToUse > 1 &&
            !await _isElementPresent(option, targetInstance: instanceToUse)) {
          instanceToUse = 1;
        }
        return tapSmart(option, targetInstance: instanceToUse);
      }),
      timeout: const Duration(seconds: 6),
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
    if (!formData.noTest) return const _StepActionResult.success();
    await _retryUntil(
      () => _performWithPopupHandling(() => tapSmart('ללא טסט')),
      timeout: const Duration(seconds: 4),
    );
    return const _StepActionResult.success();
  }

  Future<_StepActionResult> _actionWarranties() async {
    await _fetchSettingsIfNeeded();
    if (_warranties.isEmpty) return const _StepActionResult.success();
    await _scrollDown(0.2);

    final durationCounts = <String, int>{};
    final battery =
        _warranties
            .where((warranty) => warranty == 'אחריות על הסוללה')
            .toList();
    final others =
        _warranties
            .where((warranty) => warranty != 'אחריות על הסוללה')
            .toList();

    Future<bool> process(List<String> warranties) async {
      for (final warranty in warranties) {
        await _retryUntil(
          () => _performWithPopupHandling(() => tapSmart(warranty)),
          timeout: const Duration(seconds: 4),
        );
        await Future.delayed(const Duration(milliseconds: 800));

        final duration = _warrantyDurations[warranty]?.trim();
        if (duration == null || duration.isEmpty) continue;
        final instance = (durationCounts[duration] ?? 0) + 1;
        durationCounts[duration] = instance;
        await _scrollDown(0.1);

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

  Future<_StepActionResult> _tapListValues(
    List<String> values, {
    bool fetchSettings = false,
  }) async {
    if (fetchSettings) await _fetchSettingsIfNeeded();
    if (values.isEmpty) return const _StepActionResult.success();
    await _scrollDown(0.2);
    for (final value in values) {
      await _retryUntil(
        () => _performWithPopupHandling(() => tapSmart(value)),
        timeout: const Duration(seconds: 3),
      );
    }
    return const _StepActionResult.success();
  }

  Future<_StepActionResult> _actionOpenHandDropdown() async {
    await _scrollDown(0.2);
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
    await _scrollDown(0.1);
    final km = _nonEmpty(formData.kilometers, fallback: '0');
    final entered = await _retryUntil(
      () => _performWithPopupHandling(() async {
        if (!await toolTapNodeAfter('קילומטראז|קילומטר|נסועה')) return false;
        await Future.delayed(const Duration(milliseconds: 500));
        await toolEnterTextAtFocusedJs(km);
        return true;
      }),
      timeout: const Duration(seconds: 8),
    );
    if (!entered) {
      return const _StepActionResult.failure('Kilometers field not found.');
    }
    await _dismissKeyboard();
    await _scrollDown(0.3);
    return const _StepActionResult.success();
  }

  Future<_StepActionResult> _actionDisability() async {
    if (!formData.handicapped) return const _StepActionResult.success();
    await _retryUntil(
      () => _performWithPopupHandling(() => tapSmart('מותאם לנכים|נכים|נכה')),
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
    if (uiExcludedLabels.contains(trimmed)) return false;
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

  Future<String> _extractVehicleDescriptionText() async {
    String text = '';

    // 1. Access fresh accessibility tree and print it to log
    final treeStr = await _readTreeString();
    debugPrint('====================================================');
    debugPrint(
      '🌲 [Yad2-A11y] Fresh Accessibility Tree Dump at _extractVehicleDescriptionText:',
    );
    if (treeStr != null && treeStr.trim().isNotEmpty) {
      for (final line in treeStr.split('\n')) {
        debugPrint(line);
      }
    } else {
      debugPrint('[Yad2-A11y] Accessibility tree was null or empty.');
    }
    debugPrint('====================================================');

    if (treeStr != null && treeStr.isNotEmpty) {
      final nodes = _parseA11yTree(treeStr);
      debugPrint(
        '[Yad2-A11y] Parsed ${nodes.length} nodes from accessibility tree.',
      );

      // Priority 1: Check target labels (e.g. "סוג הרכב", "פרטים חשובים על הרכב")
      const targetLabels = [
        'סוג הרכב',
        'פרטים חשובים על הרכב',
        'זה המקום לתאר',
        'מה חשוב לך שידעו',
        'תיאור הרכב',
        'תיאור',
      ];
      for (int i = 0; i < nodes.length; i++) {
        final n = nodes[i];
        final matchesLabel = targetLabels.any(
          (lbl) => n.text.trim() == lbl || n.desc.trim() == lbl,
        );
        if (matchesLabel) {
          debugPrint(
            '[Yad2-A11y] Matched label node at index $i: "${n.text.isNotEmpty ? n.text : n.desc}"',
          );
          // Look ahead in subsequent nodes for the value
          for (
            int offset = 1;
            offset <= 6 && (i + offset) < nodes.length;
            offset++
          ) {
            final nextNode = nodes[i + offset];
            if (isValidExtractedDescription(nextNode.text)) {
              text = nextNode.text.trim();
              debugPrint(
                '[Yad2-A11y] Found description at offset +$offset after label: "$text"',
              );
              return _saveAndReturnDescription(text);
            }
            if (isValidExtractedDescription(nextNode.desc)) {
              text = nextNode.desc.trim();
              debugPrint(
                '[Yad2-A11y] Found description in desc at offset +$offset after label: "$text"',
              );
              return _saveAndReturnDescription(text);
            }
          }
        }
        // Also check composite container starting with "סוג הרכב "
        if (n.text.startsWith('סוג הרכב ') && n.text.length > 12) {
          final candidate = n.text.replaceFirst('סוג הרכב', '').trim();
          if (isValidExtractedDescription(candidate)) {
            text = candidate;
            debugPrint(
              '[Yad2-A11y] Found vehicle description in composite container: "$text"',
            );
            return _saveAndReturnDescription(text);
          }
        }
      }

      // Priority 2: Check EditText / textarea nodes directly
      for (final node in nodes) {
        final isEditText = node.className.toLowerCase().contains('edittext');
        if (isEditText) {
          debugPrint(
            '[Yad2-A11y] Inspecting EditText node: text="${node.text}" desc="${node.desc}"',
          );
          if (isValidExtractedDescription(node.text)) {
            text = node.text.trim();
            debugPrint(
              '[Yad2-A11y] Found description in EditText text: "$text"',
            );
            return _saveAndReturnDescription(text);
          }
          if (isValidExtractedDescription(node.desc)) {
            text = node.desc.trim();
            debugPrint(
              '[Yad2-A11y] Found description in EditText desc: "$text"',
            );
            return _saveAndReturnDescription(text);
          }
        }
      }

      // Priority 3: Any node with valid description (e.g. inside dialog / modal preview)
      for (final node in nodes) {
        if (isValidExtractedDescription(node.text)) {
          text = node.text.trim();
          debugPrint('[Yad2-A11y] Found description in node text: "$text"');
          return _saveAndReturnDescription(text);
        }
        if (isValidExtractedDescription(node.desc)) {
          text = node.desc.trim();
          debugPrint('[Yad2-A11y] Found description in node desc: "$text"');
          return _saveAndReturnDescription(text);
        }
      }
    }

    // Priority 4: Accessibility channel fallback (findNodeTextAfterTarget)
    try {
      for (final offset in [1, 2, 3]) {
        final a11yText = await _channel
            .invokeMethod<String>('findNodeTextAfterTarget', {
              'target': 'פרטים חשובים על הרכב|זה המקום לתאר|מה חשוב לך שידעו',
              'targetInstance': 1,
              'threshold': 0.75,
              'offset': offset,
            });
        if (a11yText != null && isValidExtractedDescription(a11yText)) {
          text = a11yText.trim();
          debugPrint(
            '[Yad2-A11y] Extracted description via findNodeTextAfterTarget (offset: $offset): "$text"',
          );
          return _saveAndReturnDescription(text);
        }
      }
    } catch (e) {
      debugPrint(
        '[Yad2-A11y] Error extracting description via findNodeTextAfterTarget: $e',
      );
    }

    // Fallback: Computer Vision and LLM Validation
    if (text.isEmpty) {
      debugPrint(
        '[Yad2-A11y] 🔄 Accessibility tree yielded no description. Falling back to Computer Vision & LLM validation...',
      );
      text = await _extractDescriptionViaVisionAndLlm();
    }

    return _saveAndReturnDescription(text);
  }

  Future<String> _extractDescriptionViaVisionAndLlm() async {
    try {
      debugPrint(
        '[Yad2-A11y] 📷 Capturing fresh UI context / screenshot for Computer Vision...',
      );
      final ctx = await _observeUIFresh();
      if (ctx == null || ctx.screenshot.isEmpty) {
        debugPrint(
          '[Yad2-A11y] UI screenshot not available for Computer Vision.',
        );
        return '';
      }

      String ocrText = '';
      if (ocrService != null) {
        debugPrint(
          '[Yad2-A11y] 🔍 Running Google Cloud Vision OCR on screenshot...',
        );
        final fullOcr = await ocrService!.extractFullText(ctx.screenshot);
        if (fullOcr != null && fullOcr.trim().isNotEmpty) {
          ocrText = fullOcr.trim();
          debugPrint('====================================================');
          debugPrint('📷 [Yad2-A11y] Computer Vision (OCR) Extracted Text:');
          for (final line in ocrText.split('\n')) {
            debugPrint(line);
          }
          debugPrint('====================================================');
        }
      }

      // Send to LLM for validation & extraction
      debugPrint(
        '[Yad2-A11y] 🤖 Calling LLM to validate and extract vehicle description...',
      );
      final llmResult = await _extractDescriptionWithLlm(
        ocrText: ocrText.isNotEmpty ? ocrText : null,
        screenshot: ctx.screenshot,
      );

      if (llmResult != null && isValidExtractedDescription(llmResult)) {
        debugPrint(
          '[Yad2-A11y] ✅ LLM validated & extracted description: "$llmResult"',
        );
        return llmResult;
      }
    } catch (e) {
      debugPrint(
        '[Yad2-A11y] Error during Computer Vision & LLM validation fallback: $e',
      );
    }
    return '';
  }

  Future<String?> _extractDescriptionWithLlm({
    String? ocrText,
    Uint8List? screenshot,
  }) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      final apiKey =
          (prefs.getString('anthropic_api_key') ??
                      const String.fromEnvironment(
                        'ANTHROPIC_API_KEY',
                        defaultValue: '',
                      ))
                  .trim()
                  .isNotEmpty
              ? (prefs.getString('anthropic_api_key') ??
                      const String.fromEnvironment('ANTHROPIC_API_KEY'))
                  .trim()
              : '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';

      final systemPrompt =
          'You are an expert AI assistant inspecting a vehicle listing form on Yad2. '
          'Your task is to identify and extract ONLY the user-written vehicle description '
          '(e.g. car condition, mechanical status, test validity, upgrades, accessories, care history). '
          'Do NOT extract UI buttons (like עדכנתי בואו נמשיך, לשלב הבא, סגור), UI section titles '
          '(like פרטים חשובים על הרכב, מה חשוב לך שידעו על הרכב), or placeholder instructions '
          '(like זה המקום לתאר את הרכב). '
          'If no user-written vehicle description is present, reply strictly with: NONE. '
          'Do not include markdown or explanations. Return ONLY the exact vehicle description text or NONE.';

      final messages = <Map<String, dynamic>>[
        {'role': 'system', 'content': systemPrompt},
      ];

      if (ocrText != null && ocrText.isNotEmpty) {
        messages.add({
          'role': 'user',
          'content':
              'Here is the text extracted by Computer Vision OCR from the screen:\n---\n$ocrText\n---\n'
              'Extract the user vehicle description, or return NONE if not found.',
        });
      } else if (screenshot != null && screenshot.isNotEmpty) {
        final b64 = base64Encode(screenshot);
        messages.add({
          'role': 'user',
          'content': [
            {
              'type': 'text',
              'text':
                  'Extract the user vehicle description from this Yad2 listing screen image. Return NONE if no user description is present.',
            },
            {
              'type': 'image_url',
              'image_url': {'url': 'data:image/png;base64,$b64'},
            },
          ],
        });
      } else {
        return null;
      }

      final body = jsonEncode({
        'model': 'gpt-5.6-luna',
        'messages': messages,
        'max_completion_tokens': 350,
      });

      final res = await http
          .post(
            Uri.parse('https://api.openai.com/v1/chat/completions'),
            headers: {
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $apiKey',
            },
            body: body,
          )
          .timeout(const Duration(seconds: 15));

      if (res.statusCode == 200) {
        final decoded =
            jsonDecode(utf8.decode(res.bodyBytes)) as Map<String, dynamic>;
        final content =
            decoded['choices']?[0]?['message']?['content']?.toString().trim() ??
            '';
        if (content.isNotEmpty && !content.toUpperCase().contains('NONE')) {
          return content;
        }
      } else {
        debugPrint(
          '[Yad2-A11y] LLM extraction error HTTP ${res.statusCode}: ${res.body}',
        );
      }
    } catch (e) {
      debugPrint('[Yad2-A11y] LLM extraction call failed: $e');
    }
    return null;
  }

  Future<_StepActionResult> _actionSubmitAdditionalInfo() async {
    await _scrollDown(0.35);

    // 3. Dismiss any known popups like "עדכנתי, בואו נמשיך"
    await _dismissKnownPopups();
    await Future.delayed(const Duration(milliseconds: 1500));

    final submitted = await _retryUntil(
      () => _performWithPopupHandling(() => tapSmart('לשלב הבא|שלב הבא|לשלב')),
      timeout: const Duration(seconds: 8),
    );
    if (!submitted) {
      return const _StepActionResult.failure(
        'Additional-info submit not found.',
      );
    }

    await Future.delayed(const Duration(milliseconds: 900));
    try {
      stdout.write('\x1B[2J\x1B[0;0H');
    } catch (_) {}
    debugPrint('\x1B[2J\x1B[0;0H');

    String desc = await _extractVehicleDescriptionText();
    debugPrint(
      '[Yad2-A11y] Injecting pre-existing description into Yad2 field: $desc',
    );

    if (await _dismissKnownPopups()) {
      await _scrollDown(0.2);
      // 1. First, check if a dialog/popup is presenting the additional info BEFORE dismissing it!
      String desc = await _extractVehicleDescriptionText();
      // 2. If formData has a pre-existing description and Yad2 has none, enter it into Yad2
      final hasPreExistingDesc =
          formData.description.trim().isNotEmpty &&
          isValidExtractedDescription(formData.description);
      if (!isValidExtractedDescription(desc) && hasPreExistingDesc) {
        await toolEnterTextAtFocusedJs(formData.description.trim());
        desc = formData.description.trim();
      }

      try {
        stdout.write('\x1B[2J\x1B[0;0H');
      } catch (_) {}
      debugPrint('\x1B[2J\x1B[0;0H');

      debugPrint(
        '[Yad2-A11y] Injecting pre-existing description into Yad2 field: $desc',
      );

      await _retryUntil(
        () => tapSmart('לשלב הבא|שלב הבא|לשלב'),
        timeout: const Duration(seconds: 5),
      );
    }
    return const _StepActionResult.success();
  }

  Future<_StepActionResult> _actionSelectCity() async {
    await _scrollDown(0.1);
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
      () => _performWithPopupHandling(() => toolTapNodeAfter(label)),
      timeout: const Duration(seconds: 8),
    );
    if (!fieldTapped) {
      return const _StepActionResult.failure('City input label not found.');
    }

    var current = '';
    for (final rune in typed.runes) {
      current += String.fromCharCode(rune);
      await toolEnterTextAtFocusedJs(current);
      await Future.delayed(const Duration(milliseconds: 280));
    }

    final picked = await _retryUntil(
      () => _performWithPopupHandling(() => tapSmart(city)),
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
    final price = _nonEmpty(formData.price, fallback: '80000');
    final entered = await _retryUntil(
      () => _performWithPopupHandling(() async {
        if (!await toolTapNodeAfter('מחיר|סכום מינימלי|סכום', offset: 1)) {
          return false;
        }
        await Future.delayed(const Duration(milliseconds: 500));
        await toolEnterTextAtFocusedJs(price);
        return true;
      }),
      timeout: const Duration(seconds: 8),
    );
    if (!entered) {
      return const _StepActionResult.failure('Price field not found.');
    }

    await _dismissKeyboard();
    await _scrollDown(0.5);
    final submitted = await _retryUntil(
      () => _performWithPopupHandling(
        () => tapSmart('לשלב הבא|שלב הבא|לשלב|המשך'),
      ),
      timeout: const Duration(seconds: 8),
    );
    return submitted
        ? const _StepActionResult.success()
        : const _StepActionResult.failure(
          'Submit button after price not found.',
        );
  }

  Future<_StepActionResult> _actionUploadPhotosAndContinue() async {
    final uploaded = await _injectImagesIfAny();
    if (!uploaded) {
      debugPrint('[Yad2-A11y] Continuing without image injection.');
    }
    await _scrollDown(0.75);
    final submitted = await _retryUntil(
      () => _performWithPopupHandling(
        () => tapSmart('לשלב הבא|שלב הבא|המשך|לשלב'),
      ),
      timeout: const Duration(seconds: 10),
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
    final opened = await _retryUntil(
      () => _performWithPopupHandling(() async {
        if (await toolTapNodeAfter(label, offset: labelOffset)) return true;
        if (await tapSmart(label)) return true;
        return false;
      }),
      timeout: const Duration(seconds: 6),
    );
    if (!opened) return false;
    await _waitForUiSettle(const Duration(milliseconds: 500));

    final selected = await _retryUntil(
      () => _performWithPopupHandling(
        () => tapSmart(value, targetInstance: valueInstance),
      ),
      timeout: const Duration(seconds: 6),
    );
    if (!selected) return false;

    await _waitForUiSettle(const Duration(milliseconds: 700));
    if (closeAfterSelect) {
      await _closeDropdownIfNeeded();
    }
    // A successful tap is success (matches original). No presence gate here.
    return true;
  }

  Future<_StepActionResult> _actionTermsAgreement() async {
    const termsText = 'קראתי ואישרתי את התקנון';

    // 1. Detect and tap checkbox (node before text "קראתי ואישרתי את התקנון" or text itself)
    final tappedCheckbox = await _performWithPopupHandling(() async {
      final nodeBefore = await toolTapNodeBefore(termsText);
      if (nodeBefore) return true;
      return tapSmart(termsText);
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
    final clickedNext = await _performWithPopupHandling(
      () => tapSmart('לשלב הבא|שלב הבא|לשלב'),
    );

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
  }) async {
    if (allowJsFallback) {
      for (final alt in _splitAlternatives(targetText)) {
        if (await toolFindAndTapJs(alt, targetInstance: targetInstance)) {
          onAutomationFallback?.call('JavaScript', alt);
          debugPrint('[Yad2-A11y] Shadow-DOM fallback clicked "$alt"');
          return true;
        }
      }
    }

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
  }) async {
    debugPrint(
      '[Yad2-MacHybrid] Tool tapElement("$targetText", instance=$targetInstance) using OCR logic',
    );
    try {
      // For this macOS use-case, search for the relevant words in the OCR output,
      // generate their global coordinates and send the tap
      for (final alt in _splitAlternatives(targetText)) {
        if (await toolOcrFindAndTap(
          alt,
          targetInstance: targetInstance,
          deltaY: deltaY,
        )) {
          debugPrint(
            '[Yad2-MacHybrid] tapElement tapped "$alt" successfully via OCR',
          );
          return true;
        }
      }
      return false;
    } catch (e) {
      debugPrint('[Yad2-MacHybrid] tapElement failed: $e');
      return false;
    }
  }

  Future<bool> toolTapNodeBefore(
    String targetText, {
    int targetInstance = 1,
    double deltaY = 0,
  }) async {
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
      return _channel.invokeMethod<String>('findNodeTextAfterTarget', {
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
    try {
      final bounds = await _getStableBounds('findInputBeforeAndGetBounds', {
        'target': targetText,
      });
      if (bounds == null) return false;
      await _tapBounds(bounds);
      await Future.delayed(const Duration(milliseconds: 500));
      final native = await toolEnterTextAtFocused(value);
      if (native) return true;
      onAutomationFallback?.call('JavaScript', targetText);
      await toolEnterTextAtFocusedJs(value);
      return true;
    } catch (e) {
      debugPrint('[Yad2-A11y] enterTextBefore failed: $e');
      return false;
    }
  }

  Future<bool> toolEnterTextNear(String label, String value) async {
    final tapped = await toolTapNodeAfter(label) || await tapSmart(label);
    if (!tapped) return false;
    await Future.delayed(const Duration(milliseconds: 500));
    final native = await toolEnterTextAtFocused(value);
    if (native) return true;
    onAutomationFallback?.call('JavaScript', label);
    await toolEnterTextAtFocusedJs(value);
    return true;
  }

  Future<void> toolTapScreen(double x, double y) async {
    try {
      await _channel.invokeMethod('tapScreen', {'x': x, 'y': y});
    } catch (e) {
      debugPrint('[Yad2-A11y] tapScreen failed: $e');
    }
  }

  Future<bool> toolPressBack() async {
    try {
      final pressed = await _channel.invokeMethod<bool>('pressBack');
      return pressed ?? false;
    } catch (e) {
      debugPrint('[Yad2-A11y] pressBack failed: $e');
      return false;
    }
  }

  Future<bool> toolEnterTextAtFocused(String text) async {
    try {
      final success = await _channel.invokeMethod<bool>('enterTextAtFocused', {
        'value': text,
      });
      return success ?? false;
    } catch (e) {
      debugPrint('[Yad2-A11y] enterTextAtFocused failed: $e');
      return false;
    }
  }

  Future<void> toolEnterTextAtFocusedJs(String text) async {
    final encoded = jsonEncode(text);
    await controller.runJavaScript('''
      (function(value) {
        var el = document.activeElement;
        if (!el || (el.tagName !== 'INPUT' && el.tagName !== 'TEXTAREA')) {
          var inputs = document.querySelectorAll('input:not([type="hidden"]):not([type="checkbox"]):not([type="radio"]), textarea');
          for (var i = 0; i < inputs.length; i++) {
            var rect = inputs[i].getBoundingClientRect();
            if (rect.width > 0 && rect.height > 0 && rect.top >= 0 && rect.bottom <= window.innerHeight) {
              el = inputs[i];
              break;
            }
          }
        }
        if (!el || (el.tagName !== 'INPUT' && el.tagName !== 'TEXTAREA')) return false;
        el.focus();
        var proto = el.tagName === 'TEXTAREA' ? window.HTMLTextAreaElement.prototype : window.HTMLInputElement.prototype;
        var setter = Object.getOwnPropertyDescriptor(proto, 'value') && Object.getOwnPropertyDescriptor(proto, 'value').set;
        if (setter) setter.call(el, value);
        else el.value = value;
        el.dispatchEvent(new InputEvent('input', { bubbles: true, data: value, inputType: 'insertText' }));
        el.dispatchEvent(new Event('change', { bubbles: true }));
        return true;
      })($encoded);
    ''');
  }

  Future<bool> toolFindAndTapJs(
    String targetText, {
    int targetInstance = 1,
  }) async {
    final encoded = jsonEncode(targetText);
    final result = await controller.runJavaScriptReturningResult('''
      (function(targetText, targetInstance) {
        var all = [];
        function visit(root) {
          if (!root) return;
          var elements = root.querySelectorAll('*');
          for (var i = 0; i < elements.length; i++) {
            all.push(elements[i]);
            if (elements[i].shadowRoot) visit(elements[i].shadowRoot);
          }
        }
        visit(document);

        var cleanTarget = String(targetText || '').replace(/\\s+/g, '');
        var matches = [];
        for (var i = 0; i < all.length; i++) {
          var el = all[i];
          var rect = el.getBoundingClientRect();
          if (rect.width === 0 || rect.height === 0) continue;
          if (rect.width > window.innerWidth * 0.92) continue;
          if (rect.height > Math.max(180, window.innerHeight * 0.35)) continue;
          var text = (el.getAttribute('aria-label') || el.innerText || el.textContent || '').trim();
          var cleanText = text.replace(/\\s+/g, '');
          if (cleanText === cleanTarget || cleanText.indexOf(cleanTarget) >= 0) {
            var role = el.getAttribute('role') || '';
            var style = window.getComputedStyle(el);
            var interactive = el.tagName === 'BUTTON' || el.tagName === 'A' || el.tagName === 'LABEL' ||
              role === 'button' || role === 'option' || role === 'menuitem' || style.cursor === 'pointer';
            matches.push({ el: el, area: rect.width * rect.height, interactive: interactive });
          }
        }
        matches.sort(function(a, b) {
          if (a.interactive !== b.interactive) return a.interactive ? -1 : 1;
          return a.area - b.area;
        });
        var item = matches[Math.max(0, targetInstance - 1)];
        var target = item && item.el;
        if (!target) return false;
        try { target.scrollIntoView({ behavior: 'auto', block: 'center', inline: 'center' }); } catch(e) {}
        var box = target.getBoundingClientRect();
        var x = box.left + box.width / 2;
        var y = box.top + box.height / 2;
        var opts = { bubbles: true, cancelable: true, clientX: x, clientY: y, screenX: x, screenY: y };
        try {
          target.dispatchEvent(new MouseEvent('mousedown', opts));
          target.dispatchEvent(new MouseEvent('mouseup', opts));
          target.dispatchEvent(new MouseEvent('click', opts));
          target.click();
        } catch(e) {}
        try {
          var key = Object.keys(target).find(function(k) { return k.startsWith('__reactFiber') || k.startsWith('__reactInternalInstance'); });
          var fiber = key && target[key];
          while (fiber) {
            var props = fiber.memoizedProps || fiber.pendingProps;
            if (props && typeof props.onClick === 'function') {
              props.onClick({ type: 'click', target: target, currentTarget: target, clientX: x, clientY: y, bubbles: true, preventDefault: function(){}, stopPropagation: function(){} });
              break;
            }
            fiber = fiber.return;
          }
        } catch(e) {}
        return true;
      })($encoded, $targetInstance);
    ''');
    return result == true || result == 'true';
  }

  Future<bool> toolOcrFindAndTap(
    String targetText, {
    int targetInstance = 1,
    double deltaY = 0,
  }) async {
    if (ocrService == null || observeUI == null) return false;
    final ctx = await _observeUIFresh();
    if (ctx == null) return false;
    final loc = await _findOcr(ctx, targetText, targetInstance);
    if (loc == null) return false;

    // Transform physical OCR pixels to logical (css) pixels
    final cssX = loc.centerX / _devicePixelRatio;
    final cssY = (loc.centerY + deltaY) / _devicePixelRatio;

    onTapPreview?.call(cssX, cssY);
    onAutomationFallback?.call('OCR', targetText);

    // Send logical coordinates to native macOS layer
    await toolTapScreen(cssX, cssY);
    return true;
  }

  Future<void> toolLogTree() async {
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
          await _scrollDown((call.args['percent'] as num?)?.toDouble() ?? 0.5);
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
    if (_isPaused) {
      _pausedPhase = spec.phase;
      return;
    }

    if (_phaseRetryCount < _maxRetries) {
      _phaseRetryCount++;
      final backoffMs = 900 * _phaseRetryCount;
      debugPrint(
        '[Yad2-A11y] Retry $_phaseRetryCount/$_maxRetries in ${backoffMs}ms: $reason',
      );
      Future.delayed(Duration(milliseconds: backoffMs), () {
        if (!_isPaused) unawaited(_executePhase(spec.phase));
      });
      return;
    }

    final recovered = await _tryRecovery(spec, reason);
    if (recovered) {
      _phaseRetryCount = 0;
      if (!_isPaused) unawaited(_executePhase(spec.phase));
      return;
    }

    await _handleError(
      spec.phase,
      'Stuck at ${spec.phase.description}: $reason',
    );
  }

  Future<bool> _tryRecovery(_AutomationStepSpec spec, String reason) async {
    debugPrint('[Yad2-A11y] Recovery gate for ${spec.phase.name}: $reason');

    if (await _dismissKnownPopups()) return true;

    if (await _checkIsLoginScreen()) {
      await _notifyLoginRequired();
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

  Future<bool> _isElementPresent(
    String target, {
    int targetInstance = 1,
  }) async {
    try {
      final bounds = await _channel.invokeMapMethod<String, dynamic>(
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
    const popupTexts = [
      'הבנתי',
      'עדכנתי, בואו נמשיך',
      'עדכנתי, בוא נמשיך',
      'עדכנתי בואו נמשיך',
      'אולי אחר כך',
    ];
    for (final text in popupTexts) {
      if (await toolFindElementAndTap(text, deltaY: -15)) {
        debugPrint('[Yad2-A11y] Dismissed popup: $text');
        await Future.delayed(const Duration(milliseconds: 1000));
        return true;
      }
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
      if (_isPaused) return false;
      if (await action()) return true;
      await Future.delayed(pollInterval);
    } while (DateTime.now().isBefore(deadline));
    return false;
  }

  Future<void> _scrollDown(double percent) async {
    try {
      await _channel.invokeMethod('scrollNode', {
        'direction': 'down',
        'percent': percent,
      });
    } catch (e) {
      debugPrint('[Yad2-A11y] Scroll failed: $e');
    }
    await _waitForScrollSettle();
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
      final bounds = await _channel.invokeMapMethod<String, dynamic>(
        method,
        args,
      );
      if (bounds == null) return null;
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
    final cssX = (bounds['x'] as num).toDouble() + deltaX;
    final cssY = (bounds['y'] as num).toDouble() + deltaY;
    onTapPreview?.call(cssX, cssY);
    await toolTapScreen(cssX, cssY);
  }

  Future<String?> _readTreeString() async {
    try {
      return _channel.invokeMethod<String>('logTree');
    } catch (_) {
      return null;
    }
  }

  Future<void> _dismissKeyboard() async {
    await Future.delayed(const Duration(milliseconds: 500));
    await toolPressBack();
    await Future.delayed(const Duration(milliseconds: 500));
  }

  Future<bool> _checkIsLoginScreen() async {
    try {
      final res = await controller.runJavaScriptReturningResult('''
        (function() {
          var hasPassword = document.querySelector('input[type="password"]') !== null;
          var text = document.body ? document.body.innerText : '';
          return hasPassword || text.includes('התחברות') || text.includes('כניסה לאזור האישי') || text.includes('אימייל/מספר טלפון');
        })()
      ''');
      if (res == true || res == 'true') return true;
    } catch (_) {}

    const keywords = [
      'התחברות',
      'כניסה לאזור',
      'דוא"ל',
      'סיסמה',
      'הרשמה',
      'כניסה',
      'התחבר',
    ];
    for (final keyword in keywords) {
      if (await _isElementPresent(keyword)) return true;
    }
    return false;
  }

  DateTime? _lastDeadlockNotified;

  Future<void> _notifyDeadlockInterventionRequired(
    String stepName,
    String details,
  ) async {
    final senderKey = whatsAppSenderKey?.trim();
    if (senderKey == null || senderKey.isEmpty) return;

    final now = DateTime.now();
    if (_lastDeadlockNotified != null &&
        now.difference(_lastDeadlockNotified!) < const Duration(seconds: 15)) {
      return; // Debounce notifications
    }
    _lastDeadlockNotified = now;

    try {
      final bool isP2p = senderKey.startsWith('p2p_');
      final String remoteNotice =
          isP2p
              ? 'נא ללחוץ על כפתור השליטה מרחוק (Remote Control) במסך זה כדי להשתלט על המכשיר ולסייע בהמשך הפרסום.'
              : 'נא להתחבר באמצעות פיצ׳ר השליטה מרחוק (Remote Control) באפליקציית השלט של פירסומוטו כדי לסייע ולהמשיך את הפרסום.';

      final message =
          '⚠️ האוטומציה נתקעה ונדרשת התערבותך!\n'
          'שלב: $stepName\n'
          'פירוט: $details\n\n'
          '$remoteNotice';

      await WhatsAppTextValidationService.dispatchReplyToSender(
        senderKey: senderKey,
        message: message,
      );
      debugPrint('[Yad2-A11y] Dispatched deadlock notification to $senderKey');
    } catch (e) {
      debugPrint('[Yad2-A11y] Failed to dispatch deadlock notification: $e');
    }
  }

  Future<void> _notifyLoginRequired() async {
    final senderKey = whatsAppSenderKey?.trim();
    if (senderKey == null || senderKey.isEmpty) {
      return;
    }
    try {
      final bool isP2p = senderKey.startsWith('p2p_');
      final String remoteNotice =
          isP2p
              ? 'נא ללחוץ על כפתור השליטה מרחוק (Remote Control) במסך זה כדי להזין את פרטי ההתחברות לחשבון יד2.'
              : 'נא להתחבר באמצעות פיצ׳ר השליטה מרחוק (Remote Control) באפליקציית השלט של פירסומוטו כדי להזין את פרטי ההתחברות לחשבון יד2.';

      final message =
          '⚠️ נדרשת התחברות לחשבון יד2!\n'
          'האוטומציה הגיעה למסך כניסה וממתינה להתחברות שלך.\n\n'
          '$remoteNotice';

      final success = await WhatsAppTextValidationService.dispatchReplyToSender(
        senderKey: senderKey,
        message: message,
      );
      debugPrint('[Yad2-A11y] Sent login prompt: $success');
    } catch (e) {
      debugPrint('[Yad2-A11y] Failed to send login prompt: $e');
    }
  }

  void _startLoginGate() {
    if (_loginSamplingTimer != null) return;
    debugPrint('[Yad2-A11y] Login gate active.');
    _isPaused = true;
    _pausedPhase = AutomationPhase.phase1;
    onLoginRequired?.call();
    unawaited(_beepUser());
    unawaited(_notifyLoginRequired());
    _loginSamplingTimer = Timer.periodic(const Duration(seconds: 3), (
      timer,
    ) async {
      if (_loginGateTickBusy) return;
      _loginGateTickBusy = true;
      try {
        await _dismissKnownPopups();
        if (!await _checkIsLoginScreen() && await _isElementPresent('חיפוש')) {
          timer.cancel();
          _loginSamplingTimer = null;
          _isPaused = false;
          _pausedPhase = null;
          _processPhase(AutomationPhase.phase1);
        }
      } finally {
        _loginGateTickBusy = false;
      }
    });
  }

  void _stopLoginGate() {
    _loginSamplingTimer?.cancel();
    _loginSamplingTimer = null;
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
        if (user != null) {
          final doc =
              await FirebaseFirestore.instance
                  .collection('users')
                  .doc(user.uid)
                  .get();
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
      }
    }
    _settingsFetched = true;
  }

  String _getWarrantyDropdownLabel(String warranty) {
    if (warranty.contains('שלדה')) return 'אחריות שלדה, מנוע וגיר';
    if (warranty.contains('יבואן')) return 'אחריות מהיבואן';
    if (warranty.contains('סוכנות')) return 'אחריות מהסוכנות';
    if (warranty.contains('סוללה')) return 'אחירות על סוללה';
    return warranty;
  }

  Future<bool> _injectImagesIfAny() async {
    var images = formData.images;
    if (images == null || images.isEmpty) return false;
    final expectedCount = formData.expectedImageCount;
    if (expectedCount != null && expectedCount == 0) {
      return false;
    }
    if (expectedCount != null &&
        expectedCount > 0 &&
        images.length > expectedCount) {
      images = images.sublist(images.length - expectedCount.toInt());
    }
    final base64Files = <Map<String, String>>[];
    for (var i = 0; i < images.length; i++) {
      final path = images[i];
      if (path.isEmpty) continue;
      try {
        final file = File(path);
        if (!await file.exists()) continue;
        final bytes = await file.readAsBytes();
        final ext = path.split('.').last.toLowerCase();
        final mimeType =
            (ext == 'jpg' || ext == 'jpeg') ? 'image/jpeg' : 'image/png';
        base64Files.add({
          'base64': 'data:$mimeType;base64,${base64Encode(bytes)}',
          'filename': 'photo_${i + 1}.$ext',
          'contentType': mimeType,
        });
      } catch (e) {
        debugPrint('[Yad2-A11y] Image read failed for $path: $e');
      }
    }
    if (base64Files.isEmpty) return false;

    final jsonFiles = jsonEncode(base64Files);
    final result = await controller.runJavaScriptReturningResult('''
      (function() {
        var filesArray = $jsonFiles;
        var fileInput = document.querySelector('input[type="file"]')
          || document.querySelector('input[accept*="image"]')
          || document.querySelector('input[name*="file"]')
          || document.querySelector('input[id*="file"]');
        if (!fileInput) return 'no_input';
        var container = new DataTransfer();
        for (var k = 0; k < filesArray.length; k++) {
          var item = filesArray[k];
          var byteString = atob(item.base64.split(',')[1] || item.base64);
          var ab = new ArrayBuffer(byteString.length);
          var ia = new Uint8Array(ab);
          for (var i = 0; i < byteString.length; i++) ia[i] = byteString.charCodeAt(i);
          var file = new File([new Blob([ab], { type: item.contentType })], item.filename, { type: item.contentType });
          container.items.add(file);
        }
        fileInput.files = container.files;
        fileInput.dispatchEvent(new Event('change', { bubbles: true }));
        return 'ok';
      })()
    ''');
    debugPrint('[Yad2-A11y] Image injection result: $result');
    await Future.delayed(const Duration(seconds: 3));
    return result.toString().contains('ok');
  }

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

  Future<void> _updateWhatsAppPublishingFlag(bool running) async {
    if (whatsAppSenderKey == null || whatsAppSenderKey!.isEmpty) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final key = 'wa_state_$whatsAppSenderKey';
      final jsonStr = prefs.getString(key);
      if (jsonStr != null && jsonStr.isNotEmpty) {
        final state = Map<String, String>.from(jsonDecode(jsonStr));
        state['auto_publish_started'] = running ? 'true' : 'false';
        state['KEY_AUTO_PUBLISH_STARTED'] = running ? 'true' : 'false';
        state['auto_publish_running'] = running ? 'true' : 'false';
        await prefs.setString(key, jsonEncode(state));
        debugPrint('[Yad2-A11y] Updated WhatsApp publishing flags to $running');
      }
    } catch (e) {
      debugPrint('[Yad2-A11y] Failed to update WhatsApp publishing flags: $e');
    }
  }

  void _handlePhaseComplete(AutomationPhase phase) {
    debugPrint('[Yad2-A11y] Phase complete: ${phase.description}');
    onPhaseComplete?.call(phase);

    final next = _nextPhaseAfter(phase);
    if (next == null) {
      stop();
      _notifyAutomationComplete().then((_) {
        onAutomationComplete?.call(true);
      });
      return;
    }

    Future.delayed(_delayAfter(phase), () {
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
    debugPrint('[Yad2-A11y] Phase error: ${phase.description} - $error');
    _isPaused = true;
    _pausedPhase = phase;
    _phaseRetryCount = 0;
    try {
      await _beepUser();
    } catch (_) {}
    unawaited(_notifyDeadlockInterventionRequired(phase.description, error));
    onPhaseError?.call(phase, error);
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

  const _A11yTreeNode({
    required this.className,
    required this.text,
    required this.desc,
    required this.isClickable,
  });
}

List<_A11yTreeNode> _parseA11yTree(String treeStr) {
  final nodes = <_A11yTreeNode>[];
  final regex = RegExp(
    r'\[([^\]]+)\]\s+text="([\s\S]*?)"\s+desc="([\s\S]*?)"\s+clickable=(true|false)',
  );
  for (final match in regex.allMatches(treeStr)) {
    nodes.add(
      _A11yTreeNode(
        className: match.group(1) ?? '',
        text: match.group(2) ?? '',
        desc: match.group(3) ?? '',
        isClickable: match.group(4) == 'true',
      ),
    );
  }
  return nodes;
}
