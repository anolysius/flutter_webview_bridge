import 'package:flutter/foundation.dart';

/// Latest device push state. Empty cache means pending, never permission denial.
class WebViewToken {
  static String? _fcmToken;
  static String? get fcmToken => _fcmToken;
  // Keep token-only callers compatible without retaining an old denial state.
  static set fcmToken(String? value) => update(token: value);

  static bool? isNotificationPermissionGranted;
  static String? permissionStatus;
  static String tokenStatus = 'pending';
  static String serviceCountry = 'KR';
  static int revision = 0;

  /// Device identity for push registration (e.g. `iPhone17,1` / `26.0.1`).
  /// Unlike token/permission state these persist when a later update omits
  /// them, so denial or legacy token-only updates still describe the device.
  static String? deviceModel;
  static String? osVersion;

  /// 앱이 지금 OS 권한 창을 다시 띄울 수 있다고 보는지(B3 주문 완료 A-1 / 설정 안내 분기).
  /// 앱이 준 값만 싣는다. 값 없이 온 업데이트(옛 setter 등)는 이전 값을 유지한다.
  static bool? canRequestPermission;

  /// 이 브릿지가 처리할 수 있는 웹 → 앱 기능 이름. 채널이 생성될 때 정한다.
  /// 웹은 여기 이름이 있을 때만 해당 이벤트를 보낸다(옛 앱은 모르는 이벤트에 응답하지 않는다).
  static List<String> capabilities = const [];

  static void update({
    required String? token,
    bool? permissionGranted,
    String? permission,
    String? status,
    String? deviceModel,
    String? osVersion,
    bool? canRequestPermission,
  }) {
    if (canRequestPermission != null) {
      WebViewToken.canRequestPermission = canRequestPermission;
    }
    if (deviceModel != null) WebViewToken.deviceModel = deviceModel;
    if (osVersion != null) WebViewToken.osVersion = osVersion;
    final denied = permissionGranted == false || permission == 'denied';
    _fcmToken = denied ? null : token;
    isNotificationPermissionGranted = denied ? false : permissionGranted;
    permissionStatus = permission;
    tokenStatus = denied
        ? 'pending'
        : (status ?? (token == null ? 'pending' : 'ready'));
    revision++;
  }

  static Map<String, Object?> payload({
    required String platform,
    required bool isRefresh,
  }) => {
    'token': _fcmToken,
    'platform': platform,
    'isRefresh': isRefresh,
    'serviceCountry': serviceCountry,
    'tokenStatus': tokenStatus,
    if (isNotificationPermissionGranted != null)
      'isNotificationPermissionGranted': isNotificationPermissionGranted,
    if (permissionStatus != null) 'permissionStatus': permissionStatus,
    if (deviceModel != null) 'deviceModel': deviceModel,
    if (osVersion != null) 'osVersion': osVersion,
    if (canRequestPermission != null)
      'canRequestPermission': canRequestPermission,
    'capabilities': capabilities,
  };

  /// Clears every cached value (tests only — the app never needs to forget the device).
  @visibleForTesting
  static void reset() {
    _fcmToken = null;
    isNotificationPermissionGranted = null;
    permissionStatus = null;
    tokenStatus = 'pending';
    deviceModel = null;
    osVersion = null;
    canRequestPermission = null;
    capabilities = const [];
  }
}
