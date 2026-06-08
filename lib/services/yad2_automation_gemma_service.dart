// import 'dart:async';
// import 'dart:io';
// import 'dart:convert';
// import 'package:flutter/foundation.dart';
// import 'package:flutter/services.dart';
// import 'package:webview_flutter/webview_flutter.dart';
// import 'package:audioplayers/audioplayers.dart';
// import 'package:wakelock_plus/wakelock_plus.dart';
// import 'ocr_service.dart';
// import 'phase_validator.dart';
// import 'ui_context.dart';
// import 'yad2_automation_service.dart' show VehiclePublishData, AutomationPhase;
// import 'gemma_service.dart';

// class Yad2AutomationGemmaService {
//   final WebViewController controller;
//   final OcrService ocrService;
//   final VehiclePublishData formData;
//   final double devicePixelRatio;
//   final GemmaService gemmaService = GemmaService();

//   final Future<UIContext?> Function() observeUI;

//   final void Function(AutomationPhase phase)? onPhaseComplete;
//   final void Function(AutomationPhase phase, String error)? onPhaseError;
//   final void Function(bool success)? onAutomationComplete;
//   final VoidCallback? onFirstStepDetected;
//   final void Function(double cssX, double cssY)? onTapPreview;
//   final PhaseValidator? validator;
//   final VoidCallback? onOcrFallback;

//   static const int _maxRetries = 3;
//   int _phaseRetryCount = 0;
//   bool _isPaused = false;
//   AutomationPhase? _pausedPhase;
//   AutomationPhase? _currentPhase;

//   bool get isPaused => _isPaused;
//   AutomationPhase? get pausedPhase => _pausedPhase;

//   Yad2AutomationGemmaService({
//     required this.controller,
//     required this.ocrService,
//     required this.formData,
//     required this.devicePixelRatio,
//     required this.observeUI,
//     this.onPhaseComplete,
//     this.onPhaseError,
//     this.onAutomationComplete,
//     this.onFirstStepDetected,
//     this.onTapPreview,
//     this.validator,
//     this.onOcrFallback,
//   });

//   void pauseAutomation() {
//     debugPrint('[Yad2-Gemma] ⏸️ Pause requested');
//     _isPaused = true;
//   }

//   void resumeAutomation() {
//     debugPrint('[Yad2-Gemma] ▶️ Resume requested');
//     if (!_isPaused) return;
//     _isPaused = false;

//     final phaseToResume = _pausedPhase ?? _currentPhase;
//     if (phaseToResume != null) {
//       _pausedPhase = null;
//       _processPhase(phaseToResume);
//     }
//   }

//   void stepBack() {
//     final current = _pausedPhase ?? _currentPhase;
//     if (current == null) return;
//     final currentIndex = current.index;
//     if (currentIndex > 0) {
//       final prev = AutomationPhase.values[currentIndex - 1];
//       debugPrint(
//         '[Yad2-Gemma] ↩️ Stepping back from ${current.name} to ${prev.name}',
//       );
//       _pausedPhase = prev;
//       _currentPhase = prev;
//     }
//   }

//   void startAutomation() {
//     debugPrint('[Yad2-Gemma] 🚀 Starting Gemma automation');
//     WakelockPlus.enable();
//     _processPhase(AutomationPhase.phase1);
//   }

//   void _processPhase(AutomationPhase phase) {
//     _currentPhase = phase;
//     _phaseRetryCount = 0;
//     if (_isPaused) {
//       _pausedPhase = phase;
//       debugPrint('[Yad2-Gemma] ⏸️ Automation paused at phase: ${phase.name}');
//       return;
//     }
//     _executePhase(phase);
//   }

//   Future<void> _executePhase(AutomationPhase phase) async {
//     _currentPhase = phase;
//     if (_isPaused) {
//       _pausedPhase = phase;
//       return;
//     }
//     debugPrint(
//       '[Yad2-Gemma] ════════════════════════════════════════════════════',
//     );
//     debugPrint(
//       '[Yad2-Gemma] ${phase.name.toUpperCase()}  attempt ${_phaseRetryCount + 1}/${_maxRetries + 1}',
//     );
//     debugPrint(
//       '[Yad2-Gemma] ════════════════════════════════════════════════════',
//     );

//     try {
//       switch (phase) {
//         case AutomationPhase.phase1:
//           await _phase1SelectVehicleType();
//         case AutomationPhase.phase2:
//           await _phase2EnterLicenseAndSearch();
//         case AutomationPhase.phase3:
//           await _phase3SubmitVehicleLookup();
//         case AutomationPhase.phase4:
//           await _phase4OpenColorDropdown();
//         case AutomationPhase.phase5:
//           await _phase5SelectColorShade();
//         case AutomationPhase.phase5a:
//           await _phase5aOpenMonthDropdown();
//         case AutomationPhase.phase5b:
//           await _phase5bSelectMonthValue();
//         case AutomationPhase.phase6:
//           await _phase6OpenHandDropdown();
//         case AutomationPhase.phase7:
//           await _phase7SelectHandValue();
//         case AutomationPhase.phase8:
//           await _phase8OpenCurrentOwnershipDropdown();
//         case AutomationPhase.phase9:
//           await _phase9SelectCurrentOwnershipValue();
//         case AutomationPhase.phase10:
//           await _phase10OpenPreviousOwnershipDropdown();
//         case AutomationPhase.phase11:
//           await _phase11SelectPreviousOwnershipValue();
//         case AutomationPhase.phase12:
//           await _phase12EnterKilometers();
//         case AutomationPhase.phase13:
//           await _phase13ScrollToTop();
//         case AutomationPhase.phase14:
//           await _phase14EnterAdditionalInfo();
//         case AutomationPhase.phase15:
//           await _phase15EnterPrice();
//         case AutomationPhase.phase16:
//           await _phase16SelectCity();
//         case AutomationPhase.phase17:
//           await _phase17();
//         case AutomationPhase.complete:
//           WakelockPlus.disable();
//           _handlePhaseComplete(AutomationPhase.complete);
//       }
//     } catch (e) {
//       debugPrint('[Yad2-Gemma] Phase execution error: $e');
//       await _handleBlockedFlow(phase, e.toString());
//     }
//   }

//   // ── Function Tools for Gemma ─────────────────────────────────────────────

