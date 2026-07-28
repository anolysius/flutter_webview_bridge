import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webview_bridge/flutter_webview_bridge.dart';
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

JavaScriptMessage _message(Map<String, Object?> data) => JavaScriptMessage(
  message: jsonEncode({'type': 'KAKAO_SIGN_IN_LOGIN', 'data': data}),
);

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
  });

  testWidgets(
    'negotiated critical ACK retries delivery without rerunning SDK',
    (tester) async {
      final context = await _mountedContext(tester);
      final platformController = _AckPlatformWebViewController(
        ackResults: [false, true],
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

      final login = channel.onMessageReceived(
        _message(_lineage(supportsCriticalAck: true)),
      );
      await tester.pump(const Duration(milliseconds: 350));

      expect(providerCalls, 1);
      expect(platformController.callbackCalls, 2, reason: traces.toString());
      expect(
        traces.any((trace) => trace['event'] == 'auth.attempt.ack_recovered'),
        isTrue,
      );

      providerResult.complete({
        'type': 'KAKAO_SIGN_IN_LOGIN',
        'data': {'idToken': 'test-id-token'},
      });
      await login;
      channel.resetAuthStateForServiceCountrySwitch('test-cleanup');
      channel.dispose();
    },
  );
}
