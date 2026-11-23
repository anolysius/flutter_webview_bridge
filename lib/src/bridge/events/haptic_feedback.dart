import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 웹이 기능 지원 여부를 판단할 이름. [WebViewToken.capabilities] 에 실린다.
abstract final class HapticFeedbackCapability {
  static const feedback = 'hapticFeedback';
}

/// `HAPTIC_FEEDBACK` 의 `data.style` 값. Flutter 기본 [HapticFeedback] 5종이다.
enum HapticStyle {
  light,
  medium,
  heavy,
  selection,
  vibrate;

  static HapticStyle? parse(Object? value) {
    for (final style in values) {
      if (style.name == value) return style;
    }
    return null;
  }
}

/// 웹 → 앱 단방향. 웹이 고른 순간에 기기 햅틱을 울린다.
///
/// - 웹은 응답을 기다리지 않는다. 결과를 돌려주지 않고, 실패는 로그만 남긴다.
/// - 모르는 `style` 은 울리지 않는다(새 웹이 옛 앱에 새 종류를 보내도 무해).
/// - [minInterval] 안에 연달아 오면 뒤의 것은 버린다(스크롤·연타로 진동이 겹치지 않게).
/// - iOS 는 시스템 설정의 "시스템 햅틱"을 꺼 두면 OS 가 울리지 않는다.
class HapticFeedbackEvent {
  HapticFeedbackEvent({
    Future<void> Function(HapticStyle style)? perform,
    DateTime Function()? now,
  }) : _perform = perform ?? _defaultPerform,
       _now = now ?? DateTime.now;

  static const minInterval = Duration(milliseconds: 50);

  final Future<void> Function(HapticStyle style) _perform;
  final DateTime Function() _now;
  DateTime? _lastAt;

  Future<void> process(dynamic data) async {
    final raw = data is Map ? data['style'] : null;
    final style = HapticStyle.parse(raw);
    if (style == null) {
      debugPrint('[HapticFeedback] unknown style: $raw');
      return;
    }
    final now = _now();
    final last = _lastAt;
    if (last != null && now.difference(last) < minInterval) return;
    _lastAt = now;
    try {
      await _perform(style);
    } catch (e) {
      debugPrint('[HapticFeedback] failed (${style.name}): ${e.runtimeType}');
    }
  }

  static Future<void> _defaultPerform(HapticStyle style) => switch (style) {
    HapticStyle.light => HapticFeedback.lightImpact(),
    HapticStyle.medium => HapticFeedback.mediumImpact(),
    HapticStyle.heavy => HapticFeedback.heavyImpact(),
    HapticStyle.selection => HapticFeedback.selectionClick(),
    HapticStyle.vibrate => HapticFeedback.vibrate(),
  };
}
