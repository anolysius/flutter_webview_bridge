import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webview_bridge/flutter_webview_bridge.dart';
import 'package:flutter_webview_bridge/src/auth/sso_exchange.dart';
import 'package:flutter_webview_bridge/src/bridge/auth/auth_protocol_negotiation.dart';
import 'package:flutter_webview_bridge/src/bridge/auth/auth_terminal_store.dart';
import 'package:flutter_webview_bridge/src/bridge/auth/pending_auth_attempt_store.dart';
import 'package:flutter_webview_bridge/src/bridge/auth/process_auth_attempt_coordinator.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

/// 콜드 스타트 자동 복구(auto_refresh)가 홈이 아닌 첫 화면(푸시·딥링크)에서 끝나는 경우.
///
/// 웹이 [autoRefreshDocumentCommitCapability] 를 알렸을 때만 자동 복구를 시작한 그 문서에서
/// 완료를 인정한다. 알리지 않은 웹, 직접 로그인, 인증 화면은 지금처럼 홈만 인정한다.
class _WebView extends PlatformWebViewController {
  _WebView()
    : super.implementation(const PlatformWebViewControllerCreationParams());
  final messages = <Map<String, dynamic>>[];
  String url = 'https://qa2.m.sazo.shop/ja';

  @override
  Future<String?> currentUrl() async => url;

