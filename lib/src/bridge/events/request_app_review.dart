import 'package:flutter/foundation.dart';
import 'package:in_app_review/in_app_review.dart';

/// 웹 → 앱 단방향. OS 별점 창(in_app_review)을 띄운다.
///
/// 웹은 응답을 기다리지 않으므로 결과를 돌려주지 않고, 실패는 로그만 남긴다.
/// 실제 노출 여부·빈도는 OS(App Store / Play) 정책이 결정한다.
class RequestAppReviewEvent {
  Future<void> process(dynamic data) async {
    final round = data is Map ? data['round'] : null;
    try {
      final inAppReview = InAppReview.instance;
      if (!await inAppReview.isAvailable()) {
        debugPrint('[RequestAppReview] unavailable (round=$round)');
        return;
      }
      await inAppReview.requestReview();
      debugPrint('[RequestAppReview] requested (round=$round)');
    } catch (e) {
      debugPrint('[RequestAppReview] failed (round=$round): $e');
    }
  }
}
