import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_webview_bridge/src/bridge/events/refresh_token.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// APP-300 R5 — RefreshToken 도메인별 키 분리.
/// 최우선: **KR/null 은 레거시 키 그대로** (기존 KR 자동로그인 회귀 0).
void main() {
  group('refreshTokenKeyFor — 키 매핑', () {
    test('null → 레거시 키 (회귀 0)', () {
      expect(refreshTokenKeyFor(null), 'flutter_webview_bridge_refresh_token');
    });
    test('KR → 레거시 키 (회귀 0)', () {
      expect(refreshTokenKeyFor('KR'), 'flutter_webview_bridge_refresh_token');
    });
    test('GLOBAL → __global 접미사 키', () {
      expect(
        refreshTokenKeyFor('GLOBAL'),
        'flutter_webview_bridge_refresh_token__global',
      );
    });
  });

  group('RefreshTokenEvent.process — 도메인 격리', () {
    late BuildContext ctx;

    Future<BuildContext> pumpCtx(WidgetTester tester) async {
      late BuildContext c;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) {
              c = context;
              return const SizedBox.shrink();
            },
          ),
        ),
      );
      return c;
    }

    testWidgets('KR write 는 레거시 키에 저장 (기존과 동일 위치)', (tester) async {
      SharedPreferences.setMockInitialValues({});
      ctx = await pumpCtx(tester);

      await RefreshTokenEvent().process(
        ctx,
        action: 'write',
        data: 'kr-token',
        serviceCountry: 'KR',
      );

      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getString('flutter_webview_bridge_refresh_token'),
        'kr-token',
      );
    });

    testWidgets('레거시 저장된 토큰을 KR read 가 그대로 읽음 (업그레이드 회귀 0)', (tester) async {
      // 업그레이드 전부터 레거시 키에 있던 토큰
      SharedPreferences.setMockInitialValues({
        'flutter_webview_bridge_refresh_token': 'legacy-kr-token',
      });
      ctx = await pumpCtx(tester);

      final r = await RefreshTokenEvent().process(
        ctx,
        action: 'read',
        serviceCountry: 'KR',
      );
      expect(r['data'], 'legacy-kr-token');
    });

    testWidgets('KR 와 GLOBAL 토큰은 서로 다른 키 → 격리', (tester) async {
      SharedPreferences.setMockInitialValues({});
      ctx = await pumpCtx(tester);

      await RefreshTokenEvent().process(
        ctx,
        action: 'write',
        data: 'kr-token',
        serviceCountry: 'KR',
      );
      await RefreshTokenEvent().process(
        ctx,
        action: 'write',
        data: 'global-token',
        serviceCountry: 'GLOBAL',
      );

      final kr = await RefreshTokenEvent().process(
        ctx,
        action: 'read',
        serviceCountry: 'KR',
      );
      final global = await RefreshTokenEvent().process(
        ctx,
        action: 'read',
        serviceCountry: 'GLOBAL',
      );
      expect(kr['data'], 'kr-token');
      expect(global['data'], 'global-token');
    });

    testWidgets('GLOBAL delete 는 KR 토큰을 건드리지 않음', (tester) async {
      SharedPreferences.setMockInitialValues({
        'flutter_webview_bridge_refresh_token': 'kr-token',
        'flutter_webview_bridge_refresh_token__global': 'global-token',
      });
      ctx = await pumpCtx(tester);

      await RefreshTokenEvent().process(
        ctx,
        action: 'delete',
        serviceCountry: 'GLOBAL',
      );

      final prefs = await SharedPreferences.getInstance();
      expect(
        prefs.getString('flutter_webview_bridge_refresh_token'),
        'kr-token',
      );
      expect(
        prefs.getString('flutter_webview_bridge_refresh_token__global'),
        isNull,
      );
    });

    testWidgets(
      'v2 read는 request/document/revision을 echo하고 absent를 logout으로 표현하지 않는다',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        ctx = await pumpCtx(tester);

        final response = await RefreshTokenEvent().process(
          ctx,
          action: 'read',
          data: {
            'protocolVersion': 2,
            'requestId': 'request-1',
            'authSessionId': 'attempt-1',
            'documentId': 'doc-1',
            'pageGeneration': 1,
          },
          serviceCountry: 'KR',
          authRevision: 9,
        );

        expect(response['error'], isNull);
        expect(response['data'], {
          'status': 'absent',
          'protocolVersion': 2,
          'requestId': 'request-1',
          'authSessionId': 'attempt-1',
          'documentId': 'doc-1',
          'pageGeneration': 1,
          'authRevision': 9,
        });
      },
    );

    testWidgets(
      'v2 write는 저장 read-back 검증 뒤 token 원문 없이 stored receipt만 반환한다',
      (tester) async {
        SharedPreferences.setMockInitialValues({});
        ctx = await pumpCtx(tester);

        final response = await RefreshTokenEvent().process(
          ctx,
          action: 'write',
          data: {
            'protocolVersion': 2,
            'requestId': 'request-2',
            'documentId': 'doc-2',
            'refreshToken': 'secret-refresh-token',
          },
          serviceCountry: 'KR',
          authRevision: 10,
        );

        expect((response['data'] as Map)['status'], 'stored');
        expect(
          (response['data'] as Map).containsValue('secret-refresh-token'),
          isFalse,
        );
        expect(
          (await SharedPreferences.getInstance()).getString(kRefreshTokenKey),
          'secret-refresh-token',
        );
      },
    );

    testWidgets('stale context write는 저장 직전에 폐기한다', (tester) async {
      SharedPreferences.setMockInitialValues({});
      ctx = await pumpCtx(tester);

      final response = await RefreshTokenEvent().process(
        ctx,
        action: 'write',
        data: 'must-not-persist',
        serviceCountry: 'KR',
        canMutate: () => false,
      );

      expect(response['error'], 'STALE_AUTH_CONTEXT');
      expect(
        (await SharedPreferences.getInstance()).getString(kRefreshTokenKey),
        isNull,
      );
    });
  });

  group('clearAllRefreshTokens — staff 국가 전환 = 완전 로그아웃', () {
    test('양쪽 키(KR 레거시 + GLOBAL) 모두 삭제', () async {
      SharedPreferences.setMockInitialValues({
        'flutter_webview_bridge_refresh_token': 'kr-token',
        'flutter_webview_bridge_refresh_token__global': 'global-token',
      });

      await clearAllRefreshTokens();

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('flutter_webview_bridge_refresh_token'), isNull);
      expect(
        prefs.getString('flutter_webview_bridge_refresh_token__global'),
        isNull,
      );
    });

    test('한쪽만 있어도 에러 없이 동작 (멱등)', () async {
      SharedPreferences.setMockInitialValues({
        'flutter_webview_bridge_refresh_token': 'kr-token',
      });

      await clearAllRefreshTokens();

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('flutter_webview_bridge_refresh_token'), isNull);
      expect(
        prefs.getString('flutter_webview_bridge_refresh_token__global'),
        isNull,
      );
    });

    testWidgets('이미 시작된 양국 write 뒤 clear barrier가 최종 token을 모두 제거한다', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({});
      late BuildContext context;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (value) {
              context = value;
              return const SizedBox.shrink();
            },
          ),
        ),
      );

      final krWrite = RefreshTokenEvent().process(
        context,
        action: 'write',
        data: 'late-kr-token',
        serviceCountry: 'KR',
      );
      final globalWrite = RefreshTokenEvent().process(
        context,
        action: 'write',
        data: 'late-global-token',
        serviceCountry: 'GLOBAL',
      );
      final clear = clearAllRefreshTokens();

      await Future.wait([krWrite, globalWrite, clear]);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(refreshTokenKeyFor('KR')), isNull);
      expect(prefs.getString(refreshTokenKeyFor('GLOBAL')), isNull);
    });

    testWidgets('clear 뒤 queue에 들어온 stale write는 canMutate guard로 폐기한다', (
      tester,
    ) async {
      SharedPreferences.setMockInitialValues({
        refreshTokenKeyFor('KR'): 'old-token',
      });
      late BuildContext context;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (value) {
              context = value;
              return const SizedBox.shrink();
            },
          ),
        ),
      );

      var isCurrent = true;
      final clear = clearAllRefreshTokens();
      isCurrent = false;
      final staleWrite = RefreshTokenEvent().process(
        context,
        action: 'write',
        data: 'must-not-return',
        serviceCountry: 'KR',
        canMutate: () => isCurrent,
      );

      final results = await Future.wait([clear, staleWrite]);
      expect(
        (results.last as Map<String, Object?>)['error'],
        'STALE_AUTH_CONTEXT',
      );
      expect(
        (await SharedPreferences.getInstance()).getString(
          refreshTokenKeyFor('KR'),
        ),
        isNull,
      );
    });
  });
}
