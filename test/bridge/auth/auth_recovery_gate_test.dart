import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webview_bridge/src/bridge/auth/auth_recovery_gate.dart';

void main() {
  test('confirmed home bind blocks B2 and soft recovery reload', () {
    final gate = AuthRecoveryGate()..confirmHomeTokenBind();

    expect(gate.tryConsumeRecovery(requiresUnconfirmedHome: true), isFalse);
    expect(gate.reloadCount, 0);
  });

  test('unconfirmed recovery has a single reload budget', () {
    final gate = AuthRecoveryGate();

    expect(gate.tryConsumeRecovery(requiresUnconfirmedHome: true), isTrue);
    expect(gate.tryConsumeRecovery(requiresUnconfirmedHome: false), isFalse);
    expect(gate.reloadCount, 1);
  });

  test('recovery exhaustion is reported once per reset lineage', () {
    final gate = AuthRecoveryGate();

    expect(gate.takeExhaustionSignal(), isTrue);
    expect(gate.takeExhaustionSignal(), isFalse);

    gate.reset();

    expect(gate.takeExhaustionSignal(), isTrue);
  });
}
