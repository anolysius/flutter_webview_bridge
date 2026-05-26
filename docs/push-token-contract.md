# Push Token Bridge Contract

> Flutter ↔ WebView FCM 푸시 토큰 전달 규약 (v1.0)
> 작성일: 2026-05-25 | 대상: sazo-ko-client-web 웹 팀
> Source of truth: 본 문서. 코드 시그니처 변경 시 본 문서 동기 갱신.

## TL;DR

Flutter 앱이 FCM 토큰을 수집해 webview 로 `PUSH_TOKEN` 이벤트로 전달한다. 웹은 이 이벤트의 `data.token` 을 받아 서버 `POST /api/user/mobile-device-me/register` 로 등록한다. 토큰은 **초기 발급** + **갱신** + **웹 조회 응답** 3 경로로 흘러온다.

---

## 1. 이벤트 타입

- 타입명: **`PUSH_TOKEN`** (string literal)
- transport: webview `postMessage` (Flutter → JS) — `window.addEventListener('message', e => e.data)` 로 수신
- enum 정의 (Dart 측): `WebViewBridgeFeatureType.pushToken` → value `'PUSH_TOKEN'`
  ([`packages/flutter_webview_bridge/lib/src/models/types.dart`](../../../packages/flutter_webview_bridge/lib/src/models/types.dart))

본 contract 는 **단일 이벤트 타입** 으로 초기 / 갱신 / 조회 응답 모두를 다룬다. 구분은 payload 의 `isRefresh` 플래그로 한다.

---

## 2. Payload Schema

TypeScript 표기:

```typescript
interface PushTokenMessage {
  type: 'PUSH_TOKEN';
  data: PushTokenData;
}

interface PushTokenData {
  /**
   * FCM token. null 가능 — 권한 거부 / 발급 전 / 조회 응답 시 캐시 비어있음.
   * non-null 일 때만 서버 register 호출.
   */
  token: string | null;

  /** 플랫폼 식별 — 서버 측 device 분류용 */
  platform: 'ios' | 'android';

  /**
   * true: FirebaseMessaging.onTokenRefresh 발화 (token rotate).
   *   웹은 dedup 후 register API 재호출 권장 (서버가 idempotent 처리)
   * false: 초기 발급 또는 조회 응답
   */
  isRefresh: boolean;
}
```

### 필드 의미 상세

| 필드 | 타입 | 의미 | 값 결정 시점 |
|---|---|---|---|
| `type` | `'PUSH_TOKEN'` | 이벤트 식별자 (불변) | 컴파일 타임 |
| `data.token` | `string \| null` | FCM 토큰 raw string. APNs 토큰 아님 (FCM 가 내부 변환). null 일 수 있음 | Firebase SDK 응답 시점 |
| `data.platform` | `'ios' \| 'android'` | `Platform.isIOS ? 'ios' : 'android'` | Flutter 송신 시 |
| `data.isRefresh` | `boolean` | 송신 trigger 구분 | Flutter 송신 시 |

> **APNs 토큰**: 본 contract scope 외. 서버가 FCM 발송만 하면 충분. 향후 APNs 직접 발송 필요 시 별도 task (`apnsToken` 필드 또는 `APNS_TOKEN` 이벤트 신설).

---

## 3. 송신 시점 (5 시나리오)

| # | 시점 | trigger (Flutter 측) | payload 형태 | 빈도 |
|---|---|---|---|---|
| 1 | **초기 발급** | `registerTokenWithPermission()` 성공 (권한 grant 후 token 발급 완료) | `{token: <string>, platform, isRefresh: false}` | 1회 / 앱 cold-start |
| 2 | **갱신** | `FirebaseMessaging.instance.onTokenRefresh` stream emit (Firebase SDK 가 token rotate 판단) | `{token: <string>, platform, isRefresh: true}` | 비결정적, 드묾 |
| 3 | **웹 조회 응답 (token 있음)** | 웹이 `sendToNative({type:'PUSH_TOKEN', data:null})` 호출 + Flutter 측 캐시 `WebViewToken.fcmToken != null` | `{token: <string>, platform, isRefresh: false}` | 웹 호출 시 |
| 4 | **웹 조회 응답 (token 없음)** | 위와 동일 + 캐시 `== null` (권한 거부 / 아직 발급 전) | `{token: null, platform, isRefresh: false}` | 웹 호출 시 |
| 5 | **권한 거부** | `FirebaseMessaging.requestPermission()` 이 `authorized` 아님 | (push 송신 안 함) — 단 웹 조회 시 #4 동일 처리 | — |

### 보장 / 미보장

