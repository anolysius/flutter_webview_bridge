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
      );

      final automatic = coordinator.tryBeginAutomatic(
        attemptId: 'auto-1',
        onSuperseded: () {},
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
      )!;

      final interactive = coordinator.beginInteractive(
        attemptId: 'sso-1',
        onSuperseded: () {},
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
      );

      final second = coordinator.beginInteractive(
        attemptId: 'sso-2',
        onSuperseded: () {},
      );

      expect(firstSuperseded, 1);
      expect(coordinator.isActive(first), isFalse);
      expect(coordinator.isActive(second), isTrue);
    });

    test('stale lease 완료는 현재 active attempt를 지우지 않는다', () {
      final coordinator = ProcessAuthAttemptCoordinator();
      final automatic = coordinator.tryBeginAutomatic(
        attemptId: 'auto-1',
        onSuperseded: () {},
      )!;
      final interactive = coordinator.beginInteractive(
        attemptId: 'sso-1',
        onSuperseded: () {},
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
      );

      final second = coordinator.tryBeginAutomatic(
        attemptId: 'auto-2',
        onSuperseded: () {},
      );

      expect(first, isNotNull);
      expect(second, isNull);
    });
  });
}
