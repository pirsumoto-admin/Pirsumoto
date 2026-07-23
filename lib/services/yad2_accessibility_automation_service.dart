// import 'dart:async';
// import 'dart:convert';
// import 'dart:io';
// import 'dart:math';
// import 'package:flutter/foundation.dart';
// import 'package:flutter/services.dart';
// import 'package:flutter/widgets.dart';
// import 'package:flutter/gestures.dart';
// import 'package:wakelock_plus/wakelock_plus.dart';
// import 'package:audioplayers/audioplayers.dart';
// import 'yad2_automation_models.dart' show VehiclePublishData, AutomationPhase;

// import 'package:webview_flutter/webview_flutter.dart';
// import 'package:firebase_auth/firebase_auth.dart';
// import 'package:cloud_firestore/cloud_firestore.dart';
// import 'whatsapp_message_bridge_service.dart';

// class Yad2AccessibilityAutomationService {
//   final VehiclePublishData formData;
//   final WebViewController controller;

//   final void Function(AutomationPhase phase)? onPhaseComplete;
//   final void Function(AutomationPhase phase, String error)? onPhaseError;
//   final void Function(bool success)? onAutomationComplete;
//   final VoidCallback? onFirstStepDetected;
//   final void Function(double cssX, double cssY)? onTapPreview;

//   static const int _maxRetries = 3;
//   int _phaseRetryCount = 0;
//   bool _isPaused = false;
//   AutomationPhase? _pausedPhase;
//   AutomationPhase? _currentPhase;
//   Timer? _loginSamplingTimer;

//   bool _settingsFetched = false;
//   List<String> _warranties = [];
//   Map<String, String> _warrantyDurations = {};
//   List<String> _treatments = [];
//   List<String> _services = [];

//   Future<void> _fetchSettingsIfNeeded() async {
//     if (_settingsFetched) return;
//     _warranties = formData.warranties;
//     _warrantyDurations = formData.warrantyDurations;
//     _treatments = formData.treatments;
//     _services = formData.services;

//     if (_warranties.isEmpty && _treatments.isEmpty && _services.isEmpty) {
//       try {
//         final user = FirebaseAuth.instance.currentUser;
//         if (user != null) {
//           final doc =
//               await FirebaseFirestore.instance
//                   .collection('users')
//                   .doc(user.uid)
//                   .get();
//           if (doc.exists) {
//             final data = doc.data();
//             final settings = data?['settings'] as Map<String, dynamic>?;
//             if (settings != null) {
//               if (settings['warranties'] != null) {
//                 _warranties = List<String>.from(settings['warranties']);
//               }
//               if (settings['warrantyDurations'] != null) {
//                 _warrantyDurations = Map<String, String>.from(
//                   settings['warrantyDurations'],
//                 );
//               }
//               if (settings['treatments'] != null) {
//                 _treatments = List<String>.from(settings['treatments']);
//               }
//               if (settings['services'] != null) {
//                 _services = List<String>.from(settings['services']);
//               }
//             }
//           }
//         }
//       } catch (e) {
//         debugPrint('[Yad2-A11y] Error fetching settings: $e');
//       }
//     }
//     _settingsFetched = true;
//   }

//   bool _loginGateTickBusy = false;

//   // The MethodChannel name to communicate with the Android AccessibilityService
//   static const MethodChannel _channel = MethodChannel(
//     'com.pirsumoto/accessibility',
//   );

//   static Future<bool> checkPermission() async {
//     try {
//       if (Platform.isAndroid) {
//         final bool? hasPermission = await _channel.invokeMethod<bool>(
//           'checkPermission',
//         );
//         return hasPermission ?? false;
//       }
//       return true;
//     } catch (e) {
//       return false;
//     }
//   }

//   static Future<void> openSettings() async {
//     try {
//       if (Platform.isAndroid) {
//         await _channel.invokeMethod('openSettings');
//       }
//     } catch (e) {
//       debugPrint('Error opening settings: $e');
//     }
//   }

//   bool get isPaused => _isPaused;
//   AutomationPhase? get pausedPhase => _pausedPhase;

//   final bool startedFromWhatsApp;
//   final String? whatsAppSenderKey;

//   Yad2AccessibilityAutomationService({
//     required this.formData,
//     required this.controller,
//     this.startedFromWhatsApp = false,
//     this.whatsAppSenderKey,
//     this.onPhaseComplete,
//     this.onPhaseError,
//     this.onAutomationComplete,
//     this.onFirstStepDetected,
//     this.onTapPreview,
//   });

//   void dispose() {
//     _stopLoginGate();
//     _isPaused = true;
//     _currentPhase = null;
//     _pausedPhase = null;
//   }

//   void pauseAutomation() {
//     debugPrint('[Yad2-A11y] ⏸️ Pause requested');
//     _stopLoginGate();
//     _isPaused = true;
//   }

//   void resumeAutomation() {
//     debugPrint('[Yad2-A11y] ▶️ Resume requested');
//     _stopLoginGate();
//     if (!_isPaused) return;
//     _isPaused = false;

//     final phaseToResume = _pausedPhase ?? _currentPhase;
//     if (phaseToResume != null) {
//       _pausedPhase = null;
//       _processPhase(phaseToResume);
//     }
//   }

//   void stepBack() {
//     //toolLogTree();
//     final current = _pausedPhase ?? _currentPhase;
//     if (current == null) return;
//     final currentIndex = current.index;
//     if (currentIndex > 0) {
//       final prev = AutomationPhase.values[currentIndex - 1];
//       debugPrint(
//         '[Yad2-A11y] ↩️ Stepping back from ${current.name} to ${prev.name}',
//       );
//       _pausedPhase = prev;
//       _currentPhase = prev;
//     }
//   }

//   void startAutomation() {
//     debugPrint('[Yad2-A11y] 🚀 Starting Accessibility automation');
//     SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
//     WakelockPlus.enable();
//     _processPhase(AutomationPhase.phase1);
//   }

//   void _processPhase(AutomationPhase phase) {
//     _currentPhase = phase;
//     _phaseRetryCount = 0;
//     if (_isPaused) {
//       _pausedPhase = phase;
//       debugPrint('[Yad2-A11y] ⏸️ Automation paused at phase: ${phase.name}');
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
//       '[Yad2-A11y] ════════════════════════════════════════════════════',
//     );
//     debugPrint(
//       '[Yad2-A11y] ${phase.name.toUpperCase()}  attempt ${_phaseRetryCount + 1}/${_maxRetries + 1}',
//     );
//     debugPrint(
//       '[Yad2-A11y] ════════════════════════════════════════════════════',
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
//         case AutomationPhase.phase5c:
//           await _phase5cCheckNoTest();
//         case AutomationPhase.phase5d:
//           await _phase5dWarranties();
//         case AutomationPhase.phase5e:
//           await _phase5eTreatments();
//         case AutomationPhase.phase5f:
//           await _phase5fServices();
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
//           await _phase13Disability();
//         case AutomationPhase.phase14:
//           await _phase14EnterAdditionalInfo();
//         case AutomationPhase.phase15:
//           await _phase15SelectCity();
//         case AutomationPhase.phase16:
//           await _phase16EnterPrice();
//         case AutomationPhase.phase17:
//           await _phase17();
//         case AutomationPhase.complete:
//           WakelockPlus.disable();
//           _handlePhaseComplete(AutomationPhase.complete);
//         default:
//           debugPrint('[Yad2-A11y] Ignoring commented out phase: $phase');
//           break;
//       }
//     } catch (e) {
//       debugPrint('[Yad2-A11y] Phase execution error: $e');
//       await _handleBlockedFlow(phase, e.toString());
//     }
//   }

//   // ── Function Tools for Accessibility API ─────────────────────────────────

//   /// Generic function tool: Ask Android AccessibilityService to find node and tap
//   Future<bool> toolFindElementAndTap(
//     String targetText, {
//     int targetInstance = 1,
//     double deltaY = 0, // In case we need relative tapping, handled by dart side
//   }) async {
//     debugPrint(
//       '[Yad2-A11y] Tool: toolFindElementAndTap("$targetText", instance=$targetInstance, deltaY=$deltaY)',
//     );
//     try {
//       final bounds = await _getStableBounds('findAndGetBounds', {
//         'target': targetText,
//         'targetInstance': targetInstance,
//       });

