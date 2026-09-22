/// Build-time stamping for Flutter web output (uses `dart:io`; import it from
/// scripts and tools, not from app code).
///
/// ```dart
/// import 'package:web_update_guard/stamper.dart';
///
/// final result = stampBuildDirectory('build/web');
/// print(result.info.buildId);
/// ```
library;

export 'src/build_info.dart'
    show BuildInfo, buildIdMetaName, formatBuildId, buildTimeFromId;
export 'src/stamper/cli.dart' show runCli;
export 'src/stamper/rewrite.dart'
    show
        cacheBustedScripts,
        cacheBustScripts,
        removeCacheBust,
        injectBuildIdMeta,
        removeBuildIdMeta,
        stampIndexHtml,
        unstampIndexHtml,
        stampBootstrapJs;
export 'src/stamper/stamper.dart'
    show StampException, StampResult, stampBuildDirectory;
