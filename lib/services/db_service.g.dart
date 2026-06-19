// GENERATED CODE - DO NOT MODIFY BY HAND

part of 'db_service.dart';

// **************************************************************************
// RiverpodGenerator
// **************************************************************************

// GENERATED CODE - DO NOT MODIFY BY HAND
// ignore_for_file: type=lint, type=warning

@ProviderFor(dbService)
final dbServiceProvider = DbServiceProvider._();

final class DbServiceProvider
    extends $FunctionalProvider<DBService, DBService, DBService>
    with $Provider<DBService> {
  DbServiceProvider._()
    : super(
        from: null,
        argument: null,
        retry: null,
        name: r'dbServiceProvider',
        isAutoDispose: true,
        dependencies: null,
        $allTransitiveDependencies: null,
      );

  @override
  String debugGetCreateSourceHash() => _$dbServiceHash();

  @$internal
  @override
  $ProviderElement<DBService> $createElement($ProviderPointer pointer) =>
      $ProviderElement(pointer);

  @override
  DBService create(Ref ref) {
    return dbService(ref);
  }

  /// {@macro riverpod.override_with_value}
  Override overrideWithValue(DBService value) {
    return $ProviderOverride(
      origin: this,
      providerOverride: $SyncValueProvider<DBService>(value),
    );
  }
}

String _$dbServiceHash() => r'855c0963b9cc0812966987d61238fe2572e56957';