//       if (bounds != null) {
//         final physicalX = (bounds['x'] as num).toDouble();
//         final physicalY = (bounds['y'] as num).toDouble() + deltaY;

//         // Convert from physical Android screen pixels to Flutter logical pixels
//         final pixelRatio =
//             WidgetsBinding
//                 .instance
//                 .platformDispatcher
//                 .views
//                 .first
//                 .devicePixelRatio;
//         final logicalX = physicalX / pixelRatio;
//         final logicalY = physicalY / pixelRatio;

//         debugPrint(
//           '[Yad2-A11y] Found target "$targetText". Physical ($physicalX, $physicalY). Logical ($logicalX, $logicalY)',
//         );

//         onTapPreview?.call(logicalX, logicalY);

//         // Dispatch an immutable hardware tap via Android native AccessibilityService
//         await toolTapScreen(physicalX, physicalY);
//         return true;
//       } else {
//         return false;
//       }
//     } catch (e) {
//       debugPrint('[Yad2-A11y] PlatformException in findAndTap: $e');
//       return false;
//     }
//   }

//   /// Generic function tool: Ask Android AccessibilityService to find node and enter text
//   Future<bool> toolEnterText(
//     String targetText,
//     String value, {
//     int targetInstance = 1,
//   }) async {
//     debugPrint(
//       '[Yad2-A11y] Tool: toolEnterText("$targetText", value="$value")',
//     );
//     try {
//       final bounds = await _getStableBounds('findAndGetBounds', {
//         'target': targetText,
//         'targetInstance': targetInstance,
//       });

//       if (bounds != null) {
//         final physicalX = (bounds['x'] as num).toDouble();
//         final physicalY = (bounds['y'] as num).toDouble();

//         // 1. Tap to focus the input natively
//         await toolTapScreen(physicalX, physicalY);
//         await Future.delayed(const Duration(milliseconds: 650));

//         // 2. Direct text entry via AccessibilityService (ACTION_SET_TEXT)
//         bool success = await toolEnterTextAtFocused(value);

//         // 3. Fallback to JS Injection if native Accessibility text entry fails
//         if (!success) {
//           debugPrint(
//             '[Yad2-A11y] Native text entry failed, falling back to JS injection.',
//           );
//           await toolEnterTextAtFocusedJs(value);
//           success = true;
//         }
//         return success;
//       }
//       return false;
//     } on PlatformException catch (e) {
//       debugPrint('[Yad2-A11y] PlatformException in enterText: ${e.message}');
//       return false;
//     }
//   }

//   /// Generic function tool: Ask Android AccessibilityService to find the input BEFORE a specific node and enter text
//   Future<bool> toolEnterTextBefore(String targetText, String value) async {
//     debugPrint(
//       '[Yad2-A11y] Tool: toolEnterTextBefore("$targetText", value="$value")',
//     );
//     try {
//       final bounds = await _getStableBounds('findInputBeforeAndGetBounds', {
//         'target': targetText,
//       });

//       if (bounds != null) {
//         final physicalX = (bounds['x'] as num).toDouble();
//         final physicalY = (bounds['y'] as num).toDouble();

//         // 1. Tap to focus the input natively
//         await toolTapScreen(physicalX, physicalY);
//         await Future.delayed(const Duration(milliseconds: 650));

//         // 2. Direct text entry via AccessibilityService (ACTION_SET_TEXT)
//         bool success = await toolEnterTextAtFocused(value);

//         // 3. Fallback to JS Injection if native Accessibility text entry fails
//         if (!success) {
//           debugPrint(
//             '[Yad2-A11y] Native text entry failed, falling back to JS injection.',
//           );
//           await toolEnterTextAtFocusedJs(value);
//           success = true;
//         }
//         return success;
//       }
//       return false;
//     } on PlatformException catch (e) {
//       debugPrint(
//         '[Yad2-A11y] PlatformException in enterTextBefore: ${e.message}',
//       );
//       return false;
//     }
//   }

//   /// Generic function tool: Ask Android AccessibilityService to find the node BEFORE a specific node and tap it
//   Future<bool> toolTapNodeBefore(
//     String targetText, {
//     int targetInstance = 1,
//     double deltaY = 0,
//   }) async {
//     debugPrint(
//       '[Yad2-A11y] Tool: toolTapNodeBefore("$targetText", instance=$targetInstance, deltaY=$deltaY)',
//     );
//     try {
//       final bounds = await _getStableBounds('findNodeBeforeAndGetBounds', {
//         'target': targetText,
//         'targetInstance': targetInstance,
//       });

//       if (bounds != null) {
//         final physicalX = (bounds['x'] as num).toDouble();
//         final physicalY = (bounds['y'] as num).toDouble() + deltaY;

//         final pixelRatio =
//             WidgetsBinding
//                 .instance
//                 .platformDispatcher
//                 .views
//                 .first
//                 .devicePixelRatio;
//         final logicalX = physicalX / pixelRatio;
//         final logicalY = physicalY / pixelRatio;

//         debugPrint(
//           '[Yad2-A11y] Found node before "$targetText". Physical ($physicalX, $physicalY). Logical ($logicalX, $logicalY)',
//         );

//         onTapPreview?.call(logicalX, logicalY);

//         await toolTapScreen(physicalX, physicalY);
//         return true;
//       }
//       return false;
//     } on PlatformException catch (e) {
//       debugPrint(
//         '[Yad2-A11y] PlatformException in toolTapNodeBefore: ${e.message}',
//       );
//       return false;
//     }
//   }

//   /// Generic function tool: Ask Android AccessibilityService to find the node AFTER a specific node and get its text
//   Future<String?> toolGetNodeTextAfter(
//     String targetText, {
//     int targetInstance = 1,
//     double threshold = 0.82,
//     int offset = 1,
//   }) async {
//     debugPrint(
//       '[Yad2-A11y] Tool: toolGetNodeTextAfter("$targetText", instance=$targetInstance, offset=$offset)',
//     );
//     try {
//       final text = await _channel
//           .invokeMethod<String>('findNodeTextAfterTarget', {
//             'target': targetText,
//             'targetInstance': targetInstance,
//             'threshold': threshold,
//             'offset': offset,
//           });
//       return text;
//     } on PlatformException catch (e) {
//       debugPrint(
//         '[Yad2-A11y] PlatformException in toolGetNodeTextAfter: ${e.message}',
//       );
//       return null;
//     }
//   }

//   /// Generic function tool: Ask Android AccessibilityService to find the node AFTER a specific node and tap it
//   Future<bool> toolTapNodeAfter(
//     String targetText, {
//     int targetInstance = 1,
//     double threshold = 0.82,
//     double deltaX = 0.0,
//     double deltaY = 0.0,
//     int offset = 1,
//   }) async {
//     debugPrint(
//       '[Yad2-A11y] Tool: toolTapNodeAfter("$targetText", instance=$targetInstance, deltaX=$deltaX, deltaY=$deltaY, offset=$offset)',
//     );
//     try {
//       final bounds = await _getStableBounds('findNodeAfterAndGetBounds', {
//         'target': targetText,
//         'targetInstance': targetInstance,
//         'threshold': threshold,
//         'offset': offset,
//       });

//       if (bounds != null) {
//         final physicalX = (bounds['x'] as num).toDouble() + deltaX;
//         final physicalY = (bounds['y'] as num).toDouble() + deltaY;

//         final pixelRatio =
//             WidgetsBinding
//                 .instance
//                 .platformDispatcher
//                 .views
//                 .first
//                 .devicePixelRatio;
//         final logicalX = physicalX / pixelRatio;
//         final logicalY = physicalY / pixelRatio;

//         debugPrint(
//           '[Yad2-A11y] Found node after "$targetText". Physical ($physicalX, $physicalY). Logical ($logicalX, $logicalY)',
//         );

//         onTapPreview?.call(logicalX, logicalY);

//         await toolTapScreen(physicalX, physicalY);
//         return true;
//       }
//       return false;
//     } on PlatformException catch (e) {
//       debugPrint(
//         '[Yad2-A11y] PlatformException in toolTapNodeAfter: ${e.message}',
//       );
//       return false;
//     }
//   }

