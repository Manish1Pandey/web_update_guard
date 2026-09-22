import 'dart:async';
import 'dart:convert';

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:web_update_guard/web_update_guard.dart';

const String running = '0123456789abcdef-20260922T100000Z';
const String newer = 'fedcba9876543210-20260922T120000Z';
const String older = 'aaaaaaaaaaaaaaaa-20260901T000000Z';

/// A scriptable browser for the guard.
class FakePlatform implements UpdateGuardPlatform {
  FakePlatform({this.buildId = running, this.supported = true});

  final String? buildId;
  final bool supported;
  String remoteId = running;
  Object? fetchError;
  Completer<String>? pendingFetch;
  bool hidden = false;
  final List<String> fetchedUrls = <String>[];
  final List<String> calls = <String>[];
  bool Function(String)? usedFilter;
  List<String> cacheNames = <String>['flutter-app-cache', 'my-images'];
  final StreamController<bool> visibility = StreamController<bool>.broadcast();
  final StreamController<void> focus = StreamController<void>.broadcast();
  final StreamController<void> activity = StreamController<void>.broadcast();

  @override
  bool get isSupported => supported;

  @override
  String? readRunningBuildId() => buildId;

  @override
  Future<String> fetchNoStore(String url, {required Duration timeout}) {
    fetchedUrls.add(url);
    if (pendingFetch != null) return pendingFetch!.future;
    if (fetchError != null) return Future<String>.error(fetchError!);
    return Future<String>.value(
      jsonEncode(<String, Object?>{
        'buildId': remoteId,
        'builtAt': null,
        'appVersion': '1.2.3',
      }),
    );
  }

  @override
  bool get isHidden => hidden;

  @override
  Stream<bool> get onVisibilityChange => visibility.stream;

  @override
  Stream<void> get onFocus => focus.stream;

  @override
  Stream<void> get onUserActivity => activity.stream;

  @override
  Future<int> unregisterServiceWorkers() async {
    calls.add('unregister');
    return 1;
  }

  @override
  Future<int> clearCaches({bool Function(String cacheName)? filter}) async {
    calls.add('clearCaches');
    usedFilter = filter;
    return cacheNames.where((String n) => filter?.call(n) ?? true).length;
  }

  @override
  Future<void> refreshDocument() async {
    calls.add('refreshDocument');
    throw StateError('network down'); // must not block the reload
  }

  @override
  void reload() => calls.add('reload');

  String? marker;

  @override
  String? readReloadMarker() => marker;

  @override
  void writeReloadMarker(String? buildId) => marker = buildId;
}

