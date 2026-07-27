import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webview_bridge/flutter_webview_bridge.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

class _FakePlatformWebViewController extends PlatformWebViewController {
  _FakePlatformWebViewController()
    : super.implementation(const PlatformWebViewControllerCreationParams());

  @override
  Future<Object> runJavaScriptReturningResult(String javaScript) async => true;
}

Future<BuildContext> _mountedContext(WidgetTester tester) async {
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
  return context;
}

JavaScriptMessage _message(String type, Object? data) =>
    JavaScriptMessage(message: jsonEncode({'type': type, 'data': data}));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('같은 국가 navigation을 넘은 구웹 token delete는 기존 국가 key를 삭제한다', (
    tester,
  ) async {
    SharedPreferences.setMockInitialValues({
      'flutter_webview_bridge_refresh_token': 'delete-on-kr',
    });
    final context = await _mountedContext(tester);
    final platformController = _FakePlatformWebViewController();
    final blockingStatusEntered = Completer<void>();
    final releaseBlockingStatus = Completer<void>();
    final channel = FlutterWebViewBridgeJavaScriptChannel(
      context: context,
      webViewController: WebViewController.fromPlatform(platformController),
      googleServerClientId: null,
      kakaoNativeAppKey: null,
      serviceCountry: 'KR',
      apiBaseUrl: 'https://qa.api.sazo.kr',
      webDocumentNavigationGeneration: 1,
      onAuthContextStatus: (status) async {
        if (status['idempotencyKey'] != 'same-country-delete-blocking') return;
        blockingStatusEntered.complete();
        await releaseBlockingStatus.future;
      },
    );

    final blockingStatus = channel.onMessageReceived(
      _message('AUTH_CONTEXT_STATUS', {
        'idempotencyKey': 'same-country-delete-blocking',
        'documentId': 'document-logout',
        'status': 'validationPending',
      }),
    );
    await blockingStatusEntered.future;
    final queuedLegacyDelete = channel.onMessageReceived(
      _message('REFRESH_TOKEN_DELETE', null),
    );

    channel.updateWebDocumentNavigationGeneration(2);
    releaseBlockingStatus.complete();
    await Future.wait([blockingStatus, queuedLegacyDelete]);

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getString('flutter_webview_bridge_refresh_token'), isNull);
    channel.dispose();
  });
}
