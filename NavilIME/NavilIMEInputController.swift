//
//  NavilIMEInputController.swift
//  NavilIME
//
//  Created by Manwoo Yi on 9/4/22.
//

import InputMethodKit
import Carbon

@objc(NavilIMEInputController)
open class NavilIMEInputController: IMKInputController {
    let key_code:String =       "asdfhgzxcv\tbqweryt123465=97-80]ou[ip\tlj'k;\\,/nm.\t `"
    let shift_key_code:String = "ASDFHGZXCV\tBQWERYT!@#$^%+(&_*)}OU{IP\tLJ\"K:|<?NM>\t ~"

    // Info.plist의 ComponentInputModeDict에 선언한 입력 모드 ID.
    // 두 모드 모두 이 앱이 담당하므로, 영문으로 바꿔도 입력 소스는 여전히 NavilIME이고
    // handle()이 계속 호출된다. (영문에서도 특수키가 안 죽는 이유)
    static let hangul_mode = "com.navilera.inputmethod.NavilIME.Hangul"
    static let roman_mode  = "com.navilera.inputmethod.NavilIME.Roman"

    var hangul:Hangul?

    // 특수 키 조합 테이블: (keycode, modifier, 출력 문자)
    let special_keys: [(UInt16, NSEvent.ModifierFlags, String)] = [
        (0x35, .shift,   "~"),  // Shift+ESC → ~
        (0x35, .command, "`"),  // Cmd+ESC → `
        (0x2A, .command, "₩"), // Cmd+\ → ₩
    ]

    override open func activateServer(_ sender: Any!) {
        super.activateServer(sender)

        PrintLog.shared.Log(log: "Server Activated")
        self.hangul = Hangul()
        self.hangul?.Start()
    }

    override open func deactivateServer(_ sender: Any!) {
        PrintLog.shared.Log(log: "Server deactivating")

        // 세션을 정리(super)하기 전에 조합 중이던 글자를 이전 client로 먼저 확정한다.
        // super를 먼저 부르면 포커스가 새 앱으로 넘어간 뒤 commit돼, 그 글자가
        // 새 창(예: Raycast)으로 새어 "이전 입력기 것과 섞이는" 현상이 생길 수 있다.
        self.hangul?.Flush()
        self.update_display(client: sender)
        self.hangul?.Stop()

        super.deactivateServer(sender)
    }
    
    /*
     시스템이 입력 모드를 바꿀 때(Caps Lock 한/영 전환, 메뉴바에서 모드 선택 등) 호출된다.
     Info.plist의 TICapsLockLanguageSwitchCapable 덕분에 한/영 전환이 ABC 입력 소스로
     넘어가지 않고 여기로 들어온다. 즉 영문 상태에서도 입력 소스는 여전히 NavilIME이고
     handle()이 계속 호출되므로, special_keys(₩, ~, `)가 영문에서도 살아있다.
     */
    override open func setValue(_ value: Any!, forTag tag: Int, client sender: Any!) {
        if tag == Int(kTextServiceInputModePropertyTag), let mode = value as? String {
            PrintLog.shared.Log(log: "InputMode -> \(mode)")

            self.ensureHangulReady()
            // 모드가 바뀌기 전에 조합 중이던 글자를 확정한다.
            self.commitComposition(sender)

            // 시스템이 이미 모드를 바꾼 뒤 통지한 것이므로, selectMode로 되알릴 필요가 없다.
            self.set_eng_mode(mode.hasSuffix(".Roman"), client: sender, notify_system: false)
        }
        super.setValue(value, forTag: tag, client: sender)
    }

    // 영문/한글 모드를 바꾼다.
    // notify_system이 true면 시스템에도 알려 메뉴바 표시등(한 ↔ A)을 맞춘다.
    // 자체 단축키(오른쪽 Command 등)로 바꿀 때가 그 경우다.
    func set_eng_mode(_ eng:Bool, client:Any!, notify_system:Bool) {
        if HangulMenu.shared.self_eng_mode != eng {
            HangulMenu.shared.self_eng_mode = eng
            PrintLog.shared.Log(log: eng ? "영어" : "한글")
        }

        guard notify_system, let disp = client as? IMKTextInput else { return }
        disp.selectMode(eng ? NavilIMEInputController.roman_mode
                            : NavilIMEInputController.hangul_mode)
    }