//   Future<void> toolLogTree() async {
//     debugPrint('[Yad2-A11y] Tool: toolLogTree');
//     try {
//       final String? treeStr = await _channel.invokeMethod<String>('logTree');
//       if (treeStr != null) {
//         final lines = treeStr.split('\n');
//         for (var line in lines) {
//           debugPrint(line);
//         }
//       }
//     } catch (e) {
//       debugPrint('[Yad2-A11y] Error logging tree: $e');
//     }
//   }

//   Future<void> _scrollDown(double percent) async {
//     debugPrint('[Yad2-A11y] Tool: _scrollDown ($percent)');
//     try {
//       await _channel.invokeMethod('scrollNode', {
//         'direction': 'down',
//         'percent': percent,
//       });
//     } catch (e) {
//       debugPrint('[Yad2-A11y] Scroll error: $e');
//     }
//     await _waitForScrollSettle();
//   }

//   /// Waits for the scroll animation to finish before any element lookup:
//   /// polls the WebView scroll position until two consecutive readings agree,
//   /// then gives the accessibility tree an extra beat to refresh its bounds.
//   Future<void> _waitForScrollSettle({
//     Duration timeout = const Duration(seconds: 3),
//   }) async {
//     // Let the fling animation start before sampling.
//     await Future.delayed(const Duration(milliseconds: 600));
//     final deadline = DateTime.now().add(timeout);
//     double? last;
//     int nullReads = 0;
//     while (DateTime.now().isBefore(deadline)) {
//       double? current;
//       try {
//         final res = await controller.runJavaScriptReturningResult(
//           '(window.scrollY || document.documentElement.scrollTop || 0)',
//         );
//         current = double.tryParse(res.toString());
//       } catch (_) {}
//       if (current == null) {
//         // JS unavailable (page transition) — don't burn the full timeout.
//         if (++nullReads >= 2) break;
//       } else if (last != null && (current - last).abs() < 1.0) {
//         break;
//       }
//       last = current;
//       await Future.delayed(const Duration(milliseconds: 250));
//     }
//     // Buffer for the native accessibility tree to re-sync after the DOM stops.
//     await Future.delayed(const Duration(milliseconds: 300));
//   }

//   /// Fetches node bounds and re-reads until two consecutive readings agree,
//   /// so a tap never uses coordinates captured while the page is still moving
//   /// (e.g. right after a scroll or a layout shift).
//   Future<Map<String, dynamic>?> _getStableBounds(
//     String method,
//     Map<String, dynamic> args, {
//     int maxReads = 4,
//   }) async {
//     Map<String, dynamic>? previous;
//     for (int i = 0; i < maxReads; i++) {
//       final bounds = await _channel.invokeMapMethod<String, dynamic>(
//         method,
//         args,
//       );
//       if (bounds == null) return null;
//       if (previous != null) {
//         final dx = ((bounds['x'] as num) - (previous['x'] as num)).abs();
//         final dy = ((bounds['y'] as num) - (previous['y'] as num)).abs();
//         if (dx < 2 && dy < 2) return bounds;
//         debugPrint(
//           '[Yad2-A11y] ⏳ Bounds still moving (Δx=$dx, Δy=$dy) — re-reading',
//         );
//       }
//       previous = bounds;
//       await Future.delayed(const Duration(milliseconds: 250));
//     }
//     return previous;
//   }

//   Future<void> toolTapScreen(double x, double y) async {
//     debugPrint('[Yad2-A11y] Tool: toolTapScreen($x, $y)');
//     try {
//       await _channel.invokeMethod('tapScreen', {'x': x, 'y': y});
//     } catch (e) {
//       debugPrint('[Yad2-A11y] TapScreen error: $e');
//     }
//   }

//   /// Generic function tool: Ask Android AccessibilityService to simulate a global back button press
//   Future<bool> toolPressBack() async {
//     debugPrint('[Yad2-A11y] Tool: toolPressBack');
//     try {
//       final pressed = await _channel.invokeMethod<bool>('pressBack');
//       return pressed ?? false;
//     } on PlatformException catch (e) {
//       debugPrint('[Yad2-A11y] PlatformException in pressBack: ${e.message}');
//       return false;
//     }
//   }

//   /// Inject text natively using Android MethodChannel (Instrumentation / input shell fallback)
//   Future<void> toolInjectTextNative(String text) async {
//     debugPrint('[Yad2-A11y] Tool: toolInjectTextNative($text)');
//     for (int i = 0; i < text.length; i++) {
//       try {
//         await _channel.invokeMethod<bool>('injectTextNative', {
//           'value': text[i],
//         });
//         await Future.delayed(const Duration(milliseconds: 150));
//       } catch (e) {
//         debugPrint('[Yad2-A11y] Error injecting native text "${text[i]}": $e');
//       }
//     }
//   }

//   /// Inject text natively using ACTION_SET_TEXT exactly on the currently focused field
//   Future<bool> toolEnterTextAtFocused(String text) async {
//     debugPrint('[Yad2-A11y] Tool: toolEnterTextAtFocused($text)');
//     try {
//       final success = await _channel.invokeMethod<bool>('enterTextAtFocused', {
//         'value': text,
//       });
//       debugPrint('[Yad2-A11y] enterTextAtFocused($text) returned $success');
//       return success ?? false;
//     } on PlatformException catch (e) {
//       debugPrint(
//         '[Yad2-A11y] PlatformException in enterTextAtFocused: ${e.message}',
//       );
//       return false;
//     }
//   }

//   Future<void> toolEnterTextAtFocusedJs(String text) async {
//     debugPrint('[Yad2-A11y] Tool: toolEnterTextAtFocusedJs($text)');
//     final escaped = text.replaceAll("'", "\\'");
//     await controller.runJavaScript('''
//       (function() {
//         var el = document.activeElement;
        
//         if (!el || (el.tagName !== 'INPUT' && el.tagName !== 'TEXTAREA')) {
//           var possibleInputs = document.querySelectorAll('input:not([type="hidden"]):not([type="checkbox"]):not([type="radio"])');
//           for (var i = 0; i < possibleInputs.length; i++) {
//             var rect = possibleInputs[i].getBoundingClientRect();
//             if (rect.width > 0 && rect.height > 0 && rect.top >= 0 && rect.bottom <= (window.innerHeight || document.documentElement.clientHeight)) {
//               el = possibleInputs[i];
//               break;
//             }
//           }
//         }
        
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

//   /// Uses the Shadow HTML DOM logic to find an element by exact text and dispatches native React/JS click events
//   Future<bool> toolFindAndTapJs(
//     String targetText, {
//     int targetInstance = 1,
//   }) async {
//     debugPrint(
//       '[Yad2-A11y] Tool: toolFindAndTapJs($targetText, instance: $targetInstance)',
//     );
//     final escaped = targetText.replaceAll("'", "\\'");
//     final js = '''
//       (function() {
//         var all = [];
//         function getAllElements(root) {
//           if (!root) return;
//           var elements = root.querySelectorAll('*');
//           for (var i = 0; i < elements.length; i++) {
//             all.push(elements[i]);
//             if (elements[i].shadowRoot) getAllElements(elements[i].shadowRoot);
//           }
//         }
//         getAllElements(document);
        
//         var targetEl = null;
//         var targetRect = null;
//         var cleanTarget = '$escaped'.replace(/\\s+/g, '');
//         var matchCount = 0;
//         for (var i = 0; i < all.length; i++) {
//           var el = all[i];
//           var rect = el.getBoundingClientRect();
//           if (rect.width === 0 || rect.height === 0) continue;
          
//           var text = (el.innerText || '').trim();
//           var cleanText = text.replace(/\\s+/g, '');
//           if (cleanText === cleanTarget) {
//             matchCount++;
//             if (matchCount === $targetInstance) {
//               targetEl = el;
//               try { targetEl.scrollIntoView({behavior: 'auto', block: 'center'}); } catch(e) {}
//               targetRect = targetEl.getBoundingClientRect();
//               break;
//             }
//           }
//         }
        
//         if (!targetEl) return false;
        
//         var x = targetRect.left + targetRect.width / 2;
//         var y = targetRect.top + targetRect.height / 2;
        
//         var eOpts = { bubbles:true, cancelable:true, clientX:x, clientY:y, screenX:x, screenY:y };
//         var touch = new Touch({ identifier: Date.now(), target: targetEl, clientX: x, clientY: y, screenX: x, screenY: y, pageX: x + window.scrollX, pageY: y + window.scrollY });

