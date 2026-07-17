import '../../models/types.dart';

/// Returns the canonical failure stage when an unexpected exception escapes an
/// auth-related bridge handler. `null` means the feature is not an auth attempt
/// boundary and must retain the generic bridge error behavior.
String? unexpectedAuthFailureStage(WebViewBridgeFeatureType type) {
  switch (type) {
    case WebViewBridgeFeatureType.googleSignInLogin:
    case WebViewBridgeFeatureType.appleSignInLogin:
    case WebViewBridgeFeatureType.kakaoSignInLogin:
      return 'native_sdk';
    case WebViewBridgeFeatureType.refreshTokenRead:
      return 'refresh_exchange';
    case WebViewBridgeFeatureType.refreshTokenWrite:
      return 'refresh_persist';
    case WebViewBridgeFeatureType.authUiCommitted:
      return 'ui_commit';
    default:
      return null;
  }
}
