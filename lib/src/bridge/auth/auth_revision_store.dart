import 'package:shared_preferences/shared_preferences.dart';

const kAuthRevisionKey = 'flutter_webview_bridge_auth_revision_v2';

String authRevisionKeyFor(String? serviceCountry) {
  if (serviceCountry == null || serviceCountry == 'KR') {
    return kAuthRevisionKey;
  }
  return '${kAuthRevisionKey}__${serviceCountry.toLowerCase()}';
}

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
