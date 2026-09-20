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

  static void update({
    required String? token,
    bool? permissionGranted,
    String? permission,
    String? status,
  }) {
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
  };
}
