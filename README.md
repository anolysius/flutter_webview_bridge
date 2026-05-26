# Flutter WebView Bridge

Flutter 앱과 웹뷰 간 브릿지 통신을 위한 JavaScript API

## 💡 주요 특징

- **자동 FCM 토큰 관리**: Firebase 이벤트 (초기 발급 / 갱신) 발생 시 `PUSH_TOKEN` postMessage 자동 발화. 자세한 contract: [`docs/push-token-contract.md`](./docs/push-token-contract.md)
- **실시간 앱 상태 감지**: 앱이 백그라운드/포그라운드로 전환될 때 자동 알림
- **크로스 플랫폼**: iOS/Android 모두 지원
- **Base64 이미지**: 카메라/갤러리에서 선택한 이미지를 Base64로 반환

## ⚠️ 주의사항

- **deviceId**: 앱 재설치 시 변경될 수 있음 (iOS: identifierForVendor, Android: ANDROID_ID)
- **콜백 함수**: `callbackAppState`와 `callbackPostMessage`는 반드시 구현해야 함
- **채널명**: `IN_APP_WEBVIEW_BRIDGE_CHANNEL` 정확히 사용해야 함

## 🚀 빠른 시작

### 1. WebView 브릿지 설정

```typescript
// 필수: 네이티브와 통신할 채널 설정
interface WindowWithWebView extends Window {
    IN_APP_WEBVIEW_BRIDGE_CHANNEL?: {
        postMessage: (message: string) => void;
    };
}

// 네이티브에 메시지 전송
const sendToNative = (message: any) => {
    if (window.IN_APP_WEBVIEW_BRIDGE_CHANNEL?.postMessage) {
        window.IN_APP_WEBVIEW_BRIDGE_CHANNEL.postMessage(JSON.stringify(message));
    }
};
```

### 2. 콜백 함수 구현

```typescript
// 앱 상태 변경 콜백 (필수)
window.callbackAppState = (data: string) => {
    const response = JSON.parse(data);
    console.log('앱 상태:', response.data.state); // resumed, paused, inactive 등
};

// 네이티브에서 오는 모든 메시지 콜백 (필수)
window.callbackPostMessage = (data: string) => {
    const response = JSON.parse(data);
    // 메시지 타입별 처리
};
```

## 📱 앱 생명주기 상태

| 상태 | 설명 |
|------|------|
| `resumed` | 앱 활성화 (포그라운드) |
| `paused` | 앱 백그라운드 |
| `inactive` | 앱 전환 중 |
| `detached` | 앱 종료 직전 |
| `hidden` | 앱 숨겨짐 |

**콜백 응답:**
```json
{
  "type": "APP_STATE_CHANGE",
  "data": {
    "state": "resumed"
  }
}
```

## 📋 API 사용법

### 기본 요청 구조
```typescript
const request = {
    type: "API_NAME",
    data: { /* 필요한 데이터 */ }
};
sendToNative(request);
```

### Google Sign-In

**요청:**
구글 로그인
```typescript
sendToNative({ type: "GOOGLE_SIGN_IN_LOGIN", data: null });
```
**응답:**
```json
{
  "type": "GOOGLE_SIGN_IN_LOGIN",
  "data": {
    "id": "12345678901234567890",
    "displayName": "User Name",
    "email": "abc@gmail.com", 
    "photoUrl": "https://lh3.googleusercontent.com/a/AAcHTte...",
    "idToken": "eyjhbGci0iJ9.eyJhdWQiOiIxMDY2NjY3NzM4MzItZ..."
  }
}
```

**요청:**
구글 로그아웃
```typescript
sendToNative({ type: "GOOGLE_SIGN_IN_LOGOUT", data: null });
```
**응답:**
```json
{
  "type": "GOOGLE_SIGN_IN_LOGOUT",
  "data": {
    "id": "",
    "displayName": "",
    "email": "", 
    "photoUrl": "",
    "idToken": ""
  }
}
```

### Apple Sign-In

⚠️ 현재는 iOS에서만 지원

**요청:**
애플 로그인
```typescript
sendToNative({ type: "APPLE_SIGN_IN_LOGIN", data: null });
```
**응답:**
```json
{
  "type": "APPLE_SIGN_IN_LOGIN",
  "data": {
    "id": "12345678901234567890",
    "displayName": "User Name",
    "email": "abc@gmail.com", 
    "photoUrl": null,
    "idToken": "eyjhbGci0iJ9.eyJhdWQiOiIxMDY2NjY3NzM4MzItZ..."
  }
}
```

