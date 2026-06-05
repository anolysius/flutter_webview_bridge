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

  void initFlutterWebViewBridgeJavaScriptChannel(
    BuildContext context,
    WebViewController webViewController, {
    required String? googleServerClientId,
    required String? kakaoNativeAppKey,
    String? apiBaseUrl,
    String? serviceCountry,
    void Function(String requestedCountry)? onServiceCountryChange,
  }) {
    if (_channel != null) {
      // WebView 재생성 시 channel handler 는 유지, controller 만 swap.
      // addJavaScriptChannel 중복 호출은 stale handler 위험만 키우므로 회피.
      _channel!.updateWebViewController(webViewController, newContext: context);
      _initCompleter?.complete();
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
    _channel!.addJavaScriptChannel();

    _initCompleter?.complete();

    _processQueue();
  }

  Future<Object?> runJavaScriptReturningResultAppState(
    AppLifecycleState state,
  ) async {
    return _executeOrQueue(
      operation: () {
        Map<String, Object?> sendData = {
          'type': WebViewBridgeFeatureType.appStateChange.value,
          'data': {'state': state.name},
        };
        return _channel!.runJavaScriptReturningResultAppState(
          jsonEncode(sendData),
        );
      },
    );
  }

  Future<void> runJavaScriptReturningResultPostMessage(
    Map<String, Object?> sendData,
  ) async {
    return _executeOrQueue(
      operation: () async {
        await _channel!.runJavaScriptReturningResultPostMessage(
          jsonEncode(sendData),
        );
      },
    );
  }

  Future<void> runJavaScriptSetPushToken(
    String token, {
    required bool isRefresh,
  }) async {
    return _executeOrQueue(
      operation: () async {
        Map<String, Object?> sendData = {
          'type': WebViewBridgeFeatureType.pushToken.value,
          'data': {
            'token': token,
            'platform': Platform.isIOS ? 'ios' : 'android',
            'isRefresh': isRefresh,
          },
        };
        await _channel!.runJavaScriptReturningResultPostMessage(
          jsonEncode(sendData),
        );
      },
    );
  }

  Future<T> _executeOrQueue<T>({
    required Future<T> Function() operation,
  }) async {
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

  Future<void> _processQueue() async {
    while (_requestQueue.isNotEmpty) {
      final request = _requestQueue.removeFirst();
      try {
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
    _channel?.cancelSsoWatchdog('controller-dispose');
    if (forceTerminate) {
      while (_requestQueue.isNotEmpty) {
        _requestQueue.removeFirst().completer.completeError(
          Exception(
            'WebViewBridgeController disposed before request could be processed',
          ),
        );
      }
    }
    _channel = null;
    _initCompleter = null;
  }
}

////////////////////////////////////////////////////////////////////////////////

class _QueuedRequest {
  final Future Function() operation;
  final Completer completer;

  _QueuedRequest({required this.operation, required this.completer});
}
