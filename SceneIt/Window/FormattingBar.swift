import SceneItCore
import SwiftUI

/// The editor control bar (PLAN §6.2): B, I, S, the text color and highlight with their
/// palettes, and Read aloud (#39). Each control shows its state for the page's selection; the
/// whole bar is inactive while the page can't be formatted.
struct FormattingBar: View {
    let formatting: PageFormatting
    @Environment(\.formattingBarLook) private var look

    var body: some View {
        HStack(spacing: 8) {
            BarGroup(look: look) {
                ForEach(TextStyle.allCases, id: \.self) { style in
                    BarButton(
                        formatting: formatting, command: .toggle(style), help: WindowWording.style(style)
                    ) {
                        Image(systemName: Self.symbol(style))
                    }
                }
            }
            BarDivider()
            ColorControl(formatting: formatting, kind: .textColor)
            ColorControl(formatting: formatting, kind: .highlight)
            BarDivider()
            Button {
            } label: {
                Image(systemName: "play.fill")
            }
            .buttonStyle(BarButtonStyle(look: look, state: .off))
            .disabled(true)
            .help(WindowWording.readAloud)
            .accessibilityLabel(WindowWording.readAloud)
        }
        .disabled(formatting.selection == nil)
    }

    private static func symbol(_ style: TextStyle) -> String {
        switch style {
        case .bold: "bold"
        case .italic: "italic"
        case .strike: "strikethrough"
        }
    }
}

/// A button that performs `command` and shows its state for the selection.
private struct BarButton<Label: View>: View {
    let formatting: PageFormatting
    let command: FormattingCommand
    let help: String
    @ViewBuilder let label: Label
    @Environment(\.formattingBarLook) private var look

    var body: some View {
        let state = formatting.state(of: command)
        Button {
            formatting.perform(command)
        } label: {
            label
        }
        .buttonStyle(BarButtonStyle(look: look, state: state ?? .off))
        .help(state == nil ? WindowWording.clickInThePageToFormat : help)
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

/// The text color or highlight: a button applying the last color chosen, and ▾ for the palette.
private struct ColorControl: View {
    let formatting: PageFormatting
    let kind: Kind
    @Environment(\.formattingBarLook) private var look
    @State private var showsPalette = false

    enum Kind {
        case textColor, highlight
    }

    var body: some View {
        let command = kind == .textColor ? formatting.lastTextColor : formatting.lastHighlight
        let name = kind == .textColor ? WindowWording.textColor : WindowWording.highlight
        let arrow = Button {
            showsPalette = true
        } label: {
            Image(systemName: "chevron.down")
                .font(.system(size: 8, weight: .bold))
                .frame(width: 10)
        }
        .help(formatting.selection == nil ? WindowWording.clickInThePageToFormat : WindowWording.showPalette)
        .accessibilityLabel("\(name): \(WindowWording.showPalette)")
        .popover(isPresented: $showsPalette, arrowEdge: .bottom) {
            PaletteView(formatting: formatting, commands: palette, layout: look.palette) {
                showsPalette = false
            }
        }
        let main = BarButton(formatting: formatting, command: command, help: name) {
            ColorGlyph(command: command, style: look.colorGlyph)
        }
        switch look.colorButton {
        case .separateArrow:
            HStack(spacing: 0) {
                main
                arrow.buttonStyle(BarButtonStyle(look: look, state: .off, width: .narrow))
            }
        case .split:
            HStack(spacing: 0) {
                main
                Divider().frame(height: 16)
                arrow.buttonStyle(BarButtonStyle(look: look.borderless, state: .off, width: .narrow))
            }
            .environment(\.formattingBarLook, look.borderless)
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
        }
    }

    private var palette: [FormattingCommand] {
        kind == .textColor ? FormattingCommand.textColors : FormattingCommand.highlights
    }
}

/// What the color buttons show: the last color chosen.
private struct ColorGlyph: View {
    let command: FormattingCommand
    let style: FormattingBarLook.ColorGlyph

    var body: some View {
        switch (command, style) {
        case (.textColor(let color), .letter):
            VStack(spacing: 1) {
                Text(verbatim: "A").font(.system(size: 13, weight: .semibold))
                Rectangle().fill(Color(nsColor: color.nsColor)).frame(width: 13, height: 3)
            }
        case (.textColor(let color), .symbol):
            Image(systemName: "paintbrush.pointed.fill").foregroundStyle(Color(nsColor: color.nsColor))
        case (.highlight(let highlight), .letter):
            Text(verbatim: "A").font(.system(size: 13, weight: .semibold))
                .frame(width: 18, height: 18)
                .background(RoundedRectangle(cornerRadius: 3).fill(Swatch.color(highlight)))
        case (.highlight(let highlight), .symbol):
            Image(systemName: "highlighter")
                .frame(width: 20, height: 18)
                .background(RoundedRectangle(cornerRadius: 3).fill(Swatch.color(highlight)))
        case (.toggle, _):
            EmptyView()
        }
    }
}

/// A palette: each color as a swatch, the selection's own ringed.
struct PaletteView: View {
    let formatting: PageFormatting
    let commands: [FormattingCommand]
    let layout: FormattingBarLook.Palette
    let chosen: () -> Void

    var body: some View {
        Group {
            switch layout {
            case .row:
                HStack(spacing: 4) {
                    ForEach(commands, id: \.self) { swatch($0, labelled: false) }
                }
            case .labelledGrid:
                Grid(horizontalSpacing: 4, verticalSpacing: 4) {
                    ForEach(Array(stride(from: 0, to: commands.count, by: 4)), id: \.self) { start in
                        GridRow {
                            ForEach(commands[start..<min(start + 4, commands.count)], id: \.self) {
                                swatch($0, labelled: true)
                            }
                        }
                    }
                }
            }
        }
        .padding(8)
    }

    private func swatch(_ command: FormattingCommand, labelled: Bool) -> some View {
        let name = WindowWording.menuItem(command)
        return Button {
            formatting.perform(command)
            chosen()
        } label: {
            VStack(spacing: 3) {
                Swatch(command: command, ringed: formatting.state(of: command) == .on)
                if labelled {
                    Text(name).font(.caption)
                }
            }
            .frame(minWidth: labelled ? 52 : 28)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(name)
        .accessibilityLabel(name)
    }
}

struct Swatch: View {
    let command: FormattingCommand
    let ringed: Bool

    var body: some View {
        ZStack {
            Circle().fill(fill)
            Circle().strokeBorder(.black.opacity(0.15))
            if case .highlight(nil) = command {
                Rectangle().fill(.red).frame(width: 1.5, height: 18).rotationEffect(.degrees(45))
            }
        }
        .frame(width: 18, height: 18)
        .clipShape(Circle())
        .padding(3)
        .overlay(Circle().strokeBorder(ringed ? Color.accentColor : .clear, lineWidth: 2))
    }

    private var fill: Color {
        switch command {
        case .textColor(let color): Color(nsColor: color.nsColor)
        case .highlight(let highlight): Self.color(highlight)
        case .toggle: .clear
        }
    }

    static func color(_ highlight: HighlightColor?) -> Color {
        highlight.map { Color(nsColor: $0.nsColor) } ?? .white
    }
}

/// B, I and S together, as `look` groups them.
private struct BarGroup<Content: View>: View {
    let look: FormattingBarLook
    @ViewBuilder let content: Content

    var body: some View {
        switch look.buttons {
        case .plain:
            HStack(spacing: 2) { content }
        case .bordered:
            HStack(spacing: 4) { content }
        case .segmented:
            HStack(spacing: 0) { content }
                .environment(\.formattingBarLook, look.borderless)
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
        }
    }
}

private struct BarDivider: View {
    var body: some View {
        Divider().frame(height: 18)
    }
}

/// A bar button: its glyph, its state for the selection, and its border.
private struct BarButtonStyle: ButtonStyle {
    let look: FormattingBarLook
    let state: ControlState
    var width = Width.regular
    @Environment(\.isEnabled) private var isEnabled

    enum Width {
        case regular, narrow
    }

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 13, weight: .medium))
            .frame(width: width == .regular ? 26 : 14, height: 24)
            .foregroundStyle(tint)
            .background(RoundedRectangle(cornerRadius: 5).fill(fill(pressed: configuration.isPressed)))
            .overlay(alignment: .bottom) { underline }
            .overlay {
                if look.buttons == .bordered {
                    RoundedRectangle(cornerRadius: 5).strokeBorder(.separator)
                }
            }
            .opacity(isEnabled ? 1 : 0.35)
            .contentShape(Rectangle())
    }

