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
    required this.startedAt,
    this.deduplicationKey,
    this.predecessorAttemptId,
  });

  final int generation;
  final String attemptId;
  final ProcessAuthAttemptKind kind;
  final DateTime startedAt;
  final String? deduplicationKey;
  final String? predecessorAttemptId;
}

class _PendingConvergenceHandoff {
  const _PendingConvergenceHandoff({
    required this.predecessorAttemptId,
    required this.convergenceKey,
    required this.createdAt,
  });

  final String predecessorAttemptId;
  final String convergenceKey;
  final DateTime createdAt;
}

/// async gap 전후에 같은 인증 작업이 유지되는지 판별하는 불변 identity.
class AuthTerminalWorkSnapshot {
  const AuthTerminalWorkSnapshot({
    required this.epoch,
    required this.attemptId,
    required this.revision,
    required this.leaseGeneration,
  });

  final int epoch;
  final String? attemptId;
  final int revision;
  final int? leaseGeneration;

  /// [attemptId]로 조회한 process owner의 generation과 bridge-local 경계만 비교한다.
  ///
  /// UI commit은 로그인 시작 WebView가 아닌 새 home WebView에서 도착할 수 있으므로
  /// observer bridge의 local active attempt는 identity에 포함하지 않는다. 대신 caller가
  /// 이 snapshot의 [attemptId]로 조회한 process generation을 전달해야 한다.
  bool matchesProcessOwner({
    required int epoch,
    required int revision,
    required int? leaseGeneration,
  }) =>
      this.epoch == epoch &&
      this.revision == revision &&
      this.leaseGeneration != null &&
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
  ProcessAuthAttemptCoordinator({
    DateTime Function()? now,
    this.interactiveDuplicateWindow = const Duration(seconds: 12),
  }) : _now = now ?? DateTime.now;

  static final ProcessAuthAttemptCoordinator shared =
      ProcessAuthAttemptCoordinator();

  final DateTime Function() _now;
  final Duration interactiveDuplicateWindow;

