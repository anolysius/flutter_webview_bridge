import 'dart:async';
import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webview_bridge/src/bridge/auth/service_auth_context.dart';

void main() {
  test('web auth-context capability는 명시적 protocol version으로만 활성화된다', () {
    expect(
      supportsWebAuthContextProtocol({
        'authContextProtocolVersion': webAuthContextProtocolVersion,
      }),
      isTrue,
    );
    expect(
      supportsWebAuthContextProtocol({'authContextProtocolVersion': 2}),
      isTrue,
    );
    expect(supportsWebAuthContextProtocol(null), isFalse);
    expect(supportsWebAuthContextProtocol(const <String, Object?>{}), isFalse);
    expect(
      supportsWebAuthContextProtocol({'authContextProtocolVersion': '1'}),
      isFalse,
    );
  });

  test('country와 domainType은 canonical pair로 고정된다', () {
    const kr = ServiceAuthContext(
      serviceCountry: 'KR',
      apiBaseUrl: 'https://api.sazo.kr',
      generation: 1,
    );
    const global = ServiceAuthContext(
      serviceCountry: 'GLOBAL',
      apiBaseUrl: 'https://api.sazoshop.com',
      generation: 2,
    );

    expect(kr.domainType, 'sazo-korea-shop');
    expect(global.domainType, 'sazo-global-shop');
  });

  test('country/API가 같아도 generation이 바뀌면 이전 async 작업은 stale이다', () {
    const before = ServiceAuthContext(
      serviceCountry: 'GLOBAL',
      apiBaseUrl: 'https://api.sazoshop.com',
      generation: 7,
    );
    final after = before.next(
      serviceCountry: 'GLOBAL',
      apiBaseUrl: 'https://api.sazoshop.com',
    );
    const snapshot = AuthWorkContextSnapshot(
      authEpoch: 3,
      authRevision: 11,
      service: before,
    );

    expect(
      snapshot.matches(
        authEpoch: 3,
        authRevision: 11,
        service: before,
        transitionInProgress: false,
      ),
      isTrue,
    );
    expect(
      snapshot.matches(
        authEpoch: 3,
        authRevision: 11,
        service: after,
        transitionInProgress: false,
      ),
      isFalse,
    );
    expect(
      snapshot.matches(
        authEpoch: 3,
        authRevision: 11,
        service: before,
        transitionInProgress: true,
      ),
      isFalse,
    );
  });

  test('알려진 KR/Global API host의 교차 결합은 mutation 전에 거부한다', () {
    const kr = ServiceAuthContext(
      serviceCountry: 'KR',
      apiBaseUrl: 'https://api.sazo.kr',
      generation: 1,
    );

    expect(
      () =>
          kr.next(serviceCountry: 'KR', apiBaseUrl: 'https://api.sazoshop.com'),
      throwsArgumentError,
    );
    expect(
      () => kr.next(
        serviceCountry: 'GLOBAL',
        apiBaseUrl: 'https://qa.api.sazo.kr',
      ),
      throwsArgumentError,
    );
  });

  test('QA canonical pair와 개발용 host/null은 기존대로 허용한다', () {
    expect(
      () => validateServiceAuthContextPair(
        serviceCountry: 'KR',
        apiBaseUrl: 'https://qa.api.sazo.kr',
      ),
      returnsNormally,
    );
    expect(
      () => validateServiceAuthContextPair(
        serviceCountry: 'GLOBAL',
        apiBaseUrl: 'https://qa.api.sazoshop.com',
      ),
      returnsNormally,
    );
    expect(
      () => validateServiceAuthContextPair(
        serviceCountry: 'KR',
        apiBaseUrl: 'http://localhost:3000',
      ),
      returnsNormally,
    );
  });

  test('legacy country update는 운영·QA API host도 같은 target realm으로 이동한다', () {
    expect(
      apiBaseUrlForServiceCountry(
        apiBaseUrl: 'https://api.sazo.kr',
        serviceCountry: 'GLOBAL',
      ),
      'https://api.sazoshop.com',
    );
    expect(
      apiBaseUrlForServiceCountry(
        apiBaseUrl: 'https://qa.api.sazoshop.com',
        serviceCountry: 'KR',
      ),
      'https://qa.api.sazo.kr',
    );
    expect(
      apiBaseUrlForServiceCountry(
        apiBaseUrl: 'http://localhost:3000',
        serviceCountry: 'GLOBAL',
      ),
      'http://localhost:3000',
    );
  });

  test('retired document의 모든 auth mutation은 owned explicit retry만 예외다', () {
    for (final isAuthMutation in [false, true]) {
      for (final hasOwnedRetry in [false, true]) {
        expect(
          shouldRejectRetiredAuthMessage(
            isAuthMutation: isAuthMutation,
            isRetiredDocument: true,
            hasOwnedExplicitRetry: hasOwnedRetry,
          ),
          isAuthMutation && !hasOwnedRetry,
        );
      }
    }
    expect(
      shouldRejectRetiredAuthMessage(
        isAuthMutation: true,
        isRetiredDocument: false,
        hasOwnedExplicitRetry: false,
      ),
      isFalse,
    );
  });

  test('전환 전에 활성화된 document의 늦은 mutation만 거부한다', () {
    final boundary = AuthDocumentBoundary();

    boundary.invalidate('old-document');

    expect(boundary.rejects('old-document'), isTrue);
    expect(boundary.rejects('new-document'), isFalse);
    expect(boundary.rejects(null), isFalse);
  });

  test('invalidated document 집합은 bounded하고 최신 항목을 보존한다', () {
    final boundary = AuthDocumentBoundary(maxInvalidatedDocuments: 2);

    boundary.invalidate('doc-1');
    boundary.invalidate('doc-2');
    boundary.invalidate('doc-3');

    expect(boundary.rejects('doc-1'), isFalse);
    expect(boundary.rejects('doc-2'), isTrue);
    expect(boundary.rejects('doc-3'), isTrue);
  });

  test('restart idempotency key는 실패 뒤에도 같은 terminal outcome을 보존한다', () {
    final registry = AuthContextOperationRegistry();

    expect(registry.begin('restart-1'), isTrue);
    registry.complete('restart-1', succeeded: false);

    expect(registry.begin('restart-1'), isFalse);
    expect(registry.outcome('restart-1'), AuthContextOperationOutcome.failed);
  });

  test('restart idempotency key는 TTL 뒤에만 새 operation을 허용한다', () {
    var now = DateTime.utc(2026, 7, 27);
    final registry = AuthContextOperationRegistry(now: () => now);

    expect(registry.begin('restart-1'), isTrue);
    registry.complete('restart-1', succeeded: true);
    now = now.add(const Duration(minutes: 5));
    expect(registry.begin('restart-1'), isFalse);

    now = now.add(const Duration(milliseconds: 1));
    expect(registry.begin('restart-1'), isTrue);
    expect(
      registry.outcome('restart-1'),
      AuthContextOperationOutcome.inProgress,
    );
  });

  test('auth context operation registry는 오래된 key부터 bounded 제거한다', () {
    final registry = AuthContextOperationRegistry(maxEntries: 2);

    expect(registry.begin('status-1'), isTrue);
    expect(registry.begin('status-2'), isTrue);
    expect(registry.begin('status-3'), isTrue);

    expect(registry.outcome('status-1'), isNull);
    expect(
      registry.outcome('status-2'),
      AuthContextOperationOutcome.inProgress,
    );
    expect(
      registry.outcome('status-3'),
      AuthContextOperationOutcome.inProgress,
    );
  });

  test(
    'mismatch recovery는 gate→fence→clear→transient→context→restart 순서를 고정한다',
    () async {
      final coordinator = AuthContextRecoveryCoordinator();
      final effects = <String>[];

      final result = await coordinator.run(
        idempotencyKey: 'recovery-1',
        currentContextGeneration: () => 1,
        onRestarting: () => effects.add('gate'),
        beginTransition: () {
          effects.add('fence');
          return true;
        },
        clearTokens: () async => effects.add('clear'),
        clearTransient: () => effects.add('transient'),
        completeTransition: () {
          effects.add('context');
          return true;
        },
        restart: () => effects.add('restart'),
        onFailure: () => effects.add('failure'),
      );

      expect(result, AuthContextRecoveryResult.restartAccepted);
      expect(effects, [
        'gate',
        'fence',
        'clear',
        'transient',
        'context',
        'restart',
      ]);
    },
  );

  test('mismatch recovery 성공·실패 결과는 중복 key에서 부수효과를 재실행하지 않는다', () async {
    for (final fails in [false, true]) {
      final coordinator = AuthContextRecoveryCoordinator();
      var cleanupCount = 0;
      var failureCount = 0;

      Future<AuthContextRecoveryResult> run() => coordinator.run(
        idempotencyKey: 'recovery-$fails',
        currentContextGeneration: () => 1,
        onRestarting: () {},
        beginTransition: () => true,
        clearTokens: () async {
          cleanupCount++;
          if (fails) throw StateError('clear failed');
        },
        clearTransient: () {},
        completeTransition: () => true,
        restart: () {},
        onFailure: () => failureCount++,
      );

      final first = await run();
      final duplicate = await run();

      expect(
        first,
        fails
            ? AuthContextRecoveryResult.restartFailed
            : AuthContextRecoveryResult.restartAccepted,
      );
      expect(duplicate, first);
      expect(cleanupCount, 1);
      expect(failureCount, fails ? 1 : 0);
    }
  });

  test('동시에 도착한 중복 recovery는 첫 작업의 terminal 결과를 함께 기다린다', () async {
    final coordinator = AuthContextRecoveryCoordinator();
    final clearGate = Completer<void>();
    var cleanupCount = 0;

    Future<AuthContextRecoveryResult> run() => coordinator.run(
      idempotencyKey: 'recovery-concurrent',
      currentContextGeneration: () => 1,
      onRestarting: () {},
      beginTransition: () => true,
      clearTokens: () async {
        cleanupCount++;
        await clearGate.future;
        throw StateError('clear failed');
      },
      clearTransient: () {},
      completeTransition: () => true,
      restart: () {},
      onFailure: () {},
    );

    final first = run();
    final duplicate = run();
    var duplicateCompleted = false;
    duplicate.whenComplete(() => duplicateCompleted = true);
    await Future<void>.delayed(Duration.zero);

    expect(cleanupCount, 1);
    expect(duplicateCompleted, isFalse);

    clearGate.complete();
    expect(await first, AuthContextRecoveryResult.restartFailed);
    expect(await duplicate, AuthContextRecoveryResult.restartFailed);
    expect(cleanupCount, 1);
  });

  for (final usesNullKey in [false, true]) {
    test(
      '자동 recovery는 ${usesNullKey ? "null key도" : "새 key여도"} explicit auth 전까지 한 번만 실행한다',
      () async {
        final coordinator = AuthContextRecoveryCoordinator();
        var cleanupCount = 0;
        var failureCount = 0;

        Future<AuthContextRecoveryResult> run(String key) => coordinator.run(
          idempotencyKey: usesNullKey ? null : key,
          currentContextGeneration: () => 5,
          onRestarting: () {},
          beginTransition: () => true,
          clearTokens: () async => cleanupCount++,
          clearTransient: () {},
          completeTransition: () => true,
          restart: () {},
          onFailure: () => failureCount++,
        );

        expect(
          await run('recovery-first'),
          AuthContextRecoveryResult.restartAccepted,
        );
        expect(
          await run('recovery-second'),
          AuthContextRecoveryResult.restartFailed,
        );
        expect(cleanupCount, 1);
        expect(failureCount, 1);

        coordinator.beginExplicitAuthAttempt();
        expect(
          await run('recovery-after-explicit-auth'),
          AuthContextRecoveryResult.restartAccepted,
        );
        expect(cleanupCount, 2);
      },
    );
  }

  test('terminal cleanup 실패는 명시적 provider 재시도에서만 한 번 소비된다', () async {
    final coordinator = AuthContextRecoveryCoordinator();
    var generation = 0;
    var transitionInProgress = false;

    final result = await coordinator.run(
      idempotencyKey: 'recovery-terminal-retry',
      currentContextGeneration: () => generation,
      onRestarting: () {},
      beginTransition: () {
        generation++;
        transitionInProgress = true;
        return true;
      },
      clearTokens: () async => throw StateError('clear failed'),
      clearTransient: () {},
      completeTransition: () => true,
      restart: () {},
      onFailure: () {},
    );

    expect(result, AuthContextRecoveryResult.restartFailed);
    expect(
      coordinator.consumeTerminalFailureForExplicitRetry(
        currentContextGeneration: generation,
        transitionInProgress: transitionInProgress,
      ),
      AuthContextExplicitRetryAction.reopenTransition,
    );
    expect(
      coordinator.consumeTerminalFailureForExplicitRetry(
        currentContextGeneration: generation,
        transitionInProgress: transitionInProgress,
      ),
      isNull,
    );
  });

  test('terminal retry 권한은 실패가 발생한 document만 소비한다', () async {
    final coordinator = AuthContextRecoveryCoordinator();

    await coordinator.run(
      idempotencyKey: 'recovery-document-owned',
      retryDocumentId: 'document-owner',
      currentContextGeneration: () => 9,
      onRestarting: () {},
      beginTransition: () => true,
      clearTokens: () async => throw StateError('clear failed'),
      clearTransient: () {},
      completeTransition: () => true,
      restart: () {},
      onFailure: () {},
    );

    expect(
      coordinator.consumeTerminalFailureForExplicitRetry(
        currentContextGeneration: 9,
        transitionInProgress: true,
        retryDocumentId: 'other-document',
      ),
      isNull,
    );
    expect(
      coordinator.consumeTerminalFailureForExplicitRetry(
        currentContextGeneration: 9,
        transitionInProgress: true,
        retryDocumentId: 'document-owner',
      ),
      AuthContextExplicitRetryAction.reopenTransition,
    );
  });

  test('명시적 재시도는 양쪽 token absent 뒤에만 닫힌 fence를 열 수 있다', () async {
    final coordinator = AuthContextRecoveryCoordinator();
    var generation = 1;
    var transitionInProgress = true;
    var krToken = true;
    var globalToken = true;
    var transientClearCount = 0;
    var fenceOpenCount = 0;
    var providerCallCount = 0;

    await coordinator.run(
      idempotencyKey: 'recovery-retry-cleanup-success',
      currentContextGeneration: () => generation,
      onRestarting: () {},
      beginTransition: () => true,
      clearTokens: () async => throw StateError('initial clear failed'),
      clearTransient: () {},
      completeTransition: () => true,
      restart: () {},
      onFailure: () {},
    );
    expect(
      coordinator.consumeTerminalFailureForExplicitRetry(
        currentContextGeneration: generation,
        transitionInProgress: transitionInProgress,
      ),
      AuthContextExplicitRetryAction.reopenTransition,
    );

    final cleanup = await coordinator.retryCleanupForExplicitRetry(
      contextGeneration: generation,
      isCurrentTransition: () => transitionInProgress && generation == 1,
      clearTokens: () async {
        krToken = false;
        globalToken = false;
        expect(krToken || globalToken, isFalse);
      },
      clearTransient: () => transientClearCount++,
    );
    if (cleanup == AuthContextExplicitRetryCleanupResult.ready) {
      transitionInProgress = false;
      generation++;
      fenceOpenCount++;
      providerCallCount++;
    }

    expect(cleanup, AuthContextExplicitRetryCleanupResult.ready);
    expect(krToken || globalToken, isFalse);
    expect(transientClearCount, 1);
    expect(fenceOpenCount, 1);
    expect(providerCallCount, 1);
  });

  test('명시적 재시도 cleanup이 다시 실패하면 fence와 provider를 닫고 terminal을 유지한다', () async {
    final coordinator = AuthContextRecoveryCoordinator();
    const generation = 6;
    const transitionInProgress = true;
    const globalToken = true;
    var transientClearCount = 0;
    var fenceOpenCount = 0;
    var providerCallCount = 0;

    await coordinator.run(
      idempotencyKey: 'recovery-retry-cleanup-failed',
      currentContextGeneration: () => generation,
      onRestarting: () {},
      beginTransition: () => true,
      clearTokens: () async => throw StateError('initial clear failed'),
      clearTransient: () {},
      completeTransition: () => true,
      restart: () {},
      onFailure: () {},
    );
    coordinator.consumeTerminalFailureForExplicitRetry(
      currentContextGeneration: generation,
      transitionInProgress: transitionInProgress,
    );

    final cleanup = await coordinator.retryCleanupForExplicitRetry(
      contextGeneration: generation,
      isCurrentTransition: () => transitionInProgress,
      clearTokens: () async {
        expect(globalToken, isTrue);
        throw StateError('retry clear failed');
      },
      clearTransient: () => transientClearCount++,
    );
    if (cleanup == AuthContextExplicitRetryCleanupResult.ready) {
      fenceOpenCount++;
      providerCallCount++;
    }

    expect(cleanup, AuthContextExplicitRetryCleanupResult.failed);
    expect(globalToken, isTrue);
    expect(transientClearCount, 0);
    expect(fenceOpenCount, 0);
    expect(providerCallCount, 0);
    expect(
      coordinator.consumeTerminalFailureForExplicitRetry(
        currentContextGeneration: generation,
        transitionInProgress: transitionInProgress,
      ),
      AuthContextExplicitRetryAction.reopenTransition,
    );
  });

  test('재시도 cleanup 중 다른 서비스 전환이 선점하면 terminal 권한과 fence를 넘기지 않는다', () async {
    final coordinator = AuthContextRecoveryCoordinator();
    var generation = 2;
    var transitionInProgress = true;
    final clearGate = Completer<void>();

    await coordinator.run(
      idempotencyKey: 'recovery-retry-cleanup-superseded',
      currentContextGeneration: () => generation,
      onRestarting: () {},
      beginTransition: () => true,
      clearTokens: () async => throw StateError('initial clear failed'),
      clearTransient: () {},
      completeTransition: () => true,
      restart: () {},
      onFailure: () {},
    );
    coordinator.consumeTerminalFailureForExplicitRetry(
      currentContextGeneration: generation,
      transitionInProgress: transitionInProgress,
    );

    final cleanup = coordinator.retryCleanupForExplicitRetry(
      contextGeneration: generation,
      isCurrentTransition: () => transitionInProgress && generation == 2,
      clearTokens: () async => clearGate.future,
      clearTransient: () => fail('superseded cleanup must not clear transient'),
    );
    await Future<void>.delayed(Duration.zero);
    generation++;
    transitionInProgress = true;
    clearGate.complete();

    expect(await cleanup, AuthContextExplicitRetryCleanupResult.superseded);
    expect(
      coordinator.consumeTerminalFailureForExplicitRetry(
        currentContextGeneration: generation,
        transitionInProgress: transitionInProgress,
      ),
      isNull,
    );
  });

  test('restart 실패는 열린 현재 context에서 재시도를 허용하고 transition을 다시 열지 않는다', () async {
    final coordinator = AuthContextRecoveryCoordinator();
    var generation = 0;
    var transitionInProgress = false;

    final result = await coordinator.run(
      idempotencyKey: 'recovery-restart-terminal',
      currentContextGeneration: () => generation,
      onRestarting: () {},
      beginTransition: () {
        generation++;
        transitionInProgress = true;
        return true;
      },
      clearTokens: () async {},
      clearTransient: () {},
      completeTransition: () {
        generation++;
        transitionInProgress = false;
        return true;
      },
      restart: () => throw StateError('restart failed'),
      onFailure: () {},
    );

    expect(result, AuthContextRecoveryResult.restartFailed);
    expect(
      coordinator.consumeTerminalFailureForExplicitRetry(
        currentContextGeneration: generation,
        transitionInProgress: transitionInProgress,
      ),
      AuthContextExplicitRetryAction.continueWithCurrentContext,
    );
  });

  test('이전 generation terminal 실패는 다음 서비스 전환 fence를 열지 않는다', () async {
    final coordinator = AuthContextRecoveryCoordinator();
    var generation = 0;
    var transitionInProgress = false;

    await coordinator.run(
      idempotencyKey: 'recovery-stale-terminal',
      currentContextGeneration: () => generation,
      onRestarting: () {},
      beginTransition: () {
        generation++;
        transitionInProgress = true;
        return true;
      },
      clearTokens: () async {},
      clearTransient: () {},
      completeTransition: () {
        generation++;
        transitionInProgress = false;
        return true;
      },
      restart: () => throw StateError('restart failed'),
      onFailure: () {},
    );

    generation++;
    transitionInProgress = true;
    expect(
      coordinator.consumeTerminalFailureForExplicitRetry(
        currentContextGeneration: generation,
        transitionInProgress: transitionInProgress,
      ),
      isNull,
    );
    expect(
      coordinator.consumeTerminalFailureForExplicitRetry(
        currentContextGeneration: generation - 1,
        transitionInProgress: false,
      ),
      isNull,
    );
  });

  for (final supersededAt in ['begin', 'complete']) {
    test(
      '다른 서비스 전환이 recovery $supersededAt 경계를 선점하면 old context를 복원하지 않는다',
      () async {
        final coordinator = AuthContextRecoveryCoordinator();
        var generation = 8;
        final effects = <String>[];

        final result = await coordinator.run(
          idempotencyKey: 'recovery-superseded-$supersededAt',
          currentContextGeneration: () => generation,
          onRestarting: () => effects.add('gate'),
          beginTransition: () {
            effects.add('begin');
            if (supersededAt == 'begin') return false;
            generation++;
            return true;
          },
          clearTokens: () async => effects.add('clear'),
          clearTransient: () => effects.add('transient'),
          completeTransition: () {
            effects.add('complete');
            if (supersededAt == 'complete') {
              generation++;
              return false;
            }
            return true;
          },
          restart: () => effects.add('restart'),
          onFailure: () => effects.add('failure'),
        );

        expect(result, AuthContextRecoveryResult.restartAccepted);
        expect(effects, containsAllInOrder(['gate', 'begin']));
        expect(effects, isNot(contains('restart')));
        expect(effects, isNot(contains('failure')));
        expect(
          coordinator.consumeTerminalFailureForExplicitRetry(
            currentContextGeneration: generation,
            transitionInProgress: true,
          ),
          isNull,
        );
        if (supersededAt == 'begin') {
          expect(effects, ['gate', 'begin']);
        } else {
          expect(effects, ['gate', 'begin', 'clear', 'transient', 'complete']);
        }
      },
    );
  }

  test(
    'recovery 소유 generation을 잃은 뒤의 실패는 새 transition의 retry 권한이 되지 않는다',
    () async {
      final coordinator = AuthContextRecoveryCoordinator();
      var generation = 3;

      final result = await coordinator.run(
        idempotencyKey: 'recovery-failed-after-superseded',
        currentContextGeneration: () => generation,
        onRestarting: () {},
        beginTransition: () {
          generation++;
          return true;
        },
        clearTokens: () async {
          generation++;
          throw StateError('old cleanup completed after target transition');
        },
        clearTransient: () {},
        completeTransition: () => true,
        restart: () {},
        onFailure: () {},
      );

      expect(result, AuthContextRecoveryResult.restartFailed);
      expect(
        coordinator.consumeTerminalFailureForExplicitRetry(
          currentContextGeneration: generation,
          transitionInProgress: true,
        ),
        isNull,
      );
    },
  );

  test('UI restarting callback 실패는 token cleanup/restart를 건너뛰지 않는다', () async {
    final coordinator = AuthContextRecoveryCoordinator();
    final effects = <String>[];

    final result = await coordinator.run(
      idempotencyKey: 'recovery-gate-failure',
      currentContextGeneration: () => 1,
      onRestarting: () => throw StateError('gate callback failed'),
      beginTransition: () {
        effects.add('fence');
        return true;
      },
      clearTokens: () async => effects.add('clear'),
      clearTransient: () => effects.add('transient'),
      completeTransition: () {
        effects.add('context');
        return true;
      },
      restart: () => effects.add('restart'),
      onFailure: () => effects.add('failure'),
    );

    expect(result, AuthContextRecoveryResult.restartAccepted);
    expect(effects, ['fence', 'clear', 'transient', 'context', 'restart']);
  });

  for (final operationName in [
    'google_logout',
    'apple_logout',
    'kakao_logout',
    'refresh_delete',
  ]) {
    test(
      '$operationName revision await 중 country switch 결과는 적용하지 않는다',
      () async {
        const before = ServiceAuthContext(
          serviceCountry: 'KR',
          apiBaseUrl: 'https://api.sazo.kr',
          generation: 4,
        );
        final after = before.next(
          serviceCountry: 'GLOBAL',
          apiBaseUrl: 'https://api.sazoshop.com',
        );
        var current = before;
        var transitionInProgress = false;
        final staleStages = <String>[];
        final operationGate = Completer<void>();
        String? operationCountry;
        final snapshot = AuthWorkContextSnapshot(
          authEpoch: 7,
          authRevision: 11,
          service: before,
        );
        final fence = AuthContextWorkFence(
          snapshot: snapshot,
          isCurrent: (candidate) => candidate.matches(
            authEpoch: 7,
            authRevision: 11,
            service: current,
            transitionInProgress: transitionInProgress,
          ),
          onStale: staleStages.add,
        );

        final pending = runGuardedServiceAuthOperation<int>(
          fence: fence,
          staleStage: '$operationName:after_revision',
          operation: (country) async {
            operationCountry = country;
            await operationGate.future;
            return 12;
          },
        );
        await Future<void>.delayed(Duration.zero);

        transitionInProgress = true;
        current = after;
        operationGate.complete();

        expect(await pending, isNull);
        expect(operationCountry, 'KR');
        expect(staleStages, ['$operationName:after_revision']);
      },
    );
  }

  const boundaryPhases = [
    'after_device_headers',
    'after_exchange',
    'before_persist',
    'after_persist_before_me',
    'after_me_before_cache',
    'before_delivery',
  ];
  const directions = [
    (
      fromCountry: 'KR',
      fromApi: 'https://api.sazo.kr',
      toCountry: 'GLOBAL',
      toApi: 'https://api.sazoshop.com',
    ),
    (
      fromCountry: 'GLOBAL',
      fromApi: 'https://api.sazoshop.com',
      toCountry: 'KR',
      toApi: 'https://api.sazo.kr',
    ),
  ];

  test(
    '같은-country async pipeline은 persist→cache→delivery→UI 순서를 보존한다',
    () async {
      const context = ServiceAuthContext(
        serviceCountry: 'KR',
        apiBaseUrl: 'https://api.sazo.kr',
        generation: 3,
      );
      final harness = _AsyncAuthPipelineHarness(
        before: context,
        after: context,
      );

      await harness.run(boundaryIndex: -1);

      expect(harness.refreshTokens, {'KR': 'rotated-refresh'});
      expect(harness.cachedPayloadCount, 1);
      expect(harness.deliveryCount, 1);
      expect(harness.uiCommitCount, 1);
      expect(harness.effects, ['persist', 'cache', 'delivery', 'ui']);
      expect(harness.staleStages, isEmpty);
    },
  );

  for (final direction in directions) {
    for (
      var boundaryIndex = 0;
      boundaryIndex < boundaryPhases.length;
      boundaryIndex++
    ) {
      test(
        '${direction.fromCountry}→${direction.toCountry} '
        '${boundaryPhases[boundaryIndex]} boundary 뒤 side-effect는 모두 차단된다',
        () async {
          final before = ServiceAuthContext(
            serviceCountry: direction.fromCountry,
            apiBaseUrl: direction.fromApi,
            generation: 9,
          );
          final after = before.next(
            serviceCountry: direction.toCountry,
            apiBaseUrl: direction.toApi,
          );
          final harness = _AsyncAuthPipelineHarness(
            before: before,
            after: after,
          );

          await harness.run(boundaryIndex: boundaryIndex);

          expect(harness.refreshTokens, isEmpty);
          expect(harness.cachedPayloadCount, 0);
          expect(harness.deliveryCount, 0);
          expect(harness.uiCommitCount, 0);
          expect(harness.staleStages, hasLength(1));
          expect(harness.staleStages.single, boundaryPhases[boundaryIndex]);
        },
      );
    }
  }

  for (
    var directionIndex = 0;
    directionIndex < directions.length;
    directionIndex++
  ) {
    test(
      '${directions[directionIndex].fromCountry}→'
      '${directions[directionIndex].toCountry} seed 기록 randomized 1,000회',
      () async {
        final direction = directions[directionIndex];
        final seed = 0x5A20 + directionIndex;
        final random = Random(seed);

        for (var iteration = 0; iteration < 1000; iteration++) {
          final boundaryIndex = random.nextInt(boundaryPhases.length);
          final before = ServiceAuthContext(
            serviceCountry: direction.fromCountry,
            apiBaseUrl: direction.fromApi,
            generation: iteration,
          );
          final after = before.next(
            serviceCountry: direction.toCountry,
            apiBaseUrl: direction.toApi,
          );
          final harness = _AsyncAuthPipelineHarness(
            before: before,
            after: after,
          );

          await harness.run(boundaryIndex: boundaryIndex);

          expect(
            harness.refreshTokens,
            isEmpty,
            reason:
                'seed=$seed iteration=$iteration '
                'boundary=${boundaryPhases[boundaryIndex]} token write',
          );
          expect(
            harness.cachedPayloadCount,
            0,
            reason:
                'seed=$seed iteration=$iteration '
                'boundary=${boundaryPhases[boundaryIndex]} cache',
          );
          expect(
            harness.deliveryCount,
            0,
            reason:
                'seed=$seed iteration=$iteration '
                'boundary=${boundaryPhases[boundaryIndex]} delivery',
          );
          expect(
            harness.uiCommitCount,
            0,
            reason:
                'seed=$seed iteration=$iteration '
                'boundary=${boundaryPhases[boundaryIndex]} ui commit',
          );
          expect(harness.staleStages, [boundaryPhases[boundaryIndex]]);
        }
      },
    );
  }
}