    // hangul이 없거나 automata가 nil이면 복구한다.
    // macOS가 activateServer 없이 handle을 호출하는 경우 대비.
    func ensureHangulReady() {
        if self.hangul == nil {
            self.hangul = Hangul()
        }
        if self.hangul?.automata == nil {
            self.hangul?.Start()
        }
    }

    override open func handle(_ event: NSEvent!, client sender: Any!) -> Bool {
        self.ensureHangulReady()

        if OptHandler.shared.Is_han_eng_changed(keycode: event.keyCode, modi: event.modifierFlags) {
            // 조합 중이던 글자를 먼저 확정한 뒤 모드를 바꾼다.
            self.commitComposition(sender)
            self.set_eng_mode(!HangulMenu.shared.self_eng_mode, client: sender, notify_system: true)
            return true
        }

        switch event.type {
        case .keyDown:
            let eaten = self.keydown_event_handler(event: event, client: sender)
            if eaten == false {
                self.commitComposition(sender)
            }
            return eaten
        case .leftMouseDown, .leftMouseUp, .rightMouseDown, .rightMouseUp:
            self.commitComposition(sender)
        default:
            PrintLog.shared.Log(log: "unhandled event keycode=\(event.keyCode) modi=\(event.modifierFlags.rawValue)")
        }
        return false
    }
    
    func keydown_event_handler(event:NSEvent, client:Any!) -> Bool {
        guard let hangul = self.hangul else { return false }

        let keycode = event.keyCode
        let flag = event.modifierFlags

        // 특수 키 조합은 hotfix 버퍼에 넣지 않고 바로 처리
        for sk in self.special_keys {
            if keycode == sk.0 && flag.contains(sk.1) {
                hangul.Flush()
                self.update_display(client: client, additional: sk.2)
                return true
            }
        }

        // 영문 모드에서는 키를 먹지 않고 앱으로 그대로 넘긴다.
        //
        // 예전에는 자체 ASCII 테이블(key_code)로 글자를 만들어 insertText로 넣었는데,
        // 그러면 IMK 지원이 얕은 앱(터미널/TUI 등)에서 입력이 씹힌다. 앱에 넘기면
        // 시스템 키보드 레이아웃이 글자를 만들어 주므로 US 배열 외의 자판, 죽은 키,
        // 실행 취소 단위, 자동완성도 함께 정상 동작한다.
        //
        // 특수키(₩, ~, `)는 위에서 이미 처리했으므로 여기 도달하지 않는다.
        if HangulMenu.shared.self_eng_mode {
            hangul.Flush()
            self.update_display(client: client)
            return false
        }

        // 특정 패턴 입력은 한글로 변환하지 않는다.
        // 단축키(cmd/option/control)와 함께 들어온 keycode는 hotfix 패턴에 섞으면 false-positive가 생기므로 제외.
        if !flag.contains(.command) && !flag.contains(.option) && !flag.contains(.control) {
            Hotfix.shared.add(keycode)
            if Hotfix.shared.check() {
                return false
            }
        }

        if flag.contains(.command)
            || flag.contains(.option)
            || flag.contains(.control) {
            PrintLog.shared.Log(log: "Modikey - \(keycode) with \(flag.rawValue)")
            return false
        }

        let enter_return:UInt16 = 0x24
        let tab:UInt16 = 0x30
        if keycode == enter_return || keycode == tab {
            PrintLog.shared.Log(log: "Enter or Tab")

            hangul.Flush()
            self.update_display(client: client)

            return false
        }

        let backspace:UInt16 = 0x33
        if keycode == backspace {
            PrintLog.shared.Log(log: "Backspace")

            let remain = hangul.Backspace()
            if remain {
                self.update_display(client: client, backspace: true)
            }
            return remain
        }

        if keycode >= self.key_code.count {
            PrintLog.shared.Log(log: "Bypassd keycode: \(keycode) >= \(self.key_code.count)")

            hangul.Flush()
            self.update_display(client: client)

            return false
        }

        let ascii_idx = self.key_code.index(self.key_code.startIndex, offsetBy: Int(keycode))
        var ascii = self.key_code[ascii_idx]
        if flag.contains(.shift) {
            ascii = self.shift_key_code[ascii_idx]
        }

        let is_hangul:Bool = hangul.Process(ascii: String(ascii))
        if is_hangul == false {
            PrintLog.shared.Log(log: "Not Hangul: \(ascii)")

            hangul.Flush()
            self.update_display(client: client, backspace: false, additional: String(ascii))
        } else {
            self.update_display(client: client)
        }
        return true
    }
    