  bool _automaticBootstrapObserved = false;
  int _generation = 0;
  _ActiveProcessAuthAttempt? _active;
  _PendingConvergenceHandoff? _pendingConvergenceHandoff;
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
    _pendingConvergenceHandoff = null;
    _supersedeActiveAttempt();
  }

  /// 명시적 로그아웃은 현재 process의 interactive owner를 즉시 종료한다.
  ///
  /// 로그아웃을 보낸 WebView와 로그인 owner WebView가 다를 수 있으므로 bridge-local
  /// lease만 완료해서는 안 된다. 반면 같은 국가의 cold-start bootstrap gate는 다시
  /// 열지 않아 로그아웃 직후 불필요한 자동 인증이 시작되지 않게 한다.
  void cancelActiveForExplicitLogout() {
    _pendingConvergenceHandoff = null;
    _supersedeActiveAttempt();
  }

  void _supersedeActiveAttempt() {
    final previous = _active;
    _active = null;
    previous?.onSuperseded();
  }

  ProcessAuthAttemptLease? tryBeginAutomatic({
    required String attemptId,
    required AuthAttemptSupersededCallback onSuperseded,
    required AuthAttemptSettledCallback onSettled,
    String? predecessorAttemptId,
    String? convergenceKey,
  }) {
    if (_active != null) return null;
    final resolvedPredecessorAttemptId =
        predecessorAttemptId ??
        (convergenceKey == null
            ? null
            : takeConvergenceHandoff(convergenceKey: convergenceKey));
    return _activate(
      attemptId: attemptId,
      kind: ProcessAuthAttemptKind.automatic,
      onSuperseded: onSuperseded,
      onSettled: onSettled,
      predecessorAttemptId: resolvedPredecessorAttemptId,
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
    void Function()? onActivated,
    bool forceSupersedeDuplicate = false,
  }) {
    final previous = _active;
    if (previous?.lease.attemptId == attemptId) {
      return null;
    }
    if (previous?.lease.kind == ProcessAuthAttemptKind.interactive &&
        previous?.lease.deduplicationKey == deduplicationKey) {
      final elapsed = _now().difference(previous!.lease.startedAt);
      // 짧은 구간에 도착한 동일 provider 요청만 중복으로 본다. Web의 native 접수 ACK
      // timeout 재시도는 forceSupersedeDuplicate로 명시되므로 이 window와 독립적이다.
      // window가 지나면 원 owner가 유실/고착됐다고 보고 새 시도가 선점할 수 있어야 한다.
      if (!forceSupersedeDuplicate &&
          (elapsed.isNegative || elapsed < interactiveDuplicateWindow)) {
        return null;
      }
    }
    final lease = _activate(
      attemptId: attemptId,
      kind: ProcessAuthAttemptKind.interactive,
      onSuperseded: onSuperseded,
      onSettled: onSettled,
      deduplicationKey: deduplicationKey,
    );
    _pendingConvergenceHandoff = null;
    previous?.onSuperseded();
    // 이전 owner callback이 bridge epoch를 무효화한 뒤 새 epoch를 발급해야 한다.
    // duplicate early-return 경로에서는 호출하지 않아 현재 owner identity를 보존한다.
    onActivated?.call();
    return lease;
  }

  ProcessAuthAttemptLease _activate({
    required String attemptId,
    required ProcessAuthAttemptKind kind,
    required AuthAttemptSupersededCallback onSuperseded,
    required AuthAttemptSettledCallback onSettled,
    String? deduplicationKey,
    String? predecessorAttemptId,
  }) {
    _generation += 1;
    final lease = ProcessAuthAttemptLease._(
      generation: _generation,
      attemptId: attemptId,
      kind: kind,
      startedAt: _now(),
      deduplicationKey: deduplicationKey,
      predecessorAttemptId: predecessorAttemptId,
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

  /// 다른 bridge instance도 같은 process-wide attempt의 async terminal 작업을
  /// generation으로 fence할 수 있게 한다.
  int? activeGenerationForAttempt(String? attemptId) {
    final active = _active?.lease;
    if (attemptId == null || active?.attemptId != attemptId) return null;
    return active!.generation;
  }

  String? activePredecessorForAttempt(String? attemptId) {
    final active = _active?.lease;
    if (attemptId == null || active?.attemptId != attemptId) return null;
    return active!.predecessorAttemptId;
  }

  void recordConvergenceHandoff({
    required ProcessAuthAttemptLease lease,
    required String convergenceKey,
  }) {
    if (!isActive(lease)) return;
    _pendingConvergenceHandoff = _PendingConvergenceHandoff(
      predecessorAttemptId: lease.attemptId,
      convergenceKey: convergenceKey,
      createdAt: _now(),
    );
  }

  String? takeConvergenceHandoff({
    required String convergenceKey,
    Duration maxAge = const Duration(seconds: 60),
  }) {
    final pending = _pendingConvergenceHandoff;
    if (pending == null) return null;
    final age = _now().difference(pending.createdAt);
    if (age.isNegative || age > maxAge) {
      _pendingConvergenceHandoff = null;
      return null;
    }
    if (pending.convergenceKey != convergenceKey) return null;
    _pendingConvergenceHandoff = null;
    return pending.predecessorAttemptId;
  }

  bool hasConvergenceHandoff({
    required String convergenceKey,
    Duration maxAge = const Duration(seconds: 60),
  }) {
    final pending = _pendingConvergenceHandoff;
    if (pending == null) return false;
    final age = _now().difference(pending.createdAt);
    if (age.isNegative || age > maxAge) {
      _pendingConvergenceHandoff = null;
      return false;
    }
    return pending.convergenceKey == convergenceKey;
  }

  bool isCurrentTerminalWork(
    AuthTerminalWorkSnapshot snapshot, {
    required int epoch,
    required int revision,
  }) => snapshot.matchesProcessOwner(
    epoch: epoch,
    revision: revision,
    leaseGeneration: activeGenerationForAttempt(snapshot.attemptId),
  );

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
