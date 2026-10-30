import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webview_bridge/src/bridge/events/auth_error.dart';
import 'package:flutter_webview_bridge/src/bridge/events/auth_error_mapper.dart';
import 'package:flutter_webview_bridge/src/bridge/events/sign_in_kakao.dart';
import 'package:kakao_flutter_sdk/kakao_flutter_sdk.dart';

PlatformException _webAuth(int n) => PlatformException(
  code: 'CANCELED',
  message: 'User canceled login.',
  details:
      '작업을 완료할 수 없습니다.(com.apple.AuthenticationServices.WebAuthenticationSession 오류 $n.)',
);

void main() {
  late BuildContext context;
  final kakao = SignInKakao.shared;
  final originals = (
    kakao.talkInstalled,
    kakao.loginWithTalk,
    kakao.loginWithAccount,
  );

  tearDown(() {
    kakao
      ..talkInstalled = originals.$1
      ..loginWithTalk = originals.$2
      ..loginWithAccount = originals.$3;
  });

  Future<AuthError> loginFailure(WidgetTester tester) async {
    await tester.pumpWidget(
      Builder(
        builder: (c) {
          context = c;
          return const SizedBox();
        },
      ),
    );
    try {
      await kakao.process(context, action: 'login');
    } on AuthError catch (e) {
      return e;
    }
    fail('AuthError 가 나야 한다');
  }

  testWidgets('카카오톡 실패 → 카카오계정 fallback 실패: 두 원인을 모두 남긴다', (tester) async {
    kakao
      ..talkInstalled = (() async => true)
      ..loginWithTalk = (() async =>
          throw KakaoClientException(ClientErrorCause.notSupported, 'x'))
      ..loginWithAccount = (() async => throw _webAuth(3));

    final error = await loginFailure(tester);

    expect(error.failureCause, 'KAKAO_FALLBACK_WEBAUTH_3');
    expect(
      error.failureContext['fallbackFromCause'],
      'KAKAO_TALK_CLIENT_NOT_SUPPORTED',
    );
    expect(error.failureContext['kakaoTalkInstalled'], isTrue);
    expect(error.failureContext['stepElapsedMs'], isA<int>());
    // 웹 화면 분기용 기존 값은 그대로 (AC6b·AC9).
    expect(error.code, AuthErrorCode.userCancelled);
    expect(error.nativeSdkErrorCode, 'KAKAO_USER_CANCELLED');
  });

  testWidgets('카카오톡 거절(accessDenied)도 fallback 을 타며 1차 원인이 남는다', (
    tester,
  ) async {
    // accessDenied 는 CANCELED 가 아니므로 기존 흐름대로 카카오계정 fallback 을 탄다.
    kakao
      ..talkInstalled = (() async => true)
      ..loginWithTalk = (() async =>
          throw KakaoAuthException(AuthErrorCause.accessDenied, 'x'))
      ..loginWithAccount = (() async => throw _webAuth(1));

    final error = await loginFailure(tester);

    expect(error.failureCause, 'KAKAO_FALLBACK_WEBAUTH_1');
    expect(
      error.failureContext['fallbackFromCause'],
      'KAKAO_TALK_AUTH_ACCESS_DENIED',
    );
  });

  testWidgets('카카오톡 기기 권한 화면 취소는 fallback 없이 TALK 단계 취소', (tester) async {
    kakao
      ..talkInstalled = (() async => true)
      ..loginWithTalk = (() async => throw PlatformException(code: 'CANCELED'));

    final error = await loginFailure(tester);

    expect(error.failureCause, 'KAKAO_TALK_PLATFORM_CANCELED');
    expect(error.failureContext.containsKey('fallbackFromCause'), isFalse);
  });

  testWidgets('카카오톡 미설치 → 카카오계정 창 취소는 ACCOUNT 단계 WEBAUTH_1', (tester) async {
    kakao
      ..talkInstalled = (() async => false)
      ..loginWithAccount = (() async => throw _webAuth(1));

    final error = await loginFailure(tester);

    expect(error.failureCause, 'KAKAO_ACCOUNT_WEBAUTH_1');
    expect(error.failureContext['kakaoTalkInstalled'], isFalse);
    expect(error.failureContext.containsKey('fallbackFromCause'), isFalse);
  });

  testWidgets('카카오톡 인증 오류(QA 실측 재현): 1차 오류 설명이 fallbackFromDetail 로 남는다', (
    tester,
  ) async {
    kakao
      ..talkInstalled = (() async => true)
      ..loginWithTalk = (() async => throw KakaoAuthException(
        AuthErrorCause.unknown,
        'User  denied access a.b@c.com',
      ))
      ..loginWithAccount = (() async => throw _webAuth(3));

    final error = await loginFailure(tester);

    expect(error.failureCause, 'KAKAO_FALLBACK_WEBAUTH_3');
    expect(
      error.failureContext['fallbackFromCause'],
      'KAKAO_TALK_AUTH_UNKNOWN',
    );
    expect(error.failureContext['fallbackFromDetail'], 'User denied access #');
    // 최종 예외는 KakaoAuthException 이 아니므로 providerErrorDetail 은 없다.
    expect(error.failureContext.containsKey('providerErrorDetail'), isFalse);
    expect(error.code, AuthErrorCode.userCancelled);
  });

  testWidgets('설명 없는 카카오톡 인증 오류는 NONE 으로 남는다', (tester) async {
    kakao
      ..talkInstalled = (() async => true)
      ..loginWithTalk = (() async =>
          throw KakaoAuthException(AuthErrorCause.unknown, null))
      ..loginWithAccount = (() async => throw _webAuth(3));

    final error = await loginFailure(tester);

    expect(error.failureContext['fallbackFromDetail'], 'NONE');
  });

  testWidgets('최종 실패가 카카오 인증 오류면 providerErrorDetail 이 남는다', (tester) async {
    kakao
      ..talkInstalled = (() async => false)
      ..loginWithAccount = (() async => throw KakaoAuthException(
        AuthErrorCause.invalidScope,
        'Invalid scope',
      ));

    final error = await loginFailure(tester);

    expect(error.failureCause, 'KAKAO_ACCOUNT_AUTH_INVALID_SCOPE');
    expect(error.failureContext['providerErrorDetail'], 'Invalid scope');
    expect(error.failureContext.containsKey('fallbackFromDetail'), isFalse);
  });

  testWidgets('카카오 인증 오류가 아닌 실패에는 두 필드가 없다', (tester) async {
    kakao
      ..talkInstalled = (() async => true)
      ..loginWithTalk = (() async =>
          throw KakaoClientException(ClientErrorCause.notSupported, 'x'))
      ..loginWithAccount = (() async => throw _webAuth(1));

    final error = await loginFailure(tester);

    expect(error.failureContext.containsKey('fallbackFromDetail'), isFalse);
    expect(error.failureContext.containsKey('providerErrorDetail'), isFalse);
  });
}
