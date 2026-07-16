import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webview_bridge/src/bridge/auth/auth_revision_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('revision은 앱 재생성에 해당하는 store 재생성 뒤에도 단조 증가한다', () async {
    expect(await const AuthRevisionStore().next(serviceCountry: 'KR'), 1);
    expect(await const AuthRevisionStore().next(serviceCountry: 'KR'), 2);
    expect(await const AuthRevisionStore().current(serviceCountry: 'KR'), 2);
  });

  test('KR과 GLOBAL revision은 token domain과 같이 격리된다', () async {
    expect(await const AuthRevisionStore().next(serviceCountry: 'KR'), 1);
    expect(await const AuthRevisionStore().next(serviceCountry: 'GLOBAL'), 1);
    expect(await const AuthRevisionStore().next(serviceCountry: 'GLOBAL'), 2);
    expect(await const AuthRevisionStore().current(serviceCountry: 'KR'), 1);
  });
}