//   /// Generic function tool: Find element in AxTree and tap
//   Future<bool> toolFindElementAndTap(
//     UIContext ctx,
//     String targetText, {
//     int targetInstance = 1,
//     double deltaY = 0,
//     int retryIndex = 0,
//     bool isListValue = false,
//   }) async {
//     debugPrint(
//       '[Yad2-Gemma] Tool: toolFindElementAndTap("$targetText", instance=$targetInstance, retry=$retryIndex)',
//     );
//     final allMatches = ctx.findAllByLabel(targetText);

//     // Deduplicate matches that are physically in the same spot
//     final uniqueMatches = <AxElement>[];
//     for (final el in allMatches) {
//       final isDuplicate = uniqueMatches.any(
//         (u) => (u.y - el.y).abs() < 25 && (u.x - el.x).abs() < 25,
//       );
//       if (!isDuplicate) {
//         uniqueMatches.add(el);
//       }
//     }

//     if (uniqueMatches.length >= targetInstance) {
//       final el = uniqueMatches[targetInstance - 1];

//       double offsetY = 0;
//       if (retryIndex == 1)
//         offsetY = -10.0; // 10px higher on first retry
//       else if (retryIndex == 2)
//         offsetY = 10.0; // 10px lower on second retry

//       final finalY = el.y + deltaY + offsetY;
//       debugPrint(
//         '[Yad2-Gemma] 🎯 Tapping in AxTree: "${el.label}" at (${el.x}, $finalY) [offsetY=$offsetY]',
//       );

//       await _tapAt(
//         el.x,
//         finalY,
//         hangMs: isListValue ? 0 : 200,
//         isListValue: isListValue,
//       );
//       return true;
//     }
//     return false;
//   }

//   /// Generic function tool: Find input and enter text
//   Future<bool> toolEnterText(
//     UIContext ctx,
//     String targetText,
//     String value, {
//     int targetInstance = 1,
//   }) async {
//     debugPrint(
//       '[Yad2-Gemma] Tool: toolEnterText("$targetText", value="$value")',
//     );
//     bool tapped = await toolFindElementAndTap(
//       ctx,
//       targetText,
//       targetInstance: targetInstance,
//     );
//     if (!tapped) return false;

//     await Future.delayed(
//       const Duration(milliseconds: 300),
//     ); // wait for keyboard
//     await _enterTextAtFocused(value);

//     final typingMs = value.length * 150 + 100;
//     await Future.delayed(Duration(milliseconds: typingMs));
//     await _dismissSoftKeyboard();
//     await Future.delayed(const Duration(milliseconds: 300));
//     return true;
//   }

//   /// Generic function tool: Select value from dropdown
//   Future<bool> toolSelectDropdown(
//     UIContext ctx,
//     String dropdownLabel,
//     String optionText,
//   ) async {
//     debugPrint(
//       '[Yad2-Gemma] Tool: toolSelectDropdown("$dropdownLabel", "$optionText")',
//     );
//     bool opened = await toolFindElementAndTap(ctx, dropdownLabel, deltaY: 10);
//     if (!opened) return false;

//     await Future.delayed(const Duration(milliseconds: 1000));
//     final newCtx = await _observeUIWithPopupHandling();
//     if (newCtx == null) return false;

//     bool selected = await toolFindElementAndTap(newCtx, optionText);
//     if (!selected) {
//       // bool ocrSelected = await toolOcrFindAndTap(newCtx, optionText);
//       // if (!ocrSelected) return false;
//       return false;
//     }
//     await Future.delayed(const Duration(milliseconds: 500));
//     return true;
//   }

//   /// Generic function tool: OCR Fallback
//   Future<bool> toolOcrFindAndTap(
//     UIContext ctx,
//     String targetText, {
//     int targetInstance = 1,
//     double deltaY = 0,
//   }) async {
//     debugPrint(
//       '[Yad2-Gemma] Tool: toolOcrFindAndTap("$targetText", instance=$targetInstance)',
//     );
//     onOcrFallback?.call();
//     final isMultiWord = targetText.contains(' ') && !targetText.contains('|');
//     final raw =
//         isMultiWord
//             ? await ocrService.findMultiWordPhrase(
//               ctx.screenshot,
//               targetText,
//               targetInstance: targetInstance,
//             )
//             : await ocrService.findTextLocation(
//               ctx.screenshot,
//               targetText,
//               targetInstance: targetInstance,
//             );

//     if (raw != null) {
//       final loc = _toCssLocation(raw);
//       await _tapAt(loc.centerX, loc.centerY + deltaY);
//       return true;
//     }
//     return false;
//   }

//   /// Screen Analyzer Tool: Invoked when flow stops
//   Future<void> _handleBlockedFlow(
//     AutomationPhase phase,
//     String errorContext,
//   ) async {
//     debugPrint(
//       '[Yad2-Gemma] Tool: toolAnalyzeScreenBlock (Phase: ${phase.name})',
//     );

//     WakelockPlus.disable();

//     // Immediately pause and alert the user to interact
//     await _handleError(
//       phase,
//       'Stuck: $errorContext. Please help and tap Resume.',
//     );

//     final ctx = await observeUI();
//     if (ctx == null) return;

//     final prompt = """
//     The automation flow is stuck at phase: ${phase.name}.
//     Error context: $errorContext.
//     Look at the screen. What is blocking the flow? Is there a captcha, a login screen, an error message, or a missing element?
//     If there is a simple button to dismiss an error, what is its text?
//     """;

//     final response = await gemmaService.askGemmaAboutImage(
//       ctx.screenshot,
//       prompt,
//     );
//     debugPrint('[Yad2-Gemma] Analysis Result: $response');

//     // If still paused, update the error message with Gemma's insight
//     if (_isPaused) {
//       onPhaseError?.call(
//         phase,
//         'Gemma Analysis: ${response ?? 'No conclusive result.'}',
//       );
//     }
//   }

//   // ── Helper Tools ────────────────────────────────────────────────────────

//   Future<UIContext?> _observeUIWithPopupHandling() async {
//     final ctx = await observeUI();
//     if (ctx == null) return null;

//     final dismissed = await _dismissGotItPopup(ctx);
//     if (dismissed) {
//       debugPrint('[Yad2-Gemma] 🔄 Re-observing UI after dismissing popup');
//       return observeUI();
//     }
//     return ctx;
//   }

