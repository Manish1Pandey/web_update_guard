import 'dart:async';
import 'dart:convert';

import 'build_info.dart';
import 'platform/platform_stub.dart'
    if (dart.library.js_interop) 'platform/platform_web.dart';
import 'platform/update_guard_platform.dart';
import 'update_status.dart';

/// When [WebUpdateGuard] reloads onto a new build by itself.
enum AutoReloadPolicy {
  /// Never reload automatically; the app decides (e.g. via [UpdateBanner]).
  never,

  /// Reload as soon as the tab is hidden, or once the user has made no input
  /// for [WebUpdateGuard.idleTimeout] — so nobody loses what they are typing.
  whenIdle,

  /// Reload as soon as a new build is detected.
  immediately,
}

/// What [WebUpdateGuard.applyUpdate] purges before reloading.
class ApplyUpdateOptions {
  /// Creates purge options. Everything is enabled by default.
  const ApplyUpdateOptions({
    this.unregisterServiceWorkers = true,
    this.clearCacheStorage = true,
    this.cacheNameFilter,
    this.refreshDocument = true,
  });

  /// Unregister every service worker of the origin (including Flutter's
  /// legacy `flutter_service_worker.js`).
  final bool unregisterServiceWorkers;

  /// Delete CacheStorage caches of the origin.
  final bool clearCacheStorage;

  /// When set, only caches whose name passes this predicate are deleted —
  /// use it to keep caches your app manages itself.
  final bool Function(String cacheName)? cacheNameFilter;

  /// Re-fetch the current document with `cache: 'reload'` before reloading so
  /// a stale `index.html` in the HTTP cache is replaced.
  final bool refreshDocument;
}

/// Detects that a newer Flutter web build has been deployed and moves the tab
/// onto it.
///
/// ```dart
/// final guard = WebUpdateGuard(pollInterval: const Duration(minutes: 5))
///   ..start();
/// guard.statusStream.listen((s) {
///   if (s.isUpdateAvailable) guard.applyUpdate();
/// });
/// ```
///
/// The build must have been stamped with
/// `dart run web_update_guard stamp build/web`. On non-web platforms the guard
/// is inert and reports [UpdateState.unsupported].
class WebUpdateGuard implements UpdateChecker {
  /// Creates a guard. Call [start] to begin checking.
  ///
  /// [platform] and [clock] exist for tests; leave them `null` in apps.
  WebUpdateGuard({
    this.pollInterval = const Duration(minutes: 5),
    this.checkOnStart = true,
    this.checkOnVisibilityChange = true,
    this.checkOnFocus = true,
    this.pauseWhenHidden = true,
    this.minCheckGap = const Duration(seconds: 15),
    this.versionUrl = 'version.json',
    this.fetchTimeout = const Duration(seconds: 15),
    this.comparison = ComparisonPolicy.anyDifference,
    this.autoReload = AutoReloadPolicy.never,
    this.idleTimeout = const Duration(minutes: 2),
    this.applyOptions = const ApplyUpdateOptions(),
    UpdateGuardPlatform? platform,
    DateTime Function()? clock,
  }) : assert(pollInterval > Duration.zero, 'pollInterval must be positive'),
       assert(idleTimeout > Duration.zero, 'idleTimeout must be positive'),
       _platform = platform ?? createDefaultPlatform(),
       _clock = clock ?? DateTime.now {
    final String? running = _platform.isSupported
        ? _platform.readRunningBuildId()
        : null;
    _status = UpdateStatus(
      state: !_platform.isSupported
          ? UpdateState.unsupported
          : running == null
          ? UpdateState.notStamped
          : UpdateState.idle,
      runningBuildId: running,
    );
  }

  /// How often to poll `version.json` while the guard runs.
  final Duration pollInterval;

  /// Whether [start] performs an immediate check.
  final bool checkOnStart;

  /// Check when the tab becomes visible again.
  final bool checkOnVisibilityChange;

  /// Check when the window regains focus.
  final bool checkOnFocus;

  /// Skip timer-driven polls while the tab is hidden (a check still runs when
  /// it becomes visible if [checkOnVisibilityChange] is on).
  final bool pauseWhenHidden;

  /// Minimum time between two event-driven (focus / visibility) checks.
  /// [checkNow] and the poll timer ignore it.
  final Duration minCheckGap;

