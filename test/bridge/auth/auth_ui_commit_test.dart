import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webview_bridge/src/bridge/auth/auth_ui_commit.dart';

void main() {
  Map<String, Object?> valid() => {
    'protocolVersion': 2,
    'requestId': 'request-1',
    'authSessionId': 'attempt-1',
    'authRevision': 5,
    'visibilityState': 'visible',
    'isAccessTokenBind': true,
    'userIdsMatch': true,
    'dockModel': 'mypage',
    'dockHref': '/account',
  };

  AuthUiCommitDecision evaluate(Map<String, Object?> data) =>
      validateAuthUiCommit(
        data: data,
        activeAuthSessionId: 'attempt-1',
        activeAuthRevision: 5,
        nativeIsHome: true,
        webIsHome: true,
      );

  test('visible home의 auth state/profile/dock가 모두 일치할 때만 수락한다', () {
    expect(evaluate(valid()).isAccepted, isTrue);
  });

  test('home document의 requestId가 바뀌어도 같은 attempt/revision이면 수락한다', () {
    expect(
      evaluate({...valid(), 'requestId': 'request-new-home'}).isAccepted,
      isTrue,
    );
  });

  test('process owner를 검증한 observer bridge는 local attempt 없이도 수락한다', () {
    final decision = validateAuthUiCommit(
      data: valid(),
      activeAuthSessionId: null,
      activeAuthRevision: 5,
      nativeIsHome: true,
      webIsHome: true,
    );

    expect(decision.isAccepted, isTrue);
  });

  test('hidden/wrong attempt/stale revision/로그인 href를 각각 거부한다', () {
    expect(
      evaluate({...valid(), 'visibilityState': 'hidden'}).rejection,
      AuthUiCommitRejection.hiddenDocument,
    );
    expect(
      evaluate({...valid(), 'authSessionId': 'attempt-old'}).rejection,
      AuthUiCommitRejection.wrongAttempt,
    );
    expect(
      evaluate({...valid(), 'authRevision': 4}).rejection,
      AuthUiCommitRejection.staleRevision,
    );
    expect(
      evaluate({...valid(), 'dockHref': '/auth/signin'}).rejection,
      AuthUiCommitRejection.dockMismatch,
    );
  });
}
