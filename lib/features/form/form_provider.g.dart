// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'form_provider.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning

@ProviderFor(FormController)
final formControllerProvider = FormControllerProvider._();

final class FormControllerProvider
    extends $NotifierProvider<FormController, FormState> {
  FormControllerProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'formControllerProvider',
        isAutoDispose: true,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$formControllerHash();

  @$internal
  @override
  FormController create() => FormController();

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(FormState value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<FormState>(value),
    );
  }
}

String _$formControllerHash() => r'defce4915b2aaa68304da4d9384e0fc57e472935';

abstract class _$FormController extends $Notifier<FormState> {
  FormState build();
  @$mustCallSuper
  @override
  void runBuild() {
    final ref = this.ref as $Ref<FormState, FormState>;
    final element =
        ref.element
            as $ClassProviderElement<
              AnyNotifier<FormState, FormState>,
              FormState,
              Object?,
              Object?
            >;
    element.handleCreate(ref, build);
  }
}
