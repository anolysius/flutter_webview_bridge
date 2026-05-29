import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:kakao_flutter_sdk/kakao_flutter_sdk.dart';

import '../../models/types.dart';
import 'auth_error.dart';
import 'auth_error_mapper.dart';

class SignInKakao {
  static final SignInKakao _instance = SignInKakao._internal();
  static SignInKakao get shared => _instance;
  SignInKakao._internal();

  bool _isInitialized = false;

  void initialize({required String? nativeAppKey, String? javaScriptAppKey}) {
    if (_isInitialized) return;
    KakaoSdk.init(
      nativeAppKey: nativeAppKey,
      javaScriptAppKey: javaScriptAppKey,
    );
    _isInitialized = true;
  }

  Future<Map<String, Object?>> process(
    BuildContext context, {
    required String action,
  }) async {
    Map<String, Object?> sendData = {};

    if (action == 'login') {
      sendData['type'] = WebViewBridgeFeatureType.kakaoSignInLogin.value;

      try {
        String? idToken;

        if (await isKakaoTalkInstalled()) {
          try {
            OAuthToken token = await UserApi.instance.loginWithKakaoTalk();
            idToken = token.idToken;
          } catch (error) {
            // 사용자가 카카오톡 설치 후 디바이스 권한 요청 화면에서 로그인을 취소한 경우,
            // 의도적인 로그인 취소로 보고 카카오계정으로 로그인 시도 없이 로그인 취소로 처리 (예: 뒤로 가기)
            if (error is PlatformException && error.code == 'CANCELED') {
              rethrow;
            }
            // 카카오톡에 연결된 카카오계정이 없는 경우, 카카오계정으로 로그인
            try {
              OAuthToken token = await UserApi.instance.loginWithKakaoAccount();
              idToken = token.idToken;
            } catch (error) {
              rethrow;
            }
          }
        } else {
          try {
            OAuthToken token = await UserApi.instance.loginWithKakaoAccount();
            idToken = token.idToken;
          } catch (error) {
            rethrow;
          }
        }

        User? user;
        try {
          user = await UserApi.instance.me();
        } catch (error) {
          rethrow;
        }

        // 사용자의 추가 동의가 필요한 사용자 정보 동의항목 확인
        List<String> scopes = [];

        if (user.kakaoAccount?.emailNeedsAgreement == true) {
          scopes.add('account_email');
        }
        if (user.kakaoAccount?.birthdayNeedsAgreement == true) {
          scopes.add("birthday");
        }
        if (user.kakaoAccount?.birthyearNeedsAgreement == true) {
          scopes.add("birthyear");
        }
        if (user.kakaoAccount?.phoneNumberNeedsAgreement == true) {
          scopes.add("phone_number");
        }
        if (user.kakaoAccount?.profileNeedsAgreement == true) {
          scopes.add("profile");
        }
        if (user.kakaoAccount?.ageRangeNeedsAgreement == true) {
          scopes.add("age_range");
        }

        if (scopes.isNotEmpty) {
          // OpenID Connect 사용 시
          // scope 목록에 "openid" 문자열을 추가하고 요청해야 함
          // 해당 문자열을 포함하지 않은 경우, ID 토큰이 재발급되지 않음
          // scopes.add("openid")

          // scope 목록을 전달하여 동의항목 추가 동의 요청
          // 지정된 동의항목에 대한 동의 화면을 거쳐 다시 카카오 로그인 수행
          try {
            OAuthToken token = await UserApi.instance.loginWithNewScopes(
              scopes,
            );
            idToken = token.idToken;
          } catch (e) {
            rethrow;
          }
        }

        sendData['data'] = {
          'id': user.id,
          'displayName': user.kakaoAccount?.profile?.nickname,
          'email': user.kakaoAccount?.email,
          'photoUrl': user.kakaoAccount?.profile?.profileImageUrl,
          'idToken': idToken,
        };
      } catch (e) {
        // bridge.dart catch 의 `e is AuthError` 분기에서 AUTH_ERROR payload 발화.
        throw AuthError(mapKakaoError(e), e.toString());
      }
    }

    if (action == 'logout') {
      sendData['type'] = WebViewBridgeFeatureType.kakaoSignInLogout.value;
      try {
        await UserApi.instance.logout();
        sendData['data'] = {
          'id': null,
          'displayName': null,
          'email': null,
          'photoUrl': null,
          'idToken': null,
        };
      } catch (e) {
        sendData['error'] = e.toString();
      }
    }

    return sendData;
  }
}
