import AppKit
import SceneItCore
import SwiftUI

/// The print dialog's choices (PLAN §10.1): a layout, and what to print.
@Observable
final class PrintChoices {
    var layout: PrintLayout {
        didSet { if layout != oldValue { changed() } }
    }
    var range: PrintRange {
        didSet { if range != oldValue { changed() } }
    }
    /// Only the ranges with something to print (`PrintRange.offered`).
    let ranges: [PrintRange]
    @ObservationIgnored var changed: () -> Void = {}

    init(openScene: SceneID?, in book: Book) {
        layout = .textOnly
        ranges = PrintRange.offered(in: book, open: openScene)
        range = ranges.first ?? .thisScene
    }
}

/// The choices as an accessory of the standard print dialog, so the dialog's preview follows
/// them. Choosing a layout turns the paper to suit it, as a starting point the dialog's own
/// Orientation can change.
final class PrintAccessoryController: NSViewController, NSPrintPanelAccessorizing {
    let choices: PrintChoices
    /// Changes whenever a choice does: the key the dialog watches to draw its preview again.
    @objc dynamic private(set) var revision = 0
    private var lastLayout: PrintLayout

    init(choices: PrintChoices) {
        self.choices = choices
        lastLayout = choices.layout
        super.init(nibName: nil, bundle: nil)
        choices.changed = { [weak self] in self?.choicesChanged() }
    }

    required init?(coder: NSCoder) {
        nil
    }

    override func loadView() {
        let hosting = NSHostingView(rootView: PrintAccessoryView(choices: choices))
        hosting.frame.size = hosting.fittingSize
        view = hosting
    }

    private func choicesChanged() {
        if choices.layout != lastLayout {
            lastLayout = choices.layout
            (representedObject as? NSPrintInfo)?.orientation = NSPrintInfo.PaperOrientation(
                choices.layout.orientation)
        }
        revision += 1
    }

    func localizedSummaryItems() -> [[NSPrintPanel.AccessorySummaryKey: String]] {
        [
            [.itemName: PrintWording.layoutLabel, .itemDescription: PrintWording.title(choices.layout)],
            [.itemName: PrintWording.rangeLabel, .itemDescription: PrintWording.title(choices.range)],
        ]
    }

    func keyPathsForValuesAffectingPreview() -> Set<String> {
        [#keyPath(revision)]
    }
}

extension NSPrintInfo.PaperOrientation {
    init(_ orientation: PaperOrientation) {
        self =
            switch orientation {
            case .portrait: .portrait
            case .landscape: .landscape
            }
    }
}

/// The two layouts as cards with a sketch of their page, and the range below them, as the
/// mockup draws them (15-print-dialog.png).
struct PrintAccessoryView: View {
    @Bindable var choices: PrintChoices

    var body: some View {
        VStack(alignment: .leading, spacing: PrintMetrics.sectionSpacing) {
            HStack(spacing: PrintMetrics.cardSpacing) {
                ForEach(PrintLayout.allCases, id: \.self) { layout in
                    LayoutCard(layout: layout, isChosen: choices.layout == layout) { choices.layout = layout }
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text(PrintWording.rangeLabel).font(.system(size: 11, weight: .semibold)).foregroundStyle(
                    .secondary)
                Picker(PrintWording.rangeLabel, selection: $choices.range) {
                    ForEach(choices.ranges, id: \.self) { range in
                        Text(PrintWording.title(range)).tag(range)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
            }
        }
        .padding(PrintMetrics.padding)
        .frame(width: PrintMetrics.width, alignment: .leading)
    }
}

enum PrintMetrics {
    static let width: CGFloat = 520
    static let padding: CGFloat = 16
    static let sectionSpacing: CGFloat = 14
    static let cardSpacing: CGFloat = 12
    static let cardHeight: CGFloat = 196
    static let cornerRadius: CGFloat = 8
    static let sketchSize = CGSize(width: 70, height: 90)
    static let wideSketchSize = CGSize(width: 130, height: 90)
}

private struct LayoutCard: View {
    let layout: PrintLayout
    let isChosen: Bool
    let choose: () -> Void

    var body: some View {
        Button(action: choose) {
            VStack(spacing: 8) {
                PageSketch(layout: layout)
                Text(PrintWording.title(layout)).font(.system(size: 13, weight: .semibold))
                Text(PrintWording.detail(layout))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, minHeight: PrintMetrics.cardHeight, alignment: .top)
            .background(
                isChosen ? Color.accentColor.opacity(0.1) : Color(nsColor: .controlBackgroundColor),
                in: RoundedRectangle(cornerRadius: PrintMetrics.cornerRadius)
            )
            .overlay(
                RoundedRectangle(cornerRadius: PrintMetrics.cornerRadius)
                    .strokeBorder(
                        isChosen ? Color.accentColor : Color(nsColor: .separatorColor),
                        lineWidth: isChosen ? 2 : 1)
            )
            .contentShape(RoundedRectangle(cornerRadius: PrintMetrics.cornerRadius))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isChosen ? .isSelected : [])
    }
}

/// A sheet of paper with grey lines of text; with comments, wider, with a dashed rule and
/// coloured comments beside an underlined line.
private struct PageSketch: View {
    let layout: PrintLayout

    var body: some View {
        let size = layout == .textOnly ? PrintMetrics.sketchSize : PrintMetrics.wideSketchSize
        ZStack(alignment: .topLeading) {
            Rectangle().fill(.white)
            Rectangle().strokeBorder(Color(nsColor: .separatorColor), lineWidth: 1)
            HStack(alignment: .top, spacing: 6) {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(0..<7, id: \.self) { line in
                        Capsule()
                            .fill(
                                underlined(line)
                                    ? Color(nsColor: PaletteColor.purple.nsColor) : Color.gray.opacity(0.45)
                            )
                            .frame(width: line == 4 ? 30 : nil, height: 2)
                    }
                }
                .frame(width: layout == .textOnly ? size.width - 20 : 64)
                if layout == .withComments {
                    Rectangle()
                        .stroke(style: StrokeStyle(lineWidth: 1, dash: [2, 2]))
                        .foregroundStyle(Color.gray.opacity(0.5))
                        .frame(width: 1)
                    VStack(alignment: .leading, spacing: 5) {
                        commentSketch(.purple).padding(.top, 9)
                        commentSketch(.red)
                    }
                }
            }
            .padding(10)
        }
        .frame(width: size.width, height: size.height)
    }

    private func underlined(_ line: Int) -> Bool {
        layout == .withComments && line == 2
    }

    private func commentSketch(_ color: PaletteColor) -> some View {
        HStack(spacing: 0) {
            Rectangle().fill(Color(nsColor: color.nsColor)).frame(width: 2)
            Rectangle().fill(Color.gray.opacity(0.15))
        }
        .frame(width: 34, height: 12)
    }
}
