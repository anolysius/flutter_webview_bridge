import 'dart:async';
import 'dart:convert';

import '../../models/types.dart';

const Set<String> appsFlyerEventNames = {
  'af_purchase',
  'af_initiated_checkout',
  'af_add_to_cart',
  'af_add_to_wishlist',
  'af_content_view',
  'af_search',
  'af_login',
  'af_complete_registration',
};

enum AppsFlyerDeliveryStatus { accepted, duplicate, failed }

extension AppsFlyerDeliveryStatusValue on AppsFlyerDeliveryStatus {
  String get value => name;
}

class AppsFlyerDeliveryResult {
  const AppsFlyerDeliveryResult({required this.status, this.reason});

  const AppsFlyerDeliveryResult.accepted()
    : status = AppsFlyerDeliveryStatus.accepted,
      reason = null;

  const AppsFlyerDeliveryResult.duplicate()
    : status = AppsFlyerDeliveryStatus.duplicate,
      reason = null;

  const AppsFlyerDeliveryResult.failed([this.reason])
    : status = AppsFlyerDeliveryStatus.failed;

  final AppsFlyerDeliveryStatus status;
  final String? reason;
}

class AppsFlyerAnalyticsRequest {
  const AppsFlyerAnalyticsRequest({
    required this.schemaVersion,
    required this.requestId,
    required this.eventId,
    required this.eventName,
    required this.occurredAt,
    required this.customerUserId,
    required this.parameters,
  });

  final int schemaVersion;
  final String requestId;
  final String eventId;
  final String eventName;
  final DateTime occurredAt;
  final String? customerUserId;
  final Map<String, Object> parameters;
}

typedef AppsFlyerAnalyticsCallback =
    Future<AppsFlyerDeliveryResult> Function(AppsFlyerAnalyticsRequest request);

class AppsFlyerAnalyticsParseResult {
  const AppsFlyerAnalyticsParseResult.success(this.request) : error = null;

  const AppsFlyerAnalyticsParseResult.failure(this.error) : request = null;

  final AppsFlyerAnalyticsRequest? request;
  final String? error;
}

class AppsFlyerAnalyticsEvent {
  const AppsFlyerAnalyticsEvent({this.onEvent});

  final AppsFlyerAnalyticsCallback? onEvent;

  Future<Map<String, Object?>> process(dynamic data) async {
    final parsed = parse(data);
    final request = parsed.request;
    final requestId = _stringField(data, 'requestId');
    if (request == null) {
      return _response(
        requestId: requestId,
        status: 'rejected',
        reason: parsed.error ?? 'invalid_payload',
      );
    }

    final callback = onEvent;
    if (callback == null) {
      return _response(
        requestId: request.requestId,
        status: 'rejected',
        reason: 'handler_unavailable',
      );
    }

    try {
      final result = await callback(request);
      return _response(
        requestId: request.requestId,
        status: result.status.value,
        reason: result.reason,
      );
    } catch (_) {
      return _response(
        requestId: request.requestId,
        status: 'failed',
        reason: 'callback_failed',
      );
    }
  }

