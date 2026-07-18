import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

const _pendingAuthAttemptKey = 'flutter_webview_bridge_pending_auth_attempt_v2';

String _scopedPendingAuthAttemptKey(String? serviceCountry) {
  if (serviceCountry == null || serviceCountry == 'KR') {
    return _pendingAuthAttemptKey;
  }
  return '${_pendingAuthAttemptKey}__${serviceCountry.toLowerCase()}';
}

final String authProcessInstanceId =
    'auth-process-${DateTime.now().microsecondsSinceEpoch}';

class PendingAuthAttempt {
  const PendingAuthAttempt({
    required this.attemptId,
    required this.authRevision,
    required this.provider,
    required this.protocolVersion,
    required this.startedAt,
    required this.processInstanceId,
    this.requestId,
    this.documentId,
  });

  final String attemptId;
  final int authRevision;
  final String provider;
  final int protocolVersion;
  final DateTime startedAt;
  final String processInstanceId;
  final String? requestId;
  final String? documentId;

  Map<String, Object?> toJson() => {
    'attemptId': attemptId,
    'authRevision': authRevision,
    'provider': provider,
    'protocolVersion': protocolVersion,
    'startedAt': startedAt.toUtc().toIso8601String(),
    'processInstanceId': processInstanceId,
    if (requestId != null) 'requestId': requestId,
    if (documentId != null) 'documentId': documentId,
  };

  static PendingAuthAttempt? fromJson(Object? value) {
    if (value is! Map) return null;
    final attemptId = value['attemptId'];
    final authRevision = value['authRevision'];
    final provider = value['provider'];
    final protocolVersion = value['protocolVersion'];
    final startedAt = DateTime.tryParse(value['startedAt']?.toString() ?? '');
    final processInstanceId = value['processInstanceId'];
    if (attemptId is! String ||
        attemptId.isEmpty ||
        authRevision is! int ||
        provider is! String ||
        provider.isEmpty ||
        protocolVersion is! int ||
        startedAt == null ||
        processInstanceId is! String ||
        processInstanceId.isEmpty) {
      return null;
    }
    return PendingAuthAttempt(
      attemptId: attemptId,
      authRevision: authRevision,
      provider: provider,
      protocolVersion: protocolVersion,
      startedAt: startedAt.toUtc(),
      processInstanceId: processInstanceId,
      requestId: value['requestId'] is String
          ? value['requestId'] as String
          : null,
      documentId: value['documentId'] is String
          ? value['documentId'] as String
          : null,
    );
  }
}

/// Provider UI 진입 전에 interactive attempt를 영속화해 process 강제 종료를 회수한다.
///
/// 모든 read-modify-write를 직렬화해 이전 terminal clear가 새 attempt를 지우지 않게 한다.
class PendingAuthAttemptStore {
  const PendingAuthAttemptStore();

  static Future<void> _serial = Future<void>.value();

  Future<T> _serialized<T>(Future<T> Function() operation) {
    late Future<T> result;
    result = _serial.then((_) => operation());
    _serial = result.then<void>((_) {}, onError: (Object _, StackTrace __) {});
    return result;
  }

  Future<void> markStarted({
    required PendingAuthAttempt attempt,
    String? serviceCountry,
  }) => _serialized(() async {
    final prefs = await SharedPreferences.getInstance();
    final key = _scopedPendingAuthAttemptKey(serviceCountry);
    final stored = await prefs.setString(key, jsonEncode(attempt.toJson()));
    if (!stored) throw StateError('Failed to persist pending auth attempt');
  });

  /// 현재 process에서 만든 attempt는 WebView 재생성일 수 있으므로 회수하지 않는다.
  /// 이전 process의 값만 원자적으로 take해 다음 실행에서 terminal을 한 번만 방출한다.
  Future<PendingAuthAttempt?> takeInterrupted({
    required String currentProcessInstanceId,
    String? serviceCountry,
  }) => _serialized(() async {
    final prefs = await SharedPreferences.getInstance();
    final key = _scopedPendingAuthAttemptKey(serviceCountry);
    final raw = prefs.getString(key);
    if (raw == null) return null;

    PendingAuthAttempt? pending;
    try {
      pending = PendingAuthAttempt.fromJson(jsonDecode(raw));
    } catch (_) {
      pending = null;
    }
    if (pending == null) {
      await prefs.remove(key);
      return null;
    }
    if (pending.processInstanceId == currentProcessInstanceId) return null;

    final removed = await prefs.remove(key);
    if (!removed) throw StateError('Failed to consume pending auth attempt');
    return pending;
  });

  Future<void> clearIfMatches({
    required String attemptId,
    required int authRevision,
    String? serviceCountry,
  }) => _serialized(() async {
    final prefs = await SharedPreferences.getInstance();
    final key = _scopedPendingAuthAttemptKey(serviceCountry);
    final raw = prefs.getString(key);
    if (raw == null) return;

    PendingAuthAttempt? pending;
    try {
      pending = PendingAuthAttempt.fromJson(jsonDecode(raw));
    } catch (_) {
      pending = null;
    }
    if (pending == null) {
      await prefs.remove(key);
      return;
    }
    if (pending.attemptId != attemptId ||
        pending.authRevision != authRevision) {
      return;
    }
    await prefs.remove(key);
  });
}
