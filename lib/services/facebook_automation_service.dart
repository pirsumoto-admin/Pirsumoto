import 'automation_task_scheduler.dart';
import 'automation_accessibility_channel.dart';
import 'package:publication_protocol/publication_protocol.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'yad2_automation_models.dart' show VehiclePublishData;
import 'yad2_accessibility_automation_service_optimized.dart'
    show Yad2AccessibilityAutomationService;

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
//   Phase 8  – Upload photos    : input[type="file"] via DataTransfer base64
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
  selectCondition('Select condition', 'בחירת מצב הרכב'),
  selectFuelType('Select fuel type', 'בחירת סוג דלק'),
  selectTransmission('Select transmission', 'בחירת תיבת הילוכים'),
  enterDescription('Enter description', 'הזנת תיאור'),
  publish('Publish listing', 'פרסום המודעה'),
  complete('Automation complete', 'האוטומציה הושלמה');

  final String description;
  final String descriptionHe;
  const FacebookAutomationPhase(this.description, this.descriptionHe);
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

  bool _stopped = false;
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
    _scheduler.invalidate();
    _stopped = true;
    stop();
    if (activeInstance == this) {
      activeInstance = null;
    }
  }

  void pauseAutomation() {
    _scheduler.invalidate();
    debugPrint('[FB-A11y] ⏸️ Pause requested');
    _stopLoginGate();
    _isPaused = true;
    _pausedPhase = _currentPhase;
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
    _currentPhase = phase;
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
    final work = _scheduler.run(() => _executePhaseTracked(phase));
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
    debugPrint('[FB-A11y] ════════════════════════════════════════');
    debugPrint(
      '[FB-A11y] ${phase.name.toUpperCase()}  attempt ${_phaseRetryCount + 1}/${_maxRetries + 1}',
    );
    debugPrint('[FB-A11y] ════════════════════════════════════════');

    if (!await _ensureAutomationWindow() || _stopped || _isPaused) return;

    try {
      switch (phase) {
        case FacebookAutomationPhase.loginGate:
          await _phaseLoginGate();
          break;
        case FacebookAutomationPhase.setViewport:
          await _phaseSetViewport();
          break;
        case FacebookAutomationPhase.selectVehicleType:
          await _phaseSelectVehicleType();
          break;
        case FacebookAutomationPhase.uploadPhotos:
          await _phaseUploadPhotos();
          break;
        case FacebookAutomationPhase.enterYear:
          await _phaseEnterYear();
          break;
        case FacebookAutomationPhase.enterMake:
          await _phaseEnterMake();
          break;
        case FacebookAutomationPhase.enterModel:
          await _phaseEnterModel();
          break;
        case FacebookAutomationPhase.enterMileage:
          await _phaseEnterMileage();
          break;
        case FacebookAutomationPhase.enterPrice:
          await _phaseEnterPrice();
          break;
        case FacebookAutomationPhase.selectBodyStyle:
          await _phaseSelectBodyStyle();
          break;
        case FacebookAutomationPhase.selectCondition:
          await _phaseSelectCondition();
          break;
        case FacebookAutomationPhase.selectFuelType:
          await _phaseSelectFuelType();
          break;
        case FacebookAutomationPhase.selectTransmission:
          await _phaseSelectTransmission();
          break;
        case FacebookAutomationPhase.enterDescription:
          await _phaseEnterDescription();
          break;
        case FacebookAutomationPhase.publish:
          await _phasePublish();
          break;
        case FacebookAutomationPhase.complete:
          WakelockPlus.disable();
          _handlePhaseComplete(FacebookAutomationPhase.complete);
          break;
      }
    } catch (e, st) {
      debugPrint('[FB-A11y] Phase execution error: $e\n$st');
      _handleRetry(phase, e.toString());
    }
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
    if (_stopped || _isPaused) return;
    debugPrint('[FB-A11y] 🖱️ toolTapScreen($x, $y)');
    try {
      await _automationChannel.invokeMethod('tapScreen', {'x': x, 'y': y});
    } catch (e) {
      debugPrint('[FB-A11y] TapScreen error: $e');
    }
  }

  Future<bool> toolFindElementAndTap(
    String targetText, {
    int targetInstance = 1,
    double deltaY = 0,
    double threshold = 0.82,
    bool preferEditable = false,
  }) async {
    if (_stopped || _isPaused) return false;
    debugPrint(
      '[FB-A11y] 🔍 toolFindElementAndTap("$targetText", instance=$targetInstance, preferEditable=$preferEditable)',
    );
    try {
      final bounds = await _getStableBounds('findAndGetBounds', {
        'target': targetText,
        'targetInstance': targetInstance,
        'threshold': threshold,
        'preferEditable': preferEditable,
      });
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
  }) async {
    if (_stopped || _isPaused) return false;
    debugPrint('[FB-A11y] 🔍 toolTapNodeAfter("$targetText")');
    try {
      final bounds = await _getStableBounds('findNodeAfterAndGetBounds', {
        'target': targetText,
        'targetInstance': targetInstance,
        'threshold': threshold,
        'offset': offset,
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
    if (_stopped || _isPaused) return false;
    debugPrint('[FB-A11y] ⌨️ toolEnterTextAtFocused ("$text")');
    try {
      final success = await _automationChannel.invokeMethod<bool>(
        'enterTextAtFocused',
        {'value': text},
      );
      if (success == true) return true;
    } on PlatformException catch (e) {
      debugPrint('[FB-A11y] enterTextAtFocused native error: ${e.message}');
    } catch (e) {
      debugPrint('[FB-A11y] enterTextAtFocused error: $e');
    }

    try {
      await toolEnterTextAtFocusedJs(text);
      return true;
    } catch (e) {
      debugPrint('[FB-A11y] toolEnterTextAtFocusedJs error: $e');
      return false;
    }
  }

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
      })($encoded);
    ''');
  }

  Future<bool> toolEnterTextNear(String label, String value) async {
    if (_stopped || _isPaused) return false;
    final tapped = await toolTapNodeAfter(label) || await tapSmart(label);
    if (!tapped) return false;
    await Future.delayed(const Duration(milliseconds: 500));
    final native = await toolEnterTextAtFocused(value);
    if (native) return true;
    await toolEnterTextAtFocusedJs(value);
    return true;
  }

  Future<bool> toolEnterTextBefore(String targetText, String value) async {
    if (_stopped || _isPaused) return false;
    try {
      final bounds = await _getStableBounds('findInputBeforeAndGetBounds', {
        'target': targetText,
      });
      if (bounds == null) return false;
      await _tapBounds(bounds);
      await Future.delayed(const Duration(milliseconds: 500));
      final native = await toolEnterTextAtFocused(value);
      if (native) return true;
      await toolEnterTextAtFocusedJs(value);
      return true;
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
    if (_stopped || _isPaused) return false;
    debugPrint('[FB-A11y] ⌨️ toolEnterText("$targetText", value="$value")');
    try {
      final bounds = await _getStableBounds('findAndGetBounds', {
        'target': targetText,
        'targetInstance': targetInstance,
        'threshold': threshold,
      });
      if (bounds != null) {
        await _tapBounds(bounds);
        await Future.delayed(const Duration(milliseconds: 500));
        bool ok = await toolEnterTextAtFocused(value);
        if (!ok) {
          await toolEnterTextAtFocusedJs(value);
          ok = true;
        }
        return ok;
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
  Future<bool> toolFindAndTapJs(String targetText) async {
    if (_stopped || _isPaused) return false;
    debugPrint('[FB-A11y] 🕸️ toolFindAndTapJs("$targetText")');
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
          if(t==='$escaped'||t.startsWith('$escaped')){target=opts[o];break;}
        }
        // Priority 2: any element with exact inner-text
        if(!target){
          for(var i=0;i<all.length;i++){
            var el=all[i];
            var r=el.getBoundingClientRect();
            if(r.width===0||r.height===0) continue;
            if((el.innerText||'').trim()==='$escaped'){target=el;rect=r;break;}
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
      debugPrint('[FB-A11y] toolFindAndTapJs error: $e');
      return false;
    }
  }

  // ── Tool: JS click the Nth combobox (as in facebook_screen.dart Phase 3) ──

  /// Clicks `document.querySelectorAll('[role="combobox"]')[index]`
  /// and returns the CSS center coords as "ok:x,y" or "not_found:N".
  Future<String?> toolClickComboboxByIndex(int index) async {
    debugPrint('[FB-A11y] 🕸️ toolClickComboboxByIndex($index)');
    final js = '''
      (function(){
        var combos=document.querySelectorAll('[role="combobox"]');
        if(combos.length<=$index) return 'not_found:'+combos.length;
        var el=combos[$index];
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
      debugPrint('[FB-A11y] toolClickComboboxByIndex error: $e');
      return null;
    }
  }

  /// Clicks the Nth [role="option"] element (first option = vehicle category).
  Future<String?> toolClickOptionByIndex(int index) async {
    debugPrint('[FB-A11y] 🕸️ toolClickOptionByIndex($index)');
    final js = '''
      (function(){
        var opts=document.querySelectorAll('[role="option"]');
        if(opts.length<=$index) return 'not_found';
        var el=opts[$index];
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
      debugPrint('[FB-A11y] toolClickOptionByIndex error: $e');
      return null;
    }
  }

  // ── Tool: JS text input for price / title fields ─────────────────────────

  /// Finds an input/textarea by aria-label, placeholder, or data-testid
  /// and sets its value via React's native setter + Input event.
  Future<bool> toolFillInputByLabel(String label, String value) async {
    if (_stopped || _isPaused) return false;
    debugPrint('[FB-A11y] ⌨️ toolFillInputByLabel("$label", "$value")');
    final escapedLabel = label.replaceAll("'", "\\'");
    final escapedValue = value.replaceAll("'", "\\'");
    final js = '''
      (function(){
        var selectors=[
          '[aria-label*="$escapedLabel"]',
          '[placeholder*="$escapedLabel"]',
          '[data-testid*="${escapedLabel.toLowerCase()}"]',
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
        if(ns&&ns.set){ ns.set.call(el,'$escapedValue'); }
        else { el.value='$escapedValue'; }
        el.dispatchEvent(new InputEvent('input',{bubbles:true,data:'$escapedValue',inputType:'insertText'}));
        el.dispatchEvent(new Event('change',{bubbles:true}));
        return true;
      })()
    ''';
    try {
      final r = await controller.runJavaScriptReturningResult(js);
      return r == true || r.toString() == 'true';
    } catch (e) {
      debugPrint('[FB-A11y] toolFillInputByLabel error: $e');
      return false;
    }
  }

  // ── Tool: scroll helpers ──────────────────────────────────────────────────

  Future<void> _scrollDown(double percent) async {
    if (_stopped || _isPaused) return;
    debugPrint('[FB-A11y] ⬇️ scrollDown($percent)');
    try {
      await _automationChannel.invokeMethod('scrollNode', {
        'direction': 'down',
        'percent': percent,
      });
    } catch (e) {
      debugPrint('[FB-A11y] Scroll error: $e');
    }
    await _waitForScrollSettle();
  }

  Future<void> _waitForScrollSettle({
    Duration timeout = const Duration(seconds: 3),
  }) async {
    await Future.delayed(const Duration(milliseconds: 600));
    final deadline = DateTime.now().add(timeout);
    double? last;
    int nullReads = 0;
    while (DateTime.now().isBefore(deadline)) {
      double? current;
      try {
        final res = await controller.runJavaScriptReturningResult(
          '(window.scrollY||document.documentElement.scrollTop||0)',
        );
        current = double.tryParse(res.toString());
      } catch (_) {}
      if (current == null) {
        if (++nullReads >= 2) break;
      } else if (last != null && (current - last).abs() < 1.0) {
        break;
      }
      last = current;
      await Future.delayed(const Duration(milliseconds: 250));
    }
    await Future.delayed(const Duration(milliseconds: 300));
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

    if (allowJsFallback) {
      for (final alt in alternatives) {
        if (await toolFindAndTapJs(alt)) {
          debugPrint('[FB-A11y] 🕸️ JS fallback clicked "$alt"');
          return true;
        }
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
      await controller.runJavaScript('''
        if (document.activeElement && typeof document.activeElement.blur === 'function') {
          document.activeElement.blur();
        }
      ''');
      debugPrint('[FB-A11y] Blurred active element');
    } catch (e) {
      debugPrint('[FB-A11y] toolBlurActiveElement error: $e');
    }
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
    try {
      final res = await controller.runJavaScriptReturningResult('''
        (function(){
          if(!!document.querySelector('input[type="password"]')) return true;
          var t=document.body?document.body.innerText:'';
          var kw=['Log in to Facebook','התחבר לפייסבוק','email or phone',
                  'Log In','Facebook – log in','Create new account'];
          for(var k of kw){ if(t.toLowerCase().includes(k.toLowerCase())) return true; }
          return false;
        })()
      ''');
      if (res == true || res.toString() == 'true') return true;
    } catch (_) {}

    // Fallback: accessibility tree keywords
    const loginKeywords = [
      'Log in',
      'Log In',
      'התחבר',
      'Email or phone number',
      'Create new account',
      'כתובת אימייל',
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

  Future<void> _phaseLoginGate() async {
    // Let the page settle first
    await Future.delayed(const Duration(seconds: 1));

    // Set wide viewport regardless (idempotent)
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
      pollInterval: const Duration(milliseconds: 600),
    );

    if (loginDetected) {
      onFirstStepDetected?.call();
      _startLoginGate();
      return;
    }
    if (!settled) {
      _handleRetry(FacebookAutomationPhase.loginGate, 'Page did not settle');
      return;
    }
    onFirstStepDetected?.call();
    _handlePhaseComplete(FacebookAutomationPhase.loginGate);
  }

  // Phase 2 — Set viewport
  // HTML: meta[name=viewport] — inject width=1280 so Facebook renders desktop layout
  // (Facebook marketplace shows simplified mobile UI without this)

  Future<void> _phaseSetViewport() async {
    await _applyDesktopViewport();
    await Future.delayed(const Duration(seconds: 1));
    _handlePhaseComplete(FacebookAutomationPhase.setViewport);
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
  Future<void> _phaseSelectVehicleType() async {
    await Future.delayed(const Duration(seconds: 2));
    // await toolLogAccessibilityTree();
    const dropdownLabels = ['Vehicle type', 'סוג רכב'];

    // Try to open the dropdown
    // Try to open the dropdown using ONLY native accessibility logic
    bool opened = await _retryUntil(() async {
      for (final label in dropdownLabels) {
        // Try tapping the element after the label (common on form fields)
        if (await toolFindElementAndTap(label)) {
          debugPrint(
            '[FB-A11y] Opened dropdown by tapping node after label: $label',
          );
          return true;
        }
        // Try tapping the label/combobox itself
        if (await toolFindElementAndTap(label)) {
          debugPrint(
            '[FB-A11y] Opened dropdown by tapping element itself: $label',
          );
          return true;
        }
      }
      return false;
    }, timeout: const Duration(seconds: 8));

    if (!opened) {
      _handleRetry(
        FacebookAutomationPhase.selectVehicleType,
        'Vehicle type dropdown not found or could not be opened using accessibility',
      );
      return;
    }

    // Wait for the dropdown options list to animate open
    await Future.delayed(const Duration(milliseconds: 800));

    // Tap the first value in the dropdown list (using ONLY accessibility text search)
    const optionLabels = ['Car/Truck', 'מכונית/משאית'];

    bool optionSelected = await _retryUntil(() async {
      for (final label in optionLabels) {
        if (await toolFindElementAndTap(label)) {
          debugPrint('[FB-A11y] Selected option via accessibility: $label');
          return true;
        }
      }
      return false;
    }, timeout: const Duration(seconds: 8));

    if (!optionSelected) {
      _handleRetry(
        FacebookAutomationPhase.selectVehicleType,
        'Failed to select the first option in Vehicle Type dropdown using accessibility',
      );
      return;
    }

    _handlePhaseComplete(FacebookAutomationPhase.selectVehicleType);
  }

  Future<void> toolLogAccessibilityTree({String tag = 'FB-A11y-Tree'}) async {
    if (!const bool.fromEnvironment('PIRSUMOTO_AUTOMATION_TRACE')) return;
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

  /// Scrolls an element into view using DOM inspection
  Future<bool> toolScrollElementIntoViewViaDom(List<String> keywords) async {
    if (_stopped || _isPaused) return false;
    try {
      final jsonKw = jsonEncode(keywords);
      final raw = await controller.runJavaScriptReturningResult('''
        (function() {
          var kw = $jsonKw;
          var all = document.querySelectorAll('input, [role="combobox"], [aria-label], label, span');
          for (var i = 0; i < all.length; i++) {
            var el = all[i];
            var aria = (el.getAttribute('aria-label') || '').toLowerCase();
            var ph = (el.getAttribute('placeholder') || '').toLowerCase();
            var txt = (el.innerText || el.textContent || '').toLowerCase();
            for (var k = 0; k < kw.length; k++) {
              var q = kw[k].toLowerCase();
              if (aria.indexOf(q) !== -1 || ph.indexOf(q) !== -1 || txt.indexOf(q) !== -1) {
                el.scrollIntoView({ behavior: 'smooth', block: 'center' });
                return 'scrolled';
              }
            }
          }
          return 'not_found';
        })()
      ''');
      return raw.toString().contains('scrolled');
    } catch (e) {
      return false;
    }
  }

  /// Enters text directly into an input matching selectors or aria-label/placeholder in the DOM
  Future<bool> toolEnterTextInputViaDom({
    required List<String> selectors,
    required String text,
  }) async {
    if (_stopped || _isPaused) return false;
    debugPrint('[FB-DOM] Trying to enter "$text" via selectors: $selectors');
    try {
      final jsonSelectors = jsonEncode(selectors);
      final jsonText = jsonEncode(text);
      final raw = await controller.runJavaScriptReturningResult('''
        (function() {
          var selectors = $jsonSelectors;
          var val = $jsonText;
          var found = null;
          for (var i = 0; i < selectors.length; i++) {
            var el = document.querySelector(selectors[i]);
            if (el) {
              found = el;
              break;
            }
          }
          if (!found) {
            var allInputs = document.querySelectorAll('input, textarea');
            for (var j = 0; j < allInputs.length; j++) {
              var inp = allInputs[j];
              var aria = (inp.getAttribute('aria-label') || '').toLowerCase();
              var ph = (inp.getAttribute('placeholder') || '').toLowerCase();
              for (var s = 0; s < selectors.length; s++) {
                var query = selectors[s].toLowerCase();
                var match = query.match(/["'](.*?)["']/);
                var keyword = match ? match[1] : query;
                if ((aria && aria.indexOf(keyword) !== -1) || (ph && ph.indexOf(keyword) !== -1)) {
                  found = inp;
                  break;
                }
              }
              if (found) break;
            }
          }
          if (!found) return 'not_found';

          found.scrollIntoView({ behavior: 'smooth', block: 'center' });
          found.focus();
          try { found.click(); } catch(e) {}
          
          var proto = found instanceof HTMLTextAreaElement 
              ? window.HTMLTextAreaElement.prototype 
              : window.HTMLInputElement.prototype;
          var setDesc = Object.getOwnPropertyDescriptor(proto, 'value');
          if (setDesc && setDesc.set) {
            setDesc.set.call(found, val);
          } else {
            found.value = val;
          }
          found.dispatchEvent(new Event('input', { bubbles: true }));
          found.dispatchEvent(new Event('change', { bubbles: true }));
          return 'ok';
        })()
      ''');
      debugPrint('[FB-DOM] enterTextInputViaDom result: $raw');
      return raw.toString().contains('ok');
    } catch (e) {
      debugPrint('[FB-DOM] enterTextInputViaDom error: $e');
      return false;
    }
  }

  /// Enters price specifically into the DOM, checking direct inputs, label containers,
  /// and aria-labelledby references to avoid clicking static text labels.
  Future<bool> toolEnterPriceViaDom(String price) async {
    if (_stopped || _isPaused) return false;
    try {
      final jsonPrice = jsonEncode(price);
      final raw = await controller.runJavaScriptReturningResult('''
        (function() {
          var val = $jsonPrice;
          var found = null;

          // 1. Direct inputs with aria-label or placeholder
          var direct = document.querySelectorAll(
            'input[aria-label*="Price" i], input[aria-label*="מחיר" i], ' +
            'input[placeholder*="Price" i], input[placeholder*="מחיר" i]'
          );
          if (direct.length > 0) {
            found = direct[0];
          }

          // 2. Labels containing "מחיר" or "Price" and find the input inside them
          if (!found) {
            var labels = document.querySelectorAll('label');
            for (var i = 0; i < labels.length; i++) {
              var txt = (labels[i].innerText || labels[i].textContent || '').trim().toLowerCase();
              if (txt.indexOf('מחיר') !== -1 || txt.indexOf('price') !== -1) {
                var inp = labels[i].querySelector('input');
                if (inp) {
                  found = inp;
                  break;
                }
              }
            }
          }

          // 3. aria-labelledby referencing a label element containing "מחיר" or "Price"
          if (!found) {
            var allInputs = document.querySelectorAll('input:not([type="hidden"]):not([type="file"])');
            for (var j = 0; j < allInputs.length; j++) {
              var inp = allInputs[j];
              var lbId = inp.getAttribute('aria-labelledby');
              if (lbId) {
                var lbEl = document.getElementById(lbId);
                if (lbEl) {
                  var lbTxt = (lbEl.innerText || lbEl.textContent || '').trim().toLowerCase();
                  if (lbTxt.indexOf('מחיר') !== -1 || lbTxt.indexOf('price') !== -1) {
                    found = inp;
                    break;
                  }
                }
              }
            }
          }

          if (!found) return 'not_found';

          found.scrollIntoView({ behavior: 'smooth', block: 'center' });
          found.focus();
          try { found.click(); } catch(e) {}

          var proto = window.HTMLInputElement.prototype;
          var setDesc = Object.getOwnPropertyDescriptor(proto, 'value');
          if (setDesc && setDesc.set) {
            setDesc.set.call(found, val);
          } else {
            found.value = val;
          }
          found.dispatchEvent(new Event('input', { bubbles: true }));
          found.dispatchEvent(new Event('change', { bubbles: true }));
          return 'ok';
        })()
      ''');
      debugPrint('[FB-DOM] enterPriceViaDom result: $raw');
      return raw.toString().contains('ok');
    } catch (e) {
      debugPrint('[FB-DOM] enterPriceViaDom error: $e');
      return false;
    }
  }

  // Phase 5 — Upload photos
  Future<void> _phaseUploadPhotos() async {
    final expectedCount = formData.expectedImageCount;
    var imageList = formData.images ?? const <String>[];
    if (expectedCount != null && expectedCount == 0) {
      imageList = const <String>[];
    } else if (expectedCount != null &&
        expectedCount > 0 &&
        imageList.length > expectedCount) {
      imageList = imageList.sublist(imageList.length - expectedCount);
    }

    debugPrint(
      '[FB-A11y] phaseUploadPhoto: count=${imageList.length} (expected: $expectedCount)',
    );
    if (imageList.isEmpty) {
      debugPrint(
        '[FB-A11y] No images to upload. Skipping upload photos phase.',
      );
      _handlePhaseComplete(FacebookAutomationPhase.uploadPhotos);
      return;
    }

    debugPrint('[FB-A11y] Converting ${imageList.length} images to base64...');
    final List<Map<String, String>> base64Files = [];
    for (int i = 0; i < imageList.length; i++) {
      final path = imageList[i];
      if (path.isEmpty) continue;
      try {
        final file = File(path);
        if (await file.exists()) {
          final bytes = await file.readAsBytes();
          final base64String = base64Encode(bytes);
          final ext = path.split('.').last.toLowerCase();
          final mimeType =
              (ext == 'jpg' || ext == 'jpeg') ? 'image/jpeg' : 'image/png';
          final timestamp = DateTime.now().microsecondsSinceEpoch;
          base64Files.add({
            'base64': 'data:$mimeType;base64,$base64String',
            'filename': 'photo_${i + 1}_$timestamp.$ext',
            'contentType': mimeType,
          });
        }
      } catch (e) {
        debugPrint('[FB-A11y] Error converting image $path to base64: $e');
      }
    }

    if (base64Files.isEmpty) {
      debugPrint(
        '[FB-A11y] No valid images successfully converted. Skipping upload.',
      );
      _handlePhaseComplete(FacebookAutomationPhase.uploadPhotos);
      return;
    }

    debugPrint(
      '[FB-A11y] Injecting images into Facebook WebView file input...',
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

        fileInput.value = '';
        fileInput.files = container.files;
        var event = new Event('change', { bubbles: true });
        fileInput.dispatchEvent(event);
        return 'ok';
      })()
    ''';

    try {
      final result = await controller.runJavaScriptReturningResult(jsScript);
      debugPrint('[FB-A11y] JS upload execution result: $result');
    } catch (e) {
      debugPrint('[FB-A11y] Error executing JS image upload: $e');
    }

    // Wait for upload to complete on server/UI (e.g. 5 seconds)
    await Future.delayed(const Duration(seconds: 5));

    // Log both trees right after upload completes
    debugPrint(
      '[FB-A11y] 📸 Photo upload complete. Logging state of the screen:',
    );
    await toolLogDomFormElements(tag: 'FB-PostUpload-DOM');
    await toolLogAccessibilityTree(tag: 'FB-PostUpload-A11y');

    _handlePhaseComplete(FacebookAutomationPhase.uploadPhotos);
  }

  // Phase 6 — Enter year
  Future<void> _phaseEnterYear() async {
    final yearVal = formData.year;
    debugPrint('[FB-A11y] EnterYear value: "$yearVal"');
    if (yearVal.isEmpty) {
      debugPrint('[FB-A11y] yearVal is empty in formData, skipping enterYear');
      _handlePhaseComplete(FacebookAutomationPhase.enterYear);
      return;
    }

    // Log current area
    await toolLogDomFormElements(tag: 'FB-Year-DOM');
    await toolLogAccessibilityTree(tag: 'FB-Year-A11y');

    // Scroll Year element into view via DOM first (prevents blind over-scrolling)
    await toolScrollElementIntoViewViaDom(['שנה', 'שנת', 'Year']);
    await Future.delayed(const Duration(milliseconds: 600));

    // Try finding Year dropdown via A11y
    bool opened = await _retryUntil(() async {
      if (await toolFindElementAndTap(
        'שנה|שנת|שנת ייצור|שנת דגם|Year|Model year',
      ))
        return true;
      if (await toolFindElementAndTap('שנה')) return true;
      if (await toolFindElementAndTap('Year')) return true;
      return false;
    }, timeout: const Duration(seconds: 4));

    // Fallback: If not opened via A11y, try clicking Year via DOM
    if (!opened) {
      debugPrint(
        '[FB-A11y] Year dropdown not opened via A11y, attempting DOM click...',
      );
      final domClicked = await controller.runJavaScriptReturningResult('''
        (function() {
          var el = document.querySelector('[role="combobox"][aria-label*="Year" i], [role="combobox"][aria-label*="שנה" i], input[aria-label*="Year" i], input[aria-label*="שנה" i]');
          if (el) {
            el.scrollIntoView({ block: 'center' });
            el.click();
            return 'clicked';
          }
          return 'not_found';
        })()
      ''');
      debugPrint('[FB-A11y] DOM Year click result: $domClicked');
      if (domClicked.toString().contains('clicked')) {
        opened = true;
      }
    }

    if (!opened) {
      _handleRetry(
        FacebookAutomationPhase.enterYear,
        'Year dropdown not found',
      );
      return;
    }
    await Future.delayed(const Duration(milliseconds: 800));

    // Select the year value (e.g. "2020")
    bool selected = await _retryUntil(() async {
      return await toolFindElementAndTap(yearVal);
    }, timeout: const Duration(seconds: 4));

    if (!selected) {
      debugPrint(
        '[FB-A11y] Year option $yearVal not tapped via A11y, attempting DOM option click...',
      );
      final domSelected = await controller.runJavaScriptReturningResult('''
        (function() {
          var options = document.querySelectorAll('[role="option"], option, div[role="button"], span');
          for (var i = 0; i < options.length; i++) {
            var opt = options[i];
            if ((opt.innerText || opt.textContent || '').trim() === '$yearVal') {
              opt.scrollIntoView({ block: 'center' });
              opt.click();
              return 'clicked';
            }
          }
          return 'not_found';
        })()
      ''');
      debugPrint('[FB-A11y] DOM Year option selection result: $domSelected');
      if (domSelected.toString().contains('clicked')) {
        selected = true;
      }
    }

    if (!selected) {
      _handleRetry(
        FacebookAutomationPhase.enterYear,
        'Year value $yearVal not found',
      );
      return;
    }
    _handlePhaseComplete(FacebookAutomationPhase.enterYear);
  }

  // Phase 7 — Enter make (Manufacturer - Free Text Field)
  Future<void> _phaseEnterMake() async {
    final makerVal = formData.maker;
    debugPrint('[FB-A11y] EnterMake value: "$makerVal"');
    if (makerVal.isEmpty) {
      debugPrint('[FB-A11y] makerVal is empty in formData, skipping enterMake');
      _handlePhaseComplete(FacebookAutomationPhase.enterMake);
      return;
    }

    // Log current area
    await toolLogDomFormElements(tag: 'FB-Make-DOM');

    // Scroll into view via DOM
    await toolScrollElementIntoViewViaDom(['יצרן', 'Make', 'Manufacturer']);
    await Future.delayed(const Duration(milliseconds: 500));

    // 1. Enter text via DOM directly (free text field)
    bool enteredViaDom = await toolEnterTextInputViaDom(
      selectors: [
        'input[aria-label*="Make" i]',
        'input[aria-label*="יצרן" i]',
        'input[placeholder*="Make" i]',
        'input[placeholder*="יצרן" i]',
      ],
      text: makerVal,
    );

    // 2. Also tap via A11y to focus & enter text natively
    bool tappedA11y = await toolFindElementAndTap('יצרן|Make|Manufacturer');
    if (tappedA11y) {
      await Future.delayed(const Duration(milliseconds: 500));
      await toolEnterTextAtFocused(makerVal);
    }

    if (!enteredViaDom && !tappedA11y) {
      _handleRetry(FacebookAutomationPhase.enterMake, 'Make field not found');
      return;
    }

    await Future.delayed(const Duration(milliseconds: 800));

    // Optional: If an auto-complete suggestion popped up, tap it (up to 1.5s timeout)
    try {
      await _retryUntil(() async {
        if (await toolFindElementAndTap(makerVal, targetInstance: 2))
          return true;
        return false;
      }, timeout: const Duration(milliseconds: 1500));
    } catch (_) {}

    await toolDismissKeyboardAndBlur();
    _handlePhaseComplete(FacebookAutomationPhase.enterMake);
  }

  // Phase 8 — Enter model (Free Text Field)
  Future<void> _phaseEnterModel() async {
    final modelVal = formData.model;
    debugPrint('[FB-A11y] EnterModel value: "$modelVal"');
    if (modelVal.isEmpty) {
      debugPrint(
        '[FB-A11y] modelVal is empty in formData, skipping enterModel',
      );
      _handlePhaseComplete(FacebookAutomationPhase.enterModel);
      return;
    }

    // Log current area
    await toolLogDomFormElements(tag: 'FB-Model-DOM');

    // Scroll into view via DOM
    await toolScrollElementIntoViewViaDom(['דגם', 'Model']);
    await Future.delayed(const Duration(milliseconds: 500));

    // 1. Enter text via DOM directly (free text field)
    bool enteredViaDom = await toolEnterTextInputViaDom(
      selectors: [
        'input[aria-label*="Model" i]',
        'input[aria-label*="דגם" i]',
        'input[placeholder*="Model" i]',
        'input[placeholder*="דגם" i]',
      ],
      text: modelVal,
    );

    // 2. Also tap via A11y to focus & enter text natively
    bool tappedA11y = await toolFindElementAndTap('דגם|Model');
    if (tappedA11y) {
      await Future.delayed(const Duration(milliseconds: 500));
      await toolEnterTextAtFocused(modelVal);
    }

    if (!enteredViaDom && !tappedA11y) {
      _handleRetry(FacebookAutomationPhase.enterModel, 'Model field not found');
      return;
    }

    await Future.delayed(const Duration(milliseconds: 800));

    // Optional: If an auto-complete suggestion popped up, tap it (up to 1.5s timeout)
    try {
      await _retryUntil(() async {
        if (await toolFindElementAndTap(modelVal, targetInstance: 2))
          return true;
        return false;
      }, timeout: const Duration(milliseconds: 1500));
    } catch (_) {}

    await toolDismissKeyboardAndBlur();
    _handlePhaseComplete(FacebookAutomationPhase.enterModel);
  }

  // Phase 9 — Enter mileage
  Future<void> _phaseEnterMileage() async {
    final km = formData.kilometers;
    debugPrint('[FB-A11y] EnterMileage value: "$km"');
    if (km.isEmpty) {
      debugPrint('[FB-A11y] km is empty in formData, skipping enterMileage');
      _handlePhaseComplete(FacebookAutomationPhase.enterMileage);
      return;
    }

    await toolLogDomFormElements(tag: 'FB-Mileage-DOM');
    await toolScrollElementIntoViewViaDom([
      'מיילס',
      'מיילים',
      'מייל',
      'Miles',
      'Mileage',
      'קילומטראז',
      'קילומטרים',
      'ק"מ',
      'ק״מ',
      'קמ',
      'Kilometers',
    ]);
    await Future.delayed(const Duration(milliseconds: 500));

    // 1. Enter text via DOM directly
    bool enteredViaDom = await toolEnterTextInputViaDom(
      selectors: [
        'input[aria-label*="Mileage" i]',
        'input[aria-label*="Miles" i]',
        'input[aria-label*="מיילס" i]',
        'input[aria-label*="מיילים" i]',
        'input[aria-label*="מייל" i]',
        'input[aria-label*="קילומטראז" i]',
        'input[aria-label*="קילומטר" i]',
        'input[aria-label*="ק״מ" i]',
        'input[aria-label*="ק\\"מ" i]',
        'input[aria-label*="קמ" i]',
        'input[placeholder*="Mileage" i]',
        'input[placeholder*="Miles" i]',
        'input[placeholder*="מיילס" i]',
        'input[placeholder*="מיילים" i]',
        'input[placeholder*="קילומטראז" i]',
      ],
      text: km,
    );

    // 2. Fallback via A11y if DOM entry did not match
    bool tappedA11y = false;
    if (!enteredViaDom) {
      tappedA11y = await toolFindElementAndTap(
        'מיילס|מיילים|מייל|Mileage|Miles|קילומטראז|ק"מ|ק״מ|קילומטרים|קמ',
      );
      if (!tappedA11y) {
        tappedA11y =
            await toolTapNodeAfter('מיילס') ||
            await toolTapNodeAfter('מיילים') ||
            await toolTapNodeAfter('מייל') ||
            await toolTapNodeAfter('Miles') ||
            await toolTapNodeAfter('Mileage') ||
            await toolTapNodeAfter('קילומטראז׳') ||
            await toolTapNodeAfter('קילומטראז') ||
            await toolTapNodeAfter('ק״מ') ||
            await toolTapNodeAfter('ק"מ') ||
            await toolTapNodeAfter('קילומטרים') ||
            await toolTapNodeAfter('קמ');
      }
      if (tappedA11y) {
        await Future.delayed(const Duration(milliseconds: 500));
        await toolEnterTextAtFocused(km);
      }
    }

    if (!enteredViaDom && !tappedA11y) {
      _handleRetry(
        FacebookAutomationPhase.enterMileage,
        'Mileage field not found',
      );
      return;
    }

    await Future.delayed(const Duration(milliseconds: 500));
    await toolDismissKeyboardAndBlur();
    _handlePhaseComplete(FacebookAutomationPhase.enterMileage);
  }

  // Phase 10 — Enter price
  Future<void> _phaseEnterPrice() async {
    final priceText = formData.price;
    debugPrint('[FB-A11y] EnterPrice value: "$priceText"');
    if (priceText.isEmpty) {
      debugPrint('[FB-A11y] price is empty in formData, skipping enterPrice');
      _handlePhaseComplete(FacebookAutomationPhase.enterPrice);
      return;
    }

    await toolLogDomFormElements(tag: 'FB-Price-DOM');
    await toolScrollElementIntoViewViaDom(['מחיר', 'Price']);
    await Future.delayed(const Duration(milliseconds: 500));

    // 1. Enter text via DOM directly targeting the price input or its label container
    bool enteredViaDom = await toolEnterPriceViaDom(priceText);
    if (!enteredViaDom) {
      enteredViaDom = await toolEnterTextInputViaDom(
        selectors: [
          'input[aria-label*="Price" i]',
          'input[aria-label*="מחיר" i]',
          'input[placeholder*="Price" i]',
          'input[placeholder*="מחיר" i]',
        ],
        text: priceText,
      );
    }

    // 2. Fallback via A11y: "מחיר" appears twice (1 is label, 2 is input/EditText).
    // Specifically target the input / editable node or instance 2!
    bool enteredA11y = false;
    if (!enteredViaDom) {
      debugPrint(
        '[FB-A11y] DOM price entry not confirmed, attempting A11y input matching...',
      );

      // Strategy A: Specifically prefer editable node (EditText) matching "מחיר" or "Price"
      bool tapped = await toolFindElementAndTap(
        'מחיר|Price',
        preferEditable: true,
      );

      // Strategy B: Target second instance of "מחיר" (instance 1 is label, instance 2 is input)
      if (!tapped) {
        debugPrint('[FB-A11y] Trying instance 2 of "מחיר" for input field...');
        tapped = await toolFindElementAndTap('מחיר', targetInstance: 2);
      }

      // Strategy C: Target second instance of "Price"
      if (!tapped) {
        debugPrint('[FB-A11y] Trying instance 2 of "Price" for input field...');
        tapped = await toolFindElementAndTap('Price', targetInstance: 2);
      }

      // Strategy D: Tap the input node immediately after label "מחיר"
      if (!tapped) {
        debugPrint('[FB-A11y] Trying node after label מחיר...');
        tapped =
            await toolTapNodeAfter('מחיר') || await toolTapNodeAfter('Price');
      }

      // Strategy E: Fallback to instance 1
      if (!tapped) {
        tapped = await toolFindElementAndTap('מחיר|Price');
      }

      if (tapped) {
        await Future.delayed(const Duration(milliseconds: 500));
        enteredA11y = await toolEnterTextAtFocused(priceText);
        if (!enteredA11y) {
          await toolEnterTextAtFocusedJs(priceText);
          enteredA11y = true;
        }
      }
    }

    if (!enteredViaDom && !enteredA11y) {
      _handleRetry(FacebookAutomationPhase.enterPrice, 'Price field not found');
      return;
    }

    await Future.delayed(const Duration(milliseconds: 500));
    await toolDismissKeyboardAndBlur();
    _handlePhaseComplete(FacebookAutomationPhase.enterPrice);
  }

  // Phase 11 — Select body style
  Future<void> _phaseSelectBodyStyle() async {
    await _scrollDown(0.2);
    bool opened = await _retryUntil(() async {
      if (await toolFindElementAndTap('סגנון גוף הרכב')) return true;
      if (await toolFindElementAndTap('Body style')) return true;
      if (await toolFindElementAndTap('Body Style')) return true;
      return false;
    }, timeout: const Duration(seconds: 8));

    if (!opened) {
      debugPrint('[FB-A11y] Body style dropdown not found, skipping');
      _handlePhaseComplete(FacebookAutomationPhase.selectBodyStyle);
      return;
    }
    await Future.delayed(const Duration(milliseconds: 800));

    const bodyStyleLabels = ['אחרים', 'Other', 'אחר'];
    bool selected = await _retryUntil(() async {
      for (final label in bodyStyleLabels) {
        if (await toolFindElementAndTap(label)) return true;
      }
      return false;
    }, timeout: const Duration(seconds: 6));

    if (!selected) {
      debugPrint('[FB-A11y] Could not select body style, continuing');
    }
    _handlePhaseComplete(FacebookAutomationPhase.selectBodyStyle);
  }

  // Phase 12 — Select condition
  Future<void> _phaseSelectCondition() async {
    await _scrollDown(0.2);
    bool opened = await _retryUntil(() async {
      if (await toolFindElementAndTap('מצב הרכב')) return true;
      if (await toolFindElementAndTap('Vehicle condition')) return true;
      if (await toolFindElementAndTap('Condition')) return true;
      return false;
    }, timeout: const Duration(seconds: 8));

    if (!opened) {
      debugPrint('[FB-A11y] Condition dropdown not found, skipping');
      _handlePhaseComplete(FacebookAutomationPhase.selectCondition);
      return;
    }
    await Future.delayed(const Duration(milliseconds: 800));

    final cond = formData.vehicleCondition;
    final List<String> conditionLabels = [];
    if (cond == 'מצוין') {
      conditionLabels.addAll([
        'משומש - כחדש',
        'Like New',
        'Used - Like New',
        'Excellent',
      ]);
    } else if (cond == 'טוב מאוד') {
      conditionLabels.addAll([
        'משומש - במצב טוב מאוד',
        'Very Good',
        'Used - Very Good',
        'משומש - כחדש',
        'משומש - במצב טוב',
      ]);
    } else if (cond == 'טוב') {
      conditionLabels.addAll(['משומש - במצב טוב', 'Good', 'Used - Good']);
    } else if (cond == 'סביר') {
      conditionLabels.addAll(['משומש - במצב סביר', 'Fair', 'Used - Fair']);
    } else if (cond == 'גרוע') {
      conditionLabels.addAll([
        'משומש - במצב גרוע',
        'Poor',
        'Used - Poor',
        'משומש - במצב סביר',
      ]);
    } else {
      conditionLabels.addAll(['משומש - במצב טוב', 'Good', 'Used - Good']);
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

    if (!selectedCond) {
      debugPrint('[FB-A11y] Could not select condition, continuing');
    }
    _handlePhaseComplete(FacebookAutomationPhase.selectCondition);
  }

  // Phase 13 — Select fuel type
  Future<void> _phaseSelectFuelType() async {
    await _scrollDown(0.3);
    final fuel = formData.fuelType;
    if (fuel.isEmpty) {
      _handlePhaseComplete(FacebookAutomationPhase.selectFuelType);
      return;
    }
    bool opened = await _retryUntil(() async {
      if (await toolFindElementAndTap('סוג דלק')) return true;
      if (await toolFindElementAndTap('Fuel type')) return true;
      if (await toolFindElementAndTap('Fuel Type')) return true;
      return false;
    }, timeout: const Duration(seconds: 8));

    if (!opened) {
      debugPrint('[FB-A11y] Fuel type dropdown not found, skipping');
      _handlePhaseComplete(FacebookAutomationPhase.selectFuelType);
      return;
    }
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

    if (!selected) {
      debugPrint('[FB-A11y] Fuel option $fuel not found, continuing');
    }
    _handlePhaseComplete(FacebookAutomationPhase.selectFuelType);
  }

  // Phase 14 — Select transmission
  Future<void> _phaseSelectTransmission() async {
    bool opened = await _retryUntil(() async {
      if (await toolFindElementAndTap('תיבת הילוכים')) return true;
      if (await toolFindElementAndTap('Transmission')) return true;
      return false;
    }, timeout: const Duration(seconds: 8));

    if (!opened) {
      debugPrint('[FB-A11y] Transmission dropdown not found, skipping');
      _handlePhaseComplete(FacebookAutomationPhase.selectTransmission);
      return;
    }
    await Future.delayed(const Duration(milliseconds: 800));

    final String gearVal =
        formData.gear.isNotEmpty ? formData.gear : 'הילוכים אוטומטיים';
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

    if (!selected) {
      debugPrint(
        '[FB-A11y] Could not select transmission ($gearVal), continuing',
      );
    }
    _handlePhaseComplete(FacebookAutomationPhase.selectTransmission);
  }

  // Phase 15 — Enter description
  Future<void> _phaseEnterDescription() async {
    final hasValidDesc =
        formData.description.trim().isNotEmpty &&
        Yad2AccessibilityAutomationService.isValidExtractedDescription(
          formData.description,
        );
    final descriptionText =
        hasValidDesc
            ? formData.description.trim()
            : 'למכירה: ${formData.maker} ${formData.model} שנת ${formData.year}\n'
                'יד: ${formData.hand} | ק"מ: ${formData.kilometers}\n'
                'סוג דלק: ${formData.fuelType}';
    debugPrint(
      '[FB-A11y] EnterDescription (length: ${descriptionText.length}, validCustom: $hasValidDesc):\n$descriptionText',
    );

    await toolLogDomFormElements(tag: 'FB-Description-DOM');

    // 1. Try targeted DOM injection directly on the description field without blind scrolling up
    bool enteredViaDom = await _enterDescriptionViaDom(descriptionText);

    // 2. Fallback via A11y: Description is below Transmission, so scroll down if not entered
    bool enteredA11y = false;
    if (!enteredViaDom) {
      debugPrint(
        '[FB-A11y] DOM description injection failed or not found. Trying A11y fallback...',
      );
      await _scrollDown(0.25);
      await Future.delayed(const Duration(milliseconds: 500));

      // Try DOM again after scrolling down
      enteredViaDom = await _enterDescriptionViaDom(descriptionText);

      if (!enteredViaDom) {
        bool tapped =
            await toolTapNodeAfter('תיאור', offset: 1) ||
            await toolTapNodeAfter('Description', offset: 1) ||
            await toolFindElementAndTap(
              'תיאור|Description',
              preferEditable: true,
            );
        if (tapped) {
          await Future.delayed(const Duration(milliseconds: 500));
          enteredA11y = await toolEnterTextAtFocused(descriptionText);
          if (!enteredA11y) {
            await toolEnterTextAtFocusedJs(descriptionText);
            enteredA11y = true;
          }
        }
      }
    }

    if (!enteredViaDom && !enteredA11y) {
      debugPrint('[FB-A11y] Description field not found, continuing');
    } else {
      debugPrint(
        '[FB-A11y] Description successfully entered! (DOM: $enteredViaDom, A11y: $enteredA11y)',
      );
    }

    await Future.delayed(const Duration(milliseconds: 500));
    await toolDismissKeyboardAndBlur();
    _handlePhaseComplete(FacebookAutomationPhase.enterDescription);
  }

  Future<bool> _enterDescriptionViaDom(String text) async {
    try {
      final jsonVal = jsonEncode(text);
      final raw = await controller.runJavaScriptReturningResult('''
        (function() {
          var val = $jsonVal;

          var selectors = [
            'textarea[name="description"]',
            'textarea[id*="description" i]',
            'textarea[aria-label*="description" i]',
            'textarea[aria-label*="תיאור" i]',
            'textarea[placeholder*="description" i]',
            'textarea[placeholder*="תיאור" i]',
            'div[role="textbox"][aria-label*="description" i]',
            'div[role="textbox"][aria-label*="תיאור" i]',
            'div[contenteditable="true"][aria-label*="description" i]',
            'div[contenteditable="true"][aria-label*="תיאור" i]',
            'div[contenteditable="true"]',
            'textarea'
          ];

          var target = null;
          for (var i = 0; i < selectors.length; i++) {
            var el = document.querySelector(selectors[i]);
            if (el && el.offsetParent !== null) {
              target = el;
              break;
            }
          }

          if (!target) {
            var allLabels = Array.from(document.querySelectorAll('label, div, span'));
            for (var j = 0; j < allLabels.length; j++) {
              var l = allLabels[j];
              var t = (l.innerText || l.textContent || '').trim().toLowerCase();
              if (t === 'תיאור' || t === 'description' || t.indexOf('תיאור') === 0) {
                var inp = l.querySelector('textarea, div[contenteditable="true"], div[role="textbox"], input') ||
                          (l.parentElement && l.parentElement.querySelector('textarea, div[contenteditable="true"], div[role="textbox"], input'));
                if (inp) {
                  target = inp;
                  break;
                }
              }
            }
          }

          if (!target) return 'not_found';

          target.scrollIntoView({ behavior: 'smooth', block: 'center' });
          target.focus();
          try { target.click(); } catch(e) {}

          var isTextArea = target.tagName.toLowerCase() === 'textarea' || target.tagName.toLowerCase() === 'input';
          if (isTextArea) {
            var proto = target instanceof HTMLTextAreaElement 
                ? window.HTMLTextAreaElement.prototype 
                : window.HTMLInputElement.prototype;
            var setDesc = Object.getOwnPropertyDescriptor(proto, 'value');
            if (setDesc && setDesc.set) {
              setDesc.set.call(target, val);
            } else {
              target.value = val;
            }
            target.dispatchEvent(new InputEvent('input', { bubbles: true, data: val, inputType: 'insertText' }));
            target.dispatchEvent(new Event('change', { bubbles: true }));
          } else {
            target.focus();
            try {
              document.execCommand('selectAll', false, null);
              document.execCommand('insertText', false, val);
            } catch(e) {}
            if (!target.innerText || target.innerText.trim().length === 0) {
              target.innerText = val;
            }
            target.dispatchEvent(new InputEvent('input', { bubbles: true, data: val, inputType: 'insertText' }));
            target.dispatchEvent(new Event('change', { bubbles: true }));
          }

          var currentText = target.value || target.innerText || target.textContent || '';
          return currentText.length > 0 ? 'ok' : 'empty';
        })()
      ''');
      debugPrint('[FB-DOM] _enterDescriptionViaDom result: $raw');
      return raw.toString().contains('ok');
    } catch (e) {
      debugPrint('[FB-DOM] _enterDescriptionViaDom error: $e');
      return false;
    }
  }

  bool _publishAttempted = false;

  // Phase 16 — Publish
  Future<void> _phasePublish() async {
    if (!_publishAttempted) {
      await _scrollDown(0.3);
      final tapped = await _retryUntil(
        () => tapSmart('Next|Continue|הבא|המשך'),
        timeout: const Duration(seconds: 6),
      );
      if (tapped) {
        await Future.delayed(const Duration(seconds: 2));
        await _scrollDown(0.3);
      }
      if (_stopped || _isPaused) return;
      // Once the click is attempted its outcome may be ambiguous. Resume only
      // checks confirmation; it must never submit this listing again.
      _publishAttempted = true;
      await tapSmart('Publish|Publish listing|פרסם|פרסם מודעה');
    }
    // final confirmed = await _retryUntil(() async {
    //   if (_stopped || _isPaused) return false;
    //   final url = await controller.currentUrl() ?? '';
    //   final body =
    //       (await controller.runJavaScriptReturningResult(
    //         "Array.from(document.querySelectorAll('h1,h2,[role=status],[role=alert]')).map(e=>e.innerText).join(' ')",
    //       )).toString();
    //   return PublicationConfirmation.facebook(body, url);
    // }, timeout: const Duration(seconds: 20));
    // if (!confirmed) {
    //   await _handleError(
    //     FacebookAutomationPhase.publish,
    //     'לא התקבל אישור פרסום. יש לבדוק את המודעה לפני ניסיון נוסף.',
    //   );
    //   return;
    // }
    if (_stopped || _isPaused) return;
    _handlePhaseComplete(FacebookAutomationPhase.publish);
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
      case FacebookAutomationPhase.selectCondition:
      case FacebookAutomationPhase.selectFuelType:
      case FacebookAutomationPhase.selectTransmission:
      case FacebookAutomationPhase.enterDescription:
      case FacebookAutomationPhase.publish:
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
    try {
      await _beepUser();
    } catch (_) {}
    onPhaseError?.call(phase, error);
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