    func update_display(client:Any!, backspace:Bool = false, additional:String = "") {
        let commit_unicode:[unichar] = self.hangul?.takeCommit() ?? []
        let preedit_unicode:[unichar] = self.hangul?.takePreedit() ?? []
        
        // 출력할 내용이 전혀 없으면 IMKTextInput 호출을 건너뛴다.
        if commit_unicode.isEmpty && preedit_unicode.isEmpty && additional.isEmpty && backspace == false {
            return
        }
        
        var commited:String = ""
        if commit_unicode.isEmpty == false {
            commited = String(utf16CodeUnits:commit_unicode , count: commit_unicode.count)
        }
        
        var preediting:String = ""
        if preedit_unicode.isEmpty == false {
            preediting = String(utf16CodeUnits: preedit_unicode, count: preedit_unicode.count)
        }
        
        PrintLog.shared.Log(log: "C:'\(commited)' - \(commited.count) P:'\(preediting)' - \(preediting.count)")
        
        guard let disp = client as? IMKTextInput else {
            return
        }
        
        commited += additional
        
        let build_count = 302
        if commited.isEmpty == false {
            disp.insertText(commited, replacementRange: NSRange(location: NSNotFound, length: NSNotFound))
            
            PrintLog.shared.Log(log: "\(build_count) Commit: \(commited)")
        }
        
        // replacementRange 가 아래 코드와 같아야만 잘 동작한다.
        if (preediting.isEmpty == false) || (backspace == true) {
            // 백스페이스로 글자를 지울 때, preddition.count == 0 인 상태가 되는데
            // 이 때 명시적으로 length = 0 인 NSRange를 setMarkedText()에 주어야만 자연스럽게 처리된다.
            // NSRange.length는 UTF-16 단위. NFD로 분해된 한글은 grapheme count와 다르므로 NSString.length를 쓴다.
            let sr = NSRange(location: 0, length: (preediting as NSString).length)
            let rr = NSRange(location: NSNotFound, length: NSNotFound)
            PrintLog.shared.Log(log: "RR: \(rr) SR: \(sr) on \(String(describing: disp.bundleIdentifier()))")
            disp.setMarkedText(preediting, selectionRange: sr, replacementRange: rr)
            
            PrintLog.shared.Log(log: "\(build_count) Predit: \(preediting)")
        }
    }
    
    /*
     입력 메서드가 이 메서드를 구현하면, 클라이언트가 컴포지션 세션을 즉시 종료하고자 할 때 호출됩니다.
     일반적인 응답은 클라이언트의 insertText 메서드를 호출한 다음 세션별 버퍼와 변수를 정리하는 것입니다.
     이 메시지를 받은 후 입력 방법은 주어진 컴포지션 세션이 완료된 것을 고려해야 합니다.
     */
    override open func commitComposition(_ sender: Any!) {
        PrintLog.shared.Log(log: "Commit Composition")
        self.hangul?.Flush()
        self.update_display(client: sender)
    }
    
    /*
     클라이언트는 입력 메서드가 이벤트를 지원하는지 확인하기 위해 이 메서드를 호출합니다.
     기본 구현은 NSKeyDownMask를 반환합니다.
     입력 방법이 키 다운 이벤트만 처리하는 경우, 입력 방법 키트는 기본 마우스 처리를 제공합니다.
     기본 마우스다운 처리 동작은 다음과 같습니다:
       활성 컴포지션 영역이 있고 사용자가 텍스트를 클릭하지만 컴포지션 영역 외부에서 클릭하는 경우,
       입력 방법 키트는 입력 메서드에 commitComposition: 메시지를 보냅니다.
       이것은 기본값인 NSKeyDownMask만 반환하는 입력 메서드에서만 발생합니다.
     */
    override open func recognizedEvents(_ sender: Any!) -> Int {
        // drag는 frame마다 들어와 매번 commit이 호출되므로 제외.
        return Int(NSEvent.EventTypeMask(arrayLiteral: .keyDown, .flagsChanged,
            .leftMouseUp, .rightMouseUp, .leftMouseDown, .rightMouseDown,
            .appKitDefined, .applicationDefined, .systemDefined).rawValue)
    }
    
