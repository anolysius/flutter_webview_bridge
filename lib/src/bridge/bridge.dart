import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

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
import 'events/service_country.dart';
import 'events/set_clipboard.dart';
import 'events/sign_in_apple.dart';
import 'events/sign_in_google.dart';
import 'events/sign_in_kakao.dart';
import 'auth/auth_attempt_phase.dart';
import 'auth/auth_revision_store.dart';
import 'auth/auth_terminal_store.dart';
import 'auth/auth_ui_commit.dart';
import 'auth/auto_auth_attempt.dart';
import 'auth/process_auth_attempt_coordinator.dart';

typedef AuthTraceCallback = void Function(Map<String, Object?> event);

class _ProcessAutoAuthWork {
  const _ProcessAutoAuthWork({
    required this.lease,
    required this.tracksTerminal,
  });

  final ProcessAuthAttemptLease lease;
  final bool tracksTerminal;
}

class _AuthOperationValue<T> {
  const _AuthOperationValue(this.value);
  final T value;
}

class _AuthOperationAborted {
  const _AuthOperationAborted();
}

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

  /// 서비스 국가 코드 (APP-300 R5 — 'KR' / 'GLOBAL'). 미주입(null)=KR/레거시 동작.
  /// RefreshToken 키 + SSO domainType 분기에 사용. KR/null 은 현행과 byte-identical.
  ///
  /// staff 국가 전환(SERVICE_COUNTRY_CHANGE) 시 [updateServiceCountry] 로 세션 내 갱신 →
  /// 재시작 없이 refresh-key/domainType 가 새 국가를 반영한다.
  String? _serviceCountry;
  String? get serviceCountry => _serviceCountry;

  /// 웹의 SERVICE_COUNTRY_CHANGE 수신 시 앱이 override+reload 하도록 위임하는 콜백.
  final void Function(String requestedCountry)? onServiceCountryChange;
  final AuthTraceCallback? onAuthTrace;
  bool _isDisposed = false;
  bool _pendingSsoRecovery = false;
  AppLifecycleState _appLifecycleState = AppLifecycleState.resumed;
  final Queue<String> _pendingPostMessages = Queue<String>();
  bool _isFlushingPendingPostMessages = false;
  Future<void> _messageSerial = Future<void>.value();
  static const int _maxPendingPostMessages = 20;

  FlutterWebViewBridgeJavaScriptChannel({
    required this.context,
    required this.webViewController,
    this.channelName = 'IN_APP_WEBVIEW_BRIDGE_CHANNEL',
    required this.googleServerClientId,
    required this.kakaoNativeAppKey,
    this.apiBaseUrl,
    String? serviceCountry,
    this.onServiceCountryChange,
    this.onAuthTrace,
  }) : _serviceCountry = serviceCountry {
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
    if (_isDisposed) return Future<void>.value();

    return webViewController.addJavaScriptChannel(
      channelName,
      onMessageReceived: onMessageReceived,
    );
  }

  Future<void> removeJavaScriptChannel() {
    if (_isDisposed) return Future<void>.value();

    return webViewController.removeJavaScriptChannel(channelName);
  }

  /// MainScreen rebuild 등으로 새 [WebViewController] 가 들어올 때 호출.
  /// 기존 channel handler 는 유지하고 응답 전송 대상만 최신 controller 로 교체.
  void updateWebViewController(
    WebViewController controller, {
    BuildContext? newContext,
  }) {
    if (_isDisposed) return;

    webViewController = controller;
    if (newContext != null) {
      context = newContext;
    }
  }

  /// staff 서비스 국가 전환 시 세션 내 serviceCountry 갱신 (재시작 불요).
  /// 이후 RefreshToken 키 분기(refreshTokenRead/Write/Delete) 와 SSO domainType 가
  /// 즉시 새 국가를 반영한다. 채널 재생성 없이 동작.
  void updateServiceCountry(String? code) {
    if (_isDisposed) return;
    _serviceCountry = code;
  }

  /// 명시적 로그아웃(staff 서비스 국가 전환 등) 시 in-memory SSO transient 상태를 정리한다.
  /// = SSO replay 캐시(`_cachedSessionPayload`) + watchdog + kakao resend.
  ///
  /// persistent refresh token([clearAllRefreshTokens])만 지우면, 전환 reload 후 새 문서의
  /// REFRESH_TOKEN_READ 에 bridge 가 TTL(120s) 내 캐시를 replay 해 재인증되어 로그아웃이
  /// 안 된다. 전환 경로에서 reload 전에 호출해 replay window 를 제거한다.
  void clearSsoTransientState(String reason) => _clearSsoTransientState(reason);

  /// 서비스 국가 전환은 token/replay뿐 아니라 process-wide 인증 소유권까지 끊는 경계다.
  /// 남은 interactive lease가 새 origin의 REFRESH_TOKEN_READ를 막지 않게 reload 전에 호출한다.
  void resetAuthStateForServiceCountrySwitch(String reason) {
    _processAuthCoordinator.resetForAuthBoundary();
    _autoAuthAttempt.resetForAuthBoundary();
    _invalidateAuthTransaction(reason);
  }

  void updateAppLifecycleState(AppLifecycleState state) {
    if (_isDisposed) return;

    _appLifecycleState = state;
    if (_isAppResumed) {
      if (_authAttemptPhase.shouldRunTerminalDeadline) {
        _armAttemptTerminalTimer();
      }
      unawaited(_runResumedPendingWork());
    } else {
      _attemptTerminalTimer?.cancel();
      _attemptTerminalTimer = null;
    }
  }

  void dispose() {
    _isDisposed = true;
    final abortCompleter = _activeAuthAbortCompleter;
    if (abortCompleter != null && !abortCompleter.isCompleted) {
      abortCompleter.complete();
    }
    _activeAuthAbortCompleter = null;
    _authAttemptPhase.settle();
    _autoAuthAttempt.clearActiveAttempt();
    _completeProcessAuthLease();
    _attemptTerminalTimer?.cancel();
    _attemptTerminalTimer = null;
    _pendingSsoRecovery = false;
    _pendingPostMessages.clear();
    cancelSsoWatchdog('channel-dispose');
  }

  bool get _isAppResumed => _appLifecycleState == AppLifecycleState.resumed;

  bool get _canTouchWebView => !_isDisposed && context.mounted;

  bool get _canRunLifecycleSensitiveWebViewWork =>
      _canTouchWebView && _isAppResumed;

  Future<void> _runResumedPendingWork() async {
    await _flushPendingPostMessages();

    if (_pendingSsoRecovery && _canRunLifecycleSensitiveWebViewWork) {
      _pendingSsoRecovery = false;
      await _runSsoWatchdogRecovery();
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
  static const Duration _attemptTerminalTimeout = Duration(seconds: 15);
  Timer? _ssoWatchdog;
  Timer? _attemptTerminalTimer;
  final AuthAttemptPhaseController _authAttemptPhase =
      AuthAttemptPhaseController();
  bool get _awaitingAuthTerminal => _authAttemptPhase.isAwaitingTerminal;
  Completer<void>? _activeAuthAbortCompleter;
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
  int _activeAuthRevision = 0;
  int _activeProtocolVersion = 1;
  String? _activeAuthSessionId;
  String? _activeAuthProvider;
  String? _activeRequestId;
  String? _activeDocumentId;
  final Set<String> _terminalAuthSessionIds = <String>{};
  final AutoAuthAttemptController _autoAuthAttempt =
      AutoAuthAttemptController();
  final ProcessAuthAttemptCoordinator _processAuthCoordinator =
      ProcessAuthAttemptCoordinator.shared;
  ProcessAuthAttemptLease? _processAuthLease;

  String? _authSessionIdOf(dynamic data) =>
      data is Map ? data['authSessionId'] as String? : null;

  String? _effectiveAuthSessionIdOf(dynamic data) =>
      _autoAuthAttempt.effectiveAttemptId(
        messageAttemptId: _authSessionIdOf(data),
        activeAttemptId: _activeAuthSessionId,
      );

  String? _providerOfRequest(dynamic data) =>
      data is Map ? data['provider'] as String? : null;

  String? _requestIdOf(dynamic data) =>
      data is Map ? data['requestId'] as String? : null;

  int _protocolVersionOf(dynamic data) =>
      data is Map && data['protocolVersion'] is int
      ? data['protocolVersion'] as int
      : 1;

  int? _authRevisionOf(dynamic data) =>
      data is Map && data['authRevision'] is int
      ? data['authRevision'] as int
      : null;

  void _emitAuthTrace(String event, {String? resultCode, dynamic data}) {
    onAuthTrace?.call({
      'protocolVersion': _activeProtocolVersion,
      'loginAttemptId': _effectiveAuthSessionIdOf(data),
      'requestId': _requestIdOf(data) ?? _activeRequestId,
      'authRevision': _authRevisionOf(data) ?? _activeAuthRevision,
      if (data is Map && data['documentId'] is String)
        'documentId': data['documentId'] as String,
      if (data is Map && data['pathname'] is String)
        'pathname': data['pathname'] as String,
      if (data is Map && data['visibilityState'] is String)
        'visibilityState': data['visibilityState'] as String,
      'provider': _activeAuthProvider,
      'event': event,
      if (resultCode != null) 'resultCode': resultCode,
    });
  }

  String _terminalKeyOf(dynamic data) => authTerminalKey(
    authSessionId: _effectiveAuthSessionIdOf(data),
    authRevision: _authRevisionOf(data) ?? _activeAuthRevision,
  );

  String? get _currentEffectiveAuthSessionId =>
      _autoAuthAttempt.effectiveAttemptId(
        messageAttemptId: null,
        activeAttemptId: _activeAuthSessionId,
      );

  AuthTerminalWorkSnapshot _captureAuthTerminalWork(dynamic data) =>
      AuthTerminalWorkSnapshot(
        epoch: _authEpoch,
        attemptId: _effectiveAuthSessionIdOf(data),
        revision: _authRevisionOf(data) ?? _activeAuthRevision,
        requestId: _requestIdOf(data) ?? _activeRequestId,
        leaseGeneration: _processAuthLease?.generation,
      );

  bool _isCurrentAuthTerminalWork(AuthTerminalWorkSnapshot snapshot) =>
      !_isDisposed &&
      snapshot.matches(
        epoch: _authEpoch,
        attemptId: _currentEffectiveAuthSessionId,
        revision: _activeAuthRevision,
        requestId: _activeRequestId,
        leaseGeneration: _processAuthLease?.generation,
      );

  bool _rememberTerminalKey(String key) {
    if (!_terminalAuthSessionIds.add(key)) return false;
    if (_terminalAuthSessionIds.length > 200) {
      _terminalAuthSessionIds.remove(_terminalAuthSessionIds.first);
    }
    return true;
  }

  void _settleAuthTerminalTracking() {
    _authAttemptPhase.settle();
    final abortCompleter = _activeAuthAbortCompleter;
    if (abortCompleter != null && !abortCompleter.isCompleted) {
      abortCompleter.complete();
    }
    _attemptTerminalTimer?.cancel();
    _attemptTerminalTimer = null;
  }

  Future<bool> _hasCompletedAuthTerminal(dynamic data) async {
    final key = _terminalKeyOf(data);
    final attemptId = _effectiveAuthSessionIdOf(data);
    final revision = _authRevisionOf(data) ?? _activeAuthRevision;
    if (_processAuthCoordinator.isTerminalSettled(
      attemptId: attemptId,
      revision: revision,
    )) {
      _rememberTerminalKey(key);
      return true;
    }
    if (_terminalAuthSessionIds.contains(key)) return true;

    try {
      final matchesPersistedSuccess = await const AuthTerminalStore()
          .matchesSuccess(
            authSessionId: _effectiveAuthSessionIdOf(data),
            authRevision: _authRevisionOf(data) ?? _activeAuthRevision,
            serviceCountry: serviceCountry,
          );
      if (!matchesPersistedSuccess) return false;
      _rememberTerminalKey(key);
      _processAuthCoordinator.settleTerminal(
        attemptId: attemptId,
        revision: revision,
      );
      return true;
    } catch (error) {
      // 영속 marker 조회 실패가 실제 로그인 수렴을 방해하면 안 된다.
      // ignore: avoid_print
      print(
        '[SsoExchange] auth terminal marker read FAIL: ${error.runtimeType}',
      );
      return false;
    }
  }

  void _emitAuthTerminal(String resultCode, {dynamic data}) {
    final key = _terminalKeyOf(data);
    final attemptId = _effectiveAuthSessionIdOf(data);
    final revision = _authRevisionOf(data) ?? _activeAuthRevision;
    final isFirstProcessTerminal = _processAuthCoordinator.settleTerminal(
      attemptId: attemptId,
      revision: revision,
    );
    if (!isFirstProcessTerminal || !_rememberTerminalKey(key)) {
      _emitAuthTrace(
        'auth.terminal.duplicate_ignored',
        resultCode: resultCode,
        data: data,
      );
      _settleAuthTerminalTracking();
      _completeProcessAuthLease();
      return;
    }
    _settleAuthTerminalTracking();
    _emitAuthTrace('auth.terminal', resultCode: resultCode, data: data);
    _completeProcessAuthLease();
  }

  void _completeProcessAuthLease() {
    final lease = _processAuthLease;
    _processAuthLease = null;
    if (lease != null) _processAuthCoordinator.complete(lease);
  }

  void _handleProcessAuthAttemptSuperseded(ProcessAuthAttemptLease lease) {
    if (_isDisposed || !identical(_processAuthLease, lease)) return;
    final supersededData = _activeAuthProtocolData();
    _emitAuthTerminal('user_superseded', data: supersededData);
    _authEpoch += 1;
    _autoAuthAttempt.clearActiveAttempt();
    _clearSsoTransientState('process-auth-superseded');
  }

  void _handleProcessAuthAttemptSettled(ProcessAuthAttemptLease lease) {
    if (_isDisposed || !identical(_processAuthLease, lease)) return;
    _processAuthLease = null;
    _settleAuthTerminalTracking();
    cancelSsoWatchdog('process-auth-terminal-settled');
    _autoAuthAttempt.clearActiveAttempt();
  }

  void _armAttemptTerminalTimer() {
    if (!_authAttemptPhase.shouldRunTerminalDeadline ||
        !_isAppResumed ||
        _isDisposed) {
      return;
    }
    _attemptTerminalTimer?.cancel();
    final timeoutData = _activeAuthProtocolData();
    final snapshot = _captureAuthTerminalWork(timeoutData);
    late final Timer timer;
    timer = Timer(_attemptTerminalTimeout, () {
      // 취소 직전 이미 event queue에 들어온 옛 callback이 새 timer reference를
      // 지우지 못하게 자신이 아직 owner일 때만 해제한다.
      if (identical(_attemptTerminalTimer, timer)) {
        _attemptTerminalTimer = null;
      }
      unawaited(_onAttemptTerminalTimeout(snapshot, timeoutData));
    });
    _attemptTerminalTimer = timer;
  }

  Future<void> _onAttemptTerminalTimeout(
    AuthTerminalWorkSnapshot snapshot,
    dynamic timeoutData,
  ) async {
    if (!_isCurrentAuthTerminalWork(snapshot) ||
        !_authAttemptPhase.shouldRunTerminalDeadline) {
      _emitAuthTrace(
        'auth.terminal.timeout_stale_ignored',
        resultCode: 'attempt_changed_before_check',
        data: timeoutData,
      );
      return;
    }
    final hasCompletedTerminal = await _hasCompletedAuthTerminal(timeoutData);
    if (hasCompletedTerminal) {
      if (_isCurrentAuthTerminalWork(snapshot)) {
        _settleAuthTerminalTracking();
        _completeProcessAuthLease();
      }
      _emitAuthTrace(
        'auth.terminal.timeout_ignored',
        resultCode: 'terminal_already_emitted',
        data: timeoutData,
      );
      return;
    }
    // marker 조회 중 다른 bridge가 성공을 확정했거나 새 시도로 교체될 수 있다.
    if (!_isCurrentAuthTerminalWork(snapshot) ||
        !_authAttemptPhase.shouldRunTerminalDeadline ||
        _processAuthCoordinator.isTerminalSettled(
          attemptId: snapshot.attemptId,
          revision: snapshot.revision,
        )) {
      _emitAuthTrace(
        'auth.terminal.timeout_stale_ignored',
        resultCode: 'attempt_changed_during_check',
        data: timeoutData,
      );
      return;
    }
    _terminateAuthAttemptWithError(
      resultCode: 'code_failure:auth_terminal_timeout',
      code: 'AUTH_TERMINAL_TIMEOUT',
    );
  }

  Map<String, Object?> _activeAuthProtocolData() => <String, Object?>{
    'protocolVersion': _activeProtocolVersion,
    if (_activeRequestId != null) 'requestId': _activeRequestId,
    if (_activeAuthSessionId != null) 'authSessionId': _activeAuthSessionId,
    if (_activeDocumentId != null) 'documentId': _activeDocumentId,
    'authRevision': _activeAuthRevision,
  };

  void _terminateAuthAttemptWithError({
    required String resultCode,
    required String code,
  }) {
    if (!_authAttemptPhase.shouldRunTerminalDeadline) return;
    final timeoutData = _activeAuthProtocolData();
    _emitAuthTerminal(resultCode, data: timeoutData);
    _invalidateAuthTransaction(code);
    unawaited(
      runJavaScriptPostMessage(
        jsonEncode({
          'type': WebViewBridgeFeatureType.authError.value,
          'data': {...timeoutData, 'code': code, 'message': ''},
        }),
      ),
    );
  }

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
        'errorType=${data['errorType'] ?? "null"}';
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

  _ProcessAutoAuthWork? _beginAutoAuthAttemptIfNeeded(
    dynamic requestData,
    Map<String, Object?> readResponse,
  ) {
    if (_protocolVersionOf(requestData) < 2) return null;

    final fallbackNonce = DateTime.now().microsecondsSinceEpoch;
    final isInitialBootstrap = _processAuthCoordinator
        .claimAutomaticBootstrap();
    final trackedAttemptId = isInitialBootstrap
        ? _autoAuthAttempt.beginInitialRefresh(
            requestData: requestData,
            readResponse: readResponse,
            interactiveAttemptActive: _awaitingAuthTerminal,
            fallbackNonce: fallbackNonce,
          )
        : null;
    final tracksTerminal = trackedAttemptId != null;
    final attemptId =
        trackedAttemptId ??
        _authSessionIdOf(requestData) ??
        _requestIdOf(requestData) ??
        'auto-work-$fallbackNonce';

    late final ProcessAuthAttemptLease lease;
    final claimed = _processAuthCoordinator.tryBeginAutomatic(
      attemptId: attemptId,
      onSuperseded: () {
        if (tracksTerminal) _handleProcessAuthAttemptSuperseded(lease);
      },
      onSettled: () => _handleProcessAuthAttemptSettled(lease),
    );
    if (claimed == null) {
      if (tracksTerminal) _autoAuthAttempt.clearActiveAttempt();
      return null;
    }
    lease = claimed;
    _processAuthLease = lease;

    if (tracksTerminal) {
      _activeAuthSessionId = attemptId;
      _activeAuthProvider = autoAuthProvider;
      _activeRequestId = _requestIdOf(requestData);
      _activeDocumentId = _stringFieldOf(requestData, 'documentId');
      _activeProtocolVersion = 2;
      _activeAuthAbortCompleter = null;
      // refresh 교환 중에는 network/provider 응답을 기다리므로 짧은 UI deadline을
      // 적용하지 않는다. AUTH_TOKENS_READY 송신 직전에 terminal convergence로 전환한다.
      _authAttemptPhase.beginProviderInteraction(tracksTerminal: true);
      _emitAuthTrace('auth.attempt.started', data: requestData);
    }
    return _ProcessAutoAuthWork(lease: lease, tracksTerminal: tracksTerminal);
  }

  void _completeUntrackedAutoAuthWork(_ProcessAutoAuthWork? work) {
    if (work == null || work.tracksTerminal) return;
    if (identical(_processAuthLease, work.lease)) {
      _processAuthLease = null;
    }
    _processAuthCoordinator.complete(work.lease);
  }

  void _bindAutoAuthAttemptToResponse(Map<String, Object?> response) {
    _autoAuthAttempt.bindToResponse(response);
  }

  Future<int> _beginAuthTransaction(
    WebViewBridgeFeatureType type,
    dynamic data,
  ) async {
    _authEpoch += 1;
    final transactionEpoch = _authEpoch;
    late final ProcessAuthAttemptLease processLease;
    processLease = _processAuthCoordinator.beginInteractive(
      attemptId:
          _authSessionIdOf(data) ?? 'interactive-${type.value}-$_authEpoch',
      onSuperseded: () => _handleProcessAuthAttemptSuperseded(processLease),
      onSettled: () => _handleProcessAuthAttemptSettled(processLease),
    );
    _processAuthLease = processLease;
    _autoAuthAttempt.clearActiveAttempt();
    _ssoReloadCount = 0;
    _clearSsoTransientState('ssoStart:${type.value}');
    _activeAuthSessionId = _authSessionIdOf(data);
    _activeAuthProvider = _providerOfRequest(data) ?? _providerNameOf(type);
    _activeRequestId = _requestIdOf(data);
    _activeDocumentId = _stringFieldOf(data, 'documentId');
    _activeProtocolVersion = _protocolVersionOf(data);
    final nextRevision = await const AuthRevisionStore().next(
      serviceCountry: serviceCountry,
    );
    // revision 저장을 기다리는 동안 다른 bridge의 interactive 시도가 이 lease를
    // 선점할 수 있다. 옛 초기화가 복귀해 새 시도의 phase/revision을 덮지 못하게 한다.
    if (_isDisposed ||
        transactionEpoch != _authEpoch ||
        !identical(_processAuthLease, processLease)) {
      throw const _AuthOperationAborted();
    }
    _activeAuthRevision = nextRevision;
    _activeAuthAbortCompleter = _activeProtocolVersion >= 2
        ? Completer<void>()
        : null;
    _authAttemptPhase.beginProviderInteraction(
      tracksTerminal: _activeProtocolVersion >= 2,
    );
    _emitAuthTrace('auth.attempt.started', data: data);
    // ignore: avoid_print
    print(
      '[SsoExchange] auth transaction begin '
      'epoch=$_authEpoch provider=${_activeAuthProvider ?? "null"} '
      'authSessionId=${_activeAuthSessionId ?? "null"} '
      'authRevision=$_activeAuthRevision protocol=$_activeProtocolVersion',
    );
    return transactionEpoch;
  }

  void _invalidateAuthTransaction(String reason) {
    _authEpoch += 1;
    _completeProcessAuthLease();
    _activeAuthSessionId = null;
    _activeAuthProvider = null;
    _autoAuthAttempt.clearActiveAttempt();
    _authAttemptPhase.settle();
    _attemptTerminalTimer?.cancel();
    _attemptTerminalTimer = null;
    _activeAuthAbortCompleter = null;
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

  Future<T> _awaitAuthOperation<T>(Future<T> operation) async {
    final abort = _activeAuthAbortCompleter;
    if (abort == null) return operation;
    final outcome = await Future.any<Object?>([
      operation.then<Object?>((value) => _AuthOperationValue<T>(value)),
      abort.future.then<Object?>((_) => const _AuthOperationAborted()),
    ]);
    if (outcome is _AuthOperationAborted) throw outcome;
    return (outcome as _AuthOperationValue<T>).value;
  }

  bool _isStaleAuthSessionMessage(dynamic data) {
    final requestedAuthSessionId = _authSessionIdOf(data);
    return requestedAuthSessionId != null &&
        _activeAuthSessionId != null &&
        requestedAuthSessionId != _activeAuthSessionId;
  }

  bool _isStaleAuthRevisionMessage(dynamic data) {
    final revision = _authRevisionOf(data);
    return revision != null && revision != _activeAuthRevision;
  }

  bool _isExternalSsoFailure(Object error) =>
      error is SocketException ||
      error is TimeoutException ||
      (error is SsoExchangeException && error.externalFailure);

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
    if (!_canTouchWebView) return;

    if (!_isAppResumed) {
      _pendingSsoRecovery = true;
      // ignore: avoid_print
      print(
        '[Watchdog] recovery deferred — appLifecycle=${_appLifecycleState.name}',
      );
      return;
    }

    unawaited(_runSsoWatchdogRecovery());
  }

  Future<void> _runSsoWatchdogRecovery() async {
    if (!_canRunLifecycleSensitiveWebViewWork) {
      _pendingSsoRecovery = !_isDisposed && context.mounted;
      return;
    }

    if (_ssoReloadCount >= 1) {
      _terminateAuthAttemptWithError(
        resultCode: 'code_failure:ui_commit_timeout',
        code: 'UI_COMMIT_TIMEOUT',
      );
      return;
    }
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
        await _loadHomeForSsoRecovery();
      } else {
        await webViewController.reload();
      }
    } catch (e) {
      // ignore: avoid_print
      print('[Watchdog] reload FAIL: ${e.runtimeType}');
    }
  }

  Future<void> _loadHomeForSsoRecovery() async {
    if (!_canRunLifecycleSensitiveWebViewWork) {
      _pendingSsoRecovery = !_isDisposed && context.mounted;
      return;
    }

    try {
      final rawCurrentUrl = await webViewController.currentUrl();
      if (!_canRunLifecycleSensitiveWebViewWork) return;
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
      if (!_canRunLifecycleSensitiveWebViewWork) return;
      await webViewController.loadRequest(homeUri);
    } catch (e) {
      // ignore: avoid_print
      print('[Watchdog] load home FAIL: ${e.runtimeType}');
    }
  }

  /// watchdog reload 후 fresh page 에 카카오 결과를 재전송한다.
  /// 재-arm 하지 않음 → reload 는 카카오 로그인당 최대 1회 (구조적 loop-guard).
  /// 재전송 후의 hang 은 fresh page(타이머 살아있음)의 web timeout/retry 가 흡수.
  Future<void> _resendKakaoLogin() async {
    if (!_canTouchWebView) return;

    final data = _lastKakaoSendData;
    if (data == null) return;
    // ignore: avoid_print
    print('[Watchdog] resend KAKAO_SIGN_IN_LOGIN (reload 후 fresh page 재전송)');
    try {
      await runJavaScriptPostMessage(jsonEncode(data));
    } catch (e) {
      // ignore: avoid_print
      print('[Watchdog] resend FAIL: ${e.runtimeType}');
    }
  }
  // ───────────────────────────────────────────────────────────────────────────

  Future<void> onMessageReceived(JavaScriptMessage message) async {
    final operation = _messageSerial.then(
      (_) => _handleMessageReceived(message),
    );
    _messageSerial = operation.catchError((_) {});
    return operation;
  }

  Future<void> _handleMessageReceived(JavaScriptMessage message) async {
    final json = jsonDecode(message.message);
    final type = json['type'] as String?;
    final data = json['data'];
    if (type != null) {
      final webViewBridgeFeatureType = type.webViewBridgeFeatureType;
      if (webViewBridgeFeatureType != null) {
        late Map<String, Object?> sendData;
        int? authEpoch;
        _ProcessAutoAuthWork? processAutoAuthWork;

        try {
          if (_isSsoLogin(webViewBridgeFeatureType)) {
            authEpoch = await _beginAuthTransaction(
              webViewBridgeFeatureType,
              data,
            );
            if (!context.mounted) return;
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
              sendData = await _awaitAuthOperation(
                SignInGoogle.shared.process(context, action: 'login'),
              );
              if (!_isCurrentAuthTransaction(authEpoch!, data)) {
                _logStaleAuthMessage(webViewBridgeFeatureType.value, data);
                return;
              }
              break;
            case WebViewBridgeFeatureType.googleSignInLogout:
              _activeAuthRevision = await const AuthRevisionStore().next(
                serviceCountry: serviceCountry,
              );
              if (!context.mounted) return;
              _invalidateAuthTransaction('googleSignInLogout');
              sendData = await SignInGoogle.shared.process(
                context,
                action: 'logout',
              );
              break;
            case WebViewBridgeFeatureType.appleSignInLogin:
              sendData = await _awaitAuthOperation(
                SignInApple.shared.process(context, action: 'login'),
              );
              if (!_isCurrentAuthTransaction(authEpoch!, data)) {
                _logStaleAuthMessage(webViewBridgeFeatureType.value, data);
                return;
              }
              break;
            case WebViewBridgeFeatureType.appleSignInLogout:
              _activeAuthRevision = await const AuthRevisionStore().next(
                serviceCountry: serviceCountry,
              );
              if (!context.mounted) return;
              _invalidateAuthTransaction('appleSignInLogout');
              sendData = await SignInApple.shared.process(
                context,
                action: 'logout',
              );
              break;
            case WebViewBridgeFeatureType.kakaoSignInLogin:
              sendData = await _awaitAuthOperation(
                SignInKakao.shared.process(context, action: 'login'),
              );
              if (!_isCurrentAuthTransaction(authEpoch!, data)) {
                _logStaleAuthMessage(webViewBridgeFeatureType.value, data);
                return;
              }
              break;
            case WebViewBridgeFeatureType.kakaoSignInLogout:
              _activeAuthRevision = await const AuthRevisionStore().next(
                serviceCountry: serviceCountry,
              );
              if (!context.mounted) return;
              _invalidateAuthTransaction('kakaoSignInLogout');
              sendData = await SignInKakao.shared.process(
                context,
                action: 'logout',
              );
              break;
            case WebViewBridgeFeatureType.refreshTokenRead:
              if (_protocolVersionOf(data) >= 2) {
                _activeProtocolVersion = _protocolVersionOf(data);
                _activeRequestId = _requestIdOf(data);
                _activeAuthSessionId =
                    _authSessionIdOf(data) ?? _activeAuthSessionId;
                _activeDocumentId = _stringFieldOf(data, 'documentId');
              }
              final storedRevision = await const AuthRevisionStore().current(
                serviceCountry: serviceCountry,
              );
              if (!context.mounted) return;
              if (storedRevision > _activeAuthRevision) {
                _activeAuthRevision = storedRevision;
              }
              sendData = await RefreshTokenEvent().process(
                context,
                action: 'read',
                data: data,
                serviceCountry: serviceCountry,
                authRevision: _activeAuthRevision,
              );
              break;
            case WebViewBridgeFeatureType.refreshTokenWrite:
              if (_isStaleAuthSessionMessage(data) ||
                  _isStaleAuthRevisionMessage(data)) {
                _logStaleAuthMessage('refreshTokenWrite', data);
                return;
              }
              // web SSO 교환 성공 신호. B2 카카오 로그인 중 signin 문서 confirm 은
              // 사용자가 보는 홈 문서 로그인을 보장하지 못하므로 watchdog 을 유지한다.
              // 반대로 홈 문서 confirm 은 AUTH_TOKENS_READY persist 가 active home 에
              // 도달했다는 신호이므로 즉시 watchdog 을 종료한다. 이를 유지하면 timeout 이
              // 추가 home load 를 만들어 Safari Develop inspectable document 가 매회 늘어난다.
              if (_activeProtocolVersion >= 2) {
                // v2에서는 token persist가 아니라 visible home의 AUTH_UI_COMMITTED만 terminal success다.
                _emitAuthTrace('auth.state.persisted', data: data);
              } else if (_ssoWatchdogB2 && (_ssoWatchdog?.isActive ?? false)) {
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
                serviceCountry: serviceCountry,
                authRevision: _activeAuthRevision,
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
              _activeAuthRevision = await const AuthRevisionStore().next(
                serviceCountry: serviceCountry,
              );
              if (!context.mounted) return;
              _invalidateAuthTransaction('refreshTokenDelete');
              sendData = await RefreshTokenEvent().process(
                context,
                action: 'delete',
                data: data,
                serviceCountry: serviceCountry,
                authRevision: _activeAuthRevision,
              );
              await _revokeNativeSsoSessions(data);
              break;
            case WebViewBridgeFeatureType.serviceCountryQuery:
              // 웹이 현재 서비스 국가 조회 → 주입된 serviceCountry 즉시 응답.
              sendData = ServiceCountryEvent().queryResponse(serviceCountry);
              break;
            case WebViewBridgeFeatureType.serviceCountryChange:
              // 웹의 국가 변경 요청 → 앱 콜백으로 위임(override + reload 는 앱 책임).
              final requested = ServiceCountryEvent().parseRequestedCountry(
                data,
              );
              if (requested != null) {
                onServiceCountryChange?.call(requested);
              }
              return;
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
            case WebViewBridgeFeatureType.authUiCommitted:
              await _handleAuthUiCommitted(data);
              return;
          }
        } catch (e) {
          if (e is _AuthOperationAborted) return;
          // OAuth 실패 (sign_in_*.dart 의 throw AuthError) 는 단일 surface:
          // AUTH_ERROR payload 송신 + native SnackBar skip.
          // (사용자 toast 는 webview 측이 단독 표시 — 중복 회피)
          if (e is AuthError) {
            _emitAuthTerminal(
              e.code == 'USER_CANCELLED'
                  ? 'user_cancelled'
                  : const {'NETWORK_ERROR', 'PROVIDER_ERROR'}.contains(e.code)
                  ? 'excluded_external_failure'
                  : 'code_failure:native_auth_error',
              data: data,
            );
            _invalidateAuthTransaction('authError');
            try {
              await runJavaScriptPostMessage(
                jsonEncode({
                  'type': WebViewBridgeFeatureType.authError.value,
                  'data': {
                    'code': e.code,
                    'message': '',
                    'protocolVersion': _activeProtocolVersion,
                    if (_activeRequestId != null) 'requestId': _activeRequestId,
                    if (_authSessionIdOf(data) != null)
                      'authSessionId': _authSessionIdOf(data),
                    if (_stringFieldOf(data, 'documentId') != null)
                      'documentId': _stringFieldOf(data, 'documentId'),
                    'authRevision': _activeAuthRevision,
                  },
                }),
              );
            } catch (_) {}
            return;
          }
          // 일반 exception — silent drop 방지: webview 측이 응답을 기다리고 있으므로 error payload 1건 전송 시도
          try {
            await runJavaScriptPostMessage(
              jsonEncode({
                'type': webViewBridgeFeatureType.value,
                'error': 'NATIVE_INTERNAL_ERROR',
              }),
            );
          } catch (_) {
            // controller stale / channel teardown 등 응답 전송 자체 실패는 무시
          }
          if (context.mounted) {
            WebViewUtils.showErrorSnackBar(context, 'NATIVE_INTERNAL_ERROR');
          }
          return;
        }

        if (webViewBridgeFeatureType ==
            WebViewBridgeFeatureType.refreshTokenRead) {
          processAutoAuthWork = _beginAutoAuthAttemptIfNeeded(data, sendData);
          // protocol v2 자동 인증 응답은 process-wide 소유권이 있을 때만 진행한다.
          // 다른 bridge instance에서 수동 로그인이 진행 중이면 오래된 refresh 결과가
          // 사용자가 선택한 로그인 결과를 덮어쓰지 않도록 응답 자체를 중단한다.
          if (_protocolVersionOf(data) >= 2 && processAutoAuthWork == null) {
            return;
          }
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
          if (replay != null) {
            sendData = replay;
          } else if (_protocolVersionOf(data) >= 2) {
            sendData = await _refreshStoredSessionToTokensReady(sendData, data);
          }
        }

        if (processAutoAuthWork != null &&
            !_processAuthCoordinator.isActive(processAutoAuthWork.lease)) {
          _completeUntrackedAutoAuthWork(processAutoAuthWork);
          return;
        }

        if (webViewBridgeFeatureType ==
            WebViewBridgeFeatureType.refreshTokenRead) {
          _bindAutoAuthAttemptToResponse(sendData);
        }

        // OAuth 계정 선택/동의는 사람의 입력을 기다리는 provider interaction이다.
        // 이 구간에는 짧은 terminal deadline을 적용하지 않고, SDK가 성공 결과를
        // 반환해 web으로 전달할 준비가 끝난 뒤부터 UI 수렴 deadline을 시작한다.
        // 반드시 postMessage 전에 arm해야 즉시 도착하는 UI ACK와의 race가 없다.
        if (_isSsoLogin(webViewBridgeFeatureType) &&
            _authAttemptPhase.completeProviderInteraction()) {
          _emitAuthTrace('auth.provider.completed', data: data);
          _armAttemptTerminalTimer();
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
        } else if (webViewBridgeFeatureType ==
                WebViewBridgeFeatureType.refreshTokenRead &&
            _activeProtocolVersion >= 2 &&
            sendData['type'] ==
                WebViewBridgeFeatureType.authTokensReady.value) {
          if (await _hasCompletedAuthTerminal(data)) {
            _settleAuthTerminalTracking();
            cancelSsoWatchdog('refreshTokenRead:terminalAlreadyCompleted');
            _emitAuthTrace(
              'auth.terminal.rearm_skipped',
              resultCode: 'terminal_already_emitted',
              data: data,
            );
          } else {
            _authAttemptPhase.restoreTerminalConvergence();
            _armAttemptTerminalTimer();
            _armSsoWatchdog(isB2: true);
          }
        }

        // Send Data to WebView
        final encoded = jsonEncode(sendData);
        debugPrint(
          '[Bridge] postMessage type=${webViewBridgeFeatureType.value} len=${encoded.length}',
        );
        try {
          final delivered = await _runJavaScriptPostMessageWithReceipt(encoded);
          _emitAuthTrace(
            'bridge.delivery.${delivered ? "received" : "missed"}',
            resultCode: delivered ? 'received' : 'handler_unavailable',
            data: data,
          );
          debugPrint(
            '[Bridge] postMessage ${delivered ? "RECEIVED" : "MISSED"} '
            'type=${webViewBridgeFeatureType.value}',
          );
        } catch (e) {
          debugPrint(
            '[Bridge] postMessage FAIL '
            'type=${webViewBridgeFeatureType.value}: ${e.runtimeType}',
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
        _completeUntrackedAutoAuthWork(processAutoAuthWork);
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
        print(
          '[SsoExchange] native SSO logout FAIL '
          'provider=$provider: ${e.runtimeType}',
        );
      }
    }
  }

  Future<void> _handleAuthUiCommitted(dynamic data) async {
    if (data is! Map || data['protocolVersion'] != 2) return;

    final workSnapshot = _captureAuthTerminalWork(data);
    if (!_isCurrentAuthTerminalWork(workSnapshot)) {
      _emitAuthTrace(
        'auth.ui.rejected',
        resultCode: 'stale_auth_work',
        data: data,
      );
      return;
    }

    final terminalKey = _terminalKeyOf(data);
    if (_terminalAuthSessionIds.contains(terminalKey)) {
      _emitAuthTrace(
        'auth.ui.duplicate_ignored',
        resultCode: 'idempotent_duplicate',
        data: data,
      );
      return;
    }

    // UI ACK가 native URL을 확인하는 동안 deadline timer가 같은 attempt를 먼저
    // 실패 처리하지 못하게 잠시 멈춘다. 거부되면 기존 모드로 다시 arm한다.
    final attemptTimerWasActive = _attemptTerminalTimer?.isActive ?? false;
    final watchdogWasActive = _ssoWatchdog?.isActive ?? false;
    final watchdogWasB2 = _ssoWatchdogB2;
    _attemptTerminalTimer?.cancel();
    _attemptTerminalTimer = null;
    _ssoWatchdog?.cancel();
    _ssoWatchdog = null;
    var accepted = false;

    // `_awaitingAuthTerminal == false`는 성공 terminal의 증거가 아니다. 새 document의
    // 토큰 read/ACK 순서에 따라 flag가 false인 동안에도 유효한 UI commit이 도착할 수 있다.
    // 반드시 payload를 먼저 검증하고 실제 terminal key/영속 marker로만 중복 판정한다.
    try {
      String? currentUrl;
      try {
        currentUrl = await webViewController.currentUrl().timeout(
          const Duration(seconds: 3),
        );
      } catch (error) {
        _emitAuthTrace(
          'auth.ui.rejected',
          resultCode: 'native_url_unavailable',
          data: data,
        );
        return;
      }
      if (!_isCurrentAuthTerminalWork(workSnapshot)) {
        _emitAuthTrace(
          'auth.ui.rejected',
          resultCode: 'attempt_changed_during_url_check',
          data: data,
        );
        return;
      }
      final decision = validateAuthUiCommit(
        data: data,
        activeRequestId: _activeRequestId,
        activeAuthSessionId: _activeAuthSessionId,
        activeAuthRevision: _activeAuthRevision,
        nativeIsHome: _isHomePath(currentUrl),
        webIsHome: _isHomePath(_stringFieldOf(data, 'pathname')),
      );
      if (!decision.isAccepted) {
        _emitAuthTrace(
          'auth.ui.rejected',
          resultCode: decision.rejection!.name,
          data: data,
        );
        return;
      }
      accepted = true;

      // 여기부터는 사용자가 보는 UI 성공이 검증됐다. SharedPreferences 조회/쓰기 중
      // watchdog이 끼어들어 같은 시도를 timeout으로 먼저 종결하지 못하게 즉시 정지한다.
      _settleAuthTerminalTracking();
      cancelSsoWatchdog('authUiCommitted:validated');

      final hasCompletedTerminal = await _hasCompletedAuthTerminal(data);
      if (hasCompletedTerminal) {
        _emitAuthTrace(
          'auth.ui.duplicate_ignored',
          resultCode: 'idempotent_duplicate',
          data: data,
        );
        return;
      }
      if (!_isCurrentAuthTerminalWork(workSnapshot)) {
        _emitAuthTrace(
          'auth.ui.rejected',
          resultCode: 'attempt_changed_during_terminal_check',
          data: data,
        );
        return;
      }

      try {
        await const AuthTerminalStore().markSuccess(
          authSessionId: _effectiveAuthSessionIdOf(data),
          authRevision: _authRevisionOf(data) ?? _activeAuthRevision,
          serviceCountry: serviceCountry,
        );
      } catch (error) {
        // 계측 idempotency 저장 실패 때문에 사용자가 이미 본 로그인 성공을 실패로
        // 바꾸지 않는다. 현재 process에서는 in-memory key가 계속 중복을 막는다.
        // ignore: avoid_print
        print(
          '[SsoExchange] auth terminal marker write FAIL: ${error.runtimeType}',
        );
      }
      if (!_isCurrentAuthTerminalWork(workSnapshot)) {
        _emitAuthTrace(
          'auth.ui.rejected',
          resultCode: 'attempt_changed_during_marker_write',
          data: data,
        );
        return;
      }
      _emitAuthTerminal('ui_authenticated', data: data);
    } finally {
      if (!accepted &&
          _isCurrentAuthTerminalWork(workSnapshot) &&
          _awaitingAuthTerminal) {
        if (attemptTimerWasActive) _armAttemptTerminalTimer();
        if (watchdogWasActive) _armSsoWatchdog(isB2: watchdogWasB2);
      }
    }
  }

  Future<void> _navigateHome(dynamic data) async {
    if (!_canRunLifecycleSensitiveWebViewWork) return;

    final authSessionId = _authSessionIdOf(data);
    final rawCurrentUrl = await webViewController.currentUrl();
    if (!_canRunLifecycleSensitiveWebViewWork) return;
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
    if (!_canRunLifecycleSensitiveWebViewWork) return;
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

  Future<Map<String, Object?>> _refreshStoredSessionToTokensReady(
    Map<String, Object?> readResponse,
    dynamic requestData,
  ) async {
    final readData = readResponse['data'];
    final refreshToken = readData is Map
        ? readData['refreshToken'] as String?
        : null;
    if (refreshToken == null || refreshToken.isEmpty) return readResponse;

    try {
      final sso = SsoExchange(
        apiBaseUrl: apiBaseUrl!,
        domainType: serviceCountry == 'GLOBAL'
            ? 'sazo-global-shop'
            : 'sazo-korea-shop',
      );
      final deviceHeaders = await _deviceHeaders();
      final result = await sso.refreshToAccess(
        refreshToken: refreshToken,
        deviceHeaders: deviceHeaders,
      );
      if (!context.mounted) throw StateError('CONTEXT_DISPOSED');
      final persisted = await RefreshTokenEvent().process(
        context,
        action: 'write',
        data: result.refreshToken,
        serviceCountry: serviceCountry,
        authRevision: _activeAuthRevision,
      );
      if (persisted['error'] != null) {
        throw StateError('REFRESH_TOKEN_PERSIST_FAILED');
      }
      final me = await sso.fetchMe(
        accessToken: result.accessToken,
        deviceHeaders: deviceHeaders,
      );
      final payload = <String, Object?>{
        'type': WebViewBridgeFeatureType.authTokensReady.value,
        'data': {
          'accessToken': result.accessToken,
          'refreshToken': result.refreshToken,
          'protocolVersion': 2,
          if (_requestIdOf(requestData) != null)
            'requestId': _requestIdOf(requestData),
          if (_authSessionIdOf(requestData) != null)
            'authSessionId': _authSessionIdOf(requestData),
          if (_stringFieldOf(requestData, 'documentId') != null)
            'documentId': _stringFieldOf(requestData, 'documentId'),
          if (requestData is Map && requestData['pageGeneration'] is int)
            'pageGeneration': requestData['pageGeneration'] as int,
          'authRevision': _activeAuthRevision,
          if (me != null) 'me': me,
        },
      };
      _cachedSessionPayload = payload;
      _cachedSessionAt = DateTime.now();
      _emitAuthTrace('auth.refresh.exchanged', data: requestData);
      return payload;
    } catch (error) {
      final statusCode = error is SsoExchangeException
          ? error.statusCode
          : null;
      if (statusCode != null &&
          statusCode >= 400 &&
          statusCode < 500 &&
          statusCode != 408 &&
          statusCode != 429 &&
          context.mounted) {
        await RefreshTokenEvent().process(
          context,
          action: 'delete',
          serviceCountry: serviceCountry,
          authRevision: _activeAuthRevision,
        );
      }
      _emitAuthTerminal(
        _isExternalSsoFailure(error)
            ? 'excluded_external_failure'
            : 'code_failure:native_refresh_exchange',
        data: requestData,
      );
      return {
        'type': WebViewBridgeFeatureType.authError.value,
        'data': {
          'code': 'REFRESH_EXCHANGE_FAILED',
          'message': '',
          'protocolVersion': 2,
          if (_requestIdOf(requestData) != null)
            'requestId': _requestIdOf(requestData),
          if (_authSessionIdOf(requestData) != null)
            'authSessionId': _authSessionIdOf(requestData),
          if (_stringFieldOf(requestData, 'documentId') != null)
            'documentId': _stringFieldOf(requestData, 'documentId'),
          'authRevision': _activeAuthRevision,
        },
      };
    }
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
      // domainType: KR(또는 null)=sazo-korea-shop(현행) / GLOBAL=sazo-global-shop
      // (웹 배포 계약 09-env-runtime 확인값). KR 경로 byte-identical.
      final sso = SsoExchange(
        apiBaseUrl: apiBaseUrl!,
        domainType: serviceCountry == 'GLOBAL'
            ? 'sazo-global-shop'
            : 'sazo-korea-shop',
      );
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
      final persistResult = await RefreshTokenEvent().process(
        // ignore: use_build_context_synchronously
        context,
        action: 'write',
        data: result.refreshToken,
        serviceCountry: serviceCountry,
        authRevision: _activeAuthRevision,
      );
      if (persistResult['error'] != null) {
        throw StateError('REFRESH_TOKEN_PERSIST_FAILED');
      }
      _emitAuthTrace('auth.refresh.persisted', data: requestData);
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
          'protocolVersion': _activeProtocolVersion,
          if (_activeRequestId != null) 'requestId': _activeRequestId,
          if (_stringFieldOf(requestData, 'documentId') != null)
            'documentId': _stringFieldOf(requestData, 'documentId'),
          if (requestData is Map && requestData['pageGeneration'] is int)
            'pageGeneration': requestData['pageGeneration'] as int,
          'authRevision': _activeAuthRevision,
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
      print('[SsoExchange] FAIL ${type.value}: ${e.runtimeType}');
      _emitAuthTerminal(
        _isExternalSsoFailure(e)
            ? 'excluded_external_failure'
            : 'code_failure:sso_exchange',
        data: requestData,
      );
      return {
        'type': WebViewBridgeFeatureType.authError.value,
        'data': {
          'code': 'SSO_EXCHANGE_FAILED',
          'message': '',
          'protocolVersion': _activeProtocolVersion,
          if (_activeRequestId != null) 'requestId': _activeRequestId,
          if (authSessionId != null) 'authSessionId': authSessionId,
          if (_stringFieldOf(requestData, 'documentId') != null)
            'documentId': _stringFieldOf(requestData, 'documentId'),
          'authRevision': _activeAuthRevision,
        },
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
    if (requestData is Map && payload['data'] is Map) {
      final replayData = Map<String, Object?>.from(payload['data'] as Map);
      for (final key in const [
        'protocolVersion',
        'requestId',
        'authSessionId',
        'documentId',
        'pageGeneration',
      ]) {
        if (requestData[key] != null) replayData[key] = requestData[key];
      }
      replayData['authRevision'] = _activeAuthRevision;
      _activeRequestId = _requestIdOf(requestData);
      return {
        'type': WebViewBridgeFeatureType.authTokensReady.value,
        'data': replayData,
      };
    }
    return payload;
  }
  // ───────────────────────────────────────────────────────────────────────────

  Future<void> runJavaScriptAppState(String jsonData) async {
    if (!_canRunLifecycleSensitiveWebViewWork) return;

    await _runBridgeCallback(
      callbackName: 'callbackAppState',
      jsonData: jsonData,
    );
  }

  Future<void> runJavaScriptReturningResultAppState(String jsonData) {
    return runJavaScriptAppState(jsonData);
  }

  Future<void> runJavaScriptPostMessage(String jsonData) async {
    await _runJavaScriptPostMessageWithReceipt(jsonData);
  }

  Future<bool> _runJavaScriptPostMessageWithReceipt(String jsonData) async {
    if (!_canTouchWebView) return false;

    if (!_isAppResumed) {
      _enqueuePendingPostMessage(jsonData);
      return false;
    }

    return _sendPostMessageNow(jsonData);
  }

  Future<void> runJavaScriptReturningResultPostMessage(String jsonData) {
    return runJavaScriptPostMessage(jsonData);
  }

  void _enqueuePendingPostMessage(String jsonData) {
    if (_pendingPostMessages.length >= _maxPendingPostMessages) {
      _pendingPostMessages.removeFirst();
    }
    _pendingPostMessages.add(jsonData);
    debugPrint(
      '[Bridge] postMessage queued appLifecycle=${_appLifecycleState.name} '
      'queue=${_pendingPostMessages.length}',
    );
  }

  Future<void> _flushPendingPostMessages() async {
    if (_isFlushingPendingPostMessages ||
        !_canRunLifecycleSensitiveWebViewWork) {
      return;
    }

    _isFlushingPendingPostMessages = true;
    try {
      while (_pendingPostMessages.isNotEmpty &&
          _canRunLifecycleSensitiveWebViewWork) {
        final jsonData = _pendingPostMessages.removeFirst();
        await _sendPostMessageNow(jsonData);
      }
    } finally {
      _isFlushingPendingPostMessages = false;
    }
  }

  Future<bool> _sendPostMessageNow(String jsonData) {
    return _runBridgeCallback(
      callbackName: 'callbackPostMessage',
      jsonData: jsonData,
    );
  }

  Future<bool> _runBridgeCallback({
    required String callbackName,
    required String jsonData,
  }) async {
    if (!_canTouchWebView) return false;

    final payloadLiteral = jsonEncode(jsonData);
    try {
      final result = await webViewController.runJavaScriptReturningResult('''
        (function() {
          try {
            var payload = $payloadLiteral;
            if (typeof window.$callbackName === 'function') {
              window.$callbackName(payload);
              return true;
            }
            if (typeof document.$callbackName === 'function') {
              document.$callbackName(payload);
              return true;
            }
            return false;
          } catch (_) {
            return false;
          }
        })();
      ''');
      return result == true || result == 1 || result == 'true';
    } catch (e) {
      if (!_isDisposed) {
        debugPrint('[Bridge] $callbackName JS skipped: ${e.runtimeType}');
      }
      return false;
    }
  }
}
