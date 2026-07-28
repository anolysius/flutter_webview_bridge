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
import 'events/auth_error_mapper.dart';
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
import 'auth/auth_convergence_deadline.dart';
import 'auth/auth_protocol_negotiation.dart';
import 'auth/auth_recovery_gate.dart';
import 'auth/auth_revision_store.dart';
import 'auth/auth_semantic_commit.dart';
import 'auth/auth_terminal_store.dart';
import 'auth/auth_trace_correlation.dart';
import 'auth/auth_ui_commit.dart';
import 'auth/auto_auth_attempt.dart';
import 'auth/interactive_refresh_convergence.dart';
import 'auth/pending_auth_attempt_store.dart';
import 'auth/pending_reauth_replay.dart';
import 'auth/process_auth_attempt_coordinator.dart';
import 'auth/refresh_token_protocol_adapter.dart';
import 'auth/service_auth_context.dart';
import 'auth/unexpected_auth_failure.dart';

typedef AuthTraceCallback = void Function(Map<String, Object?> event);
typedef AuthContextStatusCallback =
    FutureOr<void> Function(Map<String, Object?> status);
typedef AuthContextRestartCallback =
    FutureOr<void> Function(Map<String, Object?> request);
typedef WebAuthContextCapabilityCallback =
    void Function({
      required bool supported,
      required String? documentId,
      required int navigationGeneration,
    });
typedef AuthProviderOperation =
    Future<Map<String, Object?>> Function(
      WebViewBridgeFeatureType type,
      BuildContext context,
      dynamic data,
    );

String? _canonicalHttpOrigin(String? value) {
  if (value == null || value.trim().isEmpty) return null;
  final uri = Uri.tryParse(value.trim());
  if (uri == null ||
      (uri.scheme != 'http' && uri.scheme != 'https') ||
      uri.host.isEmpty) {
    return null;
  }
  return uri.origin;
}

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

class _BridgeMessageCompletion {
  final Completer<void> completer = Completer<void>();
  bool deferred = false;
}

class _BufferedTransitionMessage {
  const _BufferedTransitionMessage({
    required this.message,
    required this.receivedNavigationGeneration,
    required this.receivedServiceContextGeneration,
    required this.transitionConfirmation,
    required this.completion,
  });

  final JavaScriptMessage message;
  final int receivedNavigationGeneration;
  final int receivedServiceContextGeneration;
  final Completer<int?> transitionConfirmation;
  final _BridgeMessageCompletion completion;
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
  String? _apiBaseUrl;
  String? get apiBaseUrl => _apiBaseUrl;
  final String? bridgeRevision;

  /// 서비스 국가 코드 (APP-300 R5 — 'KR' / 'GLOBAL'). 미주입(null)=KR/레거시 동작.
  /// RefreshToken 키 + SSO domainType 분기에 사용. KR/null 은 현행과 byte-identical.
  ///
  /// staff 국가 전환(SERVICE_COUNTRY_CHANGE) 시 [updateServiceCountry] 로 세션 내 갱신 →
  /// 재시작 없이 refresh-key/domainType 가 새 국가를 반영한다.
  String? _serviceCountry;
  String? get serviceCountry => _serviceCountry;
  String? _webOrigin;
  late ServiceAuthContext _serviceAuthContext;
  bool _serviceContextTransitionInProgress = false;
  int? _serviceContextTransitionReleaseNavigationGeneration;
  String? _serviceContextTransitionExpectedWebOrigin;
  Completer<int?>? _serviceContextTransitionNavigationConfirmation;

  /// 웹의 SERVICE_COUNTRY_CHANGE 수신 시 앱이 override+reload 하도록 위임하는 콜백.
  final void Function(String requestedCountry)? onServiceCountryChange;
  final AuthTraceCallback? onAuthTrace;
  final AuthContextStatusCallback? onAuthContextStatus;
  final AuthContextRestartCallback? onAuthContextRestart;
  final WebAuthContextCapabilityCallback? onWebAuthContextCapability;
  int _webDocumentNavigationGeneration;
  @visibleForTesting
  final AuthProviderOperation? testAuthProviderOperation;
  @visibleForTesting
  final Future<void> Function()? testClearAllRefreshTokens;
  bool _isDisposed = false;
  bool _pendingSsoRecovery = false;
  AppLifecycleState _appLifecycleState = AppLifecycleState.resumed;
  final Queue<String> _pendingPostMessages = Queue<String>();
  bool _isFlushingPendingPostMessages = false;
  Future<void> _messageSerial = Future<void>.value();
  final Queue<_BufferedTransitionMessage> _bufferedTransitionMessages =
      Queue<_BufferedTransitionMessage>();
  static const int _maxPendingPostMessages = 20;
  static const int _maxBufferedTransitionMessages = 20;
  int _authAttemptAckDeliveryGeneration = 0;
  final AuthContextOperationRegistry _authContextStatusOperations =
      AuthContextOperationRegistry();
  final AuthContextRecoveryCoordinator _authContextRecoveryCoordinator =
      AuthContextRecoveryCoordinator();
  final AuthDocumentBoundary _authDocumentBoundary = AuthDocumentBoundary();

