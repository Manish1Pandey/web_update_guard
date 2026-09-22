# web_update_guard — Specification

## Purpose

After a new Flutter web deploy, users keep running the stale cached bundle
(`main.dart.js`, `flutter_bootstrap.js`, service worker, assets), sometimes a
mix of two versions, until they hard-refresh
([flutter/flutter#149031](https://github.com/flutter/flutter/issues/149031),
[flutter/flutter#104509](https://github.com/flutter/flutter/issues/104509)).

`web_update_guard` fixes both halves of the problem:

1. **Build time** — a CLI stamps the `flutter build web` output with a unique
   build ID and cache-busts the entry-point scripts so a new deploy can never be
   served half-old / half-new from the HTTP cache.
2. **Run time** — a Dart API detects that the server now hosts a different
   build than the one running in the tab, tells the UI, and on request (or
   automatically) purges service workers + CacheStorage and reloads.

## Functional requirements

### CLI (`dart run web_update_guard stamp <build/web>`)

| ID | Requirement |
|----|-------------|
| C1 | Compute a content hash (SHA-256) over every file in the build directory, sorted by path. `version.json` is excluded and `index.html` / `flutter_bootstrap.js` are hashed in their *unstamped* form, so the hash only changes when the real build changes. |
| C2 | Build ID = first 16 hex chars of the hash + `-` + UTC timestamp (`yyyyMMddTHHmmssZ`). |
| C3 | Write `version.json` with `buildId`, `builtAt` (ISO-8601 UTC), `appVersion` (from pubspec `version:`), `contentHash`. Keys Flutter already writes there (`app_name`, `version`, `build_number`, `package_name`, used by `package_info_plus`) are **preserved**. |
| C4 | In `index.html` and `flutter_bootstrap.js`, rewrite quoted/relative references to `main.dart.js`, `flutter_bootstrap.js` and `flutter.js` (plus the dart2wasm entry points `main.dart.wasm` / `main.dart.mjs`) to `<name>?v=<buildId>`, keeping any other query parameters. `main.dart.js_1.part.js`, `*.map` and similar names, and text inside HTML comments, are not touched. |
| C5 | Inject/replace `<meta name="web-update-guard-build-id" content="<buildId>">` in `<head>` of `index.html`. |
| C6 | Idempotent: re-running on unchanged output produces byte-identical files (the previous `builtAt` is reused when the content hash is unchanged). `--force` issues a fresh timestamp; nothing is ever duplicated. |
| C7 | Options: `--pubspec <path>`, `--app-version <v>`, `--force`, `--quiet`, `--help`. Non-zero exit code + message on a missing directory / missing `index.html`. |

### Runtime (`WebUpdateGuard`)

| ID | Requirement |
|----|-------------|
| R1 | Read the running build ID from the meta tag. |
| R2 | Fetch `version.json` (resolved against `document.baseURI`, so `--base-href` works) with `cache: 'no-store'` **and** a cache-busting query parameter, with a timeout. |
| R3 | Compare the remote build with the running one (`anyDifference` default, or `newerOnly` using the timestamps embedded in build IDs). |
| R4 | Poll on a configurable interval; optionally check on `visibilitychange` (to visible) and window `focus`, throttled by a minimum gap; optionally pause polling while the tab is hidden. |
| R5 | Expose `Stream<UpdateStatus>`, the latest `status`, `checkNow()`, `applyUpdate()`. |
| R6 | `applyUpdate()` unregisters all service workers of the origin, deletes CacheStorage caches (all, or those passing a filter), re-fetches the document with `cache: 'reload'` to refresh the HTTP cache, then `location.reload()`. Each step is optional. |
| R7 | Auto-reload policy: `never` (default), `whenIdle` (tab hidden or no user input for `idleTimeout`), `immediately`. |
| R7a | Reload-loop guard: the build ID targeted by a reload is kept in `sessionStorage`; if the page comes back still running another build, auto-reload for that same target is suppressed (manual `applyUpdate()` still works). Cleared once up to date. |
| R8 | On non-web platforms every call is a safe no-op and the status is `UpdateState.unsupported`. |

### Widgets

| ID | Requirement |
|----|-------------|
| W1 | `UpdateBanner` — inline widget that shows a `MaterialBanner` (or a custom `builder` result) above an optional child while an update is available; dismissible per build. |
| W2 | `WebUpdateListener` — wraps a subtree and presents the update through the nearest `ScaffoldMessenger` as a `SnackBar` or `MaterialBanner`, with builders for full customisation and an `onUpdateAvailable` hook. |
| W3 | Both accept any `UpdateChecker` (the interface `WebUpdateGuard` implements), so they can be driven by a fake in tests. |

## Can / Cannot

| Can | Cannot |
|-----|--------|
| Guarantee a new deploy loads a consistent `main.dart.js` / `flutter_bootstrap.js` / `flutter.js` / `main.dart.wasm` / `main.dart.mjs` (unique URLs per build). | Cache-bust files that the Flutter engine loads by computed URL (assets, fonts, local CanvasKit/skwasm, deferred `*.part.js`). These are fetched fresh after `applyUpdate()` clears caches, but HTTP-cache freshness for them still depends on your server headers. |
| Detect a new deploy within one poll interval or on tab focus / visibility. | Detect a deploy while the device is offline or the server is unreachable (reported as `UpdateState.error`, polling continues). |
| Unregister service workers and clear CacheStorage of the origin, then reload. | Clear the browser's HTTP cache in general — no web API allows that; we refresh only the document entry via `cache: 'reload'`. |
| Work behind a sub-path (`--base-href`). | Help if `index.html` itself is served with a long `max-age` by a CDN *and* the CDN ignores `cache: 'reload'` — configure `Cache-Control: no-cache` for `index.html` and `version.json`. (The reload-loop guard keeps the tab usable; the banner stays visible.) |
| Run as a no-op on Android/iOS/macOS/Windows/Linux (status `unsupported`). | Do anything useful on non-web platforms — native apps update through stores. |
| Keep `package_info_plus` working (existing `version.json` keys preserved). | Detect an update when running unstamped (e.g. `flutter run`) — status is `notStamped`. |

## Public API sketch

```dart
abstract interface class UpdateChecker {
  UpdateStatus get status;
  Stream<UpdateStatus> get statusStream;
  Future<UpdateStatus> checkNow();
  Future<void> applyUpdate();
}

class WebUpdateGuard implements UpdateChecker {
  WebUpdateGuard({Duration pollInterval, bool checkOnVisibilityChange,
      bool checkOnFocus, bool pauseWhenHidden, Duration minCheckGap,
      String versionUrl, Duration fetchTimeout, ComparisonPolicy comparison,
      AutoReloadPolicy autoReload, Duration idleTimeout,
      ApplyUpdateOptions applyOptions, UpdateGuardPlatform? platform});
  bool get isSupported; String? get runningBuildId; bool get isRunning;
  bool get autoReloadSuppressed;
  void start(); void stop(); void dispose();
}

enum UpdateState { unsupported, notStamped, idle, upToDate,
                   updateAvailable, applying, error }
class UpdateStatus { UpdateState state; String? runningBuildId; bool checking;
                     BuildInfo? latest; Object? error; DateTime? checkedAt; }
class BuildInfo { String buildId; DateTime? builtAt; String? appVersion; ... }
enum AutoReloadPolicy { never, whenIdle, immediately }
enum ComparisonPolicy { anyDifference, newerOnly }
bool isUpdateAvailable(String? running, BuildInfo remote, {ComparisonPolicy});

class UpdateBanner extends StatefulWidget { ... }
class WebUpdateListener extends StatefulWidget { ... }

// package:web_update_guard/stamper.dart (dart:io, CLI only)
StampResult stampBuildDirectory(String dir, {String? pubspecPath,
    String? appVersion, bool force, DateTime? now});
```

## Platform matrix

| Platform | CLI | Runtime API | Widgets |
|----------|-----|-------------|---------|
| Web (dart2js / dart2wasm) | — | Full | Full |
| Android / iOS / macOS / Windows / Linux | runs on host (macOS/Linux/Windows) | no-op, `unsupported` | render nothing (child only) |
