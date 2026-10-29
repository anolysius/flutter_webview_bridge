import 'dart:async' show TimeoutException;
import 'dart:io' show SocketException;

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webview_bridge/src/auth/sso_exchange.dart';
import 'package:flutter_webview_bridge/src/bridge/events/auth_failure_cause.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Future<SsoExchangeException> _exchangeFailure(MockClient client) async {
  final exchange = SsoExchange(
    apiBaseUrl: 'https://qa.api.sazo.kr',
    client: client,
  );
  try {
    await exchange.exchange(
      provider: SsoProvider.kakao,
      idToken: 'id-token',
      deviceHeaders: const {},
    );
  } on SsoExchangeException catch (e) {
    return e;
  }
  fail('SsoExchangeException 이 나야 한다');
}

void main() {
  group('서버 교환 실패 원인', () {
    test('같은 400 이라도 서버 오류 코드별로 다른 원인이 된다', () async {
      final a = await _exchangeFailure(
        MockClient((_) async => http.Response('{"code":"A400-29"}', 400)),
      );
      final b = await _exchangeFailure(
        MockClient((_) async => http.Response('{"code":"A400-31"}', 400)),
      );
      expect(a.failureCause, 'SSO_IDTOKEN_HTTP_400_A400_29');
      expect(a.serverErrorCode, 'A400-29');
      expect(b.failureCause, 'SSO_IDTOKEN_HTTP_400_A400_31');
      // 웹 allowlist 하위호환 분류는 그대로.
      expect(a.failureCode, 'SSO_ID_TOKEN_HTTP');
    });

    test('공통 envelope 의 errorCode(서비스 접두사 포함)를 우선 읽는다', () async {
      final e = await _exchangeFailure(
        MockClient(
          (_) async => http.Response(
            '{"code":400,"errorCode":"USERA400-29","message":"x"}',
            400,
          ),
        ),
      );
      expect(e.serverErrorCode, 'USERA400-29');
      expect(e.failureCause, 'SSO_IDTOKEN_HTTP_400_USERA400_29');
    });

    test('서버 코드가 없거나 allowlist 밖이면 상태 코드만 남긴다', () async {
      final noCode = await _exchangeFailure(
        MockClient((_) async => http.Response('<html>bad gateway</html>', 502)),
      );
      expect(noCode.failureCause, 'SSO_IDTOKEN_HTTP_502');
      expect(noCode.serverErrorCode, isNull);

      final private = await _exchangeFailure(
        MockClient(
          (_) async => http.Response('{"code":"private@example.com"}', 400),
        ),
      );
      expect(private.failureCause, 'SSO_IDTOKEN_HTTP_400');
      expect(private.serverErrorCode, isNull);
    });

    test('refresh 단계 실패는 REFRESH 원인이다', () async {
      final e = await _exchangeFailure(
        MockClient((request) async {
          if (request.url.path.endsWith('/id-token')) {
            return http.Response('{"refreshToken":"rt"}', 200);
          }
          return http.Response('{"code":"A400-10"}', 400);
        }),
      );
      expect(e.failureCause, 'SSO_REFRESH_HTTP_400_A400_10');
      expect(e.semanticReason, 'refresh_token_expired');
    });

    test('네트워크 실패는 종류별 원인 + 외부 실패 + 기존 NETWORK_ERROR 분류', () async {
      final cases = {
        const SocketException('no route'): 'SSO_IDTOKEN_NETWORK_SOCKET',
        TimeoutException('t'): 'SSO_IDTOKEN_NETWORK_TIMEOUT',
        http.ClientException('Connection closed'): 'SSO_IDTOKEN_NETWORK_CLIENT',
      };
      for (final entry in cases.entries) {
        final e = await _exchangeFailure(
          MockClient((_) async => throw entry.key),
        );
        expect(e.failureCause, entry.value);
        expect(e.failureCode, 'NETWORK_ERROR');
        expect(e.failureStage, 'id_token_exchange');
        expect(e.externalFailure, isTrue);
        expect(
          resultCodeForFailureCause(e.failureCause!),
          'excluded_external_failure',
        );
      }
    });

    test('모든 교환 실패 원인은 형식 규칙을 지킨다', () async {
      final e = await _exchangeFailure(
        MockClient((_) async => http.Response('not json', 200)),
      );
      expect(e.failureCause, 'SSO_IDTOKEN_INVALID_JSON');
      expect(e.failureCause, matches(RegExp(r'^[A-Z][A-Z0-9_]{0,63}$')));
    });
  });

  group('nativeFailureCause — NATIVE_INTERNAL_ERROR 분해', () {
    test('단계·예외 타입별로 다른 원인이 된다', () {
      expect(
        nativeFailureCause('refresh_exchange', const FormatException('x')),
        'NATIVE_REFRESH_EXCHANGE_UNEXPECTED_FORMAT_EXCEPTION',
      );
      expect(
        nativeFailureCause('refresh_exchange', StateError('x')),
        'NATIVE_REFRESH_EXCHANGE_UNEXPECTED_STATE_ERROR',
      );
      expect(
        nativeFailureCause('native_sdk', StateError('x')),
        'NATIVE_NATIVE_SDK_UNEXPECTED_STATE_ERROR',
      );
    });
  });
}