    private func fill(pressed: Bool) -> Color {
        if pressed { return .primary.opacity(0.2) }
        guard look.stateMark == .fill else { return .clear }
        switch state {
        case .off: return .clear
        case .on: return .primary.opacity(0.14)
        case .mixed: return .primary.opacity(0.06)
        }
    }

    private var tint: Color {
        guard look.stateMark == .tint else { return .primary }
        switch state {
        case .off: return .primary
        case .on: return .accentColor
        case .mixed: return .accentColor.opacity(0.5)
        }
    }

    @ViewBuilder private var underline: some View {
        if look.stateMark == .underline, state != .off {
            Capsule()
                .fill(Color.accentColor.opacity(state == .on ? 1 : 0.45))
                .frame(width: state == .on ? 16 : 8, height: 2)
        }
    }
}

/// The bar's look, while the owner chooses among candidates (CLAUDE.md: aesthetic choices are
/// the owner's). The window uses `recommended`; the renders show the others.
struct FormattingBarLook: Hashable {
    var buttons: Buttons
    var stateMark: StateMark
    var colorButton: ColorButton
    var colorGlyph: ColorGlyph
    var palette: Palette

    enum Buttons: CaseIterable { case plain, bordered, segmented }
    /// How a button shows that the selection is (partly) formatted its way.
    enum StateMark: CaseIterable { case fill, tint, underline }
    enum ColorButton: CaseIterable { case separateArrow, split }
    enum ColorGlyph: CaseIterable { case letter, symbol }
    enum Palette: CaseIterable { case row, labelledGrid }

    static let recommended = Self(
        buttons: .plain, stateMark: .fill, colorButton: .separateArrow, colorGlyph: .letter, palette: .row)

    /// The same look for buttons inside a group that draws the border.
    var borderless: Self {
        var look = self
        look.buttons = .plain
        return look
    }
}

extension EnvironmentValues {
    @Entry var formattingBarLook = FormattingBarLook.recommended
}
