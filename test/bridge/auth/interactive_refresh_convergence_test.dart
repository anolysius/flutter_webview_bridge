import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webview_bridge/src/bridge/auth/interactive_refresh_convergence.dart';

void main() {
  bool evaluate({
    bool ownsLease = true,
    bool isTerminalConvergence = true,
    String? activeAttempt = 'sso-current',
    String? cachedAttempt = 'sso-current',
    String? requestedAttempt,
  }) => shouldReplayInteractiveRefresh(
    ownsActiveInteractiveLease: ownsLease,
    isTerminalConvergence: isTerminalConvergence,
    activeAuthSessionId: activeAttempt,
    cachedAuthSessionId: cachedAttempt,
    requestedAuthSessionId: requestedAttempt,
  );

  test(
    '현재 interactive owner의 fresh home read는 같은 attempt cache replay를 허용한다',
    () {
      expect(evaluate(), isTrue);
      expect(evaluate(requestedAttempt: 'sso-current'), isTrue);
    },
  );

  test('다른 bridge owner 또는 일반 자동 로그인에는 replay 예외를 열지 않는다', () {
    expect(evaluate(ownsLease: false), isFalse);
    expect(evaluate(isTerminalConvergence: false), isFalse);
  });

  test('다른 attempt cache/request와 identity 없는 payload는 모두 거부한다', () {
    expect(evaluate(cachedAttempt: 'sso-old'), isFalse);
    expect(evaluate(requestedAttempt: 'sso-other'), isFalse);
    expect(evaluate(activeAttempt: null), isFalse);
    expect(evaluate(cachedAttempt: null), isFalse);
  });
}
