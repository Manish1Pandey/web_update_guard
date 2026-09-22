import 'dart:async';
import 'dart:js_interop';
import 'dart:js_interop_unsafe';

import 'package:web/web.dart' as web;

import '../build_info.dart';
import 'update_guard_platform.dart';

/// Returns the platform implementation for the web.
UpdateGuardPlatform createDefaultPlatform() => BrowserUpdateGuardPlatform();

/// The real browser implementation, built on `package:web` and
/// `dart:js_interop`.
class BrowserUpdateGuardPlatform implements UpdateGuardPlatform {
  /// Creates the browser platform.
  BrowserUpdateGuardPlatform();

  static const List<String> _activityEvents = <String>[
    'pointerdown',
    'pointermove',
    'keydown',
    'wheel',
    'touchstart',
  ];

  @override
  bool get isSupported => true;

  @override
  String? readRunningBuildId() {
    final web.Element? meta = web.document.querySelector(
      'meta[name="$buildIdMetaName"]',
    );
    final String? value = meta?.getAttribute('content')?.trim();
    return (value == null || value.isEmpty) ? null : value;
  }

  String _resolve(String url) =>
      Uri.parse(web.document.baseURI).resolve(url).toString();

  @override
  Future<String> fetchNoStore(String url, {required Duration timeout}) async {
    final String resolved = _resolve(url);
    final web.AbortController abort = web.AbortController();
    bool timedOut = false;
    final Timer timer = Timer(timeout, () {
      timedOut = true;
      abort.abort();
    });
    try {
      final web.Response response = await web.window
          .fetch(
            resolved.toJS,
            web.RequestInit(
              cache: 'no-store',
              credentials: 'same-origin',
              signal: abort.signal,
            ),
          )
          .toDart;
      if (!response.ok) {
        throw UpdateFetchException(resolved, response.status);
      }
      return (await response.text().toDart).toDart;
    } catch (e) {
      if (timedOut) {
        throw TimeoutException('Fetching $resolved timed out', timeout);
      }
      rethrow;
    } finally {
      timer.cancel();
    }
  }

  @override
  bool get isHidden => web.document.hidden;

  @override
  Stream<bool> get onVisibilityChange =>
      const web.EventStreamProvider<web.Event>(
        'visibilitychange',
      ).forTarget(web.document).map((web.Event _) => !web.document.hidden);

  @override
  Stream<void> get onFocus =>
      web.EventStreamProviders.focusEvent.forTarget(web.window);

  @override
  Stream<void> get onUserActivity {
    final List<StreamSubscription<web.Event>> subs =
        <StreamSubscription<web.Event>>[];
    late final StreamController<void> controller;
    controller = StreamController<void>.broadcast(
      onListen: () {
        for (final String type in _activityEvents) {
          subs.add(
            web.EventStreamProvider<web.Event>(type)
                .forTarget(web.window)
                .listen((web.Event _) => controller.add(null)),
          );
        }
      },
      onCancel: () {
        for (final StreamSubscription<web.Event> s in subs) {
          s.cancel();
        }
        subs.clear();
      },
    );
    return controller.stream;
  }

  @override
  Future<int> unregisterServiceWorkers() async {
    final web.Navigator navigator = web.window.navigator;
    if (!(navigator as JSObject).has('serviceWorker')) return 0;
    final JSArray<web.ServiceWorkerRegistration> regs = await navigator
        .serviceWorker
        .getRegistrations()
        .toDart;
    int removed = 0;
    for (final web.ServiceWorkerRegistration reg in regs.toDart) {
      if ((await reg.unregister().toDart).toDart) removed++;
    }
    return removed;
  }

  @override
  Future<int> clearCaches({bool Function(String cacheName)? filter}) async {
    // CacheStorage only exists in secure contexts (https or localhost).
    if (!(web.window as JSObject).has('caches')) return 0;
    final web.CacheStorage caches = web.window.caches;
    final JSArray<JSString> keys = await caches.keys().toDart;
    int deleted = 0;
    for (final JSString key in keys.toDart) {
      final String name = key.toDart;
      if (filter != null && !filter(name)) continue;
      if ((await caches.delete(name).toDart).toDart) deleted++;
    }
    return deleted;
  }

  @override
  Future<void> refreshDocument() async {
    final Uri here = Uri.parse(web.window.location.href);
    final String url = here.removeFragment().toString();
    final web.Response response = await web.window
        .fetch(
          url.toJS,
          web.RequestInit(cache: 'reload', credentials: 'same-origin'),
        )
        .toDart;
    // Drain the body so the refreshed entry is fully written to the cache.
    await response.text().toDart;
  }

  @override
  void reload() => web.window.location.reload();

  static const String _markerKey = 'web_update_guard.reloadedFor';

  @override
  String? readReloadMarker() {
    try {
      return web.window.sessionStorage.getItem(_markerKey);
    } catch (_) {
      // Storage can be blocked (privacy settings, sandboxed iframes).
      return null;
    }
  }

  @override
  void writeReloadMarker(String? buildId) {
    try {
      if (buildId == null) {
        web.window.sessionStorage.removeItem(_markerKey);
      } else {
        web.window.sessionStorage.setItem(_markerKey, buildId);
      }
    } catch (_) {
      // Without storage the loop guard is simply unavailable.
    }
  }
}
