import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path/path.dart' as p;
import 'package:web_update_guard/stamper.dart';

const String _indexHtml = '''
<!DOCTYPE html>
<html>
<head>
  <base href="/">
  <meta charset="UTF-8">
  <title>fixture</title>
  <link rel="manifest" href="manifest.json">
</head>
<body>
  <!-- You can customize the "flutter_bootstrap.js" script. -->
  <script src="flutter_bootstrap.js" async></script>
</body>
</html>
''';

// Mirrors the tail of a Flutter 3.41 flutter_bootstrap.js, including the
// inlined loader defaults and the source-map comment that must not change.
const String _bootstrapJs = '''
(()=>{let l=e.mainJsPath??"main.dart.js";let n=c("main.dart.js");})();
//# sourceMappingURL=flutter.js.map

if (!window._flutter) {
  window._flutter = {};
}
_flutter.buildConfig = {"engineRevision":"abc","builds":[{"compileTarget":"dart2js","renderer":"canvaskit","mainJsPath":"main.dart.js"},{}]};

_flutter.loader.load({
  serviceWorkerSettings: {
    serviceWorkerVersion: "2514006559"
  }
});
''';

// A legacy (pre-3.22 style) index.html that loads flutter.js directly.
const String _legacyIndex = '''
<html><head><script src="flutter.js?foo=1" defer></script></head>
<body><script>
  _flutter.loader.loadEntrypoint({entrypointUrl: 'main.dart.js'});
</script></body></html>
''';

late Directory root;
late Directory build;

String read(String rel) => File(p.join(build.path, rel)).readAsStringSync();
void write(String rel, String content) {
  final File f = File(p.join(build.path, rel));
  f.parent.createSync(recursive: true);
  f.writeAsStringSync(content);
}

Map<String, Object?> versionJson() =>
    (jsonDecode(read('version.json')) as Map).cast<String, Object?>();

Map<String, String> snapshot() => <String, String>{
  for (final File f in build.listSync(recursive: true).whereType<File>())
    p.relative(f.path, from: build.path): f.readAsStringSync(),
};

int count(String haystack, String needle) => needle.allMatches(haystack).length;

