import 'package:shared_preferences/shared_preferences.dart';

const kAuthSuccessRevisionKey =
    'flutter_webview_bridge_auth_success_revision_v2';
const kAuthSuccessAttemptKey = 'flutter_webview_bridge_auth_success_attempt_v2';

String _scopedAuthTerminalKey(String key, String? serviceCountry) {
  if (serviceCountry == null || serviceCountry == 'KR') return key;
  return '${key}__${serviceCountry.toLowerCase()}';
}

String authTerminalKey({
  required String? authSessionId,
  required int authRevision,
}) => '${authSessionId ?? 'revision-only'}:$authRevision';

/// 마지막으로 UI까지 수렴한 인증 시도를 앱 재시작 너머에서도 식별한다.
///
/// auth revision은 네이티브가 단조 증가시키므로 국가별 최신 성공 1건만 보관하면
/// 이전 시도의 늦은 메시지와 현재 인증 상태를 안전하게 구분할 수 있다.
class AuthTerminalStore {
  const AuthTerminalStore();

  Future<bool> matchesSuccess({
    required String? authSessionId,
    required int authRevision,
    String? serviceCountry,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final revision = prefs.getInt(
      _scopedAuthTerminalKey(kAuthSuccessRevisionKey, serviceCountry),
    );
    if (revision != authRevision) return false;

    final storedAttempt = prefs.getString(
      _scopedAuthTerminalKey(kAuthSuccessAttemptKey, serviceCountry),
    );
    // 자동 로그인/새 document의 REFRESH_TOKEN_READ에는 attempt id가 없을 수 있다.
    // 동일 native revision이면 새로운 로그인 시도가 아니므로 이미 수렴한 상태다.
    return storedAttempt == null ||
        authSessionId == null ||
        storedAttempt == authSessionId;
  }

  Future<void> markSuccess({
    required String? authSessionId,
    required int authRevision,
    String? serviceCountry,
  }) async {
    final prefs = await SharedPreferences.getInstance();
    final attemptKey = _scopedAuthTerminalKey(
      kAuthSuccessAttemptKey,
      serviceCountry,
    );
    final revisionKey = _scopedAuthTerminalKey(
      kAuthSuccessRevisionKey,
      serviceCountry,
    );

    // revision을 마지막에 써서 부분 저장이 최신 성공처럼 보이지 않게 한다.
    final attemptStored = authSessionId == null
        ? await prefs.remove(attemptKey)
        : await prefs.setString(attemptKey, authSessionId);
    final revisionStored = await prefs.setInt(revisionKey, authRevision);
    if (!attemptStored ||
        !revisionStored ||
        prefs.getInt(revisionKey) != authRevision ||
        (authSessionId != null &&
            prefs.getString(attemptKey) != authSessionId)) {
      throw StateError('Failed to persist auth terminal success');
    }
  }
}
