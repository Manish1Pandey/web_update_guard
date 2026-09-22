import 'dart:async';

import 'package:flutter/material.dart';

import '../update_status.dart';

/// Builds the widget [UpdateBanner] shows while an update is available.
///
/// Call [onReload] to apply the update and [onDismiss] to hide the banner
/// until a different build is deployed.
typedef UpdateBannerBuilder =
    Widget Function(
      BuildContext context,
      UpdateStatus status,
      VoidCallback onReload,
      VoidCallback onDismiss,
    );

/// An inline banner that appears above [child] while a new build is
/// available.
///
/// By default it renders a [MaterialBanner] with "Later" and "Reload"
/// actions; pass [builder] to render anything else. Dismissing hides it until
/// the server reports a different build ID.
///
/// When [child] is given, the banner and child are laid out in a [Column]
/// with the child expanded, so give [UpdateBanner] bounded height (e.g. use
/// it as a `Scaffold.body`). Without a child it sizes to the banner, or to
/// nothing when no update is available.
class UpdateBanner extends StatefulWidget {
  /// Creates an update banner driven by [checker].
  const UpdateBanner({
    super.key,
    required this.checker,
    this.child,
    this.builder,
    this.message = 'A new version of this app is available.',
    this.reloadLabel = 'Reload',
    this.dismissLabel = 'Later',
    this.dismissible = true,
    this.leading = const Icon(Icons.system_update_alt),
  });

  /// The source of update status, typically a [WebUpdateGuard].
  final UpdateChecker checker;

  /// Content shown below the banner.
  final Widget? child;

  /// Custom banner builder; replaces the default [MaterialBanner].
  final UpdateBannerBuilder? builder;

  /// Text of the default banner.
  final String message;

  /// Label of the default reload action.
  final String reloadLabel;

  /// Label of the default dismiss action.
  final String dismissLabel;

  /// Whether the default banner shows a dismiss action.
  final bool dismissible;

  /// Leading widget of the default banner.
  final Widget? leading;

  @override
  State<UpdateBanner> createState() => _UpdateBannerState();
}

class _UpdateBannerState extends State<UpdateBanner> {
  StreamSubscription<UpdateStatus>? _sub;
  late UpdateStatus _status;
  String? _dismissedBuildId;

  @override
  void initState() {
    super.initState();
    _subscribe();
  }

  @override
  void didUpdateWidget(UpdateBanner oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.checker, widget.checker)) {
      _sub?.cancel();
      _subscribe();
    }
  }

  void _subscribe() {
    _status = widget.checker.status;
    _sub = widget.checker.statusStream.listen((UpdateStatus s) {
      if (mounted) setState(() => _status = s);
    });
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  bool get _visible {
    final bool relevant =
        _status.state == UpdateState.updateAvailable ||
        _status.state == UpdateState.applying;
    return relevant &&
        _status.latest != null &&
        _status.latest!.buildId != _dismissedBuildId;
  }

  void _reload() {
    unawaited(widget.checker.applyUpdate());
  }

  void _dismiss() {
    setState(() => _dismissedBuildId = _status.latest?.buildId);
  }

  Widget _defaultBanner(BuildContext context) {
    final bool applying = _status.state == UpdateState.applying;
    return MaterialBanner(
      content: Text(widget.message),
      leading: widget.leading,
      actions: <Widget>[
        if (widget.dismissible)
          TextButton(
            onPressed: applying ? null : _dismiss,
            child: Text(widget.dismissLabel),
          ),
        TextButton(
          onPressed: applying ? null : _reload,
          child: Text(widget.reloadLabel),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final Widget? banner = _visible
        ? (widget.builder?.call(context, _status, _reload, _dismiss) ??
              _defaultBanner(context))
        : null;
    final Widget? child = widget.child;
    if (child == null) return banner ?? const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        ?banner,
        Expanded(child: child),
      ],
    );
  }
}
