import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webview_bridge/src/auth/sso_exchange.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

void main() {
  group('SsoExchange refresh semantic', () {
    test(
      'refresh 400은 backend allowlist code만 reauth semantic으로 승격한다',
      () async {
        for (final fixture in const [
          ('A400-10', 'refresh_token_expired'),
          ('A400-11', 'refresh_token_invalid'),
        ]) {
          final exchange = SsoExchange(
            apiBaseUrl: 'https://qa.api.sazo.kr',
            client: MockClient(
              (_) async => http.Response(jsonEncode({'code': fixture.$1}), 400),
            ),
          );

          await expectLater(
            exchange.refreshToAccess(
              refreshToken: 'expired-refresh',
              deviceHeaders: const {},
            ),
            throwsA(
              isA<SsoExchangeException>().having(
                (error) => error.semanticReason,
                'semanticReason',
                fixture.$2,
              ),
            ),
          );
        }
      },
    );

    test('unknown/malformed refresh 400은 code failure로 남긴다', () async {
      for (final body in ['{"code":"A400-60"}', '<html>bad request</html>']) {
        final exchange = SsoExchange(
          apiBaseUrl: 'https://qa.api.sazo.kr',
          client: MockClient((_) async => http.Response(body, 400)),
        );

        await expectLater(
          exchange.refreshToAccess(
            refreshToken: 'refresh',
            deviceHeaders: const {},
          ),
          throwsA(
            isA<SsoExchangeException>().having(
              (error) => error.semanticReason,
              'semanticReason',
              isNull,
            ),
          ),
        );
      }
    });
  });
}
