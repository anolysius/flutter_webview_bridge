import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webview_bridge/src/bridge/events/push_token.dart';
import 'package:flutter_webview_bridge/src/models/token.dart';

void main() {
  group('PushTokenEvent.process', () {
    final expectedPlatform = Platform.isIOS ? 'ios' : 'android';

    tearDown(() {
      WebViewToken.fcmToken = null;
    });

    testWidgets('returns payload with token=null when cache is empty', (
      tester,
    ) async {
      WebViewToken.fcmToken = null;
      late BuildContext capturedContext;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              capturedContext = context;
              return const SizedBox.shrink();
            },
          ),
        ),
      );

      final result = await PushTokenEvent().process(capturedContext);

      expect(result['type'], 'PUSH_TOKEN');
      final data = result['data'] as Map<String, Object?>;
      expect(data['token'], isNull);
      expect(data['platform'], expectedPlatform);
      expect(data['isRefresh'], false);
    });

    testWidgets('returns payload with cached token value when set', (
      tester,
    ) async {
      WebViewToken.fcmToken = 'fake-fcm-token';
      late BuildContext capturedContext;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              capturedContext = context;
              return const SizedBox.shrink();
            },
          ),
        ),
      );

      final result = await PushTokenEvent().process(capturedContext);

      final data = result['data'] as Map<String, Object?>;
      expect(data['token'], 'fake-fcm-token');
      expect(data['platform'], expectedPlatform);
      expect(data['isRefresh'], false);
    });

    testWidgets('platform field matches host Platform.isIOS', (tester) async {
      WebViewToken.fcmToken = 'x';
      late BuildContext capturedContext;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              capturedContext = context;
              return const SizedBox.shrink();
            },
          ),
        ),
      );

      final result = await PushTokenEvent().process(capturedContext);
      final data = result['data'] as Map<String, Object?>;
      expect(data['platform'], anyOf('ios', 'android'));
      expect(data['platform'], expectedPlatform);
    });
  });
}
