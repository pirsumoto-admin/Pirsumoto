import 'dart:io';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:easy_localization/easy_localization.dart' hide TextDirection;
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:image_picker/image_picker.dart';
import '../../services/automation_webview_session.dart';

enum PresetPlatform { yad2, facebook }

class PresetLoginScreen extends StatefulWidget {
  final PresetPlatform platform;

  const PresetLoginScreen({super.key, required this.platform});

  @override
  State<PresetLoginScreen> createState() => _PresetLoginScreenState();
}

class _PresetLoginScreenState extends State<PresetLoginScreen> {
  late final WebViewController _controller;
  AutomationWebViewSession? _browserSession;
  bool _webViewVisible = false;
  bool _webViewClosed = false;
  double _loadingProgress = 0.0;
  bool _isLoading = true;
  String _currentUrl = '';

  static const _kDesktopUserAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/128.0.0.0 Safari/537.36';

  // URLs for Yad2
  static const _kYad2LoginUrl = 'https://pluscars.yad2.co.il/';
  static const _kYad2PublishUrl =
      'https://plus.yad2.co.il/publish-ad?cat=vehicles&subCat=cars&isTrader=true&skipCache=true';

  // URLs for Facebook
  static const _kFacebookLoginUrl = 'https://www.facebook.com/';
  static const _kFacebookVehicleUrl =
      'https://www.facebook.com/marketplace/create/vehicle';

  String get _initialUrl {
    switch (widget.platform) {
      case PresetPlatform.yad2:
        return _kYad2LoginUrl;
      case PresetPlatform.facebook:
        return _kFacebookLoginUrl;
    }
  }

  Color get _themeColor {
    switch (widget.platform) {
      case PresetPlatform.yad2:
        return const Color(0xFFFF7A00); // Yad2 Orange
      case PresetPlatform.facebook:
        return const Color(0xFF1877F2); // Facebook Blue
    }
  }

  String _trText(
    BuildContext context,
    String key, {
    required String he,
    required String en,
  }) {
    final isEn = context.locale.languageCode == 'en';
    final fallback = isEn ? en : he;
    final val = tr(key);
    if (val == key || val.isEmpty) return fallback;
    return val;
  }

  String _getTitle(BuildContext context) {
    switch (widget.platform) {
      case PresetPlatform.yad2:
        return _trText(
          context,
          'preset_login.yad2_screen_title',
          he: 'יד 2 - אימות התחברות',
          en: 'Yad2 - Login Validation',
        );
      case PresetPlatform.facebook:
        return _trText(
          context,
          'preset_login.facebook_screen_title',
          he: 'פייסבוק - אימות התחברות',
          en: 'Facebook - Login Validation',
        );
    }
  }

  @override
  void initState() {
    super.initState();
    WakelockPlus.enable();
    unawaited(_initializeBrowser());
  }

