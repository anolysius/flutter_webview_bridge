import 'dart:async';
import 'dart:collection';

const webAuthContextProtocolVersion = 1;

bool supportsWebAuthContextProtocol(Object? data) {
  if (data is! Map) return false;
  final version = data['authContextProtocolVersion'];
  return version is int && version >= webAuthContextProtocolVersion;
}

String normalizeServiceCountry(String? value) =>
    value == 'GLOBAL' ? 'GLOBAL' : 'KR';

String domainTypeForServiceCountry(String? value) =>
    normalizeServiceCountry(value) == 'GLOBAL'
    ? 'sazo-global-shop'
    : 'sazo-korea-shop';

String? apiBaseUrlForServiceCountry({
  required String? apiBaseUrl,
  required String? serviceCountry,
}) {
  if (apiBaseUrl == null || apiBaseUrl.trim().isEmpty) return apiBaseUrl;
  final uri = Uri.tryParse(apiBaseUrl);
  final host = uri?.host.toLowerCase();
  if (uri == null || host == null || host.isEmpty) return apiBaseUrl;

  final country = normalizeServiceCountry(serviceCountry);
  const krSuffix = 'sazo.kr';
  const globalSuffix = 'sazoshop.com';
  String replaceSuffix(String value, String from, String to) => value == from
      ? to
      : '${value.substring(0, value.length - from.length)}$to';

  if (country == 'KR' &&
      (host == globalSuffix || host.endsWith('.$globalSuffix'))) {
    return uri
        .replace(host: replaceSuffix(host, globalSuffix, krSuffix))
        .toString();
  }
  if (country == 'GLOBAL' &&
      (host == krSuffix || host.endsWith('.$krSuffix'))) {
    return uri
        .replace(host: replaceSuffix(host, krSuffix, globalSuffix))
        .toString();
  }
  return apiBaseUrl;
}

bool shouldRejectRetiredAuthMessage({
  required bool isAuthMutation,
  required bool isRetiredDocument,
  required bool hasOwnedExplicitRetry,
}) => isAuthMutation && isRetiredDocument && !hasOwnedExplicitRetry;

/// SAZO 운영/QA API host가 service country와 반대로 결합되는 것을 차단한다.
///
/// localhost·개발 프록시·null은 기존 개발/fallback 경로를 보존한다. 반면 알려진 KR/Global
/// 운영 domain끼리의 교차 결합은 token exchange 전에 즉시 실패시킨다.
void validateServiceAuthContextPair({
  required String? serviceCountry,
  required String? apiBaseUrl,
}) {
  if (apiBaseUrl == null || apiBaseUrl.trim().isEmpty) return;

  final uri = Uri.tryParse(apiBaseUrl);
  final host = uri?.host.toLowerCase() ?? '';
  if (host.isEmpty) return;

  final isKrApi = host == 'sazo.kr' || host.endsWith('.sazo.kr');
  final isGlobalApi = host == 'sazoshop.com' || host.endsWith('.sazoshop.com');
  final country = normalizeServiceCountry(serviceCountry);
  final mismatched =
      (country == 'KR' && isGlobalApi) || (country == 'GLOBAL' && isKrApi);
  if (mismatched) {
    throw ArgumentError.value(
      apiBaseUrl,
      'apiBaseUrl',
      'API host does not match serviceCountry=$country',
    );
  }
}

/// Native SSO/refresh가 어느 인증 realm을 대상으로 실행되는지 고정하는 불변 컨텍스트.
///
/// 국가 전환 중 mutable field를 다시 읽으면 이전 HTTP 결과를 새 국가 token key에 저장할 수
/// 있으므로, 모든 async 인증 작업은 시작 시 이 값을 snapshot하고 부수효과 직전에 재검증한다.
class ServiceAuthContext {
  const ServiceAuthContext({
    required this.serviceCountry,
    required this.apiBaseUrl,
    required this.generation,
  });

  final String serviceCountry;
  final String? apiBaseUrl;
  final int generation;

  String get domainType => domainTypeForServiceCountry(serviceCountry);

  bool matches(ServiceAuthContext other) =>
      serviceCountry == other.serviceCountry &&
      apiBaseUrl == other.apiBaseUrl &&
      generation == other.generation;

  ServiceAuthContext next({
    required String? serviceCountry,
    required String? apiBaseUrl,
  }) {
    validateServiceAuthContextPair(
      serviceCountry: serviceCountry,
      apiBaseUrl: apiBaseUrl,
    );
    return ServiceAuthContext(
      serviceCountry: normalizeServiceCountry(serviceCountry),
      apiBaseUrl: apiBaseUrl,
      generation: generation + 1,
    );
  }
}

