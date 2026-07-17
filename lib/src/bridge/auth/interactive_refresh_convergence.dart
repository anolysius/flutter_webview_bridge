/// 진행 중인 interactive 로그인의 새 home document에 session replay를 허용할지 결정한다.
///
/// 다른 bridge/attempt의 refresh가 현재 사용자의 로그인을 덮지 못하도록 모든 ownership
/// identity가 일치할 때만 true다. 일반 자동 로그인은 이 예외를 사용하지 않는다.
bool shouldReplayInteractiveRefresh({
  required bool ownsActiveInteractiveLease,
  required bool isTerminalConvergence,
  required String? activeAuthSessionId,
  required String? cachedAuthSessionId,
  required String? requestedAuthSessionId,
}) {
  if (!ownsActiveInteractiveLease || !isTerminalConvergence) return false;
  if (activeAuthSessionId == null || cachedAuthSessionId == null) return false;
  if (activeAuthSessionId != cachedAuthSessionId) return false;
  return requestedAuthSessionId == null ||
      requestedAuthSessionId == cachedAuthSessionId;
}
