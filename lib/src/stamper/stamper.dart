import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:yaml/yaml.dart';

import '../build_info.dart';
import 'rewrite.dart';

/// Thrown when a build directory cannot be stamped.
class StampException implements Exception {
  /// Creates the exception.
  const StampException(this.message);

  /// Human-readable reason.
  final String message;

  @override
  String toString() => 'StampException: $message';
}

/// The outcome of [stampBuildDirectory].
class StampResult {
  /// Creates a result.
  const StampResult({
    required this.info,
    required this.writtenFiles,
    required this.reusedBuiltAt,
    required this.hashedFileCount,
  });

  /// The build metadata written to `version.json`.
  final BuildInfo info;

  /// Paths (relative to the build directory) whose content changed.
  final List<String> writtenFiles;

  /// Whether the previous `builtAt` was kept because the content hash is
  /// unchanged (a no-op re-run).
  final bool reusedBuiltAt;

  /// Number of files included in the content hash.
  final int hashedFileCount;
}

class _DigestSink implements Sink<Digest> {
  Digest? value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}

/// Stamps a `flutter build web` output directory in place.
///
/// * Computes a SHA-256 content hash of the build (ignoring `version.json`
///   and this tool's own edits) and a build ID `<hash16>-<UTC timestamp>`.
/// * Writes/merges `version.json` with `buildId`, `builtAt`, `appVersion` and
///   `contentHash`, preserving keys Flutter already put there.
/// * Cache-busts `main.dart.js`, `flutter_bootstrap.js` and `flutter.js`
///   references in `index.html` and `flutter_bootstrap.js` with `?v=<id>`.
/// * Injects `<meta name="web-update-guard-build-id">` into `index.html`.
///
/// Re-running on unchanged output is a byte-for-byte no-op unless [force] is
/// set, which issues a new timestamp. [appVersion] overrides the version read
/// from [pubspecPath] (default: `<buildDir>/../../pubspec.yaml`, then
/// `./pubspec.yaml`, then Flutter's own `version.json` fields). [now] exists
/// for tests.
///
/// Throws a [StampException] when the directory or `index.html` is missing
/// or malformed.
StampResult stampBuildDirectory(
  String buildDir, {
  String? pubspecPath,
  String? appVersion,
  bool force = false,
  DateTime? now,
}) {
  final Directory dir = Directory(buildDir);
  if (!dir.existsSync()) {
    throw StampException('Build directory "$buildDir" does not exist.');
  }
  final File index = File(p.join(dir.path, 'index.html'));
  if (!index.existsSync()) {
    throw StampException(
      'No index.html in "$buildDir". Run `flutter build web` first.',
    );
  }
  final File bootstrap = File(p.join(dir.path, 'flutter_bootstrap.js'));
  final File versionFile = File(p.join(dir.path, 'version.json'));

  final String indexText = index.readAsStringSync();
  final String? bootstrapText = bootstrap.existsSync()
      ? bootstrap.readAsStringSync()
      : null;

  final (String contentHash, int hashedCount) = _hashBuild(
    dir,
    indexText,
    bootstrapText,
  );
  final Map<String, Object?> existing = _readJsonObject(versionFile);

  DateTime builtAt;
  bool reused = false;
  final Object? previousAt = existing['builtAt'];
  final DateTime? parsedPrevious = previousAt is String
      ? DateTime.tryParse(previousAt)
      : null;
  if (!force &&
      existing['contentHash'] == contentHash &&
      parsedPrevious != null) {
    builtAt = parsedPrevious.toUtc();
    reused = true;
  } else {
    final DateTime t = (now ?? DateTime.now()).toUtc();
    builtAt = DateTime.utc(t.year, t.month, t.day, t.hour, t.minute, t.second);
  }

  final String buildId = formatBuildId(contentHash, builtAt);
  final BuildInfo info = BuildInfo(
    buildId: buildId,
    builtAt: builtAt,
    appVersion:
        appVersion ??
        _resolveAppVersion(dir, pubspecPath) ??
        _flutterVersion(existing),
    contentHash: contentHash,
  );

  final List<String> written = <String>[];
  final String stampedIndex;
  try {
    stampedIndex = stampIndexHtml(indexText, buildId);
  } on FormatException catch (e) {
    throw StampException('Cannot stamp index.html: ${e.message}');
  }
  if (stampedIndex != indexText) {
    index.writeAsStringSync(stampedIndex);
    written.add('index.html');
  }
  if (bootstrapText != null) {
    final String stamped = stampBootstrapJs(bootstrapText, buildId);
    if (stamped != bootstrapText) {
      bootstrap.writeAsStringSync(stamped);
      written.add('flutter_bootstrap.js');
    }
  }

  final Map<String, Object?> merged = <String, Object?>{
    ...existing,
    ...info.toJson(),
  };
  final String versionJson =
      '${const JsonEncoder.withIndent('  ').convert(merged)}\n';
  if (!versionFile.existsSync() ||
      versionFile.readAsStringSync() != versionJson) {
    versionFile.writeAsStringSync(versionJson);
    written.add('version.json');
  }

  return StampResult(
    info: info,
    writtenFiles: written,
    reusedBuiltAt: reused,
    hashedFileCount: hashedCount,
  );
}

