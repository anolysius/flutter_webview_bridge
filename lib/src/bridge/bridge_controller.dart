import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/cupertino.dart';
import 'package:flutter_webview_bridge/flutter_webview_bridge.dart';
import 'package:webview_flutter/webview_flutter.dart';

class WebViewBridgeController {
  FlutterWebViewBridgeJavaScriptChannel? _channel;
  Completer<void>? _initCompleter;
  final Queue<_QueuedRequest> _requestQueue = Queue<_QueuedRequest>();
  bool _isTerminated = false;
  AppLifecycleState _appLifecycleState = AppLifecycleState.resumed;

  /// PUSH_TOKEN payload 에 동봉할 서비스 국가 (APP-300 R6 — 푸시 segmentation).
  /// init 시 주입. 미주입=null → payload 에서 'KR' 기본값.
  String? _serviceCountry;

  void initFlutterWebViewBridgeJavaScriptChannel(
    BuildContext context,
    WebViewController webViewController, {
    required String? googleServerClientId,
    required String? kakaoNativeAppKey,
    String? apiBaseUrl,
    String? serviceCountry,
    void Function(String requestedCountry)? onServiceCountryChange,
  }) {
    _isTerminated = false;
    _serviceCountry = serviceCountry;
    if (_channel != null) {
      // WebView 재생성 시 channel handler 는 유지, controller 만 swap.
      // addJavaScriptChannel 중복 호출은 stale handler 위험만 키우므로 회피.
      _channel!.updateWebViewController(webViewController, newContext: context);
      _channel!.updateAppLifecycleState(_appLifecycleState);
      _completeInitialization();
      _processQueue();
      return;
    }

    _channel = FlutterWebViewBridgeJavaScriptChannel(
      context: context,
      webViewController: webViewController,
      googleServerClientId: googleServerClientId,
      kakaoNativeAppKey: kakaoNativeAppKey,
      apiBaseUrl: apiBaseUrl,
      serviceCountry: serviceCountry,
      onServiceCountryChange: onServiceCountryChange,
    );
    _channel!.updateAppLifecycleState(_appLifecycleState);
    _channel!.addJavaScriptChannel();

    _completeInitialization();

    _processQueue();
  }

  void handleAppLifecycleState(AppLifecycleState state) {
    if (_isTerminated) return;

    _appLifecycleState = state;
    _channel?.updateAppLifecycleState(state);

    if (state == AppLifecycleState.resumed) {
      unawaited(runJavaScriptAppState(state));
    }
  }

  Future<void> runJavaScriptAppState(AppLifecycleState state) async {
    if (_isTerminated || state != AppLifecycleState.resumed) return;

    return _executeOrQueue(
      operation: () async {
        Map<String, Object?> sendData = {
          'type': WebViewBridgeFeatureType.appStateChange.value,
          'data': {'state': state.name},
        };
        await _channel!.runJavaScriptAppState(jsonEncode(sendData));
      },
    );
  }

  Future<void> runJavaScriptReturningResultAppState(AppLifecycleState state) {
    return runJavaScriptAppState(state);
  }

  Future<void> runJavaScriptReturningResultPostMessage(
    Map<String, Object?> sendData,
  ) async {
    if (_isTerminated) return;

    return _executeOrQueue(
      operation: () async {
        await _channel!.runJavaScriptPostMessage(jsonEncode(sendData));
      },
    );
  }

  Future<void> runJavaScriptSetPushToken(
    String token, {
    required bool isRefresh,
  }) async {
    if (_isTerminated) return;

    return _executeOrQueue(
      operation: () async {
        Map<String, Object?> sendData = {
          'type': WebViewBridgeFeatureType.pushToken.value,
          'data': {
            'token': token,
            'platform': Platform.isIOS ? 'ios' : 'android',
            'isRefresh': isRefresh,
            // APP-300 R6: 푸시 country segmentation (서버 등록 시 활용). KR 기본값.
            'serviceCountry': _serviceCountry ?? 'KR',
          },
        };
        await _channel!.runJavaScriptPostMessage(jsonEncode(sendData));
      },
    );
  }

  Future<T> _executeOrQueue<T>({
    required Future<T> Function() operation,
  }) async {
    if (_isTerminated) {
      throw StateError('WebViewBridgeController is terminated');
    }

    if (_channel == null) {
      final completer = Completer<T>();
      _requestQueue.add(
        _QueuedRequest(operation: operation, completer: completer),
      );
      await _waitForInitialization();
      return completer.future;
    }
    return operation();
  }

  Future<void> _waitForInitialization() async {
    if (_channel != null) return;
    _initCompleter ??= Completer<void>();
    await _initCompleter!.future;
  }

  void _completeInitialization() {
    final initCompleter = _initCompleter;
    if (initCompleter != null && !initCompleter.isCompleted) {
      initCompleter.complete();
    }
  }

  Future<void> _processQueue() async {
    while (_requestQueue.isNotEmpty) {
      final request = _requestQueue.removeFirst();
      try {
        if (_isTerminated) {
          throw StateError('WebViewBridgeController is terminated');
        }
        final result = await request.operation();
        request.completer.complete(result);
      } catch (error) {
        request.completer.completeError(error);
      }
    }
  }

  bool get isInitialized => _channel != null;
  int get queueLength => _requestQueue.length;

  /// MainScreen rebuild 시 호출되는 default dispose. 큐는 보존하여
  /// 다음 [initFlutterWebViewBridgeJavaScriptChannel] 호출에서
  /// 새 [WebViewController] 로 in-flight 요청이 dispatch 되도록 한다.
  ///
  /// 앱 종료/MainScreen 영구 teardown 같이 다시 init 되지 않는 시점에는
  /// [forceTerminate]=true 를 명시해 큐의 Completer 들을 error 로 종결할 것.
  void dispose({bool forceTerminate = false}) {
    // SSO hang watchdog 정리 — 채널 teardown 후 stale controller reload 방지.
    _channel?.dispose();
    if (forceTerminate) {
      _isTerminated = true;
      while (_requestQueue.isNotEmpty) {
        _requestQueue.removeFirst().completer.completeError(
          Exception(
            'WebViewBridgeController disposed before request could be processed',
          ),
        );
      }
      final initCompleter = _initCompleter;
      if (initCompleter != null && !initCompleter.isCompleted) {
        initCompleter.completeError(
          Exception('WebViewBridgeController terminated before initialization'),
        );
      }
    }
    _channel = null;
    if (forceTerminate || _requestQueue.isEmpty) {
      _initCompleter = null;
    }
  }
}

////////////////////////////////////////////////////////////////////////////////

class _QueuedRequest {
  final Future Function() operation;
  final Completer completer;

  _QueuedRequest({required this.operation, required this.completer});
}