//         targetEl.dispatchEvent(new TouchEvent('touchstart', { bubbles: true, cancelable: true, touches: [touch], targetTouches: [touch], changedTouches: [touch] }));
//         targetEl.dispatchEvent(new MouseEvent('mousedown', eOpts));
        
//         targetEl.dispatchEvent(new TouchEvent('touchend', { bubbles: true, cancelable: true, changedTouches: [touch] }));
//         targetEl.dispatchEvent(new MouseEvent('mouseup', eOpts));
//         targetEl.dispatchEvent(new MouseEvent('click', eOpts));
//         try { targetEl.click(); } catch(e) {}
        
//         try {
//           var fiberKey = Object.keys(targetEl).find(function(k) { return k.startsWith('__reactFiber') || k.startsWith('__reactInternalInstance'); });
//           if (fiberKey) {
//             var fiber = targetEl[fiberKey];
//             while (fiber) {
//               var props = fiber.memoizedProps || fiber.pendingProps;
//               if (props && typeof props.onClick === 'function') {
//                 props.onClick({ type:'click', target:targetEl, currentTarget:targetEl, clientX:x, clientY:y, bubbles:true, preventDefault:function(){}, stopPropagation:function(){} });
//                 break;
//               }
//               fiber = fiber.return;
//             }
//           }
//         } catch(e) {}
        
//         return true;
//       })();
//     ''';

//     final result = await controller.runJavaScriptReturningResult(js);
//     return result == true || result == 'true';
//   }

//   // ── Helper Tools ────────────────────────────────────────────────────────

//   Future<void> toolLogAccessibilityTree() async {
//     debugPrint('[Yad2-A11y] Tool: toolLogAccessibilityTree');
//     try {
//       final String? treeStr = await _channel.invokeMethod<String>('logTree');
//       if (treeStr != null) {
//         final lines = treeStr.split('\n');
//         for (var line in lines) {
//           debugPrint(line);
//         }
//       }
//     } catch (e) {
//       debugPrint('[Yad2-A11y] Failed to log tree: $e');
//     }
//   }

//   Future<void> _closeDropdownIfNeeded() async {
//     await Future.delayed(const Duration(milliseconds: 500));
//     final closed = await _retryUntil(
//       () => tapSmart('סגירת חלון'),
//       timeout: const Duration(seconds: 3),
//     );
//     if (closed) {
//       debugPrint('[Yad2-A11y] ✖️ Manually closed dropdown using "סגירת חלון"');
//       await Future.delayed(const Duration(milliseconds: 500));
//     } else {
//       debugPrint(
//         '[Yad2-A11y] ✖️ "סגירת חלון" button not found, assuming dropdown is closed',
//       );
//     }
//   }

//   Future<bool> _dismissMaybeLaterPopup() async {
//     const popupTexts = ['אולי אחר כך'];
//     for (var text in popupTexts) {
//       if (await toolFindElementAndTap(text, deltaY: -15)) {
//         // Often needs a slight upward adjustment
//         debugPrint('[Yad2-A11y] 🔄 Dismissed popup: $text');
//         await Future.delayed(const Duration(milliseconds: 1500));
//         return true;
//       }
//     }
//     return false;
//   }

//   Future<bool> _dismissGotItPopup() async {
//     const popupTexts = [
//       'הבנתי',
//       'עדכנתי, בואו נמשיך',
//       'עדכנתי, בוא נמשיך',
//       'עדכנתי בואו נמשיך',
//     ];
//     for (var text in popupTexts) {
//       if (await toolFindElementAndTap(text, deltaY: -15)) {
//         // Often needs a slight upward adjustment
//         debugPrint('[Yad2-A11y] 🔄 Dismissed popup: $text');
//         await Future.delayed(const Duration(milliseconds: 1500));
//         return true;
//       }
//     }
//     return false;
//   }

//   Future<void> _handleBlockedFlow(
//     AutomationPhase phase,
//     String errorContext,
//   ) async {
//     debugPrint('[Yad2-A11y] Tool: _handleBlockedFlow (Phase: ${phase.name})');
//     WakelockPlus.disable();
//     await toolLogTree(); // Dump the tree to see why it got stuck
//     await _handleError(
//       phase,
//       'Stuck: $errorContext. Please check accessibility tree and screen.',
//     );
//   }

//   Future<bool> _performWithPopupHandling(Future<bool> Function() action) async {
//     bool result = await action();
//     if (!result) {
//       bool dismissed = await _dismissGotItPopup();
//       if (!dismissed) {
//         dismissed = await _dismissMaybeLaterPopup();
//       }
//       if (dismissed) {
//         debugPrint('[Yad2-A11y] 🔄 Re-trying action after dismissing popup');
//         result = await action();
//       }
//     }
//     return result;
//   }

//   /// Polls [action] until it succeeds or [timeout] elapses.
//   ///
//   /// Replaces fixed sleeps and fixed-count loops: the phase proceeds as soon
//   /// as the UI is ready instead of waiting a guessed duration, yet tolerates
//   /// slow page loads up to [timeout]. [action] must only have side effects
//   /// on success (lookups that fail are pure), so re-polling is safe.
//   Future<bool> _retryUntil(
//     Future<bool> Function() action, {
//     Duration timeout = const Duration(seconds: 8),
//     Duration pollInterval = const Duration(milliseconds: 400),
//   }) async {
//     final deadline = DateTime.now().add(timeout);
//     do {
//       if (_isPaused) return false;
//       if (await action()) return true;
//       await Future.delayed(pollInterval);
//     } while (DateTime.now().isBefore(deadline));
//     return false;
//   }

//   /// Pure native-tree lookup with no tap side effect — safe to poll.
//   Future<bool> _isElementPresent(
//     String target, {
//     int targetInstance = 1,
//   }) async {
//     try {
//       final bounds = await _channel.invokeMapMethod<String, dynamic>(
//         'findAndGetBounds',
//         {'target': target, 'targetInstance': targetInstance},
//       );
//       return bounds != null;
//     } catch (_) {
//       return false;
//     }
//   }

//   /// Locator fallback ladder: native Accessibility tap first, then a
//   /// shadow-DOM JS click on each `|` alternative when the native tree
//   /// does not expose the element.
//   Future<bool> tapSmart(
//     String targetText, {
//     int targetInstance = 1,
//     double deltaY = 0,
//   }) async {
//     if (await toolFindElementAndTap(
//       targetText,
//       targetInstance: targetInstance,
//       deltaY: deltaY,
//     )) {
//       return true;
//     }
//     for (final alt in targetText.split('|')) {
//       final candidate = alt.trim();
//       if (candidate.isEmpty) continue;
//       if (await toolFindAndTapJs(candidate, targetInstance: targetInstance)) {
//         debugPrint(
//           '[Yad2-A11y] 🕸️ Shadow-DOM JS fallback clicked "$candidate"',
//         );
//         return true;
//       }
//     }
//     return false;
//   }

//   void _stopLoginGate() {
//     _loginSamplingTimer?.cancel();
//     _loginSamplingTimer = null;
//   }

//   /// Login gate: beep once to prompt the user, then silently poll until the
//   /// publish flow's first-step element appears (login completed) and
//   /// auto-resume. Deliberately NOT reported via [onPhaseError] — a login wall
//   /// is an expected state, not a failure, so no error UI is shown.
//   void _startLoginGate() {
//     if (_loginSamplingTimer != null) return;
//     debugPrint('[Yad2-A11y] 🔐 Login gate active — waiting for manual login');
//     _isPaused = true;
//     _pausedPhase = AutomationPhase.phase1;
//     unawaited(_beepUser());
//     _loginSamplingTimer = Timer.periodic(const Duration(seconds: 3), (
//       timer,
//     ) async {
//       // Popup dismissal takes longer than one tick — never overlap ticks.
//       if (_loginGateTickBusy) return;
//       _loginGateTickBusy = true;
//       try {
//         //if (!await _isElementPresent('פרטיים ומסחריים')) {
//         // Post-login popups can cover the card and hide it from the
//         // native tree — dismiss them so the next tick can see it.
//         if (await _dismissGotItPopup()) {
//           debugPrint('[Yad2-A11y] 🔐 Gate: dismissed "הבנתי" popup');
//           return;
//         }
//         if (await _dismissMaybeLaterPopup()) {
//           debugPrint('[Yad2-A11y] 🔐 Gate: dismissed "אולי אחר כך" popup');
//         }
//         return;
//         //}
//         debugPrint('[Yad2-A11y] 🎉 Login completed — resuming automation');
//         timer.cancel();
//         _loginSamplingTimer = null;
//         _isPaused = false;
//         _pausedPhase = null;
//         _processPhase(AutomationPhase.phase1);
//       } finally {
//         _loginGateTickBusy = false;
//       }
//     });
//   }

