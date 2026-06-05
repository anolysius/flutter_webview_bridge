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
  });
}
