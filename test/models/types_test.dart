import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webview_bridge/src/models/types.dart';

void main() {
  test('clear badge event name round-trips', () {
    expect(WebViewBridgeFeatureType.clearBadge.value, 'CLEAR_BADGE');
    expect(
      'CLEAR_BADGE'.webViewBridgeFeatureType,
      WebViewBridgeFeatureType.clearBadge,
    );
  });

  test('auth context protocol event names round-trip', () {
    const cases = {
      WebViewBridgeFeatureType.authContextStatus: 'AUTH_CONTEXT_STATUS',
      WebViewBridgeFeatureType.authContextStatusAck: 'AUTH_CONTEXT_STATUS_ACK',
      WebViewBridgeFeatureType.authContextMismatchClearAndRestart:
          'AUTH_CONTEXT_MISMATCH_CLEAR_AND_RESTART',
    };

    for (final entry in cases.entries) {
      expect(entry.key.value, entry.value);
      expect(entry.value.webViewBridgeFeatureType, entry.key);
    }
  });
}
