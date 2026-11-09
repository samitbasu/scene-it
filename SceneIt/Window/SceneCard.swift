import AppKit
import SceneItCore
import SwiftUI

/// What both kinds of card show of a scene.
struct SceneCardContent {
    let scene: BookScene
    /// Its place in the whole story, from 1.
    let number: Int
    let isOpen: IsOpen
    /// Whether the card shows the title field of a scene just added.
    let titling: Titling

    enum IsOpen {
        case open, notOpen
    }

    enum Titling {
        case typing, done
    }
}

/// A card of the cards view (mockup 07): number, title and drag handle; words and when it last
/// changed; the first sentence; the tags.
struct SceneCard: View {
    let content: SceneCardContent
    let words: WordCount
    let ticker: MinuteTicker
    let actions: ScenesActions
    let editability: Editability

    var body: some View {
        CardShell(content: content, view: .cards, actions: actions) { _ in
            VStack(alignment: .leading, spacing: 6) {
                CardHeading(content: content, actions: actions, lines: .one)
                HStack {
                    Text(WindowWording.words(words))
                    Spacer(minLength: 8)
                    Text(ScenesWording.modified(ticker.age(of: content.scene.modified)))
                }
                .font(.system(size: WindowMetrics.Scenes.metaSize))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                let excerpt = SceneExcerpt.of(content.scene.body)
                if !excerpt.isEmpty {
                    Text(excerpt)
                        .font(.custom("Times New Roman", size: WindowMetrics.Scenes.excerptSize))
                        .lineSpacing(WindowMetrics.Scenes.excerptLineSpacing)
                        .fixedSize(horizontal: false, vertical: true)
                }
                CardTags(scene: content.scene, actions: actions, editability: editability, offer: .always)
            }
        }
    }
}

/// A tile of the light table (mockup 08): number, title on up to two lines and drag handle; the
/// tags, with + tag while the pointer is over it.
struct LightTableCard: View {
    let content: SceneCardContent
    let actions: ScenesActions
    let editability: Editability

    var body: some View {
        CardShell(content: content, view: .lightTable, actions: actions) { hovering in
            VStack(alignment: .leading, spacing: 6) {
                CardHeading(content: content, actions: actions, lines: .two)
                CardTags(
                    scene: content.scene, actions: actions, editability: editability,
                    offer: hovering == .hovering ? .always : .whileOpen)
            }
            .frame(
                minHeight: WindowMetrics.Scenes.lightTableHeight - 2
                    * WindowMetrics.Scenes.padding(.lightTable),
                alignment: .top)
        }
    }
}

/// Whether the pointer is over a card.
enum Hovering {
    case hovering, away
}

/// A card's frame: white, outlined (in the accent color while its scene is open), filling its
/// grid cell. A click anywhere the card's own controls don't take opens the scene.
private struct CardShell<Content: View>: View {
    let content: SceneCardContent
    let view: ScenesView
    let actions: ScenesActions
    @ViewBuilder let inside: (Hovering) -> Content
    @State private var hovering = Hovering.away

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: WindowMetrics.Scenes.cornerRadius)
        inside(hovering)
            .padding(WindowMetrics.Scenes.padding(view))
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(content.isOpen == .open ? WindowMetrics.Scenes.openFill : Color.white, in: shape)
            .overlay(shape.strokeBorder(border, lineWidth: borderWidth))
            .contentShape(shape)
            .onTapGesture { actions.open(content.scene.id) }
            .onHover { hovering = $0 ? .hovering : .away }
            .help(ScenesWording.openHelp)
            .accessibilityElement(children: .contain)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { actions.open(content.scene.id) }
    }

    private var border: Color {
        switch (content.isOpen, hovering) {
        case (.open, _): .accentColor
        case (.notOpen, .hovering): WindowMetrics.Scenes.hoverLine
        case (.notOpen, .away): WindowMetrics.Scenes.line
        }
    }

    private var borderWidth: CGFloat {
        content.isOpen == .open ? WindowMetrics.Scenes.openBorder : 1
    }
}

/// How many lines a title may take.
private enum TitleLines {
    case one, two

    var limit: Int {
        switch self {
        case .one: 1
        case .two: 2
        }
    }
}

/// The number in its circle, the title (or the title field, on a scene just added) and the drag
/// handle, which only shows where dragging will be (#29).
private struct CardHeading: View {
    let content: SceneCardContent
    let actions: ScenesActions
    let lines: TitleLines

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            SceneNumber(placement: .story(number: content.number))
            switch content.titling {
            case .typing:
                CardTitleField(scene: content.scene.id, title: content.scene.title.text, actions: actions)
            case .done:
                Text(WindowWording.sceneName(content.scene))
                    .font(.system(size: WindowMetrics.Scenes.titleSize, weight: .semibold))
                    .foregroundStyle(content.scene.title.text.isEmpty ? .secondary : .primary)
                    .lineLimit(lines.limit)
                    .truncationMode(.tail)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            DragGrip()
                .help(ScenesWording.dragHelp)
                .accessibilityHidden(true)
        }
    }
}

/// The mockup's ⋮⋮ at a card's top right: two columns of three dots.
private struct DragGrip: View {
    var body: some View {
        let grip = WindowMetrics.Scenes.Grip.self
        Grid(horizontalSpacing: grip.gap, verticalSpacing: grip.gap) {
            ForEach(0..<3, id: \.self) { _ in
                GridRow {
                    ForEach(0..<2, id: \.self) { _ in
                        Circle().fill(grip.color).frame(width: grip.dot, height: grip.dot)
                    }
                }
            }
        }
        .padding(.horizontal, 2)
    }
}

