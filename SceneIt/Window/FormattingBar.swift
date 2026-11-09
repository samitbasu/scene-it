import SceneItCore
import SwiftUI

/// An editor control bar (PLAN §6.2): B, I, S, and the text color and highlight with their
/// palettes. Above the page, `ReadAloudButton` follows it; the Notes tab has its compact copy.
/// Each control shows its state for its editor's selection; the whole bar is dimmed while its
/// editor can't be formatted, which is always so for one of the two. Its look is the owner's
/// pick (#18, `WindowMetrics.Bar`).
struct FormattingBar: View {
    let formatting: EditorFormatting
    /// Whose bar it is: the page's, or the notes' compact copy.
    let part: TextPart

    var body: some View {
        HStack(spacing: WindowMetrics.Bar.groupSpacing) {
            HStack(spacing: WindowMetrics.Bar.buttonSpacing) {
                ForEach(TextStyle.allCases, id: \.self) { style in
                    BarButton(
                        formatting: formatting, part: part, command: .toggle(style),
                        help: WindowWording.style(style)
                    ) {
                        Image(systemName: Self.symbol(style))
                    }
                }
            }
            BarDivider()
            ColorControl(formatting: formatting, part: part, kind: .textColor)
            ColorControl(formatting: formatting, part: part, kind: .highlight)
        }
        .disabled(formatting.selection(in: part) == nil)
    }

    private static func symbol(_ style: TextStyle) -> String {
        switch style {
        case .bold: "bold"
        case .italic: "italic"
        case .strike: "strikethrough"
        }
    }
}

/// ▶ Read aloud, ■ Stop while reading (PLAN §6.2, §10.3), with its shortcut. It isn't dimmed with
/// the formatting bar: it reads the page's selection even when the page can't be formatted.
struct ReadAloudButton: View {
    let readAloud: ReadAloud

    var body: some View {
        let control = readAloud.control
        let name = control == .stop ? WindowWording.stopReadingAloud : WindowWording.readAloud
        HStack(spacing: WindowMetrics.Bar.groupSpacing) {
            BarDivider()
            Button {
                readAloud.press()
            } label: {
                Image(systemName: control == .stop ? "stop.fill" : "play.fill")
            }
            .buttonStyle(BarButtonStyle(state: .off))
            .keyboardShortcut(.readAloud)
            .disabled(control == .unavailable)
            .help(name)
            .accessibilityLabel(name)
        }
    }
}

extension KeyboardShortcut {
    /// PLAN §11. Written "R": SwiftUI then matches the key whether the event spells it "R" or
    /// "r" ignoring modifiers, where "r" matches only "r".
    static let readAloud = KeyboardShortcut("R", modifiers: [.command, .shift])
}

/// A button that performs `command` and shows its state for its editor's selection.
private struct BarButton<Label: View>: View {
    let formatting: EditorFormatting
    let part: TextPart
    let command: FormattingCommand
    let help: String
    @ViewBuilder let label: Label

    var body: some View {
        let state = formatting.state(of: command, in: part)
        Button {
            formatting.perform(command)
        } label: {
            label
        }
        .buttonStyle(BarButtonStyle(state: state ?? .off))
        .help(state == nil ? WindowWording.clickToFormat(part) : help)
        .accessibilityLabel(help)
        .accessibilityValue(state.map(Self.accessibilityValue) ?? "")
    }

    private static func accessibilityValue(_ state: ControlState) -> String {
        switch state {
        case .off: "off"
        case .on: "on"
        case .mixed: "mixed"
        }
    }
}

/// The bar's two color controls, and their palettes.
enum PaletteKind {
    case textColor, highlight

    var name: String {
        switch self {
        case .textColor: WindowWording.textColor
        case .highlight: WindowWording.highlight
        }
    }

    var inks: [Ink] {
        switch self {
        case .textColor: PaletteColor.allCases.map(Ink.text)
        case .highlight: HighlightColor.choices.map(Ink.highlight)
        }
    }

    /// What the control's button applies: the last color chosen from its palette.
    func lastUsed(_ preferences: AppPreferences) -> Ink {
        switch self {
        case .textColor: .text(PaletteColor(preferences.lastTextColor))
        case .highlight: .highlight(preferences.lastHighlight)
        }
    }
}

/// A color the bar shows and applies: a text color, or a highlight (`nil` for None).
enum Ink: Hashable {
    case text(PaletteColor)
    case highlight(HighlightColor?)

    var command: FormattingCommand {
        switch self {
        case .text(let color): .textColor(color)
        case .highlight(let highlight): .highlight(highlight)
        }
    }

    var color: Color {
        switch self {
        case .text(let color): Color(nsColor: color.nsColor)
        case .highlight(let highlight?): Color(nsColor: highlight.nsColor)
        case .highlight(nil): .white
        }
    }
}

/// The text color or highlight: a button applying the last color chosen, and a separate ▾ for
/// the palette.
private struct ColorControl: View {
    let formatting: EditorFormatting
    let part: TextPart
    let kind: PaletteKind
    @Environment(\.windowKeys) private var keys