//   Future<bool> _checkIsLoginScreen() async {
//     try {
//       final res = await controller.runJavaScriptReturningResult('''
//         (function() {
//           var hasPassword = document.querySelector('input[type="password"]') !== null;
//           if (hasPassword) return true;
//           var text = document.body ? document.body.innerText : '';
//           if (text.includes('התחברות') || text.includes('כניסה לאזור האישי') || text.includes('אימייל/מספר טלפון')) {
//             return true;
//           }
//           return false;
//         })()
//       ''');
//       if (res == true || res == 'true') {
//         debugPrint('[Yad2-A11y] 🔐 Login screen detected via JS');
//         return true;
//       }
//     } catch (e) {
//       debugPrint('[Yad2-A11y] JS login detection failed: $e');
//     }

//     final loginKeywords = [
//       'התחברות',
//       'כניסה לאזור',
//       'דוא"ל',
//       'סיסמה',
//       'הרשמה',
//       'כניסה',
//       'התחבר',
//     ];
//     for (final word in loginKeywords) {
//       try {
//         final bounds = await _channel.invokeMapMethod<String, dynamic>(
//           'findAndGetBounds',
//           {'target': word, 'targetInstance': 1},
//         );
//         if (bounds != null) {
//           debugPrint(
//             '[Yad2-A11y] 🔐 Login screen detected via A11y with keyword: "$word"',
//           );
//           return true;
//         }
//       } catch (_) {}
//     }
//     return false;
//   }

//   // ── Phase Implementations ────────────────────────────────────────────────

//   Future<void> _phase1SelectVehicleType() async {
//     // Poll until the page settles — checking for blocking popups,
//     // login wall, or until either of the target screens is settled.
//     bool loginDetected = false;
//     await _retryUntil(
//       () async {
//         //if (await _isElementPresent('פרטיים ומסחריים')) return true;
//         if (await _isElementPresent('חיפוש')) return true;
//         if (await _dismissGotItPopup()) return false; // re-poll after dismiss
//         if (await _dismissMaybeLaterPopup()) return false;
//         if (await _checkIsLoginScreen()) {
//           loginDetected = true;
//           return true;
//         }
//         return false;
//       },
//       timeout: const Duration(milliseconds: 1000),
//       pollInterval: const Duration(milliseconds: 500),
//     );

//     if (loginDetected) {
//       if (startedFromWhatsApp &&
//           whatsAppSenderKey != null &&
//           whatsAppSenderKey!.isNotEmpty) {
//         try {
//           final success = await WhatsAppMessageBridgeService.instance
//               .sendReplyToWhatsApp(
//                 senderKey: whatsAppSenderKey!,
//                 message:
//                     'אנא התחבר לחשבון יד2 במכשיר הפירסומוטו שלך כדי להמשיך.',
//               );
//           debugPrint(
//             '[Yad2-A11y] Dispatched login prompt to WhatsApp. Success: $success',
//           );
//         } catch (e) {
//           debugPrint('[Yad2-A11y] Failed to send login prompt to WhatsApp: $e');
//         }
//       }
//       _startLoginGate();
//       return;
//     }

//     // Skip tapping the vehicle type button and transition directly to phase 2
//     onFirstStepDetected?.call();
//     _handlePhaseComplete(AutomationPhase.phase1);
//   }

//   Future<void> _phase2EnterLicenseAndSearch() async {
//     // Log the entire accessibility tree to inspect the UI at phase 2
//     // await toolLogTree();
//     await Future.delayed(const Duration(milliseconds: 800));
//     // Handle reset popup ("resume existing publication" popup)
//     if (await toolFindElementAndTap('התחלה מחדש|מחדש')) {
//       debugPrint(
//         '[Yad2-A11y] ⚠️ Reset popup found — tapped "מחדש" to start over.',
//       );
//       await Future.delayed(const Duration(milliseconds: 800));
//       //_processPhase(AutomationPhase.phase1);
//       //return;
//     }

//     final licenseText =
//         formData.licenseNumber.isNotEmpty ? formData.licenseNumber : '5211639';
//     // The license form renders after a page transition — poll for it.
//     final entered = await _retryUntil(
//       () => _performWithPopupHandling(
//         () => toolEnterTextBefore('חיפוש', licenseText),
//       ),
//       timeout: const Duration(seconds: 8),
//     );
//     if (!entered) {
//       _handleRetry(AutomationPhase.phase2, 'License input field not found');
//       return;
//     }

//     if (!await toolFindElementAndTap('חיפוש', targetInstance: 1)) {
//       _handleRetry(AutomationPhase.phase2, 'Search button not found');
//       return;
//     }

//     _handlePhaseComplete(AutomationPhase.phase2);
//   }

//   Future<void> _phase3SubmitVehicleLookup() async {
//     // The vehicle lookup runs server-side after phase 2 — poll for the next
//     // button instead of guessing the latency with a fixed sleep.
//     final tapped = await _retryUntil(
//       () => _performWithPopupHandling(() => tapSmart('לשלב הבא|שלב הבא')),
//       timeout: const Duration(seconds: 12),
//     );
//     if (!tapped) {
//       _handleRetry(AutomationPhase.phase3, 'Submit button לשלב not found');
//       return;
//     }
//     _handlePhaseComplete(AutomationPhase.phase3);
//   }

//   Future<void> _phase4OpenColorDropdown() async {
//     // The details form renders after a page transition — poll instead of
//     // a fixed sleep + full-tree dump.
//     // OLD CODE:
//     // final opened = await _retryUntil(
//     //   () => _performWithPopupHandling(() => toolTapNodeBefore(formData.color)),
//     //   timeout: const Duration(seconds: 10),
//     // );
//     final opened = await _retryUntil(
//       () => _performWithPopupHandling(() async {
//         if (await toolTapNodeAfter('צבע*')) return true;
//         if (await toolTapNodeAfter('צבע')) return true;
//         if (await toolTapNodeAfter('צבע הרכב*')) return true;
//         if (await toolTapNodeAfter('צבע הרכב')) return true;
//         return false;
//       }),
//       timeout: const Duration(seconds: 10),
//     );
//     if (opened) {
//       _handlePhaseComplete(AutomationPhase.phase4);
//       return;
//     }
//     _handleRetry(AutomationPhase.phase4, 'Color dropdown failed to open');
//   }

//   Future<void> _phase5SelectColorShade() async {
//     // OLD CODE:
//     // await _scrollDown(0.25);
//     // final selected = await _retryUntil(
//     //   () => _performWithPopupHandling(
//     //     () => toolTapNodeBefore(formData.color, targetInstance: 2),
//     //   ),
//     //   timeout: const Duration(seconds: 6),
//     // );

//     final colorSelected = await _retryUntil(
//       () => _performWithPopupHandling(() => tapSmart(formData.color)),
//       timeout: const Duration(seconds: 6),
//     );
//     if (!colorSelected) {
//       _handleRetry(AutomationPhase.phase5, 'Main color option failed to click');
//       return;
//     }

//     // Wait for the dropdown to close and the "גוון" field to appear/render
//     await Future.delayed(const Duration(milliseconds: 800));

//     // Tap the "גוון" dropdown container to open the shade picker
//     final shadeDropdownOpened = await _retryUntil(
//       () => _performWithPopupHandling(() async {
//         if (await toolTapNodeAfter('גוון*')) return true;
//         if (await toolTapNodeAfter('גוון')) return true;
//         return false;
//       }),
//       timeout: const Duration(seconds: 8),
//     );
//     if (!shadeDropdownOpened) {
//       _handleRetry(
//         AutomationPhase.phase5,
//         'Shade (גוון) dropdown failed to open',
//       );
//       return;
//     }

//     // Wait for the shade dropdown options to appear/animate open
//     await Future.delayed(const Duration(milliseconds: 1000));

