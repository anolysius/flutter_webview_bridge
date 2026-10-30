import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webview_bridge/flutter_webview_bridge.dart';
import 'package:flutter_webview_bridge/src/bridge/auth/process_auth_attempt_coordinator.dart';
import 'package:flutter_webview_bridge/src/bridge/events/auth_error.dart';
import 'package:flutter_webview_bridge/src/bridge/events/auth_error_mapper.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

/// 웹으로 보낸 postMessage 를 기록하는 WebView 대역.
class _WebView extends PlatformWebViewController {
  _WebView()
    : super.implementation(const PlatformWebViewControllerCreationParams());

  final messages = <Map<String, dynamic>>[];

  @override
  Future<Object> runJavaScriptReturningResult(String script) async {
    final encoded = RegExp(r'var payload = (.*);').firstMatch(script)?.group(1);
    if (encoded != null) {
      messages.add(
        jsonDecode(jsonDecode(encoded) as String) as Map<String, dynamic>,
      );
    }
    return true;
  }
}

Future<BuildContext> _mountedContext(WidgetTester tester) async {
  late BuildContext context;
  await tester.pumpWidget(
    MaterialApp(
      home: Builder(
        builder: (value) {
          context = value;
          return const SizedBox();
        },
      ),
    ),
  );
  return context;
}

Future<void> _pumpUntil(WidgetTester tester, bool Function() condition) async {
  for (var attempt = 0; attempt < 50 && !condition(); attempt += 1) {
    await tester.pump(const Duration(milliseconds: 1));
  }
}

var _attemptSeq = 0;

/// 테스트마다 다른 attempt — 같은 attempt 의 terminal 은 프로세스 단위로 한 번만 기록된다.
JavaScriptMessage _kakaoLogin(int seq) => JavaScriptMessage(
  message: jsonEncode({
    'type': 'KAKAO_SIGN_IN_LOGIN',
    'data': {
      'protocolVersion': 3,
      'maxProtocolVersion': 3,
      'authCapabilities': [
        'softConvergenceDeadline',
        'onboardingHandoff',
        'reauthRequiredCommit',
      ],
      'authSessionId': 'attempt-cause-$seq',
      'requestId': 'request-cause-$seq',
      'documentId': 'document-cause-$seq',
      'authRevision': 1,
      'provider': 'KAKAO',
    },
  }),
);

