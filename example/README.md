# web_update_guard example

Demo app for `web_update_guard`. It shows the guard's live status, the
**Check now** and **Purge caches & reload** buttons, the inline `UpdateBanner`,
the app-wide `WebUpdateListener` (SnackBar or MaterialBanner), and switches
for the auto-reload policy, the comparison policy and the cache filter.

```sh
flutter build web
dart run web_update_guard stamp build/web
python3 -m http.server -d build/web 8080
```

Open http://localhost:8080 (or `?autoReload=immediately`). Then deploy a new
build (rebuild and restamp, or run `dart run web_update_guard stamp --force
build/web`) and focus the tab. The update is detected and announced.

On Android, iOS and desktop the demo runs too; the status shows `unsupported`.