//   Future<bool> _dismissGotItPopup(UIContext ctx) async {
//     // Adding the comma so it EXACTLY matches the button's text: "עדכנתי, בואו נמשיך".
//     // This prevents falling back to a substring match which accidentally clicks the popup container!
//     const popupTexts = [
//       'הבנתי',
//       'עדכנתי, בואו נמשיך|עדכנתי, בוא נמשיך',
//       'עדכנתי בואו נמשיך',
//     ];
//     for (var text in popupTexts) {
//       // Added deltaY: -15 to shift the click slightly upwards since the click was hitting below the button
//       if (await toolFindElementAndTap(ctx, text, deltaY: -15)) {
//         await Future.delayed(const Duration(milliseconds: 1500));
//         return true;
//       }
//     }
//     return false;
//   }

//   // ── Phase Implementations ────────────────────────────────────────────────

//   Future<void> _phase1SelectVehicleType() async {
//     final ctx = await _observeUIWithPopupHandling();
//     if (ctx == null) return _handleRetry(AutomationPhase.phase1, 'UI null');

//     if (await toolFindElementAndTap(ctx, 'פרטיים ומסחריים')) {
//       onFirstStepDetected?.call();
//       _handlePhaseComplete(AutomationPhase.phase1);
//     } /* else if (await toolOcrFindAndTap(ctx, 'פרטיים ומסחריים')) {
//       onFirstStepDetected?.call();
//       _handlePhaseComplete(AutomationPhase.phase1);
//     } */ else {
//       throw Exception('Could not find vehicle type button');
//     }
//   }

//   Future<void> _phase2EnterLicenseAndSearch() async {
//     final ctx = await _observeUIWithPopupHandling();
//     if (ctx == null) return _handleRetry(AutomationPhase.phase2, 'UI null');

//     // Handle reset popup ("resume existing publication" popup)
//     if (await toolFindElementAndTap(ctx, 'התחלה מחדש|מחדש')) {
//       debugPrint(
//         '[Yad2-Gemma] ⚠️ Reset popup found — tapped "מחדש" to start over.',
//       );
//       await Future.delayed(const Duration(milliseconds: 2300));
//       _processPhase(AutomationPhase.phase1);
//       return;
//     }

//     final licenseText =
//         formData.licenseNumber.isNotEmpty ? formData.licenseNumber : '5211639';
//     if (!await toolEnterText(ctx, '00-000-00', licenseText)) {
//       throw Exception('License input field not found');
//     }

//     /*
//     if (!await toolOcrFindAndTap(ctx, 'חיפוש', targetInstance: 2)) {
//       throw Exception('Search button not found');
//     }
//     */
//     // Use Shadow DOM instead:
//     if (!await toolFindElementAndTap(ctx, 'חיפוש', targetInstance: 1)) {
//       throw Exception('Search button not found');
//     }

//     _handlePhaseComplete(AutomationPhase.phase2);
//   }

//   Future<void> _phase3SubmitVehicleLookup() async {
//     final ctx = await _observeUIWithPopupHandling();
//     if (ctx == null) return _handleRetry(AutomationPhase.phase3, 'UI null');

//     if (!await toolFindElementAndTap(
//       ctx,
//       'לשלב',
//     ) /* && !await toolOcrFindAndTap(ctx, 'לשלב') */ ) {
//       throw Exception('Submit button לשלב not found');
//     }
//     _handlePhaseComplete(AutomationPhase.phase3);
//   }

//   // ── Phase 4 — Open color dropdown ─────────────────────────────────────────

//   Future<void> _phase4OpenColorDropdown() async {
//     for (int i = 0; i < 3; i++) {
//       final ctx = await _observeUIWithPopupHandling();
//       if (ctx == null) continue;

//       if (!await toolFindElementAndTap(
//         ctx,
//         formData.color,
//         deltaY: 0,
//         retryIndex: i,
//       )) {
//         continue;
//       }
//       await Future.delayed(const Duration(milliseconds: 1000));

//       // Verify dropdown opened by checking if there are now 2 instances of formData.color
//       final checkCtx = await _observeUIWithPopupHandling();
//       if (checkCtx != null) {
//         if (checkCtx.findAllByLabel(formData.color).length >= 2) {
//           _handlePhaseComplete(AutomationPhase.phase4);
//           return;
//         } else {
//           debugPrint(
//             '[Yad2-Gemma] ⚠️ Color dropdown did not open. Retrying...',
//           );
//         }
//       }
//     }
//     throw Exception('Color dropdown failed to open');
//   }

//   // ── Phase 5 — Select color shade ──────────────────────────────────────────

//   Future<void> _phase5SelectColorShade() async {
//     await _scrollDown(0.25);
//     for (int i = 0; i < 3; i++) {
//       final ctx = await _observeUIWithPopupHandling();
//       if (ctx == null) continue;

//       if (!await toolFindElementAndTap(
//         ctx,
//         formData.color,
//         targetInstance: 2,
//         retryIndex: i,
//         isListValue: true,
//       )) {
//         continue;
//       }
//       await Future.delayed(const Duration(milliseconds: 1000));

//       // After clicking the shade option, the dropdown closes.
//       // The shade label now displays the selected color (e.g., "כחול"),
//       // meaning there are STILL 2 instances of "כחול" on the screen (the Color label and the Shade label).
//       // Therefore, we cannot rely on checking if length <= 1.
//       _handlePhaseComplete(AutomationPhase.phase5);
//       return;
//     }
//     throw Exception('Color shade option failed to click');
//   }

//   // ── Phase 5a — Open month dropdown ────────────────────────────────────────

//   Future<void> _phase5aOpenMonthDropdown() async {
//     await _scrollDown(0.7);
//     final monthHebrew = VehiclePublishData.monthToHebrew(formData.month);
//     final monthSearch =
//         monthHebrew != formData.month.trim()
//             ? '$monthHebrew|${formData.month.trim()}'
//             : monthHebrew;

//     // Prior check: skip if month is already set
//     final ctxCheck = await _observeUIWithPopupHandling();
//     if (ctxCheck != null) {
//       final months = [
//         'ינואר',
//         'פברואר',
//         'מרץ',
//         'אפריל',
//         'מאי',
//         'יוני',
//         'יולי',
//         'אוגוסט',
//         'ספטמבר',
//         'אוקטובר',
//         'נובמבר',
//         'דצמבר',
//       ];
//       bool isMonthSet = false;
//       for (final el in ctxCheck.axTree) {
//         if (!el.visible) continue;
//         final labelNorm = el.label.trim();
//         final valueNorm = el.value?.trim() ?? '';
//         final roleLower = el.role.toLowerCase();
//         final idLower = (el.id ?? '').toLowerCase();

//         if (idLower == 'testmonth' || idLower.contains('test')) continue;
//         if (roleLower == 'option' ||
//             roleLower == 'listitem' ||
//             roleLower == 'menuitem')
//           continue;

