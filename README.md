# web_update_guard

Stop Flutter web users from running a stale cached build after you deploy.

After a new `flutter build web` deploy, browsers keep running the old
`main.dart.js`, `flutter_bootstrap.js`, service worker and assets — sometimes a
mix of two versions — until the user hard-refreshes. This is
[flutter/flutter#149031](https://github.com/flutter/flutter/issues/149031) and
[flutter/flutter#104509](https://github.com/flutter/flutter/issues/104509).

`web_update_guard` fixes it in two parts:

1. **At build time**, a CLI stamps `build/web`. It gives the build a unique ID,
   writes that ID to `version.json`, adds `?v=<buildId>` to the entry-point
   scripts and puts the ID in a `<meta>` tag in `index.html`. A new deploy then
   has new script URLs, so the browser can't mix old and new files.
2. **At run time**, `WebUpdateGuard` fetches `version.json` with the cache
   switched off and compares its build ID with the one the running page was
   built from. When they differ, it tells your UI (or reloads on its own). To
   apply the update it unregisters service workers, clears CacheStorage,
   re-fetches `index.html` and reloads the page.

## Install

```yaml
dependencies:
  web_update_guard: ^0.1.0
```

## 1. Stamp every web build

```sh
flutter build web
dart run web_update_guard stamp build/web
# then deploy build/web
```

```
Stamped build/web
  buildId     3757e581b01d23e5-20260921T193132Z
  builtAt     2026-09-21T19:31:32.000Z
  appVersion  1.0.0+1
  files hashed 34
  updated     index.html, flutter_bootstrap.js, version.json
```

Running `stamp` again on output that hasn't changed leaves every file exactly
as it is (byte for byte). `--force` gives the build a new timestamp and never
duplicates anything.

Options: `--pubspec <path>` (where to read `version:` from; default
`build/web/../../pubspec.yaml`), `--app-version <v>`, `--force`, `--quiet`.

What changes in `build/web`:

| File | Change |
|------|--------|
| `version.json` | adds `buildId`, `builtAt`, `appVersion`, `contentHash` (Flutter's `app_name`/`version`/`build_number`/`package_name` are kept, so `package_info_plus` still works) |
| `index.html` | `flutter_bootstrap.js?v=<id>` (also `flutter.js` / `main.dart.js` in legacy templates) + `<meta name="web-update-guard-build-id" content="<id>">` |
| `flutter_bootstrap.js` | `main.dart.js?v=<id>` and, for `--wasm` builds, `main.dart.wasm?v=<id>` / `main.dart.mjs?v=<id>` |

The build ID is the first 16 hex characters of a SHA-256 hash of the whole
output, followed by the UTC build time. The hash skips the tool's own edits, so
the same content always gives the same hash.

You can also stamp from Dart code: `import 'package:web_update_guard/stamper.dart';`
and call `stampBuildDirectory('build/web')`.

## 2. Guard the running app

```dart
import 'package:web_update_guard/web_update_guard.dart';

final guard = WebUpdateGuard(
  pollInterval: const Duration(minutes: 5),     // default
  checkOnVisibilityChange: true,                // default
  checkOnFocus: true,                           // default
  autoReload: AutoReloadPolicy.never,           // or whenIdle / immediately
)..start();

guard.statusStream.listen((status) {
  if (status.isUpdateAvailable) {
    print('New build ${status.latest!.buildId} (${status.latest!.appVersion})');
  }
});

await guard.checkNow();    // check right away
await guard.applyUpdate(); // purge service workers + caches, then reload
```

### Ready-made UI

The inline banner sits above your page content:

```dart
Scaffold(
  body: UpdateBanner(
    checker: guard,
    child: MyPage(),
    // builder: (context, status, reload, dismiss) => MyOwnBanner(...),
  ),
);
```

The app-wide listener shows a SnackBar (or a MaterialBanner) through the
`ScaffoldMessenger`:

```dart
MaterialApp(
  builder: (context, child) => WebUpdateListener(
    checker: guard,
    presentation: UpdatePresentation.snackBar, // or materialBanner
    // snackBarBuilder / materialBannerBuilder / onUpdateAvailable to customise
    child: child!,
  ),
);
```

Both widgets accept any `UpdateChecker`, so tests can drive them with a fake.

### Options

| Option | Default | Meaning |
|--------|---------|---------|
| `pollInterval` | 5 min | How often to fetch `version.json`. |
| `checkOnStart` | `true` | Check as soon as `start()` is called. |
| `checkOnVisibilityChange` / `checkOnFocus` | `true` | Check when the tab becomes visible or the window gets focus. |
| `minCheckGap` | 15 s | Shortest time between two checks started by focus or visibility. |
| `pauseWhenHidden` | `true` | Skip timed checks while the tab is hidden. |
| `versionUrl` | `version.json` | Resolved against `document.baseURI`, so `--base-href` works. |
| `fetchTimeout` | 15 s | Timeout for one request. |
| `comparison` | `anyDifference` | `newerOnly` ignores builds that are older than the running one (useful when some CDN edges are still stale). |
| `autoReload` | `never` | `whenIdle` reloads once the tab is hidden or has had no input for `idleTimeout` (2 min). `immediately` reloads as soon as an update is found. |
| `applyOptions` | all on | Choose whether to unregister service workers, clear CacheStorage (`cacheNameFilter` limits which caches are deleted) and re-fetch the document. |

**Reload-loop guard.** Sometimes `version.json` is new but a CDN still serves
the old `index.html`. Reloading can't fix that. The guard remembers (in
`sessionStorage`) which build it reloaded for. If the page comes back still
running the old build, it stops reloading automatically, keeps reporting
`updateAvailable` and leaves the choice to the user. Check
`guard.autoReloadSuppressed` to see whether this has happened.

### Status states

`unsupported` (not on the web), `notStamped` (no meta tag, e.g. `flutter run`),
`idle`, `upToDate`, `updateAvailable`, `applying`, `error`. `status.checking`
is `true` while a request is running. If a check fails after an update was
already found, the state stays `updateAvailable` and `status.error` holds the
failure.

## Server configuration (recommended)

Serve `index.html` and `version.json` with `Cache-Control: no-cache`. Every
other file can be cached for a long time: the entry points get a new URL on
each deploy.

## Platform support

| Platform | CLI (`stamp`) | `WebUpdateGuard` | Widgets |
|----------|---------------|------------------|---------|
| Web — dart2js | runs on your build machine | full | full |
| Web — dart2wasm (`--wasm`) | runs on your build machine | full | full |
| Android, iOS, macOS, Windows, Linux | — | no-op, reports `unsupported` | show nothing but the child |

## Limitations

- The tool only cache-busts the entry points: `main.dart.js`,
  `flutter_bootstrap.js`, `flutter.js`, `main.dart.wasm` and `main.dart.mjs`.
  The engine builds some URLs itself (assets, fonts, a locally hosted
  CanvasKit/skwasm, deferred `*.part.js`), so the tool can't add `?v=` to them.
  `applyUpdate()` clears CacheStorage and service workers, but whether the HTTP
  cache serves these files fresh still depends on your server headers.
- No web API can clear the browser's HTTP cache. The guard only refreshes the
  `index.html` entry (with `fetch(..., {cache: 'reload'})`) before reloading.
- An unstamped build (`flutter run`, or a deploy where you forgot `stamp`)
  can't be compared. It reports `notStamped`.
- `applyUpdate()` clears every CacheStorage cache on the origin unless you set
  `cacheNameFilter`.
- The service worker and CacheStorage steps only work in secure contexts
  (https or localhost). On plain http they are skipped, and the reload still
  happens.

## Example

`example/` has a demo that shows the live status, **Check now**, **Purge
caches & reload**, both widgets, and switches for every policy. You can also
pick a policy in the URL with `?autoReload=whenIdle`.

```sh
cd example
flutter build web && dart run web_update_guard stamp build/web
python3 -m http.server -d build/web 8080
# open http://localhost:8080, then rebuild + restamp (or `stamp --force`)
# and focus the tab: the banner appears.
```

## License

MIT © 2026 Manish Kumar Panday
