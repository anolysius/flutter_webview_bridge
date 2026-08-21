import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webview_bridge/flutter_webview_bridge.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

Map<String, Object?> _payload(
  String eventName, {
  Map<String, Object>? parameters,
}) {
  final orderId = 'order-1';
  return {
    'schemaVersion': 1,
    'requestId': 'request-$eventName',
    'eventId': eventName == 'af_purchase'
        ? 'purchase:$orderId'
        : '$eventName:event-1',
    'eventName': eventName,
    'occurredAt': '2026-08-21T12:00:00.000Z',
    'customerUserId': 'user-1',
    'parameters': parameters ?? _parameters(eventName, orderId),
  };
}

Map<String, Object> _parameters(String eventName, String orderId) {
  const content = '[{"id":"item-1","quantity":2}]';
  const contentIds = '["item-1"]';
  const quantities = '[2]';
  switch (eventName) {
    case 'af_purchase':
      return {
        'af_revenue': 2000,
        'af_price': 2000,
        'af_currency': 'KRW',
        'af_order_id': orderId,
        'af_receipt_id': orderId,
        'af_content': content,
        'af_content_id': contentIds,
        'af_quantity': quantities,
      };
    case 'af_initiated_checkout':
      return {
        'af_price': 2000,
        'af_currency': 'KRW',
        'af_content': content,
        'af_content_id': contentIds,
        'af_quantity': quantities,
      };
    case 'af_add_to_cart':
      return {
        'af_price': 1000,
        'af_currency': 'KRW',
        'af_content_id': 'item-1',
        'af_content_type': 'product',
        'af_quantity': 2,
      };
    case 'af_add_to_wishlist':
    case 'af_content_view':
      return {
        'af_price': 1000,
        'af_currency': 'KRW',
        'af_content_id': 'item-1',
        'af_content_type': 'product',
      };
    case 'af_search':
      return {'af_search_string': 'camera'};
    case 'af_login':
    case 'af_complete_registration':
      return {'af_registration_method': 'kakao'};
  }
  throw ArgumentError.value(eventName);
}

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

  test('8개 allowlist event를 typed callback으로 전달한다', () async {
    final received = <AppsFlyerAnalyticsRequest>[];
    final event = AppsFlyerAnalyticsEvent(
      onEvent: (request) async {
        received.add(request);
        return const AppsFlyerDeliveryResult.accepted();
      },
    );

    for (final eventName in appsFlyerEventNames) {
      final response = await event.process(_payload(eventName));
      expect(response['type'], 'APPS_FLYER_ANALYTICS');
      expect((response['data'] as Map)['status'], 'accepted');
    }

    expect(
      received.map((request) => request.eventName).toSet(),
      appsFlyerEventNames,
    );
    expect(
      received.every((request) => request.customerUserId == 'user-1'),
      isTrue,
    );
  });

  test('unknown event와 malformed payload는 callback 전에 거부한다', () async {
    var callbackCount = 0;
    final event = AppsFlyerAnalyticsEvent(
      onEvent: (_) async {
        callbackCount += 1;
        return const AppsFlyerDeliveryResult.accepted();
      },
    );

    final unknown = await event.process(
      _payload('af_login')..['eventName'] = 'custom',
    );
    final malformed = await event.process({'requestId': 'request-1'});

    expect((unknown['data'] as Map)['status'], 'rejected');
    expect((unknown['data'] as Map)['reason'], 'unsupported_event_name');
    expect((malformed['data'] as Map)['status'], 'rejected');
    expect(callbackCount, 0);
  });

  test('구매 필수값·event ID·다중 상품 순서를 검증한다', () async {
    const event = AppsFlyerAnalyticsEvent();
    final missingRevenue = _payload('af_purchase');
    (missingRevenue['parameters'] as Map).remove('af_revenue');
    final mismatchedId = _payload('af_purchase')
      ..['eventId'] = 'purchase:other';
    final mismatchedItems = _payload('af_purchase');
    (mismatchedItems['parameters'] as Map)['af_quantity'] = '[1]';

    expect(
      ((await event.process(missingRevenue))['data'] as Map)['reason'],
      'missing_required_parameter',
    );
    expect(
      ((await event.process(mismatchedId))['data'] as Map)['reason'],
      'purchase_event_id_mismatch',
    );
    expect(
      ((await event.process(mismatchedItems))['data'] as Map)['reason'],
      'invalid_complex_content',
    );
  });

  test('PII/credential 또는 비정상 숫자 parameter를 거부한다', () async {
    const event = AppsFlyerAnalyticsEvent();
    final pii = _payload('af_login', parameters: {'email': 'a@example.com'});
    final invalidRevenue = _payload('af_purchase');
    (invalidRevenue['parameters'] as Map)['af_revenue'] = double.nan;

    expect(((await event.process(pii))['data'] as Map)['status'], 'rejected');
    expect(
      ((await event.process(invalidRevenue))['data'] as Map)['reason'],
      'invalid_parameter_value',
    );

    final nestedPii = _payload('af_purchase');
    nestedPii['parameters'] = {
      ...(nestedPii['parameters']! as Map),
      'af_content':
          '[{"id":"product-1","quantity":2,"email":"user@example.com"}]',
    };
    expect(
      ((await event.process(nestedPii))['data'] as Map)['reason'],
      'invalid_complex_content',
    );
  });

  test('callback 미주입과 callback 실패를 typed status로 응답한다', () async {
    const unavailable = AppsFlyerAnalyticsEvent();
    final failing = AppsFlyerAnalyticsEvent(
      onEvent: (_) async => throw StateError('secret'),
    );

    expect(
      ((await unavailable.process(_payload('af_login')))['data']
          as Map)['reason'],
      'handler_unavailable',
    );
    final failed = await failing.process(_payload('af_login'));
    expect((failed['data'] as Map)['status'], 'failed');
    expect((failed['data'] as Map)['reason'], 'callback_failed');
    expect(jsonEncode(failed), isNot(contains('secret')));
  });

  testWidgets('bridge channel이 callback 결과를 request ID ACK로 보낸다', (
    tester,
  ) async {
    final context = await _mountedContext(tester);
    final platformController = _FakePlatformWebViewController();
    final received = Completer<AppsFlyerAnalyticsRequest>();
    final channel = FlutterWebViewBridgeJavaScriptChannel(
      context: context,
      webViewController: WebViewController.fromPlatform(platformController),
      googleServerClientId: null,
      kakaoNativeAppKey: null,
      onAppsFlyerAnalytics: (request) async {
        received.complete(request);
        return const AppsFlyerDeliveryResult.accepted();
      },
    );

    await channel.onMessageReceived(
      JavaScriptMessage(
        message: jsonEncode({
          'type': 'APPS_FLYER_ANALYTICS',
          'data': _payload('af_login'),
        }),
      ),
    );

    expect((await received.future).eventName, 'af_login');
    expect(platformController.evaluatedScripts, hasLength(1));
    expect(
      platformController.evaluatedScripts.single,
      contains('request-af_login'),
    );
    expect(platformController.evaluatedScripts.single, contains('accepted'));
  });
}
