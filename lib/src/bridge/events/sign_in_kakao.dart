import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:kakao_flutter_sdk/kakao_flutter_sdk.dart';

import '../../models/types.dart';
import 'auth_error.dart';
import 'auth_error_mapper.dart';
import 'auth_failure_cause.dart';
import 'kakao_token_policy.dart';

class SignInKakao {
  static final SignInKakao _instance = SignInKakao._internal();
  static SignInKakao get shared => _instance;
  SignInKakao._internal();

  bool _isInitialized = false;

  /// 테스트 seam — 단계별 실패 원인 추적을 SDK 없이 검증하기 위해 SDK 호출만 교체 가능하게 둔다.
  @visibleForTesting
  Future<bool> Function() talkInstalled = isKakaoTalkInstalled;
  @visibleForTesting
  Future<OAuthToken> Function() loginWithTalk = () =>
      UserApi.instance.loginWithKakaoTalk();
  @visibleForTesting
  Future<OAuthToken> Function() loginWithAccount = () =>
      UserApi.instance.loginWithKakaoAccount();

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

      // 실패 원인 추적 — 실패한 단계·직전 단계의 실패 원인·단계 소요시간 (auth_failure_cause.dart).
      var step = KakaoAuthStep.account;
      final stepWatch = Stopwatch()..start();
      String? fallbackFromCause;
      String? fallbackFromDetail;
      bool? kakaoTalkInstalled;

      try {
        String? idToken;

        debugPrint('[SignInKakao] START — isKakaoTalkInstalled check');
        kakaoTalkInstalled = await talkInstalled();
        if (kakaoTalkInstalled) {
          debugPrint('[SignInKakao] STEP loginWithKakaoTalk');
          step = KakaoAuthStep.talk;
          stepWatch.reset();
          try {
            OAuthToken token = await loginWithTalk();
            idToken = token.idToken;
            debugPrint('[SignInKakao] loginWithKakaoTalk OK');
          } catch (error) {
            debugPrint(
              '[SignInKakao] loginWithKakaoTalk FAIL: ${error.runtimeType}',
            );
            // 사용자가 카카오톡 설치 후 디바이스 권한 요청 화면에서 로그인을 취소한 경우,
            // 의도적인 로그인 취소로 보고 카카오계정으로 로그인 시도 없이 로그인 취소로 처리 (예: 뒤로 가기)
            if (error is PlatformException && error.code == 'CANCELED') {
              rethrow;
            }
            // 카카오톡에 연결된 카카오계정이 없는 경우, 카카오계정으로 로그인
            // 카카오톡이 왜 실패했는지는 fallback 실패 원인과 함께 남긴다 (1차 원인 보존).
            fallbackFromCause = kakaoFailureCause(KakaoAuthStep.talk, error);
            fallbackFromDetail = kakaoErrorDetail(error);
            step = KakaoAuthStep.fallback;
            stepWatch.reset();
            try {
              OAuthToken token = await loginWithAccount();
              idToken = token.idToken;
            } catch (error) {
              rethrow;
            }
          }
        } else {
          debugPrint('[SignInKakao] STEP loginWithKakaoAccount (no KakaoTalk)');
          try {
            OAuthToken token = await loginWithAccount();
            idToken = token.idToken;
          } catch (error) {
            rethrow;
          }
        }

        // SDK first-call race 회피 — KakaoSdk 내부 token 적용 비동기.
        // 첫 시도에서 me() 가 'token not found' 등으로 즉시 fail 하는 회귀 차단.
        debugPrint('[SignInKakao] STEP me() — pre-warm 100ms');
        await Future.delayed(const Duration(milliseconds: 100));

        User? user;
        try {
          user = await UserApi.instance.me();
          debugPrint('[SignInKakao] me() OK first attempt');
        } catch (error) {
          debugPrint(
            '[SignInKakao] me() FAIL first attempt: '
            '${error.runtimeType} — retry',
          );
          // 1회 retry — SDK token 적용 추가 대기 후
          await Future.delayed(const Duration(milliseconds: 500));
          try {
            user = await UserApi.instance.me();
            debugPrint('[SignInKakao] me() OK retry');
          } catch (error2) {
            debugPrint('[SignInKakao] me() FAIL retry: ${error2.runtimeType}');
            // idToken 확보가 로그인 본체다. me()는 profile enrichment일 뿐이므로
            // 두 번 실패해도 토큰 교환을 계속하고 web/native me fallback에 맡긴다.
            user = null;
          }
        }

        // 사용자의 추가 동의가 필요한 사용자 정보 동의항목 확인
        List<String> scopes = [];

        if (user?.kakaoAccount?.emailNeedsAgreement == true) {
          scopes.add('account_email');
        }
        if (user?.kakaoAccount?.birthdayNeedsAgreement == true) {
          scopes.add("birthday");
        }
        if (user?.kakaoAccount?.birthyearNeedsAgreement == true) {
          scopes.add("birthyear");
        }
        if (user?.kakaoAccount?.phoneNumberNeedsAgreement == true) {
          scopes.add("phone_number");
        }
        if (user?.kakaoAccount?.profileNeedsAgreement == true) {
          scopes.add("profile");
        }
        if (user?.kakaoAccount?.ageRangeNeedsAgreement == true) {
          scopes.add("age_range");
        }

        final consentScopes = kakaoConsentScopesWithOpenId(scopes);
        if (consentScopes.isNotEmpty) {
          // scope 목록을 전달하여 동의항목 추가 동의 요청
          // 지정된 동의항목에 대한 동의 화면을 거쳐 다시 카카오 로그인 수행
          step = KakaoAuthStep.scopes;
          stepWatch.reset();
          try {
            OAuthToken token = await UserApi.instance.loginWithNewScopes(
              consentScopes,
            );
            idToken = selectKakaoIdToken(
              current: idToken,
              reissued: token.idToken,
            );
          } catch (e) {
            rethrow;
          }
        }

        if (idToken == null || idToken.isEmpty) {
          step = KakaoAuthStep.idToken;
          stepWatch.reset();
          throw StateError('KAKAO_ID_TOKEN_MISSING');
        }
        sendData['data'] = {
          'id': user?.id,
          'displayName': user?.kakaoAccount?.profile?.nickname,
          'email': user?.kakaoAccount?.email,
          'photoUrl': user?.kakaoAccount?.profile?.profileImageUrl,
          'idToken': idToken,
        };
        debugPrint('[SignInKakao] SUCCESS sendData ready');
      } catch (e) {
        // bridge.dart catch 의 `e is AuthError` 분기에서 AUTH_ERROR payload 발화.
        debugPrint(
          '[SignInKakao] OUTER CATCH — throw AuthError: ${e.runtimeType}',
        );
        final code = mapKakaoError(e);
        final safeCause = mapKakaoSafeCause(e);
        throw AuthError(
          code,
          e.runtimeType.toString(),
          nativeSdkErrorCode: 'KAKAO_${safeCause.toUpperCase()}',
          failureCause: kakaoFailureCause(step, e),
          failureContext: {
            'stepElapsedMs': stepWatch.elapsedMilliseconds,
            'kakaoTalkInstalled': ?kakaoTalkInstalled,
            'fallbackFromCause': ?fallbackFromCause,
            'fallbackFromDetail': ?fallbackFromDetail,
            'providerErrorDetail': ?kakaoErrorDetail(e),
          },
        );
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
