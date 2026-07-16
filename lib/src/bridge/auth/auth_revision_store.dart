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

  Future<int> current({String? serviceCountry}) async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getInt(authRevisionKeyFor(serviceCountry)) ?? 0;
  }

  Future<int> next({String? serviceCountry}) async {
    final prefs = await SharedPreferences.getInstance();
    final key = authRevisionKeyFor(serviceCountry);
    final nextRevision = (prefs.getInt(key) ?? 0) + 1;
    final stored = await prefs.setInt(key, nextRevision);
    if (!stored || prefs.getInt(key) != nextRevision) {
      throw StateError('Failed to persist auth revision');
    }
    return nextRevision;
  }
}
