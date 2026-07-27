import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webview_bridge/src/bridge/auth/pending_reauth_replay.dart';

void main() {
  const v3Request = <String, Object?>{
    'protocolVersion': 2,
    'maxProtocolVersion': 3,
    'authCapabilities': <String>[
      'softConvergenceDeadline',
      'onboardingHandoff',
      'reauthRequiredCommit',
    ],
    'requestId': 'request-new-document',
    'documentId': 'document-new',
    'pageGeneration': 1,
  };

  test('pending auto reauth는 새 document의 v3 request로 같은 attempt를 replay한다', () {
    final replay = buildPendingReauthReplay(
      ownsActiveAutomaticLease: true,
      isAwaitingTerminal: true,
      activeAuthSessionId: 'auto-attempt-1',
      activeAuthRevision: 7,
      semanticReason: 'refresh_token_expired',
      requestData: v3Request,
    );

    expect(replay, {
      'protocolVersion': 3,
      'authCapabilities': [
        'softConvergenceDeadline',
        'onboardingHandoff',
        'reauthRequiredCommit',
      ],
      'requestId': 'request-new-document',
      'authSessionId': 'auto-attempt-1',
      'documentId': 'document-new',
      'pageGeneration': 1,
      'authRevision': 7,
      'provider': 'AUTO_REFRESH',
      'journey': 'auto_refresh',
      'semanticReason': 'refresh_token_expired',
    });
  });

  test('v2 web, inactive lease, terminal 대기 아님은 replay하지 않는다', () {
    for (final fixture in <({bool owner, bool awaiting, Object request})>[
      (owner: false, awaiting: true, request: v3Request),
      (owner: true, awaiting: false, request: v3Request),
      (
        owner: true,
        awaiting: true,
        request: const {
          'protocolVersion': 2,
          'requestId': 'legacy-request',
          'documentId': 'legacy-document',
        },
      ),
    ]) {
      expect(
        buildPendingReauthReplay(
          ownsActiveAutomaticLease: fixture.owner,
          isAwaitingTerminal: fixture.awaiting,
          activeAuthSessionId: 'auto-attempt-1',
          activeAuthRevision: 7,
          semanticReason: 'refresh_token_expired',
          requestData: fixture.request,
        ),
        isNull,
      );
    }
  });
}
