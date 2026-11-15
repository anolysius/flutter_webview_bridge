import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webview_bridge/flutter_webview_bridge.dart';
import 'package:flutter_webview_bridge/src/bridge/auth/process_auth_attempt_coordinator.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

class _PlatformWebViewController extends PlatformWebViewController {
  _PlatformWebViewController()
    : super.implementation(const PlatformWebViewControllerCreationParams());

  final List<String> scripts = <String>[];

  @override
  Future<Object> runJavaScriptReturningResult(String javaScript) async {
    scripts.add(javaScript);
    return true;
  }

  @override
  Future<void> runJavaScript(String javaScript) async {
    scripts.add(javaScript);
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

Future<void> _pumpUntil(WidgetTester tester, bool Function() condition) async {
  for (var attempt = 0; attempt < 40 && !condition(); attempt += 1) {
    await tester.pump(const Duration(milliseconds: 1));
  }
}

JavaScriptMessage _login(String attempt, {bool retryAfterTimeout = false}) =>
    JavaScriptMessage(
      message: jsonEncode({
        'type': 'KAKAO_SIGN_IN_LOGIN',
        'data': {
          'protocolVersion': 2,
          'maxProtocolVersion': 3,
          'authCapabilities': [
            'softConvergenceDeadline',
            'onboardingHandoff',
            'reauthRequiredCommit',
            'criticalAuthDeliveryAck',
          ],
          'authSessionId': attempt,
          'requestId': 'request-$attempt',
          'documentId': 'document-stalled',
          'authRevision': 1,
          'provider': 'KAKAO',
          if (retryAfterTimeout) 'retryAfterTimeout': true,
        },
      }),
    );

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ProcessAuthAttemptCoordinator.shared.resetForAuthBoundary();
  });

  tearDown(ProcessAuthAttemptCoordinator.shared.resetForAuthBoundary);

  testWidgets(
    'new attempt releases a provider future that never completes',
    (tester) async {
      final context = await _mountedContext(tester);
      final traces = <Map<String, Object?>>[];
      final providerResults = <Completer<Map<String, Object?>>>[];
      final channel = FlutterWebViewBridgeJavaScriptChannel(
        context: context,
        webViewController: WebViewController.fromPlatform(
          _PlatformWebViewController(),
        ),
        googleServerClientId: null,
        kakaoNativeAppKey: null,
        serviceCountry: 'KR',
        apiBaseUrl: null,
        onAuthTrace: traces.add,
        testAuthProviderOperation: (_, _, _) {
          final result = Completer<Map<String, Object?>>();
          providerResults.add(result);
          return result.future;
        },
      );
      addTearDown(channel.dispose);

      var stalledCompleted = false;
      final stalled = channel.onMessageReceived(_login('attempt-stalled')).then(
        (_) => stalledCompleted = true,
      );
      await _pumpUntil(tester, () => providerResults.length == 1);
      expect(providerResults, hasLength(1), reason: traces.toString());

      // 같은 provider 의 즉시 재클릭(중복 window 안)은 진행 중인 SDK 화면을 보존한다.
      var duplicateCompleted = false;
      final duplicate = channel
          .onMessageReceived(_login('attempt-reclick'))
          .then((_) => duplicateCompleted = true);
      await tester.pump(const Duration(milliseconds: 10));
      expect(stalledCompleted, isFalse);
      expect(
        traces.any(
          (trace) => trace['event'] == 'auth.attempt.stalled_provider_released',
        ),
        isFalse,
      );

      // web 의 ACK timeout 재시도는 이전 provider 대기를 끊고 새 시도로 진행한다.
      final retry = channel.onMessageReceived(
        _login('attempt-retry', retryAfterTimeout: true),
      );
      await _pumpUntil(
        tester,
        () => stalledCompleted && duplicateCompleted && providerResults.length == 2,
      );

      expect(stalledCompleted, isTrue, reason: traces.toString());
      expect(duplicateCompleted, isTrue, reason: traces.toString());
      expect(providerResults, hasLength(2), reason: traces.toString());
      expect(
        traces.any(
          (trace) =>
              trace['event'] == 'auth.attempt.stalled_provider_released' &&
              trace['resultCode'] == 'retry_after_timeout',
        ),
        isTrue,
      );
      expect(
        traces.any(
          (trace) =>
              trace['event'] == 'auth.attempt.started' &&
              trace['loginAttemptId'] == 'attempt-retry',
        ),
        isTrue,
        reason: traces.toString(),
      );

      providerResults.last.complete({
        'type': 'KAKAO_SIGN_IN_LOGIN',
        'data': {'idToken': 'test-id-token'},
      });
      await Future.wait([stalled, duplicate, retry]);
      channel.resetAuthStateForServiceCountrySwitch('test-cleanup');
      channel.dispose();
      await tester.pumpAndSettle();
    },
  );
}
