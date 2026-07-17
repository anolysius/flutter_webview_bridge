import 'package:shared_preferences/shared_preferences.dart';

const kAuthRevisionKey = 'flutter_webview_bridge_auth_revision_v2';

String authRevisionKeyFor(String? serviceCountry) {
  if (serviceCountry == null || serviceCountry == 'KR') {
    return kAuthRevisionKey;
  }
  return '${kAuthRevisionKey}__${serviceCountry.toLowerCase()}';
}

/// refresh-token read가 await 하는 동안 서비스 국가/인증 경계가 바뀌었는지 판별한다.
class AuthRevisionReadSnapshot {
  const AuthRevisionReadSnapshot({
    required this.epoch,
    required this.serviceCountry,
  });

  final int epoch;
  final String? serviceCountry;

  bool matches({required int epoch, required String? serviceCountry}) =>
      this.epoch == epoch && this.serviceCountry == serviceCountry;
}

/// 일반 bootstrap은 대상 국가의 저장 revision을 정확히 채택한다.
/// 현재 interactive 로그인 수렴 중인 새 document read만 진행 중 revision을 보존한다.
int resolveRefreshAuthRevision({
  required int activeRevision,
  required int storedRevision,
  required bool preserveInteractiveAttempt,
}) => preserveInteractiveAttempt ? activeRevision : storedRevision;

/// Native가 소유하는 단조 증가 auth revision.
///
/// 로그인/명시적 logout 시작 전에 증가·검증 저장하며 앱 재시작 뒤에도 감소하지 않는다.
class AuthRevisionStore {
  const AuthRevisionStore();

  /// SharedPreferences의 read-modify-write는 자체적으로 원자적이지 않다.
  /// 여러 bridge instance가 동시에 next()를 호출해도 process 안에서는 반드시 직렬화한다.
  static Future<void> _nextSerial = Future<void>.value();

  Future<int> current({String? serviceCountry}) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(authRevisionKeyFor(serviceCountry)) ?? 0;
  }

  Future<int> next({String? serviceCountry}) {
    late int nextRevision;
    final operation = _nextSerial.then((_) async {
      final prefs = await SharedPreferences.getInstance();
      final key = authRevisionKeyFor(serviceCountry);
      nextRevision = (prefs.getInt(key) ?? 0) + 1;
      final stored = await prefs.setInt(key, nextRevision);
      if (!stored || prefs.getInt(key) != nextRevision) {
        throw StateError('Failed to persist auth revision');
      }
    });
    _nextSerial = operation.catchError((_) {});
    return operation.then((_) => nextRevision);
  }
}
