import 'dart:async';

import 'package:flutter/material.dart';
import 'package:google_sign_in/google_sign_in.dart';

import '../../models/types.dart';
import 'auth_error.dart';
import 'auth_error_mapper.dart';

class SignInGoogle {
  static final SignInGoogle _instance = SignInGoogle._internal();
  static SignInGoogle get shared => _instance;
  SignInGoogle._internal();

  bool _isInitialized = false;

  // Completer<GoogleSignInAccount?>? _loginCompleter;

  // https://developers.google.com/identity/protocols/oauth2/scopes?hl=ko
  final List<String> scopes = <String>[
    'https://www.googleapis.com/auth/userinfo.email',
    'https://www.googleapis.com/auth/userinfo.profile',
    'openid',
  ];

  void initialize({required String? googleServerClientId}) {
    if (_isInitialized) return;
    final GoogleSignIn signIn = GoogleSignIn.instance;
    signIn.initialize(serverClientId: googleServerClientId).then((_) {
      // signIn.authenticationEvents
      //     .listen(_handleAuthenticationEvent)
      //     .onError(_handleAuthenticationError);
      // signIn.attemptLightweightAuthentication();
    });
    _isInitialized = true;
  }

  Future<Map<String, Object?>> process(
    BuildContext context, {
    required String action,
  }) async {
    Map<String, Object?> sendData = {};

    if (action == 'login') {
      sendData['type'] = WebViewBridgeFeatureType.googleSignInLogin.value;
      if (!GoogleSignIn.instance.supportsAuthenticate()) {
        // 이전엔 빈 {} return → webview silent fail. SDK 가용 불가 명시 통보.
        throw AuthError(
          AuthErrorCode.sdkInitFailed,
          'Google sign-in not supported on this platform',
        );
      }
      try {
        final user = await GoogleSignIn.instance.authenticate(scopeHint: scopes);

        final GoogleSignInAuthentication authentication = user.authentication;
        final String? idToken = authentication.idToken;

        sendData['data'] = {
          'id': user.id,
          'displayName': user.displayName,
          'email': user.email,
          'photoUrl': user.photoUrl,
          'idToken': idToken ?? '',
        };
      } catch (e) {
        if (e is AuthError) rethrow;
        final message = e is GoogleSignInException
            ? _errorMessageFromSignInException(e)
            : 'Unknown error: $e';
        throw AuthError(mapGoogleError(e), message);
      }
    }

    if (action == 'logout') {
      sendData['type'] = WebViewBridgeFeatureType.googleSignInLogout.value;
      if (GoogleSignIn.instance.supportsAuthenticate()) {
        try {
          await GoogleSignIn.instance.disconnect();

          sendData['data'] = {
            'id': null,
            'displayName': null,
            'email': null,
            'photoUrl': null,
            'idToken': null,
          };
        } catch (e) {
          String errorMessage = e is GoogleSignInException
              ? _errorMessageFromSignInException(e)
              : 'Unknown error: $e';
          sendData['error'] = errorMessage;
        }
      }
    }

    return sendData;
  }

  /// =========================================================================
  /// Private methods (Event Handlers)
  /// =========================================================================

  // Future<void> _handleAuthenticationEvent(
  //   GoogleSignInAuthenticationEvent event,
  // ) async {
  //   final GoogleSignInAccount? user = switch (event) {
  //     GoogleSignInAuthenticationEventSignIn() => event.user,
  //     GoogleSignInAuthenticationEventSignOut() => null,
  //   };
  //
  //   try {
  //     final GoogleSignInClientAuthorization? clientAuthorization = await user
  //         ?.authorizationClient
  //         .authorizationForScopes(scopes);
  //
  //     GoogleSignInAccount? currentUser = user;
  //     bool isAuthorized = clientAuthorization != null;
  //
  //     if (currentUser != null && isAuthorized) {
  //       // Completer가 있으면 사용자 정보 전달
  //       if (_loginCompleter != null && !_loginCompleter!.isCompleted) {
  //         _loginCompleter!.complete(currentUser);
  //       }
  //     } else {
  //       // 로그인 실패 시
  //       if (_loginCompleter != null && !_loginCompleter!.isCompleted) {
  //         _loginCompleter!.complete(null);
  //       }
  //     }
  //   } catch (e) {
  //     // 에러 발생 시 Completer 완료
  //     if (_loginCompleter != null && !_loginCompleter!.isCompleted) {
  //       _loginCompleter!.completeError(e);
  //     }
  //   }
  // }
  //
  // Future<void> _handleAuthenticationError(Object e) async {
  //   String errorMessage = e is GoogleSignInException
  //       ? _errorMessageFromSignInException(e)
  //       : 'Unknown error: $e';
  //
  //   // 에러 발생 시 Completer 완료
  //   if (_loginCompleter != null && !_loginCompleter!.isCompleted) {
  //     _loginCompleter!.completeError(e);
  //   }
  // }

  String _errorMessageFromSignInException(GoogleSignInException e) {
    return switch (e.code) {
      GoogleSignInExceptionCode.canceled => 'Sign in canceled',
      _ => 'GoogleSignInException ${e.code}: ${e.description}',
    };
  }
}
