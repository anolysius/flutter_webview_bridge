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
  }) {
    _channel ??= FlutterWebViewBridgeJavaScriptChannel(
      context: context,
      webViewController: webViewController,
      googleServerClientId: googleServerClientId,
      kakaoNativeAppKey: kakaoNativeAppKey,
    );
    _channel?.addJavaScriptChannel();

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

  void dispose() {
    while (_requestQueue.isNotEmpty) {
      _requestQueue.removeFirst().completer.completeError(
        Exception(
          'WebViewBridgeController disposed before request could be processed',
        ),
      );
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