//         final isMonthFieldLabel =
//             labelNorm.contains('חודש') ||
//             labelNorm.contains('עלייה') ||
//             labelNorm.contains('עליה');
//         if (isMonthFieldLabel && months.contains(valueNorm)) {
//           isMonthSet = true;
//           break;
//         }

//         if (months.contains(labelNorm) || months.contains(valueNorm)) {
//           const inputRoles = {
//             'text',
//             'input',
//             'select',
//             'textbox',
//             'combobox',
//             'button',
//           };
//           if (inputRoles.contains(roleLower) ||
//               roleLower.contains('input') ||
//               roleLower.contains('select')) {
//             isMonthSet = true;
//             break;
//           }
//         }
//       }

//       if (isMonthSet) {
//         debugPrint(
//           '[Yad2-Gemma] ⏭️ Month value is already set in the shadow tree. Skipping month selection steps.',
//         );
//         // We skip Phase 5a and Phase 5b
//         _handlePhaseComplete(AutomationPhase.phase5b);
//         return;
//       }
//     }

//     for (int i = 0; i < 3; i++) {
//       final ctx = await _observeUIWithPopupHandling();
//       if (ctx == null) continue;

//       if (!await toolFindElementAndTap(
//         ctx,
//         'חודש עלייה לכביש|חודש עליה לכביש',
//         deltaY: 10,
//         retryIndex: i,
//       )) {
//         continue;
//       }
//       await Future.delayed(const Duration(milliseconds: 1000));

//       // Verify options are visible
//       final checkCtx = await _observeUIWithPopupHandling();
//       if (checkCtx != null && checkCtx.findAllByLabel(monthSearch).isNotEmpty) {
//         _handlePhaseComplete(AutomationPhase.phase5a);
//         return;
//       } else {
//         debugPrint('[Yad2-Gemma] ⚠️ Month dropdown did not open. Retrying...');
//       }
//     }
//     throw Exception('Month dropdown failed to open');
//   }

//   // ── Phase 5b — Select month value ─────────────────────────────────────────

//   Future<void> _phase5bSelectMonthValue() async {
//     final monthHebrew = VehiclePublishData.monthToHebrew(formData.month);
//     final monthSearch =
//         monthHebrew != formData.month.trim()
//             ? '$monthHebrew|${formData.month.trim()}'
//             : monthHebrew;

//     for (int i = 0; i < 3; i++) {
//       final ctx = await _observeUIWithPopupHandling();
//       if (ctx == null) continue;

//       if (!await toolFindElementAndTap(
//         ctx,
//         monthSearch,
//         deltaY: 10,
//         retryIndex: i,
//         isListValue: true,
//       )) {
//         continue;
//       }
//       await Future.delayed(const Duration(milliseconds: 1000));

//       // Verify closed (options no longer visible)
//       final checkCtx = await _observeUIWithPopupHandling();
//       if (checkCtx != null &&
//           checkCtx
//               .findAllByLabel('חודש עלייה לכביש|חודש עליה לכביש')
//               .isNotEmpty) {
//         // Since we don't have a reliable way to check if option is gone (label could overlap), we just check if it proceeded
//         // Actually, let's just assume it closed if we tapped it successfully, or if we can verify the text box value updated.
//         _handlePhaseComplete(AutomationPhase.phase5b);
//         return;
//       }
//     }
//     throw Exception('Month value option not found');
//   }

//   // ── Phase 6 — Open hand dropdown ──────────────────────────────────────────

//   Future<void> _phase6OpenHandDropdown() async {
//     await _scrollDown(0.25);
//     final handFull =
//         formData.hand.startsWith('יד') ? formData.hand : 'יד ${formData.hand}';
//     final handParts = handFull.split(' ');
//     final handSearch =
//         handParts.length > 1 ? '$handFull|${handParts.last}' : handFull;

//     for (int i = 0; i < 3; i++) {
//       final ctx = await _observeUIWithPopupHandling();
//       if (ctx == null) continue;

//       if (!await toolFindElementAndTap(
//         ctx,
//         'בחירת יד',
//         deltaY: 10,
//         retryIndex: i,
//       )) {
//         continue;
//       }
//       await Future.delayed(const Duration(milliseconds: 1000));

//       // Verify option is visible
//       final checkCtx = await _observeUIWithPopupHandling();
//       if (checkCtx != null && checkCtx.findAllByLabel(handSearch).isNotEmpty) {
//         _handlePhaseComplete(AutomationPhase.phase6);
//         return;
//       } else {
//         debugPrint('[Yad2-Gemma] ⚠️ Hand dropdown did not open. Retrying...');
//       }
//     }
//     throw Exception('Hand dropdown label not found');
//   }

//   // ── Phase 7 — Select hand value ───────────────────────────────────────────

//   Future<void> _phase7SelectHandValue() async {
//     final handFull =
//         formData.hand.startsWith('יד') ? formData.hand : 'יד ${formData.hand}';
//     final handParts = handFull.split(' ');
//     final handSearch =
//         handParts.length > 1 ? '$handFull|${handParts.last}' : handFull;

//     for (int i = 0; i < 3; i++) {
//       final ctx = await _observeUIWithPopupHandling();
//       if (ctx == null) continue;

//       if (!await toolFindElementAndTap(
//         ctx,
//         handSearch,
//         deltaY: 10,
//         retryIndex: i,
//         isListValue: true,
//       )) {
//         continue;
//       }
//       await Future.delayed(const Duration(milliseconds: 1000));

//       final checkCtx = await _observeUIWithPopupHandling();
//       if (checkCtx != null && checkCtx.findAllByLabel('בחירת יד').isNotEmpty) {
//         _handlePhaseComplete(AutomationPhase.phase7);
//         return;
//       }
//     }
//     throw Exception('Hand value option not found');
//   }

//   Future<void> _phase8OpenCurrentOwnershipDropdown() async {
//     await _scrollDown(0.25);
//     for (int i = 0; i < 3; i++) {
//       final ctx = await _observeUIWithPopupHandling();
//       if (ctx == null) continue;

//       if (!await toolFindElementAndTap(
//         ctx,
//         'בעלות נוכחית',
//         deltaY: 10,
//         retryIndex: i,
//       )) {
//         continue;
//       }
//       await Future.delayed(const Duration(milliseconds: 1000));

