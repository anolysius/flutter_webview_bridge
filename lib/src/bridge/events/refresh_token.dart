import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../models/types.dart';

const kRefreshTokenKey = 'flutter_webview_bridge_refresh_token';

/// 서비스 국가별 RefreshToken 저장 키 (APP-300 R5 — 도메인별 세션 격리).
///
/// ⚠️ **KR / null 은 레거시 키 그대로** — 기존 KR 사용자의 저장된 토큰을 보존해
/// 업그레이드 시 자동로그인이 깨지지 않게 한다(회귀 0). 그 외(GLOBAL)는 접미사 키.
String refreshTokenKeyFor(String? serviceCountry) {
  if (serviceCountry == null || serviceCountry == 'KR') {
    return kRefreshTokenKey;
  }
  return '${kRefreshTokenKey}__${serviceCountry.toLowerCase()}';
}

/// 모든 서비스 국가의 RefreshToken 을 일괄 삭제한다.
///
/// 서비스 국가 전환(staff)은 "완전 로그아웃" 의미이므로 KR 레거시 키와 GLOBAL(`__global`)
/// 키를 **둘 다** 제거한다 — 전환 후 어느 도메인도 자동로그인되지 않도록. 단일 키만 지우는
/// 기존 `RefreshTokenEvent(action: 'delete')`(웹 메시지 기반) 와 달리 네이티브가 직접 호출한다.
Future<void> clearAllRefreshTokens() async {
  final SharedPreferences prefs = await SharedPreferences.getInstance();
  await prefs.remove(refreshTokenKeyFor('KR')); // 레거시 키
  await prefs.remove(refreshTokenKeyFor('GLOBAL')); // __global
}

class RefreshTokenEvent {
  Future<Map<String, Object?>> process(
    BuildContext context, {
    required String action,
    dynamic data,
    String? serviceCountry,
  }) async {
    Map<String, Object?> sendData = {};

    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String storageKey = refreshTokenKeyFor(serviceCountry);

    if (action == 'read') {
      sendData['type'] = WebViewBridgeFeatureType.refreshTokenRead.value;

      // Get the stored refresh token
      final String? refreshToken = prefs.getString(storageKey);
      if (refreshToken != null) {
        sendData['data'] = refreshToken;
      } else {
        sendData['error'] = 'No refresh token found';
      }
    } else if (action == 'write') {
      sendData['type'] = WebViewBridgeFeatureType.refreshTokenWrite.value;

      // Set the refresh token. Newer web clients send confirm metadata together
      // with the token so native can tell which document confirmed SSO.
      final refreshToken = data is String
          ? data
          : data is Map
          ? (data['refreshToken'] ?? data['token']) as String?
          : null;
      if (refreshToken != null) {
        final r = await prefs.setString(storageKey, refreshToken);
        if (r == true) {
          sendData['data'] = refreshToken;
        } else {
          sendData['error'] = 'Failed to store the refresh token';
        }
      } else {
        sendData['error'] =
            'Refresh token data is required for store refresh write';
      }
    } else if (action == 'delete') {
      sendData['type'] = WebViewBridgeFeatureType.refreshTokenDelete.value;

      // Delete the stored refresh token
      final r = await prefs.remove(storageKey);
      if (r == true) {
        sendData['data'] = '';
      } else {
        sendData['error'] = 'Failed to delete the stored refresh token';
      }
    }

    return sendData;
  }
}
