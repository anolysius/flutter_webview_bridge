import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webview_bridge/flutter_webview_bridge.dart';

void main() {
  tearDown(() {
    WebViewToken.fcmToken = null;
    WebViewToken.serviceCountry = 'KR';
  });

  test('empty cache is pending, not denied', () {
    WebViewToken.fcmToken = null;
    final data = WebViewToken.payload(platform: 'ios', isRefresh: false);
    expect(data['tokenStatus'], 'pending');
    expect(data.containsKey('isNotificationPermissionGranted'), false);
  });

  test('legacy assignment clears old permission metadata', () {
    WebViewToken.update(
      token: 'old',
      permissionGranted: false,
      permission: 'denied',
    );
    WebViewToken.fcmToken = 'legacy';
    final data = WebViewToken.payload(platform: 'android', isRefresh: false);
    expect(data['token'], 'legacy');
    expect(data['tokenStatus'], 'ready');
    expect(data.containsKey('isNotificationPermissionGranted'), false);
  });

  test('denial never exposes cached token, even if caller supplies one', () {
    WebViewToken.update(
      token: 'old',
      permissionGranted: false,
      permission: 'denied',
    );
    final data = WebViewToken.payload(platform: 'ios', isRefresh: true);
    expect(data['token'], isNull);
    expect(data['isNotificationPermissionGranted'], false);
    expect(data['permissionStatus'], 'denied');
  });

  test(
    'automatic delivery updates query cache with same complete state',
    () async {
      final controller = WebViewBridgeController();
      // No web channel yet: the send remains queued but query cache is ready.
      final pending = controller.runJavaScriptSetPushToken(
        'new',
        isRefresh: true,
        isNotificationPermissionGranted: true,
        permissionStatus: 'provisional',
        tokenStatus: 'ready',
      );
      final data = WebViewToken.payload(platform: 'ios', isRefresh: false);
      expect(data['token'], 'new');
      expect(data['permissionStatus'], 'provisional');
      expect(data['isNotificationPermissionGranted'], true);
      expect(data['tokenStatus'], 'ready');
      // Dispose explicitly settles queued requests (the API may terminate with error).
      final settled = pending.catchError((Object _) {});
      controller.dispose(forceTerminate: true);
      await settled;
    },
  );

  test('query uses current country and revision increases for replacement', () {
    final revision = WebViewToken.revision;
    WebViewToken.update(
      token: null,
      permission: 'authorized',
      permissionGranted: true,
      status: 'error',
    );
    WebViewToken.serviceCountry = 'GLOBAL';
    final data = WebViewToken.payload(platform: 'android', isRefresh: false);
    expect(data['serviceCountry'], 'GLOBAL');
    expect(data['tokenStatus'], 'error');
    expect(WebViewToken.revision, greaterThan(revision));
  });
}
