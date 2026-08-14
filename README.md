# Adaptive Space MVP

Android XR을 제외한 최소 수직 슬라이스입니다.

```text
더미 웨어러블 연결·동기화
→ GPT-5.6 Luna 추천 설명 + 결정론적 환경 프로필
→ 집 시뮬레이터 적용·보정·복원
→ 호텔 데모 QR 체크인
→ 생체정보 없는 공간 변환·적용
→ 체크아웃·기본값 복원·세션 만료
```

## 구성

- `iOS/AdaptiveSpace`: iOS 17+ SwiftUI 앱
- `server`: Python OpenAI Agents SDK 서버
- `project.yml`: XcodeGen 원본 (`.xcodeproj`는 생성물)
- `mise.toml`: 런타임 버전과 공통 실행 명령
- `Brewfile`: 시스템 패키지 선언

에이전트는 동의된 더미 요약값을 바탕으로 추천 이유만 작성합니다. 컨디션 분류, 조명·온도·사운드 실행값, 공간 범위 제한, 승인, 복원과 만료는 서버의 결정론적 정책이 담당합니다.

UI는 iOS 26 이상에서 SwiftUI 네이티브 Liquid Glass(`glassEffect`, `GlassEffectContainer`, glass 버튼 스타일)를 사용합니다. iOS 17~25에서는 동일한 정보 구조와 동작을 유지하는 system material 폴백을 사용합니다.

UI 작업에 사용한 `swiftui-liquid-glass`, `mobile-app-ui-design` 스킬은 `.agents/skills`에 프로젝트 전용으로 설치되어 있으며 `skills-lock.json`으로 버전을 추적합니다.

## 실행

최초 한 번:

```bash
mise run setup
```

터미널 1에서 서버 실행:

```bash
mise run server
```

터미널 2에서 Xcode 프로젝트를 생성하고 엽니다:

```bash
mise run ios:generate
open AdaptiveSpace.xcodeproj
```

Xcode에서 `AdaptiveSpace` 스킴과 iPhone Simulator를 선택해 실행합니다. 서버 주소 기본값은 `http://127.0.0.1:8000`입니다.

## 검증

```bash
mise run check
mise run server:test
mise run ios:build
mise run ios:test
```

서버를 실행한 상태에서 전체 시뮬레이터 흐름을 검증합니다:

```bash
mise run ios:test-ui
```

## 이번 범위에서 제외

HealthKit·Apple Watch·BLE, 실제 건강정보, 실제 IoT, 카메라 QR, 로그인·DB·다중 사용자, 호텔 PMS·결제, Android XR은 구현하지 않았습니다. 더미 웨어러블과 방 시뮬레이터의 계약을 유지한 채 후속 어댑터로 교체할 수 있습니다.