//       final checkCtx = await _observeUIWithPopupHandling();
//       if (checkCtx != null &&
//           checkCtx.findAllByLabel(formData.currentOwnership).isNotEmpty) {
//         _handlePhaseComplete(AutomationPhase.phase8);
//         return;
//       } else {
//         debugPrint(
//           '[Yad2-Gemma] ⚠️ Current ownership dropdown did not open. Retrying...',
//         );
//       }
//     }
//     throw Exception('Current ownership dropdown label not found');
//   }

//   Future<void> _phase9SelectCurrentOwnershipValue() async {
//     for (int i = 0; i < 3; i++) {
//       final ctx = await _observeUIWithPopupHandling();
//       if (ctx == null) continue;

//       if (!await toolFindElementAndTap(
//         ctx,
//         formData.currentOwnership,
//         deltaY: 10,
//         retryIndex: i,
//         isListValue: true,
//       )) {
//         continue;
//       }
//       await Future.delayed(const Duration(milliseconds: 1000));

//       final checkCtx = await _observeUIWithPopupHandling();
//       if (checkCtx != null &&
//           checkCtx.findAllByLabel('בעלות נוכחית').isNotEmpty) {
//         _handlePhaseComplete(AutomationPhase.phase9);
//         return;
//       }
//     }
//     throw Exception('Current ownership value option not found');
//   }

//   Future<void> _phase10OpenPreviousOwnershipDropdown() async {
//     //await _scrollDown(0.25);
//     for (int i = 0; i < 3; i++) {
//       final ctx = await _observeUIWithPopupHandling();
//       if (ctx == null) continue;

//       if (!await toolFindElementAndTap(
//         ctx,
//         'בעלות מקורית',
//         deltaY: 10,
//         retryIndex: i,
//       )) {
//         continue;
//       }
//       await Future.delayed(const Duration(milliseconds: 1000));

//       final checkCtx = await _observeUIWithPopupHandling();
//       if (checkCtx != null &&
//           checkCtx.findAllByLabel(formData.previousOwnership).isNotEmpty) {
//         _handlePhaseComplete(AutomationPhase.phase10);
//         return;
//       } else {
//         debugPrint(
//           '[Yad2-Gemma] ⚠️ Previous ownership dropdown did not open. Retrying...',
//         );
//       }
//     }
//     throw Exception('Previous ownership dropdown label not found');
//   }

//   Future<void> _phase11SelectPreviousOwnershipValue() async {
//     for (int i = 0; i < 3; i++) {
//       final ctx = await _observeUIWithPopupHandling();
//       if (ctx == null) continue;

//       // If the previous ownership value is exactly the same as the current ownership value
//       // (e.g. both are "פרטית"), then the first instance on the screen will be the
//       // already-selected value in the Current Ownership field. We must tap the 2nd instance!
//       final targetInstance =
//           (formData.previousOwnership == formData.currentOwnership) ? 2 : 1;

//       if (!await toolFindElementAndTap(
//         ctx,
//         formData.previousOwnership,
//         deltaY: 10,
//         retryIndex: i,
//         targetInstance: targetInstance,
//         isListValue: true,
//       )) {
//         continue;
//       }
//       await Future.delayed(const Duration(milliseconds: 1000));

//       final checkCtx = await _observeUIWithPopupHandling();
//       if (checkCtx != null &&
//           checkCtx.findAllByLabel('בעלות מקורית').isNotEmpty) {
//         _handlePhaseComplete(AutomationPhase.phase11);
//         return;
//       }
//     }
//     throw Exception('Previous ownership value option not found');
//   }

//   Future<void> _phase12EnterKilometers() async {
//     final ctx = await _observeUIWithPopupHandling();
//     if (ctx == null) return _handleRetry(AutomationPhase.phase12, 'UI null');

//     if (!await toolEnterText(ctx, 'קילומטראז', formData.kilometers)) {
//       /*
//       if (!await toolOcrFindAndTap(ctx, 'קילומטראז')) {
//         throw Exception('Kilometers input field not found');
//       }
//       */
//       throw Exception('Kilometers input field not found');
//       // await Future.delayed(const Duration(milliseconds: 300));
//       // await _enterTextAtFocused(formData.kilometers);
//       // await _dismissSoftKeyboard();
//     }
//     _handlePhaseComplete(AutomationPhase.phase12);
//   }

//   Future<void> _phase13ScrollToTop() async {
//     // await _scrollDown(0.25);
//     // await Future.delayed(const Duration(milliseconds: 800));
//     _handlePhaseComplete(AutomationPhase.phase13);
//   }

//   Future<void> _phase14EnterAdditionalInfo() async {
//     // 1. Check for PRE-submit popup
//     final prePopupCtx = await _observeUIWithPopupHandling();
//     if (prePopupCtx != null) {
//       debugPrint('[Yad2-Gemma] 🔍 Checking for pre-submit popup...');
//       for (final el in prePopupCtx.axTree) {
//         if (el.label.contains('עדכנתי')) {
//           debugPrint(
//             '[Yad2-Gemma] 👀 Found potential PRE-popup: "${el.label}" (role: ${el.role})',
//           );
//         }
//       }
//       if (await toolFindElementAndTap(
//         prePopupCtx,
//         'עדכנתי, בוא נמשיך|עדכנתי|בוא נמשיך',
//         deltaY: -15,
//       )) {
//         debugPrint(
//           '[Yad2-Gemma] 👆 Tapped "עדכנתי בוא נמשיך" popup button before submit...',
//         );
//         await Future.delayed(const Duration(milliseconds: 1200));
//         await _scrollDown(0.75);
//       }
//     }

//     await _scrollDown(0.75);
//     final postScrollCtx = await _observeUIWithPopupHandling();
//     if (postScrollCtx == null) throw Exception('UI null after scroll');

//     // 2. Tap submit button (Use tighter regex to avoid text-area placeholder)
//     debugPrint('[Yad2-Gemma] 🔍 Searching for "לשלב הבא" submit button...');
//     if (!await toolFindElementAndTap(postScrollCtx, 'לשלב הבא|שלב הבא')) {
//       throw Exception('Submit button לשלב הבא not found');
//     }

//     // Increased delay from 800ms to 1500ms to give the popup time to animate in!
//     await Future.delayed(const Duration(milliseconds: 1500));

