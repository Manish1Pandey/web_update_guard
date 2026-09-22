import '../build_info.dart';

/// Entry-point file names whose references the stamp CLI cache-busts: the
/// dart2js bundle, the loader scripts and the dart2wasm module + its JS
/// support runtime.
const List<String> cacheBustedScripts = <String>[
  'main.dart.js',
  'flutter_bootstrap.js',
  'flutter.js',
  'main.dart.wasm',
  'main.dart.mjs',
];

/// Matches a reference to one of [cacheBustedScripts], optionally with a
/// query string. The name must be preceded by a quote, slash, `=`, `(` or
/// whitespace and followed by a quote, whitespace, `)`, `#`, `>` or the end,
/// so `main.dart.js_1.part.js`, `flutter.js.map` or `my_flutter.js` never
/// match.
final RegExp _scriptRef = RegExp(
  r'''(?<=^|["'`\s/=(])'''
  r'''(main\.dart\.js|main\.dart\.mjs|main\.dart\.wasm|flutter_bootstrap\.js|flutter\.js)'''
  r'''(\?[^"'`\s<>)#]*)?(?=["'`\s)#>]|$)''',
  multiLine: true,
);

final RegExp _metaTag = RegExp(
  '[ \\t]*<meta\\s+name=["\']${RegExp.escape(buildIdMetaName)}["\'][^>]*>'
  '[ \\t]*(\\r?\\n)?',
  caseSensitive: false,
);

final RegExp _headClose = RegExp('</head\\s*>', caseSensitive: false);

List<String> _queryWithoutBust(String? query) {
  if (query == null || query.length <= 1) return <String>[];
  return query
      .substring(1)
      .split('&')
      .where(
        (String p) =>
            p.isNotEmpty &&
            p != cacheBustParam &&
            !p.startsWith('$cacheBustParam=') &&
            !p.startsWith('amp;$cacheBustParam='),
      )
      .toList();
}

/// Appends `?v=<buildId>` to every script reference in [source], replacing a
/// previous `v` parameter and keeping any other parameters.
String cacheBustScripts(String source, String buildId) {
  return source.replaceAllMapped(_scriptRef, (Match m) {
    final List<String> params = _queryWithoutBust(m.group(2))
      ..add('$cacheBustParam=$buildId');
    return '${m.group(1)}?${params.join('&')}';
  });
}

/// Removes the `v` parameter added by [cacheBustScripts].
String removeCacheBust(String source) {
  return source.replaceAllMapped(_scriptRef, (Match m) {
    final List<String> params = _queryWithoutBust(m.group(2));
    return params.isEmpty ? m.group(1)! : '${m.group(1)}?${params.join('&')}';
  });
}

/// Removes every build-ID meta tag (and its line) from [html].
String removeBuildIdMeta(String html) => html.replaceAll(_metaTag, '');

/// Inserts the build-ID meta tag just before `</head>`, removing any previous
/// one first.
///
/// Throws a [FormatException] when [html] has no `</head>`.
String injectBuildIdMeta(String html, String buildId) {
  final String clean = removeBuildIdMeta(html);
  final Match? head = _headClose.firstMatch(clean);
  if (head == null) {
    throw const FormatException('index.html has no </head> tag');
  }
  final String tag =
      '<meta name="$buildIdMetaName" content="${_escapeAttr(buildId)}">';
  final int lineStart = head.start == 0
      ? 0
      : clean.lastIndexOf('\n', head.start - 1) + 1;
  final String before = clean.substring(lineStart, head.start);
  if (before.trim().isEmpty) {
    // `</head>` starts its own line: add the tag as a line of its own.
    final String newline = clean.contains('\r\n') ? '\r\n' : '\n';
    return '${clean.substring(0, lineStart)}$before  $tag$newline'
        '${clean.substring(lineStart)}';
  }
  return '${clean.substring(0, head.start)}$tag${clean.substring(head.start)}';
}

String _escapeAttr(String v) => v
    .replaceAll('&', '&amp;')
    .replaceAll('"', '&quot;')
    .replaceAll('<', '&lt;')
    .replaceAll('>', '&gt;');

final RegExp _htmlComment = RegExp(r'<!--[\s\S]*?-->');

/// Applies [transform] to the parts of [html] outside `<!-- comments -->`,
/// so explanatory comments that mention script names stay untouched.
String _outsideComments(String html, String Function(String) transform) {
  final StringBuffer out = StringBuffer();
  int last = 0;
  for (final Match m in _htmlComment.allMatches(html)) {
    out
      ..write(transform(html.substring(last, m.start)))
      ..write(m.group(0));
    last = m.end;
  }
  out.write(transform(html.substring(last)));
  return out.toString();
}

/// Returns [html] (an `index.html`) with the meta tag and cache-busting
/// removed — the form used for content hashing.
String unstampIndexHtml(String html) =>
    _outsideComments(removeBuildIdMeta(html), removeCacheBust);

/// Returns [html] (an `index.html`) stamped with [buildId]: meta tag injected
/// and script references outside HTML comments cache-busted. Idempotent.
String stampIndexHtml(String html, String buildId) => injectBuildIdMeta(
  _outsideComments(
    unstampIndexHtml(html),
    (String part) => cacheBustScripts(part, buildId),
  ),
  buildId,
);

/// Returns [js] (a `flutter_bootstrap.js`) with script references
/// cache-busted with [buildId]. Idempotent.
String stampBootstrapJs(String js, String buildId) =>
    cacheBustScripts(removeCacheBust(js), buildId);
