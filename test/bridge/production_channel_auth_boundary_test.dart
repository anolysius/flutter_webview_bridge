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

  final List<String> evaluatedScripts = <String>[];

  @override
  Future<Object> runJavaScriptReturningResult(String javaScript) async {
    evaluatedScripts.add(javaScript);
    return true;
  }
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

JavaScriptMessage _message(String type, Map<String, Object?> data) =>
    JavaScriptMessage(message: jsonEncode({'type': type, 'data': data}));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets(
    'provider await 중 direct context update는 current 결과와 queued retired mutation을 폐기한다',
    (tester) async {
      final context = await _mountedContext(tester);
      final platformController = _FakePlatformWebViewController();
      final providerEntered = Completer<void>();
      final providerResult = Completer<Map<String, Object?>>();
      final traces = <Map<String, Object?>>[];
      final channel = FlutterWebViewBridgeJavaScriptChannel(
        context: context,
        webViewController: WebViewController.fromPlatform(platformController),
        googleServerClientId: null,
        kakaoNativeAppKey: null,
        serviceCountry: 'KR',
        apiBaseUrl: 'https://qa.api.sazo.kr',
        onAuthTrace: traces.add,
        testAuthProviderOperation: (type, _, _) {
          if (!providerEntered.isCompleted) providerEntered.complete();
          return providerResult.future;
        },
      );
      final oldLineage = <String, Object?>{
        'protocolVersion': 3,
        'maxProtocolVersion': 3,
        'authCapabilities': const [
          'softConvergenceDeadline',
          'onboardingHandoff',
          'reauthRequiredCommit',
        ],
        'authSessionId': 'attempt-old',
        'requestId': 'request-old',
        'documentId': 'document-old',
        'authRevision': 1,
        'provider': 'KAKAO',
      };

      final providerFuture = channel.onMessageReceived(
        _message('KAKAO_SIGN_IN_LOGIN', oldLineage),
      );
      await providerEntered.future;
      final queuedRetiredWrite = channel.onMessageReceived(
        _message('REFRESH_TOKEN_WRITE', {
          ...oldLineage,
          'refreshToken': 'must-not-persist',
        }),
      );

      channel.updateServiceContext(
        serviceCountry: 'GLOBAL',
        apiBaseUrl: 'https://qa.api.sazoshop.com',
      );
      providerResult.complete({
        'type': 'KAKAO_SIGN_IN_LOGIN',
        'data': {'idToken': 'late-provider-result'},
      });
      await Future.wait([providerFuture, queuedRetiredWrite]);

      expect(channel.serviceCountry, 'GLOBAL');
      expect(channel.apiBaseUrl, 'https://qa.api.sazoshop.com');
      expect(
        platformController.evaluatedScripts.any(
          (script) => script.contains('late-provider-result'),
        ),
        isFalse,
      );
      expect(
        traces.any(
          (trace) =>
              trace['event'] == 'auth.context.retired_document_discarded',
        ),
        isTrue,
      );
      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getString('flutter_webview_bridge_refresh_token__global'),
        isNull,
      );
      channel.dispose();
    },
  );

  testWidgets(
    'mismatch recovery production handler가 status→양국 token clear→restart→ACK를 연결한다',
    (tester) async {
      SharedPreferences.setMockInitialValues({
        'flutter_webview_bridge_refresh_token': 'kr-token',
        'flutter_webview_bridge_refresh_token__global': 'global-token',
      });
      final context = await _mountedContext(tester);
      final platformController = _FakePlatformWebViewController();
      final statuses = <Map<String, Object?>>[];
      final restarts = <Map<String, Object?>>[];
      final channel = FlutterWebViewBridgeJavaScriptChannel(
        context: context,
        webViewController: WebViewController.fromPlatform(platformController),
        googleServerClientId: null,
        kakaoNativeAppKey: null,
        serviceCountry: 'KR',
        apiBaseUrl: 'https://qa.api.sazo.kr',
        onAuthContextStatus: statuses.add,
        onAuthContextRestart: restarts.add,
      );

      await channel.onMessageReceived(
        _message('AUTH_CONTEXT_MISMATCH_CLEAR_AND_RESTART', {
          'idempotencyKey': 'restart-once',
          'authSessionId': 'attempt-mismatch',
          'requestId': 'request-mismatch',
          'documentId': 'document-mismatch',
          'authRevision': 4,
          'expectedServiceCountry': 'KR',
          'actualServiceCountry': 'GLOBAL',
        }),
      );

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('flutter_webview_bridge_refresh_token'), isNull);
      expect(
        prefs.getString('flutter_webview_bridge_refresh_token__global'),
        isNull,
      );
      expect(
        statuses,
        contains(
          isA<Map<String, Object?>>().having(
            (status) => status['status'],
            'status',
            'restarting',
          ),
        ),
      );
      expect(restarts, hasLength(1));
      expect(
        platformController.evaluatedScripts.any(
          (script) =>
              script.contains('AUTH_CONTEXT_STATUS_ACK') &&
              script.contains('restartAccepted'),
        ),
        isTrue,
      );
      channel.dispose();
    },
  );

  testWidgets(
    '큐에서 지연된 이전 navigation의 capability/status는 새 generation으로 재라벨링하지 않는다',
    (tester) async {
      final context = await _mountedContext(tester);
      final platformController = _FakePlatformWebViewController();
      final blockingStatusEntered = Completer<void>();
      final releaseBlockingStatus = Completer<void>();
      final capabilities = <int>[];
      final statuses = <Map<String, Object?>>[];
      final channel = FlutterWebViewBridgeJavaScriptChannel(
        context: context,
        webViewController: WebViewController.fromPlatform(platformController),
        googleServerClientId: null,
        kakaoNativeAppKey: null,
        serviceCountry: null,
        apiBaseUrl: null,
        webDocumentNavigationGeneration: 1,
        onWebAuthContextCapability:
            ({
              required supported,
              required documentId,
              required navigationGeneration,
            }) {
              capabilities.add(navigationGeneration);
            },
        onAuthContextStatus: (status) async {
          statuses.add(status);
          if (status['idempotencyKey'] == 'status-blocking') {
            blockingStatusEntered.complete();
            await releaseBlockingStatus.future;
          }
        },
      );

      final blockingStatus = channel.onMessageReceived(
        _message('AUTH_CONTEXT_STATUS', {
          'idempotencyKey': 'status-blocking',
          'documentId': 'document-old',
          'status': 'validationPending',
        }),
      );
      await blockingStatusEntered.future;
      final staleCapability = channel.onMessageReceived(
        _message('DEVICE_INFO', const <String, Object?>{}),
      );
      final staleStatus = channel.onMessageReceived(
        _message('AUTH_CONTEXT_STATUS', {
          'idempotencyKey': 'status-old',
          'documentId': 'document-old',
          'status': 'safeMatched',
        }),
      );

      channel.updateWebDocumentNavigationGeneration(2);
      releaseBlockingStatus.complete();
      await Future.wait([blockingStatus, staleCapability, staleStatus]);

      expect(capabilities, isEmpty);
      expect(statuses, hasLength(1));
      expect(statuses.single['idempotencyKey'], 'status-blocking');
      expect(statuses.single['navigationGeneration'], 1);

      await channel.onMessageReceived(
        _message('AUTH_CONTEXT_STATUS', {
          'idempotencyKey': 'status-current',
          'documentId': 'document-current',
          'status': 'safeMatched',
          'navigationGeneration': 999,
        }),
      );

      expect(statuses, hasLength(2));
      expect(statuses.last['documentId'], 'document-current');
      expect(statuses.last['navigationGeneration'], 2);
      channel.dispose();
    },
  );
}
