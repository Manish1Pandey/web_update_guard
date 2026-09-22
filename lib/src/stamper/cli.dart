import 'dart:io';

import 'package:args/args.dart';

import 'stamper.dart';

const String _usage = '''
web_update_guard — stamp a Flutter web build so stale caches cannot survive a
deploy.

Usage:
  dart run web_update_guard stamp [options] <build/web>

Run after `flutter build web`, before deploying. Writes version.json,
cache-busts main.dart.js / flutter_bootstrap.js / flutter.js with ?v=<buildId>
and injects <meta name="web-update-guard-build-id"> into index.html.
Safe to re-run: unchanged output is left byte-for-byte identical.
''';

ArgParser _stampParser() => ArgParser()
  ..addOption(
    'pubspec',
    help:
        'Pubspec to read `version:` from '
        '(default: <build>/../../pubspec.yaml, then ./pubspec.yaml).',
  )
  ..addOption('app-version', help: 'Override the appVersion written.')
  ..addFlag(
    'force',
    negatable: false,
    help: 'Issue a new build timestamp even if the content is unchanged.',
  )
  ..addFlag('quiet', abbr: 'q', negatable: false, help: 'Only print errors.')
  ..addFlag('help', abbr: 'h', negatable: false, help: 'Show this help.');

/// Runs the `web_update_guard` command line with [arguments], writing to
/// [out] and [err] (stdout/stderr by default), and returns the exit code:
/// `0` success, `64` usage error, `1` stamping failure.
int runCli(List<String> arguments, {StringSink? out, StringSink? err}) {
  final StringSink o = out ?? stdout;
  final StringSink e = err ?? stderr;
  final ArgParser stamp = _stampParser();
  final ArgParser parser = ArgParser()
    ..addFlag('help', abbr: 'h', negatable: false, help: 'Show this help.')
    ..addCommand('stamp', stamp);

  final ArgResults args;
  try {
    args = parser.parse(arguments);
  } on FormatException catch (ex) {
    e
      ..writeln(ex.message)
      ..writeln()
      ..write(_usage)
      ..writeln(stamp.usage);
    return 64;
  }
  final ArgResults? cmd = args.command;
  if (args.flag('help') || cmd == null) {
    (cmd == null && !args.flag('help') ? e : o)
      ..write(_usage)
      ..writeln()
      ..writeln('Options for `stamp`:')
      ..writeln(stamp.usage);
    return args.flag('help') ? 0 : 64;
  }
  if (cmd.flag('help')) {
    o
      ..write(_usage)
      ..writeln()
      ..writeln(stamp.usage);
    return 0;
  }
  if (cmd.rest.length != 1) {
    e
      ..writeln('Expected exactly one build directory, e.g. `stamp build/web`.')
      ..writeln(stamp.usage);
    return 64;
  }

  final String dir = cmd.rest.single;
  try {
    final StampResult r = stampBuildDirectory(
      dir,
      pubspecPath: cmd.option('pubspec'),
      appVersion: cmd.option('app-version'),
      force: cmd.flag('force'),
    );
    if (!cmd.flag('quiet')) {
      o
        ..writeln('Stamped $dir')
        ..writeln('  buildId     ${r.info.buildId}')
        ..writeln('  builtAt     ${r.info.builtAt?.toIso8601String()}')
        ..writeln('  appVersion  ${r.info.appVersion ?? '(unknown)'}')
        ..writeln('  files hashed ${r.hashedFileCount}')
        ..writeln(
          r.writtenFiles.isEmpty
              ? '  unchanged (already stamped for this content)'
              : '  updated     ${r.writtenFiles.join(', ')}',
        );
    }
    return 0;
  } on StampException catch (ex) {
    e.writeln('error: ${ex.message}');
    return 1;
  } on FileSystemException catch (ex) {
    e.writeln('error: ${ex.message}: ${ex.path}');
    return 1;
  }
}
