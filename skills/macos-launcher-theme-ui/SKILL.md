---
name: macos-launcher-theme-ui
description: >-
  Guide for building and updating macOS Launcher SwiftUI interfaces (NXLauncher / NX2AppleUI)
  using the centralized Theme Style System (LauncherTheme.ButtonShape, ButtonSize, buttonSpec,
  LauncherFlowRow, LauncherBadge) and Gamepad Focus Ring / B-key rules.
  Use whenever adding, modifying, or reviewing macOS launcher views, buttons, sheets, toolbars,
  badges, toggles, checkboxes, radios, or gamepad navigation in launchers/macos/frontend.
---

# macOS Launcher Theme UI & Gamepad Focus Skill

Use this skill whenever editing SwiftUI views in `launchers/macos/frontend/Sources/NXLauncher` or `launchers/macos/frontend/Sources/NX2Apple`. All button geometry, icon spacing, typography, badges, and gamepad focus ring parameters are centralized in `LauncherTheme` (`LauncherTheme.swift` / `LauncherStyles.swift`) — never hardcode ad-hoc button frames or shapes inside feature views.

## 1. Pick the Right Theme Component & Token

| UI Surface | Shape (`ButtonShape`) | Size (`ButtonSize`) | Style / Component |
| --- | --- | --- | --- |
| Main window toolbar status / task pills | `.capsule` | `.compact` (`30 pt`) | `LauncherSecondaryButtonStyle(size: .compact, shape: .capsule)` |
| Home Hero primary / secondary actions | `.capsule` | `.hero` (`52 pt`) | `ConsolePlayButtonStyle()` / `ConsolePillButtonStyle()` |
| Sheets, settings, forms, cards, console panels | `.rounded` (`r = 10`) | `.regular` (`36 pt`) | `LauncherPrimaryButtonStyle()` / `LauncherSecondaryButtonStyle()` |
| Job / failure / risk-confirmation pages | `.rounded` (`r = 10`) | `.prominent` (`48 pt`) | `LauncherPrimaryButtonStyle(size: .prominent)` / `LauncherSecondaryButtonStyle(size: .prominent)` |
| Update popup (`UpdatePopupView`) | `.capsule` | `.regular` (`36 pt`) | `LauncherPrimaryButtonStyle(shape: .capsule)` / `LauncherSecondaryButtonStyle(shape: .capsule)` |
| Square icon button (forms / popovers / list rows) | `.rounded` | `36×36, r=10` or `28×28, r=8` | `LauncherIconButtonStyle(size:cornerRadius:)` |
| Circular icon button (toolbar / Hero / sheet `×`) | Circle | `32` / `40` / `52` | `ConsoleIconButtonStyle(size:backgroundless:accent:)` |
| Status / version / `BETA` pill tags | `.circular` capsule | `18–24 pt` | `LauncherBadge(_:...)` |
| Switch / Checkbox / Standalone Radio | — | — | `LauncherSwitchStyle()` / `PadToggleStyle(.checkbox)` / `LauncherRadioRow` |

> All button heights, horizontal paddings, fonts, icon sizes, icon spacings, and min widths come from `LauncherTheme.buttonSpec(_:primary:)`. To restyle the entire app, edit `LauncherTheme.swift` instead of individual views.

## 2. Standard Layout Patterns

### Side-by-Side Buttons (Footers & Confirm Pairs)
Place side-by-side actions in a standard `HStack` using uniform horizontal padding (`LauncherTheme.buttonSpec`) and natural label width — do not force equal widths, so long localized labels (French / Spanish / Japanese) never overflow or clip:

```swift
HStack(spacing: LauncherTheme.Space.medium) {
    Button(loc.t("s2arm.env.recheck")) { model.checkEnvironment() }
        .controllerButtonStyle(LauncherSecondaryButtonStyle())
    Button(loc.t("launch.done")) { dismiss() }
        .controllerButtonStyle(LauncherPrimaryButtonStyle())
}
```

### Wrapping Multi-Button Action Rows (Long Labels)
When a row can contain 2–4 buttons with long localized text (e.g. failure recovery actions), use `LauncherFlowRow` instead of `HStack` so buttons wrap cleanly instead of clipping icons or truncating text:

```swift
LauncherFlowRow(spacing: 12, rowSpacing: 10) {
    Button { retry() } label: { Label(t("phone.retry"), systemImage: "arrow.clockwise") }
        .controllerButtonStyle(LauncherPrimaryButtonStyle(size: .prominent))
    CopyReportButton(model: model, gameID: id, operations: ops, fallback: msg, size: .prominent)
}
```

### Capsule Badges (`有新版`, `BETA`)
Always use `LauncherBadge` (which uses `Capsule(style: .circular)` and integer height) rather than `Text(...).overlay(Capsule().strokeBorder(...))`:

```swift
LauncherBadge("BETA", foreground: Self.gold, background: .clear,
              border: Self.gold.opacity(0.55), font: .manrope(9.5, .bold),
              tracking: 1.4, horizontalPadding: 8, height: 20)
```

