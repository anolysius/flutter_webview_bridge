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
    return nextIfCurrent(
      serviceCountry: serviceCountry,
      isCurrent: () => true,
    ).then((revision) => revision!);
  }

  /// 직렬화 대기 중 이미 superseded 된 인증 작업은 SharedPreferences I/O를 생략한다.
  ///
  /// 취소된 클릭도 FIFO에 남아 최신 로그인까지 수 초간 막던 starvation을 방지한다.
  /// 저장 직전에 한 번 더 검사하여 앞선 작업을 기다리는 동안의 선점도 흡수한다.
  Future<int?> nextIfCurrent({
    String? serviceCountry,
    required bool Function() isCurrent,
  }) {
    late int nextRevision;
    final operation = _nextSerial.then((_) async {
      if (!isCurrent()) return false;
      final prefs = await SharedPreferences.getInstance();
      if (!isCurrent()) return false;
      final key = authRevisionKeyFor(serviceCountry);
      nextRevision = (prefs.getInt(key) ?? 0) + 1;
      final stored = await prefs.setInt(key, nextRevision);
      if (!stored || prefs.getInt(key) != nextRevision) {
        throw StateError('Failed to persist auth revision');
      }
      return true;
    });
    _nextSerial = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return operation.then((stored) => stored ? nextRevision : null);
  }
}
