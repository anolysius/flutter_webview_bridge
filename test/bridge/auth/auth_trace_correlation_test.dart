import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webview_bridge/src/bridge/auth/auth_trace_correlation.dart';

void main() {
  final epoch = DateTime.utc(2026, 7, 23);
  late DateTime now;
  late AuthTraceCorrelationCache cache;

  const correlation = AuthTraceCorrelation(
    requestId: 'request-1',
    loginAttemptId: 'attempt-1',
    authRevision: 7,
    protocolVersion: 3,
    provider: 'kakao',
    documentId: 'document-1',
  );

  setUp(() {
    now = epoch;
    cache = AuthTraceCorrelationCache(now: () => now);
  });

  test('terminal 직후 늦은 delivery receipt도 attempt correlation을 보존한다', () {
    cache.remember(correlation);
    cache.markTerminal('request-1');
    now = now.add(const Duration(seconds: 119));

    expect(cache.resolve('request-1')?.loginAttemptId, 'attempt-1');
    expect(cache.resolve('request-1')?.authRevision, 7);
  });

  test('terminal grace가 지나면 correlation을 제거한다', () {
    cache.remember(correlation);
    cache.markTerminal('request-1');
    now = now.add(const Duration(seconds: 121));

    expect(cache.resolve('request-1'), isNull);
  });

  test('bounded cache는 가장 오래된 entry부터 제거한다', () {
    cache = AuthTraceCorrelationCache(maxEntries: 2, now: () => now);
    for (var index = 1; index <= 3; index += 1) {
      cache.remember(
        AuthTraceCorrelation(
          requestId: 'request-$index',
          loginAttemptId: 'attempt-$index',
          authRevision: index,
          protocolVersion: 3,
        ),
      );
    }

    expect(cache.resolve('request-1'), isNull);
    expect(cache.resolve('request-2'), isNotNull);
    expect(cache.resolve('request-3'), isNotNull);
  });
}
