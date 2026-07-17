import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webview_bridge/src/bridge/auth/auto_auth_attempt.dart';

void main() {
  Map<String, Object?> request({
    int protocolVersion = 2,
    String? requestId = 'request-1',
  }) => {
    'protocolVersion': protocolVersion,
    if (requestId != null) 'requestId': requestId,
  };

  Map<String, Object?> response({String? refreshToken = 'refresh-secret'}) => {
    'type': 'REFRESH_TOKEN_READ',
    'data': {
      'protocolVersion': 2,
      'status': refreshToken == null ? 'absent' : 'found',
      if (refreshToken != null) 'refreshToken': refreshToken,
    },
  };

  group('AutoAuthAttemptController', () {
    test('첫 v2 token read를 request 기반 독립 attempt로 만든다', () {
      final controller = AutoAuthAttemptController();

      final attemptId = controller.beginInitialRefresh(
        requestData: request(),
        readResponse: response(),
        interactiveAttemptActive: false,
        fallbackNonce: 123,
      );

      expect(attemptId, 'auto-auth-request-1');
      expect(controller.activeAttemptId, attemptId);
      expect(autoAuthProvider, 'AUTO_REFRESH');
    });

    test('legacy read는 v2 cold-start 판정을 소비하지 않는다', () {
      final controller = AutoAuthAttemptController();

      expect(
        controller.beginInitialRefresh(
          requestData: request(protocolVersion: 1),
          readResponse: response(),
          interactiveAttemptActive: false,
          fallbackNonce: 123,
        ),
        isNull,
      );
      expect(
        controller.beginInitialRefresh(
          requestData: request(),
          readResponse: response(),
          interactiveAttemptActive: false,
          fallbackNonce: 123,
        ),
        'auto-auth-request-1',
      );
    });

    test('첫 v2 read에 token이 없으면 이후 same-process read를 새 시도로 만들지 않는다', () {
      final controller = AutoAuthAttemptController();

      expect(
        controller.beginInitialRefresh(
          requestData: request(),
          readResponse: response(refreshToken: null),
          interactiveAttemptActive: false,
          fallbackNonce: 123,
        ),
        isNull,
      );
      expect(
        controller.beginInitialRefresh(
          requestData: request(requestId: 'request-2'),
          readResponse: response(),
          interactiveAttemptActive: false,
          fallbackNonce: 124,
        ),
        isNull,
      );
    });

    test('interactive 로그인 중 token read는 auto attempt로 승격하지 않는다', () {
      final controller = AutoAuthAttemptController();

      expect(
        controller.beginInitialRefresh(
          requestData: request(),
          readResponse: response(),
          interactiveAttemptActive: true,
          fallbackNonce: 123,
        ),
        isNull,
      );
      expect(controller.activeAttemptId, isNull);
    });

    test('requestId가 없으면 process-local nonce로 식별한다', () {
      final controller = AutoAuthAttemptController();

      expect(
        controller.beginInitialRefresh(
          requestData: request(requestId: null),
          readResponse: response(),
          interactiveAttemptActive: false,
          fallbackNonce: 456,
        ),
        'auto-auth-456',
      );
    });

    test('auto attempt ID가 기존 web session ID보다 우선하고 응답에도 결합된다', () {
      final controller = AutoAuthAttemptController();
      controller.beginInitialRefresh(
        requestData: request(),
        readResponse: response(),
        interactiveAttemptActive: false,
        fallbackNonce: 123,
      );
      final tokenResponse = <String, Object?>{
        'type': 'AUTH_TOKENS_READY',
        'data': <String, Object?>{'authSessionId': 'previous-sso-attempt'},
      };

      controller.bindToResponse(tokenResponse);

      expect(
        controller.effectiveAttemptId(
          messageAttemptId: 'previous-sso-attempt',
          activeAttemptId: 'previous-sso-attempt',
        ),
        'auto-auth-request-1',
      );
      expect(
        (tokenResponse['data'] as Map)['authSessionId'],
        'auto-auth-request-1',
      );
    });

    test('active attempt 정리는 cold-start 1회 게이트를 다시 열지 않는다', () {
      final controller = AutoAuthAttemptController();
      controller.beginInitialRefresh(
        requestData: request(),
        readResponse: response(),
        interactiveAttemptActive: false,
        fallbackNonce: 123,
      );

      controller.clearActiveAttempt();

      expect(controller.activeAttemptId, isNull);
      expect(
        controller.beginInitialRefresh(
          requestData: request(requestId: 'request-2'),
          readResponse: response(),
          interactiveAttemptActive: false,
          fallbackNonce: 124,
        ),
        isNull,
      );
    });

    test('auth boundary reset은 대상 국가의 bootstrap을 새 시도로 허용한다', () {
      final controller = AutoAuthAttemptController();
      controller.beginInitialRefresh(
        requestData: request(),
        readResponse: response(),
        interactiveAttemptActive: false,
        fallbackNonce: 123,
      );

      controller.resetForAuthBoundary();

      expect(
        controller.beginInitialRefresh(
          requestData: request(requestId: 'kr-request'),
          readResponse: response(),
          interactiveAttemptActive: false,
          fallbackNonce: 124,
        ),
        'auto-auth-kr-request',
      );
    });
  });
}
