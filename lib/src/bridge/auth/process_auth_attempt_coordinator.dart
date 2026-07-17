enum ProcessAuthAttemptKind { automatic, interactive }

typedef AuthAttemptSupersededCallback = void Function();
typedef AuthAttemptSettledCallback = void Function();

/// 동일 로그인 시도는 document 전환으로 revision이 바뀌어도 하나의 terminal만 가진다.
/// attempt id가 없는 bootstrap만 revision을 fallback identity로 사용한다.
String processAuthTerminalKey({
  required String? attemptId,
  required int revision,
}) => attemptId == null ? 'revision:$revision' : 'attempt:$attemptId';

class ProcessAuthAttemptLease {
  const ProcessAuthAttemptLease._({
    required this.generation,
    required this.attemptId,
    required this.kind,
    this.deduplicationKey,
  });

  final int generation;
  final String attemptId;
  final ProcessAuthAttemptKind kind;
  final String? deduplicationKey;
}

/// async gap 전후에 같은 인증 작업이 유지되는지 판별하는 불변 identity.
class AuthTerminalWorkSnapshot {
  const AuthTerminalWorkSnapshot({
    required this.epoch,
    required this.attemptId,
    required this.revision,
    required this.requestId,
    required this.leaseGeneration,
  });

  final int epoch;
  final String? attemptId;
  final int revision;
  final String? requestId;
  final int? leaseGeneration;

  bool matches({
    required int epoch,
    required String? attemptId,
    required int revision,
    required String? requestId,
    required int? leaseGeneration,
  }) =>
      this.epoch == epoch &&
      this.attemptId == attemptId &&
      this.revision == revision &&
      this.requestId == requestId &&
      this.leaseGeneration == leaseGeneration;
}

class _ActiveProcessAuthAttempt {
  const _ActiveProcessAuthAttempt({
    required this.lease,
    required this.onSuperseded,
    required this.onSettled,
  });

  final ProcessAuthAttemptLease lease;
  final AuthAttemptSupersededCallback onSuperseded;
  final AuthAttemptSettledCallback onSettled;
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
  final Set<String> _terminalKeys = <String>{};

  bool claimAutomaticBootstrap() {
    if (_automaticBootstrapObserved) return false;
    _automaticBootstrapObserved = true;
    return true;
  }

  /// 서비스 국가 전환처럼 인증 저장소와 origin이 함께 바뀌는 경계에서 호출한다.
  /// 모든 bridge의 active owner를 선점 종료하고 대상 국가 bootstrap을 새로 허용한다.
  void resetForAuthBoundary() {
    _automaticBootstrapObserved = false;
    final previous = _active;
    _active = null;
    previous?.onSuperseded();
  }

  ProcessAuthAttemptLease? tryBeginAutomatic({
    required String attemptId,
    required AuthAttemptSupersededCallback onSuperseded,
    required AuthAttemptSettledCallback onSettled,
  }) {
    if (_active != null) return null;
    return _activate(
      attemptId: attemptId,
      kind: ProcessAuthAttemptKind.automatic,
      onSuperseded: onSuperseded,
      onSettled: onSettled,
    );
  }

  ProcessAuthAttemptLease beginInteractive({
    required String attemptId,
    required AuthAttemptSupersededCallback onSuperseded,
    required AuthAttemptSettledCallback onSettled,
    String? deduplicationKey,
  }) {
    return tryBeginInteractive(
      attemptId: attemptId,
      onSuperseded: onSuperseded,
      onSettled: onSettled,
      // 기존 API는 중복 제거를 요청하지 않은 호출이므로 매번 고유 key를 부여한다.
      deduplicationKey:
          deduplicationKey ?? 'legacy:${_generation + 1}:$attemptId',
    )!;
  }

  /// 동일 provider/country의 interactive 인증이 이미 진행 중이면 새 작업을 만들지 않는다.
  ///
  /// UI 재클릭이나 여러 WebView document의 중복 전달이 기존 SDK interaction을 취소하고
  /// revision write를 계속 적재하는 것을 막는다. 다른 provider로 전환한 명시적 사용자
  /// 의도는 기존처럼 이전 시도를 선점한다.
  ProcessAuthAttemptLease? tryBeginInteractive({
    required String attemptId,
    required AuthAttemptSupersededCallback onSuperseded,
    required AuthAttemptSettledCallback onSettled,
    required String deduplicationKey,
  }) {
    final previous = _active;
    if (previous?.lease.kind == ProcessAuthAttemptKind.interactive &&
        previous?.lease.deduplicationKey == deduplicationKey) {
      return null;
    }
    final lease = _activate(
      attemptId: attemptId,
      kind: ProcessAuthAttemptKind.interactive,
      onSuperseded: onSuperseded,
      onSettled: onSettled,
      deduplicationKey: deduplicationKey,
    );
    previous?.onSuperseded();
    return lease;
  }

  ProcessAuthAttemptLease _activate({
    required String attemptId,
    required ProcessAuthAttemptKind kind,
    required AuthAttemptSupersededCallback onSuperseded,
    required AuthAttemptSettledCallback onSettled,
    String? deduplicationKey,
  }) {
    _generation += 1;
    final lease = ProcessAuthAttemptLease._(
      generation: _generation,
      attemptId: attemptId,
      kind: kind,
      deduplicationKey: deduplicationKey,
    );
    _active = _ActiveProcessAuthAttempt(
      lease: lease,
      onSuperseded: onSuperseded,
      onSettled: onSettled,
    );
    return lease;
  }

  bool isActive(ProcessAuthAttemptLease lease) =>
      _active?.lease.generation == lease.generation;

  void complete(ProcessAuthAttemptLease lease) {
    if (isActive(lease)) _active = null;
  }

  bool isTerminalSettled({required String? attemptId, required int revision}) =>
      _terminalKeys.contains(
        processAuthTerminalKey(attemptId: attemptId, revision: revision),
      );

  /// process 내 여러 bridge가 같은 시도를 관측해도 첫 terminal만 승인한다.
  /// 다른 bridge가 먼저 성공을 확정하면 원 소유자에게 알려 deadline을 즉시 정지한다.
  bool settleTerminal({required String? attemptId, required int revision}) {
    final key = processAuthTerminalKey(
      attemptId: attemptId,
      revision: revision,
    );
    if (!_terminalKeys.add(key)) return false;
    if (_terminalKeys.length > 200) {
      _terminalKeys.remove(_terminalKeys.first);
    }

    final active = _active;
    if (active != null &&
        attemptId != null &&
        active.lease.attemptId == attemptId) {
      _active = null;
      active.onSettled();
    }
    return true;
  }
}