  /// URL of the version file, resolved against the document base URI, so it
  /// honours `--base-href`.
  final String versionUrl;

  /// Timeout for one `version.json` request.
  final Duration fetchTimeout;

  /// How the remote build is compared with the running one.
  final ComparisonPolicy comparison;

  /// Whether and when to reload automatically once an update is found.
  final AutoReloadPolicy autoReload;

  /// Inactivity after which [AutoReloadPolicy.whenIdle] reloads.
  final Duration idleTimeout;

  /// What [applyUpdate] purges before reloading.
  final ApplyUpdateOptions applyOptions;

  final UpdateGuardPlatform _platform;
  final DateTime Function() _clock;
  final StreamController<UpdateStatus> _controller =
      StreamController<UpdateStatus>.broadcast();
  final List<StreamSubscription<Object?>> _subscriptions =
      <StreamSubscription<Object?>>[];

  late UpdateStatus _status;
  Timer? _pollTimer;
  Timer? _idleTimer;
  StreamSubscription<void>? _activitySub;
  Future<UpdateStatus>? _inFlight;
  DateTime? _lastEventCheck;
  DateTime _lastActivity = DateTime.utc(1970);
  bool _running = false;
  bool _disposed = false;
  bool _applying = false;

  /// Whether this platform supports update detection (web only).
  bool get isSupported => _platform.isSupported;

  /// The build ID of the running page, or `null` when unsupported/unstamped.
  String? get runningBuildId => _status.runningBuildId;

  /// Whether [start] has been called and [stop] has not.
  bool get isRunning => _running;

  @override
  UpdateStatus get status => _status;

  @override
  Stream<UpdateStatus> get statusStream => _controller.stream;

  bool get _canCheck =>
      _status.state != UpdateState.unsupported &&
      _status.state != UpdateState.notStamped;

  /// Starts polling and listening for focus / visibility changes.
  ///
  /// Does nothing when unsupported, unstamped, already running or disposed.
  void start() {
    if (_disposed || _running || !_canCheck) return;
    _running = true;
    _pollTimer = Timer.periodic(pollInterval, (_) {
      if (pauseWhenHidden && _platform.isHidden) return;
      _checkQuietly();
    });
    _subscriptions.add(
      _platform.onVisibilityChange.listen((bool visible) {
        if (visible) {
          if (checkOnVisibilityChange) _eventCheck();
        } else if (autoReload == AutoReloadPolicy.whenIdle &&
            _status.isUpdateAvailable) {
          _apply();
        }
      }),
    );
    if (checkOnFocus) {
      _subscriptions.add(_platform.onFocus.listen((_) => _eventCheck()));
    }
    if (_status.isUpdateAvailable) _scheduleAutoReload();
    if (checkOnStart) _checkQuietly();
  }

  /// Stops polling and listening. [status] keeps its last value; call [start]
  /// to resume.
  void stop() {
    _running = false;
    _pollTimer?.cancel();
    _pollTimer = null;
    _idleTimer?.cancel();
    _idleTimer = null;
    _activitySub?.cancel();
    _activitySub = null;
    for (final StreamSubscription<Object?> s in _subscriptions) {
      s.cancel();
    }
    _subscriptions.clear();
  }

  /// Stops the guard and closes [statusStream]. The guard cannot be reused.
  void dispose() {
    stop();
    _disposed = true;
    _controller.close();
  }

  void _eventCheck() {
    final DateTime now = _clock();
    final DateTime? last = _lastEventCheck;
    if (last != null && now.difference(last) < minCheckGap) return;
    _lastEventCheck = now;
    _checkQuietly();
  }

  void _checkQuietly() {
    // Errors are already reflected in the status; nothing to rethrow.
    unawaited(checkNow());
  }

  void _emit(UpdateStatus next) {
    if (_disposed || next == _status) return;
    _status = next;
    _controller.add(next);
  }

  @override
  Future<UpdateStatus> checkNow() {
    if (_disposed || !_canCheck || _applying) {
      return Future<UpdateStatus>.value(_status);
    }
    return _inFlight ??= _performCheck().whenComplete(() => _inFlight = null);
  }

