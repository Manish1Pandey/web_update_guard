import 'update_guard_platform.dart';

/// Returns the platform implementation for non-web targets.
UpdateGuardPlatform createDefaultPlatform() => const UnsupportedPlatform();

/// The inert implementation used on Android, iOS, desktop and the Dart VM.
///
/// [isSupported] is `false`, so `WebUpdateGuard` never calls the other
/// members; they still behave safely if called directly.
class UnsupportedPlatform implements UpdateGuardPlatform {
  /// Creates the inert platform.
  const UnsupportedPlatform();

  @override
  bool get isSupported => false;

  @override
  String? readRunningBuildId() => null;

  @override
  Future<String> fetchNoStore(String url, {required Duration timeout}) =>
      Future<String>.error(
        UnsupportedError('web_update_guard only fetches on the web'),
      );

  @override
  bool get isHidden => false;

  @override
  Stream<bool> get onVisibilityChange => const Stream<bool>.empty();

  @override
  Stream<void> get onFocus => const Stream<void>.empty();

  @override
  Stream<void> get onUserActivity => const Stream<void>.empty();

  @override
  Future<int> unregisterServiceWorkers() async => 0;

  @override
  Future<int> clearCaches({bool Function(String cacheName)? filter}) async => 0;

  @override
  Future<void> refreshDocument() async {}

  @override
  void reload() {}

  @override
  String? readReloadMarker() => null;

  @override
  void writeReloadMarker(String? buildId) {}
}
