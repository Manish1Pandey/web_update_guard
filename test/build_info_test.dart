import 'package:flutter_test/flutter_test.dart';
import 'package:web_update_guard/web_update_guard.dart';

void main() {
  const String hash =
      '3f9a0c1b2d4e5f60718293a4b5c6d7e8f90112233445566778899aabbccddeeff';

  group('build IDs', () {
    test('format and parse round-trip', () {
      final String id = formatBuildId(
        hash,
        DateTime.utc(2026, 9, 22, 10, 5, 9),
      );
      expect(id, '3f9a0c1b2d4e5f60-20260922T100509Z');
      expect(isStampedBuildId(id), isTrue);
      expect(buildTimeFromId(id), DateTime.utc(2026, 9, 22, 10, 5, 9));
    });

    test('local times are converted to UTC', () {
      final DateTime local = DateTime.utc(2026, 1, 2, 3, 4, 5).toLocal();
      expect(formatBuildId(hash, local), endsWith('-20260102T030405Z'));
    });

    test('rejects bad hashes and parses only stamped IDs', () {
      expect(
        () => formatBuildId('xyz', DateTime.utc(2026)),
        throwsArgumentError,
      );
      expect(buildTimeFromId('custom-build-7'), isNull);
      expect(isStampedBuildId('custom-build-7'), isFalse);
    });
  });

  group('BuildInfo.fromJson', () {
    test('parses all fields', () {
      final BuildInfo info = BuildInfo.fromJson(<String, Object?>{
        'buildId': ' abc ',
        'builtAt': '2026-09-22T10:00:00.000Z',
        'appVersion': '1.0.0+2',
        'contentHash': hash,
        'app_name': 'ignored',
      });
      expect(info.buildId, 'abc');
      expect(info.builtAt, DateTime.utc(2026, 9, 22, 10));
      expect(info.appVersion, '1.0.0+2');
      expect(info.contentHash, hash);
      expect(BuildInfo.fromJson(info.toJson()), info);
    });

    test('requires a buildId', () {
      expect(
        () => BuildInfo.fromJson(<String, Object?>{}),
        throwsFormatException,
      );
      expect(
        () => BuildInfo.fromJson(<String, Object?>{'buildId': ''}),
        throwsFormatException,
      );
      expect(() => BuildInfo.fromJson(<Object?>[]), throwsFormatException);
    });

    test('tolerates malformed optional fields', () {
      final BuildInfo info = BuildInfo.fromJson(<String, Object?>{
        'buildId': 'x',
        'builtAt': 'not a date',
        'appVersion': 3,
      });
      expect(info.builtAt, isNull);
      expect(info.appVersion, isNull);
    });
  });

  group('isUpdateAvailable', () {
    const String a = '0000000000000000-20260922T100000Z';
    const String b = '1111111111111111-20260922T110000Z';
    const String bSameSecond = '2222222222222222-20260922T100000Z';

    test('anyDifference: any other ID is an update, including rollbacks', () {
      expect(
        isUpdateAvailable(
          runningBuildId: a,
          remote: const BuildInfo(buildId: a),
        ),
        isFalse,
      );
      expect(
        isUpdateAvailable(
          runningBuildId: a,
          remote: const BuildInfo(buildId: b),
        ),
        isTrue,
      );
      expect(
        isUpdateAvailable(
          runningBuildId: b,
          remote: const BuildInfo(buildId: a),
        ),
        isTrue,
      );
    });

    test('unknown running build is never an update', () {
      expect(
        isUpdateAvailable(
          runningBuildId: null,
          remote: const BuildInfo(buildId: b),
        ),
        isFalse,
      );
      expect(
        isUpdateAvailable(
          runningBuildId: '',
          remote: const BuildInfo(buildId: b),
        ),
        isFalse,
      );
    });

    test('newerOnly compares build times', () {
      bool newerOnly(String running, BuildInfo remote) => isUpdateAvailable(
        runningBuildId: running,
        remote: remote,
        policy: ComparisonPolicy.newerOnly,
      );
      expect(newerOnly(a, const BuildInfo(buildId: b)), isTrue);
      expect(newerOnly(b, const BuildInfo(buildId: a)), isFalse);
      expect(newerOnly(a, const BuildInfo(buildId: bSameSecond)), isTrue);
      // builtAt in version.json takes precedence over the ID's timestamp.
      expect(
        newerOnly(b, BuildInfo(buildId: 'custom', builtAt: DateTime.utc(2027))),
        isTrue,
      );
      // Unknown times fall back to "any difference".
      expect(
        newerOnly('custom-1', const BuildInfo(buildId: 'custom-2')),
        isTrue,
      );
    });
  });

  group('cacheBustedUrl', () {
    test('adds the nonce to relative and absolute URLs', () {
      expect(cacheBustedUrl('version.json', 7), 'version.json?_wug=7');
      expect(
        cacheBustedUrl('https://x.dev/app/version.json?a=1#f', 7),
        'https://x.dev/app/version.json?a=1&_wug=7#f',
      );
    });

    test('replaces an existing nonce', () {
      expect(cacheBustedUrl('version.json?_wug=1', 2), 'version.json?_wug=2');
    });
  });

  test('UpdateStatus copyWith and equality', () {
    const UpdateStatus s = UpdateStatus(
      state: UpdateState.error,
      runningBuildId: 'a',
      error: 'boom',
    );
    expect(s.copyWith(checking: true).checking, isTrue);
    expect(s.copyWith(clearError: true).error, isNull);
    expect(s.copyWith(), s);
    expect(s.isUpdateAvailable, isFalse);
    expect(s.toString(), contains('error: boom'));
  });
}
