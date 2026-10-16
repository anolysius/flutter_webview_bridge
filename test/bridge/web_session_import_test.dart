import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:flutter_webview_bridge/src/auth/sso_exchange.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webview_bridge/flutter_webview_bridge.dart';
import 'package:flutter_webview_bridge/src/bridge/auth/auth_protocol_negotiation.dart';
import 'package:flutter_webview_bridge/src/bridge/auth/auth_revision_store.dart';
import 'package:flutter_webview_bridge/src/bridge/auth/auth_terminal_store.dart';
import 'package:flutter_webview_bridge/src/bridge/auth/process_auth_attempt_coordinator.dart';
import 'package:flutter_webview_bridge/src/bridge/auth/pending_auth_attempt_store.dart';
import 'package:flutter_webview_bridge/src/bridge/events/refresh_token.dart';
import 'package:shared_preferences/shared_preferences.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

class _WebView extends PlatformWebViewController {
  _WebView()
    : super.implementation(const PlatformWebViewControllerCreationParams());
  final messages = <Map<String, dynamic>>[];
  String url = 'https://qa2.m.sazo.shop/auth/signin';
  int dropTokenReplies = 0;

  @override
  Future<String?> currentUrl() async => url;

  @override
  Future<Object> runJavaScriptReturningResult(String script) async {
    final encoded = RegExp(r'var payload = (.*);').firstMatch(script)?.group(1);
    if (encoded != null) {
      final message =
          jsonDecode(jsonDecode(encoded) as String) as Map<String, dynamic>;
      if (message['type'] == 'AUTH_TOKENS_READY' && dropTokenReplies > 0) {
        dropTokenReplies--;
        return false;
      }
      messages.add(message);
    }
    return true;
  }
}

class _FailRefreshStore extends InMemorySharedPreferencesStore {
  _FailRefreshStore({this.throwAfterWrite = false}) : super.empty();
  final bool throwAfterWrite;
  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    await super.setValue(valueType, key, value);
    if (key.endsWith(refreshTokenKeyFor('JP')) && throwAfterWrite) {
      throw StateError('fixture storage write failure');
    }
    return !key.endsWith(refreshTokenKeyFor('JP'));
  }
}

String _token(
  String provider, {
  String? userId = 'member-fixture',
  String kind = 'access',
}) =>
    'e30.${base64Url.encode(utf8.encode(jsonEncode({
      'provider': {'provider': provider},
      if (userId != null) 'user_id': userId,
      'token_use': kind,
    }))).replaceAll('=', '')}.fixture';

String get _refreshToken => _token('JAPAN_DB', kind: 'refresh');

Map<String, Object?> _offer() => {
  'protocolVersion': 3,
  'maxProtocolVersion': 3,
  'authCapabilities': authProtocolV3Capabilities.toList(),
};

class _Harness {
  _Harness(this.channel, this.web, this.traces, this.tester);
  final WidgetTester tester;
  final FlutterWebViewBridgeJavaScriptChannel channel;
  final _WebView web;
  final List<Map<String, Object?>> traces;

  static Future<_Harness> create(
    WidgetTester tester, {
    String country = 'JP',
    http.Client? refreshClient,
  }) async {
    late BuildContext context;
    await tester.pumpWidget(
      MaterialApp(
        home: Builder(
          builder: (value) {
            context = value;
            return const SizedBox();
          },
        ),
      ),
    );
    final web = _WebView();
    final traces = <Map<String, Object?>>[];
    final channel = (await tester.runAsync(
      () async => FlutterWebViewBridgeJavaScriptChannel(
        context: context,
        webViewController: WebViewController.fromPlatform(web),
        googleServerClientId: null,
        kakaoNativeAppKey: null,
        serviceCountry: country,
        apiBaseUrl: refreshClient == null ? null : 'https://qa2.api.sazo.shop',
        testDeviceHeaders: const {},
        testSsoExchangeFactory: refreshClient == null
            ? null
            : (api, domain) => SsoExchange(
                apiBaseUrl: api,
                domainType: domain,
                client: refreshClient,
              ),
        webOrigin: 'https://qa2.sazo.shop',
        webDocumentNavigationGeneration: 1,
        onAuthTrace: traces.add,
        testDeviceInfoOperation: () async => {
          'type': 'DEVICE_INFO',
          'data': <String, Object?>{},
        },
      ),
    ))!;
    addTearDown(channel.dispose);
    final harness = _Harness(channel, web, traces, tester);
    await harness.send('DEVICE_INFO', {
      ..._offer(),
      'documentId': 'document-1',
      'requestId': 'snapshot-1',
    });
    return harness;
  }

