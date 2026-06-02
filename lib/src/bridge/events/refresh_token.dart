import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../models/types.dart';

const kRefreshTokenKey = 'flutter_webview_bridge_refresh_token';

class RefreshTokenEvent {
  Future<Map<String, Object?>> process(
    BuildContext context, {
    required String action,
    dynamic data,
  }) async {
    Map<String, Object?> sendData = {};

    final SharedPreferences prefs = await SharedPreferences.getInstance();

    if (action == 'read') {
      sendData['type'] = WebViewBridgeFeatureType.refreshTokenRead.value;

      // Get the stored refresh token
      final String? refreshToken = prefs.getString(kRefreshTokenKey);
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
        final r = await prefs.setString(kRefreshTokenKey, refreshToken);
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
      final r = await prefs.remove(kRefreshTokenKey);
      if (r == true) {
        sendData['data'] = '';
      } else {
        sendData['error'] = 'Failed to delete the stored refresh token';
      }
    }

    return sendData;
  }
}
