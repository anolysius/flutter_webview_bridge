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

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets(
    'confirmation 영구 대기 중 buffered mutation은 explicit retry 직렬 큐를 막지 않는다',
    (tester) async {
      final context = await _mountedContext(tester);
      final platformController = _FakePlatformWebViewController();
      var clearCalls = 0;
      var providerCalls = 0;
      final providerEntered = Completer<void>();
      final channel = FlutterWebViewBridgeJavaScriptChannel(
        context: context,
        webViewController: WebViewController.fromPlatform(platformController),
        googleServerClientId: null,
        kakaoNativeAppKey: null,
        serviceCountry: 'KR',
        apiBaseUrl: null,
        webOrigin: 'https://qa.m.sazo.kr',
        webDocumentNavigationGeneration: 1,
        testClearAllRefreshTokens: () async {
          clearCalls += 1;
          if (clearCalls == 1) {
            throw StateError('first cleanup fails');
          }
        },
        testAuthProviderOperation: (type, _, _) async {
          providerCalls += 1;
          if (!providerEntered.isCompleted) providerEntered.complete();
          return {
            'type': type.value,
            'data': {'idToken': 'explicit-retry-result'},
          };
        },
      );
      addTearDown(channel.dispose);
      final lineage = <String, Object?>{
        'protocolVersion': 3,
        'maxProtocolVersion': 3,
        'authCapabilities': const [
          'softConvergenceDeadline',
          'onboardingHandoff',
          'reauthRequiredCommit',
        ],
        'authSessionId': 'attempt-explicit-retry',
        'requestId': 'request-explicit-retry',
        'documentId': 'document-explicit-retry',
        'authRevision': 1,
        'provider': 'KAKAO',
      };

      await channel.onMessageReceived(
        _message('AUTH_CONTEXT_MISMATCH_CLEAR_AND_RESTART', {
          ...lineage,
          'idempotencyKey': 'restart-cleanup-fails',
          'expectedServiceCountry': 'KR',
          'actualServiceCountry': 'GLOBAL',
        }),
      );
      expect(clearCalls, 1);

      final bufferedRead = channel.onMessageReceived(
        _message('REFRESH_TOKEN_READ', lineage),
      );
      await tester.pump();
      final explicitRetry = channel.onMessageReceived(
        _message('KAKAO_SIGN_IN_LOGIN', lineage),
      );
      await tester.runAsync(
        () => providerEntered.future.timeout(const Duration(seconds: 2)),
      );
      await tester.pump();

      expect(
        providerCalls,
        1,
        reason: 'buffered read must not head-of-line block explicit retry',
      );
      expect(clearCalls, 2);
      await Future.wait([bufferedRead, explicitRetry]);
      channel.dispose();
    },
  );
}
