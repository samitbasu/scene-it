import AppKit
import SceneItCore
import SwiftUI

/// The Comments tab (PLAN §8.1): the search field and +, then the open scene's cards in text
/// order, then the Detached group. A card's text is edited in place; its ⋯ menu recolors or
/// dismisses it. Selecting a card selects its text on the page, and clicking commented text on
/// the page selects its card (`CommentSelection`).
struct CommentsTab: View {
    let book: AppOpenBook
    let formatting: EditorFormatting
    let editors: SceneEditors
    @State private var search = ""

    var body: some View {
        let query = CommentQuery(search)
        VStack(spacing: 0) {
            header
            if !query.colors.isEmpty || !query.unknownColors.isEmpty {
                QueryChips(query: query)
                    .padding(.horizontal, 12)
                    .padding(.bottom, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if let scene = book.location.scene {
                CommentList(
                    book: book, formatting: formatting, editors: editors, scene: scene.id,
                    cards: CommentCards(scene), query: query)
            } else {
                Spacer()
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            TextField(CommentWording.searchPlaceholder, text: $search)
                .textFieldStyle(.roundedBorder)
                .help(CommentWording.searchHelp)
                .overlay(alignment: .trailing) {
                    if !search.isEmpty {
                        Button {
                            search = ""
                        } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .padding(.trailing, 5)
                        .help(CommentWording.clearSearch)
                        .accessibilityLabel(CommentWording.clearSearch)
                    }
                }
            if book.isEditable {
                Button {
                    formatting.commentablePage?.newCommentInItsCard()
                } label: {
                    Image(systemName: "plus").frame(width: 14, height: 14)
                }
                .disabled(formatting.commentablePage == nil)
                .help(CommentWording.newCommentHelp)
                .accessibilityLabel(CommentWording.newComment)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }
}

/// "Showing" and a chip per color the search filters by, then any unknown `#name` with the
/// valid ones.
private struct QueryChips: View {
    let query: CommentQuery

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if !query.colors.isEmpty {
                HStack(spacing: 6) {
                    Text(CommentWording.showing).foregroundStyle(.secondary)
                    ForEach(query.colors, id: \.self) { color in
                        HStack(spacing: 4) {
                            Circle().fill(Color(nsColor: color.nsColor)).frame(width: 8, height: 8)
                            Text(color.rawValue)
                        }
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.primary.opacity(0.07)))
                    }
                }
            }
            if !query.unknownColors.isEmpty {
                Text(CommentWording.unknownColors(query.unknownColors))
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .font(.system(size: 11))
    }
}

/// The cards the query matches, or what stands in for them; the selected card is scrolled into
/// view whenever the selection changes.
private struct CommentList: View {
    let book: AppOpenBook
    let formatting: EditorFormatting
    let editors: SceneEditors
    let scene: SceneID
    let cards: CommentCards
    let query: CommentQuery

    var body: some View {
        let shown = cards.filtered(by: query)
        let selected = editors.comments.comment(in: scene)
        if cards.isEmpty {
            placeholder(CommentWording.noComments)
        } else if shown.isEmpty {
            placeholder(CommentWording.noMatches)
        } else {
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(shown.anchored) { card($0, selected: selected) }
                        if !shown.detached.isEmpty {
                            DetachedHeader()
                            ForEach(shown.detached) { card($0, selected: selected) }
                        }
                    }
                    .padding(.horizontal, 12)
                    .padding(.top, 2)
                    .padding(.bottom, 12)
                }
                .onChange(of: selected, initial: true) {
                    guard let selected else { return }
                    withAnimation { proxy.scrollTo(selected) }
                }
            }
        }
    }

    private func card(_ card: CommentCards.Card, selected: CommentID?) -> some View {
        CommentCard(
            book: book, formatting: formatting, editors: editors, scene: scene, card: card,
            detached: cards.detached.contains { $0.id == card.id }, isSelected: card.id == selected
        )
        .id(card.id)
    }

    private func placeholder(_ text: String) -> some View {
        VStack {
            Text(text)
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 12)
                .padding(.top, 4)
                .frame(maxWidth: .infinity, alignment: .leading)
            Spacer()
        }
    }
}

/// Above the comments whose text was deleted (PLAN §8.1).
private struct DetachedHeader: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(CommentWording.detached)
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
            if CommentPanelCandidates.detachedHeader == .withHint {
                Text(CommentWording.detachedHelp)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.top, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .top) { Divider() }
    }
}

