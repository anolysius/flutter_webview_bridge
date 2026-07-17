enum ProcessAuthAttemptKind { automatic, interactive }

typedef AuthAttemptSupersededCallback = void Function();

class ProcessAuthAttemptLease {
  const ProcessAuthAttemptLease._({
    required this.generation,
    required this.attemptId,
    required this.kind,
  });

  final int generation;
  final String attemptId;
  final ProcessAuthAttemptKind kind;
}

class _ActiveProcessAuthAttempt {
  const _ActiveProcessAuthAttempt({
    required this.lease,
    required this.onSuperseded,
  });

  final ProcessAuthAttemptLease lease;
  final AuthAttemptSupersededCallback onSuperseded;
}

/// 하나의 Dart process 안에서 생성되는 여러 bridge instance의 인증 소유권을 조정한다.
///
/// WebView/MainScreen 재생성은 앱 cold-start가 아니다. 따라서 자동 로그인 bootstrap은
/// process당 한 번만 관측하며, 사용자가 시작한 interactive 로그인은 진행 중인 자동
/// 로그인을 선점한다. stale lease의 완료가 현재 시도를 지우지 않도록 generation을 쓴다.
class ProcessAuthAttemptCoordinator {
  ProcessAuthAttemptCoordinator();

  static final ProcessAuthAttemptCoordinator shared =
      ProcessAuthAttemptCoordinator();

  bool _automaticBootstrapObserved = false;
  int _generation = 0;
  _ActiveProcessAuthAttempt? _active;

  bool claimAutomaticBootstrap() {
    if (_automaticBootstrapObserved) return false;
    _automaticBootstrapObserved = true;
    return true;
  }

  ProcessAuthAttemptLease? tryBeginAutomatic({
    required String attemptId,
    required AuthAttemptSupersededCallback onSuperseded,
  }) {
    if (_active != null) return null;
    return _activate(
      attemptId: attemptId,
      kind: ProcessAuthAttemptKind.automatic,
      onSuperseded: onSuperseded,
    );
  }

  ProcessAuthAttemptLease beginInteractive({
    required String attemptId,
    required AuthAttemptSupersededCallback onSuperseded,
  }) {
    final previous = _active;
    final lease = _activate(
      attemptId: attemptId,
      kind: ProcessAuthAttemptKind.interactive,
      onSuperseded: onSuperseded,
    );
    previous?.onSuperseded();
    return lease;
  }

  ProcessAuthAttemptLease _activate({
    required String attemptId,
    required ProcessAuthAttemptKind kind,
    required AuthAttemptSupersededCallback onSuperseded,
  }) {
    _generation += 1;
    final lease = ProcessAuthAttemptLease._(
      generation: _generation,
      attemptId: attemptId,
      kind: kind,
    );
    _active = _ActiveProcessAuthAttempt(
      lease: lease,
      onSuperseded: onSuperseded,
    );
    return lease;
  }

  bool isActive(ProcessAuthAttemptLease lease) =>
      _active?.lease.generation == lease.generation;

  void complete(ProcessAuthAttemptLease lease) {
    if (isActive(lease)) _active = null;
  }
}
