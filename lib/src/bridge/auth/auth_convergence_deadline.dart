enum AuthConvergenceDeadlineEvent { softDeadline, hardDeadline }

Duration Function() _createMonotonicClock() {
  final stopwatch = Stopwatch()..start();
  return () => stopwatch.elapsed;
}

/// Counts only foreground time while native auth state converges into visible UI.
///
/// The 15 second boundary is diagnostic/recovery-only. A code failure is eligible
/// only after the 60 second hard boundary. Provider account selection is outside
/// this controller and therefore has no deadline.
class AuthConvergenceDeadlineController {
  AuthConvergenceDeadlineController({
    this.softDeadline = const Duration(seconds: 15),
    this.hardDeadline = const Duration(seconds: 60),
    Duration Function()? monotonicNow,
  }) : assert(softDeadline > Duration.zero),
       assert(hardDeadline > softDeadline),
       _now = monotonicNow ?? _createMonotonicClock();

  final Duration softDeadline;
  final Duration hardDeadline;
  final Duration Function() _now;

  Duration _foregroundElapsed = Duration.zero;
  Duration? _foregroundStartedAt;
  bool _softDeadlineEmitted = false;
  bool _active = false;

  bool get isActive => _active;
  bool get hasEmittedSoftDeadline => _softDeadlineEmitted;

  void start({required bool isForeground}) {
    _active = true;
    _softDeadlineEmitted = false;
    _foregroundElapsed = Duration.zero;
    _foregroundStartedAt = isForeground ? _now() : null;
  }

  void pause() {
    if (!_active || _foregroundStartedAt == null) return;
    _foregroundElapsed += _now() - _foregroundStartedAt!;
    _foregroundStartedAt = null;
  }

  void resume() {
    if (!_active || _foregroundStartedAt != null) return;
    _foregroundStartedAt = _now();
  }

  Duration get elapsed {
    final startedAt = _foregroundStartedAt;
    if (!_active || startedAt == null) return _foregroundElapsed;
    return _foregroundElapsed + (_now() - startedAt);
  }

  Duration? get nextTransitionIn {
    if (!_active) return null;
    final target = _softDeadlineEmitted ? hardDeadline : softDeadline;
    final remaining = target - elapsed;
    return remaining > Duration.zero ? remaining : Duration.zero;
  }

  AuthConvergenceDeadlineEvent? consumeDue() {
    if (!_active) return null;
    final currentElapsed = elapsed;
    if (currentElapsed >= hardDeadline) {
      return AuthConvergenceDeadlineEvent.hardDeadline;
    }
    if (!_softDeadlineEmitted && currentElapsed >= softDeadline) {
      _softDeadlineEmitted = true;
      return AuthConvergenceDeadlineEvent.softDeadline;
    }
    return null;
  }

  void settle() {
    _active = false;
    _softDeadlineEmitted = false;
    _foregroundElapsed = Duration.zero;
    _foregroundStartedAt = null;
  }
}
