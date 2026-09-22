import 'package:flutter/material.dart';
import 'package:web_update_guard/web_update_guard.dart';

/// Demo of web_update_guard.
///
/// 1. `flutter build web`
/// 2. `dart run web_update_guard stamp build/web`
/// 3. Serve build/web, open it, then rebuild + restamp: the running tab
///    detects the new deploy within the poll interval (or on refocus).
void main() => runApp(const DemoApp());

/// Root widget: owns the [WebUpdateGuard] and recreates it when the settings
/// change.
class DemoApp extends StatefulWidget {
  /// Creates the demo.
  const DemoApp({super.key});

  @override
  State<DemoApp> createState() => _DemoAppState();
}

class _DemoAppState extends State<DemoApp> {
  // `?autoReload=whenIdle` (or `immediately`) in the URL preselects a policy.
  AutoReloadPolicy _autoReload = AutoReloadPolicy.values.firstWhere(
    (AutoReloadPolicy p) => p.name == Uri.base.queryParameters['autoReload'],
    orElse: () => AutoReloadPolicy.never,
  );
  ComparisonPolicy _comparison = ComparisonPolicy.anyDifference;
  UpdatePresentation _presentation = UpdatePresentation.snackBar;
  bool _keepAppCaches = false;
  late WebUpdateGuard _guard;

  @override
  void initState() {
    super.initState();
    _guard = _createGuard();
  }

  WebUpdateGuard _createGuard() {
    final WebUpdateGuard guard = WebUpdateGuard(
      pollInterval: const Duration(seconds: 30),
      minCheckGap: const Duration(seconds: 5),
      autoReload: _autoReload,
      idleTimeout: const Duration(seconds: 20),
      comparison: _comparison,
      applyOptions: ApplyUpdateOptions(
        // Keep caches whose name starts with "app-" when asked to.
        cacheNameFilter: _keepAppCaches
            ? (String name) => !name.startsWith('app-')
            : null,
      ),
    );
    // Logged so the behaviour can be followed in the browser console.
    guard.statusStream.listen(
      (UpdateStatus s) => debugPrint('[web_update_guard] $s'),
    );
    debugPrint('[web_update_guard] initial ${guard.status}');
    return guard..start();
  }

  void _reconfigure(VoidCallback change) {
    setState(() {
      change();
      _guard.dispose();
      _guard = _createGuard();
    });
  }

  @override
  void dispose() {
    _guard.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'web_update_guard demo',
      theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
      // WebUpdateListener sits below the MaterialApp's ScaffoldMessenger.
      builder: (BuildContext context, Widget? child) => WebUpdateListener(
        key: ValueKey<Object>(_guard),
        checker: _guard,
        presentation: _presentation,
        child: child!,
      ),
      home: DemoHome(
        guard: _guard,
        autoReload: _autoReload,
        comparison: _comparison,
        presentation: _presentation,
        keepAppCaches: _keepAppCaches,
        onAutoReload: (AutoReloadPolicy p) =>
            _reconfigure(() => _autoReload = p),
        onComparison: (ComparisonPolicy p) =>
            _reconfigure(() => _comparison = p),
        onPresentation: (UpdatePresentation p) =>
            setState(() => _presentation = p),
        onKeepAppCaches: (bool v) => _reconfigure(() => _keepAppCaches = v),
      ),
    );
  }
}

/// The demo page: an inline [UpdateBanner], live status and settings.
class DemoHome extends StatelessWidget {
  /// Creates the page.
  const DemoHome({
    super.key,
    required this.guard,
    required this.autoReload,
    required this.comparison,
    required this.presentation,
    required this.keepAppCaches,
    required this.onAutoReload,
    required this.onComparison,
    required this.onPresentation,
    required this.onKeepAppCaches,
  });

  /// The active guard.
  final WebUpdateGuard guard;

  /// Current auto-reload policy.
  final AutoReloadPolicy autoReload;

  /// Current comparison policy.
  final ComparisonPolicy comparison;

  /// Current listener presentation.
  final UpdatePresentation presentation;