/// One comment: its color's bar, its text (edited in place), the quote of the text it covers, and
/// its ⋯ menu, shown on hover and while the card is selected.
private struct CommentCard: View {
    let book: AppOpenBook
    let formatting: EditorFormatting
    let editors: SceneEditors
    let scene: SceneID
    let card: CommentCards.Card
    let detached: Bool
    let isSelected: Bool
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    private var menuOpen: Bool {
        editors.comments.isMenuOpen(of: card.id, in: scene)
    }

    private var menuBinding: Binding<Bool> {
        Binding(
            get: { editors.comments.isMenuOpen(of: card.id, in: scene) },
            set: { open in
                if open {
                    editors.comments.openMenu(of: card.id, in: scene)
                } else if menuOpen {
                    editors.comments.closeMenu()
                }
            })
    }

    private var color: Color {
        Color(nsColor: card.comment.color.nsColor)
    }

    var body: some View {
        let editable = book.isEditable && isEnabled
        HStack(spacing: 0) {
            Rectangle().fill(color).frame(width: WindowMetrics.Comments.barWidth)
            VStack(alignment: .leading, spacing: 4) {
                CommentTextEditor(
                    book: book, editors: editors, scene: scene, comment: card.comment.id,
                    text: card.comment.text
                )
                .overlay(alignment: .topLeading) {
                    if card.comment.text.isEmpty {
                        Text(CommentWording.typeAComment)
                            .font(.system(size: WindowMetrics.Comments.textSize))
                            .foregroundStyle(.tertiary)
                            .allowsHitTesting(false)
                    }
                }
                if !card.quote.isEmpty {
                    Text(CommentWording.quote(card.quote))
                        .font(.system(size: 11).italic())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .padding(.vertical, 8)
            .padding(.leading, 10)
            .padding(.trailing, 28)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(selectedFill)
        .clipShape(shape)
        .overlay(shape.strokeBorder(isSelected ? Color.accentColor : WindowMetrics.Comments.line))
        .overlay {
            if isSelected { shape.inset(by: -2).strokeBorder(Color.accentColor.opacity(0.25), lineWidth: 2) }
        }
        .overlay(alignment: .topTrailing) {
            if editable, hovering || isSelected || menuOpen {
                Button {
                    menuBinding.wrappedValue.toggle()
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 22, height: 18)
                        .contentShape(Rectangle())
                        .background(
                            RoundedRectangle(cornerRadius: 4).fill(
                                menuOpen ? Color.primary.opacity(0.08) : .clear))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.secondary)
                .padding(4)
                .help(CommentWording.optionsHelp)
                .accessibilityLabel(CommentWording.options)
                .popover(isPresented: anchored(.button), arrowEdge: .bottom) { menu }
            }
        }
        .popover(isPresented: anchored(.card), arrowEdge: .bottom) { menu }
        .contentShape(shape)
        .onTapGesture { editors.comments.open(card.id, in: scene) }
        .onHover { hovering = $0 }
    }

    private var menu: some View {
        CommentMenu(formatting: formatting, editors: editors, comment: card.comment, detached: detached) {
            editors.comments.closeMenu()
        }
    }

    /// The menu's binding where it hangs from `anchor`; never open elsewhere.
    private func anchored(_ anchor: CommentPanelCandidates.MenuAnchor) -> Binding<Bool> {
        CommentPanelCandidates.menuAnchor == anchor ? menuBinding : .constant(false)
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: WindowMetrics.Comments.cornerRadius)
    }

    private var selectedFill: Color {
        isSelected && CommentPanelCandidates.selectedCard == .tinted
            ? Color.accentColor.opacity(0.06) : WindowMetrics.Comments.cardFill
    }
}

/// The ⋯ menu (PLAN §8.1): the seven colors, the comment's own ringed, then Dismiss, which ⌫
/// also does while the menu is open; a detached comment can also be re-anchored to the page's
/// selection.
private struct CommentMenu: View {
    let formatting: EditorFormatting
    let editors: SceneEditors
    let comment: Comment
    let detached: Bool
    let close: () -> Void

    var body: some View {
        let page = editors.page.editor
        VStack(alignment: .leading, spacing: 4) {
            Text(CommentWording.colorLabel)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 6)
            HStack(spacing: 0) {
                ForEach(PaletteColor.allCases, id: \.self) { color in
                    let name = WindowWording.paletteName(color)
                    Button {
                        page.recolor(comment.id, to: color)
                        close()
                    } label: {
                        Swatch(ink: .text(color), ringed: color == comment.color)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(name)
                    .accessibilityLabel(name)
                }
            }
            .padding(.horizontal, 2)
            Divider().padding(.vertical, 2)
            if detached {
                MenuRow(title: CommentWording.reanchor, key: nil) {
                    formatting.commentablePage?.reanchor(comment.id)
                    close()
                }
                .disabled(formatting.commentablePage == nil)
            }
            MenuRow(title: CommentWording.dismiss, key: "\u{232B}", action: dismiss)
        }
        .padding(6)
        .frame(width: WindowMetrics.Comments.menuWidth)
        .background(DeleteKey(action: dismiss))
    }
}

extension CommentMenu {
    private func dismiss() {
        editors.page.editor.dismiss(comment.id)
        close()
    }
}

/// Answers ⌫ and ⌦ with no modifiers in its window, the ⋯ menu's popover, as the window
/// offers key equivalents to every view in it.
private struct DeleteKey: NSViewRepresentable {
    let action: () -> Void

