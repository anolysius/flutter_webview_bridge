import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webview_bridge/src/bridge/auth/pending_auth_attempt_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

PendingAuthAttempt attempt({
  String id = 'attempt-1',
  int revision = 7,
  String process = 'process-a',
}) => PendingAuthAttempt(
  attemptId: id,
  authRevision: revision,
  provider: 'GOOGLE_SIGN_IN_LOGIN',
  protocolVersion: 2,
  startedAt: DateTime.utc(2026, 7, 18),
  processInstanceId: process,
  requestId: 'request-1',
  documentId: 'document-1',
);

void main() {
  const store = PendingAuthAttemptStore();

  setUp(() => SharedPreferences.setMockInitialValues({}));

  test('같은 process의 WebView 재생성은 미완료 attempt를 회수하지 않는다', () async {
    await store.markStarted(attempt: attempt());

    expect(
      await store.takeInterrupted(currentProcessInstanceId: 'process-a'),
      isNull,
    );
    expect(
      await store.takeInterrupted(currentProcessInstanceId: 'process-b'),
      isNotNull,
    );
  });

  test('이전 process attempt는 다음 실행에서 정확히 한 번 회수한다', () async {
    await store.markStarted(attempt: attempt());

    final recovered = await store.takeInterrupted(
      currentProcessInstanceId: 'process-b',
    );

    expect(recovered?.attemptId, 'attempt-1');
    expect(recovered?.authRevision, 7);
    expect(recovered?.provider, 'GOOGLE_SIGN_IN_LOGIN');
    expect(
      await store.takeInterrupted(currentProcessInstanceId: 'process-c'),
      isNull,
    );
  });

  test('옛 terminal clear는 더 최신 attempt를 지우지 않는다', () async {
    await store.markStarted(attempt: attempt(id: 'attempt-new', revision: 8));

    await store.clearIfMatches(attemptId: 'attempt-old', authRevision: 7);

    final recovered = await store.takeInterrupted(
      currentProcessInstanceId: 'process-b',
    );
    expect(recovered?.attemptId, 'attempt-new');
    expect(recovered?.authRevision, 8);
  });

  test('국가별 pending attempt는 서로 격리한다', () async {
    await store.markStarted(attempt: attempt(), serviceCountry: 'KR');
    await store.markStarted(
      attempt: attempt(id: 'global-attempt'),
      serviceCountry: 'GLOBAL',
    );

    final kr = await store.takeInterrupted(
      currentProcessInstanceId: 'process-b',
      serviceCountry: 'KR',
    );
    final global = await store.takeInterrupted(
      currentProcessInstanceId: 'process-b',
      serviceCountry: 'GLOBAL',
    );

    expect(kr?.attemptId, 'attempt-1');
    expect(global?.attemptId, 'global-attempt');
  });
}
