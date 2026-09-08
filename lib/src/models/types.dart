enum WebViewBridgeFeatureType {
  appStateChange,
  pushToken,
  clearBadge,
  deviceInfo,
  cameraAccess,
  photoLibraryAccess,
  setClipboard,
  getClipboard,
  openInAppBrowser,
  openExternalBrowser,
  openAppSettings,
  exitApp,
  googleAnalytics,
  appsFlyerAnalytics,
  airbridgeAnalytics,
  googleSignInLogin,
  googleSignInLogout,
  appleSignInLogin,
  appleSignInLogout,
  kakaoSignInLogin,
  kakaoSignInLogout,
  refreshTokenRead,
  refreshTokenWrite,
  refreshTokenDelete,
  navigateHome,
  channelTalkBoot,
  channelTalkShowMessenger,
  channelTalkShutdown,
  authError,
  authTokensReady,
  authUiCommitted,
  authOnboardingReady,
  authReauthCommitted,
  authReauthRequired,
  authAttemptStarted,
  authContextStatus,
  authContextStatusAck,
  authContextMismatchClearAndRestart,
  serviceCountryQuery,
  serviceCountryChange,
}

extension WebViewBridgeFeatureTypeValue on WebViewBridgeFeatureType {
  String get value {
    switch (this) {
      case WebViewBridgeFeatureType.appStateChange:
        return 'APP_STATE_CHANGE';
      case WebViewBridgeFeatureType.pushToken:
        return 'PUSH_TOKEN';
      case WebViewBridgeFeatureType.clearBadge:
        return 'CLEAR_BADGE';
      case WebViewBridgeFeatureType.deviceInfo:
        return 'DEVICE_INFO';
      case WebViewBridgeFeatureType.cameraAccess:
        return 'CAMERA_ACCESS';
      case WebViewBridgeFeatureType.photoLibraryAccess:
        return 'PHOTO_LIBRARY_ACCESS';
      case WebViewBridgeFeatureType.setClipboard:
        return 'SET_CLIPBOARD';
      case WebViewBridgeFeatureType.getClipboard:
        return 'GET_CLIPBOARD';
      case WebViewBridgeFeatureType.openInAppBrowser:
        return 'OPEN_IN_APP_BROWSER';
      case WebViewBridgeFeatureType.openExternalBrowser:
        return 'OPEN_EXTERNAL_BROWSER';
      case WebViewBridgeFeatureType.openAppSettings:
        return 'OPEN_APP_SETTINGS';
      case WebViewBridgeFeatureType.exitApp:
        return 'EXIT_APP';
      case WebViewBridgeFeatureType.googleAnalytics:
        return 'GOOGLE_ANALYTICS';
      case WebViewBridgeFeatureType.appsFlyerAnalytics:
        return 'APPS_FLYER_ANALYTICS';
      case WebViewBridgeFeatureType.airbridgeAnalytics:
        return 'AIRBRIDGE_ANALYTICS';
      case WebViewBridgeFeatureType.googleSignInLogin:
        return 'GOOGLE_SIGN_IN_LOGIN';
      case WebViewBridgeFeatureType.googleSignInLogout:
        return 'GOOGLE_SIGN_IN_LOGOUT';
      case WebViewBridgeFeatureType.appleSignInLogin:
        return 'APPLE_SIGN_IN_LOGIN';
      case WebViewBridgeFeatureType.appleSignInLogout:
        return 'APPLE_SIGN_IN_LOGOUT';
      case WebViewBridgeFeatureType.kakaoSignInLogin:
        return 'KAKAO_SIGN_IN_LOGIN';
      case WebViewBridgeFeatureType.kakaoSignInLogout:
        return 'KAKAO_SIGN_IN_LOGOUT';
      case WebViewBridgeFeatureType.refreshTokenRead:
        return 'REFRESH_TOKEN_READ';
      case WebViewBridgeFeatureType.refreshTokenWrite:
        return 'REFRESH_TOKEN_WRITE';
      case WebViewBridgeFeatureType.refreshTokenDelete:
        return 'REFRESH_TOKEN_DELETE';
      case WebViewBridgeFeatureType.navigateHome:
        return 'NAVIGATE_HOME';
      case WebViewBridgeFeatureType.channelTalkBoot:
        return 'CHANNEL_TALK_BOOT';
      case WebViewBridgeFeatureType.channelTalkShowMessenger:
        return 'CHANNEL_TALK_SHOW_MESSENGER';
      case WebViewBridgeFeatureType.channelTalkShutdown:
        return 'CHANNEL_TALK_SHUTDOWN';
      case WebViewBridgeFeatureType.authError:
        return 'AUTH_ERROR';
      case WebViewBridgeFeatureType.authTokensReady:
        return 'AUTH_TOKENS_READY';
      case WebViewBridgeFeatureType.authUiCommitted:
        return 'AUTH_UI_COMMITTED';
      case WebViewBridgeFeatureType.authOnboardingReady:
        return 'AUTH_ONBOARDING_READY';
      case WebViewBridgeFeatureType.authReauthCommitted:
        return 'AUTH_REAUTH_COMMITTED';
      case WebViewBridgeFeatureType.authReauthRequired:
        return 'AUTH_REAUTH_REQUIRED';
      case WebViewBridgeFeatureType.authAttemptStarted:
        return 'AUTH_ATTEMPT_STARTED';
      case WebViewBridgeFeatureType.authContextStatus:
        return 'AUTH_CONTEXT_STATUS';
      case WebViewBridgeFeatureType.authContextStatusAck:
        return 'AUTH_CONTEXT_STATUS_ACK';
      case WebViewBridgeFeatureType.authContextMismatchClearAndRestart:
        return 'AUTH_CONTEXT_MISMATCH_CLEAR_AND_RESTART';
      case WebViewBridgeFeatureType.serviceCountryQuery:
        return 'SERVICE_COUNTRY_QUERY';
      case WebViewBridgeFeatureType.serviceCountryChange:
        return 'SERVICE_COUNTRY_CHANGE';
    }
  }
}