//     // 3. Check for POST-submit popup
//     // 🚨 CRITICAL FIX: Use raw observeUI() instead of _observeUIWithPopupHandling() here!
//     // Otherwise, the global handler will dismiss the popup silently, and this manual code block
//     // will never know the popup existed, meaning it will NEVER re-click the submit button!
//     debugPrint('[Yad2-Gemma] 🔍 Observing UI for post-submit popup...');
//     final postSubmitCtx = await observeUI();
//     if (postSubmitCtx != null) {
//       for (final el in postSubmitCtx.axTree) {
//         if (el.label.contains('עדכנתי')) {
//           debugPrint(
//             '[Yad2-Gemma] 👀 Found potential POST-popup: "${el.label}" (role: ${el.role})',
//           );
//         }
//       }

//       // 🚨 CRITICAL FIX: Adding the "ו" to "בואו" so it exactly matches "עדכנתי, בואו נמשיך".
//       // Without the vav, it falls back to substring matching "עדכנתי" and taps the popup container instead of the button!
//       if (await toolFindElementAndTap(
//         postSubmitCtx,
//         'עדכנתי, בואו נמשיך|עדכנתי, בוא נמשיך',
//         deltaY: -15,
//       )) {
//         debugPrint(
//           '[Yad2-Gemma] 👆 Tapped "עדכנתי בואו נמשיך" popup button post-submit...',
//         );
//         await Future.delayed(
//           const Duration(milliseconds: 1500),
//         ); // Increased wait for dismiss animation

//         // Scrolling back down because dismissing the popup resets the scroll position to the top!
//         debugPrint(
//           '[Yad2-Gemma] 📜 Scrolling down to find the submit button again...',
//         );
//         await _scrollDown(0.75);
//         await Future.delayed(const Duration(milliseconds: 500));
//         await _scrollDown(0.5);
//         await Future.delayed(const Duration(milliseconds: 500));

//         debugPrint(
//           '[Yad2-Gemma] 📸 Fetching fresh DOM for submit button latest position...',
//         );
//         // Using observeUI() here too so we don't accidentally trigger a global popup loop
//         final postPopupCtx = await observeUI();
//         if (postPopupCtx != null) {
//           if (await toolFindElementAndTap(
//             postPopupCtx,
//             'לשלב הבא|שלב הבא',
//             deltaY: 10,
//           )) {
//             debugPrint(
//               '[Yad2-Gemma] 👆 Tapped "לשלב הבא" submit button again...',
//             );
//             await Future.delayed(const Duration(milliseconds: 1200));
//           } else {
//             debugPrint('[Yad2-Gemma] ❌ Could not find "לשלב הבא" after popup!');
//           }
//         }
//       } else {
//         debugPrint(
//           '[Yad2-Gemma] 🔍 POST-submit popup not detected or tapped. Proceeding...',
//         );
//       }
//     }

//     _handlePhaseComplete(AutomationPhase.phase14);
//   }

//   Future<void> _phase15EnterPrice() async {
//     final ctx = await _observeUIWithPopupHandling();
//     if (ctx == null) return _handleRetry(AutomationPhase.phase15, 'UI null');

//     final priceText = formData.price.isNotEmpty ? formData.price : '80000';

//     // Try via shadow tree explicit input lookup first or fallback to enterText
//     var priceTarget =
//         ctx.findInput(id: 'price') ??
//         ctx.findInput(placeholder: 'מחיר') ??
//         ctx.findInput(placeholder: 'סכום');
//     if (priceTarget != null) {
//       await _tapAt(priceTarget.x, priceTarget.y);
//       await Future.delayed(const Duration(milliseconds: 300));
//       await _enterTextAtFocused(priceText);
//       await _dismissSoftKeyboard();
//       await Future.delayed(const Duration(milliseconds: 300));
//     } else {
//       if (!await toolEnterText(ctx, 'מחיר|סכום מינימלי|סכום', priceText)) {
//         throw Exception('Price input field not found');
//       }
//     }
//     _handlePhaseComplete(AutomationPhase.phase15);
//   }

//   Future<void> _phase16SelectCity() async {
//     await _scrollDown(0.4);
//     final ctx = await _observeUIWithPopupHandling();
//     if (ctx == null) return _handleRetry(AutomationPhase.phase16, 'UI null');

//     final cityVal = formData.city.isNotEmpty ? formData.city : 'חיפה';
//     final typedVal =
//         cityVal.length > 1 ? cityVal.substring(0, cityVal.length - 1) : cityVal;

//     // Use robust input finding logic matching yad2_automation_service.dart
//     bool inputFound = false;
//     var cityTarget =
//         ctx.findInput(placeholder: 'ישוב') ??
//         ctx.findInput(placeholder: 'יישוב') ??
//         ctx.findInput(placeholder: 'הזינו טקסט') ??
//         ctx.findInput(placeholder: 'הזינן טקסט') ??
//         ctx.findInput(placeholder: 'הזינו') ??
//         ctx.findInput(placeholder: 'הזינן') ??
//         ctx.findInput(placeholder: 'טקסט') ??
//         ctx.findInput(id: 'city');

//     if (cityTarget == null) {
//       // Fallback: search for elements with label "ישוב" or "יישוב" or "ישוב*"
//       final matches = ctx.findAllByLabel('ישוב|יישוב|ישוב*|ישוב *|city');
//       if (matches.isNotEmpty) {
//         final match = matches.first;
//         final deltaY =
//             match.role == 'StaticText' || match.role == 'Label' ? 15.0 : 0.0;
//         cityTarget = AxElement(
//           id: match.id,
//           role: match.role,
//           label: match.label,
//           x: match.x,
//           y: match.y + deltaY,
//           visible: match.visible,
//         );
//       }
//     }

//     if (cityTarget != null) {
//       debugPrint(
//         '[Yad2-Gemma] 🎯 Tapping City input at (${cityTarget.x}, ${cityTarget.y})',
//       );
//       await _tapAt(cityTarget.x, cityTarget.y);
//       inputFound = true;
//     } else {
//       inputFound = await toolFindElementAndTap(ctx, 'ישוב|יישוב|city');
//     }

//     if (!inputFound) throw Exception('City input not found');

//     await Future.delayed(const Duration(milliseconds: 300));
//     await _enterTextAtFocused(typedVal);
//     await Future.delayed(Duration(milliseconds: typedVal.length * 150 + 100));

//     final dropdownCtx = await _observeUIWithPopupHandling();
//     if (dropdownCtx != null) {
//       if (await toolFindElementAndTap(dropdownCtx, cityVal)) {
//         await Future.delayed(const Duration(milliseconds: 1000));
//         await _dismissSoftKeyboard();

