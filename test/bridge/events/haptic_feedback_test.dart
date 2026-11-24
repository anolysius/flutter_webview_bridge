import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webview_bridge/src/bridge/events/haptic_feedback.dart';
import 'package:flutter_webview_bridge/src/models/types.dart';

void main() {
  late List<HapticStyle> performed;
  late DateTime clock;
  late HapticFeedbackEvent event;

  setUp(() {
    performed = [];
    clock = DateTime(2026, 11, 23, 12);
    event = HapticFeedbackEvent(
      perform: (style) async => performed.add(style),
      now: () => clock,
    );
  });

  void tick([Duration by = HapticFeedbackEvent.minInterval]) {
    clock = clock.add(by);
  }

  test('기본 5종을 그대로 울린다', () async {
    for (final name in ['light', 'medium', 'heavy', 'selection', 'vibrate']) {
      await event.process({'style': name});
      tick();
    }
    expect(performed, HapticStyle.values);
  });

  test('모르는 style·잘못된 data 는 울리지 않는다', () async {
    await event.process({'style': 'success'});
    await event.process({'style': 1});
    await event.process({});
    await event.process(null);
    await event.process('light');
    expect(performed, isEmpty);
  });

  test('minInterval 안에 연달아 오면 뒤의 것은 버린다', () async {
    await event.process({'style': 'light'});
    tick(const Duration(milliseconds: 10));
    await event.process({'style': 'heavy'});
    tick(HapticFeedbackEvent.minInterval);
    await event.process({'style': 'medium'});
    expect(performed, [HapticStyle.light, HapticStyle.medium]);
  });

  test('기기 시계가 뒤로 가도 이후 요청을 버리지 않는다', () async {
    await event.process({'style': 'light'});
    clock = clock.subtract(const Duration(hours: 1));
    await event.process({'style': 'heavy'});
    tick(const Duration(milliseconds: 10));
    await event.process({'style': 'medium'});
    expect(performed, [HapticStyle.light, HapticStyle.heavy]);
  });

  test('모르는 style 은 간격 계산에 들어가지 않는다', () async {
    await event.process({'style': 'nope'});
    await event.process({'style': 'light'});
    expect(performed, [HapticStyle.light]);
  });

  test('플랫폼 오류는 밖으로 던지지 않는다', () async {
    final failing = HapticFeedbackEvent(
      perform: (_) async => throw StateError('no vibrator'),
    );
    await expectLater(failing.process({'style': 'light'}), completes);
  });

  test('HAPTIC_FEEDBACK 이름이 왕복한다', () {
    expect(WebViewBridgeFeatureType.hapticFeedback.value, 'HAPTIC_FEEDBACK');
    expect(
      'HAPTIC_FEEDBACK'.webViewBridgeFeatureType,
      WebViewBridgeFeatureType.hapticFeedback,
    );
  });

  test('capability 이름', () {
    expect(HapticFeedbackCapability.feedback, 'hapticFeedback');
  });
}
