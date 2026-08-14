# NavilIME 개인 수정 기록

이 프로젝트는 **Manwoo Yi**([@navilera](https://github.com/navilera))님이 만든 macOS용 한글 입력기입니다.
세벌식 318Na 자판을 직접 디자인하고, 리눅스/윈도우/맥 전부 입력기를 직접 구현하신 분입니다.
아래는 개인 용도로 포크하여 수정한 내용입니다.

원본: [navilera/NavilIMEforMac](https://github.com/navilera/NavilIMEforMac)

## 2026-08-14 - 한/영 전환을 입력기 내부 모드로 (특수키가 영문에서도 살아있게)

### 문제
NavilIME는 `tsInputMethodCharacterRepertoireKey`가 `Hang` 하나뿐인 **한글 전용 입력
소스**였다. 그래서 시스템 한/영 전환(Caps Lock)을 쓰면 입력 소스 자체가 ABC로 바뀌고,
`deactivateServer` 이후 키 이벤트가 NavilIME에 오지 않았다. 결과적으로 영문 상태에서는
특수키(`Cmd+\→₩`, `Shift+ESC→~`, `Cmd+ESC→\``)가 전부 동작하지 않았다.

### 해결 — 영문 모드를 입력기가 직접 제공
- `Info.plist`에 `ComponentInputModeDict`로 **입력 모드 두 개**를 선언한다.
  - `com.navilera.inputmethod.NavilIME.Hangul` (한, `smKorean`)
  - `com.navilera.inputmethod.NavilIME.Roman` (A, `smRoman`)

  둘 다 `tsInputModeIsVisibleKey`가 true라 입력 소스 목록에 각각 뜨고, 입력 소스
  전환 단축키(Cmd+Space 등)가 이 둘을 오간다. **두 모드 모두 같은 앱이 담당하므로
  영문 상태에서도 입력 소스가 여전히 NavilIME이고 `handle()`이 계속 호출된다.**
  ABC로 넘어가면 죽던 것과 대비된다.
- `tsInputMethodCharacterRepertoireKey`에 `Latn` 추가. 영문 모드를 직접 제공하므로
  필요하다.

앱을 두 벌 만들어 등록하는 방법도 같은 결과를 내지만, 번들 2개 서명·설치와
IMKServer 프로세스 2개, 설정/특수키 테이블의 프로세스 간 동기화 비용이 붙는다.
한 앱에 모드 두 개면 동일한 UX를 한 프로세스로 얻는다.
- `NavilIMEInputController.setValue(_:forTag:client:)` 오버라이드. 시스템이
  `kTextServiceInputModePropertyTag`로 모드 변경을 통지하면 조합 중이던 글자를 확정하고
  `HangulMenu.self_eng_mode`를 맞춘다.
- `set_eng_mode(_:client:notify_system:)` 추가. 자체 단축키(오른쪽 Command 등)로
  전환할 때는 `IMKTextInput.selectMode(_:)`로 시스템에도 알려 **메뉴바 표시등이
  한 ↔ A 로 바뀌게** 한다. 기존에는 내부 영문 모드여도 표시등이 계속 한글이었다.
- `Hangul.ToggleSuspend()` 제거. 모드를 뒤집는 경로가 둘이 되면 시스템 입력 모드와
  어긋나므로 `set_eng_mode` 하나로 일원화했다.
- `ko.lproj/InfoPlist.strings`, `en.lproj/InfoPlist.strings` 추가. 입력 소스 목록에
  표시할 모드 이름을 준다. 이게 없으면 시스템 설정 > 키보드 > 입력 소스 목록에
  `com.navilera.inputmethod.NavilIME.Hangul` 이라는 ID 문자열이 그대로 노출된다.
  키는 모드 ID와 정확히 일치해야 한다.
  (한국어 "나빌입력기" / "나빌입력기 (영문)", 영어 "NavilIME" / "NavilIME (Roman)")

### 영문 모드에서는 키를 앱에 그대로 넘김
영문 모드에서 자체 ASCII 테이블(`key_code`)로 글자를 만들어 `insertText`로 넣던 것을
`return false`로 바꿔 앱이 직접 처리하게 했다. `insertText` 방식은 IMK 지원이 얕은
앱(터미널/TUI)에서 입력이 통째로 씹혔다. 앱에 넘기면 시스템 키보드 레이아웃이 글자를
만들어 주므로 US 배열 외의 자판, 죽은 키, 실행 취소 단위, 자동완성도 함께 정상화된다.
특수키는 이 분기보다 앞에서 처리하므로 영향이 없다.

### SpecialKeyTap 되살리기 — 터미널/TUI 대응
IMK 경로는 **앱이 키 이벤트를 입력 컨텍스트로 넘겨줄 때만** 동작한다. 실측 결과:

| 앱 | Shift+ESC → ~ | Cmd+ESC → ` | Cmd+\ → ₩ |
|---|---|---|---|
| Notes | O | O | O |
| Terminal | O | X | X |
| Claude CLI | X (바로 ESC) | X | X |

Terminal은 Command 조합을 메뉴 단축키로 소비해 `keyDown:`까지 넘기지 않고, TUI는
ESC를 취소 키로 직접 읽는다. 앱보다 앞단인 `CGEventTap`으로만 메울 수 있다.

- **게이트 제거.** `currentInputSourceIsNavil()`은 "NavilIME가 활성이면 IMK가
  처리하니 비켜라"는 조건이었는데, 영문 모드까지 NavilIME가 담당하게 되면서 항상
  참이 되어 탭이 한 번도 동작하지 않았다. 조건을 없애고 항상 치환한다.
- **keycode 바꿔치기.** 유니코드 문자열만 갈아끼우고 keycode를 ESC(0x35)로 두면
  keycode/raw 바이트로 판단하는 앱에서는 여전히 ESC로 읽힌다. 실제로 그 글자를 내는
  키로 바꾼다 — `Shift+ESC → 0x32+Shift`, `Cmd+ESC → 0x32`. ₩는 US 배열에 대응
  키가 없어 유니코드 치환을 유지한다.
- 이중 처리는 없다. 탭이 keycode와 수식키를 바꾸므로 뒤이어 도달하는 IMK 경로의
  `special_keys` 조건에 걸리지 않는다.

손쉬운 사용 권한이 없으면 탭이 뜨지 않고 IMK 경로만 남는다(Notes류에서는 그대로 동작).

### Caps Lock 전환은 넣지 않음
`TICapsLockLanguageSwitchCapable`을 쓰면 Caps Lock이 입력기 내부 한/영을 토글하지만,
입력 소스 전환 단축키로 모드를 오가는 이 구성과 메커니즘이 겹쳐 혼란스러워진다.
Caps Lock은 일반 대문자 고정으로 남겨둔다.

영문 상태에서도 입력 소스는 여전히 NavilIME이므로 `handle()`이 계속 호출되고,
`special_keys` 처리가 그대로 살아있다. 손쉬운 사용 권한도 `CGEventTap`도 필요 없다.

### 적용 시 주의
입력 모드 선언이 생기면서 선택되는 입력 소스 ID가
`com.navilera.inputmethod.NavilIME` → `com.navilera.inputmethod.NavilIME.Hangul`로
바뀐다. 설치 후 **시스템 설정 > 키보드 > 입력 소스에서 NavilIME를 지웠다가 다시 추가**하고
로그아웃/로그인해야 새 모드 구성이 반영된다.

## 2026-05-27 - 전역 특수키 입력 및 개인 빌드 서명

### 특수키 조합을 다른 입력기 상태에서도 동작 (전역)
- `SpecialKeyTap`: 세션 레벨 `CGEventTap`으로 특수키 조합(`Shift+ESC→~`,
  `Cmd+ESC→\``, `Cmd+\→₩`)을 전역에서 가로채 치환.
- 현재 입력기가 NavilIME가 아닐 때만 가로채고, NavilIME 활성 시엔 기존 IMK
  경로가 처리하도록 분기 → 이중 처리 방지.
- 탭이 타임아웃/사용자 입력으로 비활성화되면 자동 재활성화.
- App Sandbox에서는 전역 이벤트 탭이 막히므로 entitlements에서 `app-sandbox`를
  끔. (App Store가 아닌 직접 설치 방식이라 무방)

### 손쉬운 사용 권한 UI
- `CGEventTap`은 손쉬운 사용(Accessibility) 권한이 필요.
- 트레이 메뉴에 "특수키 전역 입력 권한 허용…" 항목 추가. 권한이 있으면
  "특수키 전역 입력: 켜짐 ✓"로 표시(비활성).
- 클릭 시 시스템 권한 요청 + 손쉬운 사용 설정 창 열기 + 안내 alert.
  LSBackgroundOnly 환경에서도 표시되도록 활성화 정책을 잠시 올림.
- 부팅 시 권한이 이미 있으면 탭 자동 시작.

### 개인 빌드 서명 구조
- `Signing.xcconfig`(기본 ad-hoc) + `Local.xcconfig.example`(템플릿) 도입.
  실제 `Local.xcconfig`는 `.gitignore`로 커밋 제외 → 개인 Team ID 비공개.
- pbxproj에서 하드코딩된 `DEVELOPMENT_TEAM`/`CODE_SIGN_IDENTITY` 제거,
  `baseConfigurationReference`로 xcconfig 연결.
- `.gitignore` 신설, 추적되던 `.DS_Store` 추적 해제.

## 2026-05-23 - 옵션 창 제거 및 안정성 라운드

### 옵션 창 제거, 한영전환 단축키를 트레이 메뉴로 통합
- 옵션 창과 관련 xib UI 전체 제거
- 한/영 전환 단축키 설정(시스템입력기 사용 / 왼쪽 Shift+Space / 오른쪽 Command / 오른쪽 Option)을 트레이 메뉴 라디오 항목으로 이동

### 두벌식 ㄷㄷㄷ 옵션 제거
- 같은 자음 연속 입력을 쌍자음으로 합치는 옵션 제거
- `shift_cho`(분리 입력) 동작을 영구 기본으로 고정, 관련 테이블/영속화 코드 단순화

### 안정성 개선
- 죽은 NSScrollView 출력을 `os_log` 래퍼로 교체 (Console.app에서 `subsystem=io.navilera.NavilIME`로 필터링)
- `setMarkedText` selectionRange를 grapheme count 대신 NSString.length(UTF-16)로 계산 (NFD 분해된 한글 잘림 방지)
- cmd/option/control이 눌린 keycode는 hotfix 순환버퍼에 넣지 않음 (false-positive 방지)
- 드래그 매 프레임 commit 호출 제거
- IBOutlet들을 옵셔널로 변경, xib에 위젯이 없어도 크래시 없이 진행

## 2026-04-14 - 대규모 정리 및 개선

### 세벌식 제거
- 세벌식 318, 390 키보드 코드 전부 삭제 (`Keyboard318.swift`, `Keyboard390.swift`)
- 두벌식(Keyboard002)만 남김
- Hangul, Keyboards, SingletonMenu, SingletonOpt, Testcases 등에서 관련 참조 모두 제거
- 트레이 메뉴에서 키보드 선택 항목 제거 (옵션 메뉴만 남김)

### 옵션 창 개선
- 디버깅용 scrollView 제거
- 윈도우 크기 축소 (517px -> 210px)
- 타이틀 "NavilIME 옵션"으로 변경
- AppDelegate에서 디버그 로그 설정 코드 제거

### 특수키 조합 추가
- `Shift + ESC` -> `~` (물결)
- `Cmd + ESC` -> `` ` `` (백틱)
- `Cmd + \` -> `₩` (원화 기호)
- 테이블 기반으로 구현되어 있어 `special_keys` 배열에 추가만 하면 확장 가능

### 크래시 방어
- `Hangul!` (force unwrap) -> `Hangul?` (optional)로 변경
- `Automata` 접근 시 `guard let` 패턴 적용
- macOS가 비정상 순서로 생명주기 호출할 때 (화면 잠금, 슬립 복귀, 빠른 앱 전환) 크래시 방지

### Hotfix 버퍼 오염 방지
- 특수키 조합을 Hotfix 패턴 체크 이전에 처리
- ESC 등의 keycode가 hotfix circular buffer에 들어가지 않음