  Future<void> dispose() async {
    await tester.runAsync(() async {
      channel.dispose();
      await const PendingAuthAttemptStore().clearIfMatches(
        attemptId: 'cleanup-barrier',
        authRevision: -1,
        serviceCountry: 'JP',
      );
    });
  }

  Future<void> send(String type, Map<String, Object?> data) async {
    await tester.runAsync(
      () => channel.onMessageReceived(
        JavaScriptMessage(message: jsonEncode({'type': type, 'data': data})),
      ),
    );
  }

  Map<String, Object?> request({String provider = 'JAPAN_DB'}) => {
    ..._offer(),
    'accessToken': _token(provider),
    'refreshToken': _refreshToken,
    'provider': 'JAPAN_DB',
    'serviceCountry': 'JP',
    'domainType': 'sazo-japan-shop',
    'documentId': 'document-1',
    'requestId': 'import-1',
    'authSessionId': _sessionId,
    'authRevision': 0,
    'serviceContextGeneration': 0,
    'navigationGeneration': 1,
    'returnTo': '/ja/detail/123?source=login',
  };

  List<Map<String, dynamic>> get ready =>
      web.messages.where((m) => m['type'] == 'AUTH_TOKENS_READY').toList();
  Map<String, dynamic> get lastError =>
      web.messages.lastWhere((m) => m['type'] == 'AUTH_ERROR')['data']
          as Map<String, dynamic>;
}