/// When a card offers + tag.
private enum TagOffer {
    case always
    /// Only while its field is open: a light-table tile the pointer isn't over.
    case whileOpen
}

/// The scene's tags as the Tags tab's chips, then + tag while the scene can be tagged. + tag is
/// the look's: a chip that opens the field, or the field itself. Return adds the tag and keeps
/// the field open for the next; Esc, or the focus leaving it empty, closes it.
private struct CardTags: View {
    let scene: BookScene
    let actions: ScenesActions
    let editability: Editability
    let offer: TagOffer

    private enum Entry {
        case closed, open
    }

    var body: some View {
        let entry: Entry = actions.model.tagging == scene.id ? .open : .closed
        let offersTag = editability == .editable && (offer == .always || entry == .open)
        if !scene.tags.isEmpty || offersTag {
            ChipFlow(spacing: ChipSpacing(points: WindowMetrics.Tags.chipGap)) {
                ForEach(Array(scene.tags.enumerated()), id: \.offset) { _, tag in
                    TagChip(label: SceneTag.shown(tag), remove: removal(of: tag))
                }
                if offersTag { newTag(entry) }
            }
        }
    }

    @ViewBuilder private func newTag(_ entry: Entry) -> some View {
        switch (WindowMetrics.Scenes.look.tagEntry, entry) {
        case (.alwaysField, _), (.chipOpensField, .open):
            NewTagField(
                book: actions.book, add: { actions.tags.add($0, to: scene.id) },
                leave: { $0.window?.makeFirstResponder(nil) },
                opening: entry == .open ? .focused : .unfocused,
                ended: { actions.stopTagging(scene.id) }
            )
            .frame(width: WindowMetrics.Tags.addFieldWidth)
        case (.chipOpensField, .closed):
            Button {
                actions.startTagging(scene.id)
            } label: {
                Text(TagWording.addPlaceholder)
                    .font(WindowMetrics.Tags.chipFont)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, WindowMetrics.Tags.chipPadding)
                    .frame(height: WindowMetrics.Tags.chipHeight)
                    .overlay(
                        RoundedRectangle(cornerRadius: WindowMetrics.Tags.chipCornerRadius)
                            .strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
                            .foregroundStyle(.tertiary)
                    )
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(TagWording.addHelp)
            .fixedSize()
        }
    }

    private func removal(of tag: String) -> TagChip.Removal? {
        guard editability == .editable else { return nil }
        return TagChip.Removal(label: TagWording.removeHelp(tag)) { actions.tags.remove(tag, from: scene.id) }
    }
}

/// The dashed tile after the last card (mockups 08 and 09): adds a scene at the end.
struct NewSceneTile: View {
    let view: ScenesView
    let add: () -> Void

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: WindowMetrics.Scenes.cornerRadius)
        Button(action: add) {
            Text(ScenesWording.newScene)
                .font(.system(size: WindowMetrics.Scenes.titleSize, weight: .medium))
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, minHeight: WindowMetrics.Scenes.newTileHeight)
                .overlay(
                    shape.strokeBorder(style: StrokeStyle(lineWidth: 1.5, dash: [5, 3])).foregroundStyle(
                        .tertiary)
                )
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .help(ScenesWording.newSceneTileHelp)
    }
}

/// The title field on a scene just added (PLAN §7.2), the page's title field
/// (`AdmittingTextField.sceneTitle`). It takes the focus as it appears and writes the title into
/// the book as it's typed, so nothing typed waits on Return to be saved. Return, or anything else
/// that ends the typing, closes it.
private struct CardTitleField: NSViewRepresentable {
    let scene: SceneID
    let title: String
    let actions: ScenesActions

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> AdmittingTextField {
        let coordinator = context.coordinator
        let field = AdmittingTextField.sceneTitle(title, in: actions.book)
        field.font = .systemFont(ofSize: WindowMetrics.Scenes.titleSize, weight: .semibold)
        field.setAccessibilityLabel(ScenesWording.titleLabel)
        field.delegate = coordinator
        field.firstFocus = .pending
        coordinator.field = field
        coordinator.actions = actions
        coordinator.show(scene, of: actions.book)
        return field
    }

    func updateNSView(_ field: AdmittingTextField, context: Context) {
        context.coordinator.actions = actions
        context.coordinator.show(scene, of: actions.book)
    }

    static func dismantleNSView(_ field: AdmittingTextField, coordinator: Coordinator) {
        coordinator.finish()
        field.delegate = nil
        field.editor?.history = nil
    }

    final class Coordinator: TitleFieldCoordinator {
        var actions: ScenesActions?

        override func command(_ selector: Selector, in textView: NSTextView) -> Bool {
            guard selector == #selector(NSResponder.insertNewline(_:)) else { return false }
            textView.window?.makeFirstResponder(nil)
            return true
        }

        override func endedEditing() {
            finish()
        }

        /// Closes the field, once. Its typing steps on the scene's title history were made in
        /// this field's own editor, which goes with it, so they go too: replayed in the page's
        /// title field they would change nothing.
        func finish() {
            guard let actions, let scene else { return }
            self.actions = nil
            actions.book.titleUndo(for: scene).removeAllActions()
            actions.finishTitling(scene)
        }
    }
}
