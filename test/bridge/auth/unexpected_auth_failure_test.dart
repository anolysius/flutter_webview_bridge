import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webview_bridge/src/bridge/auth/unexpected_auth_failure.dart';
import 'package:flutter_webview_bridge/src/models/types.dart';

void main() {
  test('unexpected auth handler failures map to canonical stages', () {
    expect(
      unexpectedAuthFailureStage(WebViewBridgeFeatureType.kakaoSignInLogin),
      'native_sdk',
    );
    expect(
      unexpectedAuthFailureStage(WebViewBridgeFeatureType.refreshTokenRead),
      'refresh_exchange',
    );
    expect(
      unexpectedAuthFailureStage(WebViewBridgeFeatureType.refreshTokenWrite),
      'refresh_persist',
    );
    expect(
      unexpectedAuthFailureStage(WebViewBridgeFeatureType.authUiCommitted),
      'ui_commit',
    );
  });

  test('logout cleanup and non-auth features do not create auth terminals', () {
    expect(
      unexpectedAuthFailureStage(WebViewBridgeFeatureType.refreshTokenDelete),
      isNull,
    );
    expect(
      unexpectedAuthFailureStage(WebViewBridgeFeatureType.deviceInfo),
      isNull,
    );
  });
}
