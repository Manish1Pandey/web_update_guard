import 'package:meta/meta.dart';

import 'build_info.dart';

/// The lifecycle state reported by an [UpdateChecker].
enum UpdateState {
  /// Not running on the web; the guard does nothing.
  unsupported,

  /// Running on the web, but `index.html` carries no build-ID meta tag (the
  /// output was not stamped, e.g. `flutter run`). Updates cannot be detected.
  notStamped,

  /// Supported and stamped, but no check has completed yet.
  idle,

  /// The server hosts the same build as the one running.
  upToDate,

  /// The server hosts a different build; see [UpdateStatus.latest].
  updateAvailable,

  /// [UpdateChecker.applyUpdate] is purging caches and reloading.
  applying,

  /// The last check failed and no update is known; see [UpdateStatus.error].
  error,
}

/// An immutable snapshot of what an [UpdateChecker] knows.
@immutable
class UpdateStatus {
  /// Creates a status snapshot.
  const UpdateStatus({
    required this.state,
    this.runningBuildId,
    this.latest,
    this.error,
    this.checkedAt,
    this.checking = false,
  });

  /// The current state.
  final UpdateState state;

  /// The build ID of the bundle running in this tab, if stamped.
  final String? runningBuildId;

  /// The build the server reported on the last successful check.
  final BuildInfo? latest;

  /// The error of the most recent check, if it failed. Also set while
  /// [state] stays [UpdateState.updateAvailable] after a later check failed.
  final Object? error;

  /// When the last check finished (successfully or not).
  final DateTime? checkedAt;

  /// Whether a check is in flight right now.
  final bool checking;

  /// Whether a different build is available on the server.
  bool get isUpdateAvailable => state == UpdateState.updateAvailable;

  /// Returns a copy with the given fields replaced. Pass `clearError: true`
  /// to drop [error].
  UpdateStatus copyWith({
    UpdateState? state,
    String? runningBuildId,
    BuildInfo? latest,
    Object? error,
    bool clearError = false,
    DateTime? checkedAt,
    bool? checking,
  }) {
    return UpdateStatus(
      state: state ?? this.state,
      runningBuildId: runningBuildId ?? this.runningBuildId,
      latest: latest ?? this.latest,
      error: clearError ? null : (error ?? this.error),
      checkedAt: checkedAt ?? this.checkedAt,
      checking: checking ?? this.checking,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is UpdateStatus &&
      other.state == state &&
      other.runningBuildId == runningBuildId &&
      other.latest == latest &&
      other.error == error &&
      other.checkedAt == checkedAt &&
      other.checking == checking;

  @override
  int get hashCode =>
      Object.hash(state, runningBuildId, latest, error, checkedAt, checking);

  @override
  String toString() =>
      'UpdateStatus(${state.name}, running: $runningBuildId, '
      'latest: ${latest?.buildId}, checking: $checking'
      '${error == null ? '' : ', error: $error'})';
}

/// Anything that can report and apply web updates.
///
/// [WebUpdateGuard] is the real implementation; the widgets in this package
/// only depend on this interface, so tests can drive them with a fake.
abstract interface class UpdateChecker {
  /// The latest status snapshot.
  UpdateStatus get status;

  /// Emits every status change (broadcast).
  Stream<UpdateStatus> get statusStream;

  /// Checks the server right away and returns the resulting status.
  Future<UpdateStatus> checkNow();

  /// Purges service workers and caches and reloads the page onto the newest
  /// build.
  Future<void> applyUpdate();
}
