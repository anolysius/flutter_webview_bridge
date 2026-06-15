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
  });
}
