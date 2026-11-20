import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart' as ph;

import '../../models/token.dart';
import '../../models/types.dart';

/// 웹 → 앱 알림 권한 기능(B3)의 앱 쪽 구현. `data` 는 웹이 보낸 원본이다.
///
/// 돌려준 Map 이 응답 `data` 가 된다. 브릿지가 `requestId` 를 붙인다.
typedef PushPermissionCallback =
    Future<Map<String, Object?>> Function(Object? data);

/// 웹이 기능 지원 여부를 판단할 이름. [WebViewToken.capabilities] 에 실린다.
abstract final class PushPermissionCapability {
  static const request = 'pushPermissionRequest';
  static const status = 'pushPermissionStatus';
  static const openNotificationSettings = 'openNotificationSettings';

  /// 상태 조회와 설정 열기는 앱 콜백이 없어도 기본 구현이 있다.
  /// 권한 요청은 앱이 콜백을 넣었을 때만 광고한다.
  static List<String> of({required bool canRequest}) => [
    if (canRequest) request,
    status,
    openNotificationSettings,
  ];
}

/// 세 이벤트의 응답을 만든다. 브릿지의 직렬 메시지 큐 밖에서 돈다.
///
/// 권한 요청은 고객이 OS 창에 답할 때까지 걸린다. 그동안 인증 같은 다른 브릿지 메시지가
/// 막히면 안 되므로 큐 안에서 기다리지 않는다(REQUEST_APP_REVIEW 와 같은 이유).
class PushPermissionEvents {
  PushPermissionEvents({
    this.onRequest,
    this.onStatus,
    this.onOpenNotificationSettings,
    Future<bool> Function()? openAppSettings,
  }) : _openAppSettings = openAppSettings ?? ph.openAppSettings;

  final PushPermissionCallback? onRequest;
  final PushPermissionCallback? onStatus;
  final PushPermissionCallback? onOpenNotificationSettings;
  final Future<bool> Function() _openAppSettings;

  /// 권한 요청 응답 상한. 넘기면 `unavailable` 로 답해 웹이 무한히 기다리지 않게 한다.
  static const requestTimeout = Duration(seconds: 60);

  bool _requestInFlight = false;

  List<String> get capabilities =>
      PushPermissionCapability.of(canRequest: onRequest != null);

  static bool handles(WebViewBridgeFeatureType type) =>
      type == WebViewBridgeFeatureType.pushPermissionRequest ||
      type == WebViewBridgeFeatureType.pushPermissionStatus ||
      type == WebViewBridgeFeatureType.openNotificationSettings;

  /// 응답 메시지 전체(`type` + `data`)를 만든다.
  Future<Map<String, Object?>> respond(
    WebViewBridgeFeatureType type,
    Object? data,
  ) async {
    final Map<String, Object?> body;
    switch (type) {
      case WebViewBridgeFeatureType.pushPermissionRequest:
        body = await _request(data);
      case WebViewBridgeFeatureType.pushPermissionStatus:
        body = await _status(data);
      case WebViewBridgeFeatureType.openNotificationSettings:
        body = await _openSettings(data);
      default:
        throw ArgumentError.value(type, 'type');
    }
    final requestId = requestIdOf(data);
    return {
      'type': type.value,
      'data': {...body, if (requestId != null) 'requestId': requestId},
    };
  }

  /// 문자열일 때만 돌려준다. 숫자 등은 오류 없이 생략한다.
  static String? requestIdOf(Object? data) {
    if (data is Map && data['requestId'] is String) {
      return data['requestId'] as String;
    }
    return null;
  }

  Future<Map<String, Object?>> _request(Object? data) async {
    final callback = onRequest;
    if (callback == null) return _unavailable();
    if (_requestInFlight) return {'result': 'busy', 'promptShown': false};
    _requestInFlight = true;
    try {
      return await callback(data).timeout(requestTimeout);
    } on TimeoutException {
      return _unavailable();
    } catch (error) {
      debugPrint('[PushPermission] request failed: $error');
      return _unavailable();
    } finally {
      _requestInFlight = false;
    }
  }

  Future<Map<String, Object?>> _status(Object? data) async {
    Map<String, Object?> body;
    final callback = onStatus;
    try {
      body = callback == null ? _cachedStatus() : await callback(data);
    } catch (error) {
      debugPrint('[PushPermission] status failed: $error');
      body = _cachedStatus();
    }
    return {...body, 'capabilities': capabilities};
  }

  Future<Map<String, Object?>> _openSettings(Object? data) async {
    final callback = onOpenNotificationSettings;
    try {
      if (callback != null) return await callback(data);
      // 브릿지는 순수 Dart 라 알림 설정으로 바로 갈 수 없다. 앱 설정까지만 연다.
      final opened = await _openAppSettings();
      return {'opened': opened ? 'app' : 'failed'};
    } catch (error) {
      debugPrint('[PushPermission] open settings failed: $error');
      return {'opened': 'failed'};
    }
  }

  static Map<String, Object?> _cachedStatus() => {
    if (WebViewToken.permissionStatus != null)
      'permissionStatus': WebViewToken.permissionStatus,
    if (WebViewToken.canRequestPermission != null)
      'canRequestPermission': WebViewToken.canRequestPermission,
  };

  static Map<String, Object?> _unavailable() => {
    'result': 'unavailable',
    'promptShown': false,
  };
}
