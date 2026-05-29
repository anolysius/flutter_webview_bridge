import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_webview_bridge/src/utils/utils.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../models/types.dart';
import 'events/app_state_change.dart';
import 'events/auth_error.dart';
import 'events/camera_access.dart';
import 'events/channel_talk.dart';
import 'events/device_info.dart';
import 'events/exit_app.dart';
import 'events/get_clipboard.dart';
import 'events/google_analytics.dart';
import 'events/open_app_settings.dart';
import 'events/open_external_browser.dart';
import 'events/open_in_app_browser.dart';
import 'events/photo_library_access.dart';
import 'events/push_token.dart';
import 'events/refresh_token.dart';
import 'events/set_clipboard.dart';
import 'events/sign_in_apple.dart';
import 'events/sign_in_google.dart';
import 'events/sign_in_kakao.dart';

class FlutterWebViewBridgeJavaScriptChannel {
  BuildContext context;
  WebViewController webViewController;
  final String channelName;
  final String? googleServerClientId;
  final String? kakaoNativeAppKey;

  FlutterWebViewBridgeJavaScriptChannel({
    required this.context,
    required this.webViewController,
    this.channelName = 'IN_APP_WEBVIEW_BRIDGE_CHANNEL',
    required this.googleServerClientId,
    required this.kakaoNativeAppKey,
  }) {
    if (googleServerClientId != null) {
      SignInGoogle.shared.initialize(
        googleServerClientId: googleServerClientId,
      );
    }
    if (kakaoNativeAppKey != null) {
      SignInKakao.shared.initialize(nativeAppKey: kakaoNativeAppKey);
    }
  }

  Future<void> addJavaScriptChannel() {
    return webViewController.addJavaScriptChannel(
      channelName,
      onMessageReceived: onMessageReceived,
    );
  }

  Future<void> removeJavaScriptChannel() {
    return webViewController.removeJavaScriptChannel(channelName);
  }

  /// MainScreen rebuild 등으로 새 [WebViewController] 가 들어올 때 호출.
  /// 기존 channel handler 는 유지하고 응답 전송 대상만 최신 controller 로 교체.
  void updateWebViewController(
    WebViewController controller, {
    BuildContext? newContext,
  }) {
    webViewController = controller;
    if (newContext != null) {
      context = newContext;
    }
  }

