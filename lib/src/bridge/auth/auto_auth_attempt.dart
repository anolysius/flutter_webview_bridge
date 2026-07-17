const autoAuthProvider = 'AUTO_REFRESH';

/// bridge instance의 첫 v2 refresh-token read를 독립 자동 로그인 시도로 승격한다.
///
/// 앱 프로세스가 살아 있는 동안 발생하는 WebContent reload/replay는 새 자동 로그인
/// 시도가 아니다. 반대로 앱 강제 종료 뒤 생성된 새 bridge instance의 첫 token read는
/// 새 attempt ID를 받아 현재 UI 수렴을 다시 계측한다.
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
    }
  }

  void clearActiveAttempt() {
    _activeAttemptId = null;
  }
}