(String, int) _hashBuild(
  Directory dir,
  String indexText,
  String? bootstrapText,
) {
  final List<File> files =
      dir
          .listSync(recursive: true, followLinks: false)
          .whereType<File>()
          .where(
            (File f) => p.relative(f.path, from: dir.path) != 'version.json',
          )
          .toList()
        ..sort((File a, File b) => _rel(dir, a).compareTo(_rel(dir, b)));

  final _DigestSink sink = _DigestSink();
  final ByteConversionSink hasher = sha256.startChunkedConversion(sink);
  for (final File f in files) {
    final String rel = _rel(dir, f);
    final List<int> bytes;
    if (rel == 'index.html') {
      bytes = utf8.encode(unstampIndexHtml(indexText));
    } else if (rel == 'flutter_bootstrap.js' && bootstrapText != null) {
      bytes = utf8.encode(removeCacheBust(bootstrapText));
    } else {
      bytes = f.readAsBytesSync();
    }
    hasher
      ..add(utf8.encode(rel))
      ..add(const <int>[0])
      ..add(utf8.encode('${bytes.length}'))
      ..add(const <int>[0])
      ..add(bytes);
  }
  hasher.close();
  return (sink.value!.toString(), files.length);
}

String _rel(Directory dir, File f) =>
    p.posix.joinAll(p.split(p.relative(f.path, from: dir.path)));

Map<String, Object?> _readJsonObject(File file) {
  if (!file.existsSync()) return <String, Object?>{};
  try {
    final Object? decoded = jsonDecode(file.readAsStringSync());
    if (decoded is Map) return decoded.cast<String, Object?>();
  } on FormatException {
    // A corrupt version.json is replaced.
  }
  return <String, Object?>{};
}

String? _resolveAppVersion(Directory buildDir, String? pubspecPath) {
  if (pubspecPath != null) {
    final File f = File(pubspecPath);
    if (!f.existsSync()) {
      throw StampException('Pubspec "$pubspecPath" does not exist.');
    }
    return _versionFromPubspec(f);
  }
  final List<File> candidates = <File>[
    File(p.join(buildDir.absolute.path, '..', '..', 'pubspec.yaml')),
    File('pubspec.yaml'),
  ];
  for (final File f in candidates) {
    if (f.existsSync()) {
      final String? v = _versionFromPubspec(f);
      if (v != null) return v;
    }
  }
  return null;
}

String? _versionFromPubspec(File f) {
  try {
    final Object? doc = loadYaml(f.readAsStringSync());
    if (doc is YamlMap) {
      final Object? v = doc['version'];
      if (v != null) return v.toString();
    }
    return null;
  } on YamlException catch (e) {
    throw StampException('Cannot parse ${f.path}: ${e.message}');
  }
}

String? _flutterVersion(Map<String, Object?> existing) {
  final Object? v = existing['version'];
  if (v is! String || v.isEmpty) return null;
  final Object? b = existing['build_number'];
  return (b is String && b.isNotEmpty) ? '$v+$b' : v;
}