## 3. Hard Rules (Never Violate)

1. **Never mix shapes or heights in the same row**: Every button in one `HStack` / `LauncherFlowRow` must use the same `ButtonShape` (all `.rounded` or all `.capsule`) and the same `ButtonSize`.
2. **Never use default `Capsule()` (`.continuous`) with `.strokeBorder(...)`**: On macOS SwiftUI, continuous capsules at small heights (18–36 pt) render vertical straight-line artifacts at left/right ends. Always use `Capsule(style: .circular)`, `LauncherControlShape`, or `LauncherBadge`.
3. **Never force `.fixedSize()` on buttons and never truncate button text**: Every square or capsule button uses its natural content width plus uniform horizontal padding from `LauncherTheme.buttonSpec(_:primary:)` (no `.fixedSize()`). Wrap multi-button long-label rows with `LauncherFlowRow`. Verify all 6 UI languages (`zh`, `zh-Hant`, `en`, `ja`, `es`, `fr`) at minimum window width.
4. **Never hand-roll button chrome or `LauncherHeroActionLabel`**: Always pass `Label(title, systemImage:)` into `LauncherPrimaryButtonStyle` / `LauncherSecondaryButtonStyle` so `LauncherLabelStyle` governs icon slot and spacing uniformly.
5. **Never apply `.clipShape(Capsule())` outside a button style**: Pass `shape: .capsule` so `PadRingShaped` reports `.infinity` to the gamepad focus ring.
6. **Always register interactive controls for gamepad navigation**:
   - Use `.controllerButtonStyle(...)`, `PadToggleStyle(.checkbox)`, `LauncherRadioRow`, or `LauncherSwitchStyle()` — never raw `.buttonStyle(...)` (mouse-only exceptions must use `.controllerExcluded(...)`). Note: checkboxes where left/right D-pad must stay reserved for navigation (such as `SGradeCard` `export.sgrade.toggle`) keep `.toggleStyle(.checkbox)` + `.controllerControl(id:activate:)` instead of `PadToggleStyle(.checkbox)`.
   - Custom `.plain` cards/rows/chips must declare `.controllerRingRadius(r)` matching their container corner radius.
   - Never produce double focus borders (solid cream controls use `outset: LauncherTheme.Focus.creamOutset`; dark/bordered controls use `outset: 0`; `LauncherRadioRow` uses `outset: 0`).
   - Every sheet / popover / inner sub-layer must handle `B` via `.controllerShortcut(.back)` or `.controllerBackAction(...)` without falling through to `Esc` beep.

## 4. Visual Verification Workflow

When changing UI styles, spacing, or button layouts:
1. Render the affected SwiftUI view(s) across all 6 languages (`zh`, `zh-Hant`, `en`, `ja`, `es`, `fr`) at minimum window width via `NSHostingView` + `NSWindow` + `bitmapImageRepForCachingDisplay` (same pattern as `SettingsLayoutTests.swift`) and inspect **BEFORE vs AFTER** side-by-side comparison images.
2. Verify visually:
   - No square + capsule or height mismatch in any row
   - No vertical straight-line artifacts on capsules/badges
   - No icon overflow, clipping, or truncated button text in any language

## 5. Keeping This Skill Synchronized (Mandatory)

Whenever you add, change, or deprecate any Theme Style token, reusable UI component, button/badge rule, or gamepad focus convention:
- **Update `skills/macos-launcher-theme-ui/SKILL.md` in the same PR** so every AI agent and contributor follows the exact same specification without drift.
- Keep Traditional Chinese (`zh-Hant`) UI strings aligned with Simplified Chinese (`zh`) and verify all 6 languages (`zh`, `zh-Hant`, `en`, `ja`, `es`, `fr`) have no truncated button text or hardcoded single-language labels.

## 6. Key Source Files

- [LauncherTheme.swift](../../launchers/macos/frontend/Sources/NXLauncher/LauncherTheme.swift): `ButtonShape`, `ButtonSize`, `buttonSpec`, `Focus`, `LauncherPrimaryButtonStyle`, `LauncherIconButtonStyle`, `LauncherLabelStyle`, `LauncherFlowRow`, `LauncherBadge`
- [LauncherStyles.swift](../../launchers/macos/frontend/Sources/NXLauncher/LauncherStyles.swift): `LauncherSecondaryButtonStyle`, `LauncherSwitchStyle`, `LauncherRadioRow`, `LauncherSegmented`, `LauncherSlider`
- [ConsoleButtonStyles.swift](../../launchers/macos/frontend/Sources/NX2Apple/ConsoleButtonStyles.swift): `ConsolePlayButtonStyle`, `ConsolePillButtonStyle`, `ConsoleIconButtonStyle`
- [LauncherPadNavigation.swift](../../launchers/macos/frontend/Sources/NX2Apple/LauncherPadNavigation.swift): `LauncherPadRing`, `PadRingShaped`, `B`-key layering
