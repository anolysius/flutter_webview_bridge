import '../../models/types.dart';

/// 서비스 국가(도메인 라우팅) 브릿지 이벤트 — APP-300 R5.
///
/// - `SERVICE_COUNTRY_QUERY` (웹→앱→웹): 웹이 현재 적용된 서비스 국가를 조회.
///   네이티브가 주입받은 serviceCountry 를 즉시 응답한다.
/// - `SERVICE_COUNTRY_CHANGE` (웹→앱): 웹의 국가 변경 UI 선택을 네이티브에 전달.
///   네이티브(앱)는 override + 도메인 reload 를 수행한다(앱측 콜백).
class ServiceCountryEvent {
  /// 현재 serviceCountry 응답 페이로드. 미주입 시 KR(현행 기본값).
  Map<String, Object?> queryResponse(String? serviceCountry) {
    return {
      'type': WebViewBridgeFeatureType.serviceCountryQuery.value,
      'data': {'serviceCountry': serviceCountry ?? 'KR'},
    };
  }

  /// CHANGE 메시지에서 요청 국가코드 추출. `{serviceCountry|country: 'KR'|'GLOBAL'}` 또는 String.
  String? parseRequestedCountry(dynamic data) {
    if (data is String && data.isNotEmpty) return data.toUpperCase();
    if (data is Map) {
      final v = (data['serviceCountry'] ?? data['country']) as String?;
      return (v != null && v.isNotEmpty) ? v.toUpperCase() : null;
    }
    return null;
  }
}
