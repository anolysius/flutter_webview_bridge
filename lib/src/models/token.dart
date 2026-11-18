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

  static void update({
    required String? token,
    bool? permissionGranted,
    String? permission,
    String? status,
    String? deviceModel,
    String? osVersion,
  }) {
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
  }
}
