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

JavaScriptMessage _message(String type, Object? data) =>
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
              trace['event'] ==
              'auth.context.stale_service_context_message_discarded',
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
    '구웹 metadata 없는 token write는 수신 navigation이 retired되면 새 국가 key에 기록하지 않는다',
    (tester) async {
      final context = await _mountedContext(tester);
      final platformController = _FakePlatformWebViewController();
      final blockingStatusEntered = Completer<void>();
      final releaseBlockingStatus = Completer<void>();
      final traces = <Map<String, Object?>>[];
      final channel = FlutterWebViewBridgeJavaScriptChannel(
        context: context,
        webViewController: WebViewController.fromPlatform(platformController),
        googleServerClientId: null,
        kakaoNativeAppKey: null,
        serviceCountry: 'KR',
        apiBaseUrl: 'https://qa.api.sazo.kr',
        webDocumentNavigationGeneration: 1,
        onAuthTrace: traces.add,
        onAuthContextStatus: (status) async {
          if (status['idempotencyKey'] != 'status-blocking') return;
          blockingStatusEntered.complete();
          await releaseBlockingStatus.future;
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
      final queuedLegacyWrite = channel.onMessageReceived(
        _message('REFRESH_TOKEN_WRITE', 'must-not-persist'),
      );

      channel.beginServiceContextTransition('test-service-country-switch');
      channel.updateServiceContext(
        serviceCountry: 'GLOBAL',
        apiBaseUrl: 'https://qa.api.sazoshop.com',
        webOrigin: 'https://qa.m.sazoshop.com',
        waitForNextNavigation: true,
      );
      channel.updateWebDocumentNavigationGeneration(2);
      channel.confirmWebDocumentNavigation(
        generation: 2,
        documentUrl: 'https://qa.m.sazoshop.com/',
      );
      releaseBlockingStatus.complete();
      await Future.wait([blockingStatus, queuedLegacyWrite]);

      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getString('flutter_webview_bridge_refresh_token__global'),
        isNull,
      );
      expect(
        traces.any(
          (trace) =>
              trace['event'] ==
                  'auth.context.stale_service_context_message_discarded' &&
              trace['resultCode'] == 'REFRESH_TOKEN_WRITE',
        ),
        isTrue,
      );
      channel.dispose();
    },
  );

  testWidgets(
    'context 설치 후 target navigation 전 구웹 token write는 새 국가 key에 기록하지 않는다',
    (tester) async {
      final context = await _mountedContext(tester);
      final platformController = _FakePlatformWebViewController();
      final blockingStatusEntered = Completer<void>();
      final releaseBlockingStatus = Completer<void>();
      final traces = <Map<String, Object?>>[];
      final channel = FlutterWebViewBridgeJavaScriptChannel(
        context: context,
        webViewController: WebViewController.fromPlatform(platformController),
        googleServerClientId: null,
        kakaoNativeAppKey: null,
        serviceCountry: 'KR',
        apiBaseUrl: 'https://qa.api.sazo.kr',
        webDocumentNavigationGeneration: 1,
        onAuthTrace: traces.add,
        onAuthContextStatus: (status) async {
          if (status['idempotencyKey'] != 'post-context-blocking') return;
          blockingStatusEntered.complete();
          await releaseBlockingStatus.future;
        },
      );

      final blockingStatus = channel.onMessageReceived(
        _message('AUTH_CONTEXT_STATUS', {
          'idempotencyKey': 'post-context-blocking',
          'documentId': 'document-old',
          'status': 'validationPending',
        }),
      );
      await blockingStatusEntered.future;

      channel.beginServiceContextTransition('test-service-country-switch');
      channel.updateServiceContext(
        serviceCountry: 'GLOBAL',
        apiBaseUrl: 'https://qa.api.sazoshop.com',
        webOrigin: 'https://qa.m.sazoshop.com',
        waitForNextNavigation: true,
      );
      final queuedLegacyWrite = channel.onMessageReceived(
        _message('REFRESH_TOKEN_WRITE', 'must-not-persist-in-gap'),
      );

      channel.updateWebDocumentNavigationGeneration(2);
      channel.confirmWebDocumentNavigation(
        generation: 2,
        documentUrl: 'https://qa.m.sazoshop.com/?sazo_auth_reset=test',
      );
      releaseBlockingStatus.complete();
      await Future.wait([blockingStatus, queuedLegacyWrite]);

      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getString('flutter_webview_bridge_refresh_token__global'),
        isNull,
      );
      expect(
        traces.any(
          (trace) =>
              trace['event'] ==
                  'auth.context.transition_buffered_message_discarded' &&
              trace['resultCode'] == 'REFRESH_TOKEN_WRITE',
        ),
        isTrue,
      );

      await channel.onMessageReceived(
        _message('REFRESH_TOKEN_WRITE', 'persist-after-target-navigation'),
      );
      expect(
        prefs.getString('flutter_webview_bridge_refresh_token__global'),
        'persist-after-target-navigation',
      );
      channel.dispose();
    },
  );

  testWidgets('연속 반대 전환의 superseded origin은 최신 context fence를 열지 않는다', (
    tester,
  ) async {
    final context = await _mountedContext(tester);
    final platformController = _FakePlatformWebViewController();
    final traces = <Map<String, Object?>>[];
    final channel = FlutterWebViewBridgeJavaScriptChannel(
      context: context,
      webViewController: WebViewController.fromPlatform(platformController),
      googleServerClientId: null,
      kakaoNativeAppKey: null,
      serviceCountry: 'KR',
      apiBaseUrl: 'https://qa.api.sazo.kr',
      webOrigin: 'https://qa.m.sazo.kr',
      webDocumentNavigationGeneration: 1,
      onAuthTrace: traces.add,
    );

    channel.beginServiceContextTransition('kr-to-global');
    channel.updateServiceContext(
      serviceCountry: 'GLOBAL',
      apiBaseUrl: 'https://qa.api.sazoshop.com',
      webOrigin: 'https://qa.m.sazoshop.com',
      waitForNextNavigation: true,
    );
    channel.updateServiceContext(
      serviceCountry: 'KR',
      apiBaseUrl: 'https://qa.api.sazo.kr',
      webOrigin: 'https://qa.m.sazo.kr',
      waitForNextNavigation: true,
    );

    channel.updateWebDocumentNavigationGeneration(2);
    channel.confirmWebDocumentNavigation(
      generation: 2,
      documentUrl: 'https://qa.m.sazoshop.com/',
    );
    final supersededWrite = channel.onMessageReceived(
      _message('REFRESH_TOKEN_WRITE', 'must-not-persist-from-global'),
    );

    final prefs = await SharedPreferences.getInstance();
    expect(
      traces.any(
        (trace) =>
            trace['event'] == 'auth.context.transition_navigation_rejected' &&
            trace['resultCode'] == 'origin_mismatch',
      ),
      isTrue,
    );

    channel.updateWebDocumentNavigationGeneration(3);
    channel.confirmWebDocumentNavigation(
      generation: 3,
      documentUrl: 'https://qa.m.sazo.kr/',
    );
    await supersededWrite;
    expect(prefs.getString('flutter_webview_bridge_refresh_token'), isNull);
    await channel.onMessageReceived(
      _message('REFRESH_TOKEN_WRITE', 'persist-after-kr-navigation'),
    );
    expect(
      prefs.getString('flutter_webview_bridge_refresh_token'),
      'persist-after-kr-navigation',
    );
    channel.dispose();
  });

  testWidgets(
    'target navigation bootstrap mutation은 origin confirm까지 보류 후 재개한다',
    (tester) async {
      final context = await _mountedContext(tester);
      final platformController = _FakePlatformWebViewController();
      final channel = FlutterWebViewBridgeJavaScriptChannel(
        context: context,
        webViewController: WebViewController.fromPlatform(platformController),
        googleServerClientId: null,
        kakaoNativeAppKey: null,
        serviceCountry: 'KR',
        apiBaseUrl: 'https://qa.api.sazo.kr',
        webOrigin: 'https://qa.m.sazo.kr',
        webDocumentNavigationGeneration: 1,
      );

      channel.beginServiceContextTransition('kr-to-global');
      channel.updateServiceContext(
        serviceCountry: 'GLOBAL',
        apiBaseUrl: 'https://qa.api.sazoshop.com',
        webOrigin: 'https://qa.m.sazoshop.com',
        waitForNextNavigation: true,
      );
      channel.updateWebDocumentNavigationGeneration(2);
      final bootstrapWrite = channel.onMessageReceived(
        _message('REFRESH_TOKEN_WRITE', 'target-bootstrap-token'),
      );

      await tester.pump();
      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getString('flutter_webview_bridge_refresh_token__global'),
        isNull,
      );

      channel.confirmWebDocumentNavigation(
        generation: 2,
        documentUrl: 'https://qa.m.sazoshop.com/',
      );
      await bootstrapWrite;
      expect(
        prefs.getString('flutter_webview_bridge_refresh_token__global'),
        'target-bootstrap-token',
      );
      channel.dispose();
    },
  );

  testWidgets('URL 확인 실패 뒤 같은 target navigation 재확인은 보류된 bootstrap을 복구한다', (
    tester,
  ) async {
    final context = await _mountedContext(tester);
    final platformController = _FakePlatformWebViewController();
    final channel = FlutterWebViewBridgeJavaScriptChannel(
      context: context,
      webViewController: WebViewController.fromPlatform(platformController),
      googleServerClientId: null,
      kakaoNativeAppKey: null,
      serviceCountry: 'KR',
      apiBaseUrl: 'https://qa.api.sazo.kr',
      webOrigin: 'https://qa.m.sazo.kr',
      webDocumentNavigationGeneration: 1,
    );

    channel.beginServiceContextTransition('kr-to-global');
    channel.updateServiceContext(
      serviceCountry: 'GLOBAL',
      apiBaseUrl: 'https://qa.api.sazoshop.com',
      webOrigin: 'https://qa.m.sazoshop.com',
      waitForNextNavigation: true,
    );
    channel.updateWebDocumentNavigationGeneration(2);
    channel.confirmWebDocumentNavigation(generation: 2, documentUrl: null);
    final bootstrapWrite = channel.onMessageReceived(
      _message('REFRESH_TOKEN_WRITE', 'retry-confirm-token'),
    );

    await tester.pump();
    channel.confirmWebDocumentNavigation(
      generation: 2,
      documentUrl: 'https://qa.m.sazoshop.com/redirected',
    );
    await bootstrapWrite;

    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getString('flutter_webview_bridge_refresh_token__global'),
      'retry-confirm-token',
    );
    channel.dispose();
  });

  testWidgets('같은 국가 navigation을 넘은 구웹 token write는 기존 국가 key에 기록한다', (
    tester,
  ) async {
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
        if (status['idempotencyKey'] != 'same-country-write-blocking') return;
        blockingStatusEntered.complete();
        await releaseBlockingStatus.future;
      },
    );

    final blockingStatus = channel.onMessageReceived(
      _message('AUTH_CONTEXT_STATUS', {
        'idempotencyKey': 'same-country-write-blocking',
        'documentId': 'document-signin',
        'status': 'validationPending',
      }),
    );
    await blockingStatusEntered.future;
    final queuedLegacyWrite = channel.onMessageReceived(
      _message('REFRESH_TOKEN_WRITE', 'persist-on-kr'),
    );

    channel.updateWebDocumentNavigationGeneration(2);
    releaseBlockingStatus.complete();
    await Future.wait([blockingStatus, queuedLegacyWrite]);

    final prefs = await SharedPreferences.getInstance();
    expect(
      prefs.getString('flutter_webview_bridge_refresh_token'),
      'persist-on-kr',
    );
    channel.dispose();
  });

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
