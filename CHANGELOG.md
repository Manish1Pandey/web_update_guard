## 0.1.1

- Homepage and README now link to the package's documentation page on flutterdev.in. No code changes.

## 0.1.0

- Initial release.
- `dart run web_update_guard stamp build/web`: content-hash + timestamp build
  ID, `version.json` (merged with Flutter's own keys), `?v=<buildId>`
  cache-busting of `main.dart.js`, `flutter_bootstrap.js`, `flutter.js`,
  `main.dart.wasm` and `main.dart.mjs`, build-ID `<meta>` tag. Idempotent.
- `WebUpdateGuard`: polling, focus / visibility checks, `no-store` +
  cache-busted `version.json` fetch, `Stream<UpdateStatus>`, `checkNow()`,
  `applyUpdate()` (unregister service workers, clear CacheStorage, refresh the
  document, reload), auto-reload policies `never` / `whenIdle` / `immediately`,
  reload-loop guard. No-op (`unsupported`) off the web.
- Widgets: `UpdateBanner` (inline `MaterialBanner` or custom builder) and
  `WebUpdateListener` (`SnackBar` / `MaterialBanner` via `ScaffoldMessenger`).