//     // Select the shade value (formData.shade) from the open shade dropdown list
//     debugPrint('Yad2-A11y - aric: Tapping shade: ${formData.shade}');
//     final shadeSelected = await _retryUntil(
//       () => _performWithPopupHandling(() async {
//         if (await tapSmart(formData.shade, targetInstance: 2)) return true;
//         return false;
//       }),
//       timeout: const Duration(seconds: 6),
//     );

//     if (shadeSelected) {
//       _handlePhaseComplete(AutomationPhase.phase5);
//       return;
//     }
//     _handleRetry(AutomationPhase.phase5, 'Shade (גוון) option failed to click');
//   }

//   Future<void> _phase5aOpenMonthDropdown() async {
//     //await _scrollDown(0.35);

//     final opened = await _retryUntil(
//       () =>
//           _performWithPopupHandling(() => toolTapNodeAfter('חודש עלייה לכביש')),
//       timeout: const Duration(seconds: 8),
//     );
//     if (opened) {
//       _handlePhaseComplete(AutomationPhase.phase5a);
//       return;
//     }
//     _handleRetry(AutomationPhase.phase5a, 'Month dropdown failed to open');
//   }

//   Future<void> _phase5bSelectMonthValue() async {
//     final monthHebrew = VehiclePublishData.monthToHebrew(formData.month);
//     final monthSearch =
//         monthHebrew != formData.month.trim()
//             ? '$monthHebrew|${formData.month.trim()}'
//             : monthHebrew;

//     // The option list animates open after phase 5a — poll for the value,
//     // with a shadow-DOM JS click fallback for options the native tree misses.
//     final selected = await _retryUntil(
//       () => _performWithPopupHandling(() => tapSmart(monthSearch)),
//       timeout: const Duration(seconds: 6),
//     );
//     if (selected) {
//       _handlePhaseComplete(AutomationPhase.phase5b);
//       return;
//     }

//     _handleRetry(AutomationPhase.phase5b, 'Month value option not found');
//   }

//   Future<void> _phase5cCheckNoTest() async {
//     if (formData.noTest) {
//       await _retryUntil(
//         () => tapSmart('ללא טסט'),
//         timeout: const Duration(seconds: 4),
//       );
//     }
//     _handlePhaseComplete(AutomationPhase.phase5c);
//   }

//   String _getWarrantyDropdownLabel(String warranty) {
//     if (warranty.contains('שלדה')) return 'אחריות שלדה, מנוע וגיר';
//     if (warranty.contains('יבואן')) return 'אחריות מהיבואן';
//     if (warranty.contains('סוכנות')) return 'אחריות מהסוכנות';
//     if (warranty.contains('סוללה')) return 'אחירות על סוללה'; // user typo match
//     return warranty;
//   }

//   Future<void> _phase5dWarranties() async {
//     await _scrollDown(0.2);
//     await _fetchSettingsIfNeeded();
//     debugPrint('[Yad2-A11y] 🔧 Phase 5d: Filling warranties');
//     debugPrint('[Yad2-A11y]   Selected warranties: $_warranties');
//     debugPrint('[Yad2-A11y]   Warranty durations: $_warrantyDurations');
//     if (_warranties.isNotEmpty) {
//       await _scrollDown(0.2);

//       Map<String, int> durationSelectionCounts = {};

//       Future<void> processWarrantiesList(List<String> list) async {
//         for (final warranty in list) {
//           // 1. Select the warranty checkbox
//           await _retryUntil(
//             () => tapSmart(warranty),
//             timeout: const Duration(seconds: 4),
//           );

//           // Wait a moment for the specific dropdown for this warranty to dynamically appear
//           await Future.delayed(const Duration(milliseconds: 1000));

//           // 2. Select the duration for THIS warranty before moving to the next
//           final duration = _warrantyDurations[warranty];
//           if (duration != null && duration.isNotEmpty) {
//             final cleanDuration = duration.trim();
//             final instanceIndex =
//                 (durationSelectionCounts[cleanDuration] ?? 0) + 1;
//             durationSelectionCounts[cleanDuration] = instanceIndex;

//             await _scrollDown(
//               0.1,
//             ); // add some scroll down to reach the newly appeared dropdown

//             // Tap the dropdown using toolTapNodeAfter on the parent label
//             final label = _getWarrantyDropdownLabel(warranty);
//             await toolLogTree();
//             final dropdownOpened = await _retryUntil(
//               () => _performWithPopupHandling(
//                 () => toolTapNodeAfter(label) /* fallback if needed */,
//               ),
//               timeout: const Duration(seconds: 3),
//             );

//             // The dropdown opens, now select the duration
//             if (dropdownOpened) {
//               await Future.delayed(const Duration(milliseconds: 500));
//               debugPrint('Tap duration $duration with instance $instanceIndex');
//               await _retryUntil(
//                 () => tapSmart(duration, targetInstance: instanceIndex),
//                 timeout: const Duration(seconds: 3),
//               );
//             } else {
//               // Alternatively, try tapping the duration directly if it's already visible
//               await _retryUntil(
//                 () => tapSmart(duration, targetInstance: instanceIndex),
//                 timeout: const Duration(seconds: 3),
//               );
//             }
//           }
//         }
//       }

//       final batteryWarranties =
//           _warranties.where((w) => w == 'אחריות על הסוללה').toList();
//       final otherWarranties =
//           _warranties.where((w) => w != 'אחריות על הסוללה').toList();

//       if (batteryWarranties.isNotEmpty) {
//         await processWarrantiesList(batteryWarranties);
//       }
//       if (otherWarranties.isNotEmpty) {
//         await processWarrantiesList(otherWarranties);
//       }
//     }
//     _handlePhaseComplete(AutomationPhase.phase5d);
//   }

//   Future<void> _phase5eTreatments() async {
//     await _fetchSettingsIfNeeded();
//     if (_treatments.isNotEmpty) {
//       await _scrollDown(0.2);
//       for (final treatment in _treatments) {
//         await _retryUntil(
//           () => tapSmart(treatment),
//           timeout: const Duration(seconds: 3),
//         );
//       }
//     }
//     _handlePhaseComplete(AutomationPhase.phase5e);
//   }

//   Future<void> _phase5fServices() async {
//     await _fetchSettingsIfNeeded();
//     if (_services.isNotEmpty) {
//       await _scrollDown(0.2);
//       for (final service in _services) {
//         await _retryUntil(
//           () => tapSmart(service),
//           timeout: const Duration(seconds: 3),
//         );
//       }
//     }
//     _handlePhaseComplete(AutomationPhase.phase5f);
//   }

//   Future<void> _phase6OpenHandDropdown() async {
//     // Check if 2 nodes after the EditText (which follows 'יד*') text value is empty.
//     // The EditText is 2 nodes after the 'יד*' node.
//     final String? textValue = await toolGetNodeTextAfter('יד*', offset: 2);

//     if (textValue != null && textValue.trim().isNotEmpty) {
//       debugPrint(
//         '[Yad2-A11y] "יד*" value is not empty ($textValue). Jumping to Phase 12.',
//       );
//       _handlePhaseComplete(
//         AutomationPhase.phase11,
//       ); // phase11 triggers jump to phase12
//       return;
//     }

//     final opened = await _retryUntil(
//       () => _performWithPopupHandling(() => toolTapNodeAfter('יד*')),
//       timeout: const Duration(seconds: 8),
//     );
//     if (opened) {
//       _handlePhaseComplete(AutomationPhase.phase6);
//       return;
//     }
//     _handleRetry(AutomationPhase.phase6, 'Hand dropdown label not found');
//   }

//   Future<void> _phase7SelectHandValue() async {
//     final handFull =
//         formData.hand.startsWith('יד') ? formData.hand : 'יד ${formData.hand}';
//     final handParts = handFull.split(' ');
//     final handSearch =
//         handParts.length > 1 ? '$handFull|${handParts.last}' : handFull;

//     final selected = await _retryUntil(
//       () => _performWithPopupHandling(() => tapSmart(handSearch)),
//       timeout: const Duration(seconds: 6),
//     );
//     if (selected) {
//       await _closeDropdownIfNeeded();
//       _handlePhaseComplete(AutomationPhase.phase7);
//       return;
//     }
//     _handleRetry(AutomationPhase.phase7, 'Hand value option not found');
//   }