int _testGeneration = 0;
String get _sessionId => 'member-$_testGeneration';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    _testGeneration++;
    SharedPreferences.setMockInitialValues({});
    ProcessAuthAttemptCoordinator.shared.resetForAuthBoundary();
  });
  tearDown(ProcessAuthAttemptCoordinator.shared.resetForAuthBoundary);

  testWidgets(
    'device snapshot and import persist JP before correlated tokens-ready',
    (tester) async {
      final h = await _Harness.create(tester);
      final info = h.web.messages.single['data'] as Map;
      expect(info['authCapabilities'], contains('webSessionImport'));
      expect(info['requestId'], 'snapshot-1');
      expect(info['authRevision'], 0);
      expect(info['serviceContextGeneration'], 0);
      expect(info['navigationGeneration'], 1);
      final request = h.request();
      await h.send('AUTH_WEB_SESSION_IMPORT', request);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(refreshTokenKeyFor('JP')), _refreshToken);
      expect(prefs.getString(refreshTokenKeyFor('KR')), isNull);
      expect(prefs.getString(refreshTokenKeyFor('GLOBAL')), isNull);
      expect(
        await tester.runAsync(
          () => const AuthRevisionStore().current(serviceCountry: 'JP'),
        ),
        1,
      );
      expect(h.web.messages.map((m) => m['type']), [
        'DEVICE_INFO',
        'AUTH_ATTEMPT_STARTED',
        'AUTH_TOKENS_READY',
      ]);
      final result = h.ready.single['data'] as Map;
      expect(result['authRevision'], 1);
      expect(result['requestId'], 'import-1');
      expect(result['authSessionId'], _sessionId);
      expect(result['serviceCountry'], 'JP');
      expect(result['provider'], 'JAPAN_DB');
      expect(jsonEncode(h.traces), isNot(contains(_refreshToken)));
      expect(jsonEncode(h.traces), isNot(contains(request['accessToken'])));
      await h.dispose();
    },
  );

  for (final provider in [
    'GOOGLE',
    'APPLE',
    'KAKAO',
    'NAVER',
    'DB',
    'GLOBAL_DB',
    'GLOBAL_GOOGLE',
    'JAPAN_GOOGLE',
  ]) {
    testWidgets('$provider token cannot import as JAPAN_DB', (tester) async {
      final h = await _Harness.create(tester);
      await h.send('AUTH_WEB_SESSION_IMPORT', h.request(provider: provider));
      expect(h.ready, isEmpty);
      expect(
        h.lastError['failureCode'],
        'WEB_SESSION_IMPORT_PROVIDER_MISMATCH',
      );
      expect(h.lastError.containsKey('accessToken'), isFalse);
      expect(h.lastError.containsKey('refreshToken'), isFalse);
      expect(
        await tester.runAsync(
          () => const AuthRevisionStore().current(serviceCountry: 'JP'),
        ),
        0,
      );
      expect(
        (await SharedPreferences.getInstance()).getString(
          refreshTokenKeyFor('JP'),
        ),
        isNull,
      );
    });
  }

  for (final invalid in <String, Map<String, String>>{
    'KR refresh provider': {'refreshToken': _token('DB', kind: 'refresh')},
    'GLOBAL refresh provider': {
      'refreshToken': _token('GLOBAL_DB', kind: 'refresh'),
    },
    'JP social refresh provider': {
      'refreshToken': _token('JAPAN_GOOGLE', kind: 'refresh'),
    },
    'different JP refresh user': {
      'refreshToken': _token(
        'JAPAN_DB',
        userId: 'different-user',
        kind: 'refresh',
      ),
    },
    'missing refresh user': {
      'refreshToken': _token('JAPAN_DB', userId: null, kind: 'refresh'),
    },
    'empty refresh user': {
      'refreshToken': _token('JAPAN_DB', userId: '', kind: 'refresh'),
    },
    'whitespace refresh user': {
      'refreshToken': _token('JAPAN_DB', userId: '  ', kind: 'refresh'),
    },
    'missing access user': {'accessToken': _token('JAPAN_DB', userId: null)},
    'empty access user': {'accessToken': _token('JAPAN_DB', userId: '')},
    'missing both users': {
      'accessToken': _token('JAPAN_DB', userId: null),
      'refreshToken': _token('JAPAN_DB', userId: null, kind: 'refresh'),
    },
    'malformed refresh JWT': {'refreshToken': 'not-a-jwt'},
    'malformed refresh payload': {'refreshToken': 'e30.not-valid-json.fixture'},
  }.entries) {
    testWidgets('${invalid.key} cannot import JP session', (tester) async {
      final h = await _Harness.create(tester);
      await h.send('AUTH_WEB_SESSION_IMPORT', {
        ...h.request(),
        ...invalid.value,
      });
      expect(h.ready, isEmpty);
      expect(
        h.web.messages.any((m) => m['type'] == 'AUTH_ATTEMPT_STARTED'),
        isFalse,
      );
      expect(
        h.lastError['failureCode'],
        'WEB_SESSION_IMPORT_PROVIDER_MISMATCH',
      );
      expect(h.lastError.containsKey('accessToken'), isFalse);
      expect(h.lastError.containsKey('refreshToken'), isFalse);
      expect(
        await tester.runAsync(
          () => const AuthRevisionStore().current(serviceCountry: 'JP'),
        ),
        0,
      );
      expect(
        (await SharedPreferences.getInstance()).getString(
          refreshTokenKeyFor('JP'),
        ),
        isNull,
      );
    });
  }

  for (final missing in [
    'accessToken',
    'refreshToken',
    'requestId',
    'documentId',
    'authRevision',
    'serviceContextGeneration',
    'navigationGeneration',
    'returnTo',
    'authCapabilities',
  ]) {
    testWidgets('missing $missing fails without starting an attempt', (
      tester,
    ) async {
      final h = await _Harness.create(tester);
      await h.send('AUTH_WEB_SESSION_IMPORT', h.request()..remove(missing));
      expect(h.ready, isEmpty);
      expect(h.lastError['failureCode'], 'WEB_SESSION_IMPORT_INVALID');
      expect(
        await tester.runAsync(
          () => const AuthRevisionStore().current(serviceCountry: 'JP'),
        ),
        0,
      );
    });
  }

  for (final destination in [
    'https://attacker.example/path',
    '//attacker.example/path',
    '/auth/signin',
    '/auth/reset',
    'javascript:alert(1)',
    '/ja/auth/signup?redirect=https%3A%2F%2Fattacker.example%2Fcart',
    '/ja/auth/signup?redirect=%2Fauth%2Fsignin',
  ]) {
    testWidgets('unsafe destination $destination is rejected', (tester) async {
      final h = await _Harness.create(tester);
      await h.send(
        'AUTH_WEB_SESSION_IMPORT',
        h.request()..['returnTo'] = destination,
      );
      expect(h.lastError['failureCode'], 'WEB_SESSION_IMPORT_INVALID');
      expect(h.ready, isEmpty);
    });
  }

  testWidgets(
    'lost result retry replays tokens without another revision or write',
    (tester) async {
      final h = await _Harness.create(tester);
      h.web.dropTokenReplies = 1;
      final request = h.request();
      await h.send('AUTH_WEB_SESSION_IMPORT', request);
      expect(h.ready, isEmpty);
      await h.send('AUTH_WEB_SESSION_IMPORT', request);
      expect(h.ready, hasLength(1));
      expect(
        await tester.runAsync(
          () => const AuthRevisionStore().current(serviceCountry: 'JP'),
        ),
        1,
      );
      await h.send('AUTH_WEB_SESSION_IMPORT', {
        ...request,
        'refreshToken': _token('JAPAN_DB', kind: 'other-refresh'),
      });
      expect(h.lastError['failureCode'], 'WEB_SESSION_IMPORT_STALE');
      expect(
        (await SharedPreferences.getInstance()).getString(
          refreshTokenKeyFor('JP'),
        ),
        _refreshToken,
      );
      await h.dispose();
    },
  );

  testWidgets(
    'timeout cancellation deletes stored session and rejects late delivery retry',
    (tester) async {
      final h = await _Harness.create(tester);
      h.web.dropTokenReplies = 1;
      final request = h.request();
      await h.send('AUTH_WEB_SESSION_IMPORT', request);
      expect(h.ready, isEmpty);
      await h.send('REFRESH_TOKEN_DELETE', {
        ..._offer(),
        'authSessionId': _sessionId,
        'requestId': 'import-1',
        'documentId': 'document-1',
        'authRevision': 1,
        'provider': 'JAPAN_DB',
        'revokeNativeSso': false,
        'source': 'web-session-import-cancel',
      });
      await h.send('AUTH_WEB_SESSION_IMPORT', request);
      expect(h.ready, isEmpty);
      expect(h.lastError['failureCode'], 'WEB_SESSION_IMPORT_STALE');
      expect(
        (await SharedPreferences.getInstance()).getString(
          refreshTokenKeyFor('JP'),
        ),
        isNull,
      );
      expect(
        await tester.runAsync(
          () => const AuthRevisionStore().current(serviceCountry: 'JP'),
        ),
        2,
      );
      await h.dispose();
    },
  );

  testWidgets(
    'storage failure removes optimistic token and never delivers success',
    (tester) async {
      SharedPreferencesStorePlatform.instance = _FailRefreshStore();
      final h = await _Harness.create(tester);
      await h.send('AUTH_WEB_SESSION_IMPORT', h.request());
      expect(h.ready, isEmpty);
      expect(h.lastError['failureCode'], 'WEB_SESSION_IMPORT_PERSIST_FAILED');
      expect(
        (await SharedPreferences.getInstance()).getString(
          refreshTokenKeyFor('JP'),
        ),
        isNull,
      );
    },
  );

  testWidgets(
    'thrown storage failure removes optimistic session before error',
    (tester) async {
      SharedPreferencesStorePlatform.instance = _FailRefreshStore(
        throwAfterWrite: true,
      );
      final h = await _Harness.create(tester);
      await h.send('AUTH_WEB_SESSION_IMPORT', h.request());
      expect(h.ready, isEmpty);
      expect(h.lastError['failureCode'], 'WEB_SESSION_IMPORT_PERSIST_FAILED');
      expect(
        (await SharedPreferences.getInstance()).getString(
          refreshTokenKeyFor('JP'),
        ),
        isNull,
      );
      await h.dispose();
    },
  );

  for (final boundary in [
    'logout',
    'otherLogin',
    'navigation',
    'service',
    'document',
  ]) {
    testWidgets('$boundary invalidates an API-start snapshot', (tester) async {
      final h = await _Harness.create(tester);
      final request = h.request();
      switch (boundary) {
        case 'logout':
          await h.send('REFRESH_TOKEN_DELETE', {
            ..._offer(),
            'provider': 'JAPAN_DB',
          });
        case 'otherLogin':
          await tester.runAsync(
            () => const AuthRevisionStore().next(serviceCountry: 'JP'),
          );
        case 'navigation':
          h.channel.updateWebDocumentNavigationGeneration(2);
        case 'service':
          h.channel.updateServiceContext(
            serviceCountry: 'KR',
            apiBaseUrl: null,
          );
          h.channel.updateServiceContext(
            serviceCountry: 'JP',
            apiBaseUrl: null,
          );
        case 'document':
          request['documentId'] = 'old-document';
      }
      await h.send('AUTH_WEB_SESSION_IMPORT', request);
      expect(h.ready, isEmpty);
      expect(h.lastError['failureCode'], 'WEB_SESSION_IMPORT_STALE');
      expect(
        (await SharedPreferences.getInstance()).getString(
          refreshTokenKeyFor('JP'),
        ),
        isNull,
      );
    });
  }

  testWidgets(
    'restart reads JP session, DB logout deletes it and invalidates replay without SDK revoke',
    (tester) async {
      final h = await _Harness.create(tester);
      await h.send('AUTH_WEB_SESSION_IMPORT', h.request());
      await h.dispose();
      final fresh = await _Harness.create(tester);
      await fresh.send('REFRESH_TOKEN_READ', {
        ..._offer(),
        'requestId': 'read-1',
        'documentId': 'document-1',
      });
      final read =
          fresh.web.messages.lastWhere(
                (m) => m['type'] == 'REFRESH_TOKEN_READ',
              )['data']
              as Map;
      expect(read['refreshToken'], _refreshToken);
      final output = <String>[];
      await runZoned(
        () => fresh.send('REFRESH_TOKEN_DELETE', {
          ..._offer(),
          'provider': 'JAPAN_DB',
          'revokeNativeSso': true,
        }),
        zoneSpecification: ZoneSpecification(
          print: (_, _, _, line) => output.add(line),
        ),
      );
      expect(output.any((s) => s.contains('native SSO logout start')), isFalse);
      expect(
        (await SharedPreferences.getInstance()).getString(
          refreshTokenKeyFor('JP'),
        ),
        isNull,
      );
      await fresh.send('AUTH_WEB_SESSION_IMPORT', h.request());
      expect(fresh.ready, isEmpty);
      expect(fresh.lastError['failureCode'], 'WEB_SESSION_IMPORT_STALE');
    },
  );

  testWidgets(
    'restarted bridge refresh exchange restores JAPAN_DB tokens-ready',
    (tester) async {
      final h = await _Harness.create(tester);
      await h.send('AUTH_WEB_SESSION_IMPORT', h.request());
      await h.dispose();
      final requests = <http.Request>[];
      final client = MockClient((request) async {
        requests.add(request);
        if (request.url.path.endsWith('/token/refresh')) {
          expect(jsonDecode(request.body)['refreshToken'], _refreshToken);
          return http.Response(
            jsonEncode({
              'data': {
                'accessToken': _token('JAPAN_DB'),
                'refreshToken': 'rotated-fixture',
              },
            }),
            200,
          );
        }
        return http.Response(
          jsonEncode({
            'data': {'user_id': 'member-fixture'},
          }),
          200,
        );
      });
      final fresh = await _Harness.create(tester, refreshClient: client);
      await fresh.send('REFRESH_TOKEN_READ', {
        ..._offer(),
        'requestId': 'read-1',
        'documentId': 'document-1',
      });
      expect(fresh.ready, hasLength(1));
      expect(
        (fresh.ready.single['data'] as Map)['accessToken'],
        _token('JAPAN_DB'),
      );
      expect((fresh.ready.single['data'] as Map)['serviceCountry'], 'JP');
      expect(
        (await SharedPreferences.getInstance()).getString(
          refreshTokenKeyFor('JP'),
        ),
        'rotated-fixture',
      );
      expect(requests.first.url.host, 'qa2.api.sazo.shop');
      expect(
        requests.every((r) => r.headers['x-domain-type'] == 'sazo-japan-shop'),
        isTrue,
      );
      await fresh.dispose();
    },
  );

  testWidgets(
    'signup requires matching native onboarding route before original cart commit',
    (tester) async {
      final h = await _Harness.create(tester);
      await h.send('AUTH_WEB_SESSION_IMPORT', {
        ...h.request(),
        'returnTo': '/ja/auth/signup?redirect=%2Fja%2Fcart',
      });
      final commit = <String, Object?>{
        ..._offer(),
        'authSessionId': _sessionId,
        'requestId': 'import-1',
        'documentId': 'document-target',
        'authRevision': 1,
        'visibilityState': 'visible',
        'isAccessTokenBind': true,
        'userIdsMatch': true,
        'dockModel': 'mypage',
        'dockHref': '/account',
        'pathname': '/ja/auth/signup',
      };
      h.web.url = 'https://attacker.example/ja/auth/signup';
      await h.send('AUTH_ONBOARDING_READY', commit);
      expect(
        h.traces.any((t) => t['resultCode'] == 'onboarding_ready'),
        isFalse,
      );
      h.web.url = 'https://qa2.m.sazo.shop/ja/auth/signup';
      await h.send('AUTH_ONBOARDING_READY', commit);
      expect(
        h.traces.any((t) => t['resultCode'] == 'onboarding_ready'),
        isTrue,
      );
      h.web.url = 'https://qa2.m.sazo.shop/ja/cart';
      await h.send('AUTH_UI_COMMITTED', {...commit, 'pathname': '/ja/cart'});
      expect(
        await const AuthTerminalStore().matchesSuccess(
          authSessionId: _sessionId,
          authRevision: 1,
          serviceCountry: 'JP',
        ),
        isTrue,
      );
      await h.dispose();
    },
  );

  testWidgets(
    'UI commit accepts only this imported destination and actual native origin',
    (tester) async {
      final h = await _Harness.create(tester);
      await h.send('AUTH_WEB_SESSION_IMPORT', h.request());
      final commit = <String, Object?>{
        ..._offer(),
        'authSessionId': _sessionId,
        'requestId': 'import-1',
        'documentId': 'document-target',
        'authRevision': 1,
        'visibilityState': 'visible',
        'isAccessTokenBind': true,
        'userIdsMatch': true,
        'dockModel': 'mypage',
        'dockHref': '/account',
        'pathname': '/ja/detail/123',
      };
      h.web.url = 'https://attacker.example/ja/detail/123';
      await h.send('AUTH_UI_COMMITTED', commit);
      expect(
        await const AuthTerminalStore().matchesSuccess(
          authSessionId: _sessionId,
          authRevision: 1,
          serviceCountry: 'JP',
        ),
        isFalse,
      );
      h.web.url = 'https://qa2.m.sazo.shop/ja/detail/999';
      await h.send('AUTH_UI_COMMITTED', commit);
      expect(
        await const AuthTerminalStore().matchesSuccess(
          authSessionId: _sessionId,
          authRevision: 1,
          serviceCountry: 'JP',
        ),
        isFalse,
      );
      h.web.url = 'https://qa2.m.sazo.shop/ja/detail/123';
      await h.send('AUTH_UI_COMMITTED', commit);
      expect(
        await const AuthTerminalStore().matchesSuccess(
          authSessionId: _sessionId,
          authRevision: 1,
          serviceCountry: 'JP',
        ),
        isTrue,
        reason: jsonEncode(h.traces),
      );
      await h.dispose();
    },
  );
}