class AuthWorkContextSnapshot {
  const AuthWorkContextSnapshot({
    required this.authEpoch,
    required this.authRevision,
    required this.service,
  });

  final int authEpoch;
  final int authRevision;
  final ServiceAuthContext service;

  bool matches({
    required int authEpoch,
    required int authRevision,
    required ServiceAuthContext service,
    required bool transitionInProgress,
  }) =>
      !transitionInProgress &&
      this.authEpoch == authEpoch &&
      this.authRevision == authRevision &&
      this.service.matches(service);
}

/// 실제 async 인증 파이프라인이 snapshot 경계를 일관되게 재검증하는 fence.
///
/// bridge의 device headers/exchange/persist/me/cache/delivery 단계가 이 fence를
/// 공유하므로 최초 stale 지점에서 trace를 정확히 한 번 남기고 이후 부수효과를 막는다.
class AuthContextWorkFence {
  AuthContextWorkFence({
    required this.snapshot,
    required bool Function(AuthWorkContextSnapshot snapshot) isCurrent,
    required void Function(String stage) onStale,
  }) : _isCurrent = isCurrent,
       _onStale = onStale;

  final AuthWorkContextSnapshot snapshot;
  final bool Function(AuthWorkContextSnapshot snapshot) _isCurrent;
  final void Function(String stage) _onStale;
  bool _staleReported = false;

  bool get canMutate => !_staleReported && _isCurrent(snapshot);

  bool checkpoint(String stage) {
    if (_staleReported) return false;
    if (_isCurrent(snapshot)) return true;
    _staleReported = true;
    _onStale(stage);
    return false;
  }
}

/// service context를 snapshot한 비동기 작업은 snapshot 국가에서만 실행하고,
/// await 중 국가 전환이 시작되면 반환값을 현재 상태에 적용하지 않는다.
Future<T?> runGuardedServiceAuthOperation<T>({
  required AuthContextWorkFence fence,
  required String staleStage,
  required Future<T> Function(String serviceCountry) operation,
}) async {
  final result = await operation(fence.snapshot.service.serviceCountry);
  return fence.checkpoint(staleStage) ? result : null;
}

/// service boundary 전에 활성화된 WebView document의 늦은 mutation을 식별한다.
///
/// documentId는 web document마다 무작위로 생성되므로 최근 invalidated ID만 bounded하게
/// 기억하면 fence 해제 뒤 도착한 old-document write/delete를 새 국가 저장소에 적용하지
/// 않을 수 있다.
class AuthDocumentBoundary {
  AuthDocumentBoundary({this.maxInvalidatedDocuments = 64});

  final int maxInvalidatedDocuments;
  final LinkedHashSet<String> _invalidated = LinkedHashSet<String>();

  void invalidate(String? documentId) {
    final normalized = _normalize(documentId);
    if (normalized == null) return;
    _invalidated
      ..remove(normalized)
      ..add(normalized);
    while (_invalidated.length > maxInvalidatedDocuments) {
      _invalidated.remove(_invalidated.first);
    }
  }

  bool rejects(String? documentId) {
    final normalized = _normalize(documentId);
    return normalized != null && _invalidated.contains(normalized);
  }

  static String? _normalize(String? value) {
    final normalized = value?.trim();
    return normalized == null || normalized.isEmpty ? null : normalized;
  }
}

enum AuthContextOperationOutcome { inProgress, succeeded, failed }

enum AuthContextRecoveryResult { restartAccepted, restartFailed }

enum AuthContextExplicitRetryAction {
  reopenTransition,
  continueWithCurrentContext,
}

enum AuthContextExplicitRetryCleanupResult { ready, failed, superseded }

class _AuthContextTerminalFailure {
  const _AuthContextTerminalFailure({
    required this.contextGeneration,
    required this.retryDocumentId,
  });

  final int contextGeneration;
  final String? retryDocumentId;
}

class _AuthContextOperationEntry {
  const _AuthContextOperationEntry({
    required this.recordedAt,
    required this.outcome,
  });

  final DateTime recordedAt;
  final AuthContextOperationOutcome outcome;
}

/// auth-context status/restart의 idempotency key를 bounded TTL로 기억한다.
///
/// restart 실패도 terminal outcome으로 보존해 동일 메시지가 재전달되더라도 cleanup을
/// 다시 실행하지 않고 동일한 `restartFailed` ACK를 반환할 수 있게 한다.
class AuthContextOperationRegistry {
  AuthContextOperationRegistry({
    this.maxEntries = 32,
    this.ttl = const Duration(minutes: 5),
    DateTime Function()? now,
  }) : _now = now ?? DateTime.now;

