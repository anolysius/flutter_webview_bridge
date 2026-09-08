import '../../models/types.dart';

const Set<String> airbridgeEventCategories = {
  'airbridge.ecommerce.order.completed',
  'airbridge.initiateCheckout',
  'airbridge.ecommerce.product.addedToCart',
  'airbridge.addToWishlist',
  'airbridge.ecommerce.product.viewed',
  'airbridge.ecommerce.searchResults.viewed',
  'airbridge.user.signin',
  'airbridge.user.signup',
};

enum AirbridgeDeliveryStatus { accepted, duplicate, failed }

class AirbridgeDeliveryResult {
  const AirbridgeDeliveryResult({required this.status, this.reason});

  const AirbridgeDeliveryResult.accepted()
    : status = AirbridgeDeliveryStatus.accepted,
      reason = null;

  const AirbridgeDeliveryResult.duplicate()
    : status = AirbridgeDeliveryStatus.duplicate,
      reason = null;

  const AirbridgeDeliveryResult.failed([this.reason])
    : status = AirbridgeDeliveryStatus.failed;

  final AirbridgeDeliveryStatus status;
  final String? reason;
}

class AirbridgeAnalyticsRequest {
  const AirbridgeAnalyticsRequest({
    required this.schemaVersion,
    required this.requestId,
    required this.eventId,
    required this.category,
    required this.occurredAt,
    required this.userId,
    required this.semanticAttributes,
    required this.customAttributes,
  });

  final int schemaVersion;
  final String requestId;
  final String eventId;
  final String category;
  final DateTime occurredAt;
  final String? userId;
  final Map<String, Object> semanticAttributes;
  final Map<String, Object> customAttributes;
}

typedef AirbridgeAnalyticsCallback =
    Future<AirbridgeDeliveryResult> Function(AirbridgeAnalyticsRequest request);

class AirbridgeAnalyticsParseResult {
  const AirbridgeAnalyticsParseResult.success(this.request) : error = null;

  const AirbridgeAnalyticsParseResult.failure(this.error) : request = null;

  final AirbridgeAnalyticsRequest? request;
  final String? error;
}

class AirbridgeAnalyticsEvent {
  const AirbridgeAnalyticsEvent({this.onEvent});

  final AirbridgeAnalyticsCallback? onEvent;

  Future<Map<String, Object?>> process(dynamic data) async {
    final parsed = parse(data);
    final request = parsed.request;
    final requestId = data is Map ? _boundedString(data['requestId']) : null;
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
        status: result.status.name,
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

  AirbridgeAnalyticsParseResult parse(dynamic data) {
    if (data is! Map) {
      return const AirbridgeAnalyticsParseResult.failure('invalid_payload');
    }

    final schemaVersion = data['schemaVersion'];
    final requestId = _boundedString(data['requestId']);
    final eventId = _boundedString(data['eventId']);
    final category = _boundedString(data['category'], maxLength: 100);
    final occurredAtRaw = _boundedString(data['occurredAt']);
    final userIdRaw = data['userId'];
    final userId = userIdRaw == null
        ? null
        : _boundedString(userIdRaw, maxLength: 128);

    if (schemaVersion is! int || schemaVersion != 1) {
      return const AirbridgeAnalyticsParseResult.failure(
        'unsupported_schema_version',
      );
    }
    if (requestId == null || eventId == null) {
      return const AirbridgeAnalyticsParseResult.failure('invalid_id');
    }
    if (category == null || !airbridgeEventCategories.contains(category)) {
      return const AirbridgeAnalyticsParseResult.failure(
        'unsupported_category',
      );
    }
    if (occurredAtRaw == null) {
      return const AirbridgeAnalyticsParseResult.failure('invalid_occurred_at');
    }
    final occurredAt = DateTime.tryParse(occurredAtRaw);
    if (occurredAt == null || !occurredAt.isUtc) {
      return const AirbridgeAnalyticsParseResult.failure('invalid_occurred_at');
    }
    if (userIdRaw != null && userId == null) {
      return const AirbridgeAnalyticsParseResult.failure('invalid_user_id');
    }

    final semanticResult = _parseSemanticAttributes(
      category,
      data['semanticAttributes'],
    );
    if (semanticResult.error != null) {
      return AirbridgeAnalyticsParseResult.failure(semanticResult.error);
    }
    final customResult = _parseCustomAttributes(data['customAttributes']);
    if (customResult.error != null) {
      return AirbridgeAnalyticsParseResult.failure(customResult.error);
    }

    final semanticAttributes = semanticResult.attributes!;
    if (category == 'airbridge.ecommerce.order.completed') {
      final transactionId = semanticAttributes['transactionID'];
      if (transactionId is! String || eventId != 'purchase:$transactionId') {
        return const AirbridgeAnalyticsParseResult.failure(
          'purchase_event_id_mismatch',
        );
      }
    }

    return AirbridgeAnalyticsParseResult.success(
      AirbridgeAnalyticsRequest(
        schemaVersion: schemaVersion,
        requestId: requestId,
        eventId: eventId,
        category: category,
        occurredAt: occurredAt,
        userId: userId,
        semanticAttributes: semanticAttributes,
        customAttributes: customResult.attributes!,
      ),
    );
  }

  Map<String, Object?> _response({
    required String? requestId,
    required String status,
    String? reason,
  }) {
    return {
      'type': WebViewBridgeFeatureType.airbridgeAnalytics.value,
      'data': {
        'requestId': requestId,
        'status': status,
        if (reason != null) 'reason': reason,
      },
    };
  }
}

class _AttributesParseResult {
  const _AttributesParseResult.success(this.attributes) : error = null;

