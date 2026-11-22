// S2Arm（不是上游文件）：键位弹窗的录键规则（#1606 ④ 键盘录入改进，Ting2024 原作，main 上重做）。纯状态机，单测 InputKeyCaptureTests。
//   Esc 取消；带 ⌘ 的交给系统；自动重复不录；左右修饰键并成一个（右 Shift 60 / Control 62 / Option 61 → 56 / 59 / 58）。
//   修饰键按下先记成待定：按着它再按别的键 = 录组合（键 + 修饰位）；没按别的键就松开 = 录这个修饰键本身。
//   原先修饰键一按下就录成单键，「按着 Shift 再按 A」录不成 Shift+A；失焦 / 停止录入时 reset 丢掉待定
struct InputKeyCapture {
    enum Result: Equatable { case bind(KeyBinding), cancel }
    private var pending: Int?
    mutating func reset() { pending = nil }
    mutating func event(code raw: Int, modifiers: Int, flagsChanged: Bool, repeatKey: Bool = false, command: Bool = false) -> Result? {
        if command { pending = nil; return nil }
        if repeatKey { return nil }
        let code = [60: 56, 62: 59, 61: 58][raw] ?? raw
        if flagsChanged {
            let bit = code == 56 ? 1 : code == 59 ? 2 : code == 58 ? 4 : 0
            if bit == 0 { return nil }
            if modifiers & bit != 0 { pending = code; return nil }   // 按下：先等，可能是组合
            guard pending == code else { return nil }                // 松开的不是待定那个（或组合已录）：不录
            pending = nil
            return .bind(KeyBinding(code: code, modifiers: 0))
        }
        pending = nil
        return code == 53 ? .cancel : .bind(KeyBinding(code: code, modifiers: modifiers))
    }
}