  @override
  Future<Object> runJavaScriptReturningResult(String script) async {
    final encoded = RegExp(r'var payload = (.*);').firstMatch(script)?.group(1);
    if (encoded != null) {
      messages.add(
        jsonDecode(jsonDecode(encoded) as String) as Map<String, dynamic>,
      );
    }
    return true;
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

Map<String, Object?> _offer({bool documentCommit = false}) => {
  'protocolVersion': 3,
  'maxProtocolVersion': 3,
  'authCapabilities': [
    ...requiredAuthProtocolV3Capabilities,
    criticalAuthDeliveryAckCapability,
    webSessionImportCapability,
    if (documentCommit) autoRefreshDocumentCommitCapability,
  ],
};

class _Harness {
  _Harness(this.channel, this.web, this.tester);
  final WidgetTester tester;
  final FlutterWebViewBridgeJavaScriptChannel channel;
  final _WebView web;
  final prints = <String>[];

  static Future<_Harness> create(
    WidgetTester tester, {
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
    final channel = (await tester.runAsync(
      () async => FlutterWebViewBridgeJavaScriptChannel(
        context: context,
        webViewController: WebViewController.fromPlatform(web),
        googleServerClientId: null,
        kakaoNativeAppKey: null,
        serviceCountry: 'JP',
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
        testDeviceInfoOperation: () async => {
          'type': 'DEVICE_INFO',
          'data': <String, Object?>{},
        },
      ),
    ))!;
    addTearDown(channel.dispose);
    final harness = _Harness(channel, web, tester);
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

  Future<void> send(String type, Object? data) async {
    await runZoned(
      () => tester.runAsync(
        () => channel.onMessageReceived(
          JavaScriptMessage(message: jsonEncode({'type': type, 'data': data})),
        ),
      ),
      zoneSpecification: ZoneSpecification(
        print: (_, _, _, line) => prints.add(line),
      ),
    );
  }

  Map<String, dynamic> get ready =>
      web.messages.lastWhere((m) => m['type'] == 'AUTH_TOKENS_READY')['data']
          as Map<String, dynamic>;

  bool get confirmAccepted =>
      prints.any((p) => p.contains('home confirm accepted'));
  bool get confirmKept =>
      prints.any((p) => p.contains('keep B2 watchdog — non-home confirm'));
}

int _generation = 0;
String get _importSessionId => 'member-$_generation';

/// 이전 실행에서 로그인해 둔 상태(저장된 refresh token)를 만든다.
Future<void> _seedLoggedIn(WidgetTester tester) async {
  final h = await _Harness.create(tester);
  h.web.url = 'https://qa2.m.sazo.shop/auth/signin';
  await h.send('AUTH_WEB_SESSION_IMPORT', {
    ..._offer(),
    'accessToken': _token('JAPAN_DB'),
    'refreshToken': _refreshToken,
    'provider': 'JAPAN_DB',
    'serviceCountry': 'JP',
    'domainType': 'sazo-japan-shop',
    'documentId': 'document-1',
    'requestId': 'import-1',
    'authSessionId': _importSessionId,
    'authRevision': 0,
    'serviceContextGeneration': 0,
    'navigationGeneration': 1,
    'returnTo': '/ja/detail/123?source=login',
  });
  await h.dispose();
}

http.Client _refreshClient() => MockClient((request) async {
  if (request.url.path.endsWith('/token/refresh')) {
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

/// 앱 재시작 → 첫 문서([url])에서 웹이 자동 복구를 요청하고 AUTH_TOKENS_READY 를 받는다.
Future<_Harness> _coldStartAutoRefresh(
  WidgetTester tester, {
  required String url,
  required bool documentCommit,
}) async {
  await _seedLoggedIn(tester);
  final h = await _Harness.create(tester, refreshClient: _refreshClient());
  h.web.url = url;
  await h.send('REFRESH_TOKEN_READ', {
    ..._offer(documentCommit: documentCommit),
    'requestId': 'read-$_generation',
    'documentId': 'document-1',
  });
  expect(h.ready["accessToken"], _token("JAPAN_DB"));
  return h;
}

/// 웹이 토큰 저장 후 보내는 확인(REFRESH_TOKEN_WRITE object payload).
Map<String, Object?> _confirm(
  _Harness h, {
  required String pathname,
  String documentId = 'document-1',
  bool documentCommit = true,
}) {
  final stripped =
      pathname.replaceFirst(RegExp(r'^/(ko|en|ja)(?=/|$)'), '').isEmpty
      ? '/'
      : pathname.replaceFirst(RegExp(r'^/(ko|en|ja)(?=/|$)'), '');
  return {
    ..._offer(documentCommit: documentCommit),
    'refreshToken': 'rotated-fixture',
    'authSessionId': h.ready['authSessionId'],
    'requestId': h.ready['requestId'],
    'authRevision': h.ready['authRevision'],
    'documentId': documentId,
    'pathname': pathname,
    'webPathname': stripped,
    'isHomeDocument': stripped == '/',
  };
}

/// 웹이 화면에 로그인 상태를 반영한 뒤 보내는 최종 완료(AUTH_UI_COMMITTED).
Map<String, Object?> _uiCommit(
  _Harness h, {
  required String pathname,
  String documentId = 'document-1',
}) => {
  'protocolVersion': 3,
  'requestId': h.ready['requestId'],
  'authSessionId': h.ready['authSessionId'],
  'authRevision': h.ready['authRevision'],
  'documentId': documentId,
  'pathname': pathname,
  'visibilityState': 'visible',
  'isAccessTokenBind': true,
  'userIdsMatch': true,
  'dockModel': 'mypage',
  'dockHref': '/account',
};

Future<bool> _terminalSucceeded(_Harness h) =>
    const AuthTerminalStore().matchesSuccess(
      authSessionId: h.ready['authSessionId'] as String,
      authRevision: h.ready['authRevision'] as int,
      serviceCountry: 'JP',
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() {
    _generation++;
    SharedPreferences.setMockInitialValues({});
    ProcessAuthAttemptCoordinator.shared.resetForAuthBoundary();
  });
  tearDown(ProcessAuthAttemptCoordinator.shared.resetForAuthBoundary);

  const orders = 'https://qa2.m.sazo.shop/ja/account/orders';

  group('웹이 capability 를 알리지 않으면 지금과 같다 (홈만 인정)', () {
    testWidgets('홈이 아닌 첫 화면의 확인은 받지 않고 watchdog 을 유지한다', (tester) async {
      final h = await _coldStartAutoRefresh(
        tester,
        url: orders,
        documentCommit: false,
      );
      await h.send(
        'REFRESH_TOKEN_WRITE',
        _confirm(h, pathname: '/ja/account/orders', documentCommit: false),
      );
      expect(h.confirmKept, isTrue);
      expect(h.confirmAccepted, isFalse);
      await h.dispose();
    });

    testWidgets('홈이 아닌 화면의 최종 완료는 거절한다', (tester) async {
      final h = await _coldStartAutoRefresh(
        tester,
        url: orders,
        documentCommit: false,
      );
      await h.send(
        'AUTH_UI_COMMITTED',
        _uiCommit(h, pathname: '/ja/account/orders'),
      );
      expect(await tester.runAsync(() => _terminalSucceeded(h)), isFalse);
      await h.dispose();
    });

    testWidgets('홈 첫 화면은 확인·최종 완료 모두 받는다', (tester) async {
      final h = await _coldStartAutoRefresh(
        tester,
        url: 'https://qa2.m.sazo.shop/ja',
        documentCommit: false,
      );
      await h.send(
        'REFRESH_TOKEN_WRITE',
        _confirm(h, pathname: '/ja', documentCommit: false),
      );
      expect(h.confirmAccepted, isTrue);
      await h.send('AUTH_UI_COMMITTED', _uiCommit(h, pathname: '/ja'));
      expect(await tester.runAsync(() => _terminalSucceeded(h)), isTrue);
      await h.dispose();
    });
  });

  group('웹이 capability 를 알리면 자동 복구를 시작한 문서에서 완료를 인정한다', () {
    testWidgets('딥링크 첫 화면의 확인으로 watchdog 을 끝내고 최종 완료를 받는다', (tester) async {
      final h = await _coldStartAutoRefresh(
        tester,
        url: orders,
        documentCommit: true,
      );
      await h.send(
        'REFRESH_TOKEN_WRITE',
        _confirm(h, pathname: '/ja/account/orders'),
      );
      expect(h.confirmAccepted, isTrue);
      expect(h.confirmKept, isFalse);
      expect(h.prints.any((p) => p.contains('load home')), isFalse);

      await h.send(
        'AUTH_UI_COMMITTED',
        _uiCommit(h, pathname: '/ja/account/orders'),
      );
      expect(await tester.runAsync(() => _terminalSucceeded(h)), isTrue);
      await h.dispose();
    });

    testWidgets('홈 첫 화면은 지금과 같이 받는다', (tester) async {
      final h = await _coldStartAutoRefresh(
        tester,
        url: 'https://qa2.m.sazo.shop/ja',
        documentCommit: true,
      );
      await h.send('REFRESH_TOKEN_WRITE', _confirm(h, pathname: '/ja'));
      expect(h.confirmAccepted, isTrue);
      await h.send('AUTH_UI_COMMITTED', _uiCommit(h, pathname: '/ja'));
      expect(await tester.runAsync(() => _terminalSucceeded(h)), isTrue);
      await h.dispose();
    });

    testWidgets('다른 문서에서 온 확인·완료는 받지 않는다', (tester) async {
      final h = await _coldStartAutoRefresh(
        tester,
        url: orders,
        documentCommit: true,
      );
      await h.send(
        'REFRESH_TOKEN_WRITE',
        _confirm(h, pathname: '/ja/account/orders', documentId: 'document-2'),
      );
      expect(h.confirmAccepted, isFalse);
      expect(h.confirmKept, isTrue);
      await h.send(
        'AUTH_UI_COMMITTED',
        _uiCommit(h, pathname: '/ja/account/orders', documentId: 'document-2'),
      );
      expect(await tester.runAsync(() => _terminalSucceeded(h)), isFalse);
      await h.dispose();
    });

    testWidgets('인증 화면(/auth/*)은 인정하지 않는다', (tester) async {
      final h = await _coldStartAutoRefresh(
        tester,
        url: 'https://qa2.m.sazo.shop/ja/auth/signin',
        documentCommit: true,
      );
      await h.send(
        'REFRESH_TOKEN_WRITE',
        _confirm(h, pathname: '/ja/auth/signin'),
      );
      expect(h.confirmAccepted, isFalse);
      expect(h.confirmKept, isTrue);
      await h.send(
        'AUTH_UI_COMMITTED',
        _uiCommit(h, pathname: '/ja/auth/signin'),
      );
      expect(await tester.runAsync(() => _terminalSucceeded(h)), isFalse);
      await h.dispose();
    });

    testWidgets('앱이 보는 화면과 웹 경로가 다르면 최종 완료를 거절한다', (tester) async {
      final h = await _coldStartAutoRefresh(
        tester,
        url: orders,
        documentCommit: true,
      );
      h.web.url = 'https://qa2.m.sazo.shop/ja/cart';
      await h.send(
        'AUTH_UI_COMMITTED',
        _uiCommit(h, pathname: '/ja/account/orders'),
      );
      expect(await tester.runAsync(() => _terminalSucceeded(h)), isFalse);
      await h.dispose();
    });
  });

  testWidgets('직접 로그인(웹 세션 가져오기)은 capability 가 있어도 목적지만 인정한다', (tester) async {
    final h = await _Harness.create(tester);
    h.web.url = 'https://qa2.m.sazo.shop/ja/account/orders';
    await h.send('AUTH_WEB_SESSION_IMPORT', {
      ..._offer(documentCommit: true),
      'accessToken': _token('JAPAN_DB'),
      'refreshToken': _refreshToken,
      'provider': 'JAPAN_DB',
      'serviceCountry': 'JP',
      'domainType': 'sazo-japan-shop',
      'documentId': 'document-1',
      'requestId': 'import-1',
      'authSessionId': _importSessionId,
      'authRevision': 0,
      'serviceContextGeneration': 0,
      'navigationGeneration': 1,
      'returnTo': '/ja/detail/123',
    });
    await h.send('AUTH_UI_COMMITTED', {
      ..._uiCommit(h, pathname: '/ja/account/orders'),
      'requestId': 'import-1',
      'authSessionId': _importSessionId,
      'authRevision': 1,
    });
    expect(
      await tester.runAsync(
        () => const AuthTerminalStore().matchesSuccess(
          authSessionId: _importSessionId,
          authRevision: 1,
          serviceCountry: 'JP',
        ),
      ),
      isFalse,
    );
    await h.dispose();
  });
}