  const _AttributesParseResult.failure(this.error) : attributes = null;

  final Map<String, Object>? attributes;
  final String? error;
}

_AttributesParseResult _parseSemanticAttributes(String category, dynamic raw) {
  if (raw is! Map || raw.length > 12) {
    return const _AttributesParseResult.failure('invalid_semantic_attributes');
  }

  const commerceKeys = {'value', 'currency', 'products', 'totalQuantity'};
  const allowedByCategory = <String, Set<String>>{
    'airbridge.ecommerce.order.completed': {
      ...commerceKeys,
      'transactionID',
      'inAppPurchased',
    },
    'airbridge.initiateCheckout': commerceKeys,
    'airbridge.ecommerce.product.addedToCart': commerceKeys,
    'airbridge.addToWishlist': commerceKeys,
    'airbridge.ecommerce.product.viewed': commerceKeys,
    'airbridge.ecommerce.searchResults.viewed': {'query'},
    'airbridge.user.signin': <String>{},
    'airbridge.user.signup': <String>{},
  };
  const requiredByCategory = <String, Set<String>>{
    'airbridge.ecommerce.order.completed': {
      'transactionID',
      'value',
      'currency',
      'products',
    },
    'airbridge.initiateCheckout': {'value', 'currency', 'products'},
    'airbridge.ecommerce.product.addedToCart': {'currency', 'products'},
    'airbridge.addToWishlist': {'currency', 'products'},
    'airbridge.ecommerce.product.viewed': {'currency', 'products'},
    'airbridge.ecommerce.searchResults.viewed': {'query'},
    'airbridge.user.signin': <String>{},
    'airbridge.user.signup': <String>{},
  };

  final allowed = allowedByCategory[category]!;
  final result = <String, Object>{};
  for (final entry in raw.entries) {
    final key = entry.key;
    if (key is! String || !allowed.contains(key)) {
      return const _AttributesParseResult.failure(
        'unsupported_semantic_attribute',
      );
    }
    final value = entry.value;
    if (!_isValidSemanticValue(key, value)) {
      return const _AttributesParseResult.failure('invalid_attribute_value');
    }
    result[key] = value as Object;
  }

  if (!result.keys.toSet().containsAll(requiredByCategory[category]!)) {
    return const _AttributesParseResult.failure(
      'missing_required_semantic_attribute',
    );
  }
  if (result.containsKey('products') &&
      !_hasValidProducts(result['products'])) {
    return const _AttributesParseResult.failure('invalid_products');
  }
  return _AttributesParseResult.success(result);
}

_AttributesParseResult _parseCustomAttributes(dynamic raw) {
  if (raw == null) return const _AttributesParseResult.success({});
  if (raw is! Map || raw.length > 20) {
    return const _AttributesParseResult.failure('invalid_custom_attributes');
  }

  final result = <String, Object>{};
  for (final entry in raw.entries) {
    final key = entry.key;
    final value = entry.value;
    if (key is! String ||
        key.isEmpty ||
        key.length > 64 ||
        _isForbiddenKey(key)) {
      return const _AttributesParseResult.failure('forbidden_attribute_key');
    }
    if (!_isScalar(value) ||
        (value is String && (value.isEmpty || value.length > 2048))) {
      return const _AttributesParseResult.failure('invalid_attribute_value');
    }
    result[key] = value as Object;
  }
  return _AttributesParseResult.success(result);
}

bool _isValidSemanticValue(String key, dynamic value) {
  switch (key) {
    case 'transactionID':
      return _boundedString(value) != null;
    case 'query':
      return _boundedString(value, maxLength: 1000) != null;
    case 'currency':
      return value is String && RegExp(r'^[A-Z]{3}$').hasMatch(value);
    case 'value':
      return _isNonNegativeNumber(value);
    case 'totalQuantity':
      return value is num && value.isFinite && value > 0;
    case 'inAppPurchased':
      return value is bool;
    case 'products':
      return value is List;
  }
  return false;
}

bool _hasValidProducts(Object? raw) {
  if (raw is! List || raw.isEmpty || raw.length > 100) return false;
  const allowedKeys = {'productID', 'name', 'price', 'quantity', 'currency'};
  for (final product in raw) {
    if (product is! Map ||
        product.keys.any(
          (key) => key is! String || !allowedKeys.contains(key),
        )) {
      return false;
    }
    final productId = _boundedString(product['productID']);
    final productName = product['name'];
    final price = product['price'];
    final quantity = product['quantity'];
    final currency = product['currency'];
    if (productId == null ||
        (productName != null &&
            _boundedString(productName, maxLength: 1000) == null) ||
        !_isNonNegativeNumber(price) ||
        price == null ||
        quantity is! num ||
        !quantity.isFinite ||
        quantity <= 0 ||
        currency is! String ||
        !RegExp(r'^[A-Z]{3}$').hasMatch(currency)) {
      return false;
    }
  }
  return true;
}

bool _isNonNegativeNumber(dynamic value) =>
    value is num && value.isFinite && value >= 0;

bool _isScalar(dynamic value) =>
    value is String || value is bool || (value is num && value.isFinite);

bool _isForbiddenKey(String key) {
  final normalized = key.toLowerCase();
  return const [
    'email',
    'phone',
    'token',
    'address',
    'password',
    'credential',
  ].any(normalized.contains);
}

String? _boundedString(dynamic value, {int maxLength = 200}) {
  if (value is! String) return null;
  final normalized = value.trim();
  if (normalized.isEmpty || normalized.length > maxLength) return null;
  return normalized;
}
