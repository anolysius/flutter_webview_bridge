import 'dart:async';

import 'package:flutter/material.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

import '../../models/types.dart';
import 'auth_error.dart';
import 'auth_error_mapper.dart';
import 'auth_failure_cause.dart';

class SignInApple {
  static final SignInApple _instance = SignInApple._internal();
  static SignInApple get shared => _instance;
  SignInApple._internal();

  /// 테스트 seam — 실패 원인 추적을 SDK 없이 검증하기 위해 SDK 호출만 교체 가능하게 둔다.
  @visibleForTesting
  Future<AuthorizationCredentialAppleID> Function() getCredential = () =>
      SignInWithApple.getAppleIDCredential(
        scopes: [
          AppleIDAuthorizationScopes.email,
          AppleIDAuthorizationScopes.fullName,
        ],
      );

  Future<Map<String, Object?>> process(
    BuildContext context, {
    required String action,
  }) async {
    Map<String, Object?> sendData = {};

    if (action == 'login') {
      sendData['type'] = WebViewBridgeFeatureType.appleSignInLogin.value;

      final stepWatch = Stopwatch()..start();
      try {
        String? familyName, givenName, displayName;

        AuthorizationCredentialAppleID appleCredential = await getCredential();

        familyName = appleCredential.familyName;
        givenName = appleCredential.givenName;
        if (familyName != null && givenName != null) {
          displayName = '$givenName $familyName';
        } else if (givenName != null) {
          displayName = givenName;
        } else if (familyName != null) {
          displayName = familyName;
        }

        sendData['data'] = {
          'id': appleCredential.userIdentifier,
          'displayName': displayName,
          'email': appleCredential.email,
          'photoUrl': null,
          'idToken': appleCredential.identityToken,
        };
      } catch (e) {
        final code = mapAppleError(e);
        throw AuthError(
          code,
          e.toString(),
          nativeSdkErrorCode: 'APPLE_$code',
          failureCause: appleFailureCause(e),
          failureContext: {'stepElapsedMs': stepWatch.elapsedMilliseconds},
        );
      }
    }

    if (action == 'logout') {
      sendData['type'] = WebViewBridgeFeatureType.appleSignInLogout.value;
      try {
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