void main() {
  group('initial state', () {
    test('non-web platform reports unsupported and never fetches', () async {
      final FakePlatform platform = FakePlatform(supported: false);
      final WebUpdateGuard guard = WebUpdateGuard(platform: platform)..start();
      expect(guard.isSupported, isFalse);
      expect(guard.isRunning, isFalse);
      expect(guard.status.state, UpdateState.unsupported);
      expect((await guard.checkNow()).state, UpdateState.unsupported);
      await guard.applyUpdate();
      expect(platform.fetchedUrls, isEmpty);
      expect(platform.calls, isEmpty);
      guard.dispose();
    });

    test('default platform on the VM is unsupported', () async {
      final WebUpdateGuard guard = WebUpdateGuard()..start();
      expect(guard.status.state, UpdateState.unsupported);
      expect((await guard.checkNow()).state, UpdateState.unsupported);
      await guard.applyUpdate();
      guard.dispose();
    });

    test('missing meta tag reports notStamped', () async {
      final FakePlatform platform = FakePlatform(buildId: null);
      final WebUpdateGuard guard = WebUpdateGuard(platform: platform);
      expect(guard.status.state, UpdateState.notStamped);
      expect((await guard.checkNow()).state, UpdateState.notStamped);
      expect(platform.fetchedUrls, isEmpty);
    });
  });

  group('checkNow', () {
    test(
      'same build is upToDate, different build is updateAvailable',
      () async {
        final FakePlatform platform = FakePlatform();
        final WebUpdateGuard guard = WebUpdateGuard(platform: platform);
        expect(guard.status.state, UpdateState.idle);
        expect((await guard.checkNow()).state, UpdateState.upToDate);
        platform.remoteId = newer;
        final UpdateStatus s = await guard.checkNow();
        expect(s.state, UpdateState.updateAvailable);
        expect(s.latest!.buildId, newer);
        expect(s.latest!.appVersion, '1.2.3');
        expect(s.runningBuildId, running);
        expect(s.checking, isFalse);
      },
    );

    test('requests are cache-busted and use the configured URL', () async {
      final FakePlatform platform = FakePlatform();
      final WebUpdateGuard guard = WebUpdateGuard(
        platform: platform,
        versionUrl: 'meta/version.json?app=1',
        clock: () => DateTime.fromMicrosecondsSinceEpoch(42),
      );
      await guard.checkNow();
      expect(platform.fetchedUrls.single, 'meta/version.json?app=1&_wug=42');
    });

    test('emits checking then result on the stream', () async {
      final FakePlatform platform = FakePlatform()..remoteId = newer;
      final WebUpdateGuard guard = WebUpdateGuard(platform: platform);
      final List<UpdateStatus> seen = <UpdateStatus>[];
      guard.statusStream.listen(seen.add);
      await guard.checkNow();
      await Future<void>.delayed(Duration.zero);
      expect(seen.map((UpdateStatus s) => (s.state, s.checking)), <Object>[
        (UpdateState.idle, true),
        (UpdateState.updateAvailable, false),
      ]);
    });

    test('concurrent calls share one request', () async {
      final FakePlatform platform = FakePlatform()
        ..pendingFetch = Completer<String>();
      final WebUpdateGuard guard = WebUpdateGuard(platform: platform);
      final Future<UpdateStatus> a = guard.checkNow();
      final Future<UpdateStatus> b = guard.checkNow();
      expect(identical(a, b), isTrue);
      platform.pendingFetch!.complete(
        jsonEncode(<String, String>{'buildId': running}),
      );
      expect((await a).state, UpdateState.upToDate);
      expect(platform.fetchedUrls, hasLength(1));
    });

    test(
      'errors: error state, but a known update survives a failure',
      () async {
        final FakePlatform platform = FakePlatform()
          ..fetchError = const UpdateFetchException('version.json', 404);
        final WebUpdateGuard guard = WebUpdateGuard(platform: platform);
        UpdateStatus s = await guard.checkNow();
        expect(s.state, UpdateState.error);
        expect(s.error, isA<UpdateFetchException>());

        platform
          ..fetchError = null
          ..remoteId = newer;
        s = await guard.checkNow();
        expect(s.state, UpdateState.updateAvailable);
        expect(s.error, isNull);

        platform.fetchError = TimeoutException('slow');
        s = await guard.checkNow();
        expect(s.state, UpdateState.updateAvailable);
        expect(s.error, isA<TimeoutException>());
        expect(s.latest!.buildId, newer);
      },
    );

    test('an unstamped version.json is a FormatException error', () async {
      final FakePlatform platform = FakePlatform()
        ..pendingFetch = (Completer<String>()
          ..complete('{"app_name":"x","version":"1.0.0"}'));
      final WebUpdateGuard guard = WebUpdateGuard(platform: platform);
      final UpdateStatus s = await guard.checkNow();
      expect(s.state, UpdateState.error);
      expect(s.error, isA<FormatException>());
    });

    test('newerOnly ignores an older build served by a stale edge', () async {
      final FakePlatform platform = FakePlatform()..remoteId = older;
      final WebUpdateGuard guard = WebUpdateGuard(
        platform: platform,
        comparison: ComparisonPolicy.newerOnly,
      );
      expect((await guard.checkNow()).state, UpdateState.upToDate);
      platform.remoteId = newer;
      expect((await guard.checkNow()).state, UpdateState.updateAvailable);
    });
  });

  group('scheduling', () {
    test('polls on the interval and pauses while hidden', () {
      fakeAsync((FakeAsync async) {
        final FakePlatform platform = FakePlatform();
        final WebUpdateGuard guard = WebUpdateGuard(
          platform: platform,
          pollInterval: const Duration(minutes: 1),
          clock: () => async.getClock(DateTime.utc(2026)).now(),
        )..start();
        async.flushMicrotasks();
        expect(platform.fetchedUrls, hasLength(1), reason: 'checkOnStart');
        async.elapse(const Duration(minutes: 3));
        expect(platform.fetchedUrls, hasLength(4));
        platform.hidden = true;
        async.elapse(const Duration(minutes: 3));
        expect(platform.fetchedUrls, hasLength(4));
        guard.stop();
        platform.hidden = false;
        async.elapse(const Duration(minutes: 3));
        expect(platform.fetchedUrls, hasLength(4));
        guard.dispose();
      });
    });

    test('visibility and focus trigger throttled checks', () {
      fakeAsync((FakeAsync async) {
        final FakePlatform platform = FakePlatform();
        final WebUpdateGuard guard = WebUpdateGuard(
          platform: platform,
          checkOnStart: false,
          pollInterval: const Duration(hours: 1),
          minCheckGap: const Duration(seconds: 10),
          clock: () => async.getClock(DateTime.utc(2026)).now(),
        )..start();
        platform.visibility.add(true);
        async.flushMicrotasks();
        expect(platform.fetchedUrls, hasLength(1));
        platform.focus.add(null);
        async.flushMicrotasks();
        expect(platform.fetchedUrls, hasLength(1), reason: 'throttled');
        async.elapse(const Duration(seconds: 11));
        platform.focus.add(null);
        async.flushMicrotasks();
        expect(platform.fetchedUrls, hasLength(2));
        platform.visibility.add(false);
        async.flushMicrotasks();
        expect(platform.fetchedUrls, hasLength(2), reason: 'hidden: no check');
        guard.dispose();
      });
    });

    test('focus/visibility checks can be disabled', () {
      fakeAsync((FakeAsync async) {
        final FakePlatform platform = FakePlatform();
        final WebUpdateGuard guard = WebUpdateGuard(
          platform: platform,
          checkOnStart: false,
          checkOnFocus: false,
          checkOnVisibilityChange: false,
        )..start();
        platform.visibility.add(true);
        platform.focus.add(null);
        async.flushMicrotasks();
        expect(platform.fetchedUrls, isEmpty);
        guard.dispose();
      });
    });
  });

  group('applyUpdate and auto-reload', () {
    test('purges in order and reloads even if a step fails', () async {
      final FakePlatform platform = FakePlatform();
      bool keep(String n) => n.startsWith('flutter');
      final WebUpdateGuard guard = WebUpdateGuard(
        platform: platform,
        applyOptions: ApplyUpdateOptions(cacheNameFilter: keep),
      );
      final List<UpdateState> states = <UpdateState>[];
      guard.statusStream.listen((UpdateStatus s) => states.add(s.state));
      await guard.applyUpdate();
      expect(platform.calls, <String>[
        'unregister',
        'clearCaches',
        'refreshDocument',
        'reload',
      ]);
      expect(platform.usedFilter, same(keep));
      expect(states, contains(UpdateState.applying));
      await guard.applyUpdate();
      expect(platform.calls.where((String c) => c == 'reload'), hasLength(1));
      expect((await guard.checkNow()).state, UpdateState.applying);
    });

    test('purge steps can be switched off', () async {
      final FakePlatform platform = FakePlatform();
      final WebUpdateGuard guard = WebUpdateGuard(
        platform: platform,
        applyOptions: const ApplyUpdateOptions(
          unregisterServiceWorkers: false,
          clearCacheStorage: false,
          refreshDocument: false,
        ),
      );
      await guard.applyUpdate();
      expect(platform.calls, <String>['reload']);
    });

    test('never: no reload on detection', () {
      fakeAsync((FakeAsync async) {
        final FakePlatform platform = FakePlatform()..remoteId = newer;
        final WebUpdateGuard guard = WebUpdateGuard(platform: platform)
          ..start();
        async.elapse(const Duration(hours: 1));
        expect(guard.status.state, UpdateState.updateAvailable);
        expect(platform.calls, isEmpty);
        guard.dispose();
      });
    });

    test('immediately: reloads as soon as detected', () {
      fakeAsync((FakeAsync async) {
        final FakePlatform platform = FakePlatform()..remoteId = newer;
        final WebUpdateGuard guard = WebUpdateGuard(
          platform: platform,
          autoReload: AutoReloadPolicy.immediately,
        )..start();
        async.flushMicrotasks();
        expect(platform.calls.last, 'reload');
        guard.dispose();
      });
    });

    test('whenIdle: waits for inactivity, activity postpones it', () {
      fakeAsync((FakeAsync async) {
        final FakePlatform platform = FakePlatform()..remoteId = newer;
        final WebUpdateGuard guard = WebUpdateGuard(
          platform: platform,
          autoReload: AutoReloadPolicy.whenIdle,
          idleTimeout: const Duration(seconds: 60),
          pollInterval: const Duration(hours: 1),
          clock: () => async.getClock(DateTime.utc(2026)).now(),
        )..start();
        async.flushMicrotasks();
        expect(guard.status.isUpdateAvailable, isTrue);
        async.elapse(const Duration(seconds: 50));
        platform.activity.add(null); // user typing
        async.elapse(const Duration(seconds: 50));
        expect(platform.calls, isEmpty, reason: 'only 50s idle');
        async.elapse(const Duration(seconds: 11));
        expect(platform.calls.last, 'reload');
        guard.dispose();
      });
    });

    test('whenIdle: hiding the tab reloads right away', () {
      fakeAsync((FakeAsync async) {
        final FakePlatform platform = FakePlatform()..remoteId = newer;
        final WebUpdateGuard guard = WebUpdateGuard(
          platform: platform,
          autoReload: AutoReloadPolicy.whenIdle,
          idleTimeout: const Duration(minutes: 10),
        )..start();
        async.flushMicrotasks();
        expect(platform.calls, isEmpty);
        platform.visibility.add(false);
        async.flushMicrotasks();
        expect(platform.calls.last, 'reload');
        guard.dispose();
      });
    });

    test('reload-loop guard: no second auto-reload for the same build', () {
      fakeAsync((FakeAsync async) {
        // First page life: detects `newer`, reloads, leaves a marker.
        final FakePlatform platform = FakePlatform()..remoteId = newer;
        WebUpdateGuard guard = WebUpdateGuard(
          platform: platform,
          autoReload: AutoReloadPolicy.immediately,
        )..start();
        async.flushMicrotasks();
        expect(platform.calls.where((String c) => c == 'reload'), hasLength(1));
        expect(platform.marker, newer);
        guard.dispose();

        // Second page life: still running the old build (stale index.html).
        platform.calls.clear();
        guard = WebUpdateGuard(
          platform: platform,
          autoReload: AutoReloadPolicy.immediately,
        )..start();
        async.flushMicrotasks();
        expect(guard.status.state, UpdateState.updateAvailable);
        expect(guard.autoReloadSuppressed, isTrue);
        expect(platform.calls, isEmpty, reason: 'no reload loop');

        // A manual apply is still honoured.
        guard.applyUpdate();
        async.flushMicrotasks();
        expect(platform.calls.last, 'reload');
        guard.dispose();
      });
    });

    test('reload marker is cleared once the tab is up to date', () async {
      final FakePlatform platform = FakePlatform()..marker = newer;
      final WebUpdateGuard guard = WebUpdateGuard(platform: platform);
      expect((await guard.checkNow()).state, UpdateState.upToDate);
      expect(platform.marker, isNull);
    });

    test('whenIdle: an already hidden tab reloads on detection', () {
      fakeAsync((FakeAsync async) {
        final FakePlatform platform = FakePlatform()
          ..remoteId = newer
          ..hidden = true;
        final WebUpdateGuard guard = WebUpdateGuard(
          platform: platform,
          autoReload: AutoReloadPolicy.whenIdle,
        )..start();
        async.flushMicrotasks();
        expect(platform.calls.last, 'reload');
        guard.dispose();
      });
    });
  });
}
