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

  /// `callbackPostMessage` 로 보낸 메시지만 꺼낸다. 브릿지는 JSON 을 문자열 리터럴로
  /// 한 번 더 감싸(`var payload = "<json>";`) 넘긴다.
  List<Map<String, dynamic>> get posted => evaluatedScripts
      .where((script) => script.contains('callbackPostMessage'))
      .map((script) {
        final match = RegExp(
          r'var payload = (".*?(?<!\\)");',
          dotAll: true,
        ).firstMatch(script);
        if (match == null) return null;
        try {
          final decoded = jsonDecode(jsonDecode(match.group(1)!) as String);
          return decoded is Map<String, dynamic> ? decoded : null;
        } on FormatException {
          return null;
        }
      })
      .whereType<Map<String, dynamic>>()
      .toList();
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

  tearDown(WebViewToken.reset);

  group('PUSH_TOKEN 확장 필드', () {
    test('canRequestPermission 은 앱이 준 값만 싣고, 값 없는 업데이트는 유지한다', () {
      var data = WebViewToken.payload(platform: 'android', isRefresh: false);
      expect(data.containsKey('canRequestPermission'), isFalse);

      WebViewToken.update(
        token: null,
        permission: 'denied',
        permissionGranted: false,
        canRequestPermission: true,
      );
      data = WebViewToken.payload(platform: 'android', isRefresh: false);
      expect(data['canRequestPermission'], isTrue);

      // 옛 setter 경로(값 없음)는 바꾸지 않는다.
      WebViewToken.fcmToken = 'legacy';
      data = WebViewToken.payload(platform: 'android', isRefresh: false);
      expect(data['canRequestPermission'], isTrue);

      WebViewToken.update(
        token: 't',
        permission: 'authorized',
        canRequestPermission: false,
      );
      data = WebViewToken.payload(platform: 'android', isRefresh: false);
      expect(data['canRequestPermission'], isFalse);
    });

    test('capabilities 는 브릿지가 정한 목록을 그대로 싣는다', () {
      WebViewToken.capabilities = const ['pushPermissionStatus'];
      final data = WebViewToken.payload(platform: 'ios', isRefresh: false);
      expect(data['capabilities'], ['pushPermissionStatus']);
    });

    test('reset 은 새 필드도 지운다', () {
      WebViewToken.update(
        token: 't',
        permission: 'authorized',
        canRequestPermission: false,
      );
      WebViewToken.capabilities = const ['x'];
      WebViewToken.reset();
      final data = WebViewToken.payload(platform: 'ios', isRefresh: false);
      expect(data.containsKey('canRequestPermission'), isFalse);
      expect(data['capabilities'], isEmpty);
    });
  });

  test('이벤트 이름 매핑', () {
    expect(
      'PUSH_PERMISSION_REQUEST'.webViewBridgeFeatureType,
      WebViewBridgeFeatureType.pushPermissionRequest,
    );
    expect(
      'PUSH_PERMISSION_STATUS'.webViewBridgeFeatureType,
      WebViewBridgeFeatureType.pushPermissionStatus,
    );
    expect(
      'OPEN_NOTIFICATION_SETTINGS'.webViewBridgeFeatureType,
      WebViewBridgeFeatureType.openNotificationSettings,
    );
    expect(
      WebViewBridgeFeatureType.pushPermissionRequest.value,
      'PUSH_PERMISSION_REQUEST',
    );
  });

  group('채널 capabilities', () {
    testWidgets('콜백을 넣은 기능만 광고한다', (tester) async {
      final context = await _mountedContext(tester);
      FlutterWebViewBridgeJavaScriptChannel(
        context: context,
        webViewController: WebViewController.fromPlatform(
          _FakePlatformWebViewController(),
        ),
        googleServerClientId: null,
        kakaoNativeAppKey: null,
      );
      expect(WebViewToken.capabilities, [
        'pushPermissionStatus',
        'openNotificationSettings',
        'hapticFeedback',
      ]);

      FlutterWebViewBridgeJavaScriptChannel(
        context: context,
        webViewController: WebViewController.fromPlatform(
          _FakePlatformWebViewController(),
        ),
        googleServerClientId: null,
        kakaoNativeAppKey: null,
        onPushPermissionRequest: (_) async => {'result': 'granted'},
      );
      expect(WebViewToken.capabilities, [
        'pushPermissionRequest',
        'pushPermissionStatus',
        'openNotificationSettings',
        'hapticFeedback',
      ]);
    });
  });

  testWidgets('DEVICE_INFO 응답에 capabilities 를 싣는다', (tester) async {
    final context = await _mountedContext(tester);
    final platform = _FakePlatformWebViewController();
    final channel = FlutterWebViewBridgeJavaScriptChannel(
      context: context,
      webViewController: WebViewController.fromPlatform(platform),
      googleServerClientId: null,
      kakaoNativeAppKey: null,
      onPushPermissionRequest: (_) async => {'result': 'granted'},
      testDeviceInfoOperation: () async => {
        'type': 'DEVICE_INFO',
        'data': <String, Object?>{},
      },
    );

    await channel.onMessageReceived(_message('DEVICE_INFO', null));
    await tester.pump();

    final data = platform.posted.single['data'] as Map;
    expect(data['capabilities'], [
      'pushPermissionRequest',
      'pushPermissionStatus',
      'openNotificationSettings',
      'hapticFeedback',
    ]);
  });

  group('PUSH_PERMISSION_REQUEST', () {
    testWidgets('앱 콜백 결과에 문자열 requestId 를 붙여 응답한다', (tester) async {
      final context = await _mountedContext(tester);
      final platform = _FakePlatformWebViewController();
      Object? received;
      final channel = FlutterWebViewBridgeJavaScriptChannel(
        context: context,
        webViewController: WebViewController.fromPlatform(platform),
        googleServerClientId: null,
        kakaoNativeAppKey: null,
        onPushPermissionRequest: (data) async {
          received = data;
          return {
            'result': 'granted',
            'promptShown': true,
            'permissionStatus': 'authorized',
            'canRequestPermission': false,
          };
        },
      );

      await channel.onMessageReceived(
        _message('PUSH_PERMISSION_REQUEST', {'requestId': 'r1'}),
      );
      await tester.pump();

      expect(received, {'requestId': 'r1'});
      final response = platform.posted.single;
      expect(response['type'], 'PUSH_PERMISSION_REQUEST');
      expect(response['data'], {
        'result': 'granted',
        'promptShown': true,
        'permissionStatus': 'authorized',
        'canRequestPermission': false,
        'requestId': 'r1',
      });
    });

    testWidgets('숫자 requestId 는 오류 없이 생략한다', (tester) async {
      final context = await _mountedContext(tester);
      final platform = _FakePlatformWebViewController();
      final channel = FlutterWebViewBridgeJavaScriptChannel(
        context: context,
        webViewController: WebViewController.fromPlatform(platform),
        googleServerClientId: null,
        kakaoNativeAppKey: null,
        onPushPermissionRequest: (_) async => {'result': 'denied'},
      );

      await channel.onMessageReceived(
        _message('PUSH_PERMISSION_REQUEST', {'requestId': 7}),
      );
      await tester.pump();

      final data = platform.posted.single['data'] as Map;
      expect(data['result'], 'denied');
      expect(data.containsKey('requestId'), isFalse);
    });

    testWidgets('앱 콜백이 없으면 unavailable', (tester) async {
      final context = await _mountedContext(tester);
      final platform = _FakePlatformWebViewController();
      final channel = FlutterWebViewBridgeJavaScriptChannel(
        context: context,
        webViewController: WebViewController.fromPlatform(platform),
        googleServerClientId: null,
        kakaoNativeAppKey: null,
      );

      await channel.onMessageReceived(_message('PUSH_PERMISSION_REQUEST', {}));
      await tester.pump();

      final data = platform.posted.single['data'] as Map;
      expect(data['result'], 'unavailable');
      expect(data['promptShown'], isFalse);
    });

    testWidgets('응답을 기다리는 동안 다른 메시지를 막지 않는다', (tester) async {
      final context = await _mountedContext(tester);
      final platform = _FakePlatformWebViewController();
      final release = Completer<Map<String, Object?>>();
      var badgeCleared = false;
      final channel = FlutterWebViewBridgeJavaScriptChannel(
        context: context,
        webViewController: WebViewController.fromPlatform(platform),
        googleServerClientId: null,
        kakaoNativeAppKey: null,
        onPushPermissionRequest: (_) => release.future,
        onClearBadge: () async => badgeCleared = true,
      );

      await channel.onMessageReceived(
        _message('PUSH_PERMISSION_REQUEST', {'requestId': 'a'}),
      );
      await channel.onMessageReceived(_message('CLEAR_BADGE', null));
      expect(badgeCleared, isTrue);
      expect(platform.posted, isEmpty);

      release.complete({'result': 'denied', 'promptShown': true});
      await tester.pump();
      expect(platform.posted.single['data']['result'], 'denied');
    });

    testWidgets('진행 중에 또 오면 두 번째는 바로 busy', (tester) async {
      final context = await _mountedContext(tester);
      final platform = _FakePlatformWebViewController();
      final release = Completer<Map<String, Object?>>();
      var calls = 0;
      final channel = FlutterWebViewBridgeJavaScriptChannel(
        context: context,
        webViewController: WebViewController.fromPlatform(platform),
        googleServerClientId: null,
        kakaoNativeAppKey: null,
        onPushPermissionRequest: (_) {
          calls++;
          return release.future;
        },
      );

      await channel.onMessageReceived(
        _message('PUSH_PERMISSION_REQUEST', {'requestId': 'a'}),
      );
      await channel.onMessageReceived(
        _message('PUSH_PERMISSION_REQUEST', {'requestId': 'b'}),
      );
      await tester.pump();
      expect(calls, 1);
      expect(platform.posted.single['data'], {
        'result': 'busy',
        'promptShown': false,
        'requestId': 'b',
      });

      release.complete({'result': 'granted', 'promptShown': true});
      await tester.pump();
      expect(platform.posted.last['data']['requestId'], 'a');
    });

    testWidgets('상한 시간을 넘기면 unavailable 로 응답한다', (tester) async {
      final context = await _mountedContext(tester);
      final platform = _FakePlatformWebViewController();
      final channel = FlutterWebViewBridgeJavaScriptChannel(
        context: context,
        webViewController: WebViewController.fromPlatform(platform),
        googleServerClientId: null,
        kakaoNativeAppKey: null,
        onPushPermissionRequest: (_) =>
            Completer<Map<String, Object?>>().future,
      );

      await channel.onMessageReceived(
        _message('PUSH_PERMISSION_REQUEST', {'requestId': 'slow'}),
      );
      await tester.pump(const Duration(seconds: 61));

      expect(platform.posted.single['data'], {
        'result': 'unavailable',
        'promptShown': false,
        'requestId': 'slow',
      });
    });
  });

  group('PUSH_PERMISSION_STATUS', () {
    testWidgets('앱 콜백이 없으면 캐시 상태와 capabilities 를 돌려준다', (tester) async {
      final context = await _mountedContext(tester);
      final platform = _FakePlatformWebViewController();
      final channel = FlutterWebViewBridgeJavaScriptChannel(
        context: context,
        webViewController: WebViewController.fromPlatform(platform),
        googleServerClientId: null,
        kakaoNativeAppKey: null,
      );
      WebViewToken.update(
        token: null,
        permission: 'denied',
        permissionGranted: false,
        canRequestPermission: true,
      );

      await channel.onMessageReceived(
        _message('PUSH_PERMISSION_STATUS', {'requestId': 's'}),
      );
      await tester.pump();

      expect(platform.posted.single['data'], {
        'permissionStatus': 'denied',
        'canRequestPermission': true,
        'capabilities': ['pushPermissionStatus', 'openNotificationSettings'],
        'requestId': 's',
      });
    });

    testWidgets('앱 콜백 값에 capabilities 를 덧붙인다', (tester) async {
      final context = await _mountedContext(tester);
      final platform = _FakePlatformWebViewController();
      final channel = FlutterWebViewBridgeJavaScriptChannel(
        context: context,
        webViewController: WebViewController.fromPlatform(platform),
        googleServerClientId: null,
        kakaoNativeAppKey: null,
        onPushPermissionStatus: (_) async => {
          'permissionStatus': 'authorized',
          'canRequestPermission': false,
        },
      );

      await channel.onMessageReceived(_message('PUSH_PERMISSION_STATUS', null));
      await tester.pump();

      final data = platform.posted.single['data'] as Map;
      expect(data['permissionStatus'], 'authorized');
      expect(data['canRequestPermission'], isFalse);
      expect(data['capabilities'], [
        'pushPermissionStatus',
        'openNotificationSettings',
      ]);
    });
  });

  group('OPEN_NOTIFICATION_SETTINGS', () {
    testWidgets('앱 콜백이 연 곳을 돌려준다', (tester) async {
      final context = await _mountedContext(tester);
      final platform = _FakePlatformWebViewController();
      final channel = FlutterWebViewBridgeJavaScriptChannel(
        context: context,
        webViewController: WebViewController.fromPlatform(platform),
        googleServerClientId: null,
        kakaoNativeAppKey: null,
        onOpenNotificationSettings: (_) async => {'opened': 'notification'},
      );

      await channel.onMessageReceived(
        _message('OPEN_NOTIFICATION_SETTINGS', {'requestId': 'o'}),
      );
      await tester.pump();

      expect(platform.posted.single, {
        'type': 'OPEN_NOTIFICATION_SETTINGS',
        'data': {'opened': 'notification', 'requestId': 'o'},
      });
    });

    testWidgets('앱 콜백이 실패하면 failed', (tester) async {
      final context = await _mountedContext(tester);
      final platform = _FakePlatformWebViewController();
      final channel = FlutterWebViewBridgeJavaScriptChannel(
        context: context,
        webViewController: WebViewController.fromPlatform(platform),
        googleServerClientId: null,
        kakaoNativeAppKey: null,
        onOpenNotificationSettings: (_) async => throw StateError('x'),
      );

      await channel.onMessageReceived(
        _message('OPEN_NOTIFICATION_SETTINGS', null),
      );
      await tester.pump();

      expect(platform.posted.single['data'], {'opened': 'failed'});
    });
  });
}
