import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webview_bridge/src/bridge/auth/auth_semantic_commit.dart';

void main() {
  Map<String, Object?> valid({bool reauth = false}) => {
    'protocolVersion': 3,
    'requestId': 'request-1',
    'authSessionId': 'attempt-1',
    'authRevision': 4,
    'visibilityState': 'visible',
    if (reauth) ...{
      'isAccessTokenBind': false,
      'dockModel': 'login',
      'dockHref': '/auth/signin',
    },
  };

  AuthSemanticCommitDecision evaluate(
    Map<String, Object?> data, {
    AuthSemanticCommitKind kind = AuthSemanticCommitKind.onboardingReady,
    bool nativeRouteMatches = true,
    bool webRouteMatches = true,
  }) => validateAuthSemanticCommit(
    kind: kind,
    data: data,
    activeProtocolVersion: 3,
    activeRequestId: 'request-1',
    activeAuthSessionId: 'attempt-1',
    activeAuthRevision: 4,
    nativeRouteMatches: nativeRouteMatches,
    webRouteMatches: webRouteMatches,
  );

  test('onboarding은 exact correlation과 양쪽 signup route일 때만 수락한다', () {
    expect(evaluate(valid()).isAccepted, isTrue);
    expect(
      evaluate({...valid(), 'requestId': 'request-old'}).rejection,
      AuthSemanticCommitRejection.wrongRequest,
    );
    expect(
      evaluate(valid(), nativeRouteMatches: false).rejection,
      AuthSemanticCommitRejection.wrongRoute,
    );
  });

  test('reauth는 visible login dock과 access unbound를 함께 요구한다', () {
    expect(
      evaluate(
        valid(reauth: true),
        kind: AuthSemanticCommitKind.reauthRequired,
      ).isAccepted,
      isTrue,
    );
    expect(
      evaluate({
        ...valid(reauth: true),
        'isAccessTokenBind': true,
      }, kind: AuthSemanticCommitKind.reauthRequired).rejection,
      AuthSemanticCommitRejection.authStateMismatch,
    );
    expect(
      evaluate({
        ...valid(reauth: true),
        'dockHref': '/account',
      }, kind: AuthSemanticCommitKind.reauthRequired).rejection,
      AuthSemanticCommitRejection.dockMismatch,
    );
  });

  test('v2 또는 stale revision은 v3 semantic commit을 활성화하지 않는다', () {
    expect(
      evaluate({...valid(), 'protocolVersion': 2}).rejection,
      AuthSemanticCommitRejection.protocolMismatch,
    );
    expect(
      evaluate({...valid(), 'authRevision': 3}).rejection,
      AuthSemanticCommitRejection.staleRevision,
    );
  });
}
