import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:audioplayers/audioplayers.dart';
import 'package:webview_flutter/webview_flutter.dart';
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
  });

  void dispose() {
    _stopLoginGate();
    _isPaused = true;
    _currentPhase = null;
    _pausedPhase = null;
  }

  void pauseAutomation() {
    debugPrint('[FB-A11y] ⏸️ Pause requested');
    _stopLoginGate();
    _isPaused = true;
  }

  void resumeAutomation() {
    debugPrint('[FB-A11y] ▶️ Resume requested');
    _stopLoginGate();
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
    debugPrint('[FB-A11y] 🚀 Starting Facebook automation');
    SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersiveSticky);
    WakelockPlus.enable();
    _processPhase(FacebookAutomationPhase.loginGate);
  }

  // ── Phase dispatcher ──────────────────────────────────────────────────────

  void _processPhase(FacebookAutomationPhase phase) {
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
      final bounds = await _channel.invokeMapMethod<String, dynamic>(
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

  // ── Tool: native accessibility tap ───────────────────────────────────────

  Future<void> toolTapScreen(double x, double y) async {
    debugPrint('[FB-A11y] 🖱️ toolTapScreen($x, $y)');
    try {
      await _channel.invokeMethod('tapScreen', {'x': x, 'y': y});
    } catch (e) {
      debugPrint('[FB-A11y] TapScreen error: $e');
    }
  }

  Future<bool> toolFindElementAndTap(
    String targetText, {
    int targetInstance = 1,
    double deltaY = 0,
  }) async {
    debugPrint(
      '[FB-A11y] 🔍 toolFindElementAndTap("$targetText", instance=$targetInstance)',
    );
    try {
      final bounds = await _getStableBounds('findAndGetBounds', {
        'target': targetText,
        'targetInstance': targetInstance,
      });
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
          '[FB-A11y] Found "$targetText" at physical ($physicalX, $physicalY)',
        );
        onTapPreview?.call(logicalX, logicalY);
        await toolTapScreen(physicalX, physicalY);
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
    debugPrint('[FB-A11y] 🔍 toolTapNodeAfter("$targetText")');
    try {
      final bounds = await _getStableBounds('findNodeAfterAndGetBounds', {
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
        onTapPreview?.call(physicalX / pixelRatio, physicalY / pixelRatio);
        await toolTapScreen(physicalX, physicalY);
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
  }) async {
    debugPrint('[FB-A11y] 🔍 toolTapNodeBefore("$targetText")');
    try {
      final bounds = await _getStableBounds('findNodeBeforeAndGetBounds', {
        'target': targetText,
        'targetInstance': targetInstance,
      });
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
        onTapPreview?.call(physicalX / pixelRatio, physicalY / pixelRatio);
        await toolTapScreen(physicalX, physicalY);
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
    debugPrint('[FB-A11y] ⌨️ toolEnterTextAtFocused ("$text")');
    try {
      final escaped = text.replaceAll("'", "\\'");
      final jsResult = await controller.runJavaScriptReturningResult('''
        (function(){
          var el = document.activeElement;
          if(!el) return 'no_active_element';
          el.focus();
          var success = document.execCommand('insertText', false, '$escaped');
          if (!success) {
            var ns = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype,'value')
                  || Object.getOwnPropertyDescriptor(window.HTMLTextAreaElement.prototype,'value');
            if(ns && ns.set){ ns.set.call(el,'$escaped'); }
            else { el.value='$escaped'; }
            el.dispatchEvent(new InputEvent('input',{bubbles:true,data:'$escaped',inputType:'insertText'}));
            el.dispatchEvent(new Event('change',{bubbles:true}));
            return 'fallback_ok';
          }
          return 'exec_ok';
        })()
      ''');
      debugPrint('[FB-A11y] toolEnterTextAtFocused JS result: \$jsResult');
      final resStr = jsResult.toString().trim().replaceAll('"', '');
      if (resStr == 'exec_ok' || resStr == 'fallback_ok') {
        return true;
      }
    } catch (e) {
      debugPrint('[FB-A11y] toolEnterTextAtFocused JS error: $e');
    }

    try {
      final success = await _channel.invokeMethod<bool>('enterTextAtFocused', {
        'value': text,
      });
      return success ?? false;
    } on PlatformException catch (e) {
      debugPrint('[FB-A11y] enterTextAtFocused native error: ${e.message}');
      return false;
    }
  }

  /*
  /// JS fallback: sets value on the active element using React's native setter
  /// so the synthetic event system picks up the change.
  Future<void> toolEnterTextAtFocusedJs(String text) async {
    debugPrint('[FB-A11y] ⌨️ toolEnterTextAtFocusedJs("$text")');
    final escaped = text.replaceAll("'", "\\'");
    await controller.runJavaScript('''
      (function(){
        var el = document.activeElement;
        if(!el || (el.tagName !== 'INPUT' && el.tagName !== 'TEXTAREA')){
          var inputs = document.querySelectorAll(
            'input:not([type="hidden"]):not([type="checkbox"]):not([type="radio"])');
          for(var i=0; i<inputs.length; i++){
            var r=inputs[i].getBoundingClientRect();
            if(r.width>0 && r.height>0){el=inputs[i]; break;}
          }
        }
        if(!el || (el.tagName !== 'INPUT' && el.tagName !== 'TEXTAREA')) return;
        el.focus();
        var ns = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype,'value')
              || Object.getOwnPropertyDescriptor(window.HTMLTextAreaElement.prototype,'value');
        if(ns && ns.set){ ns.set.call(el,'$escaped'); }
        else { el.value='$escaped'; }
        el.dispatchEvent(new InputEvent('input',{bubbles:true,data:'$escaped',inputType:'insertText'}));
        el.dispatchEvent(new Event('change',{bubbles:true}));
      })();
    ''');
  }
  */

  Future<bool> toolEnterText(
    String targetText,
    String value, {
    int targetInstance = 1,
  }) async {
    debugPrint('[FB-A11y] ⌨️ toolEnterText("$targetText", value="$value")');
    try {
      final bounds = await _getStableBounds('findAndGetBounds', {
        'target': targetText,
        'targetInstance': targetInstance,
      });
      if (bounds != null) {
        final physicalX = (bounds['x'] as num).toDouble();
        final physicalY = (bounds['y'] as num).toDouble();
        await toolTapScreen(physicalX, physicalY);
        await Future.delayed(const Duration(milliseconds: 650));
        bool ok = await toolEnterTextAtFocused(value);
        // JS fallback logic marked out
        /*
        if (!ok) {
          await toolEnterTextAtFocusedJs(value);
          ok = true;
        }
        */
        return ok;
      }
      return false;
    } catch (e) {
      debugPrint('[FB-A11y] toolEnterText error: $e');
      return false;
    }
  }

  /*
  // ── Tool: JS shadow-DOM click (Facebook uses React shadow tree heavily) ────

  /// Finds an element by EXACT inner-text match across the full shadow DOM
  /// and fires touch + mouse + React-synthetic click events, matching how
  /// facebook_screen.dart dispatches clicks on [role="option"] elements.
  Future<bool> toolFindAndTapJs(String targetText) async {
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
        var touch=new Touch({identifier:Date.now(),target:target,
          clientX:x,clientY:y,screenX:x,screenY:y,
          pageX:x+window.scrollX,pageY:y+window.scrollY});
        target.dispatchEvent(new TouchEvent('touchstart',
          {bubbles:true,cancelable:true,touches:[touch],targetTouches:[touch],changedTouches:[touch]}));
        target.dispatchEvent(new MouseEvent('mousedown',eOpts));
        target.dispatchEvent(new TouchEvent('touchend',
          {bubbles:true,cancelable:true,changedTouches:[touch]}));
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
    final result = await controller.runJavaScriptReturningResult(js);
    return result == true || result.toString() == 'true';
  }

  // ── Tool: JS click the Nth combobox (as in facebook_screen.dart Phase 3) ──

  /// Clicks `document.querySelectorAll('[role="combobox"]')[index]`
  /// and returns the CSS center coords as "ok:x,y" or "not_found:N".
  Future<String?> toolClickComboboxByIndex(int index) async {
    debugPrint('[FB-A11y] 🕸️ toolClickComboboxByIndex($index)');
    final js = '''
      (function(){
        var combos=document.querySelectorAll('[role="combobox"]');
        if(combos.length<=${index}) return 'not_found:'+combos.length;
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
        if(opts.length<=${index}) return 'not_found';
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
  */

  // ── Tool: scroll helpers ──────────────────────────────────────────────────

  Future<void> _scrollDown(double percent) async {
    debugPrint('[FB-A11y] ⬇️ scrollDown($percent)');
    try {
      await _channel.invokeMethod('scrollNode', {
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
      final bounds = await _channel.invokeMapMethod<String, dynamic>(
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

  Future<bool> tapSmart(
    String targetText, {
    int targetInstance = 1,
    double deltaY = 0,
  }) async {
    if (await toolFindElementAndTap(
      targetText,
      targetInstance: targetInstance,
      deltaY: deltaY,
    )) {
      return true;
    }
    // JS fallback marked out as requested
    /*
    for (final alt in targetText.split('|')) {
      final candidate = alt.trim();
      if (candidate.isEmpty) continue;
      if (await toolFindAndTapJs(candidate)) {
        debugPrint('[FB-A11y] 🕸️ JS fallback clicked "$candidate"');
        return true;
      }
    }
    */
    return false;
  }

  // ── Tool: press back ─────────────────────────────────────────────────────

  Future<bool> toolPressBack() async {
    try {
      final pressed = await _channel.invokeMethod<bool>('pressBack');
      return pressed ?? false;
    } on PlatformException catch (e) {
      debugPrint('[FB-A11y] pressBack error: ${e.message}');
      return false;
    }
  }

  Future<void> toolBlurActiveElement() async {
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
    await toolBlurActiveElement();
    await Future.delayed(const Duration(milliseconds: 350));
    if (isKeyboardVisible()) {
      debugPrint('[FB-A11y] Keyboard is still visible, sending back press');
      await toolPressBack();
      await Future.delayed(const Duration(milliseconds: 500));
    } else {
      debugPrint('[FB-A11y] Keyboard is already closed, skipping back press');
    }
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
    debugPrint('[FB-A11y] 🔐 Login gate active — waiting for user login');
    _isPaused = true;
    _pausedPhase = FacebookAutomationPhase.setViewport; // resume from viewport
    unawaited(_beepUser());

    _loginSamplingTimer = Timer.periodic(const Duration(seconds: 1), (
      timer,
    ) async {
      if (_loginGateTickBusy) return;
      _loginGateTickBusy = true;
      try {
        if (!await _isLoggedInAndOnForm()) return;
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

  // Phase 5 — Upload photos
  Future<void> _phaseUploadPhotos() async {
    debugPrint('[FB-A11y] phaseUploadPhoto: ${formData.images == null}');
    if (formData.images == null || formData.images!.isEmpty) {
      debugPrint('[FB-A11y] No images uploaded. Skipping upload photos phase.');
      _handlePhaseComplete(FacebookAutomationPhase.uploadPhotos);
      return;
    }

    debugPrint(
      '[FB-A11y] Converting ${formData.images!.length} images to base64...',
    );
    final List<Map<String, String>> base64Files = [];
    for (int i = 0; i < formData.images!.length; i++) {
      final path = formData.images![i];
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
    _handlePhaseComplete(FacebookAutomationPhase.uploadPhotos);
  }

  // Phase 6 — Enter year
  Future<void> _phaseEnterYear() async {
    await _scrollDown(0.5);
    final yearVal = formData.year;
    debugPrint('EnterYear value: $yearVal');
    if (yearVal.isEmpty) {
      _handlePhaseComplete(FacebookAutomationPhase.enterYear);
      return;
    }

    await toolLogAccessibilityTree();
    bool opened = await _retryUntil(() async {
      if (await toolFindElementAndTap('שנה')) return true;
      if (await toolFindElementAndTap('Year')) return true;
      return false;
    }, timeout: const Duration(seconds: 4));

    if (!opened) {
      _handleRetry(
        FacebookAutomationPhase.enterYear,
        'Year dropdown not found',
      );
      return;
    }
    await Future.delayed(const Duration(milliseconds: 800));

    bool selected = await _retryUntil(() async {
      return await toolFindElementAndTap(yearVal);
    }, timeout: const Duration(seconds: 6));

    if (!selected) {
      _handleRetry(
        FacebookAutomationPhase.enterYear,
        'Year value $yearVal not found',
      );
      return;
    }
    _handlePhaseComplete(FacebookAutomationPhase.enterYear);
  }

  // Phase 7 — Enter make
  Future<void> _phaseEnterMake() async {
    final makerVal = formData.maker;
    if (makerVal.isEmpty) {
      _handlePhaseComplete(FacebookAutomationPhase.enterMake);
      return;
    }
    bool tapped = await _retryUntil(() async {
      if (await toolFindElementAndTap('יצרן')) return true;
      if (await toolFindElementAndTap('Make')) return true;
      return false;
    }, timeout: const Duration(seconds: 8));

    if (!tapped) {
      _handleRetry(FacebookAutomationPhase.enterMake, 'Make field not found');
      return;
    }
    await Future.delayed(const Duration(milliseconds: 800));

    debugPrint('[FB-A11y] Entering make: $makerVal');
    await toolEnterTextAtFocused(makerVal);
    await Future.delayed(const Duration(milliseconds: 800));

    // Tap make suggestion (prefer second instance if suggestion is list element)
    debugPrint('[FB-A11y] Tapping make suggestion: $makerVal');
    bool selected = await _retryUntil(() async {
      if (await toolFindElementAndTap(makerVal, targetInstance: 2)) return true;
      return await toolFindElementAndTap(makerVal, targetInstance: 1);
    }, timeout: const Duration(seconds: 6));

    if (!selected) {
      debugPrint(
        '[FB-A11y] Maker suggestion for $makerVal not found, continuing',
      );
    }

    // Dismiss keyboard and blur focus
    await toolDismissKeyboardAndBlur();

    _handlePhaseComplete(FacebookAutomationPhase.enterMake);
  }

  // Phase 8 — Enter model
  Future<void> _phaseEnterModel() async {
    await _scrollDown(0.2);
    final modelVal = formData.model;
    if (modelVal.isEmpty) {
      _handlePhaseComplete(FacebookAutomationPhase.enterModel);
      return;
    }
    bool tapped = await _retryUntil(() async {
      if (await toolFindElementAndTap('דגם')) return true;
      if (await toolFindElementAndTap('Model')) return true;
      return false;
    }, timeout: const Duration(seconds: 8));

    if (!tapped) {
      _handleRetry(FacebookAutomationPhase.enterModel, 'Model field not found');
      return;
    }
    await Future.delayed(const Duration(milliseconds: 800));

    debugPrint('[FB-A11y] Entering model: $modelVal');
    await toolEnterTextAtFocused(modelVal);
    await Future.delayed(const Duration(milliseconds: 800));

    // Tap model suggestion (prefer second instance if suggestion is list element)
    debugPrint('[FB-A11y] Tapping model suggestion: $modelVal');
    bool selected = await _retryUntil(() async {
      if (await toolFindElementAndTap(modelVal, targetInstance: 2)) return true;
      return await toolFindElementAndTap(modelVal, targetInstance: 1);
    }, timeout: const Duration(seconds: 6));

    if (!selected) {
      debugPrint(
        '[FB-A11y] Model suggestion for $modelVal not found, continuing',
      );
    }

    // Dismiss keyboard and blur focus
    await toolDismissKeyboardAndBlur();

    _handlePhaseComplete(FacebookAutomationPhase.enterModel);
  }

  // Phase 9 — Enter mileage
  Future<void> _phaseEnterMileage() async {
    final km = formData.kilometers;
    if (km.isEmpty) {
      _handlePhaseComplete(FacebookAutomationPhase.enterMileage);
      return;
    }
    bool tapped = await _retryUntil(() async {
      if (await toolTapNodeAfter('מיילים')) return true;
      if (await toolTapNodeAfter('Miles')) return true;
      if (await toolTapNodeAfter('Mileage')) return true;
      return false;
    }, timeout: const Duration(seconds: 8));

    if (!tapped) {
      _handleRetry(
        FacebookAutomationPhase.enterMileage,
        'Mileage field not found',
      );
      return;
    }
    await Future.delayed(const Duration(milliseconds: 800));
    await toolEnterTextAtFocused(km);
    await Future.delayed(const Duration(milliseconds: 500));
    await toolDismissKeyboardAndBlur();
    _handlePhaseComplete(FacebookAutomationPhase.enterMileage);
  }

  // Phase 10 — Enter price
  Future<void> _phaseEnterPrice() async {
    final priceText = formData.price;
    if (priceText.isEmpty) {
      _handlePhaseComplete(FacebookAutomationPhase.enterPrice);
      return;
    }
    bool tapped = await _retryUntil(() async {
      if (await toolFindElementAndTap('מחיר', targetInstance: 2)) return true;
      if (await toolFindElementAndTap('Price', targetInstance: 2)) return true;
      return false;
    }, timeout: const Duration(seconds: 8));

    if (!tapped) {
      _handleRetry(FacebookAutomationPhase.enterPrice, 'Price field not found');
      return;
    }
    await Future.delayed(const Duration(milliseconds: 800));
    await toolEnterTextAtFocused(priceText);
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
    final descriptionText =
        'למכירה: ${formData.maker} ${formData.model} שנת ${formData.year}\n'
        'יד: ${formData.hand} | ק"מ: ${formData.kilometers}\n'
        'סוג דלק: ${formData.fuelType}';

    bool tapped = await _retryUntil(() async {
      if (await toolTapNodeAfter('תיאור')) return true;
      if (await toolTapNodeAfter('Description')) return true;
      return false;
    }, timeout: const Duration(seconds: 8));

    if (!tapped) {
      debugPrint('[FB-A11y] Description field not found, skipping');
      _handlePhaseComplete(FacebookAutomationPhase.enterDescription);
      return;
    }
    await Future.delayed(const Duration(milliseconds: 800));
    await toolEnterTextAtFocused(descriptionText);
    await Future.delayed(const Duration(milliseconds: 500));
    await toolDismissKeyboardAndBlur();
    _handlePhaseComplete(FacebookAutomationPhase.enterDescription);
  }

  // Phase 16 — Publish
  Future<void> _phasePublish() async {
    await _scrollDown(0.3);

    // Click Next first if multi-page
    bool tapped = await _retryUntil(
      () => tapSmart('Next|Continue|הבא|המשך'),
      timeout: const Duration(seconds: 6),
    );

    if (tapped) {
      await Future.delayed(const Duration(seconds: 2));
      await _scrollDown(0.3);
    }

    final published = await _retryUntil(
      () => tapSmart('Publish|Publish listing|פרסם|פרסם מודעה'),
      timeout: const Duration(seconds: 8),
    );

    if (!published) {
      _handleRetry(FacebookAutomationPhase.publish, 'Publish button not found');
      return;
    }
    _handlePhaseComplete(FacebookAutomationPhase.publish);
  }

  // ── Phase chain controller ────────────────────────────────────────────────

  void _handlePhaseComplete(FacebookAutomationPhase phase) {
    debugPrint('[FB-A11y] ✅ Phase complete: ${phase.descriptionHe}');
    onPhaseComplete?.call(phase);

    FacebookAutomationPhase? next;
    int delayMs = 1000;

    switch (phase) {
      case FacebookAutomationPhase.loginGate:
        next = FacebookAutomationPhase.setViewport;
        delayMs = 500;
      case FacebookAutomationPhase.setViewport:
        next = FacebookAutomationPhase.selectVehicleType;
        delayMs = 1000; // wait for page/form to load
      case FacebookAutomationPhase.selectVehicleType:
        next = FacebookAutomationPhase.uploadPhotos;
        delayMs = 1000;
      case FacebookAutomationPhase.uploadPhotos:
        next = FacebookAutomationPhase.enterYear;
        delayMs = 1000;
      case FacebookAutomationPhase.enterYear:
        next = FacebookAutomationPhase.enterMake;
        delayMs = 1000;
      case FacebookAutomationPhase.enterMake:
        next = FacebookAutomationPhase.enterModel;
        delayMs = 1000;
      case FacebookAutomationPhase.enterModel:
        next = FacebookAutomationPhase.enterMileage;
        delayMs = 1000;
      case FacebookAutomationPhase.enterMileage:
        next = FacebookAutomationPhase.enterPrice;
        delayMs = 1000;
      case FacebookAutomationPhase.enterPrice:
        next = FacebookAutomationPhase.selectBodyStyle;
        delayMs = 1000;
      case FacebookAutomationPhase.selectBodyStyle:
        next = FacebookAutomationPhase.selectCondition;
        delayMs = 1000;
      case FacebookAutomationPhase.selectCondition:
        next = FacebookAutomationPhase.selectFuelType;
        delayMs = 1000;
      case FacebookAutomationPhase.selectFuelType:
        next = FacebookAutomationPhase.selectTransmission;
        delayMs = 1000;
      case FacebookAutomationPhase.selectTransmission:
        next = FacebookAutomationPhase.enterDescription;
        delayMs = 1000;
      case FacebookAutomationPhase.enterDescription:
        next = FacebookAutomationPhase.publish;
        delayMs = 1000;
      case FacebookAutomationPhase.publish:
        next = FacebookAutomationPhase.complete;
        delayMs = 700;
      case FacebookAutomationPhase.complete:
        WakelockPlus.disable();
        onAutomationComplete?.call(true);
        return;
    }

    Future.delayed(Duration(milliseconds: delayMs), () {
      _processPhase(next!);
    });
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
      Future.delayed(Duration(milliseconds: backoffMs), () {
        _executePhase(phase);
      });
    } else {
      _handleError(phase, reason);
    }
  }

  Future<void> _handleError(FacebookAutomationPhase phase, String error) async {
    debugPrint('[FB-A11y] ❌ Error at ${phase.descriptionHe}: $error');
    _isPaused = true;
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
