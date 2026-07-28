import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webview_bridge/flutter_webview_bridge.dart';
import 'package:flutter_webview_bridge/src/bridge/auth/process_auth_attempt_coordinator.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

class _AckPlatformWebViewController extends PlatformWebViewController {
  _AckPlatformWebViewController({required this.ackResults})
    : super.implementation(const PlatformWebViewControllerCreationParams());

  final List<bool> ackResults;
  int callbackCalls = 0;

  @override
  Future<Object> runJavaScriptReturningResult(String javaScript) async {
    callbackCalls += 1;
    if (ackResults.isEmpty) return true;
    return ackResults.removeAt(0);
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
  for (var attempt = 0; attempt < 20 && !condition(); attempt += 1) {
    await tester.pump(const Duration(milliseconds: 1));
  }
}

JavaScriptMessage _message(
  Map<String, Object?> data, {
  String type = 'KAKAO_SIGN_IN_LOGIN',
}) => JavaScriptMessage(message: jsonEncode({'type': type, 'data': data}));

Map<String, Object?> _lineage({required bool supportsCriticalAck}) => {
  'protocolVersion': 2,
  'maxProtocolVersion': 3,
  'authCapabilities': [
    'softConvergenceDeadline',
    'onboardingHandoff',
    'reauthRequiredCommit',
    if (supportsCriticalAck) 'criticalAuthDeliveryAck',
  ],
  'authSessionId': 'attempt-ack',
  'requestId': 'request-ack',
  'documentId': 'document-ack',
  'authRevision': 1,
  'provider': 'KAKAO',
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ProcessAuthAttemptCoordinator.shared.resetForAuthBoundary();
  });

  tearDown(ProcessAuthAttemptCoordinator.shared.resetForAuthBoundary);

  testWidgets(
    'same critical request replays ACK after native retries exhaust',
    (tester) async {
      final context = await _mountedContext(tester);
      final platformController = _AckPlatformWebViewController(
        ackResults: [false, false, false, false, false, true],
      );
      final providerResult = Completer<Map<String, Object?>>();
      final traces = <Map<String, Object?>>[];
      var providerCalls = 0;
      final channel = FlutterWebViewBridgeJavaScriptChannel(
        context: context,
        webViewController: WebViewController.fromPlatform(platformController),
        googleServerClientId: null,
        kakaoNativeAppKey: null,
        serviceCountry: 'KR',
        apiBaseUrl: null,
        onAuthTrace: traces.add,
        testAuthProviderOperation: (type, _, _) {
          providerCalls += 1;
          return providerResult.future;
        },
      );
      addTearDown(channel.dispose);

      final request = _message(_lineage(supportsCriticalAck: true));
      final login = channel.onMessageReceived(request);
      await _pumpUntil(
        tester,
        () => providerCalls == 1 && platformController.callbackCalls == 1,
      );
      expect(providerCalls, 1, reason: traces.toString());
      expect(platformController.callbackCalls, 1);

      await tester.pump(const Duration(milliseconds: 250));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 2));
      expect(platformController.callbackCalls, 5);
      expect(
        traces.any(
          (trace) => trace['event'] == 'auth.attempt.ack_retry_exhausted',
        ),
        isTrue,
      );

      var mismatchedCompleted = false;
      final mismatched = channel
          .onMessageReceived(
            _message(
              _lineage(supportsCriticalAck: true),
              type: 'GOOGLE_SIGN_IN_LOGIN',
            ),
          )
          .then((_) {
            mismatchedCompleted = true;
          });
      await tester.pump();
      expect(mismatchedCompleted, isFalse);
      expect(providerCalls, 1);
      expect(platformController.callbackCalls, 5);

      var duplicateCompleted = false;
      final duplicate = channel.onMessageReceived(request).then((_) {
        duplicateCompleted = true;
      });
      await _pumpUntil(tester, () => duplicateCompleted);

      expect(duplicateCompleted, isTrue);
      expect(providerCalls, 1);
      expect(platformController.callbackCalls, 6);
      expect(
        traces.any(
          (trace) =>
              trace['event'] == 'auth.attempt.duplicate_ack_replayed' &&
              trace['resultCode'] == 'same_request_in_flight_fast_path',
        ),
        isTrue,
      );

      providerResult.complete({
        'type': 'KAKAO_SIGN_IN_LOGIN',
        'data': {'idToken': 'test-id-token'},
      });
      await Future.wait([login, mismatched, duplicate]);
      expect(providerCalls, 1);
      channel.resetAuthStateForServiceCountrySwitch('test-cleanup');
      channel.dispose();
      await tester.pumpAndSettle();
    },
  );
}