//   Future<void> _phase8OpenCurrentOwnershipDropdown() async {
//     final opened = await _retryUntil(
//       () => _performWithPopupHandling(() => toolTapNodeAfter('בעלות נוכחית')),
//       timeout: const Duration(seconds: 8),
//     );
//     if (opened) {
//       _handlePhaseComplete(AutomationPhase.phase8);
//       return;
//     }
//     _handleRetry(
//       AutomationPhase.phase8,
//       'Current ownership dropdown label not found',
//     );
//   }

//   Future<void> _phase9SelectCurrentOwnershipValue() async {
//     final ownershipParts = formData.currentOwnership.trim().split(' ');
//     final currentOwnershipSearch =
//         ownershipParts.length > 1
//             ? '${formData.currentOwnership.trim()}|${ownershipParts.last}'
//             : formData.currentOwnership.trim();

//     final selected = await _retryUntil(
//       () => _performWithPopupHandling(() => tapSmart(currentOwnershipSearch)),
//       timeout: const Duration(seconds: 6),
//     );
//     if (selected) {
//       await _closeDropdownIfNeeded();
//       _handlePhaseComplete(AutomationPhase.phase9);
//       return;
//     }
//     _handleRetry(
//       AutomationPhase.phase9,
//       'Current ownership value option not found',
//     );
//   }

//   Future<void> _phase10OpenPreviousOwnershipDropdown() async {
//     final opened = await _retryUntil(
//       () => _performWithPopupHandling(() => toolTapNodeAfter('בעלות מקורית')),
//       timeout: const Duration(seconds: 8),
//     );
//     if (opened) {
//       _handlePhaseComplete(AutomationPhase.phase10);
//       return;
//     }
//     _handleRetry(
//       AutomationPhase.phase10,
//       'Previous ownership dropdown label not found',
//     );
//   }

//   Future<void> _phase11SelectPreviousOwnershipValue() async {
//     final ownershipParts = formData.previousOwnership.trim().split(' ');
//     final previousOwnershipSearch =
//         ownershipParts.length > 1
//             ? '${formData.previousOwnership.trim()}|${ownershipParts.last}'
//             : formData.previousOwnership.trim();

//     final selected = await _retryUntil(
//       () => _performWithPopupHandling(() => tapSmart(previousOwnershipSearch)),
//       timeout: const Duration(seconds: 6),
//     );
//     if (selected) {
//       await _closeDropdownIfNeeded();
//       _handlePhaseComplete(AutomationPhase.phase11);
//       return;
//     }
//     _handleRetry(
//       AutomationPhase.phase11,
//       'Previous ownership value option not found',
//     );
//   }

//   Future<void> _phase12EnterKilometers() async {
//     await _scrollDown(0.2);
//     final entered = await _retryUntil(
//       () => _performWithPopupHandling(() async {
//         if (await toolTapNodeAfter('קילומטראז')) {
//           await Future.delayed(const Duration(milliseconds: 650));
//           // Use JS injection to avoid native paste doubling issues on masked fields
//           await toolEnterTextAtFocusedJs(formData.kilometers);
//           return true;
//         }
//         return false;
//       }),
//       timeout: const Duration(seconds: 8),
//     );
//     if (!entered) {
//       _handleRetry(AutomationPhase.phase12, 'Kilometers input field not found');
//       return;
//     }
//     // Close the keyboard
//     await Future.delayed(const Duration(milliseconds: 650));
//     await toolPressBack();
//     await Future.delayed(const Duration(milliseconds: 650));

//     _handlePhaseComplete(AutomationPhase.phase12);
//   }

//   Future<void> _phase13Disability() async {
//     if (formData.handicapped) {
//       await _retryUntil(
//         () => tapSmart('מותאם לנכים'),
//         timeout: const Duration(seconds: 4),
//       );
//     }

//     _handlePhaseComplete(AutomationPhase.phase13);
//   }

//   Future<void> _phase14EnterAdditionalInfo() async {
//     await _scrollDown(0.1);
//     // 1. Check for PRE-submit popup
//     if (await toolFindElementAndTap(
//       'עדכנתי, בוא נמשיך|עדכנתי|בוא נמשיך',
//       deltaY: -15,
//     )) {
//       debugPrint(
//         '[Yad2-A11y] 👆 Tapped "עדכנתי בוא נמשיך" popup button before submit...',
//       );
//       await Future.delayed(const Duration(milliseconds: 800));
//       await _scrollDown(0.2);
//     } else {
//       await _scrollDown(0.2);
//     }

//     final submitted = await _retryUntil(
//       () => tapSmart('לשלב הבא|שלב הבא'),
//       timeout: const Duration(seconds: 8),
//     );
//     if (!submitted) {
//       _handleRetry(AutomationPhase.phase14, 'Submit button לשלב הבא not found');
//       return;
//     }

//     await Future.delayed(const Duration(milliseconds: 1500));

//     // 3. Check for POST-submit popup
//     if (await toolFindElementAndTap(
//       'עדכנתי, בואו נמשיך|עדכנתי, בוא נמשיך',
//       deltaY: -15,
//     )) {
//       debugPrint(
//         '[Yad2-A11y] 👆 Tapped "עדכנתי בואו נמשיך" popup button post-submit...',
//       );
//       await Future.delayed(const Duration(milliseconds: 1500));
//       await _scrollDown(0.2);
//       await Future.delayed(const Duration(milliseconds: 650));

//       if (await toolFindElementAndTap('לשלב הבא|שלב הבא')) {
//         debugPrint('[Yad2-A11y] 👆 Tapped "לשלב הבא" submit button again...');
//         await Future.delayed(const Duration(milliseconds: 1200));
//       }
//     }

//     _handlePhaseComplete(AutomationPhase.phase14);
//   }

//   Future<void> _phase15SelectCity() async {
//     await _scrollDown(0.1);
//     final cityVal = formData.city.isNotEmpty ? formData.city : 'חיפה';
//     final typedVal =
//         cityVal.length > 1 ? cityVal.substring(0, cityVal.length - 1) : cityVal;

//     // 1. Tap the initial city field to open the autocomplete search UI
//     final fieldTapped = await _retryUntil(
//       () => _performWithPopupHandling(() => toolTapNodeAfter('ישוב*')),
//       timeout: const Duration(seconds: 8),
//     );
//     if (!fieldTapped) {
//       _handleRetry(AutomationPhase.phase15, 'City input label not found');
//       return;
//     }

//     // 3. Type letter by letter to trigger autocomplete logic
//     String currentText = "";
//     for (int i = 0; i < typedVal.length; i++) {
//       currentText += typedVal[i];

//       // Use JS injection on the active element to guarantee we don't lose focus
//       await toolEnterTextAtFocusedJs(currentText);
//       await Future.delayed(const Duration(milliseconds: 300));
//     }

//     // 4. Poll for the dropdown suggestion — the autocomplete API latency
//     // varies, so a fixed wait either wastes time or fires too early.
//     final picked = await _retryUntil(
//       () => tapSmart(cityVal),
//       timeout: const Duration(seconds: 8),
//     );
//     if (picked) {
//       _handlePhaseComplete(AutomationPhase.phase15);
//       return;
//     }

//     _handleRetry(AutomationPhase.phase15, 'City value option not found');
//   }

//   Future<void> _phase16EnterPrice() async {
//     debugPrint('[Yad2-A11y] Entered Price logic');
//     final priceText = formData.price.isNotEmpty ? formData.price : '80000';
//     final entered = await _retryUntil(
//       () => _performWithPopupHandling(() async {
//         if (await toolTapNodeAfter('מחיר', offset: 1)) {
//           await Future.delayed(const Duration(milliseconds: 650));
//           await toolEnterTextAtFocusedJs(priceText);
//           return true;
//         }
//         return false;
//       }),
//       timeout: const Duration(seconds: 8),
//     );
//     if (!entered) {
//       _handleRetry(AutomationPhase.phase16, 'Price input field not found');
//       return;
//     }
//     // Close the keyboard
//     await Future.delayed(const Duration(milliseconds: 650));
//     await toolPressBack();
//     await Future.delayed(const Duration(milliseconds: 650));

//     await _scrollDown(0.5);

//     final submitted = await _retryUntil(
//       () => tapSmart('לשלב הבא|שלב הבא|לשלב'),
//       timeout: const Duration(seconds: 8),
//     );
//     if (submitted) {
//       _handlePhaseComplete(AutomationPhase.phase16);
//       return;
//     }
//     _handleRetry(
//       AutomationPhase.phase16,
//       'Submit button after price not found',
//     );
//   }