//         // click submit
//         await _scrollDown(0.75);
//         final postScrollCtx = await _observeUIWithPopupHandling();
//         if (postScrollCtx != null) {
//           if (await toolFindElementAndTap(
//             postScrollCtx,
//             'לשלב הבא|שלב הבא|לשלב',
//           ) /* || await toolOcrFindAndTap(postScrollCtx, 'לשלב הבא|שלב הבא|לשלב') */ ) {
//             _handlePhaseComplete(AutomationPhase.phase16);
//             return;
//           }
//         }
//       }
//     }

//     throw Exception('Could not select "$cityVal" from suggestion list');
//   }

//   Future<void> _phase17() async {
//     final ctx = await _observeUIWithPopupHandling();
//     if (ctx == null) return _handleRetry(AutomationPhase.phase17, 'UI null');

//     // Skipping explicit file upload through JS for brevity in Gemma flow (requires JS bridge logic)
//     // You can replicate the JS logic from original if needed.
//     debugPrint(
//       '[Yad2-Gemma] Upload Photos phase reached. Proceeding to submit.',
//     );

//     await _scrollDown(0.75);
//     final postScrollCtx = await _observeUIWithPopupHandling();
//     if (postScrollCtx == null) throw Exception('UI null');

//     if (!await toolFindElementAndTap(
//       postScrollCtx,
//       'לשלב הבא|שלב הבא|המשך|לשלב',
//     ) /* && !await toolOcrFindAndTap(postScrollCtx, 'לשלב הבא|שלב הבא|המשך|לשלב') */ ) {
//       throw Exception('Submit button not found on photos page');
//     }

//     _handlePhaseComplete(AutomationPhase.phase17);
//   }

//   // ── Flow Controllers ──────────────────────────────────────────────────────

//   void _handlePhaseComplete(AutomationPhase phase) {
//     debugPrint('[Yad2-Gemma] ✅ Phase complete: ${phase.description}');
//     onPhaseComplete?.call(phase);

//     AutomationPhase? next;
//     int delayMs = 1000;

//     switch (phase) {
//       case AutomationPhase.phase1:
//         next = AutomationPhase.phase2;
//         delayMs = 1500;
//       case AutomationPhase.phase2:
//         next = AutomationPhase.phase3;
//         delayMs = 2500;
//       case AutomationPhase.phase3:
//         next = AutomationPhase.phase4;
//         delayMs = 3000;
//       case AutomationPhase.phase4:
//         next = AutomationPhase.phase5;
//       case AutomationPhase.phase5:
//         next = AutomationPhase.phase5a;
//         delayMs = 1500;
//       case AutomationPhase.phase5a:
//         next = AutomationPhase.phase5b;
//         delayMs = 1500;
//       case AutomationPhase.phase5b:
//         next = AutomationPhase.phase6;
//         delayMs = 1000;
//       case AutomationPhase.phase6:
//         next = AutomationPhase.phase7;
//         delayMs = 1500;
//       case AutomationPhase.phase7:
//         next = AutomationPhase.phase8;
//         delayMs = 1000;
//       case AutomationPhase.phase8:
//         next = AutomationPhase.phase9;
//         delayMs = 1500;
//       case AutomationPhase.phase9:
//         final handTrimmed = formData.hand.trim();
//         final isFirstHand = [
//           'ראשונה',
//           'יד ראשונה',
//           '1',
//           'יד 1',
//           'ראשון',
//         ].contains(handTrimmed);
//         next = isFirstHand ? AutomationPhase.phase12 : AutomationPhase.phase10;
//       case AutomationPhase.phase10:
//         next = AutomationPhase.phase11;
//       case AutomationPhase.phase11:
//         next = AutomationPhase.phase12;
//       case AutomationPhase.phase12:
//         next = AutomationPhase.phase13;
//       case AutomationPhase.phase13:
//         next = AutomationPhase.phase14;
//         delayMs = 2500;
//       case AutomationPhase.phase14:
//         next = AutomationPhase.phase15;
//         delayMs = 3000;
//       case AutomationPhase.phase15:
//         next = AutomationPhase.phase16;
//         delayMs = 2500;
//       case AutomationPhase.phase16:
//         next = AutomationPhase.phase17;
//         delayMs = 3000;
//       case AutomationPhase.phase17:
//         next = AutomationPhase.complete;
//         delayMs = 1500;
//       case AutomationPhase.complete:
//         onAutomationComplete?.call(true);
//         return;
//     }

//     Future.delayed(Duration(milliseconds: delayMs), () {
//       _processPhase(next!);
//     });
//   }

//   Future<void> _handleError(AutomationPhase phase, String error) async {
//     debugPrint('[Yad2-Gemma] ❌ Phase error: ${phase.description} — $error');
//     _isPaused = true;
//     _pausedPhase = phase;
//     _phaseRetryCount = 0;
//     try {
//       await _beepUser();
//     } catch (e) {
//       debugPrint('[Yad2-Gemma] Error playing error beep: $e');
//     }
//     onPhaseError?.call(phase, error);
//   }

//   void _handleRetry(AutomationPhase phase, String reason) {
//     if (_isPaused) {
//       _pausedPhase = phase;
//       return;
//     }
//     if (_phaseRetryCount < _maxRetries) {
//       _phaseRetryCount++;
//       debugPrint(
//         '[Yad2-Gemma] 🔄 Retrying phase $_phaseRetryCount/$_maxRetries — $reason',
//       );
//       Future.delayed(const Duration(milliseconds: 1000), () {
//         _executePhase(phase);
//       });
//     } else {
//       _handleError(phase, reason);
//     }
//   }

//   Future<void> _beepUser() async {
//     debugPrint('[Yad2-Gemma] 🔔 Beeping user for manual interaction');
//     bool assetPlayed = false;
//     try {
//       final player = AudioPlayer();
//       final candidates = ['beep.mp3', 'beep.wav', 'alert.mp3', 'alert.wav'];
//       for (final asset in candidates) {
//         try {
//           await player
//               .play(AssetSource(asset))
//               .timeout(const Duration(seconds: 2));
//           assetPlayed = true;
//           break;
//         } catch (_) {}
//       }
//     } catch (e) {}

//     if (!assetPlayed) {
//       try {
//         for (int i = 0; i < 3; i++) {
//           await SystemSound.play(SystemSoundType.click);
//           await Future.delayed(const Duration(milliseconds: 100));
//         }
//       } catch (_) {}
//     }
//     try {
//       await HapticFeedback.vibrate();
//     } catch (_) {}
//   }

//   // ── Lower-level Helpers (from original) ───────────────────────────────────