**요청:**
애플 로그아웃 

⚠️ 애플 로그아웃은 지원 하지 않음.
```typescript
sendToNative({ type: "APPLE_SIGN_IN_LOGOUT", data: null });
```
**응답:**
```json
{
  "type": "APPLE_SIGN_IN_LOGOUT",
  "data": {
    "id": "",
    "displayName": "",
    "email": "", 
    "photoUrl": "",
    "idToken": ""
  }
}
```

### Kakao Sign-In

**요청:**
카카오 로그인
```typescript
sendToNative({ type: "KAKAO_SIGN_IN_LOGIN", data: null });
```
**응답:**
```json
{
  "type": "KAKAO_SIGN_IN_LOGIN",
  "data": {
    "id": "12345678901234567890",
    "displayName": "User Name",
    "email": "abc@gmail.com", 
    "photoUrl": "https://k.kakaocdn.net/dn/J2zIJ/btsFQtnO1ZV/pK1jrKBXKv3L5bRiOlRfP1...",
    "idToken": "eyjhbGci0iJ9.eyJhdWQiOiIxMDY2NjY3NzM4MzItZ..."
  }
}
```

**요청:**
카카오 로그아웃
```typescript
sendToNative({ type: "KAKAO_SIGN_IN_LOGOUT", data: null });
```
**응답:**
```json
{
  "type": "KAKAO_SIGN_IN_LOGOUT",
  "data": {
    "id": "",
    "displayName": "",
    "email": "", 
    "photoUrl": "",
    "idToken": ""
  }
}
```

### RefreshToken

**요청:**
RefreshToken 읽기
```typescript
sendToNative({ type: "REFRESH_TOKEN_READ", data: null });
```
**응답:**
```json
{
  "type": "REFRESH_TOKEN_READ",
  "data": "eyjhbGci0iJ9.eyJhdWQiOiIxMDY2NjY3NzM4MzItZ..."
}
```
**요청:**
RefreshToken 저장
```typescript
sendToNative({ type: "REFRESH_TOKEN_WRITE", data: "eyjhbGci0iJ9.eyJhdWQiOiIxMDY2NjY3NzM4MzItZ..."});
```
**응답:**
```json
{
  "type": "REFRESH_TOKEN_WRITE",
  "data": "eyjhbGci0iJ9.eyJhdWQiOiIxMDY2NjY3NzM4MzItZ..."
}
```

**요청:**
RefreshToken 삭제
```typescript
sendToNative({ type: "REFRESH_TOKEN_DELETE", data: null });
```
**응답:**
```json
{
  "type": "REFRESH_TOKEN_DELETE",
  "data": ""
}
```

### 푸시 알림

`PUSH_TOKEN` 이벤트는 두 방향:
- **Flutter → Web (push)**: 초기 발급 / 갱신 시 자동 발화
- **Web → Flutter (query) → Web (response)**: 웹이 캐시 조회 호출 시 응답

**Web → Flutter 조회 요청:**
```typescript
// FCM 토큰 조회 (캐시 기반)
sendToNative({ type: "PUSH_TOKEN", data: null });
```

**모든 PUSH_TOKEN 메시지의 응답/push 형태:**
```json
{
  "type": "PUSH_TOKEN",
  "data": {
    "token": "fcm_token_value_here",
    "platform": "ios",
    "isRefresh": false
  }
}
```

| 필드 | 타입 | 의미 |
|---|---|---|
| `token` | `string \| null` | FCM token. 발급 전·권한 거부 시 `null` |
| `platform` | `'ios' \| 'android'` | 송신 측 플랫폼 |
| `isRefresh` | `boolean` | `true` = onTokenRefresh 발화, `false` = 초기/조회 응답 |

전체 contract (송신 시점 5 시나리오 + null 응답 처리 + 웹 측 구현 가이드): [`docs/push-token-contract.md`](./docs/push-token-contract.md)

### 디바이스 정보