- ✅ **순서 보장**: 동일 launch 내에서 #1 (초기) 가 #2 (갱신) 보다 먼저 발생
- ✅ **WebViewBridge 큐잉**: webview channel 미초기화 시 Flutter 측이 큐잉 후 ready 시 flush
- ⚠️ **page navigation race**: cold-start 후 page load (웹 측 `addEventListener` 등록) 가 #1 발화보다 늦으면 메시지 유실 가능. **웹 측은 페이지 mount 직후 `sendToNative({type:'PUSH_TOKEN', data:null})` 로 캐시 조회 수행 권장** (시나리오 #3/#4)
- ⚠️ **갱신 idempotency**: 동일 token 으로 갱신 발화 가능 (Firebase SDK 동작). 웹이 last-known-token 비교 후 register 호출 dedup 권장

---

## 4. 예시 JSON

### 시나리오 #1 — 초기 발급 (iOS)

```json
{
  "type": "PUSH_TOKEN",
  "data": {
    "token": "fAB...:APA91bH...",
    "platform": "ios",
    "isRefresh": false
  }
}
```

### 시나리오 #2 — 갱신 (Android)

```json
{
  "type": "PUSH_TOKEN",
  "data": {
    "token": "eXm...:APA91bF...",
    "platform": "android",
    "isRefresh": true
  }
}
```

### 시나리오 #4 — 웹 조회 응답 (캐시 없음, iOS)

```json
{
  "type": "PUSH_TOKEN",
  "data": {
    "token": null,
    "platform": "ios",
    "isRefresh": false
  }
}
```

---

## 5. 웹 측 구현 가이드

### 5.1 메시지 핸들러 등록

```typescript
// 예시 위치 (실제는 sazo-ko-client-web 의 webview-bridge layer 에서 결정)
window.addEventListener('message', (event) => {
  const msg = parseMessage(event.data); // {type, data}
  if (msg?.type === 'PUSH_TOKEN') {
    handlePushToken(msg.data);
  }
});
```

> 등록 위치: webview 와 통신하는 단일 SOT bridge 모듈. App 전역 mount 직후 (가능한 가장 빠른 시점). React 의 경우 root layout 의 `useEffect(..., [])` 권장.

### 5.2 register API 호출 정책

```typescript
async function handlePushToken({ token, platform, isRefresh }: PushTokenData) {
  // 1. null guard
  if (token === null) {
    // 캐시 비어있음 — 향후 갱신 또는 초기 발급 대기.
    // register 호출 skip.
    return;
  }

  // 2. dedup (선택, 권장)
  const lastToken = readLocalCache('lastFcmToken');
  if (lastToken === token && !isRefresh) {
    // 동일 token 재수신 (조회 응답 등) — skip
    return;
  }

  // 3. 서버 등록
  await fetch('/api/user/mobile-device-me/register', {
    method: 'POST',
    body: JSON.stringify({ token, platform /* ... */ }),
  });

  writeLocalCache('lastFcmToken', token);
}
```

> 서버 API spec: 본 contract scope 외. sazo-ko-client-web 의 server API 모듈 참고.
> idempotency: 서버가 동일 token 재등록을 안전히 처리 (upsert) 한다고 가정. 동일하지 않으면 클라이언트 dedup 가 책임.

### 5.3 token=null 응답 처리 (시나리오 #4 대응)

웹이 `sendToNative({type:'PUSH_TOKEN', data:null})` 로 캐시 조회 시 받을 수 있는 응답:
- `data.token != null`: register 호출 (이미 dedup 후)
- `data.token == null`: skip + 향후 시나리오 #1 (초기 발급) 또는 #2 (갱신) push 대기

`null` 응답을 에러로 취급하지 말 것 — 권한 미부여 또는 cold-start 직후의 정상 상태.

### 5.4 isRefresh:true 처리

- 갱신은 비결정적 (Firebase SDK 가 token rotate 판단). 빈도 낮음
- `isRefresh: true` 이면 dedup 무시하고 register API 강제 호출 권장 (서버가 outdated token 으로 push 보내는 것 방지)

---

## 6. Out of scope

- **서버 측 register API spec / DB schema** — sazo-ko-client-web 별도 task
- **APNs 토큰** — FCM only. 서버가 Firebase Cloud Messaging 으로 발송한다는 전제. APNs 직접 발송 path 필요해질 시 별도 task (`push-token-server-sync` 또는 신규 contract v2)
- **silent push** — iOS DUET 의존 platform-level 이슈, push-deeplink-recovery 이니셔티브 task 03b 에서 별도 처리됨
- **token 삭제 (logout)** — 본 contract 는 token 등록만. logout 시 delete API 는 별도 endpoint 가정

---

## 7. 변경 이력

| 일자 | 버전 | 변경 |
|---|---|---|
| 2026-05-25 | 1.0 | 신규. PUSH_TOKEN 단일 이벤트 + token nullable + isRefresh 플래그. push-deeplink-recovery 이니셔티브 task push-token-contract 산출물. |
