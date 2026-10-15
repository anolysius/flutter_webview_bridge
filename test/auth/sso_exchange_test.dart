import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webview_bridge/src/auth/sso_exchange.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  group('SsoExchange', () {
    for (final domain in [
      'sazo-korea-shop',
      'sazo-global-shop',
      'sazo-japan-shop',
    ]) {
      for (final tokenProvider in [
        'GOOGLE',
        'APPLE',
        'KAKAO',
        'NAVER',
        'GLOBAL_GOOGLE',
        'GLOBAL_APPLE',
        'JAPAN_GOOGLE',
        'JAPAN_APPLE',
        'JAPAN_LINE',
      ]) {
        test(
          '$domain rejects only explicit non-JP realm evidence in $tokenProvider',
          () async {
            final jwtPayload = base64Url
                .encode(
                  utf8.encode(
                    jsonEncode({
                      'provider': {
                        'provider': tokenProvider,
                        'provider_id': 'fixture',
                      },
                    }),
                  ),
                )
                .replaceAll('=', '');
            final accessToken = 'e30.$jwtPayload.fixture';
            final exchange = SsoExchange(
              apiBaseUrl: 'https://qa2.api.sazo.shop',
              domainType: domain,
              client: MockClient((request) async {
                if (request.url.path.endsWith('/id-token')) {
                  return http.Response('{"refreshToken":"initial"}', 200);
                }
                return http.Response(
                  jsonEncode({
                    'data': {
                      'accessToken': accessToken,
                      'refreshToken': 'rotated',
                    },
                  }),
                  200,
                );
              }),
            );
            for (final interactive in [false, true]) {
              final operation = interactive
                  ? exchange.exchange(
                      provider: SsoProvider.google,
                      idToken: 'id',
                      deviceHeaders: const {},
                    )
                  : exchange.refreshToAccess(
                      refreshToken: 'stored',
                      deviceHeaders: const {},
                    );
              if (domain == 'sazo-japan-shop' &&
                  !tokenProvider.startsWith('JAPAN_')) {
                await expectLater(
                  operation,
                  throwsA(
                    isA<SsoExchangeException>()
                        .having(
                          (e) => e.failureCode,
                          'failureCode',
                          'SSO_SERVICE_COUNTRY_MISMATCH',
                        )
                        .having(
                          (e) => e.failureStage,
                          'failureStage',
                          'auth_context_validation',
                        ),
                  ),
                );
              } else {
                expect((await operation).accessToken, accessToken);
              }
            }
          },
        );
      }
    }

    for (final domainType in [
      'sazo-korea-shop',
      'sazo-global-shop',
      'sazo-japan-shop',
    ]) {
      for (final provider in [SsoProvider.google, SsoProvider.apple]) {
        test(
          '$domainType $provider exchange, refresh and me preserve realm',
          () async {
            final isJapan = domainType == 'sazo-japan-shop';
            final origin = isJapan
                ? 'https://qa2.api.sazo.shop'
                : domainType == 'sazo-global-shop'
                ? 'https://qa.api.sazoshop.com'
                : 'https://qa.api.sazo.kr';
            final requests = <http.Request>[];
            final exchange = SsoExchange(
              apiBaseUrl: origin,
              domainType: domainType,
              client: MockClient((request) async {
                requests.add(request);
                if (request.url.path.endsWith('/id-token')) {
                  return http.Response(
                    '{"refreshToken":"initial-refresh"}',
                    200,
                  );
                }
                if (request.url.path.endsWith('/token/refresh')) {
                  return http.Response(
                    '{"data":{"accessToken":"access","refreshToken":"rotated"}}',
                    200,
                  );
                }
                return http.Response('{"id":42}', 200);
              }),
            );
            final result = await exchange.exchange(
              provider: provider,
              idToken: 'provider-token',
              deviceHeaders: const {'x-sazo-app-id': 'com.shop.sazo.test'},
            );
            expect(result.refreshToken, 'rotated');
            expect(
              await exchange.fetchMe(
                accessToken: result.accessToken,
                deviceHeaders: const {},
              ),
              {'id': 42},
            );
            final providerPath = '${isJapan ? 'japan-' : ''}${provider.name}';
            expect(requests.map((r) => r.url.toString()), [
              '$origin/api/user/auth/$providerPath/id-token',
              '$origin/api/user/auth/token/refresh',
              '$origin/api/user/user-me',
            ]);
            for (final request in requests) {
              expect(request.headers['x-domain-type'], domainType);
            }
            expect(requests.last.headers['x-sazo-domain-type'], domainType);
            expect(
              jsonDecode(requests[1].body)['refreshToken'],
              'initial-refresh',
            );
          },
        );
      }
    }

    test(
      'JP never sends Kakao tokens to the Korean provider endpoint',
      () async {
        var requests = 0;
        final exchange = SsoExchange(
          apiBaseUrl: 'https://qa2.api.sazo.shop',
          domainType: 'sazo-japan-shop',
          client: MockClient((_) async {
            requests++;
            return http.Response('{}', 200);
          }),
        );
        await expectLater(
          exchange.exchange(
            provider: SsoProvider.kakao,
            idToken: 'token',
            deviceHeaders: const {},
          ),
          throwsA(
            isA<SsoExchangeException>().having(
              (e) => e.failureCode,
              'failureCode',
              'SSO_UNSUPPORTED_PROVIDER',
            ),
          ),
        );
        expect(requests, 0);
      },
    );

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
