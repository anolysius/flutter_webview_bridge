import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webview_bridge/src/bridge/auth/process_auth_attempt_coordinator.dart';

void main() {
  group('ProcessAuthAttemptCoordinator', () {
    test('auto bootstrap은 여러 bridge instance를 통틀어 process당 한 번만 claim된다', () {
      final coordinator = ProcessAuthAttemptCoordinator();

      expect(coordinator.claimAutomaticBootstrap(), isTrue);
      expect(coordinator.claimAutomaticBootstrap(), isFalse);
    });

    test('active interactive 시도는 새 auto attempt를 억제한다', () {
      final coordinator = ProcessAuthAttemptCoordinator();
      final interactive = coordinator.beginInteractive(
        attemptId: 'sso-1',
        onSuperseded: () {},
        onSettled: () {},
      );

      final automatic = coordinator.tryBeginAutomatic(
        attemptId: 'auto-1',
        onSuperseded: () {},
        onSettled: () {},
      );

      expect(coordinator.isActive(interactive), isTrue);
      expect(automatic, isNull);
    });

    test('interactive 시도는 active auto를 선점하고 callback을 정확히 한 번 호출한다', () {
      final coordinator = ProcessAuthAttemptCoordinator();
      var superseded = 0;
      final automatic = coordinator.tryBeginAutomatic(
        attemptId: 'auto-1',
        onSuperseded: () => superseded += 1,
        onSettled: () {},
      )!;

      final interactive = coordinator.beginInteractive(
        attemptId: 'sso-1',
        onSuperseded: () {},
        onSettled: () {},
      );

      expect(superseded, 1);
      expect(coordinator.isActive(automatic), isFalse);
      expect(coordinator.isActive(interactive), isTrue);
    });

    test('새 interactive 시도는 이전 interactive 시도를 선점한다', () {
      final coordinator = ProcessAuthAttemptCoordinator();
      var firstSuperseded = 0;
      final first = coordinator.beginInteractive(
        attemptId: 'sso-1',
        onSuperseded: () => firstSuperseded += 1,
        onSettled: () {},
      );

      final second = coordinator.beginInteractive(
        attemptId: 'sso-2',
        onSuperseded: () {},
        onSettled: () {},
      );

      expect(firstSuperseded, 1);
      expect(coordinator.isActive(first), isFalse);
      expect(coordinator.isActive(second), isTrue);
    });

    test('동일 provider의 중복 interactive 시도는 active owner를 유지한다', () {
      final coordinator = ProcessAuthAttemptCoordinator();
      var firstSuperseded = 0;
      final first = coordinator.tryBeginInteractive(
        attemptId: 'sso-google-1',
        deduplicationKey: 'KR:GOOGLE_SIGN_IN_LOGIN',
        onSuperseded: () => firstSuperseded += 1,
        onSettled: () {},
      )!;

      final duplicate = coordinator.tryBeginInteractive(
        attemptId: 'sso-google-2',
        deduplicationKey: 'KR:GOOGLE_SIGN_IN_LOGIN',
        onSuperseded: () {},
        onSettled: () {},
      );

      expect(duplicate, isNull);
      expect(firstSuperseded, 0);
      expect(coordinator.isActive(first), isTrue);
    });

    test('다른 provider의 interactive 시도는 active owner를 선점한다', () {
      final coordinator = ProcessAuthAttemptCoordinator();
      var googleSuperseded = 0;
      final google = coordinator.tryBeginInteractive(
        attemptId: 'sso-google',
        deduplicationKey: 'KR:GOOGLE_SIGN_IN_LOGIN',
        onSuperseded: () => googleSuperseded += 1,
        onSettled: () {},
      )!;

      final kakao = coordinator.tryBeginInteractive(
        attemptId: 'sso-kakao',
        deduplicationKey: 'KR:KAKAO_SIGN_IN_LOGIN',
        onSuperseded: () {},
        onSettled: () {},
      )!;

      expect(googleSuperseded, 1);
      expect(coordinator.isActive(google), isFalse);
      expect(coordinator.isActive(kakao), isTrue);
    });

    test('stale lease 완료는 현재 active attempt를 지우지 않는다', () {
      final coordinator = ProcessAuthAttemptCoordinator();
      final automatic = coordinator.tryBeginAutomatic(
        attemptId: 'auto-1',
        onSuperseded: () {},
        onSettled: () {},
      )!;
      final interactive = coordinator.beginInteractive(
        attemptId: 'sso-1',
        onSuperseded: () {},
        onSettled: () {},
      );

      coordinator.complete(automatic);

      expect(coordinator.isActive(interactive), isTrue);
      coordinator.complete(interactive);
      expect(coordinator.isActive(interactive), isFalse);
    });

    test('active auto가 있으면 두 번째 bridge의 auto attempt를 억제한다', () {
      final coordinator = ProcessAuthAttemptCoordinator();
      final first = coordinator.tryBeginAutomatic(
        attemptId: 'auto-1',
        onSuperseded: () {},
        onSettled: () {},
      );

      final second = coordinator.tryBeginAutomatic(
        attemptId: 'auto-2',
        onSuperseded: () {},
        onSettled: () {},
      );

      expect(first, isNotNull);
      expect(second, isNull);
    });

    test('다른 bridge의 terminal 확정은 원 소유자의 deadline을 즉시 정지시킨다', () {
      final coordinator = ProcessAuthAttemptCoordinator();
      var settled = 0;
      final owner = coordinator.beginInteractive(
        attemptId: 'sso-1',
        onSuperseded: () {},
        onSettled: () => settled += 1,
      );

      expect(
        coordinator.settleTerminal(attemptId: 'sso-1', revision: 7),
        isTrue,
      );

      expect(settled, 1);
      expect(coordinator.isActive(owner), isFalse);
    });

    test('동일 attempt는 revision이 달라도 process terminal이 한 번만 승인된다', () {
      final coordinator = ProcessAuthAttemptCoordinator();

      expect(
        coordinator.settleTerminal(attemptId: 'sso-1', revision: 7),
        isTrue,
      );
      expect(
        coordinator.settleTerminal(attemptId: 'sso-1', revision: 8),
        isFalse,
      );
      expect(
        coordinator.isTerminalSettled(attemptId: 'sso-1', revision: 99),
        isTrue,
      );
    });

    test('관련 없는 terminal은 현재 active attempt를 종료하지 않는다', () {
      final coordinator = ProcessAuthAttemptCoordinator();
      var settled = 0;
      final active = coordinator.beginInteractive(
        attemptId: 'sso-active',
        onSuperseded: () {},
        onSettled: () => settled += 1,
      );

      coordinator.settleTerminal(attemptId: 'sso-other', revision: 1);

      expect(settled, 0);
      expect(coordinator.isActive(active), isTrue);
    });

    test('auth boundary reset은 active owner를 종료하고 bootstrap gate를 다시 연다', () {
      final coordinator = ProcessAuthAttemptCoordinator();
      var superseded = 0;
      final active = coordinator.beginInteractive(
        attemptId: 'global-sso',
        onSuperseded: () => superseded += 1,
        onSettled: () {},
      );
      expect(coordinator.claimAutomaticBootstrap(), isTrue);
      expect(coordinator.claimAutomaticBootstrap(), isFalse);

      coordinator.resetForAuthBoundary();

      expect(superseded, 1);
      expect(coordinator.isActive(active), isFalse);
      expect(coordinator.claimAutomaticBootstrap(), isTrue);
    });

    test('boundary 이전 stale lease 완료가 대상 국가의 새 auto owner를 지우지 않는다', () {
      final coordinator = ProcessAuthAttemptCoordinator();
      final old = coordinator.beginInteractive(
        attemptId: 'global-sso',
        onSuperseded: () {},
        onSettled: () {},
      );
      coordinator.resetForAuthBoundary();
      final target = coordinator.tryBeginAutomatic(
        attemptId: 'kr-bootstrap',
        onSuperseded: () {},
        onSettled: () {},
      )!;

      coordinator.complete(old);

      expect(coordinator.isActive(target), isTrue);
    });

    test('active owner가 없는 auth boundary reset은 반복 호출해도 안전하다', () {
      final coordinator = ProcessAuthAttemptCoordinator();

      coordinator.resetForAuthBoundary();
      coordinator.resetForAuthBoundary();

      expect(coordinator.claimAutomaticBootstrap(), isTrue);
      expect(coordinator.claimAutomaticBootstrap(), isFalse);
    });

    test('superseded callback의 stale 완료가 callback 중 생성된 새 owner를 지우지 않는다', () {
      final coordinator = ProcessAuthAttemptCoordinator();
      late ProcessAuthAttemptLease old;
      late ProcessAuthAttemptLease target;
      old = coordinator.beginInteractive(
        attemptId: 'global-sso',
        onSuperseded: () {
          target = coordinator.tryBeginAutomatic(
            attemptId: 'kr-bootstrap',
            onSuperseded: () {},
            onSettled: () {},
          )!;
          coordinator.complete(old);
        },
        onSettled: () {},
      );

      coordinator.resetForAuthBoundary();

      expect(coordinator.isActive(target), isTrue);
    });
  });

  group('AuthTerminalWorkSnapshot', () {
    const snapshot = AuthTerminalWorkSnapshot(
      epoch: 3,
      attemptId: 'sso-1',
      revision: 7,
      requestId: 'request-1',
      leaseGeneration: 11,
    );

    test('async gap 전후 모든 identity가 같을 때만 현재 작업이다', () {
      expect(
        snapshot.matches(
          epoch: 3,
          attemptId: 'sso-1',
          revision: 7,
          requestId: 'request-1',
          leaseGeneration: 11,
        ),
        isTrue,
      );
    });

    test('await 중 새 attempt/epoch/lease로 바뀌면 stale로 판정한다', () {
      expect(
        snapshot.matches(
          epoch: 4,
          attemptId: 'sso-2',
          revision: 8,
          requestId: 'request-2',
          leaseGeneration: 12,
        ),
        isFalse,
      );
    });

    test('동일 attempt여도 document request가 바뀐 옛 callback은 stale이다', () {
      expect(
        snapshot.matches(
          epoch: 3,
          attemptId: 'sso-1',
          revision: 7,
          requestId: 'request-new-document',
          leaseGeneration: 11,
        ),
        isFalse,
      );
    });
  });
}
