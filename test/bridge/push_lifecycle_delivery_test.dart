import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webview_bridge/flutter_webview_bridge.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

class _DelayedWebView extends PlatformWebViewController {
  _DelayedWebView()
    : super.implementation(const PlatformWebViewControllerCreationParams());

  final dispatched = <Map<String, dynamic>>[];
  final delivered = <Map<String, dynamic>>[];
  Completer<void>? delayNext;

  @override
  Future<Object> runJavaScriptReturningResult(String javaScript) async {
    final literal = RegExp(r'var payload = (.*);').firstMatch(javaScript)![1]!;
    final message =
        jsonDecode(jsonDecode(literal) as String) as Map<String, dynamic>;
    dispatched.add(message);
    final delay = delayNext;
    delayNext = null;
    if (delay != null) await delay.future;
    delivered.add(message);
    return true;
  }
}

String _push(String? token) => jsonEncode({
  'type': 'PUSH_TOKEN',
  'data': {
    'token': token,
    'isNotificationPermissionGranted': token != null,
    'permissionStatus': token == null ? 'denied' : 'authorized',
    'tokenStatus': token == null ? 'pending' : 'ready',
  },
});

void main() {
  late _DelayedWebView platform;
  late FlutterWebViewBridgeJavaScriptChannel channel;

  Future<void> mount(WidgetTester tester) async {
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
    platform = _DelayedWebView();
    channel = FlutterWebViewBridgeJavaScriptChannel(
      context: context,
      webViewController: WebViewController.fromPlatform(platform),
      googleServerClientId: null,
      kakaoNativeAppKey: null,
    );
    addTearDown(channel.dispose);
  }

  List<Object?> deliveredTokens() => platform.delivered
      .where((message) => message['type'] == 'PUSH_TOKEN')
      .map((message) => (message['data'] as Map)['token'])
      .toList();

  testWidgets(
    'paused push states coalesce to the latest permission and token',
    (tester) async {
      await mount(tester);
      channel.updateAppLifecycleState(AppLifecycleState.paused);
      await channel.runJavaScriptPostMessage(_push('old'));
      await channel.runJavaScriptPostMessage(_push(null));
      await channel.runJavaScriptPostMessage(_push('latest'));
      expect(platform.dispatched, isEmpty);
      channel.updateAppLifecycleState(AppLifecycleState.resumed);
      await tester.pump();
      expect(deliveredTokens(), ['latest']);
    },
  );

  testWidgets(
    'fresh push supersedes stale replay while unrelated JS is delayed',
    (tester) async {
      await mount(tester);
      channel.updateAppLifecycleState(AppLifecycleState.paused);
      await channel.runJavaScriptPostMessage(
        jsonEncode({'type': 'DEVICE_INFO', 'data': {}}),
      );
      await channel.runJavaScriptPostMessage(_push('old'));
      await channel.runJavaScriptPostMessage(_push(null));
      final delayedJs = Completer<void>();
      platform.delayNext = delayedJs;
      channel.updateAppLifecycleState(AppLifecycleState.resumed);
      await tester.pump();
      await channel.runJavaScriptPostMessage(_push('latest'));
      expect(deliveredTokens(), ['latest']);
      delayedJs.complete();
      await tester.pump();
      expect(deliveredTokens(), ['latest']);
      expect(platform.delivered.last['type'], 'DEVICE_INFO');
    },
  );

  testWidgets(
    'in-flight push settles before newer push and skips stale denial',
    (tester) async {
      await mount(tester);
      channel.updateAppLifecycleState(AppLifecycleState.paused);
      await channel.runJavaScriptPostMessage(_push('old'));
      final delayedJs = Completer<void>();
      platform.delayNext = delayedJs;
      channel.updateAppLifecycleState(AppLifecycleState.resumed);
      await tester.pump();
      final denied = channel.runJavaScriptPostMessage(_push(null));
      final latest = channel.runJavaScriptPostMessage(_push('latest'));
      await tester.pump();
      expect(platform.dispatched, hasLength(1));
      expect(deliveredTokens(), isEmpty);
      delayedJs.complete();
      await Future.wait([denied, latest]);
      expect(deliveredTokens(), ['old', 'latest']);
    },
  );

  testWidgets('dispose drops push awaiting an in-flight JS evaluation', (
    tester,
  ) async {
    await mount(tester);
    final delayedJs = Completer<void>();
    platform.delayNext = delayedJs;
    final old = channel.runJavaScriptPostMessage(_push('old'));
    await tester.pump();
    final latest = channel.runJavaScriptPostMessage(_push('latest'));
    channel.dispose();
    delayedJs.complete();
    await Future.wait([old, latest]);
    expect(platform.dispatched, hasLength(1));
  });
}