/// 이번 장애 가설 B 의 형태 — 카카오톡 실패 후 카카오계정 창을 못 띄움.
const _fallbackPresentationFailure = AuthError(
  AuthErrorCode.userCancelled,
  'PlatformException',
  nativeSdkErrorCode: 'KAKAO_USER_CANCELLED',
  failureCause: 'KAKAO_FALLBACK_WEBAUTH_3',
  failureContext: {
    'fallbackFromCause': 'KAKAO_TALK_AUTH_ACCESS_DENIED',
    'fallbackFromDetail': 'User denied access',
    'stepElapsedMs': 1140,
    'kakaoTalkInstalled': true,
  },
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ProcessAuthAttemptCoordinator.shared.resetForAuthBoundary();
  });

  tearDown(ProcessAuthAttemptCoordinator.shared.resetForAuthBoundary);

  // 브릿지의 프로세스 단위 비동기 상태(코디네이터·저장소)는 테스트별 fake-async zone 을 넘지 못한다.
  // 그래서 시나리오를 한 testWidgets 안에서 차례로 돌린다 — 각 시나리오는 별도 channel·attempt.
  final scenarios = <(String, Future<void> Function(WidgetTester))>[];
  void scenario(String name, Future<void> Function(WidgetTester) body) =>
      scenarios.add((name, body));

  Future<
    ({
      _WebView web,
      List<Map<String, Object?>> traces,
      FlutterWebViewBridgeJavaScriptChannel channel,
    })
  >
  start(
    WidgetTester tester, {
    AuthFailureDiagnosticsProvider? diagnostics,
    AuthError error = _fallbackPresentationFailure,
  }) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final context = await _mountedContext(tester);
    final web = _WebView();
    final traces = <Map<String, Object?>>[];
    final channel = FlutterWebViewBridgeJavaScriptChannel(
      context: context,
      webViewController: WebViewController.fromPlatform(web),
      googleServerClientId: null,
      kakaoNativeAppKey: null,
      serviceCountry: 'KR',
      apiBaseUrl: null,
      onAuthTrace: traces.add,
      authFailureDiagnostics: diagnostics,
      testAuthProviderOperation: (type, _, _) async => throw error,
    );
    addTearDown(() {
      channel.resetAuthStateForServiceCountrySwitch('test-cleanup');
      channel.dispose();
    });
    unawaited(channel.onMessageReceived(_kakaoLogin(++_attemptSeq)));
    await _pumpUntil(
      tester,
      () => web.messages.any((m) => m['type'] == 'AUTH_ERROR'),
    );
    return (web: web, traces: traces, channel: channel);
  }

  Map<String, Object?> terminalOf(List<Map<String, Object?>> traces) =>
      traces.singleWhere((t) => t['event'] == 'auth.terminal');

  scenario('terminal 에 원인·진단이 실리고 분류는 원인 표를 따른다 (AC2·AC3·AC6)', (tester) async {
    final run = await start(tester);
    final terminal = terminalOf(run.traces);

    expect(terminal['failureCause'], 'KAKAO_FALLBACK_WEBAUTH_3');
    expect(terminal['fallbackFromCause'], 'KAKAO_TALK_AUTH_ACCESS_DENIED');
    expect(terminal['fallbackFromDetail'], 'User denied access');
    expect(terminal.containsKey('providerErrorDetail'), isFalse);
    expect(terminal['stepElapsedMs'], 1140);
    expect(terminal['kakaoTalkInstalled'], isTrue);
    expect(terminal['appLifecycleState'], 'resumed');
    // 창을 못 띄운 실패는 '취소'가 아니라 코드 실패로 집계된다.
    expect(terminal['resultCode'], 'code_failure:native_auth_error');
    // 하위호환 필드는 그대로 (AC9).
    expect(terminal['failureCode'], 'USER_CANCELLED');
    expect(terminal['nativeSdkErrorCode'], 'KAKAO_USER_CANCELLED');
  });

  scenario('웹 화면용 AUTH_ERROR.code 는 바뀌지 않고 원인이 함께 간다 (AC6b)', (tester) async {
    final run = await start(tester);
    final authError = run.web.messages.singleWhere(
      (m) => m['type'] == 'AUTH_ERROR',
    );
    final data = authError['data'] as Map<String, dynamic>;

    expect(data['code'], 'USER_CANCELLED');
    expect(data['nativeSdkErrorCode'], 'KAKAO_USER_CANCELLED');
    expect(data['failureCause'], 'KAKAO_FALLBACK_WEBAUTH_3');
    expect(data['fallbackFromCause'], 'KAKAO_TALK_AUTH_ACCESS_DENIED');
    expect(data['fallbackFromDetail'], 'User denied access');
  });

  scenario('진단 수집이 끝나지 않아도 AUTH_ERROR 는 즉시 나간다 (AC6c)', (tester) async {
    final neverCompletes = Completer<Map<String, Object>>();
    final run = await start(tester, diagnostics: () => neverCompletes.future);

    expect(
      run.web.messages.where((m) => m['type'] == 'AUTH_ERROR'),
      hasLength(1),
    );
    expect(terminalOf(run.traces)['failureCause'], 'KAKAO_FALLBACK_WEBAUTH_3');

    // 300ms 안에 못 받으면 진단 이벤트는 생략한다.
    await tester.pump(const Duration(milliseconds: 400));
    expect(
      run.traces.where((t) => t['event'] == 'auth.failure.diagnostics'),
      isEmpty,
    );
  });

  scenario('진단값은 같은 attempt 의 별도 이벤트로 남는다 (AC4)', (tester) async {
    final run = await start(
      tester,
      diagnostics: () async => {
        'iosKeyWindowPresent': false,
        'iosSceneActivationState': 'foregroundInactive',
      },
    );
    await _pumpUntil(
      tester,
      () => run.traces.any((t) => t['event'] == 'auth.failure.diagnostics'),
    );

    final diagnostics = run.traces.singleWhere(
      (t) => t['event'] == 'auth.failure.diagnostics',
    );
    final terminal = terminalOf(run.traces);
    expect(diagnostics['loginAttemptId'], terminal['loginAttemptId']);
    expect(diagnostics['failureCause'], 'KAKAO_FALLBACK_WEBAUTH_3');
    expect(diagnostics['iosKeyWindowPresent'], isFalse);
    expect(diagnostics['iosSceneActivationState'], 'foregroundInactive');
  });

  scenario('진단 provider 가 실패해도 로그인 흐름은 영향이 없다', (tester) async {
    final run = await start(
      tester,
      diagnostics: () async => throw StateError('channel missing'),
    );
    await tester.pump(const Duration(milliseconds: 50));

    expect(
      run.web.messages.where((m) => m['type'] == 'AUTH_ERROR'),
      hasLength(1),
    );
    expect(
      run.traces.where((t) => t['event'] == 'auth.failure.diagnostics'),
      isEmpty,
    );
  });

  scenario('진짜 사용자 취소는 user_cancelled 로 남는다', (tester) async {
    final run = await start(
      tester,
      error: const AuthError(
        AuthErrorCode.userCancelled,
        'PlatformException',
        nativeSdkErrorCode: 'KAKAO_USER_CANCELLED',
        failureCause: 'KAKAO_ACCOUNT_WEBAUTH_1',
      ),
    );
    expect(terminalOf(run.traces)['resultCode'], 'user_cancelled');
  });

  testWidgets('로그인 실패 원인 trace 시나리오', (tester) async {
    for (final (name, body) in scenarios) {
      await body(tester);
      ProcessAuthAttemptCoordinator.shared.resetForAuthBoundary();
      // ignore: avoid_print
      print('scenario ok: $name');
    }
  });
}