    /*
     마우스 버튼이 눌리면 현재 조합을 종료하고 커밋
     */
    override open func mouseDown(onCharacterIndex index: Int, coordinate point: NSPoint, withModifier flags: Int, continueTracking keepTracking: UnsafeMutablePointer<ObjCBool>!, client sender: Any!) -> Bool {
        PrintLog.shared.Log(log: "Mouse Down")
        
        self.commitComposition(sender)
        return false
    }
    
    
    /*
     이 메서드는 입력 메서드가 현재 상태를 반영하도록 메뉴를 업데이트할 수 있도록 메뉴를 그려야 할 때마다 호출됩니다.
     */
   override open func menu() -> NSMenu! {
        // 권한이 방금 허용됐다면 탭을 켜고, 메뉴 표시 상태도 갱신한다.
        SpecialKeyTap.shared.startIfTrusted()
        HangulMenu.shared.refresh_permission_state()
        return HangulMenu.shared.menu
   }
    
    /*
     IMKit 프레임워크는 실제 NSMenu 객체가 어디에 있건간에 NSMenuItem.action은 무조건 InputController 내부에 있어야 한다.
     그리고 sender는 NSMenuItem이 아니다. <-- 졸라 중요.
     IMKit에서 생성한 Dictionary 타입 객체가 sender로 전달된다.
     거기서 NSMenuItem을 찾으려면 ["IMKCommandMenuItem"]으로 Dictionary에서 값을 가져와야 한다.
     인터넷 그 어디에도 공식적인 문서 자료가 없다. 내가 삽질해서 찾은 것임.
     */
    @objc func select_haneng_hotkey(_ sender:Any?) {
        self.hangul?.Flush()
        guard let dict = sender as? [String: Any],
              let item = dict["IMKCommandMenuItem"] as? NSMenuItem else {
            return
        }
        HangulMenu.shared.set_hotkey(tag: item.tag)
    }

    // 특수키(₩, ~, `)를 다른 입력기 상태에서도 쓰려면 손쉬운 사용 권한이 필요하다.
    // 권한 안내 팝업을 띄우고, 시스템 설정의 손쉬운 사용 창을 연다.
    @objc func grant_special_key_permission(_ sender:Any?) {
        if SpecialKeyTap.shared.isTrusted {
            SpecialKeyTap.shared.startIfTrusted()
            return
        }

        // OS가 직접 띄우는 시스템 권한 창(가장 확실한 경로)을 먼저 트리거하고,
        // 손쉬운 사용 설정 창도 연다. 이 둘은 백그라운드 앱(LSBackgroundOnly)에서도 동작한다.
        SpecialKeyTap.shared.requestPermissionPrompt()
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }

        // 설명용 NSAlert. LSBackgroundOnly에서는 창이 앞으로 안 올 수 있어,
        // 잠깐 활성화 정책을 accessory로 올려 확실히 표시되게 한다.
        let prevPolicy = NSApp.activationPolicy()
        NSApp.setActivationPolicy(.accessory)
        NSApp.activate(ignoringOtherApps: true)

        let alert = NSAlert()
        alert.messageText = "특수키 전역 입력 권한이 필요합니다"
        alert.informativeText = "₩, ~, ` 같은 특수키 조합을 영문 등 다른 입력기 상태에서도 쓰려면 "
            + "‘손쉬운 사용’ 권한이 필요합니다.\n\n"
            + "열린 시스템 설정의 ‘손쉬운 사용’ 목록에서 NavilIME를 켠 뒤, 입력기를 한 번 "
            + "전환하거나 다시 로그인하면 적용됩니다."
        alert.addButton(withTitle: "확인")
        alert.runModal()

        NSApp.setActivationPolicy(prevPolicy)
    }
}