class _AsyncAuthPipelineHarness {
  _AsyncAuthPipelineHarness({required this.before, required this.after})
    : _current = before;

  static const _phases = [
    'after_device_headers',
    'after_exchange',
    'before_persist',
    'after_persist_before_me',
    'after_me_before_cache',
    'before_delivery',
  ];

  final ServiceAuthContext before;
  final ServiceAuthContext after;
  late ServiceAuthContext _current;
  final Map<String, String> refreshTokens = <String, String>{};
  final List<String> staleStages = <String>[];
  final List<String> effects = <String>[];
  int cachedPayloadCount = 0;
  int deliveryCount = 0;
  int uiCommitCount = 0;

  Future<void> run({required int boundaryIndex}) async {
    final snapshot = AuthWorkContextSnapshot(
      authEpoch: 4,
      authRevision: 12,
      service: before,
    );
    final fence = AuthContextWorkFence(
      snapshot: snapshot,
      isCurrent: (candidate) => candidate.matches(
        authEpoch: 4,
        authRevision: 12,
        service: _current,
        transitionInProgress: false,
      ),
      onStale: staleStages.add,
    );

    await Future<void>.value(); // device headers
    _switchAt(0, boundaryIndex);
    if (!fence.checkpoint(_phases[0])) return;

    await Future<void>.value(); // exchange HTTP
    _switchAt(1, boundaryIndex);
    if (!fence.checkpoint(_phases[1])) return;

    _switchAt(2, boundaryIndex);
    if (!fence.checkpoint(_phases[2])) return;
    if (fence.canMutate) {
      refreshTokens[before.serviceCountry] = 'rotated-refresh';
      effects.add('persist');
    }

    await Future<void>.value(); // queued persistence completion
    _switchAt(3, boundaryIndex);
    if (!fence.checkpoint(_phases[3])) return;

    await Future<void>.value(); // /me
    _switchAt(4, boundaryIndex);
    if (!fence.checkpoint(_phases[4])) return;
    cachedPayloadCount++;
    effects.add('cache');

    await Future<void>.value(); // outer bridge delivery turn
    _switchAt(5, boundaryIndex);
    if (!fence.checkpoint(_phases[5])) return;
    deliveryCount++;
    effects.add('delivery');
    uiCommitCount++;
    effects.add('ui');
  }

  void _switchAt(int phase, int boundaryIndex) {
    if (phase != boundaryIndex) return;
    _current = after;
    // production beginTransition+clear barrier가 token mutation queue와 replay
    // cache를 같은 경계에서 비우는 동작을 fake store로 재현한다.
    refreshTokens.clear();
    cachedPayloadCount = 0;
  }
}