  final int maxEntries;
  final Duration ttl;
  final DateTime Function() _now;
  final LinkedHashMap<String, _AuthContextOperationEntry> _entries =
      LinkedHashMap<String, _AuthContextOperationEntry>();

  bool begin(String? key) {
    final normalized = _normalize(key);
    if (normalized == null) return true;
    _prune();
    if (_entries.containsKey(normalized)) return false;
    _entries[normalized] = _AuthContextOperationEntry(
      recordedAt: _now(),
      outcome: AuthContextOperationOutcome.inProgress,
    );
    while (_entries.length > maxEntries) {
      _entries.remove(_entries.keys.first);
    }
    return true;
  }

  void complete(String? key, {required bool succeeded}) {
    final normalized = _normalize(key);
    if (normalized == null || !_entries.containsKey(normalized)) return;
    _entries[normalized] = _AuthContextOperationEntry(
      recordedAt: _now(),
      outcome: succeeded
          ? AuthContextOperationOutcome.succeeded
          : AuthContextOperationOutcome.failed,
    );
  }

  AuthContextOperationOutcome? outcome(String? key) {
    final normalized = _normalize(key);
    if (normalized == null) return null;
    _prune();
    return _entries[normalized]?.outcome;
  }

  void _prune() {
    final current = _now();
    _entries.removeWhere(
      (_, entry) => current.difference(entry.recordedAt) > ttl,
    );
  }

  static String? _normalize(String? value) {
    final normalized = value?.trim();
    return normalized == null || normalized.isEmpty ? null : normalized;
  }
}

/// mismatch credential cleanup과 controlled restart 순서를 한 곳에서 고정한다.
///
/// 동일 idempotency key의 중복은 성공·실패 모두 최초 결과를 재사용하며 어떤
/// cleanup/restart 부수효과도 다시 실행하지 않는다.
class AuthContextRecoveryCoordinator {
  AuthContextRecoveryCoordinator({AuthContextOperationRegistry? registry})
    : _registry = registry ?? AuthContextOperationRegistry();

  final AuthContextOperationRegistry _registry;
  final Map<String, Future<AuthContextRecoveryResult>> _inFlight =
      <String, Future<AuthContextRecoveryResult>>{};
  _AuthContextTerminalFailure? _terminalFailure;
  bool _recoveryAttemptConsumed = false;

  Future<AuthContextRecoveryResult> run({
    required String? idempotencyKey,
    String? retryDocumentId,
    required int Function() currentContextGeneration,
    required FutureOr<void> Function() onRestarting,
    required bool Function() beginTransition,
    required Future<void> Function() clearTokens,
    required void Function() clearTransient,
    required bool Function() completeTransition,
    required FutureOr<void> Function() restart,
    required FutureOr<void> Function() onFailure,
  }) {
    final normalizedKey = _normalizeKey(idempotencyKey);
    final existing = normalizedKey == null ? null : _inFlight[normalizedKey];
    if (existing != null) return existing;

    if (!_registry.begin(idempotencyKey)) {
      return Future<AuthContextRecoveryResult>.value(
        _registry.outcome(idempotencyKey) == AuthContextOperationOutcome.failed
            ? AuthContextRecoveryResult.restartFailed
            : AuthContextRecoveryResult.restartAccepted,
      );
    }
    if (_recoveryAttemptConsumed) {
      return _rejectRepeatedRecovery(
        idempotencyKey: idempotencyKey,
        onFailure: onFailure,
      );
    }
    _recoveryAttemptConsumed = true;

    final operation = _runFirst(
      idempotencyKey: idempotencyKey,
      retryDocumentId: retryDocumentId,
      currentContextGeneration: currentContextGeneration,
      onRestarting: onRestarting,
      beginTransition: beginTransition,
      clearTokens: clearTokens,
      clearTransient: clearTransient,
      completeTransition: completeTransition,
      restart: restart,
      onFailure: onFailure,
    );
    if (normalizedKey != null) {
      _inFlight[normalizedKey] = operation;
      operation.whenComplete(() {
        if (identical(_inFlight[normalizedKey], operation)) {
          _inFlight.remove(normalizedKey);
        }
      });
    }
    return operation;
  }

