enum AuthAttemptPhase { idle, providerInteraction, terminalConvergence }

/// 인증 시도의 deadline 적용 구간을 추적한다.
///
/// OAuth 계정 선택/동의 화면은 사람의 입력을 기다리므로 짧은 terminal deadline의
/// 대상이 아니다. provider 결과가 native로 돌아온 뒤 web UI가 로그인 상태로
/// 수렴하는 구간에만 terminal deadline을 허용한다.
class AuthAttemptPhaseController {
  AuthAttemptPhase _phase = AuthAttemptPhase.idle;

  AuthAttemptPhase get phase => _phase;
  bool get isAwaitingTerminal => _phase != AuthAttemptPhase.idle;
  bool get shouldRunTerminalDeadline =>
      _phase == AuthAttemptPhase.terminalConvergence;

  bool shouldEmitConvergenceHandoffOnDispose({
    required bool hasActiveProcessLease,
  }) => hasActiveProcessLease && isAwaitingTerminal;

  void beginProviderInteraction({required bool tracksTerminal}) {
    _phase = tracksTerminal
        ? AuthAttemptPhase.providerInteraction
        : AuthAttemptPhase.idle;
  }

  /// provider SDK가 성공 결과를 반환한 시도를 UI 수렴 단계로 전환한다.
  ///
  /// 이미 종결된 시도([idle])나 provider 단계가 아닌 시도는 되살리지 않는다.
  bool completeProviderInteraction() {
    if (_phase != AuthAttemptPhase.providerInteraction) return false;
    _phase = AuthAttemptPhase.terminalConvergence;
    return true;
  }

  /// 저장된 세션 replay처럼 provider UI 없이 시작하는 수렴 경로를 복원한다.
  void restoreTerminalConvergence() {
    _phase = AuthAttemptPhase.terminalConvergence;
  }

  void settle() {
    _phase = AuthAttemptPhase.idle;
  }
}
