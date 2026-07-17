const autoAuthProvider = 'AUTO_REFRESH';

/// coordinator가 허용한 첫 v2 refresh-token read를 독립 자동 로그인 시도로 승격한다.
///
/// process-wide 1회 게이트와 interactive 우선권은
/// ProcessAuthAttemptCoordinator가 담당하고, 이 객체는 현재 bridge의 attempt ID 결합만
/// 담당한다. 앱 프로세스가 살아 있는 동안 발생하는 WebContent reload/replay는 새 자동
/// 로그인 시도가 아니다.
class AutoAuthAttemptController {
  bool _initialV2RefreshObserved = false;
  String? _activeAttemptId;

  String? get activeAttemptId => _activeAttemptId;

  String? effectiveAttemptId({
    required String? messageAttemptId,
    required String? activeAttemptId,
  }) => _activeAttemptId ?? messageAttemptId ?? activeAttemptId;

  String? beginInitialRefresh({
    required dynamic requestData,
    required Map<String, Object?> readResponse,
    required bool interactiveAttemptActive,
    required int fallbackNonce,
  }) {
    final isV2 = requestData is Map && requestData['protocolVersion'] == 2;
    if (!isV2) return null;

    if (_initialV2RefreshObserved) return null;
    _initialV2RefreshObserved = true;

    final responseData = readResponse['data'];
    final refreshToken = responseData is Map
        ? responseData['refreshToken'] as String?
        : null;
    if (interactiveAttemptActive ||
        refreshToken == null ||
        refreshToken.isEmpty) {
      return null;
    }

    final requestId = requestData['requestId'] as String?;
    _activeAttemptId = 'auto-auth-${requestId ?? fallbackNonce}';
    return _activeAttemptId;
  }

  void bindToResponse(Map<String, Object?> response) {
    final attemptId = _activeAttemptId;
    if (attemptId == null) return;
    final responseData = response['data'];
    if (responseData is Map) {
      responseData['authSessionId'] = attemptId;
      responseData['provider'] = autoAuthProvider;
    }
  }

  void clearActiveAttempt() {
    _activeAttemptId = null;
  }

  /// origin/service-country 전환은 같은 process 안에서도 새로운 auth bootstrap이다.
  void resetForAuthBoundary() {
    _initialV2RefreshObserved = false;
    _activeAttemptId = null;
  }
}
