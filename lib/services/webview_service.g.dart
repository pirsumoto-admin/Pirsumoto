// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'webview_service.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning

@ProviderFor(webviewService)
final webviewServiceProvider = WebviewServiceProvider._();

final class WebviewServiceProvider
    extends $FunctionalProvider<WebviewService, WebviewService, WebviewService>
    with $Provider<WebviewService> {
  WebviewServiceProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'webviewServiceProvider',
        isAutoDispose: true,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$webviewServiceHash();

  @$internal
  @override
  $ProviderElement<WebviewService> $createElement($ProviderPointer pointer) =>
      $ProviderElement(pointer);

  @override
  WebviewService create(Ref ref) {
    return webviewService(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(WebviewService value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<WebviewService>(value),
    );
  }
}

String _$webviewServiceHash() => r'2f27d3f24f6f3c4e341e425203983d34c1780527';