  FlutterWebViewBridgeJavaScriptChannel({
    required this.context,
    required this.webViewController,
    this.channelName = 'IN_APP_WEBVIEW_BRIDGE_CHANNEL',
    required this.googleServerClientId,
    required this.kakaoNativeAppKey,
    String? apiBaseUrl,
    String? webOrigin,
    this.bridgeRevision,
    String? serviceCountry,
    this.onServiceCountryChange,
    this.onAuthTrace,
    this.onAuthContextStatus,
    this.onAuthContextRestart,
    this.onWebAuthContextCapability,
    int webDocumentNavigationGeneration = 0,
    this.testAuthProviderOperation,
    this.testClearAllRefreshTokens,
  }) : _webDocumentNavigationGeneration = webDocumentNavigationGeneration,
       _apiBaseUrl = apiBaseUrl,
       _webOrigin = _canonicalHttpOrigin(webOrigin),
       _serviceCountry = normalizeServiceCountry(serviceCountry) {
    validateServiceAuthContextPair(
      serviceCountry: serviceCountry,
      apiBaseUrl: apiBaseUrl,
    );
    _serviceAuthContext = ServiceAuthContext(
      serviceCountry: normalizeServiceCountry(serviceCountry),
      apiBaseUrl: apiBaseUrl,
      generation: 0,
    );
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

  /// 국가 전환의 첫 await 전에 호출한다. 이후 시작되는 인증 mutation을 target context가
  /// 설치되고 새 문서 탐색이 시작될 때까지 차단하며, 이미 실행 중인 모든 인증 snapshot을
  /// stale로 만든다.
  void beginServiceContextTransition(String reason) {
    if (_isDisposed || _serviceContextTransitionInProgress) return;
    _serviceContextTransitionInProgress = true;
    _serviceContextTransitionReleaseNavigationGeneration = null;
    _serviceContextTransitionExpectedWebOrigin = null;
    final previousConfirmation =
        _serviceContextTransitionNavigationConfirmation;
    if (previousConfirmation != null && !previousConfirmation.isCompleted) {
      _resolveTransitionConfirmation(previousConfirmation, null);
    }
    _serviceContextTransitionNavigationConfirmation = Completer<int?>();
    _serviceAuthContext = _serviceAuthContext.next(
      serviceCountry: _serviceAuthContext.serviceCountry,
      apiBaseUrl: _serviceAuthContext.apiBaseUrl,
    );
    resetAuthStateForServiceCountrySwitch(reason);
    _emitAuthTrace('auth.context.transition_started', resultCode: reason);
  }

  /// serviceCountry, API origin, domainType을 동일 generation으로 원자 갱신한다.
  void updateServiceContext({
    required String? serviceCountry,
    required String? apiBaseUrl,
    String? webOrigin,
    bool waitForNextNavigation = false,
  }) {
    if (_isDisposed) return;
    final nextCountry = normalizeServiceCountry(serviceCountry);
    final nextWebOrigin = _canonicalHttpOrigin(webOrigin) ?? _webOrigin;
    final isSameContext =
        nextCountry == _serviceAuthContext.serviceCountry &&
        apiBaseUrl == _serviceAuthContext.apiBaseUrl &&
        nextWebOrigin == _webOrigin;
    if (!_serviceContextTransitionInProgress &&
        isSameContext &&
        !waitForNextNavigation) {
      return;
    }
    if (!_serviceContextTransitionInProgress) {
      _serviceContextTransitionInProgress = waitForNextNavigation;
      _serviceContextTransitionReleaseNavigationGeneration = null;
      resetAuthStateForServiceCountrySwitch('service-context-direct-update');
    }
    final nextContext = _serviceAuthContext.next(
      serviceCountry: nextCountry,
      apiBaseUrl: apiBaseUrl,
    );
    _serviceCountry = nextContext.serviceCountry;
    _apiBaseUrl = nextContext.apiBaseUrl;
    _webOrigin = nextWebOrigin;
    _serviceAuthContext = nextContext;
    if (waitForNextNavigation) {
      // Context installation alone does not retire the still-visible old
      // document. Keep the mutation fence closed until the target load
      // synchronously claims the next navigation generation.
      _serviceContextTransitionInProgress = true;
      _serviceContextTransitionReleaseNavigationGeneration =
          _webDocumentNavigationGeneration + 1;
      _serviceContextTransitionExpectedWebOrigin = nextWebOrigin;
      _serviceContextTransitionNavigationConfirmation ??= Completer<int?>();
      _emitAuthTrace(
        'auth.context.transition_context_installed',
        data: {
          'serviceCountry': nextCountry,
          'domainType': _serviceAuthContext.domainType,
          'expectedWebOrigin': nextWebOrigin,
          'releaseNavigationGeneration':
              _serviceContextTransitionReleaseNavigationGeneration,
        },
      );
      return;
    }
    _completeServiceContextTransition(
      confirmedNavigationGeneration: _webDocumentNavigationGeneration,
    );
  }

  void _completeServiceContextTransition({int? confirmedNavigationGeneration}) {
    final confirmation = _serviceContextTransitionNavigationConfirmation;
    _serviceContextTransitionNavigationConfirmation = null;
    _serviceContextTransitionInProgress = false;
    _serviceContextTransitionReleaseNavigationGeneration = null;
    _serviceContextTransitionExpectedWebOrigin = null;
    if (confirmation != null) {
      _resolveTransitionConfirmation(
        confirmation,
        confirmedNavigationGeneration,
      );
    }
    _emitAuthTrace(
      'auth.context.transition_completed',
      data: {
        'serviceCountry': _serviceAuthContext.serviceCountry,
        'domainType': _serviceAuthContext.domainType,
      },
    );
  }

  /// legacy caller 호환. 새 앱은 반드시 [beginServiceContextTransition] 뒤
  /// [updateServiceContext]로 country와 API origin을 함께 갱신한다.
  void updateServiceCountry(String? code) {
    updateServiceContext(
      serviceCountry: code,
      apiBaseUrl: apiBaseUrlForServiceCountry(
        apiBaseUrl: _apiBaseUrl,
        serviceCountry: code,
      ),
    );
  }

  /// 명시적 로그아웃(staff 서비스 국가 전환 등) 시 in-memory SSO transient 상태를 정리한다.
  /// = SSO replay 캐시(`_cachedSessionPayload`) + watchdog + kakao resend.
  ///
  /// persistent refresh token([clearAllRefreshTokens])만 지우면, 전환 reload 후 새 문서의
  /// REFRESH_TOKEN_READ 에 bridge 가 TTL(120s) 내 캐시를 replay 해 재인증되어 로그아웃이
  /// 안 된다. 전환 경로에서 reload 전에 호출해 replay window 를 제거한다.
  void clearSsoTransientState(String reason) => _clearSsoTransientState(reason);

  Future<void> _clearAllRefreshTokens() =>
      testClearAllRefreshTokens?.call() ?? clearAllRefreshTokens();

  /// 서비스 국가 전환은 token/replay뿐 아니라 process-wide 인증 소유권까지 끊는 경계다.
  /// 남은 interactive lease가 새 origin의 REFRESH_TOKEN_READ를 막지 않게 reload 전에 호출한다.
  void resetAuthStateForServiceCountrySwitch(String reason) {
    _authDocumentBoundary.invalidate(_activeDocumentId);
    _processAuthCoordinator.resetForAuthBoundary();
    _autoAuthAttempt.resetForAuthBoundary();
    _invalidateAuthTransaction(reason);
    // revision/request/document는 service-country domain에 속한다. 이전 국가 값이 대상
    // 국가 첫 read에 섞이면 정상 로그인 응답이 stale-revision으로 거부된다.
    _activeAuthRevision = 0;
    _activeProtocolVersion = 1;
    _activeAuthCapabilities = const <String>{};
    _activeRequestId = null;
    _activeDocumentId = null;
    _emitAuthTrace('auth.boundary.reset', resultCode: reason);
  }

  AuthWorkContextSnapshot _captureAuthWorkContext() => AuthWorkContextSnapshot(
    authEpoch: _authEpoch,
    authRevision: _activeAuthRevision,
    service: _serviceAuthContext,
  );

  bool _isCurrentAuthWorkContext(AuthWorkContextSnapshot snapshot) =>
      snapshot.matches(
        authEpoch: _authEpoch,
        authRevision: _activeAuthRevision,
        service: _serviceAuthContext,
        transitionInProgress: _serviceContextTransitionInProgress,
      );

  AuthContextWorkFence _authContextWorkFence(
    AuthWorkContextSnapshot snapshot,
    dynamic data,
  ) => AuthContextWorkFence(
    snapshot: snapshot,
    isCurrent: _isCurrentAuthWorkContext,
    onStale: (stage) => _discardStaleAuthWorkContext(stage, data),
  );

  void updateAppLifecycleState(AppLifecycleState state) {
    if (_isDisposed) return;

    _appLifecycleState = state;
    if (_isAppResumed) {
      _authConvergenceDeadline.resume();
      if (_authAttemptPhase.shouldRunTerminalDeadline) {
        _armAttemptTerminalTimer();
      }
      unawaited(_runResumedPendingWork());
    } else {
      _authConvergenceDeadline.pause();
      _attemptTerminalTimer?.cancel();
      _attemptTerminalTimer = null;
    }
  }

  void updateWebDocumentNavigationGeneration(int generation) {
    if (_isDisposed || generation < _webDocumentNavigationGeneration) return;
    _webDocumentNavigationGeneration = generation;
  }

  void confirmWebDocumentNavigation({
    required int generation,
    required String? documentUrl,
  }) {
    if (_isDisposed || generation != _webDocumentNavigationGeneration) return;
    final releaseGeneration =
        _serviceContextTransitionReleaseNavigationGeneration;
    if (!_serviceContextTransitionInProgress ||
        releaseGeneration == null ||
        generation < releaseGeneration) {
      return;
    }
    final expectedOrigin = _serviceContextTransitionExpectedWebOrigin;
    final actualOrigin = _canonicalHttpOrigin(documentUrl);
    if (expectedOrigin == null || actualOrigin != expectedOrigin) {
      _emitAuthTrace(
        'auth.context.transition_navigation_rejected',
        resultCode: 'origin_mismatch',
        data: {
          'serviceCountry': _serviceAuthContext.serviceCountry,
          'expectedWebOrigin': expectedOrigin,
          'actualWebOrigin': actualOrigin,
          'navigationGeneration': generation,
        },
      );
      return;
    }
    // Auth requests received while origin confirmation was pending wait on the
    // transition completion. Only requests captured from this exact target
    // navigation are resumed; pre-navigation and superseded-document requests
    // are discarded by their receipt generation.
    _completeServiceContextTransition(
      confirmedNavigationGeneration: generation,
    );
  }

  void dispose() {
    final processLease = _processAuthLease;
    final shouldEmitConvergenceHandoff = _authAttemptPhase
        .shouldEmitConvergenceHandoffOnDispose(
          hasActiveProcessLease:
              processLease != null &&
              _processAuthCoordinator.isActive(processLease),
        );
    if (shouldEmitConvergenceHandoff) {
      // 인증 시작 document가 home/account document로 교체되면 이 bridge의 timer와
      // process owner가 함께 사라져 원 시도가 terminal 없이 남을 수 있다. 새 document의
      // 자동 인증이 같은 revision에서 UI 성공을 증명하도록 명시적인 handoff로 닫는다.
      // 집계기는 후속 UI 성공이 없는 handoff를 실패로 계산하므로 누락을 숨기지 않는다.
      _processAuthCoordinator.recordConvergenceHandoff(
        lease: processLease!,
        convergenceKey: '${serviceCountry ?? "KR"}:$_activeAuthRevision',
      );
      _emitAuthTerminal('convergence_handoff', data: _activeAuthProtocolData());
    }
    _isDisposed = true;
    final transitionConfirmation =
        _serviceContextTransitionNavigationConfirmation;
    if (transitionConfirmation != null && !transitionConfirmation.isCompleted) {
      transitionConfirmation.complete(null);
    }
    _serviceContextTransitionNavigationConfirmation = null;
    for (final buffered in _bufferedTransitionMessages) {
      if (!buffered.completion.completer.isCompleted) {
        buffered.completion.completer.complete();
      }
    }
    _bufferedTransitionMessages.clear();
    final abortCompleter = _activeAuthAbortCompleter;
    if (abortCompleter != null && !abortCompleter.isCompleted) {
      abortCompleter.complete();
    }
    _activeAuthAbortCompleter = null;
    _authAttemptPhase.settle();
    _authConvergenceDeadline.settle();
    _autoAuthAttempt.clearActiveAttempt();
    _completeProcessAuthLease();
    _attemptTerminalTimer?.cancel();
    _attemptTerminalTimer = null;
    _authAttemptAckDeliveryGeneration += 1;
    _pendingSsoRecovery = false;
    _pendingConvergenceSoftRecovery = false;
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
    if (_pendingConvergenceSoftRecovery &&
        _canRunLifecycleSensitiveWebViewWork) {
      _pendingConvergenceSoftRecovery = false;
      await _runConvergenceSoftRecovery();
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
  Timer? _attemptTerminalTimer;
  final AuthAttemptPhaseController _authAttemptPhase =
      AuthAttemptPhaseController();
  final AuthConvergenceDeadlineController _authConvergenceDeadline =
      AuthConvergenceDeadlineController();
  bool get _awaitingAuthTerminal => _authAttemptPhase.isAwaitingTerminal;
  Completer<void>? _activeAuthAbortCompleter;
  // B2 watchdog 여부 — timeout 시 raw 재전송(B1) 대신 reload→세션 replay(B2) 로 복구.
  bool _ssoWatchdogB2 = false;
  bool _pendingConvergenceSoftRecovery = false;
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
  Set<String> _activeAuthCapabilities = const <String>{};
  String? _activeAuthSessionId;
  String? _activeAuthProvider;
  String? _activeAuthJourney;
  String? _activeReauthSemanticReason;
  String? _activeRequestId;
  String? _activeDocumentId;
  final Set<String> _terminalAuthSessionIds = <String>{};
  final Set<String> _onboardingReadyKeys = <String>{};
  final Set<String> _interruptedAttemptRecoveryChecked = <String>{};
  final AuthTraceCorrelationCache _authTraceCorrelations =
      AuthTraceCorrelationCache();
  final AutoAuthAttemptController _autoAuthAttempt =
      AutoAuthAttemptController();
  final ProcessAuthAttemptCoordinator _processAuthCoordinator =
      ProcessAuthAttemptCoordinator.shared;
  ProcessAuthAttemptLease? _processAuthLease;
  final Stopwatch _authTotalElapsed = Stopwatch();
  int? _activeProviderElapsedMs;
  final AuthRecoveryGate _authRecoveryGate = AuthRecoveryGate();

  bool get _ownsActiveInteractiveLease {
    final lease = _processAuthLease;
    return lease != null &&
        lease.kind == ProcessAuthAttemptKind.interactive &&
        _processAuthCoordinator.isActive(lease);
  }

  bool get _ownsActiveAutomaticLease {
    final lease = _processAuthLease;
    return lease != null &&
        lease.kind == ProcessAuthAttemptKind.automatic &&
        _processAuthCoordinator.isActive(lease);
  }

  bool get _hasPendingAutomaticReauth =>
      _ownsActiveAutomaticLease &&
      _awaitingAuthTerminal &&
      _activeReauthSemanticReason != null;

  String? get _cachedAuthSessionId {
    final data = _cachedSessionPayload?['data'];
    return data is Map ? data['authSessionId'] as String? : null;
  }

  bool _canReplayInteractiveRefresh(dynamic data) =>
      shouldReplayInteractiveRefresh(
        ownsActiveInteractiveLease: _ownsActiveInteractiveLease,
        isTerminalConvergence: _authAttemptPhase.shouldRunTerminalDeadline,
        activeAuthSessionId: _activeAuthSessionId,
        cachedAuthSessionId: _cachedAuthSessionId,
        requestedAuthSessionId: _authSessionIdOf(data),
      );

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

  int? _authRevisionOf(dynamic data) =>
      data is Map && data['authRevision'] is int
      ? data['authRevision'] as int
      : null;

  void _rememberActiveAuthCorrelation({String? attemptId}) {
    final requestId = _activeRequestId;
    final resolvedAttemptId = attemptId ?? _activeAuthSessionId;
    if (requestId == null || resolvedAttemptId == null) return;
    _authTraceCorrelations.remember(
      AuthTraceCorrelation(
        requestId: requestId,
        loginAttemptId: resolvedAttemptId,
        authRevision: _activeAuthRevision,
        protocolVersion: _activeProtocolVersion,
        provider: _activeAuthProvider,
        documentId: _activeDocumentId,
        predecessorAttemptId: _processAuthCoordinator
            .activePredecessorForAttempt(resolvedAttemptId),
      ),
    );
  }

  Map<String, Object?>? _replayPendingAutomaticReauth(dynamic requestData) {
    final replayData = buildPendingReauthReplay(
      ownsActiveAutomaticLease: _ownsActiveAutomaticLease,
      isAwaitingTerminal: _awaitingAuthTerminal,
      activeAuthSessionId: _activeAuthSessionId,
      activeAuthRevision: _activeAuthRevision,
      semanticReason: _activeReauthSemanticReason,
      requestData: requestData,
    );
    if (replayData == null) return null;

    _activeProtocolVersion = currentAuthProtocolVersion;
    _activeAuthCapabilities = negotiateAuthProtocolCapabilities(requestData);
    _activeRequestId = _requestIdOf(replayData);
    _activeDocumentId = _stringFieldOf(replayData, 'documentId');
    _rememberActiveAuthCorrelation();
    _emitAuthTrace(
      'auth.reauth.document_replay',
      resultCode: 'pending_reauth_replayed',
      data: replayData,
    );
    return <String, Object?>{
      'type': WebViewBridgeFeatureType.authReauthRequired.value,
      'data': replayData,
    };
  }

  void _emitAuthTrace(String event, {String? resultCode, dynamic data}) {
    final requestId = _requestIdOf(data) ?? _activeRequestId;
    final correlation = _authTraceCorrelations.resolve(requestId);
    final attemptId =
        _effectiveAuthSessionIdOf(data) ?? correlation?.loginAttemptId;
    final predecessorAttemptId =
        data is Map && data['predecessorAttemptId'] is String
        ? data['predecessorAttemptId'] as String
        : _processAuthCoordinator.activePredecessorForAttempt(attemptId) ??
              correlation?.predecessorAttemptId;
    onAuthTrace?.call({
      'traceSchemaVersion': 3,
      'protocolVersion': correlation?.protocolVersion ?? _activeProtocolVersion,
      'loginAttemptId': attemptId,
      if (predecessorAttemptId != null)
        'predecessorAttemptId': predecessorAttemptId,
      'requestId': requestId,
      'authRevision':
          _authRevisionOf(data) ??
          correlation?.authRevision ??
          _activeAuthRevision,
      if (data is Map && data['documentId'] is String)
        'documentId': data['documentId'] as String,
      if (!(data is Map && data['documentId'] is String) &&
          correlation?.documentId != null)
        'documentId': correlation!.documentId,
      if (data is Map && data['pathname'] is String)
        'pathname': data['pathname'] as String,
      if (data is Map && data['host'] is String) 'host': data['host'] as String,
      if (data is Map && data['visibilityState'] is String)
        'visibilityState': data['visibilityState'] as String,
      'provider':
          _providerOfRequest(data) ??
          correlation?.provider ??
          _activeAuthProvider,
      'serviceCountry': serviceCountry,
      if (data is Map && data['expectedServiceCountry'] is String)
        'expectedServiceCountry': data['expectedServiceCountry'] as String,
      if (data is Map && data['actualServiceCountry'] is String)
        'actualServiceCountry': data['actualServiceCountry'] as String,
      if (data is Map && data['domainType'] is String)
        'domainType': data['domainType'] as String,
      'event': event,
      if (resultCode != null) 'resultCode': resultCode,
      if (data is Map && data['failureStage'] is String)
        'failureStage': data['failureStage'] as String,
      if (data is Map && data['failureCode'] is String)
        'failureCode': data['failureCode'] as String,
      if (data is Map && data['httpStatus'] is int)
        'httpStatus': data['httpStatus'] as int,
      if (data is Map && data['nativeSdkErrorCode'] is String)
        'nativeSdkErrorCode': data['nativeSdkErrorCode'] as String,
      if (data is Map && data['success'] is bool)
        'success': data['success'] as bool,
      if (data is Map && data['uiAuthCommitted'] is bool)
        'uiAuthCommitted': data['uiAuthCommitted'] as bool,
      if (data is Map && data['journey'] is String)
        'journey': data['journey'] as String,
      if (data is Map && data['semanticReason'] is String)
        'semanticReason': data['semanticReason'] as String,
      if (data is Map && data['nativeSdkCause'] is String)
        'nativeSdkCause': data['nativeSdkCause'] as String,
      if (data is Map && data['providerElapsedMs'] is int)
        'providerElapsedMs': data['providerElapsedMs'] as int,
      if (data is Map && data['convergenceElapsedMs'] is int)
        'convergenceElapsedMs': data['convergenceElapsedMs'] as int,
      if (data is Map && data['totalElapsedMs'] is int)
        'totalElapsedMs': data['totalElapsedMs'] as int,
    });
  }

  Map<String, Object?> _failureData(
    dynamic data, {
    required String failureStage,
    required String failureCode,
    int? httpStatus,
  }) => <String, Object?>{
    if (data is Map)
      for (final entry in data.entries)
        if (entry.key is String) entry.key as String: entry.value,
    'failureStage': failureStage,
    'failureCode': failureCode,
    if (httpStatus != null) 'httpStatus': httpStatus,
  };

  String _failureStageOf(Object error, String fallback) {
    if (error is SsoExchangeException) return error.failureStage;
    if (error is StateError &&
        error.message == 'REFRESH_TOKEN_PERSIST_FAILED') {
      return 'refresh_persist';
    }
    return fallback;
  }

  String _failureCodeOf(Object error, String fallback) {
    if (error is SsoExchangeException) return error.failureCode;
    if (error is StateError &&
        error.message == 'REFRESH_TOKEN_PERSIST_FAILED') {
      return 'REFRESH_TOKEN_PERSIST_FAILED';
    }
    if (error is SocketException || error is TimeoutException) {
      return 'NETWORK_ERROR';
    }
    return fallback;
  }

  String _terminalKeyOf(dynamic data) => authTerminalKey(
    authSessionId: _effectiveAuthSessionIdOf(data),
    authRevision: _authRevisionOf(data) ?? _activeAuthRevision,
  );

  AuthTerminalWorkSnapshot _captureAuthTerminalWork(dynamic data) {
    final attemptId = _effectiveAuthSessionIdOf(data);
    return AuthTerminalWorkSnapshot(
      epoch: _authEpoch,
      attemptId: attemptId,
      revision: _authRevisionOf(data) ?? _activeAuthRevision,
      leaseGeneration: _processAuthCoordinator.activeGenerationForAttempt(
        attemptId,
      ),
    );
  }

  bool _isCurrentAuthTerminalWork(AuthTerminalWorkSnapshot snapshot) {
    return !_isDisposed &&
        _processAuthCoordinator.isCurrentTerminalWork(
          snapshot,
          epoch: _authEpoch,
          revision: _activeAuthRevision,
        );
  }

  bool _rememberTerminalKey(String key) {
    if (!_terminalAuthSessionIds.add(key)) return false;
    if (_terminalAuthSessionIds.length > 200) {
      _terminalAuthSessionIds.remove(_terminalAuthSessionIds.first);
    }
    return true;
  }

  void _settleAuthTerminalTracking() {
    _authAttemptPhase.settle();
    _authConvergenceDeadline.settle();
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

  Future<bool> _hasVisibleWebAuthUiMarker(dynamic data) async {
    if (_activeProtocolVersion < currentAuthProtocolVersion ||
        !_canRunLifecycleSensitiveWebViewWork) {
      return false;
    }
    final attemptId = _effectiveAuthSessionIdOf(data);
    final revision = _authRevisionOf(data) ?? _activeAuthRevision;
    if (attemptId == null) return false;
    final markerKey =
        'sazo_webview_auth_ui_commit_v2:${Uri.encodeComponent(attemptId)}:$revision';
    try {
      final result = await webViewController
          .runJavaScriptReturningResult('''
            (function() {
              try {
                if (document.visibilityState !== 'visible') return false;
                var path = window.location.pathname || '/';
                var normalizedPath = path.length > 1 && path.endsWith('/')
                  ? path.slice(0, -1)
                  : path;
                var isHome = ['/', '/ko', '/en', '/ja'].includes(normalizedPath);
                if (!isHome) return false;
                var raw = window.localStorage.getItem(${jsonEncode(markerKey)});
                if (!raw) return false;
                var marker = JSON.parse(raw);
                return marker.authSessionId === ${jsonEncode(attemptId)} &&
                  marker.authRevision === $revision &&
                  typeof marker.updatedAt === 'number' &&
                  Date.now() - marker.updatedAt >= 0 &&
                  Date.now() - marker.updatedAt <= 300000;
              } catch (_) {
                return false;
              }
            })();
          ''')
          .timeout(const Duration(seconds: 3));
      return result == true || result == 1 || result == 'true';
    } catch (_) {
      return false;
    }
  }

  void _emitAuthTerminal(String resultCode, {dynamic data}) {
    final attemptId = _effectiveAuthSessionIdOf(data);
    final predecessorAttemptId = _processAuthCoordinator
        .activePredecessorForAttempt(attemptId);
    final convergenceElapsedMs = _authConvergenceDeadline.isActive
        ? _authConvergenceDeadline.elapsed.inMilliseconds
        : null;
    final terminalData = <String, Object?>{
      if (data is Map)
        for (final entry in data.entries)
          if (entry.key is String) entry.key as String: entry.value,
      if (predecessorAttemptId != null)
        'predecessorAttemptId': predecessorAttemptId,
      if (!(data is Map && data['journey'] is String) &&
          _activeAuthJourney != null)
        'journey': _activeAuthJourney,
      if (_activeProviderElapsedMs != null)
        'providerElapsedMs': _activeProviderElapsedMs,
      if (convergenceElapsedMs != null)
        'convergenceElapsedMs': convergenceElapsedMs,
      if (_authTotalElapsed.isRunning ||
          _authTotalElapsed.elapsed > Duration.zero)
        'totalElapsedMs': _authTotalElapsed.elapsedMilliseconds,
    };
    _authTotalElapsed.stop();
    final key = _terminalKeyOf(terminalData);
    final revision = _authRevisionOf(terminalData) ?? _activeAuthRevision;
    _authTraceCorrelations.markTerminal(
      _requestIdOf(terminalData) ?? _activeRequestId,
    );
    if (attemptId != null) {
      unawaited(
        const PendingAuthAttemptStore().clearIfMatches(
          attemptId: attemptId,
          authRevision: revision,
          serviceCountry: serviceCountry,
        ),
      );
    }
    final isFirstProcessTerminal = _processAuthCoordinator.settleTerminal(
      attemptId: attemptId,
      revision: revision,
    );
    if (!isFirstProcessTerminal || !_rememberTerminalKey(key)) {
      _emitAuthTrace(
        'auth.terminal.duplicate_ignored',
        resultCode: resultCode,
        data: terminalData,
      );
      _settleAuthTerminalTracking();
      _completeProcessAuthLease();
      return;
    }
    _settleAuthTerminalTracking();
    _emitAuthTrace('auth.terminal', resultCode: resultCode, data: terminalData);
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

  void _markProviderCompleted(dynamic data) {
    if (_activeProviderElapsedMs != null) return;
    _activeProviderElapsedMs = _authTotalElapsed.elapsedMilliseconds;
    _emitAuthTrace('auth.provider.completed', data: data);
  }

  void _startAttemptTerminalDeadline() {
    if (_activeProtocolVersion >= currentAuthProtocolVersion) {
      _authConvergenceDeadline.start(isForeground: _isAppResumed);
    } else {
      // A rolled-back/old web does not understand the v3 soft deadline. Keep
      // its established v2 15-second terminal behavior byte-for-byte.
      _authConvergenceDeadline.settle();
    }
    _armAttemptTerminalTimer();
  }

  void _ensureAttemptTerminalDeadline() {
    if (_activeProtocolVersion >= currentAuthProtocolVersion &&
        !_authConvergenceDeadline.isActive) {
      _authConvergenceDeadline.start(isForeground: _isAppResumed);
    }
    _armAttemptTerminalTimer();
  }

  void _armAttemptTerminalTimer() {
    if (!_authAttemptPhase.shouldRunTerminalDeadline ||
        !_isAppResumed ||
        _isDisposed) {
      return;
    }
    _attemptTerminalTimer?.cancel();
    if (_activeProtocolVersion < currentAuthProtocolVersion) {
      final timeoutData = _activeAuthProtocolData();
      final snapshot = _captureAuthTerminalWork(timeoutData);
      late final Timer timer;
      timer = Timer(const Duration(seconds: 15), () {
        if (identical(_attemptTerminalTimer, timer)) {
          _attemptTerminalTimer = null;
        }
        unawaited(_onLegacyAttemptTerminalTimeout(snapshot, timeoutData));
      });
      _attemptTerminalTimer = timer;
      return;
    }
    final remaining = _authConvergenceDeadline.nextTransitionIn;
    if (remaining == null) return;
    final timeoutData = _activeAuthProtocolData();
    final snapshot = _captureAuthTerminalWork(timeoutData);
    late final Timer timer;
    timer = Timer(remaining, () {
      // 취소 직전 이미 event queue에 들어온 옛 callback이 새 timer reference를
      // 지우지 못하게 자신이 아직 owner일 때만 해제한다.
      if (identical(_attemptTerminalTimer, timer)) {
        _attemptTerminalTimer = null;
      }
      unawaited(_onAttemptTerminalDeadline(snapshot, timeoutData));
    });
    _attemptTerminalTimer = timer;
  }

  Future<void> _onLegacyAttemptTerminalTimeout(
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
    if (await _hasCompletedAuthTerminal(timeoutData)) {
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
    if (!_isCurrentAuthTerminalWork(snapshot) ||
        !_authAttemptPhase.shouldRunTerminalDeadline) {
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

  Future<void> _onAttemptTerminalDeadline(
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
    final deadlineEvent = _authConvergenceDeadline.consumeDue();
    if (deadlineEvent == null) {
      _armAttemptTerminalTimer();
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
    if (deadlineEvent == AuthConvergenceDeadlineEvent.softDeadline) {
      _emitAuthTrace(
        'auth.convergence.slow',
        resultCode: 'soft_deadline',
        data: timeoutData,
      );
      await _runConvergenceSoftRecovery();
      if (_isCurrentAuthTerminalWork(snapshot) &&
          _authAttemptPhase.shouldRunTerminalDeadline) {
        _armAttemptTerminalTimer();
      }
      return;
    }
    // The web writes this marker only after visible home auth/profile/dock
    // convergence and immediately before posting AUTH_UI_COMMITTED. If that
    // callback lost the JS/native race, recover the already-proven UI success
    // instead of destructively logging the user out at the hard boundary.
    if (await _hasVisibleWebAuthUiMarker(timeoutData)) {
      if (!_isCurrentAuthTerminalWork(snapshot) ||
          !_authAttemptPhase.shouldRunTerminalDeadline) {
        _emitAuthTrace(
          'auth.terminal.timeout_stale_ignored',
          resultCode: 'attempt_changed_during_ui_marker_check',
          data: timeoutData,
        );
        return;
      }
      try {
        await const AuthTerminalStore().markSuccess(
          authSessionId: snapshot.attemptId,
          authRevision: snapshot.revision,
          serviceCountry: serviceCountry,
        );
      } catch (_) {
        // The visible web marker remains sufficient evidence in this process.
      }
      _emitAuthTerminal(
        'ui_authenticated',
        data: <String, Object?>{
          if (timeoutData is Map)
            for (final entry in timeoutData.entries)
              if (entry.key is String) entry.key as String: entry.value,
          'success': true,
          'uiAuthCommitted': true,
        },
      );
      return;
    }
    if (!_isCurrentAuthTerminalWork(snapshot) ||
        !_authAttemptPhase.shouldRunTerminalDeadline ||
        _processAuthCoordinator.isTerminalSettled(
          attemptId: snapshot.attemptId,
          revision: snapshot.revision,
        )) {
      _emitAuthTrace(
        'auth.terminal.timeout_stale_ignored',
        resultCode: 'attempt_changed_during_final_ui_check',
        data: timeoutData,
      );
      return;
    }
    _emitAuthTrace(
      'auth.convergence.hard_deadline',
      resultCode: 'hard_deadline',
      data: _failureData(
        timeoutData,
        failureStage: 'terminal_deadline',
        failureCode: 'AUTH_TERMINAL_TIMEOUT',
      ),
    );
    _terminateAuthAttemptWithError(
      resultCode: 'code_failure:auth_terminal_timeout',
      code: 'AUTH_TERMINAL_TIMEOUT',
    );
  }

  Map<String, Object?> _activeAuthProtocolData() => <String, Object?>{
    'protocolVersion': _activeProtocolVersion,
    if (_activeProtocolVersion >= 3 && _activeAuthCapabilities.isNotEmpty)
      'authCapabilities': _activeAuthCapabilities.toList(growable: false),
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
    final timeoutData = _failureData(
      _activeAuthProtocolData(),
      failureStage: 'terminal_deadline',
      failureCode: code,
    );
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

  void _emitMeFetchResult(Map<String, dynamic>? me, dynamic data) {
    if (me != null) {
      _emitAuthTrace('auth.me.fetched', resultCode: 'success', data: data);
      return;
    }
    _emitAuthTrace(
      'auth.me.fetch_fallback',
      resultCode: 'fallback',
      data: _failureData(
        data,
        failureStage: 'me_fetch',
        failureCode: 'ME_FETCH_FALLBACK',
      ),
    );
  }

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
    _pendingConvergenceSoftRecovery = false;
    _pendingSsoRecovery = false;
    _authRecoveryGate.reset();
    _authAttemptAckDeliveryGeneration += 1;
    _lastKakaoSendData = null;
    _resendKakaoAfterReload = false;
    _clearSessionReplay(reason);
  }

  Future<_ProcessAutoAuthWork?> _beginAutoAuthAttemptIfNeeded(
    dynamic requestData,
    Map<String, Object?> readResponse,
  ) async {
    if (authProtocolVersionOf(requestData) < 2) return null;

    final fallbackNonce = DateTime.now().microsecondsSinceEpoch;
    final convergenceKey = '${serviceCountry ?? "KR"}:$_activeAuthRevision';
    final hasConvergenceHandoff = _processAuthCoordinator.hasConvergenceHandoff(
      convergenceKey: convergenceKey,
    );
    final isInitialBootstrap = _processAuthCoordinator
        .claimAutomaticBootstrap();
    // process bootstrap을 이미 관측했더라도 document dispose handoff의 후속 read는
    // 별도 tracked AUTO attempt로 승격해야 원 시도의 UI 수렴을 증명할 수 있다.
    final trackedAttemptId = isInitialBootstrap || hasConvergenceHandoff
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
      convergenceKey: tracksTerminal ? convergenceKey : null,
    );
    if (claimed == null) {
      if (tracksTerminal) _autoAuthAttempt.clearActiveAttempt();
      return null;
    }
    lease = claimed;
    _processAuthLease = lease;

    if (tracksTerminal) {
      _authRecoveryGate.reset();
      _activeAuthSessionId = attemptId;
      _activeAuthProvider = autoAuthProvider;
      _activeAuthJourney = 'auto_refresh';
      _activeReauthSemanticReason = null;
      _activeRequestId = _requestIdOf(requestData);
      _activeDocumentId = _stringFieldOf(requestData, 'documentId');
      _activeProtocolVersion = negotiateAuthProtocolVersion(requestData);
      _activeAuthCapabilities = negotiateAuthProtocolCapabilities(requestData);
      _authTotalElapsed
        ..reset()
        ..start();
      _activeProviderElapsedMs = null;
      _rememberActiveAuthCorrelation(attemptId: attemptId);
      _activeAuthAbortCompleter = null;
      // refresh 교환 중에는 network/provider 응답을 기다리므로 짧은 UI deadline을
      // 적용하지 않는다. AUTH_TOKENS_READY 송신 직전에 terminal convergence로 전환한다.
      _authAttemptPhase.beginProviderInteraction(tracksTerminal: true);
      _authConvergenceDeadline.settle();
      try {
        await const PendingAuthAttemptStore().markStarted(
          attempt: PendingAuthAttempt(
            attemptId: attemptId,
            authRevision: _activeAuthRevision,
            provider: autoAuthProvider,
            protocolVersion: _activeProtocolVersion,
            startedAt: DateTime.now().toUtc(),
            processInstanceId: authProcessInstanceId,
            requestId: _activeRequestId,
            documentId: _activeDocumentId,
          ),
          serviceCountry: serviceCountry,
        );
      } catch (_) {
        _emitAuthTrace(
          'auth.attempt.persistence_failed',
          resultCode: 'pending_attempt_write_failed',
          data: _failureData(
            requestData,
            failureStage: 'attempt_persistence',
            failureCode: 'PENDING_ATTEMPT_PERSIST_FAILED',
          ),
        );
      }
      _emitAuthTrace('auth.attempt.started', data: requestData);
    }
    return _ProcessAutoAuthWork(lease: lease, tracksTerminal: tracksTerminal);
  }

  Future<void> _recoverInterruptedAuthAttemptIfNeeded() async {
    final country = serviceCountry ?? 'KR';
    if (_interruptedAttemptRecoveryChecked.contains(country)) return;

    PendingAuthAttempt? interrupted;
    try {
      interrupted = await const PendingAuthAttemptStore().takeInterrupted(
        currentProcessInstanceId: authProcessInstanceId,
        serviceCountry: serviceCountry,
      );
      _interruptedAttemptRecoveryChecked.add(country);
    } catch (_) {
      _emitAuthTrace(
        'auth.interrupted.recovery_failed',
        resultCode: 'pending_attempt_read_failed',
        data: _failureData(
          const <String, Object?>{},
          failureStage: 'attempt_recovery',
          failureCode: 'PENDING_ATTEMPT_READ_FAILED',
        ),
      );
      return;
    }
    if (interrupted == null) return;

    try {
      final alreadySucceeded = await const AuthTerminalStore().matchesSuccess(
        authSessionId: interrupted.attemptId,
        authRevision: interrupted.authRevision,
        serviceCountry: serviceCountry,
      );
      if (alreadySucceeded) return;
    } catch (_) {
      // 성공 marker 조회 실패만으로 회수를 누락하면 missing terminal이 다시 생긴다.
      // pending attempt 자체가 이전 process 소유라는 영속 증거를 우선한다.
    }

    // 이전 process는 계정 선택/동의 화면에서 강제 종료되어 callback을 실행할 수 없었다.
    // 다음 process의 첫 v2 refresh read가 사용자 중단 terminal을 한 번만 보충한다.
    _emitAuthTrace(
      'auth.terminal',
      resultCode: 'process_interrupted',
      data: <String, Object?>{
        'protocolVersion': interrupted.protocolVersion,
        'authSessionId': interrupted.attemptId,
        'authRevision': interrupted.authRevision,
        'provider': interrupted.provider,
        if (interrupted.requestId != null) 'requestId': interrupted.requestId,
        if (interrupted.documentId != null)
          'documentId': interrupted.documentId,
      },
    );
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
    late final ProcessAuthAttemptLease processLease;
    late final int transactionEpoch;
    final provider = _providerOfRequest(data) ?? _providerNameOf(type);
    final claimedLease = _processAuthCoordinator.tryBeginInteractive(
      attemptId:
          _authSessionIdOf(data) ??
          'interactive-${type.value}-${DateTime.now().microsecondsSinceEpoch}',
      onSuperseded: () => _handleProcessAuthAttemptSuperseded(processLease),
      onSettled: () => _handleProcessAuthAttemptSettled(processLease),
      deduplicationKey: '${serviceCountry ?? "KR"}:$provider',
      forceSupersedeDuplicate: data is Map && data['retryAfterTimeout'] == true,
      onActivated: () {
        _authEpoch += 1;
        transactionEpoch = _authEpoch;
      },
    );
    if (claimedLease == null) {
      final duplicateAttemptId = _authSessionIdOf(data);
      final duplicateRequestId = _requestIdOf(data);
      final isSameActiveRequest =
          _ownsActiveInteractiveLease &&
          duplicateAttemptId != null &&
          duplicateAttemptId == _activeAuthSessionId &&
          duplicateRequestId != null &&
          duplicateRequestId == _activeRequestId;
      if (isSameActiveRequest &&
          _activeAuthCapabilities.contains(criticalAuthDeliveryAckCapability)) {
        _emitAuthTrace(
          'auth.attempt.duplicate_ack_replayed',
          resultCode: 'same_request_in_flight',
          data: data,
        );
        await _sendAuthAttemptStartedAck();
      }
      _emitAuthTrace(
        'auth.attempt.duplicate_ignored',
        resultCode: 'duplicate_in_flight',
        data: data,
      );
      throw const _AuthOperationAborted();
    }
    processLease = claimedLease;
    _processAuthLease = processLease;
    _autoAuthAttempt.clearActiveAttempt();
    _clearSsoTransientState('ssoStart:${type.value}');
    _activeAuthSessionId = processLease.attemptId;
    _activeAuthProvider = provider;
    _activeAuthJourney = 'existing_user_login';
    _activeReauthSemanticReason = null;
    _activeRequestId = _requestIdOf(data);
    _activeDocumentId = _stringFieldOf(data, 'documentId');
    _activeProtocolVersion = negotiateAuthProtocolVersion(data);
    _activeAuthCapabilities = negotiateAuthProtocolCapabilities(data);
    _authTotalElapsed
      ..reset()
      ..start();
    _activeProviderElapsedMs = null;
    final nextRevision = await const AuthRevisionStore().nextIfCurrent(
      serviceCountry: serviceCountry,
      isCurrent: () =>
          !_isDisposed &&
          transactionEpoch == _authEpoch &&
          identical(_processAuthLease, processLease) &&
          _processAuthCoordinator.isActive(processLease),
    );
    // revision 저장을 기다리는 동안 다른 bridge의 interactive 시도가 이 lease를
    // 선점할 수 있다. 옛 초기화가 복귀해 새 시도의 phase/revision을 덮지 못하게 한다.
    if (_isDisposed ||
        transactionEpoch != _authEpoch ||
        !identical(_processAuthLease, processLease) ||
        nextRevision == null ||
        !_processAuthCoordinator.isActive(processLease)) {
      throw const _AuthOperationAborted();
    }
    _activeAuthRevision = nextRevision;
    _rememberActiveAuthCorrelation(attemptId: processLease.attemptId);
    _activeAuthAbortCompleter = _activeProtocolVersion >= 2
        ? Completer<void>()
        : null;
    _authAttemptPhase.beginProviderInteraction(
      tracksTerminal: _activeProtocolVersion >= 2,
    );
    _authConvergenceDeadline.settle();
    if (_activeProtocolVersion >= 2) {
      try {
        await const PendingAuthAttemptStore().markStarted(
          attempt: PendingAuthAttempt(
            attemptId: processLease.attemptId,
            authRevision: _activeAuthRevision,
            provider: provider,
            protocolVersion: _activeProtocolVersion,
            startedAt: DateTime.now().toUtc(),
            processInstanceId: authProcessInstanceId,
            requestId: _activeRequestId,
            documentId: _activeDocumentId,
          ),
          serviceCountry: serviceCountry,
        );
      } catch (_) {
        _emitAuthTrace(
          'auth.attempt.persistence_failed',
          resultCode: 'pending_attempt_write_failed',
          data: _failureData(
            data,
            failureStage: 'attempt_persistence',
            failureCode: 'PENDING_ATTEMPT_PERSIST_FAILED',
          ),
        );
      }
    }
    _emitAuthTrace('auth.attempt.started', data: data);
    await _sendAuthAttemptStartedAck();
    // ignore: avoid_print
    print(
      '[SsoExchange] auth transaction begin '
      'epoch=$_authEpoch provider=${_activeAuthProvider ?? "null"} '
      'authSessionId=${_activeAuthSessionId ?? "null"} '
      'authRevision=$_activeAuthRevision protocol=$_activeProtocolVersion',
    );
    return transactionEpoch;
  }

  String _authAttemptStartedAckPayload() => jsonEncode({
    'type': WebViewBridgeFeatureType.authAttemptStarted.value,
    'data': {
      ..._activeAuthProtocolData(),
      if (_activeAuthProvider != null) 'provider': _activeAuthProvider,
    },
  });

  Future<void> _sendAuthAttemptStartedAck() async {
    final payload = _authAttemptStartedAckPayload();
    if (!_activeAuthCapabilities.contains(criticalAuthDeliveryAckCapability)) {
      await runJavaScriptPostMessage(payload);
      return;
    }

    final deliveryGeneration = ++_authAttemptAckDeliveryGeneration;
    final authEpoch = _authEpoch;
    final attemptId = _activeAuthSessionId;
    final requestId = _activeRequestId;
    final revision = _activeAuthRevision;
    final delivered = await _runJavaScriptPostMessageWithReceipt(payload);
    if (delivered) return;

    unawaited(
      _retryAuthAttemptStartedAck(
        payload: payload,
        deliveryGeneration: deliveryGeneration,
        authEpoch: authEpoch,
        attemptId: attemptId,
        requestId: requestId,
        revision: revision,
      ),
    );
  }

  Future<void> _retryAuthAttemptStartedAck({
    required String payload,
    required int deliveryGeneration,
    required int authEpoch,
    required String? attemptId,
    required String? requestId,
    required int revision,
  }) async {
    const retryDelays = <Duration>[
      Duration(milliseconds: 250),
      Duration(milliseconds: 500),
      Duration(seconds: 1),
      Duration(seconds: 2),
    ];
    for (final delay in retryDelays) {
      await Future<void>.delayed(delay);
      if (deliveryGeneration != _authAttemptAckDeliveryGeneration ||
          authEpoch != _authEpoch ||
          attemptId == null ||
          attemptId != _activeAuthSessionId ||
          requestId == null ||
          requestId != _activeRequestId ||
          revision != _activeAuthRevision ||
          !_ownsActiveInteractiveLease) {
        _emitAuthTrace(
          'auth.attempt.ack_retry_cancelled',
          resultCode: 'stale_lineage',
          data: _activeAuthProtocolData(),
        );
        return;
      }
      if (!_isAppResumed) continue;
      if (await _sendPostMessageNow(payload)) {
        _emitAuthTrace(
          'auth.attempt.ack_recovered',
          resultCode: 'handler_ready',
          data: _activeAuthProtocolData(),
        );
        return;
      }
    }
    if (deliveryGeneration == _authAttemptAckDeliveryGeneration &&
        authEpoch == _authEpoch &&
        attemptId == _activeAuthSessionId &&
        requestId == _activeRequestId &&
        revision == _activeAuthRevision &&
        _ownsActiveInteractiveLease) {
      _emitAuthTrace(
        'auth.attempt.ack_retry_exhausted',
        resultCode: 'handler_unavailable',
        data: _failureData(
          _activeAuthProtocolData(),
          failureStage: 'web_delivery',
          failureCode: 'BRIDGE_HANDLER_UNAVAILABLE',
        ),
      );
    }
  }

  void _invalidateAuthTransaction(String reason) {
    _authEpoch += 1;
    // background 중 old document로 보내려다 보류된 응답도 같은 auth boundary에
    // 속한다. 국가 전환/명시적 로그아웃 뒤 resume에서 재전달되지 않게 함께 폐기한다.
    _pendingPostMessages.clear();
    _completeProcessAuthLease();
    _activeAuthSessionId = null;
    _activeAuthProvider = null;
    _activeAuthJourney = null;
    _activeReauthSemanticReason = null;
    _activeAuthCapabilities = const <String>{};
    _authAttemptAckDeliveryGeneration += 1;
    _autoAuthAttempt.clearActiveAttempt();
    _authAttemptPhase.settle();
    _authConvergenceDeadline.settle();
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

  bool _isInvalidatedAuthDocumentMessage(dynamic data) =>
      _authDocumentBoundary.rejects(_stringFieldOf(data, 'documentId'));

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

  void _discardStaleAuthWorkContext(String reason, dynamic data) {
    _logStaleAuthMessage(reason, data);
    _emitAuthTrace(
      'auth.context.stale_discarded',
      resultCode: reason,
      data: data,
    );
  }

  void _armSsoWatchdog({bool isB2 = false}) {
    if (isB2 && _authRecoveryGate.homeTokenBindConfirmed) {
      return;
    }
    if (_authRecoveryGate.reloadCount >= 1) {
      _emitRecoveryExhaustedOnce();
      return;
    }
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

  void _emitRecoveryExhaustedOnce() {
    if (!_authRecoveryGate.takeExhaustionSignal()) return;
    _emitAuthTrace(
      'auth.convergence.recovery_exhausted',
      resultCode: 'reload_limit_reached',
      data: _activeAuthProtocolData(),
    );
  }

  Future<void> _runSsoWatchdogRecovery() async {
    if (!_canRunLifecycleSensitiveWebViewWork) {
      _pendingSsoRecovery = !_isDisposed && context.mounted;
      return;
    }

    final isB2 = _ssoWatchdogB2;
    if (isB2 && _authRecoveryGate.homeTokenBindConfirmed) {
      _emitAuthTrace(
        'auth.convergence.recovery_skipped',
        resultCode: 'awaiting_ui_commit',
        data: _activeAuthProtocolData(),
      );
      return;
    }
    if (!_authRecoveryGate.tryConsumeRecovery(requiresUnconfirmedHome: isB2)) {
      _emitRecoveryExhaustedOnce();
      return;
    }
    // B1(web 교환): reload 후 fresh page 에 카카오 raw payload 재전송 (web 교환 재개).
    // B2(네이티브 교환): reload 후 fresh page 가 REFRESH_TOKEN_READ → 세션 replay 로 로그인 복원
    //   (raw 재전송 불필요 — replay 가 throttle/race 없이 동일 payload 전달). jettison 으로 새 문서가
    //   AUTH_TOKENS_READY 를 못 받아 confirm(REFRESH_TOKEN_WRITE) 미수신인 케이스를 결정론적 복구.
    if (!_ssoWatchdogB2) {
      _resendKakaoAfterReload = true;
    }
    // ignore: avoid_print
    print(
      '[Watchdog] reload ${_authRecoveryGate.reloadCount} — SSO confirm 미수신 '
      '(${isB2 ? "B2 replay" : "B1 resend"})',
    );
    try {
      if (isB2) {
        await _loadHomeForSsoRecovery();
      } else {
        await webViewController.reload();
      }
    } catch (e) {
      // ignore: avoid_print
      print('[Watchdog] reload FAIL: ${e.runtimeType}');
    }
  }

  Future<void> _runConvergenceSoftRecovery() async {
    if (!_canRunLifecycleSensitiveWebViewWork) {
      _pendingConvergenceSoftRecovery = !_isDisposed && context.mounted;
      return;
    }
    if (_authRecoveryGate.homeTokenBindConfirmed) {
      _emitAuthTrace(
        'auth.convergence.recovery_skipped',
        resultCode: 'awaiting_ui_commit',
        data: _activeAuthProtocolData(),
      );
      return;
    }
    if (!_authRecoveryGate.tryConsumeRecovery(requiresUnconfirmedHome: true)) {
      _emitRecoveryExhaustedOnce();
      return;
    }
    _emitAuthTrace(
      'auth.convergence.recovery_started',
      resultCode: 'home_reload',
      data: _activeAuthProtocolData(),
    );
    await _loadHomeForSsoRecovery();
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
    // JavaScriptChannel callbacks can wait behind a long-running provider
    // operation. Capture the navigation at receipt time so an old document's
    // queued control message is never relabelled as the current document.
    final receivedNavigationGeneration = _webDocumentNavigationGeneration;
    final receivedServiceContextGeneration = _serviceAuthContext.generation;
    final receivedTransitionConfirmation = _serviceContextTransitionInProgress
        ? _serviceContextTransitionNavigationConfirmation
        : null;
    final completion = _BridgeMessageCompletion();
    await _enqueueBridgeMessage(
      message,
      receivedNavigationGeneration: receivedNavigationGeneration,
      receivedServiceContextGeneration: receivedServiceContextGeneration,
      receivedTransitionConfirmation: receivedTransitionConfirmation,
      completion: completion,
    );
    await completion.completer.future;
  }

  Future<void> _enqueueBridgeMessage(
    JavaScriptMessage message, {
    required int receivedNavigationGeneration,
    required int receivedServiceContextGeneration,
    required Completer<int?>? receivedTransitionConfirmation,
    required _BridgeMessageCompletion completion,
  }) {
    completion.deferred = false;
    final operation = _messageSerial.then(
      (_) => _handleMessageReceived(
        message,
        receivedNavigationGeneration: receivedNavigationGeneration,
        receivedServiceContextGeneration: receivedServiceContextGeneration,
        receivedTransitionConfirmation: receivedTransitionConfirmation,
        completion: completion,
      ),
    );
    operation.then(
      (_) {
        if (!completion.deferred && !completion.completer.isCompleted) {
          completion.completer.complete();
        }
      },
      onError: (Object error, StackTrace stackTrace) {
        if (!completion.completer.isCompleted) {
          completion.completer.completeError(error, stackTrace);
        }
      },
    );
    _messageSerial = operation.catchError((_) {});
    return operation;
  }

  void _bufferTransitionMessage({
    required JavaScriptMessage message,
    required int receivedNavigationGeneration,
    required int receivedServiceContextGeneration,
    required Completer<int?> transitionConfirmation,
    required _BridgeMessageCompletion completion,
  }) {
    completion.deferred = true;
    if (_bufferedTransitionMessages.length >= _maxBufferedTransitionMessages) {
      final evicted = _bufferedTransitionMessages.removeFirst();
      if (!evicted.completion.completer.isCompleted) {
        evicted.completion.completer.complete();
      }
      _emitAuthTrace(
        'auth.context.transition_buffer_overflow_discarded',
        resultCode: 'oldest',
      );
    }
    _bufferedTransitionMessages.add(
      _BufferedTransitionMessage(
        message: message,
        receivedNavigationGeneration: receivedNavigationGeneration,
        receivedServiceContextGeneration: receivedServiceContextGeneration,
        transitionConfirmation: transitionConfirmation,
        completion: completion,
      ),
    );
  }

  void _resolveTransitionConfirmation(
    Completer<int?> confirmation,
    int? navigationGeneration,
  ) {
    if (!confirmation.isCompleted) {
      confirmation.complete(navigationGeneration);
    }
    final replay = _bufferedTransitionMessages
        .where(
          (buffered) =>
              identical(buffered.transitionConfirmation, confirmation),
        )
        .toList(growable: false);
    _bufferedTransitionMessages.removeWhere(
      (buffered) => identical(buffered.transitionConfirmation, confirmation),
    );
    for (final buffered in replay) {
      unawaited(
        _enqueueBridgeMessage(
          buffered.message,
          receivedNavigationGeneration: buffered.receivedNavigationGeneration,
          receivedServiceContextGeneration:
              buffered.receivedServiceContextGeneration,
          receivedTransitionConfirmation: confirmation,
          completion: buffered.completion,
        ),
      );
    }
  }

  bool _isAuthMutation(WebViewBridgeFeatureType type) => const {
    WebViewBridgeFeatureType.googleSignInLogin,
    WebViewBridgeFeatureType.googleSignInLogout,
    WebViewBridgeFeatureType.appleSignInLogin,
    WebViewBridgeFeatureType.appleSignInLogout,
    WebViewBridgeFeatureType.kakaoSignInLogin,
    WebViewBridgeFeatureType.kakaoSignInLogout,
    WebViewBridgeFeatureType.refreshTokenRead,
    WebViewBridgeFeatureType.refreshTokenWrite,
    WebViewBridgeFeatureType.refreshTokenDelete,
    WebViewBridgeFeatureType.authContextStatus,
    WebViewBridgeFeatureType.authContextMismatchClearAndRestart,
  }.contains(type);

  Map<String, Object?> _authContextAck(
    Map<String, Object?> data, {
    required String status,
  }) => {
    'type': WebViewBridgeFeatureType.authContextStatusAck.value,
    'data': {
      'status': status,
      if (data['idempotencyKey'] is String)
        'idempotencyKey': data['idempotencyKey'],
      if (data['documentId'] is String) 'documentId': data['documentId'],
      if (data['requestId'] is String) 'requestId': data['requestId'],
      if (data['authRevision'] is int) 'authRevision': data['authRevision'],
      'serviceCountry': _serviceAuthContext.serviceCountry,
      'domainType': _serviceAuthContext.domainType,
    },
  };

  Future<void> _handleMessageReceived(
    JavaScriptMessage message, {
    required int receivedNavigationGeneration,
    required int receivedServiceContextGeneration,
    required Completer<int?>? receivedTransitionConfirmation,
    required _BridgeMessageCompletion completion,
  }) async {
    final json = jsonDecode(message.message);
    final type = json['type'] as String?;
    final data = json['data'];
    if (type != null) {
      final webViewBridgeFeatureType = type.webViewBridgeFeatureType;
      if (webViewBridgeFeatureType != null) {
        final isNavigationScopedControlMessage =
            webViewBridgeFeatureType == WebViewBridgeFeatureType.deviceInfo ||
            webViewBridgeFeatureType ==
                WebViewBridgeFeatureType.authContextStatus ||
            webViewBridgeFeatureType ==
                WebViewBridgeFeatureType.authContextMismatchClearAndRestart;
        if (isNavigationScopedControlMessage &&
            receivedNavigationGeneration != _webDocumentNavigationGeneration) {
          _emitAuthTrace(
            'auth.context.stale_navigation_message_discarded',
            resultCode: webViewBridgeFeatureType.value,
            data: {
              if (data is Map) ...Map<String, Object?>.from(data),
              'receivedNavigationGeneration': receivedNavigationGeneration,
              'currentNavigationGeneration': _webDocumentNavigationGeneration,
            },
          );
          return;
        }
        // Old web can send token payloads without document/revision metadata.
        // A service-context generation captured at receipt distinguishes a
        // dangerous country/boundary transition from an ordinary same-country
        // redirect, where queued legacy write/delete must remain valid.
        if (_isAuthMutation(webViewBridgeFeatureType) &&
            receivedServiceContextGeneration !=
                _serviceAuthContext.generation) {
          _emitAuthTrace(
            'auth.context.stale_service_context_message_discarded',
            resultCode: webViewBridgeFeatureType.value,
            data: {
              if (data is Map) ...Map<String, Object?>.from(data),
              'receivedServiceContextGeneration':
                  receivedServiceContextGeneration,
              'currentServiceContextGeneration': _serviceAuthContext.generation,
            },
          );
          return;
        }
        final explicitRetryAction = _isSsoLogin(webViewBridgeFeatureType)
            ? _authContextRecoveryCoordinator
                  .consumeTerminalFailureForExplicitRetry(
                    currentContextGeneration: _serviceAuthContext.generation,
                    transitionInProgress: _serviceContextTransitionInProgress,
                    retryDocumentId: _stringFieldOf(data, 'documentId'),
                  )
            : null;
        if (shouldRejectRetiredAuthMessage(
          isAuthMutation: _isAuthMutation(webViewBridgeFeatureType),
          isRetiredDocument: _isInvalidatedAuthDocumentMessage(data),
          hasOwnedExplicitRetry: explicitRetryAction != null,
        )) {
          _emitAuthTrace(
            'auth.context.retired_document_discarded',
            resultCode: webViewBridgeFeatureType.value,
            data: data,
          );
          return;
        }
        if (_isAuthMutation(webViewBridgeFeatureType) &&
            receivedTransitionConfirmation != null &&
            explicitRetryAction !=
                AuthContextExplicitRetryAction.reopenTransition) {
          if (!receivedTransitionConfirmation.isCompleted) {
            _bufferTransitionMessage(
              message: message,
              receivedNavigationGeneration: receivedNavigationGeneration,
              receivedServiceContextGeneration:
                  receivedServiceContextGeneration,
              transitionConfirmation: receivedTransitionConfirmation,
              completion: completion,
            );
            return;
          }
          final confirmedNavigationGeneration =
              await receivedTransitionConfirmation.future;
          if (_isDisposed) return;
          final isConfirmedTargetDocument =
              confirmedNavigationGeneration != null &&
              receivedNavigationGeneration == confirmedNavigationGeneration &&
              receivedServiceContextGeneration ==
                  _serviceAuthContext.generation;
          if (!isConfirmedTargetDocument) {
            _emitAuthTrace(
              'auth.context.transition_buffered_message_discarded',
              resultCode: webViewBridgeFeatureType.value,
              data: {
                if (data is Map) ...Map<String, Object?>.from(data),
                'receivedNavigationGeneration': receivedNavigationGeneration,
                'confirmedNavigationGeneration': confirmedNavigationGeneration,
                'receivedServiceContextGeneration':
                    receivedServiceContextGeneration,
                'currentServiceContextGeneration':
                    _serviceAuthContext.generation,
              },
            );
            return;
          }
          if (isNavigationScopedControlMessage &&
              receivedNavigationGeneration !=
                  _webDocumentNavigationGeneration) {
            _emitAuthTrace(
              'auth.context.stale_navigation_message_discarded',
              resultCode: webViewBridgeFeatureType.value,
              data: data,
            );
            return;
          }
        }
        if (_serviceContextTransitionInProgress &&
            _isAuthMutation(webViewBridgeFeatureType)) {
          if (explicitRetryAction !=
              AuthContextExplicitRetryAction.reopenTransition) {
            _emitAuthTrace(
              'auth.context.transition_message_discarded',
              resultCode: webViewBridgeFeatureType.value,
              data: data,
            );
            return;
          }
        } else if (explicitRetryAction ==
            AuthContextExplicitRetryAction.continueWithCurrentContext) {
          _emitAuthTrace(
            'auth.context.explicit_retry_terminal_failure_consumed',
            resultCode: webViewBridgeFeatureType.value,
            data: data,
          );
        }
        late Map<String, Object?> sendData;
        int? authEpoch;
        AuthWorkContextSnapshot? authDeliveryContext;
        _ProcessAutoAuthWork? processAutoAuthWork;
        Map<String, Object?>? pendingReauthReplay;

        try {
          if (explicitRetryAction ==
              AuthContextExplicitRetryAction.reopenTransition) {
            final retryGeneration = _serviceAuthContext.generation;
            final retryCleanup = await _authContextRecoveryCoordinator
                .retryCleanupForExplicitRetry(
                  contextGeneration: retryGeneration,
                  retryDocumentId: _stringFieldOf(data, 'documentId'),
                  isCurrentTransition: () =>
                      _serviceContextTransitionInProgress &&
                      _serviceAuthContext.generation == retryGeneration,
                  clearTokens: _clearAllRefreshTokens,
                  clearTransient: () =>
                      _clearSsoTransientState('auth-context-explicit-retry'),
                );
            if (retryCleanup ==
                AuthContextExplicitRetryCleanupResult.superseded) {
              _emitAuthTrace(
                'auth.context.explicit_retry_transition_superseded',
                resultCode: webViewBridgeFeatureType.value,
                data: data,
              );
              return;
            }
            if (retryCleanup == AuthContextExplicitRetryCleanupResult.failed) {
              final failureData = _failureData(
                data,
                failureStage: 'service_context_recovery',
                failureCode: 'AUTH_CONTEXT_RECOVERY_FAILED',
              );
              _emitAuthTrace(
                'auth.context.explicit_retry_cleanup_failed',
                resultCode: 'AUTH_CONTEXT_RECOVERY_FAILED',
                data: failureData,
              );
              _emitAuthTerminal(
                'code_failure:service_context_recovery',
                data: failureData,
              );
              final retryStatus = data is Map
                  ? Map<String, Object?>.from(data)
                  : <String, Object?>{};
              try {
                await onAuthContextStatus?.call({
                  ...retryStatus,
                  'status': 'recoveryFailed',
                  ...failureData,
                });
              } catch (_) {}
              try {
                await runJavaScriptPostMessage(
                  jsonEncode({
                    'type': WebViewBridgeFeatureType.authError.value,
                    'data': {
                      ...failureData,
                      'code': 'AUTH_CONTEXT_RECOVERY_FAILED',
                      'message': '',
                    },
                  }),
                );
              } catch (_) {}
              return;
            }
            updateServiceContext(
              serviceCountry: _serviceAuthContext.serviceCountry,
              apiBaseUrl: _serviceAuthContext.apiBaseUrl,
              webOrigin: _webOrigin,
              waitForNextNavigation: false,
            );
            _emitAuthTrace(
              'auth.context.explicit_retry_transition_reopened',
              resultCode: webViewBridgeFeatureType.value,
              data: data,
            );
          }
          if (!context.mounted) return;
          if (_isSsoLogin(webViewBridgeFeatureType)) {
            _authContextRecoveryCoordinator.beginExplicitAuthAttempt();
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
              onWebAuthContextCapability?.call(
                supported: supportsWebAuthContextProtocol(data),
                documentId: _stringFieldOf(data, 'documentId'),
                navigationGeneration: receivedNavigationGeneration,
              );
              sendData = await DeviceInfoEvent().process(context);
              final responseData = sendData['data'];
              if (responseData is Map) {
                responseData['bridgeRevision'] = bridgeRevision ?? 'unknown';
                responseData.addAll(authProtocolCapabilityResponse(data));
              }
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
                testAuthProviderOperation?.call(
                      webViewBridgeFeatureType,
                      context,
                      data,
                    ) ??
                    SignInGoogle.shared.process(context, action: 'login'),
              );
              if (!_isCurrentAuthTransaction(authEpoch!, data)) {
                _logStaleAuthMessage(webViewBridgeFeatureType.value, data);
                return;
              }
              break;
            case WebViewBridgeFeatureType.googleSignInLogout:
              _processAuthCoordinator.cancelActiveForExplicitLogout();
              final googleLogoutRevisionSnapshot = _captureAuthWorkContext();
              final googleLogoutRevision =
                  await runGuardedServiceAuthOperation<int>(
                    fence: _authContextWorkFence(
                      googleLogoutRevisionSnapshot,
                      data,
                    ),
                    staleStage: 'google_logout:after_revision',
                    operation: (country) =>
                        const AuthRevisionStore().next(serviceCountry: country),
                  );
              if (!context.mounted || googleLogoutRevision == null) return;
              _activeAuthRevision = googleLogoutRevision;
              _invalidateAuthTransaction('googleSignInLogout');
              final googleLogoutFence = _authContextWorkFence(
                _captureAuthWorkContext(),
                data,
              );
              sendData = await SignInGoogle.shared.process(
                context,
                action: 'logout',
              );
              if (!googleLogoutFence.checkpoint(
                'google_logout:after_provider',
              )) {
                return;
              }
              break;
            case WebViewBridgeFeatureType.appleSignInLogin:
              sendData = await _awaitAuthOperation(
                testAuthProviderOperation?.call(
                      webViewBridgeFeatureType,
                      context,
                      data,
                    ) ??
                    SignInApple.shared.process(context, action: 'login'),
              );
              if (!_isCurrentAuthTransaction(authEpoch!, data)) {
                _logStaleAuthMessage(webViewBridgeFeatureType.value, data);
                return;
              }
              break;
            case WebViewBridgeFeatureType.appleSignInLogout:
              _processAuthCoordinator.cancelActiveForExplicitLogout();
              final appleLogoutRevisionSnapshot = _captureAuthWorkContext();
              final appleLogoutRevision =
                  await runGuardedServiceAuthOperation<int>(
                    fence: _authContextWorkFence(
                      appleLogoutRevisionSnapshot,
                      data,
                    ),
                    staleStage: 'apple_logout:after_revision',
                    operation: (country) =>
                        const AuthRevisionStore().next(serviceCountry: country),
                  );
              if (!context.mounted || appleLogoutRevision == null) return;
              _activeAuthRevision = appleLogoutRevision;
              _invalidateAuthTransaction('appleSignInLogout');
              final appleLogoutFence = _authContextWorkFence(
                _captureAuthWorkContext(),
                data,
              );
              sendData = await SignInApple.shared.process(
                context,
                action: 'logout',
              );
              if (!appleLogoutFence.checkpoint('apple_logout:after_provider')) {
                return;
              }
              break;
            case WebViewBridgeFeatureType.kakaoSignInLogin:
              sendData = await _awaitAuthOperation(
                testAuthProviderOperation?.call(
                      webViewBridgeFeatureType,
                      context,
                      data,
                    ) ??
                    SignInKakao.shared.process(context, action: 'login'),
              );
              if (!_isCurrentAuthTransaction(authEpoch!, data)) {
                _logStaleAuthMessage(webViewBridgeFeatureType.value, data);
                return;
              }
              break;
            case WebViewBridgeFeatureType.kakaoSignInLogout:
              _processAuthCoordinator.cancelActiveForExplicitLogout();
              final kakaoLogoutRevisionSnapshot = _captureAuthWorkContext();
              final kakaoLogoutRevision =
                  await runGuardedServiceAuthOperation<int>(
                    fence: _authContextWorkFence(
                      kakaoLogoutRevisionSnapshot,
                      data,
                    ),
                    staleStage: 'kakao_logout:after_revision',
                    operation: (country) =>
                        const AuthRevisionStore().next(serviceCountry: country),
                  );
              if (!context.mounted || kakaoLogoutRevision == null) return;
              _activeAuthRevision = kakaoLogoutRevision;
              _invalidateAuthTransaction('kakaoSignInLogout');
              final kakaoLogoutFence = _authContextWorkFence(
                _captureAuthWorkContext(),
                data,
              );
              sendData = await SignInKakao.shared.process(
                context,
                action: 'logout',
              );
              if (!kakaoLogoutFence.checkpoint('kakao_logout:after_provider')) {
                return;
              }
              break;
            case WebViewBridgeFeatureType.refreshTokenRead:
              if (authProtocolVersionOf(data) >= 2) {
                await _recoverInterruptedAuthAttemptIfNeeded();
              }
              final readSnapshot = AuthRevisionReadSnapshot(
                epoch: _authEpoch,
                serviceCountry: serviceCountry,
              );
              final preserveActiveAttempt =
                  (_ownsActiveInteractiveLease && _awaitingAuthTerminal) ||
                  _hasPendingAutomaticReauth;
              final storedRevision = await const AuthRevisionStore().current(
                serviceCountry: readSnapshot.serviceCountry,
              );
              if (!context.mounted ||
                  !readSnapshot.matches(
                    epoch: _authEpoch,
                    serviceCountry: serviceCountry,
                  )) {
                return;
              }
              _activeAuthRevision = resolveRefreshAuthRevision(
                activeRevision: _activeAuthRevision,
                storedRevision: storedRevision,
                preserveInteractiveAttempt: preserveActiveAttempt,
              );
              if (!preserveActiveAttempt && authProtocolVersionOf(data) >= 2) {
                _activeProtocolVersion = authProtocolVersionOf(data);
                _activeRequestId = _requestIdOf(data);
                _activeAuthSessionId =
                    _authSessionIdOf(data) ?? _activeAuthSessionId;
                _activeDocumentId = _stringFieldOf(data, 'documentId');
              }
              authDeliveryContext = _captureAuthWorkContext();
              sendData = await RefreshTokenEvent().process(
                context,
                action: 'read',
                data: adaptRefreshTokenRequestForStorage(data),
                serviceCountry: serviceCountry,
                authRevision: _activeAuthRevision,
              );
              sendData = restoreRefreshTokenResponseProtocol(sendData, data);
              if (!_isCurrentAuthWorkContext(authDeliveryContext)) {
                _discardStaleAuthWorkContext('refresh:after_token_read', data);
                return;
              }
              break;
            case WebViewBridgeFeatureType.refreshTokenWrite:
              if (_isStaleAuthSessionMessage(data) ||
                  _isStaleAuthRevisionMessage(data) ||
                  _isInvalidatedAuthDocumentMessage(data)) {
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
                if (_isHomeDocumentConfirm(data)) {
                  _authRecoveryGate.confirmHomeTokenBind();
                  _pendingSsoRecovery = false;
                  _pendingConvergenceSoftRecovery = false;
                  if (_ssoWatchdogB2) {
                    cancelSsoWatchdog('refreshTokenWrite:home');
                  }
                  // ignore: avoid_print
                  print(
                    '[Watchdog] home confirm accepted; '
                    'wait AUTH_UI_COMMITTED ${_confirmDebugOf(data)}',
                  );
                } else if (_ssoWatchdogB2 &&
                    (_ssoWatchdog?.isActive ?? false)) {
                  // ignore: avoid_print
                  print(
                    '[Watchdog] keep B2 watchdog — non-home confirm; '
                    'wait home convergence ${_confirmDebugOf(data)}',
                  );
                }
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
                data: adaptRefreshTokenRequestForStorage(data),
                serviceCountry: serviceCountry,
                authRevision: _activeAuthRevision,
              );
              sendData = restoreRefreshTokenResponseProtocol(sendData, data);
              break;
            case WebViewBridgeFeatureType.refreshTokenDelete:
              if (_isStaleAuthSessionMessage(data) ||
                  _isInvalidatedAuthDocumentMessage(data)) {
                _logStaleAuthMessage('refreshTokenDelete', data);
                return;
              }
              // account logout은 다른 WebView document에서 도착할 수 있다. 저장소 삭제를
              // 기다리는 동안 직후 재로그인이 기존 process owner에 의해 중복 처리되지
              // 않도록 shared owner를 먼저 동기적으로 종료한다.
              _processAuthCoordinator.cancelActiveForExplicitLogout();
              // web 가 종결 실패/로그아웃으로 token 삭제 — 타이머 살아있는 실제 실패이므로
              // reload 무의미. watchdog 해제 (frozen 케이스는 애초에 아무 메시지도 안 옴).
              // ignore: avoid_print
              print(
                '[SsoExchange] refresh token delete requested ${_deleteDebugOf(data)}',
              );
              final deleteRevisionSnapshot = _captureAuthWorkContext();
              final deleteRevision = await runGuardedServiceAuthOperation<int>(
                fence: _authContextWorkFence(deleteRevisionSnapshot, data),
                staleStage: 'refresh_delete:after_revision',
                operation: (country) =>
                    const AuthRevisionStore().next(serviceCountry: country),
              );
              if (!context.mounted || deleteRevision == null) return;
              _activeAuthRevision = deleteRevision;
              _invalidateAuthTransaction('refreshTokenDelete');
              final deleteFence = _authContextWorkFence(
                _captureAuthWorkContext(),
                data,
              );
              final deleteResponse =
                  await runGuardedServiceAuthOperation<Map<String, Object?>>(
                    fence: deleteFence,
                    staleStage: 'refresh_delete:after_token_delete',
                    operation: (country) => RefreshTokenEvent().process(
                      context,
                      action: 'delete',
                      data: adaptRefreshTokenRequestForStorage(data),
                      serviceCountry: country,
                      authRevision: _activeAuthRevision,
                    ),
                  );
              if (deleteResponse == null) return;
              sendData = deleteResponse;
              sendData = restoreRefreshTokenResponseProtocol(sendData, data);
              await _revokeNativeSsoSessions(data);
              if (!deleteFence.checkpoint(
                'refresh_delete:after_native_revoke',
              )) {
                return;
              }
              break;
            case WebViewBridgeFeatureType.authContextStatus:
              final statusData = data is Map
                  ? Map<String, Object?>.from(data)
                  : <String, Object?>{};
              // Native-owned correlation field: overwrite any untrusted web
              // value with the generation captured when the message arrived.
              statusData['navigationGeneration'] = receivedNavigationGeneration;
              final idempotencyKey = statusData['idempotencyKey'] as String?;
              final isFirst = _authContextStatusOperations.begin(
                idempotencyKey,
              );
              if (isFirst) {
                _activeDocumentId =
                    _stringFieldOf(statusData, 'documentId') ??
                    _activeDocumentId;
                await onAuthContextStatus?.call(statusData);
                _emitAuthTrace(
                  'auth.context.status',
                  resultCode: statusData['status'] as String?,
                  data: statusData,
                );
              }
              sendData = _authContextAck(statusData, status: 'accepted');
              break;
            case WebViewBridgeFeatureType.authContextStatusAck:
              // native → web acknowledgement only.
              return;
            case WebViewBridgeFeatureType.authContextMismatchClearAndRestart:
              final restartData = data is Map
                  ? Map<String, Object?>.from(data)
                  : <String, Object?>{};
              restartData['navigationGeneration'] =
                  receivedNavigationGeneration;
              final restartKey = restartData['idempotencyKey'] as String?;
              _activeDocumentId =
                  _stringFieldOf(restartData, 'documentId') ??
                  _activeDocumentId;
              final currentCountry = _serviceAuthContext.serviceCountry;
              final currentApiBaseUrl = _serviceAuthContext.apiBaseUrl;
              int? recoveryTransitionGeneration;
              final recoveryResult = await _authContextRecoveryCoordinator.run(
                idempotencyKey: restartKey,
                retryDocumentId: _stringFieldOf(restartData, 'documentId'),
                currentContextGeneration: () => _serviceAuthContext.generation,
                // 별도 mismatch/restarting status가 유실돼도 cleanup 요청 자체가
                // native 지역 판단 gate를 먼저 닫는다.
                onRestarting: () => onAuthContextStatus?.call({
                  ...restartData,
                  'status': 'restarting',
                }),
                beginTransition: () {
                  if (_serviceContextTransitionInProgress) return false;
                  beginServiceContextTransition('auth-context-mismatch');
                  recoveryTransitionGeneration = _serviceAuthContext.generation;
                  return _serviceContextTransitionInProgress;
                },
                clearTokens: _clearAllRefreshTokens,
                clearTransient: () =>
                    _clearSsoTransientState('auth-context-mismatch'),
                completeTransition: () {
                  if (!_serviceContextTransitionInProgress ||
                      _serviceAuthContext.generation !=
                          recoveryTransitionGeneration) {
                    return false;
                  }
                  updateServiceContext(
                    serviceCountry: currentCountry,
                    apiBaseUrl: currentApiBaseUrl,
                    webOrigin: _webOrigin,
                    waitForNextNavigation: true,
                  );
                  return true;
                },
                restart: () async {
                  await onAuthContextRestart?.call(restartData);
                  _emitAuthTrace(
                    'auth.context.restart_requested',
                    resultCode: 'cleared',
                    data: restartData,
                  );
                },
                onFailure: () {
                  _emitAuthTrace(
                    'auth.context.restart_failed',
                    resultCode: 'cleanup_failed',
                    data: restartData,
                  );
                  return onAuthContextStatus?.call({
                    ...restartData,
                    'status': 'recoveryFailed',
                    'failureStage': 'service_context_recovery',
                    'failureCode': 'AUTH_CONTEXT_RECOVERY_FAILED',
                  });
                },
              );
              sendData = _authContextAck(
                restartData,
                status:
                    recoveryResult == AuthContextRecoveryResult.restartFailed
                    ? 'restartFailed'
                    : 'restartAccepted',
              );
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
            case WebViewBridgeFeatureType.authOnboardingReady:
              await _handleAuthOnboardingReady(data);
              return;
            case WebViewBridgeFeatureType.authReauthCommitted:
              await _handleAuthReauthCommitted(data);
              return;
            case WebViewBridgeFeatureType.authReauthRequired:
              // native → web semantic outcome only.
              return;
            case WebViewBridgeFeatureType.authAttemptStarted:
              // native → web acknowledgement only.
              return;
          }
        } catch (e) {
          if (e is _AuthOperationAborted) return;
          // OAuth 실패 (sign_in_*.dart 의 throw AuthError) 는 단일 surface:
          // AUTH_ERROR payload 송신 + native SnackBar skip.
          // (사용자 toast 는 webview 측이 단독 표시 — 중복 회피)
          if (e is AuthError) {
            final nativeSdkCause = safeNativeSdkCauseFromCode(
              e.nativeSdkErrorCode,
            );
            final failureData = _failureData(
              data,
              failureStage: 'native_sdk',
              failureCode: e.code,
            )..['nativeSdkErrorCode'] = e.nativeSdkErrorCode;
            if (nativeSdkCause != null) {
              failureData['nativeSdkCause'] = nativeSdkCause;
            }
            _emitAuthTerminal(
              e.code == 'USER_CANCELLED'
                  ? 'user_cancelled'
                  : const {'NETWORK_ERROR', 'PROVIDER_ERROR'}.contains(e.code)
                  ? 'excluded_external_failure'
                  : 'code_failure:native_auth_error',
              data: failureData,
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
                    'failureStage': 'native_sdk',
                    'failureCode': e.code,
                    'nativeSdkErrorCode': e.nativeSdkErrorCode,
                    if (nativeSdkCause != null)
                      'nativeSdkCause': nativeSdkCause,
                  },
                }),
              );
            } catch (_) {}
            return;
          }
          // 예상 밖 auth exception도 반드시 canonical terminal로 닫는다. 그렇지 않으면
          // UI에는 실패가 보여도 KPI에는 attempt 자체가 사라질 수 있다.
          final unexpectedFailureStage = unexpectedAuthFailureStage(
            webViewBridgeFeatureType,
          );
          if (unexpectedFailureStage != null) {
            final failureData = _failureData(
              data,
              failureStage: unexpectedFailureStage,
              failureCode: 'NATIVE_INTERNAL_ERROR',
            );
            _emitAuthTerminal(
              'code_failure:native_internal',
              data: failureData,
            );
            _invalidateAuthTransaction('NATIVE_INTERNAL_ERROR');
            try {
              await runJavaScriptPostMessage(
                jsonEncode({
                  'type': WebViewBridgeFeatureType.authError.value,
                  'data': {
                    ...failureData,
                    'code': 'NATIVE_INTERNAL_ERROR',
                    'message': '',
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
          pendingReauthReplay = _replayPendingAutomaticReauth(data);
          final isInteractiveReplay =
              authProtocolVersionOf(data) >= 2 &&
              _canReplayInteractiveRefresh(data);
          if (isInteractiveReplay) {
            _emitAuthTrace('auth.refresh.interactive_replay', data: data);
          }
          if (!isInteractiveReplay && pendingReauthReplay == null) {
            processAutoAuthWork = await _beginAutoAuthAttemptIfNeeded(
              data,
              sendData,
            );
          }
          // protocol v2 자동 인증 응답은 process-wide 소유권이 있을 때만 진행한다.
          // 다른 bridge instance에서 수동 로그인이 진행 중이면 오래된 refresh 결과가
          // 사용자가 선택한 로그인 결과를 덮어쓰지 않도록 응답 자체를 중단한다.
          // 단, 현재 bridge가 소유한 동일 interactive 시도의 session replay는 새 home
          // document로 수렴하는 경로이므로 새 auto lease 없이 그대로 허용한다.
          if (authProtocolVersionOf(data) >= 2 &&
              processAutoAuthWork == null &&
              !isInteractiveReplay &&
              pendingReauthReplay == null) {
            return;
          }
          if (pendingReauthReplay != null) sendData = pendingReauthReplay;
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
                WebViewBridgeFeatureType.refreshTokenRead &&
            pendingReauthReplay == null) {
          final replay = _replayRecentSession(data);
          if (replay != null) {
            sendData = replay;
          } else if (authProtocolVersionOf(data) >= 2) {
            final refreshed = await _refreshStoredSessionToTokensReady(
              sendData,
              data,
              authContext: authDeliveryContext!,
            );
            if (refreshed == null) return;
            sendData = refreshed;
          }
        }

        if (processAutoAuthWork != null &&
            !shouldDeliverAutoAuthResponse(
              isLeaseActive: _processAuthCoordinator.isActive(
                processAutoAuthWork.lease,
              ),
              isTerminalSettled: _processAuthCoordinator.isTerminalSettled(
                attemptId: processAutoAuthWork.lease.attemptId,
                revision: _activeAuthRevision,
              ),
              responseType: sendData['type'],
            )) {
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
          _markProviderCompleted(data);
          _startAttemptTerminalDeadline();
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
            const {
              'AUTH_TOKENS_READY',
              'AUTH_REAUTH_REQUIRED',
            }.contains(sendData['type'])) {
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
            _ensureAttemptTerminalDeadline();
            if (sendData['type'] ==
                WebViewBridgeFeatureType.authTokensReady.value) {
              _armSsoWatchdog(isB2: true);
            }
          }
        }

        if (authDeliveryContext != null &&
            !_isCurrentAuthWorkContext(authDeliveryContext)) {
          _discardStaleAuthWorkContext('refresh:before_delivery', data);
          return;
        }

        // Send Data to WebView
        final encoded = jsonEncode(sendData);
        debugPrint(
          '[Bridge] postMessage type=${webViewBridgeFeatureType.value} len=${encoded.length}',
        );
        try {
          final delivered = await _runJavaScriptPostMessageWithReceipt(encoded);
          final deliveryTraceData = delivered
              ? data
              : _failureData(
                  data,
                  failureStage: 'web_delivery',
                  failureCode: 'BRIDGE_HANDLER_UNAVAILABLE',
                );
          _emitAuthTrace(
            'bridge.delivery.${delivered ? "received" : "missed"}',
            resultCode: delivered ? 'received' : 'handler_unavailable',
            data: deliveryTraceData,
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
    if (data is! Map ||
        data['protocolVersion'] is! int ||
        (data['protocolVersion'] as int) < 2 ||
        (data['protocolVersion'] as int) > 3) {
      return;
    }

    final workSnapshot = _captureAuthTerminalWork(data);
    final isKnownTerminal = _processAuthCoordinator.isTerminalSettled(
      attemptId: workSnapshot.attemptId,
      revision: workSnapshot.revision,
    );
    final terminalKey = _terminalKeyOf(data);
    if (isKnownTerminal || _terminalAuthSessionIds.contains(terminalKey)) {
      _rememberTerminalKey(terminalKey);
      _emitAuthTrace(
        'auth.ui.duplicate_ignored',
        resultCode: 'idempotent_duplicate',
        data: data,
      );
      return;
    }
    if (workSnapshot.leaseGeneration == null) {
      _emitAuthTrace(
        'auth.ui.rejected',
        resultCode: 'no_active_auth_owner',
        data: data,
      );
      return;
    }
    if (!_isCurrentAuthTerminalWork(workSnapshot)) {
      _emitAuthTrace(
        'auth.ui.rejected',
        resultCode: 'stale_auth_work',
        data: data,
      );
      return;
    }

    // UI ACK가 native URL을 확인하는 동안 deadline timer가 같은 attempt를 먼저
    // 실패 처리하지 못하게 잠시 멈춘다. 거부되면 기존 모드로 다시 arm한다.
    final attemptDeadlineWasActive =
        _authConvergenceDeadline.isActive ||
        (_attemptTerminalTimer?.isActive ?? false);
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
        // process generation으로 동일 attempt임을 이미 검증했다. observer home
        // bridge의 local active attempt는 비어 있거나 이전 document 값일 수 있다.
        activeAuthSessionId: workSnapshot.attemptId,
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
      final successData = <String, Object?>{
        for (final entry in data.entries)
          if (entry.key is String) entry.key as String: entry.value,
        'success': true,
        'uiAuthCommitted': true,
      };
      _emitAuthTerminal('ui_authenticated', data: successData);
    } finally {
      if (!accepted &&
          _isCurrentAuthTerminalWork(workSnapshot) &&
          _awaitingAuthTerminal) {
        if (attemptDeadlineWasActive) _armAttemptTerminalTimer();
        if (watchdogWasActive) _armSsoWatchdog(isB2: watchdogWasB2);
      }
    }
  }

  bool _isSignupPath(String? value) {
    if (value == null || value.isEmpty) return false;
    final uri = Uri.tryParse(value);
    final segments = (uri?.path ?? value)
        .split('/')
        .where((segment) => segment.isNotEmpty)
        .toList();
    if (segments.isNotEmpty &&
        const {'ko', 'en', 'ja'}.contains(segments.first)) {
      segments.removeAt(0);
    }
    return segments.length >= 2 &&
        segments[0] == 'auth' &&
        segments[1] == 'signup';
  }

  Future<void> _handleAuthOnboardingReady(dynamic data) async {
    if (data is! Map) {
      _emitAuthTrace(
        'auth.onboarding.rejected',
        resultCode: 'invalid_payload',
        data: data,
      );
      return;
    }
    final snapshot = _captureAuthTerminalWork(data);
    if (!_isCurrentAuthTerminalWork(snapshot)) {
      _emitAuthTrace(
        'auth.onboarding.rejected',
        resultCode: 'stale_auth_work',
        data: data,
      );
      return;
    }
    final attemptDeadlineWasActive =
        _authConvergenceDeadline.isActive ||
        (_attemptTerminalTimer?.isActive ?? false);
    final watchdogWasActive = _ssoWatchdog?.isActive ?? false;
    final watchdogWasB2 = _ssoWatchdogB2;
    _attemptTerminalTimer?.cancel();
    _attemptTerminalTimer = null;
    _ssoWatchdog?.cancel();
    _ssoWatchdog = null;
    var accepted = false;
    try {
      String? currentUrl;
      try {
        currentUrl = await webViewController.currentUrl().timeout(
          const Duration(seconds: 3),
        );
      } catch (_) {
        _emitAuthTrace(
          'auth.onboarding.rejected',
          resultCode: 'native_url_unavailable',
          data: data,
        );
        return;
      }
      if (!_isCurrentAuthTerminalWork(snapshot)) {
        _emitAuthTrace(
          'auth.onboarding.rejected',
          resultCode: 'attempt_changed_during_url_check',
          data: data,
        );
        return;
      }
      final decision = validateAuthSemanticCommit(
        kind: AuthSemanticCommitKind.onboardingReady,
        data: data,
        activeProtocolVersion: _activeProtocolVersion,
        activeRequestId: _activeRequestId,
        activeAuthSessionId: _activeAuthSessionId,
        activeAuthRevision: _activeAuthRevision,
        nativeRouteMatches: _isSignupPath(currentUrl),
        webRouteMatches: _isSignupPath(_stringFieldOf(data, 'pathname')),
      );
      if (!decision.isAccepted) {
        _emitAuthTrace(
          'auth.onboarding.rejected',
          resultCode: decision.rejection!.name,
          data: data,
        );
        return;
      }
      final key = '${snapshot.attemptId}:${snapshot.revision}';
      if (!_onboardingReadyKeys.add(key)) {
        _emitAuthTrace(
          'auth.onboarding.duplicate_ignored',
          resultCode: 'idempotent_duplicate',
          data: data,
        );
        return;
      }
      accepted = true;

      // Close only the convergence clock. The original process lease remains
      // so a later visible home commit can finish login after signup.
      _activeAuthJourney = 'signup_onboarding';
      _settleAuthTerminalTracking();
      cancelSsoWatchdog('authOnboardingReady:validated');
      final originalAttemptId = snapshot.attemptId;
      _emitAuthTrace(
        'auth.terminal',
        resultCode: 'onboarding_ready',
        data: <String, Object?>{
          for (final entry in data.entries)
            if (entry.key is String) entry.key as String: entry.value,
          'authSessionId': '${originalAttemptId ?? "unknown"}:onboarding',
          if (originalAttemptId != null)
            'predecessorAttemptId': originalAttemptId,
          'journey': 'signup_onboarding',
        },
      );
    } finally {
      if (!accepted &&
          _isCurrentAuthTerminalWork(snapshot) &&
          _awaitingAuthTerminal) {
        if (attemptDeadlineWasActive) _armAttemptTerminalTimer();
        if (watchdogWasActive) _armSsoWatchdog(isB2: watchdogWasB2);
      }
    }
  }

  Future<void> _handleAuthReauthCommitted(dynamic data) async {
    if (data is! Map) {
      _emitAuthTrace(
        'auth.reauth.rejected',
        resultCode: 'invalid_payload',
        data: data,
      );
      return;
    }
    final snapshot = _captureAuthTerminalWork(data);
    if (!_isCurrentAuthTerminalWork(snapshot)) {
      _emitAuthTrace(
        'auth.reauth.rejected',
        resultCode: 'stale_auth_work',
        data: data,
      );
      return;
    }
    final attemptDeadlineWasActive =
        _authConvergenceDeadline.isActive ||
        (_attemptTerminalTimer?.isActive ?? false);
    final watchdogWasActive = _ssoWatchdog?.isActive ?? false;
    final watchdogWasB2 = _ssoWatchdogB2;
    _attemptTerminalTimer?.cancel();
    _attemptTerminalTimer = null;
    _ssoWatchdog?.cancel();
    _ssoWatchdog = null;
    var accepted = false;
    try {
      String? currentUrl;
      try {
        currentUrl = await webViewController.currentUrl().timeout(
          const Duration(seconds: 3),
        );
      } catch (_) {
        _emitAuthTrace(
          'auth.reauth.rejected',
          resultCode: 'native_url_unavailable',
          data: data,
        );
        return;
      }
      if (!_isCurrentAuthTerminalWork(snapshot)) {
        _emitAuthTrace(
          'auth.reauth.rejected',
          resultCode: 'attempt_changed_during_url_check',
          data: data,
        );
        return;
      }
      final decision = validateAuthSemanticCommit(
        kind: AuthSemanticCommitKind.reauthRequired,
        data: data,
        activeProtocolVersion: _activeProtocolVersion,
        activeRequestId: _activeRequestId,
        activeAuthSessionId: _activeAuthSessionId,
        activeAuthRevision: _activeAuthRevision,
        nativeRouteMatches: _isHomePath(currentUrl),
        webRouteMatches: _isHomePath(_stringFieldOf(data, 'pathname')),
      );
      if (!decision.isAccepted) {
        _emitAuthTrace(
          'auth.reauth.rejected',
          resultCode: decision.rejection!.name,
          data: data,
        );
        return;
      }
      accepted = true;
      final terminalData = <String, Object?>{
        for (final entry in data.entries)
          if (entry.key is String) entry.key as String: entry.value,
        'provider': autoAuthProvider,
        'journey': 'auto_refresh',
        if (_activeReauthSemanticReason != null)
          'semanticReason': _activeReauthSemanticReason,
      };
      _emitAuthTerminal('reauth_required', data: terminalData);
      _activeReauthSemanticReason = null;
      _clearSessionReplay('reauth-required-committed');
    } finally {
      if (!accepted &&
          _isCurrentAuthTerminalWork(snapshot) &&
          _awaitingAuthTerminal) {
        if (attemptDeadlineWasActive) _armAttemptTerminalTimer();
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

  Future<Map<String, Object?>?> _refreshStoredSessionToTokensReady(
    Map<String, Object?> readResponse,
    dynamic requestData, {
    required AuthWorkContextSnapshot authContext,
  }) async {
    final readData = readResponse['data'];
    final refreshToken = readData is Map
        ? readData['refreshToken'] as String?
        : null;
    if (refreshToken == null || refreshToken.isEmpty) return readResponse;
    final snapshotApiBaseUrl = authContext.service.apiBaseUrl;
    if (snapshotApiBaseUrl == null) return readResponse;
    final workFence = _authContextWorkFence(authContext, requestData);

    try {
      final sso = SsoExchange(
        apiBaseUrl: snapshotApiBaseUrl,
        domainType: authContext.service.domainType,
      );
      final deviceHeaders = await _deviceHeaders();
      if (!workFence.checkpoint('refresh:after_device_headers')) return null;
      final result = await sso.refreshToAccess(
        refreshToken: refreshToken,
        deviceHeaders: deviceHeaders,
      );
      if (!context.mounted) return null;
      if (!workFence.checkpoint('refresh:after_exchange')) return null;
      final persisted = await RefreshTokenEvent().process(
        context,
        action: 'write',
        data: result.refreshToken,
        serviceCountry: authContext.service.serviceCountry,
        authRevision: authContext.authRevision,
        canMutate: () => workFence.canMutate,
      );
      if (persisted['error'] == 'STALE_AUTH_CONTEXT') {
        workFence.checkpoint('refresh:after_persist');
        return null;
      }
      if (!workFence.checkpoint('refresh:after_persist')) {
        return null;
      }
      if (persisted['error'] != null) {
        throw StateError('REFRESH_TOKEN_PERSIST_FAILED');
      }
      final me = await sso.fetchMe(
        accessToken: result.accessToken,
        deviceHeaders: deviceHeaders,
      );
      if (!workFence.checkpoint('refresh:after_me')) return null;
      _emitMeFetchResult(me, requestData);
      final payload = <String, Object?>{
        'type': WebViewBridgeFeatureType.authTokensReady.value,
        'data': {
          'accessToken': result.accessToken,
          'refreshToken': result.refreshToken,
          'protocolVersion': _activeProtocolVersion,
          if (_requestIdOf(requestData) != null)
            'requestId': _requestIdOf(requestData),
          if (_authSessionIdOf(requestData) != null)
            'authSessionId': _authSessionIdOf(requestData),
          if (_stringFieldOf(requestData, 'documentId') != null)
            'documentId': _stringFieldOf(requestData, 'documentId'),
          if (requestData is Map && requestData['pageGeneration'] is int)
            'pageGeneration': requestData['pageGeneration'] as int,
          'authRevision': authContext.authRevision,
          'serviceCountry': authContext.service.serviceCountry,
          'domainType': authContext.service.domainType,
          if (me != null) 'me': me,
        },
      };
      _cachedSessionPayload = payload;
      _cachedSessionAt = DateTime.now();
      _markProviderCompleted(requestData);
      _emitAuthTrace('auth.refresh.exchanged', data: requestData);
      return payload;
    } catch (error) {
      if (!workFence.checkpoint('refresh:catch')) return null;
      _markProviderCompleted(requestData);
      final statusCode = error is SsoExchangeException
          ? error.statusCode
          : null;
      final semanticReason = error is SsoExchangeException
          ? error.semanticReason
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
          serviceCountry: authContext.service.serviceCountry,
          authRevision: authContext.authRevision,
        );
        if (!workFence.checkpoint('refresh:after_delete')) return null;
      }
      if (semanticReason != null && _activeProtocolVersion >= 3) {
        _activeReauthSemanticReason = semanticReason;
        final reauthData = <String, Object?>{
          ..._activeAuthProtocolData(),
          'provider': autoAuthProvider,
          'journey': 'auto_refresh',
          'semanticReason': semanticReason,
        };
        _emitAuthTrace(
          'auth.reauth.required',
          resultCode: semanticReason,
          data: reauthData,
        );
        return {
          'type': WebViewBridgeFeatureType.authReauthRequired.value,
          'data': reauthData,
        };
      }
      final failureStage = _failureStageOf(error, 'refresh_exchange');
      final failureCode = _failureCodeOf(error, 'NATIVE_INTERNAL_ERROR');
      final failureData = _failureData(
        requestData,
        failureStage: failureStage,
        failureCode: failureCode,
        httpStatus: statusCode,
      );
      _emitAuthTerminal(
        _isExternalSsoFailure(error)
            ? 'excluded_external_failure'
            : 'code_failure:native_refresh_exchange',
        data: failureData,
      );
      return {
        'type': WebViewBridgeFeatureType.authError.value,
        'data': {
          'code': 'REFRESH_EXCHANGE_FAILED',
          'message': '',
          'protocolVersion': _activeProtocolVersion,
          if (_requestIdOf(requestData) != null)
            'requestId': _requestIdOf(requestData),
          if (_authSessionIdOf(requestData) != null)
            'authSessionId': _authSessionIdOf(requestData),
          if (_stringFieldOf(requestData, 'documentId') != null)
            'documentId': _stringFieldOf(requestData, 'documentId'),
          'authRevision': _activeAuthRevision,
          'failureStage': failureStage,
          'failureCode': failureCode,
          if (statusCode != null) 'httpStatus': statusCode,
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
    final authContext = _captureAuthWorkContext();
    final snapshotApiBaseUrl = authContext.service.apiBaseUrl;
    if (snapshotApiBaseUrl == null) return sendData;
    final workFence = _authContextWorkFence(authContext, requestData);
    try {
      // domainType: KR(또는 null)=sazo-korea-shop(현행) / GLOBAL=sazo-global-shop
      // (웹 배포 계약 09-env-runtime 확인값). KR 경로 byte-identical.
      final sso = SsoExchange(
        apiBaseUrl: snapshotApiBaseUrl,
        domainType: authContext.service.domainType,
      );
      final deviceHeaders = await _deviceHeaders();
      if (!workFence.checkpoint('sso:after_device_headers')) return null;
      final result = await sso.exchange(
        provider: _providerOf(type),
        idToken: idToken,
        profile: profile,
        persist: persist,
        deviceHeaders: deviceHeaders,
      );
      if (!_isCurrentAuthTransaction(authEpoch, requestData) ||
          !workFence.canMutate) {
        if (workFence.checkpoint('sso:after_exchange')) {
          _logStaleAuthMessage('ssoExchange:afterExchange', requestData);
        }
        return null;
      }
      // 자동로그인용 refresh 네이티브 저장. (RefreshTokenEvent 는 context 를 SharedPreferences
      // 용으로만 받고 UI 미사용 → async gap 안전)
      final persistResult = await RefreshTokenEvent().process(
        // ignore: use_build_context_synchronously
        context,
        action: 'write',
        data: result.refreshToken,
        serviceCountry: authContext.service.serviceCountry,
        authRevision: authContext.authRevision,
        canMutate: () => workFence.canMutate,
      );
      if (persistResult['error'] == 'STALE_AUTH_CONTEXT') {
        workFence.checkpoint('sso:after_persist');
        return null;
      }
      if (!workFence.checkpoint('sso:after_persist')) {
        return null;
      }
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
      _emitMeFetchResult(me, requestData);
      if (!_isCurrentAuthTransaction(authEpoch, requestData) ||
          !workFence.canMutate) {
        if (workFence.checkpoint('sso:after_me')) {
          _logStaleAuthMessage('ssoExchange:afterMe', requestData);
        }
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
          'authRevision': authContext.authRevision,
          'serviceCountry': authContext.service.serviceCountry,
          'domainType': authContext.service.domainType,
          if (me != null) 'me': me,
        },
      };
      // 세션 replay 캐시 — WebContent jettison 후 새 document 가 REFRESH_TOKEN_READ 로
      // 물어오면 이 payload 를 그대로 재전송(재교환 없음). TTL 내에서만 유효.
      _cachedSessionPayload = payload;
      _cachedSessionAt = DateTime.now();
      return payload;
    } catch (e) {
      if (!_isCurrentAuthTransaction(authEpoch, requestData) ||
          !workFence.canMutate) {
        if (workFence.checkpoint('sso:catch')) {
          _logStaleAuthMessage('ssoExchange:catch', requestData);
        }
        return null;
      }
      // ignore: avoid_print
      print('[SsoExchange] FAIL ${type.value}: ${e.runtimeType}');
      final statusCode = e is SsoExchangeException ? e.statusCode : null;
      final failureStage = _failureStageOf(e, 'unknown');
      final failureCode = _failureCodeOf(e, 'NATIVE_INTERNAL_ERROR');
      final failureData = _failureData(
        requestData,
        failureStage: failureStage,
        failureCode: failureCode,
        httpStatus: statusCode,
      );
      _emitAuthTerminal(
        _isExternalSsoFailure(e)
            ? 'excluded_external_failure'
            : 'code_failure:sso_exchange',
        data: failureData,
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
          'failureStage': failureStage,
          'failureCode': failureCode,
          if (statusCode != null) 'httpStatus': statusCode,
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
    if (_serviceContextTransitionInProgress) return null;
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
    final cachedServiceCountry = cachedData is Map
        ? cachedData['serviceCountry'] as String?
        : null;
    if (cachedServiceCountry != null &&
        normalizeServiceCountry(cachedServiceCountry) !=
            _serviceAuthContext.serviceCountry) {
      _cachedSessionPayload = null;
      _cachedSessionAt = null;
      _emitAuthTrace(
        'auth.context.replay_discarded',
        resultCode: 'service_country_mismatch',
        data: requestData,
      );
      return null;
    }
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
      _activeDocumentId = _stringFieldOf(requestData, 'documentId');
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
