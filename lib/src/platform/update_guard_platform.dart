/// The browser operations [WebUpdateGuard] needs, behind an interface so the
/// guard's logic can be unit-tested on the VM with a fake implementation.
///
/// The default implementation is chosen by conditional import: a real
/// `package:web` implementation on the web, and an inert one elsewhere whose
/// [isSupported] is `false`.
abstract class UpdateGuardPlatform {
  /// Whether this platform can detect and apply web updates.
  bool get isSupported;

  /// Reads the build ID of the running page from the
  /// `web-update-guard-build-id` meta tag, or `null` when absent.
  String? readRunningBuildId();

  /// Fetches [url] (resolved against the document base URI) bypassing every
  /// cache (`cache: 'no-store'`) and returns the body text.
  ///
  /// Throws a `TimeoutException` after [timeout] and an [UpdateFetchException]
  /// for non-2xx responses.
  Future<String> fetchNoStore(String url, {required Duration timeout});

  /// Whether the page is currently hidden (background tab, minimised).
  bool get isHidden;

  /// Emits `true` when the page becomes visible and `false` when it becomes
  /// hidden.
  Stream<bool> get onVisibilityChange;

  /// Emits when the window gains focus.
  Stream<void> get onFocus;

  /// Emits on user input (pointer, key, wheel, touch). Used to detect idleness.
  Stream<void> get onUserActivity;

  /// Unregisters every service worker registration of the origin and returns
  /// how many were removed.
  Future<int> unregisterServiceWorkers();

  /// Deletes CacheStorage caches of the origin whose name passes [filter]
  /// (all when `null`) and returns how many were deleted.
  Future<int> clearCaches({bool Function(String cacheName)? filter});

  /// Re-fetches the current document with `cache: 'reload'` so the HTTP cache
  /// holds the newest `index.html` before reloading.
  Future<void> refreshDocument();

  /// Reloads the page.
  void reload();

  /// Reads the build ID the last automatic reload targeted (per tab, survives
  /// the reload), or `null`.
  ///
  /// Used to stop reload loops when the server's `version.json` and
  /// `index.html` disagree (e.g. a CDN still serving an old `index.html`).
  String? readReloadMarker();

  /// Stores (or clears, with `null`) the reload marker.
  void writeReloadMarker(String? buildId);
}

/// Thrown when a fetch returns a non-2xx HTTP status.
class UpdateFetchException implements Exception {
  /// Creates the exception.
  const UpdateFetchException(this.url, this.statusCode);

  /// The requested URL.
  final String url;

  /// The HTTP status code.
  final int statusCode;

  @override
  String toString() => 'UpdateFetchException: HTTP $statusCode for $url';
}