    func makeNSView(context: Context) -> KeyView {
        KeyView()
    }

    func updateNSView(_ view: KeyView, context: Context) {
        view.action = action
    }

    final class KeyView: NSView {
        var action: (() -> Void)?

        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            let modifiers = event.modifierFlags.intersection([.shift, .command, .option, .control])
            guard event.type == .keyDown, modifiers.isEmpty, Self.deleteKeys.contains(event.keyCode),
                let action
            else { return super.performKeyEquivalent(with: event) }
            action()
            return true
        }

        /// Delete and Forward Delete, by their key codes, which no keyboard layout moves.
        private static let deleteKeys: Set<UInt16> = [51, 117]
    }
}

/// A row of the ⋯ menu, highlighted under the pointer as a menu's items are.
private struct MenuRow: View {
    let title: String
    let key: String?
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            HStack {
                Text(title)
                Spacer()
                if let key { Text(key).foregroundStyle(.secondary) }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 4).fill(
                    hovering && isEnabled ? Color.primary.opacity(0.08) : .clear))
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }
}

/// A card's text: an `AdmittingTextView` (no input method, the character policy applied, no
/// drag and drop: ADRs 0028 and 0036), sized to its text. Typing keeps each change in the
/// model at once, with no undo step (`OpenBook.draftText`), so autosave has it; the whole edit
/// becomes one step on the page's undo when the card loses the focus (PLAN §8.1). Taking the
/// focus selects the card, and its text on the page.
private struct CommentTextEditor: NSViewRepresentable {
    let book: AppOpenBook
    let editors: SceneEditors
    let scene: SceneID
    let comment: CommentID
    let text: String

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> CommentTextView {
        let view = CommentTextView(admitting: CharacterPolicy.admittedInput)
        view.isRichText = false
        view.allowsUndo = true
        view.drawsBackground = false
        view.font = .systemFont(ofSize: WindowMetrics.Comments.textSize)
        view.textContainerInset = .zero
        view.textContainer?.lineFragmentPadding = 0
        view.isContinuousSpellCheckingEnabled = true
        view.setAccessibilityLabel(CommentWording.typeAComment)
        view.string = text
        let coordinator = context.coordinator
        view.onChange = { [weak coordinator] in coordinator?.typed($0) }
        view.onFocus = { [weak coordinator] in coordinator?.focused() }
        view.onResign = { [weak coordinator] in coordinator?.commit() }
        coordinator.view = view
        let center = NotificationCenter.default
        center.addObserver(
            coordinator, selector: #selector(Coordinator.sceneWillSwitch), name: .openBookWillSwitchScene,
            object: book)
        for name in [Notification.Name.NSUndoManagerDidUndoChange, .NSUndoManagerDidRedoChange] {
            center.addObserver(
                coordinator, selector: #selector(Coordinator.historyChanged), name: name, object: nil)
        }
        return view
    }

    func updateNSView(_ view: CommentTextView, context: Context) {
        let coordinator = context.coordinator
        coordinator.target = (book, editors, scene, comment)
        view.comment = comment
        view.history = coordinator.history
        let editable = book.isEditable && context.environment.isEnabled
        if view.isEditable != editable { view.isEditable = editable }
        if coordinator.original == nil, view.string != text { view.string = text }
        if let opening = editors.comments.opening, opening.comment == comment, opening.scene == scene {
            DispatchQueue.main.async { [weak view, editors, scene, comment] in
                guard let view, editors.comments.takeOpening(comment, in: scene) else { return }
                view.takeFocusAtEnd()
            }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: CommentTextView, context: Context) -> CGSize?
    {
        let width = proposal.width ?? WindowMetrics.panelWidth
        return CGSize(width: width, height: view.height(fitting: width))
    }

    static func dismantleNSView(_ view: CommentTextView, coordinator: Coordinator) {
        coordinator.commit()
        view.onChange = nil
        view.onFocus = nil
        view.onResign = nil
    }

    final class Coordinator: NSObject {
        var target: (book: AppOpenBook, editors: SceneEditors, scene: SceneID, comment: CommentID)?
        weak var view: CommentTextView?
        /// The card's own typing history while it has the focus; its edit then goes onto the
        /// page's undo as one step.
        let history = UndoManager()
        /// The comment's text before this edit's first change; `nil` while nothing's typed.
        private(set) var original: String?

        func typed(_ text: String) {
            guard let target,
                let comment = target.book.book.scene(target.scene)?.comments.first(where: {
                    $0.id == target.comment
                })
            else { return }
            if original == nil { original = comment.text }
            target.book.draftText(text, ofComment: target.comment, in: target.scene)
        }

        func focused() {
            guard let target else { return }
            target.editors.comments.select(target.comment, in: target.scene)
            target.editors.page.editor.selectText(ofComment: target.comment)
        }

        /// The edit, as one step on the page's undo.
        func commit() {
            history.removeAllActions()
            guard let original, let target, let view else { return }
            self.original = nil
            target.editors.page.editor.setText(view.string, ofComment: target.comment, since: original)
        }

        /// An undo or redo of the comment's text can bring back the very text SwiftUI last handed
        /// the view, which then sees no change to show, so the text is taken from the model here.
        @objc func historyChanged(_ notification: Notification) {
            guard original == nil, let target, let view,
                let text = target.book.book.scene(target.scene)?.comments.first(where: {
                    $0.id == target.comment
                })?
                .text, view.string != text
            else { return }
            view.string = text
        }

        /// Before another scene opens: the edit stays in this one.
        @objc func sceneWillSwitch(_ notification: Notification) {
            guard let view, view.window?.firstResponder === view else { return }
            view.window?.makeFirstResponder(nil)
        }
    }
}

/// A card's text view, which says when it takes and leaves the focus. Tab moves the focus on;
/// Esc hands it back to the page.
final class CommentTextView: AdmittingTextView {
    var onFocus: (() -> Void)?
    var onResign: (() -> Void)?
    /// The comment whose text this is.
    var comment: CommentID?

    private var focusOnArrival = false

    /// Takes the keyboard focus with the caret at the end, now or, if SwiftUI hasn't put the
    /// view in a window yet, as soon as it does.
    func takeFocusAtEnd() {
        guard let window else {
            focusOnArrival = true
            return
        }
        guard window.makeFirstResponder(self) else { return }
        setSelectedRange(NSRange(location: (string as NSString).length, length: 0))
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        guard focusOnArrival, window != nil else { return }
        focusOnArrival = false
        takeFocusAtEnd()
    }

    override func becomeFirstResponder() -> Bool {
        let accepted = super.becomeFirstResponder()
        if accepted { onFocus?() }
        return accepted
    }

    override func resignFirstResponder() -> Bool {
        let resigned = super.resignFirstResponder()
        if resigned { onResign?() }
        return resigned
    }

    override func insertTab(_ sender: Any?) {
        window?.selectNextKeyView(sender)
    }

    override func insertBacktab(_ sender: Any?) {
        window?.selectPreviousKeyView(sender)
    }

    override func cancelOperation(_ sender: Any?) {
        window?.makeFirstResponder(nil)
    }

    /// How tall the text is, laid out `width` wide; never less than a line.
    func height(fitting width: CGFloat) -> CGFloat {
        if frame.width != width { setFrameSize(NSSize(width: width, height: frame.height)) }
        let line = (font ?? .systemFont(ofSize: NSFont.systemFontSize)).boundingRectForFont.height
        guard let layout = textLayoutManager else { return line }
        layout.ensureLayout(for: layout.documentRange)
        return max(ceil(layout.usageBoundsForTextContainer.height), ceil(line))
    }
}

extension WindowMetrics {
    /// The comments panel, from mockups 02 to 04.
    enum Comments {
        static let barWidth: CGFloat = 4
        static let cornerRadius: CGFloat = 6
        static let textSize: CGFloat = 13
        static let menuWidth: CGFloat = 196
        static let line = Color(red: 0xD9 / 255, green: 0xD7 / 255, blue: 0xD1 / 255)
        static let cardFill = Color.white
    }
}

/// The looks the owner is choosing between (#25), until they pick; then the pick stays and
/// this goes.
enum CommentPanelCandidates {
    enum DetachedHeader { case label, withHint }
    enum SelectedCard { case ring, tinted }
    enum MenuAnchor { case card, button }

    static var detachedHeader = DetachedHeader.withHint
    static var selectedCard = SelectedCard.ring
    static var menuAnchor = MenuAnchor.card
}
