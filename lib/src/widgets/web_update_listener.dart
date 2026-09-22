import 'dart:async';

import 'package:flutter/material.dart';

import '../update_status.dart';

/// How [WebUpdateListener] presents an available update.
enum UpdatePresentation {
  /// A persistent [SnackBar] with a reload action.
  snackBar,

  /// A [MaterialBanner] at the top of the nearest [Scaffold].
  materialBanner,
}

/// Builds the [SnackBar] shown by [WebUpdateListener].
typedef UpdateSnackBarBuilder =
    SnackBar Function(
      BuildContext context,
      UpdateStatus status,
      VoidCallback onReload,
    );

/// Builds the [MaterialBanner] shown by [WebUpdateListener].
typedef UpdateMaterialBannerBuilder =
    MaterialBanner Function(
      BuildContext context,
      UpdateStatus status,
      VoidCallback onReload,
      VoidCallback onDismiss,
    );

/// Called by [WebUpdateListener] once per newly detected build.
typedef UpdateAvailableCallback =
    void Function(BuildContext context, UpdateStatus status);

/// Listens to an [UpdateChecker] and announces each newly deployed build via
/// the nearest [ScaffoldMessenger].
///
/// Place it below `MaterialApp` — for example in `MaterialApp.builder` or
/// around a page's `Scaffold`. Each build ID is announced once; a later,
/// different build replaces the previous announcement.
class WebUpdateListener extends StatefulWidget {
  /// Creates a listener driven by [checker].
  const WebUpdateListener({
    super.key,
    required this.checker,
    required this.child,
    this.presentation = UpdatePresentation.snackBar,
    this.snackBarBuilder,
    this.materialBannerBuilder,
    this.onUpdateAvailable,
    this.message = 'A new version of this app is available.',
    this.reloadLabel = 'Reload',
    this.dismissLabel = 'Later',
    this.snackBarDuration = const Duration(days: 1),
    this.scaffoldMessengerKey,
  });

  /// The source of update status, typically a [WebUpdateGuard].
  final UpdateChecker checker;

  /// The subtree this listener wraps.
  final Widget child;

  /// Whether to use a [SnackBar] or a [MaterialBanner].
  final UpdatePresentation presentation;

  /// Custom snack bar; used when [presentation] is
  /// [UpdatePresentation.snackBar].
  final UpdateSnackBarBuilder? snackBarBuilder;

  /// Custom banner; used when [presentation] is
  /// [UpdatePresentation.materialBanner].
  final UpdateMaterialBannerBuilder? materialBannerBuilder;

  /// Replaces the built-in presentation entirely when set.
  final UpdateAvailableCallback? onUpdateAvailable;

  /// Text of the default snack bar / banner.
  final String message;

  /// Label of the default reload action.
  final String reloadLabel;

  /// Label of the default banner's dismiss action.
  final String dismissLabel;

  /// How long the default snack bar stays up. Long by default so users do not
  /// miss it.
  final Duration snackBarDuration;

  /// Messenger to use instead of looking one up from the context — needed
  /// when this widget sits above `MaterialApp` (pass the same key to
  /// `MaterialApp.scaffoldMessengerKey`).
  final GlobalKey<ScaffoldMessengerState>? scaffoldMessengerKey;

  @override
  State<WebUpdateListener> createState() => _WebUpdateListenerState();
}

class _WebUpdateListenerState extends State<WebUpdateListener> {
  StreamSubscription<UpdateStatus>? _sub;
  String? _announcedBuildId;
  ScaffoldMessengerState? _shownOn;
  UpdatePresentation? _shownAs;

  @override
  void initState() {
    super.initState();
    _subscribe();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _handle(widget.checker.status);
    });
  }

  @override
  void didUpdateWidget(WebUpdateListener oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.checker, widget.checker)) {
      _sub?.cancel();
      _subscribe();
    }
  }

  void _subscribe() {
    _sub = widget.checker.statusStream.listen(_handle);
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  void _reload() {
    unawaited(widget.checker.applyUpdate());
  }

  ScaffoldMessengerState? _messenger() {
    final ScaffoldMessengerState? m =
        widget.scaffoldMessengerKey?.currentState ??
        ScaffoldMessenger.maybeOf(context);
    if (m == null) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: FlutterError(
            'WebUpdateListener could not find a ScaffoldMessenger.\n'
            'Place it below MaterialApp (e.g. in MaterialApp.builder) or pass '
            'scaffoldMessengerKey.',
          ),
          library: 'web_update_guard',
        ),
      );
    }
    return m;
  }

  void _hideCurrent() {
    final ScaffoldMessengerState? m = _shownOn;
    if (m == null || !m.mounted) return;
    switch (_shownAs) {
      case UpdatePresentation.snackBar:
        m.hideCurrentSnackBar();
      case UpdatePresentation.materialBanner:
        m.hideCurrentMaterialBanner();
      case null:
        break;
    }
    _shownOn = null;
    _shownAs = null;
  }

  void _handle(UpdateStatus status) {
    if (!mounted || !status.isUpdateAvailable) return;
    final String? id = status.latest?.buildId;
    if (id == null || id == _announcedBuildId) return;
    _announcedBuildId = id;

    final UpdateAvailableCallback? custom = widget.onUpdateAvailable;
    if (custom != null) {
      custom(context, status);
      return;
    }
    final ScaffoldMessengerState? messenger = _messenger();
    if (messenger == null) return;
    _hideCurrent();
    switch (widget.presentation) {
      case UpdatePresentation.snackBar:
        messenger.showSnackBar(
          widget.snackBarBuilder?.call(context, status, _reload) ??
              SnackBar(
                content: Text(widget.message),
                duration: widget.snackBarDuration,
                action: SnackBarAction(
                  label: widget.reloadLabel,
                  onPressed: _reload,
                ),
              ),
        );
      case UpdatePresentation.materialBanner:
        void dismiss() => messenger.hideCurrentMaterialBanner();
        messenger.showMaterialBanner(
          widget.materialBannerBuilder?.call(
                context,
                status,
                _reload,
                dismiss,
              ) ??
              MaterialBanner(
                content: Text(widget.message),
                leading: const Icon(Icons.system_update_alt),
                actions: <Widget>[
                  TextButton(
                    onPressed: dismiss,
                    child: Text(widget.dismissLabel),
                  ),
                  TextButton(
                    onPressed: _reload,
                    child: Text(widget.reloadLabel),
                  ),
                ],
              ),
        );
    }
    _shownOn = messenger;
    _shownAs = widget.presentation;
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
