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
    @Environment(\.windowKeys) private var keys

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
        .onAppear {
            keys?.setPanelFocus(for: .comments) { [book, editors] in
                Self.takeFocus(book: book, editors: editors)
            }
        }
    }

    /// Tab into the tab: the selected card's text, or else the search field. `true` only if one
    /// of them took the focus.
    private static func takeFocus(book: AppOpenBook, editors: SceneEditors) -> Bool {
        guard let window = editors.page.textView.window, let content = window.contentView else {
            return false
        }
        func shown(in view: NSView) -> [NSView] {
            view.isHidden ? [] : [view] + view.subviews.flatMap(shown)
        }
        let views = shown(in: content)
        if let scene = book.location.scene?.id, let card = editors.comments.comment(in: scene),
            let text = views.lazy.compactMap({ $0 as? CommentTextView }).first(where: { $0.comment == card })
        {
            text.takeFocusAtEnd()
            return window.firstResponder === text
        }
        let field = views.lazy.compactMap { $0 as? NSTextField }.first {
            $0.placeholderString == CommentWording.searchPlaceholder && $0.isEnabled
        }
        return field.map(window.makeFirstResponder) ?? false
    }

    private var header: some View {
        HStack(spacing: 8) {
            TextField(CommentWording.searchPlaceholder, text: $search)
                .textFieldStyle(.roundedBorder)
                // Shift-Tab arrives as backtab, U+0019.
                .onKeyPress(keys: [.tab, KeyEquivalent("\u{19}")]) { press in
                    guard let keys else { return .ignored }
                    let direction: TabDirection =
                        press.key == .tab && !press.modifiers.contains(.shift) ? .forward : .backward
                    return keys.tab(direction, from: .panel) ? .handled : .ignored
                }
                .onKeyPress(.escape) {
                    keys?.escapeAfterThisKey(from: .focusedView) == .handled ? .handled : .ignored
                }
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
            if book.accepts(.annotations) {
                Button {
                    Self.addComment(through: formatting)
                } label: {
                    Image(systemName: "plus").frame(width: 14, height: 14)
                }
                .disabled(formatting.commentablePage == nil)
                .help(CommentWording.newCommentHelp(KeyboardShortcut.newComment.spelled))
                .accessibilityLabel(CommentWording.newComment)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    /// The + button's action: New Comment on the page's selection, its card opened.
    static func addComment(through formatting: EditorFormatting) {
        formatting.commentablePage?.newCommentInItsCard()
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
            placeholder(
                book.accepts(.annotations) ? CommentWording.noComments : CommentWording.noCommentsReadOnly)
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
            isSelected: card.id == selected
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
            Text(CommentWording.detachedHelp)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
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
    let isSelected: Bool
    @State private var hovering = false
    @Environment(\.self) private var environment

    private var color: Color {
        Color(nsColor: card.comment.color.nsColor)
    }

    var body: some View {
        let editability = Editability(book, for: .annotations, in: environment)
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
            if editability == .editable, hovering || isSelected {
                CommentMenuButton(
                    book: book, formatting: formatting, editors: editors, scene: scene, comment: card.id
                )
                .frame(width: 22, height: 18)
                .padding(4)
            }
        }
        .contentShape(shape)
        .onTapGesture { editors.comments.open(card.id, in: scene) }
        .onHover { hovering = $0 }
    }

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: WindowMetrics.Comments.cornerRadius)
    }

    private var selectedFill: Color {
        isSelected ? Color.accentColor.opacity(0.06) : WindowMetrics.Comments.cardFill
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
    @Environment(\.windowKeys) private var keys

    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> CommentTextView {
        let view = CommentTextView(
            admitting: CharacterPolicy.admittedInput,
            editability: { [weak book = self.book] in Editability(book, for: .annotations) })
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
        view.onFinish = { [weak coordinator] in coordinator?.finish() }
        coordinator.view = view
        NotificationCenter.default.addObserver(
            coordinator, selector: #selector(Coordinator.sceneWillSwitch), name: .openBookWillSwitchScene,
            object: book)
        return view
    }

    func updateNSView(_ view: CommentTextView, context: Context) {
        let coordinator = context.coordinator
        coordinator.target = (book, editors, scene, comment)
        coordinator.heardUndo.hear(
            book.pageUndo(for: scene), by: coordinator, calling: #selector(Coordinator.historyChanged))
        view.comment = comment
        view.keys = keys
        view.history = coordinator.history
        let editable = Editability(book, for: .annotations, in: context.environment) == .editable
        // As the title field does: a book that stops taking edits ends the edit under way, and
        // the card shows the model's text.
        if !editable, view.window?.firstResponder === view { view.window?.makeFirstResponder(nil) }
        if view.isEditable != editable { view.isEditable = editable }
        if coordinator.original == nil, view.string != text { view.string = text }
        if editors.comments.isOpening(comment, in: scene) {
            DispatchQueue.main.async { [weak view, editors, scene, comment] in
                guard let view, editors.comments.takeOpening(comment, in: scene) else { return }
                view.takeFocusAtEnd()
            }
        }
    }

    func sizeThatFits(_ proposal: ProposedViewSize, nsView view: CommentTextView, context: Context) -> CGSize?
    {
        view.size(fitting: proposal)
    }

    static func dismantleNSView(_ view: CommentTextView, coordinator: Coordinator) {
        coordinator.commit()
        view.onChange = nil
        view.onFocus = nil
        view.onResign = nil
        view.onFinish = nil
    }

    final class Coordinator: NSObject {
        var target: (book: AppOpenBook, editors: SceneEditors, scene: SceneID, comment: CommentID)?
        weak var view: CommentTextView?
        /// The card's own typing history while it has the focus; its edit then goes onto the
        /// page's undo as one step.
        let history = UndoManager()
        /// The comment's text before this edit's first change; `nil` while nothing's typed.
        private(set) var original: String?
        /// The scene's page undo, which holds the comment's edits.
        let heardUndo = HeardUndo()

        /// The comment as the model has it.
        private var modelComment: Comment? {
            target.flatMap { $0.book.book.scene($0.scene)?.comment($0.comment) }
        }

        func typed(_ text: String) {
            guard let target, let comment = modelComment else { return }
            if original == nil { original = comment.text }
            target.book.draftText(text, ofComment: target.comment, in: target.scene)
        }

        func focused() {
            guard let target else { return }
            target.editors.comments.select(target.comment, in: target.scene)
            target.editors.page.editor.selectText(ofComment: target.comment)
        }

        /// The edit, as one step on the page's undo, in the scene it was typed in; typing on the
        /// page after it is a step of its own.
        func commit() {
            history.removeAllActions()
            guard let original, let target, let view else { return }
            self.original = nil
            target.editors.page.textView.breakUndoCoalescing()
            target.book.setText(view.string, ofComment: target.comment, in: target.scene, since: original)
        }

        /// Esc, or a menu action that needs the edit done first: the focus goes back to the page,
        /// so Undo there undoes the edit.
        func finish() {
            guard let target, let view, view.window?.firstResponder === view else { return }
            target.editors.page.textView.takeFocus()
            if view.window?.firstResponder === view { view.window?.makeFirstResponder(nil) }
        }

        /// An undo or redo of the comment's text can bring back the very text SwiftUI last handed
        /// the view, which then sees no change to show, so the text is taken from the model here.
        @objc func historyChanged(_ notification: Notification) {
            guard original == nil, let view, let text = modelComment?.text, view.string != text else {
                return
            }
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
    var onFinish: (() -> Void)?
    /// The comment whose text this is.
    var comment: CommentID?
    weak var keys: WindowKeys?

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
        guard let keys else { return window?.selectNextKeyView(sender) ?? () }
        keys.tab(.forward, from: .panel)
    }

    override func insertBacktab(_ sender: Any?) {
        guard let keys else { return window?.selectPreviousKeyView(sender) ?? () }
        keys.tab(.backward, from: .panel)
    }

    override func cancelOperation(_ sender: Any?) {
        if keys?.escape(from: .focusedView) != .handled { finishEditing() }
    }

    /// Ends the edit under way, the focus going back to the page.
    func finishEditing() {
        onFinish?()
    }

    /// The text laid out as wide as `proposal` offers (the panel's width if it offers none),
    /// and as tall as it then is; never less than a line.
    func size(fitting proposal: ProposedViewSize) -> CGSize {
        let width = proposal.width ?? WindowMetrics.panelWidth
        if frame.width != width { setFrameSize(NSSize(width: width, height: frame.height)) }
        let line = ceil((font ?? .systemFont(ofSize: NSFont.systemFontSize)).boundingRectForFont.height)
        guard let layout = textLayoutManager else { return CGSize(width: width, height: line) }
        layout.ensureLayout(for: layout.documentRange)
        return CGSize(width: width, height: max(ceil(layout.usageBoundsForTextContainer.height), line))
    }
}

extension WindowMetrics {
    /// The comments panel, from mockups 02 to 04.
    enum Comments {
        static let barWidth: CGFloat = 4
        static let cornerRadius: CGFloat = 6
        static let textSize: CGFloat = 13
        /// The line after a color's name in the ⋯ menu.
        static let menuSample = CGSize(width: 24, height: 5)
        static let line = Color(red: 0xD9 / 255, green: 0xD7 / 255, blue: 0xD1 / 255)
        static let cardFill = Color.white
    }
}
