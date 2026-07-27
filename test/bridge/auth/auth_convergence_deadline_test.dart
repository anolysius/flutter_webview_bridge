import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webview_bridge/src/bridge/auth/auth_convergence_deadline.dart';

void main() {
  late Duration now;
  late AuthConvergenceDeadlineController controller;

  group('AuthConvergenceDeadlineController', () {
    setUp(() {
      now = Duration.zero;
      controller = AuthConvergenceDeadlineController(monotonicNow: () => now);
    });

    test('15초는 soft event이고 60초만 hard event다', () {
      controller.start(isForeground: true);

      now = const Duration(milliseconds: 14999);
      expect(controller.consumeDue(), isNull);
      now = const Duration(seconds: 15);
      expect(
        controller.consumeDue(),
        AuthConvergenceDeadlineEvent.softDeadline,
      );
      now = const Duration(milliseconds: 59999);
      expect(controller.consumeDue(), isNull);
      now = const Duration(seconds: 60);
      expect(
        controller.consumeDue(),
        AuthConvergenceDeadlineEvent.hardDeadline,
      );
    });

    test('background 시간은 hard deadline에서 제외한다', () {
      controller.start(isForeground: true);
      now = const Duration(seconds: 10);
      controller.pause();

      now = const Duration(hours: 1);
      expect(controller.elapsed, const Duration(seconds: 10));
      controller.resume();

      now += const Duration(seconds: 5);
      expect(
        controller.consumeDue(),
        AuthConvergenceDeadlineEvent.softDeadline,
      );
      now += const Duration(seconds: 45);
      expect(
        controller.consumeDue(),
        AuthConvergenceDeadlineEvent.hardDeadline,
      );
    });

    test('soft event는 멱등이고 다음 timer는 남은 hard budget을 사용한다', () {
      controller.start(isForeground: true);

      now = const Duration(seconds: 15);
      expect(
        controller.consumeDue(),
        AuthConvergenceDeadlineEvent.softDeadline,
      );
      now = const Duration(seconds: 16);
      expect(controller.consumeDue(), isNull);
      expect(controller.nextTransitionIn, const Duration(seconds: 44));
    });

    test('settle 후 stale callback은 어떤 event도 만들지 않는다', () {
      controller
        ..start(isForeground: true)
        ..settle();

      now = const Duration(minutes: 2);
      expect(controller.consumeDue(), isNull);
      expect(controller.nextTransitionIn, isNull);
    });
  });
}
