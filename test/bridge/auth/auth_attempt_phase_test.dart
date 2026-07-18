import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webview_bridge/src/bridge/auth/auth_attempt_phase.dart';

void main() {
  group('AuthAttemptPhaseController', () {
    test('provider 계정 선택 중에는 terminal deadline을 허용하지 않는다', () {
      final controller = AuthAttemptPhaseController()
        ..beginProviderInteraction(tracksTerminal: true);

      expect(controller.phase, AuthAttemptPhase.providerInteraction);
      expect(controller.isAwaitingTerminal, isTrue);
      expect(controller.shouldRunTerminalDeadline, isFalse);
    });

    test('provider 결과가 돌아온 뒤에만 terminal deadline을 허용한다', () {
      final controller = AuthAttemptPhaseController()
        ..beginProviderInteraction(tracksTerminal: true);

      expect(controller.completeProviderInteraction(), isTrue);
      expect(controller.phase, AuthAttemptPhase.terminalConvergence);
      expect(controller.shouldRunTerminalDeadline, isTrue);
    });

    test('이미 종결된 provider 결과는 시도를 되살리지 않는다', () {
      final controller = AuthAttemptPhaseController()
        ..beginProviderInteraction(tracksTerminal: true)
        ..settle();

      expect(controller.completeProviderInteraction(), isFalse);
      expect(controller.phase, AuthAttemptPhase.idle);
      expect(controller.shouldRunTerminalDeadline, isFalse);
    });

    test('세션 replay는 provider UI 없이 terminal 수렴 단계로 복원한다', () {
      final controller = AuthAttemptPhaseController()
        ..restoreTerminalConvergence();

      expect(controller.isAwaitingTerminal, isTrue);
      expect(controller.shouldRunTerminalDeadline, isTrue);
    });

    test('legacy protocol은 terminal 추적을 시작하지 않는다', () {
      final controller = AuthAttemptPhaseController()
        ..beginProviderInteraction(tracksTerminal: false);

      expect(controller.phase, AuthAttemptPhase.idle);
      expect(controller.isAwaitingTerminal, isFalse);
      expect(controller.shouldRunTerminalDeadline, isFalse);
    });

    test(
      'active process owner가 terminal 대기 중 dispose되면 convergence handoff한다',
      () {
        final controller = AuthAttemptPhaseController()
          ..beginProviderInteraction(tracksTerminal: true);

        expect(
          controller.shouldEmitConvergenceHandoffOnDispose(
            hasActiveProcessLease: true,
          ),
          isTrue,
        );
        expect(
          controller.shouldEmitConvergenceHandoffOnDispose(
            hasActiveProcessLease: false,
          ),
          isFalse,
        );

        controller.settle();
        expect(
          controller.shouldEmitConvergenceHandoffOnDispose(
            hasActiveProcessLease: true,
          ),
          isFalse,
        );
      },
    );
  });
}