  /// Whether caches named `app-*` survive [WebUpdateGuard.applyUpdate].
  final bool keepAppCaches;

  /// Changes the auto-reload policy.
  final ValueChanged<AutoReloadPolicy> onAutoReload;

  /// Changes the comparison policy.
  final ValueChanged<ComparisonPolicy> onComparison;

  /// Changes the listener presentation.
  final ValueChanged<UpdatePresentation> onPresentation;

  /// Toggles keeping `app-*` caches.
  final ValueChanged<bool> onKeepAppCaches;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('web_update_guard')),
      body: UpdateBanner(
        checker: guard,
        message: 'Inline UpdateBanner: a new build is deployed.',
        child: ListView(
          padding: const EdgeInsets.all(16),
          children: <Widget>[
            StreamBuilder<UpdateStatus>(
              stream: guard.statusStream,
              initialData: guard.status,
              builder: (BuildContext context, AsyncSnapshot<UpdateStatus> s) =>
                  _StatusCard(status: s.data!),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: <Widget>[
                FilledButton.icon(
                  onPressed: guard.checkNow,
                  icon: const Icon(Icons.refresh),
                  label: const Text('Check now'),
                ),
                OutlinedButton.icon(
                  onPressed: guard.isSupported ? guard.applyUpdate : null,
                  icon: const Icon(Icons.cleaning_services_outlined),
                  label: const Text('Purge caches & reload'),
                ),
              ],
            ),
            const SizedBox(height: 24),
            Text('Settings', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            _Choice<AutoReloadPolicy>(
              label: 'Auto-reload',
              value: autoReload,
              values: AutoReloadPolicy.values,
              onChanged: onAutoReload,
            ),
            _Choice<ComparisonPolicy>(
              label: 'Comparison',
              value: comparison,
              values: ComparisonPolicy.values,
              onChanged: onComparison,
            ),
            _Choice<UpdatePresentation>(
              label: 'Listener style',
              value: presentation,
              values: UpdatePresentation.values,
              onChanged: onPresentation,
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Keep caches named "app-*" when purging'),
              value: keepAppCaches,
              onChanged: onKeepAppCaches,
            ),
          ],
        ),
      ),
    );
  }
}

class _StatusCard extends StatelessWidget {
  const _StatusCard({required this.status});

  final UpdateStatus status;

  @override
  Widget build(BuildContext context) {
    final BuildInfo? latest = status.latest;
    final List<(String, String)> rows = <(String, String)>[
      ('State', status.state.name + (status.checking ? ' (checking…)' : '')),
      ('Running build', status.runningBuildId ?? '—'),
      ('Server build', latest?.buildId ?? '—'),
      ('Server app version', latest?.appVersion ?? '—'),
      ('Server built at', latest?.builtAt?.toIso8601String() ?? '—'),
      ('Last check', status.checkedAt?.toIso8601String() ?? '—'),
      if (status.error != null) ('Last error', '${status.error}'),
    ];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            for (final (String k, String v) in rows)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 2),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    SizedBox(width: 150, child: Text(k)),
                    Expanded(child: SelectableText(v)),
                  ],
                ),
              ),
            if (status.state == UpdateState.unsupported)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text(
                  'Not running on the web: the guard is a no-op here.',
                ),
              ),
            if (status.state == UpdateState.notStamped)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text(
                  'index.html has no build-ID meta tag. Run '
                  '`dart run web_update_guard stamp build/web`.',
                ),
              ),
          ],
        ),
      ),
    );
  }
}

class _Choice<T extends Enum> extends StatelessWidget {
  const _Choice({
    required this.label,
    required this.value,
    required this.values,
    required this.onChanged,
  });

  final String label;
  final T value;
  final List<T> values;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: <Widget>[
          SizedBox(width: 120, child: Text(label)),
          Expanded(
            child: SegmentedButton<T>(
              segments: <ButtonSegment<T>>[
                for (final T v in values)
                  ButtonSegment<T>(value: v, label: Text(v.name)),
              ],
              selected: <T>{value},
              onSelectionChanged: (Set<T> s) => onChanged(s.single),
            ),
          ),
        ],
      ),
    );
  }
}