extension WebViewBridgeFeatureTypeString on String {
  WebViewBridgeFeatureType? get webViewBridgeFeatureType {
    switch (this) {
      case 'APP_STATE_CHANGE':
        return WebViewBridgeFeatureType.appStateChange;
      case 'PUSH_TOKEN':
        return WebViewBridgeFeatureType.pushToken;
      case 'CLEAR_BADGE':
        return WebViewBridgeFeatureType.clearBadge;
      case 'DEVICE_INFO':
        return WebViewBridgeFeatureType.deviceInfo;
      case 'CAMERA_ACCESS':
        return WebViewBridgeFeatureType.cameraAccess;
      case 'PHOTO_LIBRARY_ACCESS':
        return WebViewBridgeFeatureType.photoLibraryAccess;
      case 'SET_CLIPBOARD':
        return WebViewBridgeFeatureType.setClipboard;
      case 'GET_CLIPBOARD':
        return WebViewBridgeFeatureType.getClipboard;
      case 'OPEN_IN_APP_BROWSER':
        return WebViewBridgeFeatureType.openInAppBrowser;
      case 'OPEN_EXTERNAL_BROWSER':
        return WebViewBridgeFeatureType.openExternalBrowser;
      case 'OPEN_APP_SETTINGS':
        return WebViewBridgeFeatureType.openAppSettings;
      case 'EXIT_APP':
        return WebViewBridgeFeatureType.exitApp;
      case 'GOOGLE_ANALYTICS':
        return WebViewBridgeFeatureType.googleAnalytics;
      case 'APPS_FLYER_ANALYTICS':
        return WebViewBridgeFeatureType.appsFlyerAnalytics;
      case 'AIRBRIDGE_ANALYTICS':
        return WebViewBridgeFeatureType.airbridgeAnalytics;
      case 'GOOGLE_SIGN_IN_LOGIN':
        return WebViewBridgeFeatureType.googleSignInLogin;
      case 'GOOGLE_SIGN_IN_LOGOUT':
        return WebViewBridgeFeatureType.googleSignInLogout;
      case 'APPLE_SIGN_IN_LOGIN':
        return WebViewBridgeFeatureType.appleSignInLogin;
      case 'APPLE_SIGN_IN_LOGOUT':
        return WebViewBridgeFeatureType.appleSignInLogout;
      case 'KAKAO_SIGN_IN_LOGIN':
        return WebViewBridgeFeatureType.kakaoSignInLogin;
      case 'KAKAO_SIGN_IN_LOGOUT':
        return WebViewBridgeFeatureType.kakaoSignInLogout;
      case 'REFRESH_TOKEN_READ':
        return WebViewBridgeFeatureType.refreshTokenRead;
      case 'REFRESH_TOKEN_WRITE':
        return WebViewBridgeFeatureType.refreshTokenWrite;
      case 'REFRESH_TOKEN_DELETE':
        return WebViewBridgeFeatureType.refreshTokenDelete;
      case 'NAVIGATE_HOME':
        return WebViewBridgeFeatureType.navigateHome;
      case 'CHANNEL_TALK_BOOT':
        return WebViewBridgeFeatureType.channelTalkBoot;
      case 'CHANNEL_TALK_SHOW_MESSENGER':
        return WebViewBridgeFeatureType.channelTalkShowMessenger;
      case 'CHANNEL_TALK_SHUTDOWN':
        return WebViewBridgeFeatureType.channelTalkShutdown;
      case 'AUTH_ERROR':
        return WebViewBridgeFeatureType.authError;
      case 'AUTH_TOKENS_READY':
        return WebViewBridgeFeatureType.authTokensReady;
      case 'AUTH_UI_COMMITTED':
        return WebViewBridgeFeatureType.authUiCommitted;
      case 'AUTH_ONBOARDING_READY':
        return WebViewBridgeFeatureType.authOnboardingReady;
      case 'AUTH_REAUTH_COMMITTED':
        return WebViewBridgeFeatureType.authReauthCommitted;
      case 'AUTH_REAUTH_REQUIRED':
        return WebViewBridgeFeatureType.authReauthRequired;
      case 'AUTH_ATTEMPT_STARTED':
        return WebViewBridgeFeatureType.authAttemptStarted;
      case 'AUTH_CONTEXT_STATUS':
        return WebViewBridgeFeatureType.authContextStatus;
      case 'AUTH_CONTEXT_STATUS_ACK':
        return WebViewBridgeFeatureType.authContextStatusAck;
      case 'AUTH_CONTEXT_MISMATCH_CLEAR_AND_RESTART':
        return WebViewBridgeFeatureType.authContextMismatchClearAndRestart;
      case 'SERVICE_COUNTRY_QUERY':
        return WebViewBridgeFeatureType.serviceCountryQuery;
      case 'SERVICE_COUNTRY_CHANGE':
        return WebViewBridgeFeatureType.serviceCountryChange;
    }
    return null;
  }
}

////////////////////////////////////////////////////////////////////////////////

enum GoogleAnalyticsEventType { setUserId, sendLogEvent, sendLogPurchaseEvent }

extension GoogleAnalyticsEventTypeValue on GoogleAnalyticsEventType {
  String get value {
    switch (this) {
      case GoogleAnalyticsEventType.setUserId:
        return 'SET_USER_ID';
      case GoogleAnalyticsEventType.sendLogEvent:
        return 'SEND_LOG_EVENT';
      case GoogleAnalyticsEventType.sendLogPurchaseEvent:
        return 'SEND_LOG_PURCHASE_EVENT';
    }
  }
}

extension GoogleAnalyticsEventTypeString on String {
  GoogleAnalyticsEventType? get googleAnalyticsEventType {
    switch (this) {
      case 'SET_USER_ID':
        return GoogleAnalyticsEventType.setUserId;
      case 'SEND_LOG_EVENT':
        return GoogleAnalyticsEventType.sendLogEvent;
      case 'SEND_LOG_PURCHASE_EVENT':
        return GoogleAnalyticsEventType.sendLogPurchaseEvent;
    }
    return null;
  }
}
