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

  test('여러 bridge의 동시 next 요청도 중복 없이 단조 증가한다', () async {
    final revisions = await Future.wait(
      List.generate(
        20,
        (_) => const AuthRevisionStore().next(serviceCountry: 'KR'),
      ),
    );

    expect(revisions.toSet(), Set<int>.from(List.generate(20, (i) => i + 1)));
    expect(await const AuthRevisionStore().current(serviceCountry: 'KR'), 20);
  });

  test('직렬화 대기 전에 superseded 된 revision 작업은 저장하지 않는다', () async {
    final revisions = await Future.wait([
      ...List.generate(
        20,
        (_) => const AuthRevisionStore().nextIfCurrent(
          serviceCountry: 'KR',
          isCurrent: _alwaysStale,
        ),
      ),
      const AuthRevisionStore().nextIfCurrent(
        serviceCountry: 'KR',
        isCurrent: _alwaysCurrent,
      ),
    ]);

    expect(revisions.take(20), everyElement(isNull));
    expect(revisions.last, 1);
    expect(await const AuthRevisionStore().current(serviceCountry: 'KR'), 1);
  });

  test('국가 전환 뒤 bootstrap read는 이전 국가 active revision 대신 대상 저장값을 채택한다', () {
    expect(
      resolveRefreshAuthRevision(
        activeRevision: 7,
        storedRevision: 2,
        preserveInteractiveAttempt: false,
      ),
      2,
    );
  });

  test('동일 interactive 로그인 수렴 중 read는 진행 중 revision을 보존한다', () {
    expect(
      resolveRefreshAuthRevision(
        activeRevision: 7,
        storedRevision: 6,
        preserveInteractiveAttempt: true,
      ),
      7,
    );
  });

  test('revision read snapshot은 await 중 country 또는 epoch가 바뀌면 stale이다', () {
    const snapshot = AuthRevisionReadSnapshot(
      epoch: 3,
      serviceCountry: 'GLOBAL',
    );

    expect(snapshot.matches(epoch: 3, serviceCountry: 'GLOBAL'), isTrue);
    expect(snapshot.matches(epoch: 4, serviceCountry: 'GLOBAL'), isFalse);
    expect(snapshot.matches(epoch: 3, serviceCountry: 'KR'), isFalse);
  });
}

bool _alwaysStale() => false;

bool _alwaysCurrent() => true;
