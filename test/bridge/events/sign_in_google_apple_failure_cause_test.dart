import 'dart:async' show TimeoutException;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webview_bridge/src/bridge/events/auth_error.dart';
import 'package:flutter_webview_bridge/src/bridge/events/auth_error_mapper.dart';
import 'package:flutter_webview_bridge/src/bridge/events/sign_in_apple.dart';
import 'package:flutter_webview_bridge/src/bridge/events/sign_in_google.dart';
import 'package:google_sign_in/google_sign_in.dart';
import 'package:sign_in_with_apple/sign_in_with_apple.dart';

void main() {
  late BuildContext context;
  final google = SignInGoogle.shared;
  final apple = SignInApple.shared;
  final originals = (
    google.supportsAuthenticate,
    google.authenticate,
    apple.getCredential,
  );

  tearDown(() {
    google
      ..supportsAuthenticate = originals.$1
      ..authenticate = originals.$2;
    apple.getCredential = originals.$3;
  });

  Future<AuthError> loginFailure(
    WidgetTester tester,
    Future<Object?> Function(BuildContext) process,
  ) async {
    await tester.pumpWidget(
      Builder(
        builder: (c) {
          context = c;
          return const SizedBox();
        },
      ),
    );
    try {
      await process(context);
    } on AuthError catch (e) {
      return e;
    }
    fail('AuthError 가 나야 한다');
  }

  group('구글', () {
    testWidgets('SDK 분류가 같아도 원인 코드는 enum 별로 다르다', (tester) async {
      google.supportsAuthenticate = () => true;
      final causes = <String?>{};
      for (final code in [
        GoogleSignInExceptionCode.clientConfigurationError,
        GoogleSignInExceptionCode.providerConfigurationError,
        GoogleSignInExceptionCode.uiUnavailable,
      ]) {
        google.authenticate = (_) async =>
            throw GoogleSignInException(code: code);
        final error = await loginFailure(
          tester,
          (c) => google.process(c, action: 'login'),
        );
        // 기존 화면용 분류는 셋 다 SDK_INIT_FAILED 로 같다 (하위호환).
        expect(error.code, AuthErrorCode.sdkInitFailed);
        expect(error.failureContext['stepElapsedMs'], isA<int>());
        causes.add(error.failureCause);
      }
      expect(causes, {
        'GOOGLE_SIGN_IN_CLIENT_CONFIGURATION_ERROR',
        'GOOGLE_SIGN_IN_PROVIDER_CONFIGURATION_ERROR',
        'GOOGLE_SIGN_IN_UI_UNAVAILABLE',
      });
    });

    testWidgets('authenticate 미지원 플랫폼은 별도 원인', (tester) async {
      google.supportsAuthenticate = () => false;
      final error = await loginFailure(
        tester,
        (c) => google.process(c, action: 'login'),
      );
      expect(error.failureCause, 'GOOGLE_SIGN_IN_AUTHENTICATE_UNSUPPORTED');
      expect(error.nativeSdkErrorCode, 'GOOGLE_SDK_INIT_FAILED');
    });

    testWidgets('네트워크 타임아웃', (tester) async {
      google
        ..supportsAuthenticate = (() => true)
        ..authenticate = ((_) async => throw TimeoutException('t'));
      final error = await loginFailure(
        tester,
        (c) => google.process(c, action: 'login'),
      );
      expect(error.failureCause, 'GOOGLE_SIGN_IN_NETWORK_TIMEOUT');
    });
  });

  group('애플', () {
    testWidgets('unknown 계열 4종이 서로 다른 원인으로 남는다', (tester) async {
      final causes = <String?>{};
      for (final code in [
        AuthorizationErrorCode.unknown,
        AuthorizationErrorCode.credentialExport,
        AuthorizationErrorCode.credentialImport,
        AuthorizationErrorCode.matchedExcludedCredential,
      ]) {
        apple.getCredential = () async =>
            throw SignInWithAppleAuthorizationException(
              code: code,
              message: 'private',
            );
        final error = await loginFailure(
          tester,
          (c) => apple.process(c, action: 'login'),
        );
        expect(error.code, AuthErrorCode.unknown);
        causes.add(error.failureCause);
      }
      expect(causes.length, 4);
    });

    testWidgets('사용자 취소', (tester) async {
      apple.getCredential = () async =>
          throw const SignInWithAppleAuthorizationException(
            code: AuthorizationErrorCode.canceled,
            message: 'x',
          );
      final error = await loginFailure(
        tester,
        (c) => apple.process(c, action: 'login'),
      );
      expect(error.failureCause, 'APPLE_AUTHORIZE_CANCELED');
      expect(error.code, AuthErrorCode.userCancelled);
    });
  });
}