  AppsFlyerAnalyticsParseResult parse(dynamic data) {
    if (data is! Map) {
      return const AppsFlyerAnalyticsParseResult.failure('invalid_payload');
    }

    final schemaVersion = data['schemaVersion'];
    final requestId = _boundedString(data['requestId']);
    final eventId = _boundedString(data['eventId']);
    final eventName = _boundedString(data['eventName'], maxLength: 45);
    final occurredAtRaw = _boundedString(data['occurredAt']);
    final customerUserIdRaw = data['customerUserId'];
    final customerUserId = customerUserIdRaw == null
        ? null
        : _boundedString(customerUserIdRaw, maxLength: 128);

    if (schemaVersion != 1) {
      return const AppsFlyerAnalyticsParseResult.failure(
        'unsupported_schema_version',
      );
    }
    if (requestId == null || eventId == null) {
      return const AppsFlyerAnalyticsParseResult.failure('invalid_id');
    }
    if (eventName == null || !appsFlyerEventNames.contains(eventName)) {
      return const AppsFlyerAnalyticsParseResult.failure(
        'unsupported_event_name',
      );
    }
    if (occurredAtRaw == null) {
      return const AppsFlyerAnalyticsParseResult.failure('invalid_occurred_at');
    }
    final occurredAt = DateTime.tryParse(occurredAtRaw);
    if (occurredAt == null || !occurredAt.isUtc) {
      return const AppsFlyerAnalyticsParseResult.failure('invalid_occurred_at');
    }
    if (customerUserIdRaw != null && customerUserId == null) {
      return const AppsFlyerAnalyticsParseResult.failure(
        'invalid_customer_user_id',
      );
    }

    final parametersResult = _parseParameters(eventName, data['parameters']);
    if (parametersResult.error != null) {
      return AppsFlyerAnalyticsParseResult.failure(parametersResult.error);
    }
    final parameters = parametersResult.parameters!;

    if (eventName == 'af_purchase') {
      final orderId = parameters['af_order_id'];
      if (orderId is! String || eventId != 'purchase:$orderId') {
        return const AppsFlyerAnalyticsParseResult.failure(
          'purchase_event_id_mismatch',
        );
      }
    }

    return AppsFlyerAnalyticsParseResult.success(
      AppsFlyerAnalyticsRequest(
        schemaVersion: schemaVersion as int,
        requestId: requestId,
        eventId: eventId,
        eventName: eventName,
        occurredAt: occurredAt,
        customerUserId: customerUserId,
        parameters: parameters,
      ),
    );
  }

  Map<String, Object?> _response({
    required String? requestId,
    required String status,
    String? reason,
  }) {
    return {
      'type': WebViewBridgeFeatureType.appsFlyerAnalytics.value,
      'data': {
        'requestId': requestId,
        'status': status,
        if (reason != null) 'reason': reason,
      },
    };
  }
}

class _ParametersParseResult {
  const _ParametersParseResult.success(this.parameters) : error = null;

  const _ParametersParseResult.failure(this.error) : parameters = null;

  final Map<String, Object>? parameters;
  final String? error;
}

_ParametersParseResult _parseParameters(String eventName, dynamic raw) {
  if (raw is! Map) {
    return const _ParametersParseResult.failure('invalid_parameters');
  }
  if (raw.length > 12) {
    return const _ParametersParseResult.failure('too_many_parameters');
  }

  const productKeys = {
    'af_price',
    'af_currency',
    'af_content',
    'af_content_id',
    'af_content_type',
    'af_quantity',
  };
  const allowedByEvent = <String, Set<String>>{
    'af_purchase': {
      ...productKeys,
      'af_revenue',
      'af_order_id',
      'af_receipt_id',
    },
    'af_initiated_checkout': productKeys,
    'af_add_to_cart': productKeys,
    'af_add_to_wishlist': productKeys,
    'af_content_view': productKeys,
    'af_search': {'af_search_string', 'af_content_list'},
    'af_login': {'af_registration_method'},
    'af_complete_registration': {'af_registration_method'},
  };
  const requiredByEvent = <String, Set<String>>{
    'af_purchase': {
      'af_revenue',
      'af_price',
      'af_currency',
      'af_order_id',
      'af_receipt_id',
      'af_content',
      'af_content_id',
      'af_quantity',
    },
    'af_initiated_checkout': {
      'af_price',
      'af_currency',
      'af_content',
      'af_content_id',
      'af_quantity',
    },
    'af_add_to_cart': {
      'af_price',
      'af_currency',
      'af_content_id',
      'af_content_type',
      'af_quantity',
    },
    'af_add_to_wishlist': {
      'af_price',
      'af_currency',
      'af_content_id',
      'af_content_type',
    },
    'af_content_view': {
      'af_price',
      'af_currency',
      'af_content_id',
      'af_content_type',
    },
    'af_search': {'af_search_string'},
    'af_login': <String>{},
    'af_complete_registration': <String>{},
  };

  final allowed = allowedByEvent[eventName]!;
  final parameters = <String, Object>{};
  for (final entry in raw.entries) {
    final key = entry.key;
    final value = entry.value;
    if (key is! String || !allowed.contains(key)) {
      return const _ParametersParseResult.failure('unsupported_parameter_key');
    }
    final normalizedKey = key.toLowerCase();
    if (const [
      'email',
      'phone',
      'token',
      'address',
      'password',
    ].any(normalizedKey.contains)) {
      return const _ParametersParseResult.failure('forbidden_parameter_key');
    }
    if (value is num && !value.isFinite) {
      return const _ParametersParseResult.failure('invalid_parameter_value');
    }
    if (value is! String && value is! num && value is! bool) {
      return const _ParametersParseResult.failure('invalid_parameter_value');
    }
    if (value is String) {
      final maxLength = key == 'af_content' ? 65536 : 2048;
      if (value.isEmpty || value.length > maxLength) {
        return const _ParametersParseResult.failure('invalid_parameter_value');
      }
    }
    parameters[key] = value as Object;
  }

  if (!parameters.keys.toSet().containsAll(requiredByEvent[eventName]!)) {
    return const _ParametersParseResult.failure('missing_required_parameter');
  }
  if (!_isNonNegativeNumber(parameters['af_price']) ||
      !_isNonNegativeNumber(parameters['af_revenue'])) {
    return const _ParametersParseResult.failure('invalid_monetary_value');
  }
  final currency = parameters['af_currency'];
  if (currency != null &&
      (currency is! String || !RegExp(r'^[A-Z]{3}$').hasMatch(currency))) {
    return const _ParametersParseResult.failure('invalid_currency');
  }
  if (parameters.containsKey('af_content') &&
      !_hasValidComplexContent(parameters)) {
    return const _ParametersParseResult.failure('invalid_complex_content');
  }

  return _ParametersParseResult.success(parameters);
}

