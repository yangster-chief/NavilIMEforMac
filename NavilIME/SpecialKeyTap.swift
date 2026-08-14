//
//  SpecialKeyTap.swift
//  NavilIME
//
//  전역 키 가로채기(CGEventTap)로 특수키 조합을 어느 앱에서든 치환한다.
//
//  IMK 경로(NavilIMEInputController.special_keys)는 앱이 키 이벤트를 입력 컨텍스트로
//  넘겨줄 때만 동작한다. Notes 같은 AppKit 앱은 넘겨주지만, 터미널은 Command 조합을
//  메뉴 단축키로 소비해 넘기지 않고, TUI(예: Claude CLI)는 ESC를 취소 키로 직접
//  읽어버린다. 그래서 그런 앱에서는 IMK 경로만으로는 특수키가 통하지 않는다.
//  이 탭은 앱보다 앞단이라 그 경우를 메운다.
//
//  동작하려면 App Sandbox가 꺼져 있어야 하고 손쉬운 사용(Accessibility) 권한이
//  허용돼야 한다. 권한이 없으면 탭이 안 뜨고 IMK 경로만 남는다(정상 동작하는 앱에서는
//  그대로 쓸 수 있다).
//
//  [중요] 탭은 전용 스레드의 런루프에서 돈다. IMK 입력 경로(NavilIMEInputController.handle)는
//  메인 스레드에서 도는데, 시스템 전역 keyDown 탭을 메인 런루프에 걸면 모든 키 입력이
//  메인 스레드를 동기 통과하게 되어, 메인 스레드가 바쁜 순간 입력/전환 지연이 생긴다.
//  그래서 탭은 메인이 아닌 별도 스레드로 분리한다. (TIS 조회 비용도 탭 스레드에서만 소비된다.)
//

import Cocoa
import ApplicationServices
import Carbon

// IMK 경로(NavilIMEInputController.special_keys)와 동일한 조합을 유지한다.
//
// outKeyCode: 치환해서 내보낼 실제 키의 keycode. 유니코드 문자열만 바꾸고 keycode를
//   ESC(0x35)로 두면 터미널이나 TUI처럼 keycode/raw 바이트로 판단하는 앱에서는
//   여전히 ESC로 읽힌다(= Claude CLI에서 "바로 ESC 되어버리는" 증상). 그래서 실제로
//   그 글자를 내는 키로 바꿔친다. `와 ~ 는 keycode 0x32(Shift 유무)로 만들 수 있다.
//   nil이면 원래 keycode를 두고 유니코드 문자열로만 치환한다(₩ 처럼 US 배열에
//   대응 키가 없는 경우).
struct SpecialKeyCombo {
    let keyCode: CGKeyCode
    let flag: CGEventFlags
    let output: String
    let outKeyCode: CGKeyCode?
    let outFlags: CGEventFlags
}

class SpecialKeyTap {
    static let shared = SpecialKeyTap()

    // NavilIMEInputController.special_keys와 짝을 이룬다. 한쪽을 바꾸면 다른 쪽도 맞춘다.
    let combos: [SpecialKeyCombo] = [
        // Shift+ESC → ~   (0x32 + Shift = 진짜 ~ 키 입력)
        SpecialKeyCombo(keyCode: 0x35, flag: .maskShift,   output: "~",
                        outKeyCode: 0x32, outFlags: .maskShift),
        // Cmd+ESC → `     (0x32 = 진짜 ` 키 입력)
        SpecialKeyCombo(keyCode: 0x35, flag: .maskCommand, output: "`",
                        outKeyCode: 0x32, outFlags: []),
        // Cmd+\ → ₩       (US 배열에 ₩ 키가 없어 유니코드로만 치환)
        SpecialKeyCombo(keyCode: 0x2A, flag: .maskCommand, output: "₩",
                        outKeyCode: nil,  outFlags: []),
    ]

    private var eventTap: CFMachPort?
    private var runLoopSource: CFRunLoopSource?

    // 탭은 메인이 아닌 전용 스레드의 런루프에서 돈다.
    private var tapThread: Thread?
    private var tapRunLoop: CFRunLoop?

    private init() {}

    var isTrusted: Bool {
        return AXIsProcessTrusted()
    }

    var isRunning: Bool {
        return tapThread != nil
    }

