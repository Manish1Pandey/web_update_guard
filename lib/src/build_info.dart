import 'package:meta/meta.dart';

/// The `name` of the `<meta>` tag the stamp CLI injects into `index.html`.
///
/// Its `content` is the build ID of the bundle that page belongs to, which is
/// how the running app knows which build it is.
const String buildIdMetaName = 'web-update-guard-build-id';

/// The query parameter the stamp CLI appends to cache-busted script URLs.
const String cacheBustParam = 'v';

/// The query parameter [WebUpdateGuard] appends to `version.json` requests so
/// that no intermediate cache can answer them.
const String versionFetchNonceParam = '_wug';

final RegExp _buildIdPattern = RegExp(r'^([0-9a-f]{16})-(\d{8}T\d{6}Z)$');

/// Formats a build ID from a hex [contentHash] and the build time.
///
/// The result is `<first 16 hex chars of the hash>-<yyyyMMddTHHmmssZ>`, for
/// example `3f9a0c1b2d4e5f60-20260922T101500Z`. It is URL-safe and sortable by
/// time within the same hash.
String formatBuildId(String contentHash, DateTime builtAt) {
  final String hash = contentHash.toLowerCase();
  if (hash.length < 16 || !RegExp(r'^[0-9a-f]+$').hasMatch(hash)) {
    throw ArgumentError.value(
      contentHash,
      'contentHash',
      'must be at least 16 lowercase hex characters',
    );
  }
  final DateTime t = builtAt.toUtc();
  String two(int v) => v.toString().padLeft(2, '0');
  final String stamp =
      '${t.year.toString().padLeft(4, '0')}${two(t.month)}${two(t.day)}'
      'T${two(t.hour)}${two(t.minute)}${two(t.second)}Z';
  return '${hash.substring(0, 16)}-$stamp';
}

/// Returns `true` when [buildId] has the format produced by [formatBuildId].
bool isStampedBuildId(String buildId) => _buildIdPattern.hasMatch(buildId);

/// Extracts the UTC build time embedded in a build ID made by
/// [formatBuildId], or `null` when [buildId] has another format.
DateTime? buildTimeFromId(String buildId) {
  final RegExpMatch? m = _buildIdPattern.firstMatch(buildId);
  if (m == null) return null;
  final String s = m.group(2)!;
  return DateTime.utc(
    int.parse(s.substring(0, 4)),
    int.parse(s.substring(4, 6)),
    int.parse(s.substring(6, 8)),
    int.parse(s.substring(9, 11)),
    int.parse(s.substring(11, 13)),
    int.parse(s.substring(13, 15)),
  );
}

/// Metadata about one deployed build, as written to `version.json` by the
/// stamp CLI.
@immutable
class BuildInfo {
  /// Creates build metadata.
  const BuildInfo({
    required this.buildId,
    this.builtAt,
    this.appVersion,
    this.contentHash,
  });

  /// Parses the `version.json` document written by the stamp CLI.
  ///
  /// Throws a [FormatException] when `buildId` is missing or not a non-empty
  /// string. Other fields are optional and ignored when malformed.
  factory BuildInfo.fromJson(Object? json) {
    if (json is! Map) {
      throw const FormatException('version.json must be a JSON object');
    }
    final Object? id = json['buildId'];
    if (id is! String || id.trim().isEmpty) {
      throw const FormatException(
        'version.json has no "buildId" — was the build stamped with '
        '`dart run web_update_guard stamp build/web`?',
      );
    }
    final Object? builtAt = json['builtAt'];
    final Object? appVersion = json['appVersion'];
    final Object? hash = json['contentHash'];
    return BuildInfo(
      buildId: id.trim(),
      builtAt: builtAt is String ? DateTime.tryParse(builtAt)?.toUtc() : null,
      appVersion: appVersion is String ? appVersion : null,
      contentHash: hash is String ? hash : null,
    );
  }

  /// The unique ID of the build.
  final String buildId;

  /// When the build was stamped (UTC), if known.
  final DateTime? builtAt;

  /// The `version:` of the app's pubspec at build time, if known.
  final String? appVersion;

  /// The full SHA-256 content hash of the build output, if known.
  final String? contentHash;

  /// The effective build time: [builtAt], or the time embedded in [buildId].
  DateTime? get effectiveBuiltAt => builtAt ?? buildTimeFromId(buildId);

  /// Serialises the fields this package owns in `version.json`.
  Map<String, Object?> toJson() => <String, Object?>{
    'buildId': buildId,
    'builtAt': builtAt?.toUtc().toIso8601String(),
    'appVersion': appVersion,
    'contentHash': contentHash,
  };

  @override
  bool operator ==(Object other) =>
      other is BuildInfo &&
      other.buildId == buildId &&
      other.builtAt == builtAt &&
      other.appVersion == appVersion &&
      other.contentHash == contentHash;

  @override
  int get hashCode => Object.hash(buildId, builtAt, appVersion, contentHash);

  @override
  String toString() =>
      'BuildInfo(buildId: $buildId, builtAt: $builtAt, '
      'appVersion: $appVersion)';
}

/// How a remote build is compared with the running one.
enum ComparisonPolicy {
  /// Any build ID different from the running one is an update. Correct for
  /// rollbacks too, and the default.
  anyDifference,

  /// Only a build that is strictly newer (by build time) is an update. Use
  /// this when several CDN edges may briefly serve an older `version.json`.
  /// Falls back to [anyDifference] when either time is unknown.
  newerOnly,
}

/// Decides whether [remote] should be treated as an update for a tab that is
/// running [runningBuildId].
///
/// Returns `false` when [runningBuildId] is `null` (an unstamped build cannot
/// be compared) or equal to the remote build ID.
bool isUpdateAvailable({
  required String? runningBuildId,
  required BuildInfo remote,
  ComparisonPolicy policy = ComparisonPolicy.anyDifference,
}) {
  if (runningBuildId == null || runningBuildId.isEmpty) return false;
  if (remote.buildId == runningBuildId) return false;
  switch (policy) {
    case ComparisonPolicy.anyDifference:
      return true;
    case ComparisonPolicy.newerOnly:
      final DateTime? runningAt = buildTimeFromId(runningBuildId);
      final DateTime? remoteAt = remote.effectiveBuiltAt;
      if (runningAt == null || remoteAt == null) return true;
      // Build IDs carry second precision; compare at that precision.
      final int r = runningAt.millisecondsSinceEpoch ~/ 1000;
      final int n = remoteAt.millisecondsSinceEpoch ~/ 1000;
      return n >= r;
  }
}

/// Returns [url] with a unique [nonce] query parameter
/// ([versionFetchNonceParam]) added, preserving any existing parameters and
/// fragment. Works for relative and absolute URLs.
String cacheBustedUrl(String url, Object nonce) {
  final Uri uri = Uri.parse(url);
  final Map<String, List<String>> params = <String, List<String>>{
    for (final MapEntry<String, List<String>> e
        in uri.queryParametersAll.entries)
      if (e.key != versionFetchNonceParam) e.key: e.value,
    versionFetchNonceParam: <String>['$nonce'],
  };
  return uri.replace(queryParameters: params).toString();
}
