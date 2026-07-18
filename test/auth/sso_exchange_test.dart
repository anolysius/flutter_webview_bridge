import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webview_bridge/src/auth/sso_exchange.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  group('SsoExchange', () {
    test('id-token 요청부터 device headers 를 포함한다', () async {
      final requests = <http.Request>[];
      final client = MockClient((request) async {
        requests.add(request);

        if (request.url.path.endsWith('/id-token')) {
          return http.Response(
            jsonEncode({'refreshToken': 'refresh-token'}),
            200,
          );
        }
        if (request.url.path == '/api/user/auth/token/refresh') {
          return http.Response(
            jsonEncode({
              'data': {
                'accessToken': 'access-token',
                'refreshToken': 'device-refresh-token',
              },
            }),
            200,
          );
        }
        return http.Response('not found', 404);
      });

      final exchange = SsoExchange(
        apiBaseUrl: 'https://qa.api.sazo.kr',
        client: client,
      );
      final deviceHeaders = {
        'x-sazo-app-id': 'kr.co.sazo.shop',
        'x-sazo-app-os': 'ios',
        'x-sazo-app-version': '1.4.0',
        'x-sazo-device-id': 'device-idfv',
      };

      for (final provider in SsoProvider.values) {
        final result = await exchange.exchange(
          provider: provider,
          idToken: 'id-token',
          deviceHeaders: deviceHeaders,
        );
        expect(result.accessToken, 'access-token');
        expect(result.refreshToken, 'device-refresh-token');
      }

      final idTokenRequests = requests.where(
        (request) => request.url.path.endsWith('/id-token'),
      );
      expect(idTokenRequests, hasLength(SsoProvider.values.length));

      for (final request in idTokenRequests) {
        expect(
          request.headers,
          containsPair('x-sazo-app-id', 'kr.co.sazo.shop'),
        );
        expect(request.headers, containsPair('x-sazo-app-os', 'ios'));
        expect(request.headers, containsPair('x-sazo-app-version', '1.4.0'));
        expect(
          request.headers,
          containsPair('x-sazo-device-id', 'device-idfv'),
        );
        expect(
          request.headers,
          containsPair('x-domain-type', 'sazo-korea-shop'),
        );
      }
    });

    test('5xx는 external failure로 분류하고 응답 본문을 exception에 노출하지 않는다', () async {
      final exchange = SsoExchange(
        apiBaseUrl: 'https://qa.api.sazo.kr',
        client: MockClient(
          (_) async => http.Response(
            '{"email":"private@example.com","accessToken":"secret"}',
            503,
          ),
        ),
      );

      try {
        await exchange.exchange(
          provider: SsoProvider.kakao,
          idToken: 'id-token',
          deviceHeaders: const {},
        );
        fail('exception expected');
      } on SsoExchangeException catch (error) {
        expect(error.externalFailure, isTrue);
        expect(error.failureStage, 'id_token_exchange');
        expect(error.failureCode, 'SSO_ID_TOKEN_HTTP');
        expect(error.statusCode, 503);
        expect(error.toString(), isNot(contains('private@example.com')));
        expect(error.toString(), isNot(contains('secret')));
      }
    });

    test('id-token 성공 응답이 JSON이 아니면 안전한 구조화 코드로 분류한다', () async {
      final exchange = SsoExchange(
        apiBaseUrl: 'https://qa.api.sazo.kr',
        client: MockClient(
          (_) async => http.Response('<html>bad gateway</html>', 200),
        ),
      );

      expect(
        () => exchange.exchange(
          provider: SsoProvider.kakao,
          idToken: 'id-token',
          deviceHeaders: const {},
        ),
        throwsA(
          isA<SsoExchangeException>()
              .having(
                (e) => e.failureStage,
                'failureStage',
                'id_token_exchange',
              )
              .having(
                (e) => e.failureCode,
                'failureCode',
                'SSO_ID_TOKEN_INVALID_RESPONSE',
              ),
        ),
      );
    });

    test('refresh 응답 accessToken 누락은 refresh 단계 코드로 분류한다', () async {
      final exchange = SsoExchange(
        apiBaseUrl: 'https://qa.api.sazo.kr',
        client: MockClient((request) async {
          if (request.url.path.endsWith('/id-token')) {
            return http.Response(
              jsonEncode({'refreshToken': 'refresh-token'}),
              200,
            );
          }
          return http.Response(jsonEncode({'data': <String, Object?>{}}), 200);
        }),
      );

      expect(
        () => exchange.exchange(
          provider: SsoProvider.google,
          idToken: 'id-token',
          deviceHeaders: const {},
        ),
        throwsA(
          isA<SsoExchangeException>()
              .having((e) => e.failureStage, 'failureStage', 'refresh_exchange')
              .having(
                (e) => e.failureCode,
                'failureCode',
                'SSO_REFRESH_MISSING_ACCESS',
              ),
        ),
      );
    });
  });
}
