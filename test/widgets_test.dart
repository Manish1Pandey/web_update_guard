import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:web_update_guard/web_update_guard.dart';

const String running = '0000000000000000-20260922T100000Z';

/// A hand-driven [UpdateChecker].
class FakeChecker implements UpdateChecker {
  final StreamController<UpdateStatus> _controller =
      StreamController<UpdateStatus>.broadcast(sync: true);
  UpdateStatus _status = const UpdateStatus(
    state: UpdateState.upToDate,
    runningBuildId: running,
  );
  int applyCalls = 0;

  @override
  UpdateStatus get status => _status;

  @override
  Stream<UpdateStatus> get statusStream => _controller.stream;

  void emit(UpdateStatus s) {
    _status = s;
    _controller.add(s);
  }

  void announce(String buildId) => emit(
    UpdateStatus(
      state: UpdateState.updateAvailable,
      runningBuildId: running,
      latest: BuildInfo(buildId: buildId, appVersion: '2.0.0'),
    ),
  );

  @override
  Future<UpdateStatus> checkNow() async => _status;

  @override
  Future<void> applyUpdate() async {
    applyCalls++;
    emit(_status.copyWith(state: UpdateState.applying));
  }
}

Widget app(Widget home) => MaterialApp(home: home);

void main() {
  group('UpdateBanner', () {
    testWidgets('hidden until an update, then reload applies it', (
      WidgetTester tester,
    ) async {
      final FakeChecker checker = FakeChecker();
      await tester.pumpWidget(
        app(
          Scaffold(
            body: UpdateBanner(
              checker: checker,
              child: const Center(child: Text('content')),
            ),
          ),
        ),
      );
      expect(find.byType(MaterialBanner), findsNothing);
      expect(find.text('content'), findsOneWidget);

      checker.announce('b1');
      await tester.pump();
      expect(find.byType(MaterialBanner), findsOneWidget);
      expect(
        find.text('A new version of this app is available.'),
        findsOneWidget,
      );

      await tester.tap(find.text('Reload'));
      await tester.pump();
      expect(checker.applyCalls, 1);
      // While applying, the banner stays but its buttons are disabled.
      final TextButton reload = tester.widget<TextButton>(
        find.widgetWithText(TextButton, 'Reload'),
      );
      expect(reload.onPressed, isNull);
    });

    testWidgets('dismiss hides it until a different build arrives', (
      WidgetTester tester,
    ) async {
      final FakeChecker checker = FakeChecker()..announce('b1');
      await tester.pumpWidget(
        app(Scaffold(body: UpdateBanner(checker: checker))),
      );
      expect(find.byType(MaterialBanner), findsOneWidget, reason: 'initial');

      await tester.tap(find.text('Later'));
      await tester.pump();
      expect(find.byType(MaterialBanner), findsNothing);

      checker.announce('b1');
      await tester.pump();
      expect(find.byType(MaterialBanner), findsNothing, reason: 'same build');

      checker.announce('b2');
      await tester.pump();
      expect(find.byType(MaterialBanner), findsOneWidget);
    });

    testWidgets('custom builder and labels', (WidgetTester tester) async {
      final FakeChecker checker = FakeChecker();
      await tester.pumpWidget(
        app(
          Scaffold(
            body: UpdateBanner(
              checker: checker,
              builder:
                  (
                    _,
                    UpdateStatus s,
                    VoidCallback reload,
                    VoidCallback dismiss,
                  ) => ElevatedButton(
                    onPressed: reload,
                    child: Text('Get ${s.latest!.appVersion}'),
                  ),
            ),
          ),
        ),
      );
      checker.announce('b1');
      await tester.pump();
      expect(find.byType(MaterialBanner), findsNothing);
      await tester.tap(find.text('Get 2.0.0'));
      expect(checker.applyCalls, 1);
    });

    testWidgets('non-dismissible default banner has no Later action', (
      WidgetTester tester,
    ) async {
      final FakeChecker checker = FakeChecker()..announce('b1');
      await tester.pumpWidget(
        app(
          Scaffold(
            body: UpdateBanner(
              checker: checker,
              dismissible: false,
              message: 'Nieuwe versie',
              reloadLabel: 'Herladen',
            ),
          ),
        ),
      );
      expect(find.text('Nieuwe versie'), findsOneWidget);
      expect(find.text('Herladen'), findsOneWidget);
      expect(find.text('Later'), findsNothing);
    });

    testWidgets('switching checkers resubscribes', (WidgetTester tester) async {
      final FakeChecker a = FakeChecker();
      final FakeChecker b = FakeChecker();
      await tester.pumpWidget(app(Scaffold(body: UpdateBanner(checker: a))));
      await tester.pumpWidget(app(Scaffold(body: UpdateBanner(checker: b))));
      a.announce('from-a');
      await tester.pump();
      expect(find.byType(MaterialBanner), findsNothing);
      b.announce('from-b');
      await tester.pump();
      expect(find.byType(MaterialBanner), findsOneWidget);
    });
  });

  group('WebUpdateListener', () {
    Widget host(
      FakeChecker checker, {
      UpdatePresentation? presentation,
      UpdateAvailableCallback? onUpdate,
      UpdateSnackBarBuilder? snack,
    }) {
      return MaterialApp(
        home: Scaffold(
          body: WebUpdateListener(
            checker: checker,
            presentation: presentation ?? UpdatePresentation.snackBar,
            onUpdateAvailable: onUpdate,
            snackBarBuilder: snack,
            child: const Text('page'),
          ),
        ),
      );
    }

    testWidgets('shows a SnackBar once per build and reloads', (
      WidgetTester tester,
    ) async {
      final FakeChecker checker = FakeChecker();
      await tester.pumpWidget(host(checker));
      expect(find.byType(SnackBar), findsNothing);

      checker.announce('b1');
      await tester.pumpAndSettle();
      expect(find.byType(SnackBar), findsOneWidget);
      expect(
        find.text('A new version of this app is available.'),
        findsOneWidget,
      );

      // Re-emitting the same build does not stack another snack bar.
      checker.announce('b1');
      await tester.pumpAndSettle();
      expect(find.byType(SnackBar), findsOneWidget);

      await tester.tap(find.text('Reload'));
      expect(checker.applyCalls, 1);
    });

    testWidgets('a newer build replaces the previous announcement', (
      WidgetTester tester,
    ) async {
      final FakeChecker checker = FakeChecker();
      await tester.pumpWidget(
        host(
          checker,
          snack: (_, UpdateStatus s, VoidCallback reload) => SnackBar(
            content: Text('build ${s.latest!.buildId}'),
            duration: const Duration(hours: 1),
          ),
        ),
      );
      checker.announce('b1');
      await tester.pumpAndSettle();
      expect(find.text('build b1'), findsOneWidget);
      checker.announce('b2');
      await tester.pumpAndSettle();
      expect(find.text('build b1'), findsNothing);
      expect(find.text('build b2'), findsOneWidget);
    });

    testWidgets('MaterialBanner presentation with dismiss', (
      WidgetTester tester,
    ) async {
      final FakeChecker checker = FakeChecker();
      await tester.pumpWidget(
        host(checker, presentation: UpdatePresentation.materialBanner),
      );
      checker.announce('b1');
      await tester.pumpAndSettle();
      expect(find.byType(MaterialBanner), findsOneWidget);
      await tester.tap(find.text('Later'));
      await tester.pumpAndSettle();
      expect(find.byType(MaterialBanner), findsNothing);
      expect(checker.applyCalls, 0);
    });

    testWidgets('announces an update already known at mount time', (
      WidgetTester tester,
    ) async {
      final FakeChecker checker = FakeChecker()..announce('b1');
      await tester.pumpWidget(host(checker));
      await tester.pumpAndSettle();
      expect(find.byType(SnackBar), findsOneWidget);
    });

    testWidgets('onUpdateAvailable replaces the built-in UI', (
      WidgetTester tester,
    ) async {
      final FakeChecker checker = FakeChecker();
      final List<String> seen = <String>[];
      await tester.pumpWidget(
        host(
          checker,
          onUpdate: (_, UpdateStatus s) => seen.add(s.latest!.buildId),
        ),
      );
      checker.announce('b1');
      checker.announce('b1');
      checker.announce('b2');
      await tester.pumpAndSettle();
      expect(seen, <String>['b1', 'b2']);
      expect(find.byType(SnackBar), findsNothing);
    });
  });

  testWidgets('real WebUpdateGuard on the VM renders nothing', (
    WidgetTester tester,
  ) async {
    final WebUpdateGuard guard = WebUpdateGuard()..start();
    await tester.pumpWidget(
      app(
        Scaffold(
          body: WebUpdateListener(
            checker: guard,
            child: UpdateBanner(checker: guard, child: const Text('page')),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(guard.status.state, UpdateState.unsupported);
    expect(find.byType(MaterialBanner), findsNothing);
    expect(find.byType(SnackBar), findsNothing);
    expect(find.text('page'), findsOneWidget);
    guard.dispose();
  });
}