//   Future<void> _tapAt(
//     double cssX,
//     double cssY, {
//     int hangMs = 200,
//     bool isListValue = false,
//   }) async {
//     onTapPreview?.call(cssX, cssY);
//     await Future.delayed(const Duration(milliseconds: 300));

//     // UNIFIED ROBUST LOGIC FOR ALL TAPS
//     // Includes React fiber injection and ancestor walks for popups.
//     // Force-close outside click is ONLY applied if isListValue is true.
//     await controller.runJavaScript('''
//       (function() {
//         var x = $cssX, y = $cssY;
//         var el = document.elementFromPoint(x, y);
//         if (!el) return;
        
//         while (el.shadowRoot) {
//           var inner = el.shadowRoot.elementFromPoint(x, y);
//           if (!inner || inner === el) break;
//           el = inner;
//         }
        
//         var eOpts = { bubbles:true, cancelable:true, clientX:x, clientY:y, screenX:x, screenY:y };
//         var touch = new Touch({ identifier: Date.now(), target: el, clientX: x, clientY: y, screenX: x, screenY: y, pageX: x, pageY: y });

//         el.dispatchEvent(new TouchEvent('touchstart', { bubbles: true, cancelable: true, touches: [touch], targetTouches: [touch], changedTouches: [touch] }));
//         el.dispatchEvent(new MouseEvent('mousedown', eOpts));
//         if (el.tagName === 'INPUT' || el.tagName === 'TEXTAREA') el.focus();

//         function finishTap() {
//           el.dispatchEvent(new TouchEvent('touchend', { bubbles: true, cancelable: true, changedTouches: [touch] }));
//           el.dispatchEvent(new MouseEvent('mouseup', eOpts));
//           el.dispatchEvent(new MouseEvent('click', eOpts));
//           try { el.click(); } catch(e) {}
          
//           try {
//             var fiberKey = Object.keys(el).find(function(k) { return k.startsWith('__reactFiber') || k.startsWith('__reactInternalInstance'); });
//             if (fiberKey) {
//               var fiber = el[fiberKey];
//               while (fiber) {
//                 var props = fiber.memoizedProps || fiber.pendingProps;
//                 if (props && typeof props.onClick === 'function') {
//                   props.onClick({ type:'click', target:el, currentTarget:el, clientX:x, clientY:y, bubbles:true, preventDefault:function(){}, stopPropagation:function(){} });
//                   break;
//                 }
//                 fiber = fiber.return;
//               }
//             }
//           } catch(e) {}
          
//           try {
//             var walk = el.parentElement;
//             for (var i = 0; i < 4; i++) {
//               if (!walk || walk === document.body) break;
//               walk.dispatchEvent(new TouchEvent('touchstart', { bubbles:true, cancelable:true, composed:true, touches:[new Touch({identifier:Date.now()+i+1, target:walk, clientX:x, clientY:y, screenX:x, screenY:y, pageX:x+window.scrollX, pageY:y+window.scrollY, radiusX:11.5,radiusY:11.5,rotationAngle:0,force:1})], targetTouches:[], changedTouches:[] }));
//               walk.dispatchEvent(new TouchEvent('touchend', { bubbles:true, cancelable:true, composed:true, touches:[], targetTouches:[], changedTouches:[] }));
//               walk.dispatchEvent(new MouseEvent('click', eOpts));
//               walk = walk.parentElement;
//             }
//           } catch(e) {}
          
//           if ($isListValue) {
//             try {
//               var tag = el.tagName;
//               if (tag !== 'INPUT' && tag !== 'TEXTAREA') {
//                 el.blur();
//                 var safeX = x < 10 ? x + 5 : x - 5;
//                 var safeY = y < 10 ? y + 5 : y - 5;
//                 var outsideOpts = { bubbles: true, cancelable: true, clientX: safeX, clientY: safeY, screenX: safeX, screenY: safeY };
//                 document.dispatchEvent(new MouseEvent('mousedown', outsideOpts));
//                 document.dispatchEvent(new MouseEvent('click', outsideOpts));
//                 document.dispatchEvent(new TouchEvent('touchstart', { bubbles:true, cancelable:true, touches:[new Touch({identifier:Date.now()+99, target:document.body, clientX:safeX, clientY:safeY, screenX:safeX, screenY:safeY, pageX:safeX, pageY:safeY})], targetTouches:[], changedTouches:[] }));
//               }
//             } catch(e) {}
//           }
//         }

//         if ($hangMs > 0) setTimeout(finishTap, $hangMs);
//         else finishTap();
//       })();
//     ''');

//     if (hangMs > 0) {
//       await Future.delayed(Duration(milliseconds: hangMs + 50));
//     }
//   }

//   Future<void> _dismissSoftKeyboard() async {
//     await controller.runJavaScript('''
//       (function() {
//         var el = document.activeElement;
//         if (el) el.blur();
//       })();
//     ''');
//   }

//   Future<void> _enterTextAtFocused(String text) async {
//     final escaped = text.replaceAll("'", "\\'");
//     await controller.runJavaScript('''
//       (function() {
//         var el = document.activeElement;
//         if (!el || (el.tagName !== 'INPUT' && el.tagName !== 'TEXTAREA')) return;
//         el.focus();
//         var nativeSetter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value')
//                         || Object.getOwnPropertyDescriptor(window.HTMLTextAreaElement.prototype, 'value');
//         if (nativeSetter && nativeSetter.set) {
//           nativeSetter.set.call(el, '$escaped');
//         } else {
//           el.value = '$escaped';
//         }
//         el.dispatchEvent(new InputEvent('input', { bubbles: true, data: '$escaped', inputType: 'insertText' }));
//         el.dispatchEvent(new Event('change', { bubbles: true }));
//       })();
//     ''');
//   }

//   Future<void> _scrollDown(double percent) async {
//     await controller.runJavaScript('''
//       (function() {
//         var scrollAmt = window.innerHeight * $percent;
//         window.scrollBy({ top: scrollAmt, behavior: 'smooth' });
//       })();
//     ''');
//     await Future.delayed(const Duration(milliseconds: 1000));
//   }

//   TextLocation _toCssLocation(TextLocation loc) => TextLocation(
//     text: loc.text,
//     minX: loc.minX / devicePixelRatio,
//     minY: loc.minY / devicePixelRatio,
//     maxX: loc.maxX / devicePixelRatio,
//     maxY: loc.maxY / devicePixelRatio,
//     confidence: loc.confidence,
//   );
// }