bool _isNonNegativeNumber(Object? value) =>
    value == null || (value is num && value.isFinite && value >= 0);

bool _hasValidComplexContent(Map<String, Object> parameters) {
  try {
    final content = jsonDecode(parameters['af_content']! as String);
    final contentIds = jsonDecode(parameters['af_content_id']! as String);
    final quantities = jsonDecode(parameters['af_quantity']! as String);
    if (content is! List || contentIds is! List || quantities is! List) {
      return false;
    }
    if (content.isEmpty ||
        content.length > 100 ||
        content.length != contentIds.length ||
        content.length != quantities.length) {
      return false;
    }
    const allowedItemKeys = {
      'id',
      'name',
      'price',
      'quantity',
      'brand',
      'category',
      'platform',
    };
    for (var index = 0; index < content.length; index += 1) {
      final item = content[index];
      final contentId = contentIds[index];
      final quantity = quantities[index];
      if (item is! Map ||
          item.keys.any(
            (key) => key is! String || !allowedItemKeys.contains(key),
          ) ||
          contentId is! String ||
          contentId.isEmpty ||
          contentId.length > 200 ||
          quantity is! num ||
          !quantity.isFinite ||
          quantity <= 0 ||
          item['id'] != contentId ||
          item['quantity'] != quantity ||
          !_hasValidItemValues(item)) {
        return false;
      }
    }
    return true;
  } catch (_) {
    return false;
  }
}

bool _hasValidItemValues(Map<dynamic, dynamic> item) {
  final id = item['id'];
  final name = item['name'];
  final price = item['price'];
  final quantity = item['quantity'];
  if (id is! String || id.isEmpty || id.length > 200) return false;
  if (name != null && (name is! String || name.length > 1000)) return false;
  if (price != null && (price is! num || !price.isFinite || price.isNegative)) {
    return false;
  }
  if (quantity is! num || !quantity.isFinite || quantity <= 0) return false;
  for (final key in const ['brand', 'category', 'platform']) {
    final value = item[key];
    if (value != null && (value is! String || value.length > 500)) return false;
  }
  return true;
}

String? _boundedString(dynamic value, {int maxLength = 200}) {
  if (value is! String) return null;
  final normalized = value.trim();
  if (normalized.isEmpty || normalized.length > maxLength) return null;
  return normalized;
}

String? _stringField(dynamic data, String key) {
  if (data is! Map) return null;
  final value = data[key];
  return value is String ? value : null;
}
