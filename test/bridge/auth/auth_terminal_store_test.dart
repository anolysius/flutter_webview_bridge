import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webview_bridge/src/bridge/auth/auth_terminal_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('성공 marker는 store와 bridge가 재생성되어도 동일 attempt/revision을 찾는다', () async {
    await const AuthTerminalStore().markSuccess(
      authSessionId: 'attempt-1',
      authRevision: 5,
      serviceCountry: 'KR',
    );

    expect(
      await const AuthTerminalStore().matchesSuccess(
        authSessionId: 'attempt-1',
        authRevision: 5,
        serviceCountry: 'KR',
      ),
      isTrue,
    );
  });

  test('다른 attempt 또는 revision은 완료된 terminal로 오인하지 않는다', () async {
    await const AuthTerminalStore().markSuccess(
      authSessionId: 'attempt-1',
      authRevision: 5,
    );

    expect(
      await const AuthTerminalStore().matchesSuccess(
        authSessionId: 'attempt-2',
        authRevision: 5,
      ),
      isFalse,
    );
    expect(
      await const AuthTerminalStore().matchesSuccess(
        authSessionId: 'attempt-1',
        authRevision: 6,
      ),
      isFalse,
    );
  });

  test('attempt가 없는 새 document는 동일 revision의 완료 상태를 승계한다', () async {
    await const AuthTerminalStore().markSuccess(
      authSessionId: 'attempt-1',
      authRevision: 5,
    );

    expect(
      await const AuthTerminalStore().matchesSuccess(
        authSessionId: null,
        authRevision: 5,
      ),
      isTrue,
    );
  });

  test('attempt id 없이 수렴한 성공도 revision marker로 영속화한다', () async {
    await const AuthTerminalStore().markSuccess(
      authSessionId: null,
      authRevision: 7,
    );

    expect(
      await const AuthTerminalStore().matchesSuccess(
        authSessionId: null,
        authRevision: 7,
      ),
      isTrue,
    );
  });

  test('KR과 GLOBAL terminal marker는 격리된다', () async {
    await const AuthTerminalStore().markSuccess(
      authSessionId: 'attempt-kr',
      authRevision: 5,
      serviceCountry: 'KR',
    );

    expect(
      await const AuthTerminalStore().matchesSuccess(
        authSessionId: 'attempt-kr',
        authRevision: 5,
        serviceCountry: 'GLOBAL',
      ),
      isFalse,
    );
  });

  test('terminal key는 attempt와 revision을 함께 사용한다', () {
    expect(
      authTerminalKey(authSessionId: 'attempt-1', authRevision: 5),
      isNot(authTerminalKey(authSessionId: 'attempt-1', authRevision: 6)),
    );
  });
}
