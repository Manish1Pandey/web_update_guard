/// Keeps Flutter web users off stale cached builds.
///
/// Stamp the build with `dart run web_update_guard stamp build/web`, then run
/// a [WebUpdateGuard] in the app and show an [UpdateBanner] or wrap the app in
/// a [WebUpdateListener]. On non-web platforms everything is a no-op that
/// reports [UpdateState.unsupported].
library;

export 'src/build_info.dart';
export 'src/platform/update_guard_platform.dart';
export 'src/update_status.dart';
export 'src/web_update_guard.dart';
export 'src/widgets/update_banner.dart';
export 'src/widgets/web_update_listener.dart';
