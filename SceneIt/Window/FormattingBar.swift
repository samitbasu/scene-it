import SceneItCore
import SwiftUI

/// The editor control bar (PLAN §6.2): B, I, S, the text color and highlight with their
/// palettes, and Read aloud (#39). Each control shows its state for the page's selection; the
/// whole bar is dimmed while the page can't be formatted. Its look is the owner's pick (#18,
/// `WindowMetrics.Bar`).
struct FormattingBar: View {
    let formatting: PageFormatting

    var body: some View {
        HStack(spacing: WindowMetrics.Bar.groupSpacing) {
            HStack(spacing: WindowMetrics.Bar.buttonSpacing) {
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
            .buttonStyle(BarButtonStyle(state: .off))
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

    var body: some View {
        let state = formatting.state(of: command)
        Button {
            formatting.perform(command)
        } label: {
            label
        }
        .buttonStyle(BarButtonStyle(state: state ?? .off))
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

/// The text color or highlight: a button applying the last color chosen, and a separate ▾ for
/// the palette.
private struct ColorControl: View {
    let formatting: PageFormatting
    let kind: Kind
    @State private var showsPalette = false

    enum Kind {
        case textColor, highlight
    }

    var body: some View {
        let command = kind == .textColor ? formatting.lastTextColor : formatting.lastHighlight
        let name = kind == .textColor ? WindowWording.textColor : WindowWording.highlight
        HStack(spacing: 0) {
            BarButton(formatting: formatting, command: command, help: name) {
                ColorGlyph(command: command)
            }
            Button {
                showsPalette = true
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
            }
            .buttonStyle(BarButtonStyle(state: .off, width: .narrow))
            .help(
                formatting.selection == nil ? WindowWording.clickInThePageToFormat : WindowWording.showPalette
            )
            .accessibilityLabel("\(name): \(WindowWording.showPalette)")
            .popover(isPresented: $showsPalette, arrowEdge: .bottom) {
                PaletteView(formatting: formatting, commands: palette) {
                    showsPalette = false
                }
            }
        }
    }

    private var palette: [FormattingCommand] {
        kind == .textColor ? FormattingCommand.textColors : FormattingCommand.highlights
    }
}

/// What a color button shows: an "A" over a bar of the last text color, or on a tile of the last
/// highlight.
private struct ColorGlyph: View {
    let command: FormattingCommand

    var body: some View {
        let letter = Text(verbatim: "A").font(.system(size: 13, weight: .semibold))
        switch command {
        case .textColor(let color):
            VStack(spacing: 1) {
                letter
                Rectangle().fill(Color(nsColor: color.nsColor))
                    .frame(
                        width: WindowMetrics.Bar.colorBarSize.width,
                        height: WindowMetrics.Bar.colorBarSize.height)
            }
        case .highlight(let highlight):
            letter
                .frame(width: WindowMetrics.Bar.highlightTile, height: WindowMetrics.Bar.highlightTile)
                .background(RoundedRectangle(cornerRadius: 3).fill(Swatch.color(highlight)))
        case .toggle:
            EmptyView()
        }
    }
}

/// A palette: a row of swatches, named in their tooltips, the selection's own ringed.
struct PaletteView: View {
    let formatting: PageFormatting
    let commands: [FormattingCommand]
    let chosen: () -> Void

    var body: some View {
        HStack(spacing: WindowMetrics.Bar.buttonSpacing) {
            ForEach(commands, id: \.self) { command in
                let name = WindowWording.menuItem(command)
                Button {
                    formatting.perform(command)
                    chosen()
                } label: {
                    Swatch(command: command, ringed: formatting.state(of: command) == .on)
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
    let command: FormattingCommand
    let ringed: Bool

    var body: some View {
        let size = WindowMetrics.Bar.swatchSize
        ZStack {
            Circle().fill(fill)
            Circle().strokeBorder(.black.opacity(0.15))
            if case .highlight(nil) = command {
                Rectangle().fill(.red).frame(width: 1.5, height: size).rotationEffect(.degrees(45))
            }
        }
        .frame(width: size, height: size)
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