**요청:**
```typescript
// 디바이스 정보 조회 (기종, OS, 앱버전 등)
sendToNative({ type: "DEVICE_INFO", data: null });
```
**응답:**
```json
{
  "type": "DEVICE_INFO",
  "data": {
    "systemName": "iOS",
    "manufacturer": "iPhone", 
    "model": "iPhone 15 Pro",
    "deviceId": "F5046170-6EBE-420E-8ABD-1BFA3E9FB56C",
    "systemVersion": "18.6",
    "bundleId": "kr.shop.sazo.test",
    "buildNumber": "1",
    "version": "1.0.0",
    "readableVersion": "1.0.0.1",
    "deviceName": "iPhone",
    "deviceLocale": "ko_KR",
    "timezone": "Asia/Seoul"
  }
}
```

### 미디어 접근

**요청:**
```typescript
// 카메라로 사진 촬영
sendToNative({ type: "CAMERA_ACCESS", data: null });

// 갤러리에서 사진 선택
sendToNative({ type: "PHOTO_LIBRARY_ACCESS", data: null });
```

> ⚠️ **중요**: base64Data To Blob 변환해서 사용

**응답:**
```json
{
  "type": "CAMERA_ACCESS", // 또는 "PHOTO_LIBRARY_ACCESS"
  "data": [
    {
      "fileName": "image_picker_D1A5F6B4-B15F-4F2E-A57F-05E45F8476BC-551-000000058A4C1A20.jpg",
      "mimeType": "image/jpeg",
      "base64Data": "/4Qk0RXhpZgAATU0AKgAAAAgACgEPAAIAAAAGAAAAhg...",
      "size": 91680
    }
  ]
}
```

### 클립보드

**요청:**
```typescript
// 텍스트 복사 (응답 없음)
sendToNative({ 
    type: "SET_CLIPBOARD", 
    data: { text: "복사할 텍스트" } 
});

// 클립보드 내용 가져오기
sendToNative({ type: "GET_CLIPBOARD", data: null });
```
**응답:**
```json
{
  "type": "GET_CLIPBOARD", 
  "data": {
    "text": "클립보드에 있던 텍스트"
  }
}
```

### 브라우저 열기

**요청:**
```typescript
// 인앱 브라우저 (응답 없음)
sendToNative({ 
    type: "OPEN_IN_APP_BROWSER", 
    data: { url: "https://example.com" } 
});

// 외부 브라우저 (응답 없음)
sendToNative({ 
    type: "OPEN_EXTERNAL_BROWSER", 
    data: { url: "https://example.com" } 
});
```

### 시스템 제어

**요청:**
```typescript
// 앱 설정 열기 (응답 없음)
sendToNative({ type: "OPEN_APP_SETTINGS", data: null });

// 앱 종료 (응답 없음)
sendToNative({ type: "EXIT_APP", data: null });
```

### Analytics

**요청:**
```typescript
// Google Analytics 이벤트 전송 (응답 없음)
sendToNative({ type: "GOOGLE_ANALYTICS", data: {
    eventType: "SET_USER_ID",
    item: {
        userId: "unique_user_id_here",
    }
} });

sendToNative({ type: "GOOGLE_ANALYTICS", data: {
    eventType: "SEND_LOG_EVENT",
    item: {
        eventName: "event_name_here",
        parameters: {
            ...
        },
    }
} });

sendToNative({ type: "GOOGLE_ANALYTICS", data: {
    eventType: "SEND_LOG_PURCHASE_EVENT",
    item: {
        eventName: "purchase",
        parameters: {
            ecommerce: {
                ...
            }
        },
    },
} });

// AppsFlyer Analytics 이벤트 전송 (응답 없음)
sendToNative({ type: "APPS_FLYER_ANALYTICS", data: null });
```

### 채널톡

**요청:**
```typescript
// 채널톡 (Boot)
sendToNative({ 
    type: "CHANNEL_TALK_BOOT", 
    data: {
        pluginKey: "xxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx", 
        userId: "user1234",
        email: "user1234@gmail.com",
        name: "홍길동"
    } 
});

// 채널톡 (Show Messenger)
sendToNative({ type: "CHANNEL_TALK_SHOW_MESSENGER", data: null });

// 채널톡 (Shutdown)
sendToNative({ type: "CHANNEL_TALK_SHUTDOWN", data: null });
```

## ❌ 오류 응답
모든 API에서 오류 발생 시:
```json
{
  "type": "요청한_API_타입",
  "error": "This request is not supported"
}
```

---