//   Future<void> _phase17() async {
//     debugPrint(
//       '[Yad2-A11y] Upload Photos phase reached. Proceeding to submit.',
//     );

//     // Convert local images to base64 and upload them via JS injection
//     final images = formData.images;
//     if (images == null || images.isEmpty) {
//       debugPrint(
//         '[Yad2-A11y] ⚠️ No images selected, proceeding directly to next step...',
//       );
//     } else {
//       debugPrint(
//         '[Yad2-A11y] ⏳ Converting ${images.length} images to base64 for upload...',
//       );
//       final List<Map<String, String>> base64Files = [];
//       for (int i = 0; i < images.length; i++) {
//         final path = images[i];
//         if (path.isEmpty) continue;
//         try {
//           final file = File(path);
//           if (await file.exists()) {
//             final bytes = await file.readAsBytes();
//             final base64String = base64Encode(bytes);
//             final ext = path.split('.').last.toLowerCase();
//             final mimeType =
//                 (ext == 'jpg' || ext == 'jpeg') ? 'image/jpeg' : 'image/png';
//             base64Files.add({
//               'base64': 'data:$mimeType;base64,$base64String',
//               'filename': 'photo_${i + 1}.$ext',
//               'contentType': mimeType,
//             });
//           }
//         } catch (e) {
//           debugPrint('[Yad2-A11y] Error converting image $path to base64: $e');
//         }
//       }

//       if (base64Files.isNotEmpty) {
//         debugPrint(
//           '[Yad2-A11y] 📤 Injecting ${base64Files.length} images into WebView file input...',
//         );
//         final jsonFiles = jsonEncode(base64Files);
//         final jsScript = '''
//           (function() {
//             var filesArray = $jsonFiles;
//             var fileInput = document.querySelector('input[type="file"]') 
//                          || document.querySelector('input[accept*="image"]')
//                          || document.querySelector('input[name*="file"]')
//                          || document.querySelector('input[id*="file"]');
//             if (!fileInput) {
//               console.error('File input not found');
//               return 'no_input';
//             }

//             var container = new DataTransfer();
//             for (var k = 0; k < filesArray.length; k++) {
//               var item = filesArray[k];
//               var base64Data = item.base64;
//               var filename = item.filename;
//               var contentType = item.contentType;

//               var byteString = atob(base64Data.split(',')[1] || base64Data);
//               var ab = new ArrayBuffer(byteString.length);
//               var ia = new Uint8Array(ab);
//               for (var i = 0; i < byteString.length; i++) {
//                 ia[i] = byteString.charCodeAt(i);
//               }
//               var blob = new Blob([ab], {type: contentType});
//               var file = new File([blob], filename, {type: contentType});
//               container.items.add(file);
//             }

//             fileInput.files = container.files;
//             var event = new Event('change', { bubbles: true });
//             fileInput.dispatchEvent(event);
//             return 'ok';
//           })()
//         ''';

//         final result = await controller.runJavaScriptReturningResult(jsScript);
//         debugPrint('[Yad2-A11y] ✅ JS upload execution result: $result');

//         // Wait for upload to complete on server/UI
//         await Future.delayed(const Duration(milliseconds: 3000));
//       } else {
//         debugPrint('[Yad2-A11y] ⚠️ No valid local image files found to upload');
//       }
//     }

//     await _scrollDown(0.75);
//     await Future.delayed(const Duration(milliseconds: 650));

//     final submitted = await _retryUntil(
//       () => _performWithPopupHandling(
//         () => tapSmart('לשלב הבא|שלב הבא|המשך|לשלב'),
//       ),
//       timeout: const Duration(seconds: 10),
//     );
//     if (!submitted) {
//       _handleRetry(
//         AutomationPhase.phase17,
//         'Submit button not found on photos page',
//       );
//       return;
//     }
//     _handlePhaseComplete(AutomationPhase.phase17);
//   }

//   // ── Flow Controllers ──────────────────────────────────────────────────────

//   void _handlePhaseComplete(AutomationPhase phase) {
//     debugPrint('[Yad2-A11y] ✅ Phase complete: ${phase.description}');
//     onPhaseComplete?.call(phase);

//     AutomationPhase? next;
//     int delayMs = 1000;

//     switch (phase) {
//       case AutomationPhase.phase1:
//         next = AutomationPhase.phase2;
//         delayMs = 500;
//         break;
//       case AutomationPhase.phase2:
//         next = AutomationPhase.phase3;
//         delayMs = 500;
//         break;
//       case AutomationPhase.phase3:
//         next = AutomationPhase.phase4;
//         delayMs = 1000;
//         break;
//       case AutomationPhase.phase4:
//         next = AutomationPhase.phase5;
//         break;
//       case AutomationPhase.phase5:
//         next = AutomationPhase.phase5a;
//         delayMs = 700;
//         break;
//       case AutomationPhase.phase5a:
//         next = AutomationPhase.phase5b;
//         delayMs = 700;
//         break;
//       case AutomationPhase.phase5b:
//         next = AutomationPhase.phase5c;
//         delayMs = 500;
//         break;
//       case AutomationPhase.phase5c:
//         next = AutomationPhase.phase5d;
//         delayMs = 700;
//         break;
//       case AutomationPhase.phase5d:
//         next = AutomationPhase.phase5e;
//         delayMs = 700;
//         break;
//       case AutomationPhase.phase5e:
//         next = AutomationPhase.phase5f;
//         delayMs = 700;
//         break;
//       case AutomationPhase.phase5f:
//         next = AutomationPhase.phase6;
//         delayMs = 700;
//         break;
//       case AutomationPhase.phase6:
//         next = AutomationPhase.phase7;
//         delayMs = 700;
//         break;
//       case AutomationPhase.phase7:
//         next = AutomationPhase.phase8;
//         delayMs = 500;
//         break;
//       case AutomationPhase.phase8:
//         next = AutomationPhase.phase9;
//         delayMs = 700;
//         break;
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
//         break;
//       case AutomationPhase.phase10:
//         next = AutomationPhase.phase11;
//         break;
//       case AutomationPhase.phase11:
//         next = AutomationPhase.phase12;
//         break;
//       case AutomationPhase.phase12:
//         next = AutomationPhase.phase13;
//         break;
//       case AutomationPhase.phase13:
//         next = AutomationPhase.phase14;
//         delayMs = 1000;
//         break;
//       case AutomationPhase.phase14:
//         next = AutomationPhase.phase15;
//         delayMs = 1000;
//         break;
//       case AutomationPhase.phase15:
//         next = AutomationPhase.phase16;
//         delayMs = 1000;
//         break;
//       case AutomationPhase.phase16:
//         next = AutomationPhase.phase17;
//         delayMs = 1000;
//         break;
//       case AutomationPhase.phase17:
//         next = AutomationPhase.complete;
//         delayMs = 700;
//         break;
//       case AutomationPhase.complete:
//         onAutomationComplete?.call(true);
//         return;
//     }

//     Future.delayed(Duration(milliseconds: delayMs), () {
//       _processPhase(next!);
//     });
//   }

//   Future<void> _handleError(AutomationPhase phase, String error) async {
//     debugPrint('[Yad2-A11y] ❌ Phase error: ${phase.description} — $error');
//     _isPaused = true;
//     _pausedPhase = phase;
//     _phaseRetryCount = 0;
//     try {
//       await _beepUser();
//     } catch (e) {
//       debugPrint('[Yad2-A11y] Error playing error beep: $e');
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
//       // Escalating backoff: later retries usually fail because the page is
//       // still loading, so give it progressively more time to settle.
//       final backoffMs = 1000 * _phaseRetryCount;
//       debugPrint(
//         '[Yad2-A11y] 🔄 Retrying phase $_phaseRetryCount/$_maxRetries in ${backoffMs}ms — $reason',
//       );
//       Future.delayed(Duration(milliseconds: backoffMs), () {
//         _executePhase(phase);
//       });
//     } else {
//       _handleError(phase, reason);
//     }
//   }

//   Future<void> _beepUser() async {
//     debugPrint('[Yad2-A11y] 🔔 Beeping user for manual interaction');
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
// }