  Future<void> _initializeBrowser() async {
    try {
      _browserSession = await AutomationWebViewSession.open(
        auxiliary: true,
        isCurrent: () => mounted && !_webViewClosed,
        stop: () async {
          _webViewClosed = true;
        },
        detach: () async {
          if (mounted) setState(() => _webViewVisible = false);
          await WidgetsBinding.instance.endOfFrame;
        },
        configure: _configureBrowser,
      );
      if (mounted && _browserSession != null && !_webViewClosed) {
        setState(() => _webViewVisible = true);
      }
    } catch (error) {
      debugPrint('[PresetLogin] Browser startup failed: $error');
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _configureBrowser(WebViewController controller) async {
    if (widget.platform == PresetPlatform.facebook) {
      await controller.setUserAgent(_kDesktopUserAgent);
    }

    await controller.setNavigationDelegate(
      NavigationDelegate(
        onProgress: (int progress) {
          if (mounted && !_webViewClosed) {
            setState(() {
              _loadingProgress = progress / 100.0;
              _isLoading = progress < 100;
            });
          }
        },
        onPageStarted: (String url) {
          if (mounted && !_webViewClosed) {
            setState(() {
              _currentUrl = url;
              _isLoading = true;
            });
          }
        },
        onPageFinished: (String url) {
          if (mounted && !_webViewClosed) {
            setState(() {
              _currentUrl = url;
              _isLoading = false;
            });
          }
        },
        onWebResourceError: (WebResourceError error) {
          debugPrint('[PresetLogin] WebResourceError: ${error.description}');
        },
      ),
    );

    // Setup file chooser on Android WebView to handle image/file pickers gracefully
    if (Platform.isAndroid && controller.platform is AndroidWebViewController) {
      final androidController = controller.platform as AndroidWebViewController;
      AndroidWebViewController.enableDebugging(true);
      await androidController.setMediaPlaybackRequiresUserGesture(false);
      await androidController.setOnShowFileSelector((
        FileSelectorParams params,
      ) async {
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

    _controller = controller;
    await _controller.loadRequest(Uri.parse(_initialUrl));
  }

  @override
  void dispose() {
    _webViewClosed = true;
    _browserSession?.closeInBackground();
    WakelockPlus.disable();
    super.dispose();
  }

  void _loadUrl(String url) {
    if (!_webViewVisible || _webViewClosed) return;
    _controller.loadRequest(Uri.parse(url));
  }

  @override
  Widget build(BuildContext context) {
    final isYad2 = widget.platform == PresetPlatform.yad2;

    final title = _getTitle(context);
    final closeText = _trText(
      context,
      'preset_login.done',
      he: 'סגור',
      en: 'Close',
    );
    final backTooltip = _trText(
      context,
      'preset_login.back_to_dialog',
      he: 'סגור וחזור',
      en: 'Close & Return',
    );
    final reloadTooltip = _trText(
      context,
      'preset_login.reload',
      he: 'רענן',
      en: 'Reload',
    );
    final loginNotice = _trText(
      context,
      'preset_login.login_notice',
      he: 'אם אינך מחובר, התחבר כעת כדי שהעוגיות יישמרו לאוטומציה.',
      en:
          'Please log in if prompted so session cookies are saved for automation.',
    );

    return Scaffold(
      appBar: AppBar(
        backgroundColor: _themeColor,
        foregroundColor: Colors.white,
        elevation: 2,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back),
          tooltip: backTooltip,
          onPressed: () => Navigator.of(context).pop(),
        ),
        title: Text(
          title,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
          overflow: TextOverflow.ellipsis,
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: reloadTooltip,
            onPressed:
                _webViewVisible && !_webViewClosed
                    ? () => _controller.reload()
                    : null,
          ),
          IconButton(
            icon: const Icon(Icons.close),
            tooltip: closeText,
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
      body: Column(
        children: [
          if (_isLoading)
            LinearProgressIndicator(
              value: _loadingProgress > 0 ? _loadingProgress : null,
              backgroundColor: _themeColor.withValues(alpha: 0.2),
              valueColor: AlwaysStoppedAnimation<Color>(_themeColor),
              minHeight: 3,
            ),
          // Informative helper bar
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            color: Colors.grey.shade100,
            child: Row(
              children: [
                Icon(Icons.info_outline, size: 18, color: _themeColor),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    loginNotice,
                    style: TextStyle(fontSize: 12, color: Colors.grey.shade800),
                  ),
                ),
                const SizedBox(width: 6),
                // Quick shortcut button to verify destination page
                TextButton.icon(
                  style: TextButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                  ),
                  icon: const Icon(Icons.open_in_browser, size: 16),
                  label: Text(
                    isYad2 ? 'דף פרסום' : 'Marketplace',
                    style: const TextStyle(fontSize: 11),
                  ),
                  onPressed: () {
                    if (isYad2) {
                      _loadUrl(_kYad2PublishUrl);
                    } else {
                      _loadUrl(_kFacebookVehicleUrl);
                    }
                  },
                ),
              ],
            ),
          ),
          // WebView
          Expanded(
            child:
                _webViewVisible
                    ? WebViewWidget(controller: _controller)
                    : const SizedBox.shrink(),
          ),
        ],
      ),
      // Persistent bottom button to make exiting crystal clear
      bottomNavigationBar: SafeArea(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            color: Colors.white,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.08),
                blurRadius: 6,
                offset: const Offset(0, -2),
              ),
            ],
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  _currentUrl.isEmpty ? _initialUrl : _currentUrl,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11, color: Colors.grey.shade600),
                ),
              ),
              const SizedBox(width: 12),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: _themeColor,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 10,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(20),
                  ),
                ),
                onPressed: () => Navigator.of(context).pop(),
                icon: const Icon(Icons.done, size: 18),
                label: Text(
                  backTooltip,
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