  Future<UpdateStatus> _performCheck() async {
    _emit(_status.copyWith(checking: true));
    final String url = cacheBustedUrl(
      versionUrl,
      _clock().microsecondsSinceEpoch,
    );
    try {
      final String body = await _platform.fetchNoStore(
        url,
        timeout: fetchTimeout,
      );
      final BuildInfo remote = BuildInfo.fromJson(jsonDecode(body));
      final bool update = isUpdateAvailable(
        runningBuildId: _status.runningBuildId,
        remote: remote,
        policy: comparison,
      );
      if (_applying) return _status;
      _emit(
        UpdateStatus(
          state: update ? UpdateState.updateAvailable : UpdateState.upToDate,
          runningBuildId: _status.runningBuildId,
          latest: remote,
          checkedAt: _clock(),
        ),
      );
      if (update) {
        _scheduleAutoReload();
      } else if (_platform.readReloadMarker() != null) {
        _platform.writeReloadMarker(null);
      }
    } catch (e) {
      if (_applying) return _status;
      _emit(
        _status.copyWith(
          state: _status.isUpdateAvailable
              ? UpdateState.updateAvailable
              : UpdateState.error,
          error: e,
          checkedAt: _clock(),
          checking: false,
        ),
      );
    }
    return _status;
  }

  /// Whether an automatic reload already targeted the latest build in this
  /// tab and yet the page still runs another build — i.e. reloading does not
  /// help (typically a stale `index.html` in a CDN). Auto-reload then stops
  /// to avoid a reload loop; [applyUpdate] still works when called directly.
  bool get autoReloadSuppressed {
    final String? latest = _status.latest?.buildId;
    return latest != null && _platform.readReloadMarker() == latest;
  }

  void _scheduleAutoReload() {
    if (!_running || autoReloadSuppressed) return;
    switch (autoReload) {
      case AutoReloadPolicy.never:
        return;
      case AutoReloadPolicy.immediately:
        _apply();
      case AutoReloadPolicy.whenIdle:
        if (_platform.isHidden) {
          _apply();
          return;
        }
        if (_idleTimer == null) {
          if (_activitySub == null) {
            // Input is only observed from now on, so the user gets one full
            // idle window before the reload.
            _lastActivity = _clock();
            _activitySub = _platform.onUserActivity.listen(
              (_) => _lastActivity = _clock(),
            );
          }
          _armIdleTimer();
        }
    }
  }

  void _armIdleTimer() {
    final Duration idleFor = _clock().difference(_lastActivity);
    final Duration remaining = idleTimeout - idleFor;
    _idleTimer = Timer(
      remaining > Duration.zero ? remaining : Duration.zero,
      () {
        _idleTimer = null;
        if (!_running || !_status.isUpdateAvailable) return;
        if (_clock().difference(_lastActivity) >= idleTimeout) {
          _apply();
        } else {
          _armIdleTimer();
        }
      },
    );
  }

  void _apply() {
    unawaited(applyUpdate());
  }

  /// Unregisters service workers, clears CacheStorage and the cached document
  /// (per [applyOptions]) and reloads the page.
  ///
  /// Every purge step is best-effort: a failing step never prevents the
  /// reload. Calling it without a detected update simply force-refreshes.
  /// Does nothing on unsupported platforms.
  @override
  Future<void> applyUpdate() async {
    if (_disposed || !_platform.isSupported || _applying) return;
    _applying = true;
    final String? target = _status.latest?.buildId;
    if (target != null) _platform.writeReloadMarker(target);
    _idleTimer?.cancel();
    _idleTimer = null;
    _emit(_status.copyWith(state: UpdateState.applying, checking: false));
    final ApplyUpdateOptions o = applyOptions;
    if (o.unregisterServiceWorkers) {
      await _bestEffort(_platform.unregisterServiceWorkers);
    }
    if (o.clearCacheStorage) {
      await _bestEffort(() => _platform.clearCaches(filter: o.cacheNameFilter));
    }
    if (o.refreshDocument) {
      await _bestEffort(_platform.refreshDocument);
    }
    _platform.reload();
  }

  static Future<void> _bestEffort(Future<Object?> Function() step) async {
    try {
      await step();
    } catch (_) {
      // Purging is an optimisation; the reload must still happen.
    }
  }
}