    // 손쉬운 사용 권한이 있으면 탭을 켠다. 권한이 없으면 시스템 권한 요청 다이얼로그를 띄운다.
    func requestPermissionPrompt() {
        let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
        let options = [key: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
    }

    // 권한이 있으면(그리고 아직 안 켜졌으면) 탭을 시작한다.
    func startIfTrusted() {
        guard isTrusted, tapThread == nil else { return }
        start()
    }

    func start() {
        guard tapThread == nil else { return }
        guard isTrusted else {
            PrintLog.shared.Log(log: "SpecialKeyTap: not trusted, tap not created")
            return
        }

        // 전용 스레드의 런루프에서 탭을 돌려 메인 스레드(IMK 입력 경로)와 분리한다.
        let thread = Thread { [weak self] in
            guard let self = self else { return }
            guard self.createTap() else { return }
            self.tapRunLoop = CFRunLoopGetCurrent()
            PrintLog.shared.Log(log: "SpecialKeyTap: started (dedicated thread)")
            CFRunLoopRun()
            self.teardownTap()
            PrintLog.shared.Log(log: "SpecialKeyTap: stopped")
        }
        thread.name = "io.navilera.NavilIME.SpecialKeyTap"
        thread.qualityOfService = .userInteractive
        tapThread = thread
        thread.start()
    }

    func stop() {
        if let tap = eventTap {
            CGEvent.tapEnable(tap: tap, enable: false)
        }
        if let rl = tapRunLoop {
            CFRunLoopStop(rl)
        }
        tapThread = nil
        tapRunLoop = nil
    }

    // 탭 스레드에서 실행. 런루프 소스를 현재(전용) 런루프에 단다.
    private func createTap() -> Bool {
        let mask = (1 << CGEventType.keyDown.rawValue)
        let refcon = Unmanaged.passUnretained(self).toOpaque()

        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: CGEventMask(mask),
            callback: { _, type, event, refcon in
                guard let refcon = refcon else { return Unmanaged.passUnretained(event) }
                let me = Unmanaged<SpecialKeyTap>.fromOpaque(refcon).takeUnretainedValue()
                return me.handle(type: type, event: event)
            },
            userInfo: refcon
        ) else {
            PrintLog.shared.Log(log: "SpecialKeyTap: tapCreate failed")
            return false
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetCurrent(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        eventTap = tap
        runLoopSource = source
        return true
    }

    // 탭 스레드에서 실행. 런루프가 멈춘 뒤 정리한다.
    private func teardownTap() {
        if let source = runLoopSource {
            CFRunLoopRemoveSource(CFRunLoopGetCurrent(), source, .commonModes)
        }
        eventTap = nil
        runLoopSource = nil
    }

    private func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        // macOS가 과도한 부하/사용자 입력으로 탭을 끄면 다시 켠다.
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap = eventTap {
                CGEvent.tapEnable(tap: tap, enable: true)
            }
            return Unmanaged.passUnretained(event)
        }

        guard type == .keyDown else { return Unmanaged.passUnretained(event) }

        let keyCode = CGKeyCode(event.getIntegerValueField(.keyboardEventKeycode))
        let flags = event.flags

        // 특수키 조합 후보가 아니면(거의 모든 키) 아무 일도 하지 않고 즉시 통과한다.
        guard let combo = combos.first(where: { keyCode == $0.keyCode && flags.contains($0.flag) }) else {
            return Unmanaged.passUnretained(event)
        }

        // 입력 소스가 NavilIME인지 따지지 않고 항상 치환한다.
        //
        // 예전에는 "NavilIME가 활성이면 IMK 경로가 처리하니 비켜라"고 게이트를 뒀는데,
        // 영문 모드까지 NavilIME가 담당하게 되면서 그 조건이 항상 참이 되어 탭이 아예
        // 동작하지 않았다. 게다가 IMK 경로는 앱이 이벤트를 입력 컨텍스트로 넘겨줄 때만
        // 동작해서, 터미널(Command 조합을 안 넘김)이나 TUI(ESC를 직접 소비)에서는
        // 특수키가 통하지 않는다. 탭은 앱보다 앞단이라 그런 앱에서도 통한다.
        //
        // 이중 처리 걱정은 없다. 여기서 keycode와 수식키를 바꿔치기하므로, 뒤이어
        // 도달하는 IMK 경로에서는 special_keys 조건에 더 이상 걸리지 않는다.
        event.flags = combo.outFlags
        if let outKey = combo.outKeyCode {
            event.setIntegerValueField(.keyboardEventKeycode, value: Int64(outKey))
        }
        let utf16 = Array(combo.output.utf16)
        event.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
        return Unmanaged.passUnretained(event)
    }
}
