import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_webview_bridge/src/utils/utils.dart';
import 'package:webview_flutter/webview_flutter.dart';

import '../auth/sso_exchange.dart';
import '../device/device_info.dart';
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

  /// B2: 네이티브 SSO 토큰 교환 API base (flavor 별, 예 https://qa.api.sazo.kr).
  /// 주입 시 SSO 로그인 교환을 네이티브가 수행(AUTH_TOKENS_READY) — WKWebView throttling 우회.
  /// 미주입(null) 시 기존 경로(SIGN_IN_LOGIN → web 교환 + watchdog) fallback.
  final String? apiBaseUrl;

  FlutterWebViewBridgeJavaScriptChannel({
    required this.context,
    required this.webViewController,
    this.channelName = 'IN_APP_WEBVIEW_BRIDGE_CHANNEL',
    required this.googleServerClientId,
    required this.kakaoNativeAppKey,
    this.apiBaseUrl,
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

  // ── SSO hang watchdog ──────────────────────────────────────────────────────
  // 카카오 로그인은 loginWithKakaoTalk() 로 카카오톡 앱 전환(paused→resumed)이 일어나고,
  // 복귀 후 iOS 가 WKWebView WebContent 프로세스를 suspend → web 의 JS setTimeout 이 동결되어
  // web 자체 복구(timeout/retry)가 발동 못 하는 케이스가 있다 (실기기 진단 2026-05-30).
  // Dart Timer 는 WKWebView suspend 와 무관하게(앱 foreground 시) 동작하므로, 카카오 결과 송신
  // 후 watchdog 을 걸고, web 가 성공 신호(REFRESH_TOKEN_WRITE)를 7초 내 보내지 못하면 native 가
  // webViewController.reload() 로 fresh connection 을 강제 → 기존 web sso-pending resume 이 재개.
  //
  // loop-guard 는 구조적: watchdog 은 native 가 받은 KAKAO_SIGN_IN_LOGIN 에만 arm 된다.
  // reload 후 web 의 resume 은 내부 fake postMessage(window.callbackPostMessage)라 native 로
  // 다시 오지 않으므로 재-arm 되지 않는다 → 한 번의 카카오 로그인당 reload 최대 1회.
  static const Duration _ssoWatchdogTimeout = Duration(seconds: 7);
  // B2(네이티브 교환) 경로 watchdog timeout — signin 문서 confirm 이후 native home load 와
  // fresh home document replay confirm 까지 허용하되, home 이 끝내 갱신되지 않으면 복구.
  static const Duration _ssoWatchdogTimeoutB2 = Duration(seconds: 8);
  Timer? _ssoWatchdog;
  int _ssoReloadCount = 0;
  // B2 watchdog 여부 — timeout 시 raw 재전송(B1) 대신 reload→세션 replay(B2) 로 복구.
  bool _ssoWatchdogB2 = false;
  // reload 복구: native 메모리에 마지막 카카오 결과 보관 (WebContent jettison 무관).
  // reload 후 sessionStorage 가 소실되어 web 의 sso-pending resume 이 불가함이 실기기로
  // 확인됨(2026-05-30) → fresh page mount 시 native 가 이 payload 를 재전송해 교환을 재개.
  Map<String, Object?>? _lastKakaoSendData;
  bool _resendKakaoAfterReload = false;

  // ── SSO session replay (근본 fix: WebContent 프로세스 jettison 대응) ──────────
  // 카카오 앱 전환 복귀 시 iOS 가 WKWebView WebContent 프로세스를 jettison/restart 하면 "/" 가
  // 새 document 로 재로드되고 web 의 sessionStorage 가 휘발한다(실기기 확인 2026-06-01:
  // 새 home 문서 auth_token=null). 로그인 결과(AUTH_TOKENS_READY)는 evaluateJavaScript 로 송신
  // 시점의 active 문서 1곳에만 가므로(broadcast 없음) 새 home 문서는 이를 못 받아 로그아웃 고착.
  // bridge(Dart) 는 Flutter 프로세스에 살아 있어(WebContent 자식만 restart) 마지막 성공 SSO 세션
  // payload 를 메모리에 보관할 수 있다 → 새 문서가 REFRESH_TOKEN_READ 로 물어오면 그대로 replay 해
  // 재교환/throttle/race 없이 결정론적 로그인. recency(TTL) 게이트로 reboot(캐시 없음)·일반 자동
  // 로그인은 기존 baseline(raw refresh token → web 교환) 유지 → PC/모바일웹·기존 흐름 무영향.
  static const Duration _sessionReplayTtl = Duration(seconds: 120);
  Map<String, Object?>? _cachedSessionPayload;
  DateTime? _cachedSessionAt;
  int _authEpoch = 0;
  String? _activeAuthSessionId;
  String? _activeAuthProvider;

  String? _authSessionIdOf(dynamic data) =>
      data is Map ? data['authSessionId'] as String? : null;

  String? _providerOfRequest(dynamic data) =>
      data is Map ? data['provider'] as String? : null;

  bool _isSsoLogin(WebViewBridgeFeatureType type) =>
      type == WebViewBridgeFeatureType.googleSignInLogin ||
      type == WebViewBridgeFeatureType.appleSignInLogin ||
      type == WebViewBridgeFeatureType.kakaoSignInLogin;

  String _providerNameOf(WebViewBridgeFeatureType type) {
    if (type == WebViewBridgeFeatureType.googleSignInLogin ||
        type == WebViewBridgeFeatureType.googleSignInLogout) {
      return 'google';
    }
    if (type == WebViewBridgeFeatureType.appleSignInLogin ||
        type == WebViewBridgeFeatureType.appleSignInLogout) {
      return 'apple';
    }
    return 'kakao';
  }

  String? _stringFieldOf(dynamic data, String key) =>
      data is Map ? data[key] as String? : null;

  bool _boolFieldOf(dynamic data, String key) =>
      data is Map && data[key] == true;

  bool _isHomePath(String? pathname) {
    if (pathname == null || pathname.isEmpty) return false;
    final uri = Uri.tryParse(pathname);
    final path = uri?.path ?? pathname.split('?').first.split('#').first;
    if (path == '/') return true;
    final segments = path.split('/').where((s) => s.isNotEmpty).toList();
    return segments.length == 1 &&
        const {'ko', 'en', 'ja'}.contains(segments.first);
  }

  bool _isHomeDocumentConfirm(dynamic data) =>
      _boolFieldOf(data, 'isHomeDocument') ||
      _isHomePath(_stringFieldOf(data, 'pathname')) ||
      _isHomePath(_stringFieldOf(data, 'webPathname'));

  String _confirmDebugOf(dynamic data) {
    if (data is! Map) return 'legacy-string';
    return 'documentId=${data['documentId'] ?? "null"} '
        'pathname=${data['pathname'] ?? data['webPathname'] ?? "null"} '
        'authSessionId=${data['authSessionId'] ?? "null"} '
        'isHomeDocument=${data['isHomeDocument'] ?? "null"}';
  }

  String _deleteDebugOf(dynamic data) {
    if (data is! Map) return 'legacy-null';
    return 'source=${data['source'] ?? "null"} '
        'documentId=${data['documentId'] ?? "null"} '
        'pathname=${data['pathname'] ?? data['webPathname'] ?? "null"} '
        'authSessionId=${data['authSessionId'] ?? "null"} '
        'isHomeDocument=${data['isHomeDocument'] ?? "null"} '
        'error=${data['errorMessage'] ?? "null"}';
  }

  void _clearSessionReplay(String reason) {
    final hadPayload = _cachedSessionPayload != null;
    _cachedSessionPayload = null;
    _cachedSessionAt = null;
    if (hadPayload) {
      // ignore: avoid_print
      print('[SsoExchange] session replay clear ($reason)');
    }
  }

  void _clearSsoTransientState(String reason) {
    cancelSsoWatchdog(reason);
    _lastKakaoSendData = null;
    _resendKakaoAfterReload = false;
    _clearSessionReplay(reason);
  }

  int _beginAuthTransaction(WebViewBridgeFeatureType type, dynamic data) {
    _authEpoch += 1;
    _clearSsoTransientState('ssoStart:${type.value}');
    _activeAuthSessionId = _authSessionIdOf(data);
    _activeAuthProvider = _providerOfRequest(data) ?? _providerNameOf(type);
    // ignore: avoid_print
    print(
      '[SsoExchange] auth transaction begin '
      'epoch=$_authEpoch provider=${_activeAuthProvider ?? "null"} '
      'authSessionId=${_activeAuthSessionId ?? "null"}',
    );
    return _authEpoch;
  }

  void _invalidateAuthTransaction(String reason) {
    _authEpoch += 1;
    _activeAuthSessionId = null;
    _activeAuthProvider = null;
    _clearSsoTransientState(reason);
    // ignore: avoid_print
    print(
      '[SsoExchange] auth transaction invalidated ($reason) epoch=$_authEpoch',
    );
  }

  bool _isCurrentAuthTransaction(int epoch, dynamic data) {
    if (epoch != _authEpoch) return false;
    final requestedAuthSessionId = _authSessionIdOf(data);
    if (requestedAuthSessionId != null &&
        _activeAuthSessionId != null &&
        requestedAuthSessionId != _activeAuthSessionId) {
      return false;
    }
    return true;
  }

  bool _isStaleAuthSessionMessage(dynamic data) {
    final requestedAuthSessionId = _authSessionIdOf(data);
    return requestedAuthSessionId != null &&
        _activeAuthSessionId != null &&
        requestedAuthSessionId != _activeAuthSessionId;
  }

  bool _shouldRevokeNativeSso(dynamic data) =>
      data is Map && data['revokeNativeSso'] == true;

  String? _normalizedProviderOf(dynamic data) {
    final raw = _providerOfRequest(data)?.toLowerCase();
    if (raw == null || raw.isEmpty) return null;
    if (raw.contains('kakao')) return 'kakao';
    if (raw.contains('google') || raw.contains('gmail')) return 'google';
    if (raw.contains('apple')) return 'apple';
    return null;
  }

  void _logStaleAuthMessage(String reason, dynamic data) {
    // ignore: avoid_print
    print(
      '[SsoExchange] stale auth message skipped ($reason) '
      'request=${_authSessionIdOf(data) ?? "null"} '
      'active=${_activeAuthSessionId ?? "null"} epoch=$_authEpoch',
    );
  }

  void _armSsoWatchdog({bool isB2 = false}) {
    _ssoWatchdog?.cancel();
    _ssoWatchdogB2 = isB2;
    final timeout = isB2 ? _ssoWatchdogTimeoutB2 : _ssoWatchdogTimeout;
    _ssoWatchdog = Timer(timeout, _onSsoWatchdogTimeout);
    // release 빌드에서도 보이도록 native print (debugPrint 는 release no-op).
    // watchdog 동작은 release syslog 검증 대상이라 의도적 print.
    // ignore: avoid_print
    print(
      '[Watchdog] arm ${timeout.inSeconds}s (kakaoSignInLogin${isB2 ? ", B2" : ""})',
    );
  }

  /// web 가 SSO 성공(REFRESH_TOKEN_WRITE) 또는 종결 실패(REFRESH_TOKEN_DELETE)를 알리면 해제.
  /// dispose 시에도 호출 (stale controller reload 방지).
  void cancelSsoWatchdog(String reason) {
    if (_ssoWatchdog?.isActive ?? false) {
      // ignore: avoid_print
      print('[Watchdog] cancel ($reason)');
    }
    _ssoWatchdog?.cancel();
    _ssoWatchdog = null;
    _ssoWatchdogB2 = false;
  }

  void _onSsoWatchdogTimeout() {
    _ssoWatchdog = null;
    _ssoReloadCount += 1;
    // B1(web 교환): reload 후 fresh page 에 카카오 raw payload 재전송 (web 교환 재개).
    // B2(네이티브 교환): reload 후 fresh page 가 REFRESH_TOKEN_READ → 세션 replay 로 로그인 복원
    //   (raw 재전송 불필요 — replay 가 throttle/race 없이 동일 payload 전달). jettison 으로 새 문서가
    //   AUTH_TOKENS_READY 를 못 받아 confirm(REFRESH_TOKEN_WRITE) 미수신인 케이스를 결정론적 복구.
    if (!_ssoWatchdogB2) {
      _resendKakaoAfterReload = true;
    }
    // ignore: avoid_print
    print(
      '[Watchdog] reload $_ssoReloadCount — SSO confirm 미수신 '
      '(${_ssoWatchdogB2 ? "B2 replay" : "B1 resend"})',
    );
    try {
      if (_ssoWatchdogB2) {
        unawaited(_loadHomeForSsoRecovery());
      } else {
        webViewController.reload();
      }
    } catch (e) {
      // ignore: avoid_print
      print('[Watchdog] reload FAIL: $e');
    }
  }

  Future<void> _loadHomeForSsoRecovery() async {
    try {
      final rawCurrentUrl = await webViewController.currentUrl();
      if (rawCurrentUrl == null || rawCurrentUrl.isEmpty) {
        await webViewController.reload();
        return;
      }
      final currentUri = Uri.tryParse(rawCurrentUrl);
      if (currentUri == null ||
          (currentUri.scheme != 'https' && currentUri.scheme != 'http') ||
          currentUri.host.isEmpty) {
        await webViewController.reload();
        return;
      }
      final homeUri = Uri.parse('${currentUri.origin}/');
      // ignore: avoid_print
      print('[Watchdog] load home for B2 recovery url=$homeUri');
      await webViewController.loadRequest(homeUri);
    } catch (e) {
      // ignore: avoid_print
      print('[Watchdog] load home FAIL: $e');
    }
  }

  /// watchdog reload 후 fresh page 에 카카오 결과를 재전송한다.
  /// 재-arm 하지 않음 → reload 는 카카오 로그인당 최대 1회 (구조적 loop-guard).
  /// 재전송 후의 hang 은 fresh page(타이머 살아있음)의 web timeout/retry 가 흡수.
  Future<void> _resendKakaoLogin() async {
    final data = _lastKakaoSendData;
    if (data == null) return;
    // ignore: avoid_print
    print('[Watchdog] resend KAKAO_SIGN_IN_LOGIN (reload 후 fresh page 재전송)');
    try {
      await runJavaScriptReturningResultPostMessage(jsonEncode(data));
    } catch (e) {
      // ignore: avoid_print
      print('[Watchdog] resend FAIL: $e');
    }
  }
  // ───────────────────────────────────────────────────────────────────────────

  Future<void> onMessageReceived(JavaScriptMessage message) async {
    final json = jsonDecode(message.message);
    final type = json['type'] as String?;
    final data = json['data'];
    if (type != null) {
      final webViewBridgeFeatureType = type.webViewBridgeFeatureType;
      if (webViewBridgeFeatureType != null) {
        late Map<String, Object?> sendData;
        int? authEpoch;

        try {
          if (_isSsoLogin(webViewBridgeFeatureType)) {
            authEpoch = _beginAuthTransaction(webViewBridgeFeatureType, data);
          }
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
              if (!_isCurrentAuthTransaction(authEpoch!, data)) {
                _logStaleAuthMessage(webViewBridgeFeatureType.value, data);
                return;
              }
              break;
            case WebViewBridgeFeatureType.googleSignInLogout:
              _invalidateAuthTransaction('googleSignInLogout');
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
              if (!_isCurrentAuthTransaction(authEpoch!, data)) {
                _logStaleAuthMessage(webViewBridgeFeatureType.value, data);
                return;
              }
              break;
            case WebViewBridgeFeatureType.appleSignInLogout:
              _invalidateAuthTransaction('appleSignInLogout');
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
              if (!_isCurrentAuthTransaction(authEpoch!, data)) {
                _logStaleAuthMessage(webViewBridgeFeatureType.value, data);
                return;
              }
              break;
            case WebViewBridgeFeatureType.kakaoSignInLogout:
              _invalidateAuthTransaction('kakaoSignInLogout');
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
              if (_isStaleAuthSessionMessage(data)) {
                _logStaleAuthMessage('refreshTokenWrite', data);
                return;
              }
              // web SSO 교환 성공 신호. B2 카카오 로그인 중 signin 문서 confirm 은
              // 사용자가 보는 홈 문서 로그인을 보장하지 못하므로 watchdog 을 유지한다.
              // 반대로 홈 문서 confirm 은 AUTH_TOKENS_READY persist 가 active home 에
              // 도달했다는 신호이므로 즉시 watchdog 을 종료한다. 이를 유지하면 timeout 이
              // 추가 home load 를 만들어 Safari Develop inspectable document 가 매회 늘어난다.
              if (_ssoWatchdogB2 && (_ssoWatchdog?.isActive ?? false)) {
                if (_isHomeDocumentConfirm(data)) {
                  cancelSsoWatchdog('refreshTokenWrite:home');
                  // ignore: avoid_print
                  print(
                    '[Watchdog] home confirm accepted; '
                    'B2 convergence complete ${_confirmDebugOf(data)}',
                  );
                } else {
                  // ignore: avoid_print
                  print(
                    '[Watchdog] keep B2 watchdog — non-home confirm; '
                    'wait home convergence ${_confirmDebugOf(data)}',
                  );
                }
              } else {
                cancelSsoWatchdog('refreshTokenWrite');
              }
              sendData = await RefreshTokenEvent().process(
                context,
                action: 'write',
                data: data,
              );
              break;
            case WebViewBridgeFeatureType.refreshTokenDelete:
              if (_isStaleAuthSessionMessage(data)) {
                _logStaleAuthMessage('refreshTokenDelete', data);
                return;
              }
              // web 가 종결 실패/로그아웃으로 token 삭제 — 타이머 살아있는 실제 실패이므로
              // reload 무의미. watchdog 해제 (frozen 케이스는 애초에 아무 메시지도 안 옴).
              // ignore: avoid_print
              print(
                '[SsoExchange] refresh token delete requested ${_deleteDebugOf(data)}',
              );
              _invalidateAuthTransaction('refreshTokenDelete');
              sendData = await RefreshTokenEvent().process(
                context,
                action: 'delete',
              );
              await _revokeNativeSsoSessions(data);
              break;
            case WebViewBridgeFeatureType.navigateHome:
              if (_isStaleAuthSessionMessage(data)) {
                _logStaleAuthMessage('navigateHome', data);
                return;
              }
              await _navigateHome(data);
              return;
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
            case WebViewBridgeFeatureType.authTokensReady:
              // B2: native → web 단방향. webview 가 request 로 보내는 type 아님. silent skip.
              return;
          }
        } catch (e) {
          // OAuth 실패 (sign_in_*.dart 의 throw AuthError) 는 단일 surface:
          // AUTH_ERROR payload 송신 + native SnackBar skip.
          // (사용자 toast 는 webview 측이 단독 표시 — 중복 회피)
          if (e is AuthError) {
            _invalidateAuthTransaction('authError');
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

        // ── B2: 카카오 로그인만 네이티브가 토큰 교환 후 AUTH_TOKENS_READY 로 변환 ──
        // WKWebView throttling(카카오 앱 전환) 우회. 구글/애플은 앱 전환이 없어 문제 없고
        // 검증된 web 교환 경로 유지(회귀 안전). 필요 시 _isSsoLogin 으로 확장 가능.
        if (apiBaseUrl != null &&
            webViewBridgeFeatureType ==
                WebViewBridgeFeatureType.kakaoSignInLogin) {
          final exchanged = await _ssoExchangeToTokensReady(
            webViewBridgeFeatureType,
            sendData,
            data,
            authEpoch!,
          );
          if (exchanged == null) return;
          sendData = exchanged;
        }

        // ── 근본 fix: WebContent jettison 후 새 document 의 세션 replay ──
        // 새 home 문서가 자동로그인용 REFRESH_TOKEN_READ 를 보낼 때, 최근(TTL 내) 성공 SSO 세션
        // 캐시가 있으면 그 AUTH_TOKENS_READY payload 를 그대로 replay 한다. 재교환이 아니라 캐시
        // 재전송이므로 throttle/race 가 없고, 로그인 때 통한 동일 payload(accessToken+me)라 콘텐츠도
        // 정상. 캐시 없음(reboot·TTL 경과·로그아웃) → 원본(raw refresh token) 유지 → 기존 web 교환
        // 자동로그인 경로 그대로(회귀 없음, B 무영향).
        if (apiBaseUrl != null &&
            webViewBridgeFeatureType ==
                WebViewBridgeFeatureType.refreshTokenRead) {
          final replay = _replayRecentSession(data);
          if (replay != null) sendData = replay;
        }

        // ── SSO watchdog arm (반드시 송신 *전*) ──
        // ⚠ 송신 후 arm 하면, B2 에서 web 이 AUTH_TOKENS_READY 수신 즉시 보내는 confirm
        // (REFRESH_TOKEN_WRITE)이 arm *전*에 처리돼 cancel 이 no-op 이 되고, 직후 arm 된 watchdog 가
        // 성공 로그인에도 false-fire(reload)한다 (실기기 확인 2026-06-02: confirm 36.800 → arm 36.802
        // → reload 38.805). 송신 전 arm 하면 송신 후 도착하는 confirm 이 정상 cancel → 성공 로그인은
        // reload 0, jettison-miss(confirm 미수신)만 timeout 후 reload→replay.
        if (webViewBridgeFeatureType ==
            WebViewBridgeFeatureType.kakaoSignInLogin) {
          if (!_isCurrentAuthTransaction(authEpoch!, data)) {
            _logStaleAuthMessage(
              'post:${webViewBridgeFeatureType.value}',
              data,
            );
            return;
          }
          if (apiBaseUrl == null) {
            // B1(web 교환): reload 후 raw 재전송용 payload 보관 + watchdog(7s).
            _lastKakaoSendData = sendData;
            _armSsoWatchdog();
          } else if (sendData['type'] ==
              WebViewBridgeFeatureType.authTokensReady.value) {
            // B2(네이티브 교환 성공): AUTH_TOKENS_READY 송신 예정. web confirm 미수신 시 reload→replay.
            _armSsoWatchdog(isB2: true);
          }
        }

        // Send Data to WebView
        final encoded = jsonEncode(sendData);
        debugPrint(
          '[Bridge] postMessage type=${webViewBridgeFeatureType.value} len=${encoded.length}',
        );
        try {
          final r = await runJavaScriptReturningResultPostMessage(encoded);
          debugPrint(
            '[Bridge] postMessage OK type=${webViewBridgeFeatureType.value} result=$r',
          );
        } catch (e) {
          debugPrint(
            '[Bridge] postMessage FAIL type=${webViewBridgeFeatureType.value}: $e',
          );
        }

        // watchdog reload 후 fresh page 가 mount 완료(REFRESH_TOKEN_READ — 이 시점에
        // device headers 준비됨)되면 native 가 카카오 payload 재전송 → 교환 재개.
        // (reload 가 sessionStorage 를 날려 web sso-pending resume 이 불가한 것의 대체)
        // flag 1회 clear → reload(최대 1회)와 함께 구조적 loop-guard.
        if (_resendKakaoAfterReload &&
            webViewBridgeFeatureType ==
                WebViewBridgeFeatureType.refreshTokenRead) {
          _resendKakaoAfterReload = false;
          await _resendKakaoLogin();
        }
      }
    }
  }

  // ── B2: 네이티브 SSO 토큰 교환 (현재 카카오 한정) ────────────────────────────
  // 구글/애플 확장 시: 호출 조건에 googleSignInLogin/appleSignInLogin 추가 + 실기기 검증.
  SsoProvider _providerOf(WebViewBridgeFeatureType t) {
    if (t == WebViewBridgeFeatureType.googleSignInLogin) {
      return SsoProvider.google;
    }
    if (t == WebViewBridgeFeatureType.appleSignInLogin) {
      return SsoProvider.apple;
    }
    return SsoProvider.kakao;
  }

  Future<void> _revokeNativeSsoSessions(dynamic data) async {
    if (!_shouldRevokeNativeSso(data)) return;

    final provider = _normalizedProviderOf(data);
    final providers = provider == null
        ? const ['kakao', 'google', 'apple']
        : <String>[provider];

    for (final provider in providers) {
      try {
        // ignore: avoid_print
        print('[SsoExchange] native SSO logout start provider=$provider');
        switch (provider) {
          case 'kakao':
            await SignInKakao.shared
                .process(context, action: 'logout')
                .timeout(const Duration(seconds: 3));
            break;
          case 'google':
            await SignInGoogle.shared
                .process(context, action: 'logout')
                .timeout(const Duration(seconds: 3));
            break;
          case 'apple':
            await SignInApple.shared
                .process(context, action: 'logout')
                .timeout(const Duration(seconds: 3));
            break;
        }
        // ignore: avoid_print
        print('[SsoExchange] native SSO logout OK provider=$provider');
      } catch (e) {
        // SDK 세션 정리 실패가 사줘 refresh token 삭제를 되돌리면 안 된다.
        // 다음 로그인 시도는 새 authSessionId 로 시작하고, 실패 원인은 로그로 남긴다.
        // ignore: avoid_print
        print('[SsoExchange] native SSO logout FAIL provider=$provider: $e');
      }
    }
  }

  Future<void> _navigateHome(dynamic data) async {
    final authSessionId = _authSessionIdOf(data);
    final rawCurrentUrl = await webViewController.currentUrl();
    if (rawCurrentUrl == null || rawCurrentUrl.isEmpty) {
      // ignore: avoid_print
      print('[Bridge] NAVIGATE_HOME skipped — currentUrl missing');
      return;
    }
    final currentUri = Uri.tryParse(rawCurrentUrl);
    if (currentUri == null ||
        (currentUri.scheme != 'https' && currentUri.scheme != 'http') ||
        currentUri.host.isEmpty) {
      // ignore: avoid_print
      print(
        '[Bridge] NAVIGATE_HOME skipped — invalid currentUrl: $rawCurrentUrl',
      );
      return;
    }
    final homeUri = Uri.parse('${currentUri.origin}/');
    // Use the controller-level navigation instead of JS location.replace.
    // In iOS WKWebView, app-switch SSO can leave multiple inspectable
    // WebContent documents around; JS may run in a document that is not the
    // visible top-level page. loadRequest forces the displayed WebView to
    // converge on home, where session replay can hydrate auth state.
    // ignore: avoid_print
    print(
      '[Bridge] NAVIGATE_HOME loadRequest '
      'authSessionId=${authSessionId ?? "null"} url=$homeUri',
    );
    await webViewController.loadRequest(homeUri);
  }

  Future<Map<String, String>> _deviceHeaders() async {
    final info = await WebViewDeviceInfo.fromData();
    return {
      if (info?.bundleId != null) 'x-sazo-app-id': info!.bundleId!,
      if (info?.systemName != null)
        'x-sazo-app-os': info!.systemName!.toLowerCase(),
      if (info?.version != null) 'x-sazo-app-version': info!.version!,
      if (info?.deviceId != null) 'x-sazo-device-id': info!.deviceId!,
    };
  }

  /// SSO SignIn 결과(idToken 포함 sendData)를 네이티브 교환 후 AUTH_TOKENS_READY payload 로
  /// 변환. 실패 시 AUTH_ERROR payload. web 은 결과로 토큰 persist 만 (HTTP 교환 0).
  Future<Map<String, Object?>?> _ssoExchangeToTokensReady(
    WebViewBridgeFeatureType type,
    Map<String, Object?> sendData,
    dynamic requestData,
    int authEpoch,
  ) async {
    final data = sendData['data'];
    final idToken = data is Map ? data['idToken'] as String? : null;
    if (idToken == null || idToken.isEmpty) return sendData;
    final profile = <String, Object?>{
      'email': data is Map ? data['email'] : null,
      'name': data is Map ? data['displayName'] : null,
      'picture': data is Map ? data['photoUrl'] : null,
    };
    final persist =
        (requestData is Map ? requestData['persist'] : null) == true;
    final authSessionId = _authSessionIdOf(requestData);
    final requestProvider = _providerOfRequest(requestData);
    try {
      final sso = SsoExchange(apiBaseUrl: apiBaseUrl!);
      final deviceHeaders = await _deviceHeaders();
      final result = await sso.exchange(
        provider: _providerOf(type),
        idToken: idToken,
        profile: profile,
        persist: persist,
        deviceHeaders: deviceHeaders,
      );
      if (!_isCurrentAuthTransaction(authEpoch, requestData)) {
        _logStaleAuthMessage('ssoExchange:afterExchange', requestData);
        return null;
      }
      // 자동로그인용 refresh 네이티브 저장. (RefreshTokenEvent 는 context 를 SharedPreferences
      // 용으로만 받고 UI 미사용 → async gap 안전)
      await RefreshTokenEvent().process(
        // ignore: use_build_context_synchronously
        context,
        action: 'write',
        data: result.refreshToken,
      );
      // me 도 네이티브 fetch — web me fetch 가 카카오 throttle 로 hang 하는 것 우회.
      // 실패는 non-fatal(me 생략 → web 이 기존 fetch 로 fallback).
      final me = await sso.fetchMe(
        accessToken: result.accessToken,
        deviceHeaders: deviceHeaders,
      );
      if (!_isCurrentAuthTransaction(authEpoch, requestData)) {
        _logStaleAuthMessage('ssoExchange:afterMe', requestData);
        return null;
      }
      // ignore: avoid_print
      print(
        '[SsoExchange] OK ${type.value} → AUTH_TOKENS_READY '
        '(me ${me == null ? "SKIP" : "OK"}, '
        'authSessionId=${authSessionId ?? "null"})',
      );
      final payload = <String, Object?>{
        'type': WebViewBridgeFeatureType.authTokensReady.value,
        'data': {
          'accessToken': result.accessToken,
          'refreshToken': result.refreshToken,
          'profile': profile,
          if (authSessionId != null) 'authSessionId': authSessionId,
          if (requestProvider != null) 'provider': requestProvider,
          if (me != null) 'me': me,
        },
      };
      // 세션 replay 캐시 — WebContent jettison 후 새 document 가 REFRESH_TOKEN_READ 로
      // 물어오면 이 payload 를 그대로 재전송(재교환 없음). TTL 내에서만 유효.
      _cachedSessionPayload = payload;
      _cachedSessionAt = DateTime.now();
      return payload;
    } catch (e) {
      if (!_isCurrentAuthTransaction(authEpoch, requestData)) {
        _logStaleAuthMessage('ssoExchange:catch', requestData);
        return null;
      }
      // ignore: avoid_print
      print('[SsoExchange] FAIL ${type.value}: $e');
      return {
        'type': WebViewBridgeFeatureType.authError.value,
        'data': {'code': 'SSO_EXCHANGE_FAILED', 'message': e.toString()},
      };
    }
  }

  /// 최근(TTL 내) 성공 SSO 세션 payload(AUTH_TOKENS_READY)를 replay 용으로 반환. 없거나 만료면 null.
  ///
  /// 근본 fix: 카카오 복귀 시 WebContent 프로세스 jettison 으로 web 의 sessionStorage 가 휘발해
  /// 새 home 문서가 로그인 결과를 못 받는 경우, 그 문서의 REFRESH_TOKEN_READ 에 이 캐시를 그대로
  /// 재전송한다. 재교환이 아니라 캐시 replay 이므로 throttle/race 가 없고, 로그인 때 통한 동일
  /// payload 라 콘텐츠도 정상. TTL 게이트로 reboot·일반 자동로그인(캐시 없음)은 baseline 유지.
  Map<String, Object?>? _replayRecentSession(dynamic requestData) {
    final at = _cachedSessionAt;
    final payload = _cachedSessionPayload;
    if (payload == null || at == null) return null;
    if (DateTime.now().difference(at) > _sessionReplayTtl) {
      _cachedSessionPayload = null;
      _cachedSessionAt = null;
      return null;
    }
    final requestedAuthSessionId = _authSessionIdOf(requestData);
    final cachedData = payload['data'];
    final cachedAuthSessionId = cachedData is Map
        ? cachedData['authSessionId'] as String?
        : null;
    if (_activeAuthSessionId != null &&
        cachedAuthSessionId != null &&
        _activeAuthSessionId != cachedAuthSessionId) {
      // ignore: avoid_print
      print(
        '[SsoExchange] session replay skip — active authSessionId mismatch '
        'active=$_activeAuthSessionId cache=$cachedAuthSessionId',
      );
      return null;
    }
    if (requestedAuthSessionId != null &&
        cachedAuthSessionId != null &&
        requestedAuthSessionId != cachedAuthSessionId) {
      // ignore: avoid_print
      print(
        '[SsoExchange] session replay skip — authSessionId mismatch '
        'request=$requestedAuthSessionId cache=$cachedAuthSessionId',
      );
      return null;
    }
    // ignore: avoid_print
    print(
      '[SsoExchange] session replay → AUTH_TOKENS_READY '
      '(authSessionId=${cachedAuthSessionId ?? "null"})',
    );
    return payload;
  }
  // ───────────────────────────────────────────────────────────────────────────

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