  Future<void> onMessageReceived(JavaScriptMessage message) async {
    final json = jsonDecode(message.message);
    final type = json['type'] as String?;
    final data = json['data'];
    if (type != null) {
      final webViewBridgeFeatureType = type.webViewBridgeFeatureType;
      if (webViewBridgeFeatureType != null) {
        late Map<String, Object?> sendData;

        try {
          switch (webViewBridgeFeatureType) {
            case WebViewBridgeFeatureType.appStateChange:
              sendData = await AppStateChangeEvent().process(context);
              break;
            case WebViewBridgeFeatureType.pushToken:
              sendData = await PushTokenEvent().process(context);
              break;
            case WebViewBridgeFeatureType.deviceInfo:
              sendData = await DeviceInfoEvent().process(context);
              break;
            case WebViewBridgeFeatureType.cameraAccess:
              sendData = await CameraAccessEvent().process(context);
              break;
            case WebViewBridgeFeatureType.photoLibraryAccess:
              sendData = await PhotoLibraryAccessEvent().process(context);
              break;
            case WebViewBridgeFeatureType.setClipboard:
              sendData = await SetClipboardEvent().process(context, data);
              break;
            case WebViewBridgeFeatureType.getClipboard:
              sendData = await GetClipboardEvent().process(context);
              break;
            case WebViewBridgeFeatureType.openInAppBrowser:
              sendData = await OpenInAppBrowserEvent().process(context, data);
              break;
            case WebViewBridgeFeatureType.openExternalBrowser:
              sendData = await OpenExternalBrowserEvent().process(
                context,
                data,
              );
              break;
            case WebViewBridgeFeatureType.openAppSettings:
              sendData = await OpenAppSettingsEvent().process(context);
              return;
            case WebViewBridgeFeatureType.googleAnalytics:
              sendData = await GoogleAnalyticsEvent().process(context, data);
              break;
            case WebViewBridgeFeatureType.appsFlyerAnalytics:
              // TODO: Handle this case.
              throw UnimplementedError();
            case WebViewBridgeFeatureType.exitApp:
              sendData = await ExitAppEvent().process(context);
              break;
            case WebViewBridgeFeatureType.googleSignInLogin:
              sendData = await SignInGoogle.shared.process(
                context,
                action: 'login',
              );
              break;
            case WebViewBridgeFeatureType.googleSignInLogout:
              sendData = await SignInGoogle.shared.process(
                context,
                action: 'logout',
              );
              break;
            case WebViewBridgeFeatureType.appleSignInLogin:
              sendData = await SignInApple.shared.process(
                context,
                action: 'login',
              );
              break;
            case WebViewBridgeFeatureType.appleSignInLogout:
              sendData = await SignInApple.shared.process(
                context,
                action: 'logout',
              );
              break;
            case WebViewBridgeFeatureType.kakaoSignInLogin:
              sendData = await SignInKakao.shared.process(
                context,
                action: 'login',
              );
              break;
            case WebViewBridgeFeatureType.kakaoSignInLogout:
              sendData = await SignInKakao.shared.process(
                context,
                action: 'logout',
              );
              break;
            case WebViewBridgeFeatureType.refreshTokenRead:
              sendData = await RefreshTokenEvent().process(
                context,
                action: 'read',
              );
              break;
            case WebViewBridgeFeatureType.refreshTokenWrite:
              sendData = await RefreshTokenEvent().process(
                context,
                action: 'write',
                data: data,
              );
              break;
            case WebViewBridgeFeatureType.refreshTokenDelete:
              sendData = await RefreshTokenEvent().process(
                context,
                action: 'delete',
              );
              break;
            case WebViewBridgeFeatureType.channelTalkBoot:
              sendData = await ChannelTalkEvent().processBoot(context, data);
              break;
            case WebViewBridgeFeatureType.channelTalkShowMessenger:
              sendData = await ChannelTalkEvent().processShowMessenger(context);
              break;
            case WebViewBridgeFeatureType.channelTalkShutdown:
              sendData = await ChannelTalkEvent().processShutdown(context);
              break;
            case WebViewBridgeFeatureType.authError:
              // native 측 단방향 발화 only — webview 가 request 로 보내는 type 아님.
              // 도달 시 silent skip (early return) 으로 의도하지 않은 echo 회피.
              return;
          }
        } catch (e) {
          // OAuth 실패 (sign_in_*.dart 의 throw AuthError) 는 단일 surface:
          // AUTH_ERROR payload 송신 + native SnackBar skip.
          // (사용자 toast 는 webview 측이 단독 표시 — 중복 회피)
          if (e is AuthError) {
            try {
              await runJavaScriptReturningResultPostMessage(
                jsonEncode({
                  'type': WebViewBridgeFeatureType.authError.value,
                  'data': {'code': e.code, 'message': e.message},
                }),
              );
            } catch (_) {}
            return;
          }
          // 일반 exception — silent drop 방지: webview 측이 응답을 기다리고 있으므로 error payload 1건 전송 시도
          try {
            await runJavaScriptReturningResultPostMessage(
              jsonEncode({
                'type': webViewBridgeFeatureType.value,
                'error': e.toString(),
              }),
            );
          } catch (_) {
            // controller stale / channel teardown 등 응답 전송 자체 실패는 무시
          }
          if (context.mounted) {
            WebViewUtils.showErrorSnackBar(context, e.toString());
          }
          return;
        }

        // Send Data to WebView
        await runJavaScriptReturningResultPostMessage(jsonEncode(sendData));
      }
    }
  }

  Future<Object> runJavaScriptReturningResultAppState(String jsonData) async {
    // JSON 문자열에서 특수문자 이스케이프 처리
    final escapedData = jsonData.replaceAll("'", "\\'").replaceAll('\n', '\\n');

    return webViewController.runJavaScriptReturningResult('''
        (function() {
          if (typeof window.callbackAppState === 'function') {
            window.callbackAppState('$escapedData');
            return 'success';
          } else if (typeof document.callbackAppState === 'function') {
            document.callbackAppState('$escapedData');
            return 'success';
          }
          throw new Error('callbackAppState function not available');
        })()
      ''');
  }

  Future<Object> runJavaScriptReturningResultPostMessage(
    String jsonData,
  ) async {
    // JSON 문자열에서 특수문자 이스케이프 처리
    final escapedData = jsonData.replaceAll("'", "\\'").replaceAll('\n', '\\n');

    return webViewController.runJavaScriptReturningResult('''
        (function() {
          if (typeof window.callbackPostMessage === 'function') {
            window.callbackPostMessage('$escapedData');
            return 'success';
          } else if (typeof document.callbackPostMessage === 'function') {
            document.callbackPostMessage('$escapedData');
            return 'success';
          }
          throw new Error('callbackPostMessage function not available');
        })()
      ''');
  }
}
