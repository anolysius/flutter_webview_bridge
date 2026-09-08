import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webview_bridge/flutter_webview_bridge.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

Map<String, Object?> _payload(
  String category, {
  Map<String, Object?>? semanticAttributes,
  Map<String, Object?>? customAttributes,
}) {
  const transactionId = 'order-1';
  return {
    'schemaVersion': 1,
    'requestId': 'request-$category',
    'eventId': category == 'airbridge.ecommerce.order.completed'
        ? 'purchase:$transactionId'
        : '$category:event-1',
    'category': category,
    'occurredAt': '2026-09-04T12:00:00.000Z',
    'userId': 'user-1',
    'semanticAttributes':
        semanticAttributes ?? _semanticAttributes(category, transactionId),
    if (customAttributes != null) 'customAttributes': customAttributes,
  };
}

Map<String, Object?> _semanticAttributes(
  String category,
  String transactionId,
) {
  final product = <String, Object?>{
    'productID': 'item-1',
    'name': 'Camera',
    'price': 1000,
    'quantity': 2,
    'currency': 'KRW',
  };
  switch (category) {
    case 'airbridge.ecommerce.order.completed':
      return {
        'transactionID': transactionId,
        'value': 2000,
        'currency': 'KRW',
        'products': [product],
        'totalQuantity': 2,
        'inAppPurchased': true,
      };
    case 'airbridge.initiateCheckout':
      return {
        'value': 2000,
        'currency': 'KRW',
        'products': [product],
        'totalQuantity': 2,
      };
    case 'airbridge.ecommerce.product.addedToCart':
    case 'airbridge.addToWishlist':
    case 'airbridge.ecommerce.product.viewed':
      return {
        'value': 1000,
        'currency': 'KRW',
        'products': [product],
      };
    case 'airbridge.ecommerce.searchResults.viewed':
      return {'query': 'camera'};
    case 'airbridge.user.signin':
    case 'airbridge.user.signup':
      return const {};
  }
  throw ArgumentError.value(category);
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

  test('8개 표준 category를 typed callback으로 전달한다', () async {
    final received = <AirbridgeAnalyticsRequest>[];
    final event = AirbridgeAnalyticsEvent(
      onEvent: (request) async {
        received.add(request);
        return const AirbridgeDeliveryResult.accepted();
      },
    );

    for (final category in airbridgeEventCategories) {
      final response = await event.process(_payload(category));
      expect(response['type'], 'AIRBRIDGE_ANALYTICS');
      expect((response['data'] as Map)['status'], 'accepted');
    }

    expect(
      received.map((request) => request.category).toSet(),
      airbridgeEventCategories,
    );
    expect(received.every((request) => request.userId == 'user-1'), isTrue);
  });

  test('unknown category와 malformed payload는 callback 전에 거부한다', () async {
    var callbackCount = 0;
    final event = AirbridgeAnalyticsEvent(
      onEvent: (_) async {
        callbackCount += 1;
        return const AirbridgeDeliveryResult.accepted();
      },
    );

    final unknown = await event.process(
      _payload('airbridge.user.signin')..['category'] = 'custom',
    );
    final malformed = await event.process({'requestId': 'request-1'});
    final nonIntegerVersion = await event.process(
      _payload('airbridge.user.signin')..['schemaVersion'] = 1.0,
    );
    final oversizedId = await event.process(
      _payload('airbridge.user.signin')
        ..['requestId'] = List.filled(201, 'x').join(),
    );

    expect((unknown['data'] as Map)['status'], 'rejected');
    expect((unknown['data'] as Map)['reason'], 'unsupported_category');
    expect((malformed['data'] as Map)['status'], 'rejected');
    expect(
      (nonIntegerVersion['data'] as Map)['reason'],
      'unsupported_schema_version',
    );
    expect((oversizedId['data'] as Map)['requestId'], isNull);
    expect(callbackCount, 0);
  });

  test('구매 필수값과 transaction ID 정합성을 검증한다', () async {
    const event = AirbridgeAnalyticsEvent();
    final missingValue = _payload('airbridge.ecommerce.order.completed');
    (missingValue['semanticAttributes'] as Map).remove('value');
    final mismatchedId = _payload('airbridge.ecommerce.order.completed')
      ..['eventId'] = 'purchase:other';

    expect(
      ((await event.process(missingValue))['data'] as Map)['reason'],
      'missing_required_semantic_attribute',
    );
    expect(
      ((await event.process(mismatchedId))['data'] as Map)['reason'],
      'purchase_event_id_mismatch',
    );
  });

  test('PII/credential, 비정상 숫자, 과대 상품 배열을 거부한다', () async {
    const event = AirbridgeAnalyticsEvent();
    final pii = _payload(
      'airbridge.user.signin',
      customAttributes: {'email': 'a@example.com'},
    );
    final invalidValue = _payload('airbridge.ecommerce.order.completed');
    (invalidValue['semanticAttributes'] as Map)['value'] = double.nan;
    final tooManyProducts = _payload('airbridge.initiateCheckout');
    (tooManyProducts['semanticAttributes'] as Map)['products'] = List.generate(
      101,
      (index) => {
        'productID': 'item-$index',
        'price': 1,
        'quantity': 1,
        'currency': 'KRW',
      },
    );

    expect(
      ((await event.process(pii))['data'] as Map)['reason'],
      'forbidden_attribute_key',
    );
    expect(
      ((await event.process(invalidValue))['data'] as Map)['reason'],
      'invalid_attribute_value',
    );
    expect(
      ((await event.process(tooManyProducts))['data'] as Map)['reason'],
      'invalid_products',
    );
  });

  test('callback 미주입과 callback 실패를 typed status로 응답한다', () async {
    const unavailable = AirbridgeAnalyticsEvent();
    final failing = AirbridgeAnalyticsEvent(
      onEvent: (_) async => throw StateError('secret'),
    );

    expect(
      ((await unavailable.process(_payload('airbridge.user.signin')))['data']
          as Map)['reason'],
      'handler_unavailable',
    );
    final failed = await failing.process(_payload('airbridge.user.signin'));
    expect((failed['data'] as Map)['status'], 'failed');
    expect((failed['data'] as Map)['reason'], 'callback_failed');
    expect(jsonEncode(failed), isNot(contains('secret')));
  });

  testWidgets('bridge channel이 Airbridge callback 결과를 request ID ACK로 보낸다', (
    tester,
  ) async {
    final context = await _mountedContext(tester);
    final platformController = _FakePlatformWebViewController();
    final received = Completer<AirbridgeAnalyticsRequest>();
    final channel = FlutterWebViewBridgeJavaScriptChannel(
      context: context,
      webViewController: WebViewController.fromPlatform(platformController),
      googleServerClientId: null,
      kakaoNativeAppKey: null,
      onAirbridgeAnalytics: (request) async {
        received.complete(request);
        return const AirbridgeDeliveryResult.accepted();
      },
    );

    await channel.onMessageReceived(
      JavaScriptMessage(
        message: jsonEncode({
          'type': 'AIRBRIDGE_ANALYTICS',
          'data': _payload('airbridge.user.signin'),
        }),
      ),
    );

    expect((await received.future).category, 'airbridge.user.signin');
    expect(platformController.evaluatedScripts, hasLength(1));
    expect(
      platformController.evaluatedScripts.single,
      contains('request-airbridge.user.signin'),
    );
    expect(platformController.evaluatedScripts.single, contains('accepted'));
  });
}
