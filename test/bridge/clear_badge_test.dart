import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webview_bridge/flutter_webview_bridge.dart';
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('CLEAR_BADGE awaits one callback and sends no JS response', (
    tester,
  ) async {
    final context = await _mountedContext(tester);
    final platformController = _FakePlatformWebViewController();
    final callbackStarted = Completer<void>();
    final callbackRelease = Completer<void>();
    var callbackCount = 0;
    final channel = FlutterWebViewBridgeJavaScriptChannel(
      context: context,
      webViewController: WebViewController.fromPlatform(platformController),
      googleServerClientId: null,
      kakaoNativeAppKey: null,
      onClearBadge: () async {
        callbackCount += 1;
        callbackStarted.complete();
        await callbackRelease.future;
      },
    );

    var messageCompleted = false;
    final received = channel
        .onMessageReceived(
          JavaScriptMessage(
            message: jsonEncode({'type': 'CLEAR_BADGE', 'data': null}),
          ),
        )
        .then((_) => messageCompleted = true);

    await callbackStarted.future;
    expect(callbackCount, 1);
    expect(messageCompleted, isFalse);
    expect(platformController.evaluatedScripts, isEmpty);

    callbackRelease.complete();
    await received;

    expect(callbackCount, 1);
    expect(messageCompleted, isTrue);
    expect(platformController.evaluatedScripts, isEmpty);
  });
}