  /// terminal failure는 실패가 발생한 service generation에서만 소비한다.
  ///
  /// 다른 국가 전환이 먼저 시작돼 generation이 바뀌면 오래된 실패 표시는 폐기해,
  /// 이후 provider 입력이 무관한 transition fence를 열지 못하게 한다.
  AuthContextExplicitRetryAction? consumeTerminalFailureForExplicitRetry({
    required int currentContextGeneration,
    required bool transitionInProgress,
    String? retryDocumentId,
  }) {
    final failure = _terminalFailure;
    if (failure == null) return null;
    if (failure.contextGeneration != currentContextGeneration) {
      _terminalFailure = null;
      return null;
    }
    if (failure.retryDocumentId != null &&
        failure.retryDocumentId != retryDocumentId) {
      return null;
    }
    _terminalFailure = null;
    return transitionInProgress
        ? AuthContextExplicitRetryAction.reopenTransition
        : AuthContextExplicitRetryAction.continueWithCurrentContext;
  }

  /// clear 실패로 닫힌 fence를 다시 열기 전에 양쪽 token cleanup을 재시도한다.
  ///
  /// [clearTokens]는 양쪽 key absent를 검증한 뒤에만 성공해야 한다. 재실패하면 같은
  /// generation의 terminal retry 권한을 복구하고, 다른 transition이 선점했으면 조용히
  /// superseded 처리해 그 fence를 열지 않는다.
  Future<AuthContextExplicitRetryCleanupResult> retryCleanupForExplicitRetry({
    required int contextGeneration,
    String? retryDocumentId,
    required bool Function() isCurrentTransition,
    required Future<void> Function() clearTokens,
    required void Function() clearTransient,
  }) async {
    try {
      await clearTokens();
    } catch (_) {
      if (isCurrentTransition()) {
        _terminalFailure = _AuthContextTerminalFailure(
          contextGeneration: contextGeneration,
          retryDocumentId: retryDocumentId,
        );
        return AuthContextExplicitRetryCleanupResult.failed;
      }
      return AuthContextExplicitRetryCleanupResult.superseded;
    }
    if (!isCurrentTransition()) {
      return AuthContextExplicitRetryCleanupResult.superseded;
    }
    clearTransient();
    return AuthContextExplicitRetryCleanupResult.ready;
  }

  void beginExplicitAuthAttempt() {
    _recoveryAttemptConsumed = false;
  }

  Future<AuthContextRecoveryResult> _rejectRepeatedRecovery({
    required String? idempotencyKey,
    required FutureOr<void> Function() onFailure,
  }) async {
    _registry.complete(idempotencyKey, succeeded: false);
    try {
      await onFailure();
    } catch (_) {
      // failure ACK/trace delivery remains authoritative.
    }
    return AuthContextRecoveryResult.restartFailed;
  }

  Future<AuthContextRecoveryResult> _runFirst({
    required String? idempotencyKey,
    required String? retryDocumentId,
    required int Function() currentContextGeneration,
    required FutureOr<void> Function() onRestarting,
    required bool Function() beginTransition,
    required Future<void> Function() clearTokens,
    required void Function() clearTransient,
    required bool Function() completeTransition,
    required FutureOr<void> Function() restart,
    required FutureOr<void> Function() onFailure,
  }) async {
    int? ownedContextGeneration;
    try {
      try {
        await onRestarting();
      } catch (_) {
        // UI gate callback failure must not skip credential cleanup.
      }
      if (!beginTransition()) {
        _registry.complete(idempotencyKey, succeeded: true);
        _terminalFailure = null;
        _recoveryAttemptConsumed = false;
        return AuthContextRecoveryResult.restartAccepted;
      }
      ownedContextGeneration = currentContextGeneration();
      await clearTokens();
      clearTransient();
      if (!completeTransition()) {
        _registry.complete(idempotencyKey, succeeded: true);
        _terminalFailure = null;
        _recoveryAttemptConsumed = false;
        return AuthContextRecoveryResult.restartAccepted;
      }
      ownedContextGeneration = currentContextGeneration();
      await restart();
      _registry.complete(idempotencyKey, succeeded: true);
      _terminalFailure = null;
      return AuthContextRecoveryResult.restartAccepted;
    } catch (_) {
      _registry.complete(idempotencyKey, succeeded: false);
      final failureGeneration = currentContextGeneration();
      _terminalFailure =
          ownedContextGeneration != null &&
              ownedContextGeneration == failureGeneration
          ? _AuthContextTerminalFailure(
              contextGeneration: failureGeneration,
              retryDocumentId: retryDocumentId,
            )
          : null;
      try {
        await onFailure();
      } catch (_) {
        // failure ACK/trace delivery remains authoritative.
      }
      return AuthContextRecoveryResult.restartFailed;
    }
  }

  static String? _normalizeKey(String? value) {
    final normalized = value?.trim();
    return normalized == null || normalized.isEmpty ? null : normalized;
  }
}