    /// Open while the window's keys say so, so Esc closes it before anything else.
    private var showsPalette: Binding<Bool> {
        let palette = WindowPopover.palette(part, kind)
        return Binding(
            get: { keys?.popover == palette },
            set: { shown in
                if shown {
                    keys?.popover = palette
                } else if keys?.popover == palette {
                    keys?.popover = nil
                }
            })
    }

    var body: some View {
        let ink = kind.lastUsed(formatting.preferences)
        HStack(spacing: 0) {
            BarButton(formatting: formatting, part: part, command: ink.command, help: kind.name) {
                ColorGlyph(ink: ink)
            }
            Button {
                showsPalette.wrappedValue = true
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(BarButtonStyle(state: .off, width: .narrow))
            .help(
                formatting.selection(in: part) == nil
                    ? WindowWording.clickToFormat(part) : WindowWording.showPalette
            )
            .accessibilityLabel("\(kind.name): \(WindowWording.showPalette)")
            .popover(isPresented: showsPalette, arrowEdge: .bottom) {
                PaletteView(formatting: formatting, part: part, kind: kind) {
                    showsPalette.wrappedValue = false
                }
                .background(EscapeKey(keys: keys))
            }
            // A bar that's gone (the panel hidden, a tab switched) takes its palette with it.
            .onDisappear { showsPalette.wrappedValue = false }
        }
    }
}

/// What a color button shows: an "A" over a bar of the text color, or on a tile of the
/// highlight.
private struct ColorGlyph: View {
    let ink: Ink

    var body: some View {
        let letter = Text(verbatim: "A").font(.system(size: 13, weight: .semibold))
        switch ink {
        case .text:
            VStack(spacing: 1) {
                letter
                Rectangle().fill(ink.color)
                    .frame(
                        width: WindowMetrics.Bar.colorBarSize.width,
                        height: WindowMetrics.Bar.colorBarSize.height)
            }
        case .highlight:
            letter
                .frame(width: WindowMetrics.Bar.highlightTile, height: WindowMetrics.Bar.highlightTile)
                .background(RoundedRectangle(cornerRadius: 3).fill(ink.color))
        }
    }
}

/// A palette: a row of swatches, named in their tooltips, the selection's own ringed.
struct PaletteView: View {
    let formatting: EditorFormatting
    let part: TextPart
    let kind: PaletteKind
    let chosen: () -> Void

    var body: some View {
        HStack(spacing: WindowMetrics.Bar.buttonSpacing) {
            ForEach(kind.inks, id: \.self) { ink in
                let name = WindowWording.menuItem(ink.command)
                Button {
                    formatting.perform(ink.command)
                    chosen()
                } label: {
                    Swatch(ink: ink, ringed: formatting.state(of: ink.command, in: part) == .on)
                        .frame(minWidth: WindowMetrics.Bar.buttonSize.width)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help(name)
                .accessibilityLabel(name)
            }
        }
        .padding(8)
    }
}

/// One palette color; "None" is a white circle with a red slash.
private struct Swatch: View {
    let ink: Ink
    let ringed: Bool

    var body: some View {
        let size = WindowMetrics.Bar.swatchSize
        ZStack {
            Circle().fill(ink.color)
            Circle().strokeBorder(.black.opacity(0.15))
            if ink == .highlight(nil) {
                Rectangle().fill(.red).frame(width: 1.5, height: size).rotationEffect(.degrees(45))
            }
        }
        .frame(width: size, height: size)
        .clipShape(Circle())
        .padding(3)
        .overlay(Circle().strokeBorder(ringed ? Color.accentColor : .clear, lineWidth: 2))
    }
}

private struct BarDivider: View {
    var body: some View {
        Divider().frame(height: 18)
    }
}

/// A plain glyph button whose background shows its state: darker for on, lighter for mixed.
private struct BarButtonStyle: ButtonStyle {
    let state: ControlState
    var width = Width.regular
    @Environment(\.isEnabled) private var isEnabled

    enum Width {
        case regular, narrow
    }

    func makeBody(configuration: Configuration) -> some View {
        let size = WindowMetrics.Bar.buttonSize
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .frame(width: width == .regular ? size.width : WindowMetrics.Bar.arrowWidth, height: size.height)
            .background(
                RoundedRectangle(cornerRadius: WindowMetrics.Bar.cornerRadius)
                    .fill(.primary.opacity(fillOpacity(pressed: configuration.isPressed)))
            )
            .opacity(isEnabled ? 1 : WindowMetrics.Bar.dimmedOpacity)
            .contentShape(Rectangle())
    }

    private func fillOpacity(pressed: Bool) -> Double {
        if pressed { return WindowMetrics.Bar.pressedFill }
        switch state {
        case .off: return 0
        case .on: return WindowMetrics.Bar.onFill
        case .mixed: return WindowMetrics.Bar.mixedFill
        }
    }
}