void main() {
  final DateTime t1 = DateTime.utc(2026, 9, 22, 10, 15, 30, 999);
  final DateTime t2 = DateTime.utc(2026, 9, 23, 8, 0, 0);

  setUp(() {
    root = Directory.systemTemp.createTempSync('wug_stamp_');
    build = Directory(p.join(root.path, 'build', 'web'))
      ..createSync(recursive: true);
    File(
      p.join(root.path, 'pubspec.yaml'),
    ).writeAsStringSync('name: fixture\nversion: 2.3.4+56\n');
    write('index.html', _indexHtml);
    write('flutter_bootstrap.js', _bootstrapJs);
    write('flutter.js', '/* loader */');
    write('main.dart.js', 'console.log("app v1");');
    write('main.dart.js_1.part.js', 'console.log("deferred");');
    write('assets/AssetManifest.bin.json', '"x"');
    // What `flutter build web` writes; package_info_plus reads these keys.
    write(
      'version.json',
      '{"app_name":"fixture","version":"2.3.4","build_number":"56",'
          '"package_name":"fixture"}',
    );
  });

  tearDown(() => root.deleteSync(recursive: true));

  test('writes version.json and keeps Flutter keys', () {
    final StampResult r = stampBuildDirectory(build.path, now: t1);
    final Map<String, Object?> v = versionJson();
    expect(v['buildId'], r.info.buildId);
    expect(r.info.buildId, matches(RegExp(r'^[0-9a-f]{16}-20260922T101530Z$')));
    expect(v['builtAt'], '2026-09-22T10:15:30.000Z');
    expect(v['appVersion'], '2.3.4+56');
    expect(v['contentHash'], hasLength(64));
    expect(v['app_name'], 'fixture');
    expect(v['build_number'], '56');
    expect(r.hashedFileCount, 6);
    expect(
      r.writtenFiles,
      containsAll(<String>[
        'index.html',
        'flutter_bootstrap.js',
        'version.json',
      ]),
    );
  });

  test('rewrites index.html: cache-busts and injects meta tag', () {
    final String id = stampBuildDirectory(build.path, now: t1).info.buildId;
    final String html = read('index.html');
    expect(html, contains('<script src="flutter_bootstrap.js?v=$id" async>'));
    expect(
      html,
      contains(
        '  <meta name="web-update-guard-build-id" content="$id">\n</head>',
      ),
    );
    expect(html, contains('href="manifest.json"'), reason: 'untouched');
    expect(
      html,
      contains('customize the "flutter_bootstrap.js" script'),
      reason: 'HTML comments are left alone',
    );
  });

  test('rewrites flutter_bootstrap.js but not part files or source maps', () {
    final String id = stampBuildDirectory(build.path, now: t1).info.buildId;
    final String js = read('flutter_bootstrap.js');
    expect(js, contains('"mainJsPath":"main.dart.js?v=$id"'));
    expect(js, contains('e.mainJsPath??"main.dart.js?v=$id"'));
    expect(js, contains('c("main.dart.js?v=$id")'));
    expect(js, contains('//# sourceMappingURL=flutter.js.map\n'));
    expect(js, contains('serviceWorkerVersion: "2514006559"'));
    expect(read('main.dart.js_1.part.js'), 'console.log("deferred");');
    expect(read('main.dart.js'), 'console.log("app v1");');
  });

  test('re-running on unchanged output is a byte-identical no-op', () {
    final StampResult first = stampBuildDirectory(build.path, now: t1);
    final Map<String, String> before = snapshot();
    final StampResult second = stampBuildDirectory(build.path, now: t2);
    expect(second.info.buildId, first.info.buildId);
    expect(second.reusedBuiltAt, isTrue);
    expect(second.writtenFiles, isEmpty);
    expect(snapshot(), before);
  });

  test('--force re-stamps with a new timestamp and never duplicates', () {
    final String id1 = stampBuildDirectory(build.path, now: t1).info.buildId;
    final String id2 = stampBuildDirectory(
      build.path,
      now: t2,
      force: true,
    ).info.buildId;
    expect(id2, isNot(id1));
    expect(id2.split('-').first, id1.split('-').first, reason: 'same content');
    final String html = read('index.html');
    expect(count(html, 'web-update-guard-build-id'), 1);
    expect(count(html, '?v='), 1);
    expect(html, contains('flutter_bootstrap.js?v=$id2"'));
    expect(html, isNot(contains(id1)));
    final String js = read('flutter_bootstrap.js');
    expect(count(js, '?v='), 3);
    expect(js, isNot(contains(id1)));
    expect(versionJson()['buildId'], id2);
  });

  test('a real content change produces a new hash', () {
    final String id1 = stampBuildDirectory(build.path, now: t1).info.buildId;
    write('main.dart.js', 'console.log("app v2");');
    final StampResult r = stampBuildDirectory(build.path, now: t1);
    expect(r.reusedBuiltAt, isFalse);
    expect(r.info.buildId.split('-').first, isNot(id1.split('-').first));
  });

  test('a fresh flutter build over a stamped dir hashes like the original', () {
    final String id1 = stampBuildDirectory(build.path, now: t1).info.buildId;
    // Simulate `flutter build web` again: unstamped files, Flutter's own
    // version.json, identical content.
    write('index.html', _indexHtml);
    write('flutter_bootstrap.js', _bootstrapJs);
    write('version.json', '{"app_name":"fixture","version":"2.3.4"}');
    final String id2 = stampBuildDirectory(build.path, now: t2).info.buildId;
    expect(id2.split('-').first, id1.split('-').first);
  });

  test('legacy index keeps other query params and busts flutter.js', () {
    write('index.html', _legacyIndex);
    final String id = stampBuildDirectory(build.path, now: t1).info.buildId;
    String html = read('index.html');
    expect(html, contains('src="flutter.js?foo=1&v=$id"'));
    expect(html, contains("entrypointUrl: 'main.dart.js?v=$id'"));
    expect(html, contains('<meta name="web-update-guard-build-id"'));
    stampBuildDirectory(build.path, now: t2, force: true);
    html = read('index.html');
    expect(count(html, 'foo=1'), 1);
    expect(count(html, 'web-update-guard-build-id'), 1);
    expect(unstampIndexHtml(html), _legacyIndex);
  });

  test('app version sources: override, explicit pubspec, Flutter fallback', () {
    expect(
      stampBuildDirectory(build.path, appVersion: '9.9.9').info.appVersion,
      '9.9.9',
    );
    final File other = File(p.join(root.path, 'other.yaml'))
      ..writeAsStringSync('name: x\nversion: 1.0.0\n');
    expect(
      stampBuildDirectory(build.path, pubspecPath: other.path).info.appVersion,
      '1.0.0',
    );
    File(p.join(root.path, 'pubspec.yaml')).deleteSync();
    final Directory isolated = Directory.systemTemp.createTempSync('wug_cwd_');
    final Directory saved = Directory.current;
    Directory.current = isolated;
    try {
      expect(stampBuildDirectory(build.path).info.appVersion, '2.3.4+56');
    } finally {
      Directory.current = saved;
      isolated.deleteSync(recursive: true);
    }
  });

  test('errors are reported as StampException', () {
    expect(
      () => stampBuildDirectory(p.join(root.path, 'missing')),
      throwsA(isA<StampException>()),
    );
    File(p.join(build.path, 'index.html')).deleteSync();
    expect(
      () => stampBuildDirectory(build.path),
      throwsA(
        isA<StampException>().having(
          (StampException e) => e.message,
          'message',
          contains('index.html'),
        ),
      ),
    );
    write('index.html', '<html><body></body></html>');
    expect(
      () => stampBuildDirectory(build.path),
      throwsA(isA<StampException>()),
    );
    expect(
      () => stampBuildDirectory(build.path, pubspecPath: '/nope/pubspec.yaml'),
      throwsA(isA<StampException>()),
    );
  });

  group('runCli', () {
    test('stamp succeeds and prints the build id', () {
      final StringBuffer out = StringBuffer();
      final StringBuffer err = StringBuffer();
      final int code = runCli(
        <String>['stamp', build.path],
        out: out,
        err: err,
      );
      expect(code, 0, reason: err.toString());
      expect(
        out.toString(),
        contains('buildId     ${versionJson()['buildId']}'),
      );
      final StringBuffer again = StringBuffer();
      expect(runCli(<String>['stamp', build.path], out: again), 0);
      expect(again.toString(), contains('unchanged'));
    });

    test('usage errors return 64, failures return 1, help returns 0', () {
      final StringBuffer sink = StringBuffer();
      expect(runCli(<String>[], out: sink, err: sink), 64);
      expect(runCli(<String>['stamp'], out: sink, err: sink), 64);
      expect(runCli(<String>['stamp', '--bogus'], out: sink, err: sink), 64);
      expect(runCli(<String>['--help'], out: sink, err: sink), 0);
      expect(runCli(<String>['stamp', '--help'], out: sink, err: sink), 0);
      final StringBuffer err = StringBuffer();
      expect(runCli(<String>['stamp', p.join(root.path, 'nope')], err: err), 1);
      expect(err.toString(), contains('does not exist'));
    });
  });

  group('rewrite helpers', () {
    test('only exact script names are matched', () {
      const String src =
          '"main.dart.js" "main.dart.js_1.part.js" "my_flutter.js" '
          '"flutter.js.map" "/app/flutter.js" (flutter_bootstrap.js)';
      expect(
        cacheBustScripts(src, 'ID'),
        '"main.dart.js?v=ID" "main.dart.js_1.part.js" "my_flutter.js" '
        '"flutter.js.map" "/app/flutter.js?v=ID" (flutter_bootstrap.js?v=ID)',
      );
      expect(removeCacheBust(cacheBustScripts(src, 'ID')), src);
    });

    test('dart2wasm entry points are cache-busted too', () {
      const String config =
          '{"compileTarget":"dart2wasm","renderer":"skwasm",'
          '"mainWasmPath":"main.dart.wasm","jsSupportRuntimePath":"main.dart.mjs"}';
      expect(
        cacheBustScripts(config, 'ID'),
        '{"compileTarget":"dart2wasm","renderer":"skwasm",'
        '"mainWasmPath":"main.dart.wasm?v=ID",'
        '"jsSupportRuntimePath":"main.dart.mjs?v=ID"}',
      );
      expect(
        cacheBustScripts('"main.dart.wasm.map"', 'ID'),
        '"main.dart.wasm.map"',
      );
    });

    test('meta injection works without a newline before </head>', () {
      const String html = '<html><head><title>x</title></head></html>';
      final String once = injectBuildIdMeta(html, 'A');
      expect(
        once,
        '<html><head><title>x</title>'
        '<meta name="web-update-guard-build-id" content="A"></head></html>',
      );
      expect(injectBuildIdMeta(once, 'B'), injectBuildIdMeta(html, 'B'));
      expect(removeBuildIdMeta(once), html);
    });
  });
}
