import AppKit
import SceneItCore
import SwiftUI

/// The File Cabinet sheet's state while it's open: its filters, the selected card, the card whose
/// + tag field is open, and the last click. They go when the sheet closes. The ticker keeps the
/// cards' ages current.
@MainActor
@Observable
final class FileCabinetModel {
    var filter = CabinetFilter()
    /// The card Return opens.
    var selected: FiledCopyNumber?
    var tagging: FiledCopyNumber?
    var clicks = CardClicks<FiledCopyNumber>()
    @ObservationIgnored let ticker: MinuteTicker
    /// The sheet's own focus, which takes the keys when no field has them.
    @ObservationIgnored let keyFocus = UndoFocusAnchor()

    init(ticker: MinuteTicker = MinuteTicker(clock: ContinuousClock())) {
        self.ticker = ticker
    }

    var today: CalendarDay {
        CalendarDay(ticker.now, in: .current)
    }

    /// The sheet's own focus gained or lost the keys. Losing them drops the selection, so Return
    /// never opens a card the writer has stopped looking at.
    func sheetKeys(_ change: FocusChange) {
        if change == .lost { selected = nil }
    }

    /// The cards shown changed, so they may have moved under the pointer.
    func cardsMoved() {
        clicks.forget()
    }

    func close() {
        filter = CabinetFilter()
        selected = nil
        tagging = nil
        clicks.forget()
    }
}

/// What the File Cabinet's controls do. A card's tags change in the index through the store, which
/// never writes the filed copy (PLAN §5.5); `open` opens a copy read-only (§7.5).
struct FileCabinetActions {
    let book: AppOpenBook
    let store: AppBookStore
    let model: FileCabinetModel
    let open: (FiledCopyNumber) -> Void

    /// A click on a card (`CardClicks`, ADR 0046): a double click opens the copy, and a single
    /// click selects it.
    func click(_ click: CardClick, on copy: FiledCopyNumber) {
        switch model.clicks.take(click, on: copy) {
        case .open(let copy): open(copy)
        case .select(let copy): select(copy)
        }
    }

    /// The sheet takes the keys, and Return opens `copy`.
    func select(_ copy: FiledCopyNumber) {
        model.keyFocus.takeFocus()
        model.selected = copy
    }

    /// Return or Enter opens the selected copy.
    func handle(_ key: CardKey) -> KeyOutcome {
        guard key == .open, let selected = model.selected else { return .passedOn }
        open(selected)
        return .handled
    }

    /// A card's + tag chip: opens the field on that card, closing any other.
    func startTagging(_ copy: FiledCopyNumber) {
        guard book.accepts(.archive) else { return }
        model.selected = nil
        model.tagging = copy
    }

    func stopTagging(_ copy: FiledCopyNumber) {
        if model.tagging == copy { model.tagging = nil }
    }

    func returnKeys(from view: NSView?) {
        model.selected = nil
        model.keyFocus.takeFocus(after: view)
    }

    /// The + tag field's Return: the tag as `SceneTag.typed` reads it.
    func addTag(_ typed: String, to copy: FiledCopyNumber) {
        guard let tag = SceneTag.typed(typed) else { return }
        edit(copy, .addTag(tag))
    }

    func removeTag(_ tag: String, from copy: FiledCopyNumber) {
        edit(copy, .removeTag(tag))
    }

    private func edit(_ copy: FiledCopyNumber, _ change: RecordChange) {
        Task { [book, store] in await store.editRecord(of: book, copy, change) }
    }
}

/// The File Cabinet sheet (PLAN §7.4, mockup 12): the header; the filters (search, a date range
/// and the tags); then a card per filed copy, newest first. A click selects a card and a double
/// click opens the copy read-only (ADR 0046). Esc or × closes it.
struct FileCabinetSheet: View {
    let book: AppOpenBook
    @Bindable var model: FileCabinetModel
    let actions: FileCabinetActions
    @Binding var mode: WindowMode
    @Environment(\.windowKeys) private var keys

    var body: some View {
        let cards = FileCabinet.cards(of: book.archive, model.filter)
        VStack(spacing: 0) {
            CabinetHeader(copies: book.archive.copies.count, mode: $mode)
            Divider()
            if !book.archive.copies.isEmpty {
                CabinetFilters(index: book.archive, filter: $model.filter)
                Divider()
            }
            ScrollView(.vertical) {
                CabinetGrid(book: book, cards: cards, model: model, actions: actions)
            }
            .background(WindowMetrics.Scenes.background)
        }
        .background(.background)
        .background(
            UndoFocusHolder(
                role: .sheet, anchor: model.keyFocus,
                keyHandler: { event in CardKey(event).map(actions.handle) ?? .passedOn },
                focusChanged: { model.sheetKeys($0) })
        )
        // A change to a card's tags or note, as well as to the cards shown, forgets the last click
        // (ADR 0043 §5).
        .onChange(of: cards) { model.cardsMoved() }
        .onChange(of: FileCabinet.tags(of: book.archive), initial: true) { _, tags in
            model.filter.keepTags(in: tags)
        }
        .background(EscapeKey(keys: keys, inner: closeTagField))
        .task { await model.ticker.run() }
    }

    /// Esc closes a card's + tag field first; the next Esc closes the sheet.
    private func closeTagField() -> KeyOutcome {
        guard model.tagging != nil else { return .passedOn }
        model.tagging = nil
        actions.returnKeys(from: model.keyFocus.view)
        return .handled
    }
}

/// The mockup's header: the title, how many copies there are and what a double click does, and ×.
private struct CabinetHeader: View {
    let copies: Int
    @Binding var mode: WindowMode

    var body: some View {
        HStack(spacing: WindowMetrics.Scenes.headerSpacing) {
            Text(FileCabinetWording.title)
                .font(.title3.weight(.semibold))
            Text(FileCabinetWording.subtitle(copies: copies))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button {
                mode = mode.closingSheet
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help(WindowWording.closeSheet)
        }
        .padding(.horizontal, 16)
        .frame(height: WindowMetrics.barHeight)
    }
}

/// The search field, the date range as two date pickers, and a chip per tag.
private struct CabinetFilters: View {
    let index: ArchiveIndex
    @Binding var filter: CabinetFilter

    var body: some View {
        HStack(alignment: .top, spacing: WindowMetrics.Cabinet.filterSpacing) {
            TextField(FileCabinetWording.searchPlaceholder, text: $filter.words)
                .textFieldStyle(.roundedBorder)
                .frame(width: WindowMetrics.Scenes.filterWidth)
            if let span = FileCabinet.span(of: index) {
                FiledDatesField(span: span, dates: $filter.dates)
            }
            ChipFlow(spacing: ChipSpacing(points: WindowMetrics.Tags.chipGap)) {
                ForEach(FileCabinet.tags(of: index), id: \.self) { tag in
                    FilterChip(tag: tag, chosen: filter.isChosen(tag) ? .chosen : .notChosen) {
                        filter.toggle(tag)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

/// From and to, as native date fields (the owner's pick, #33), and ⓧ, which clears both. An end
/// left as it is shows the oldest or newest copy's day and filters nothing. The File Cabinet's
/// filters and the Search sheet's File Cabinet scope both use it.
struct FiledDatesField: View {
    let span: ClosedRange<CalendarDay>
    @Binding var dates: FiledDates
    var label = FileCabinetWording.from

    var body: some View {
        let from = dates.from ?? span.lowerBound
        let to = dates.to ?? span.upperBound
        HStack(spacing: 6) {
            Text(label).foregroundStyle(.secondary)
            DatePicker(
                FileCabinetWording.from, selection: date(\.from, shown: from),
                in: ...to.noon(in: .current), displayedComponents: .date
            )
            Text(FileCabinetWording.to).foregroundStyle(.secondary)
            DatePicker(
                FileCabinetWording.to, selection: date(\.to, shown: to), in: from.noon(in: .current)...,
                displayedComponents: .date)
            if !dates.isOpen {
                Button {
                    dates = FiledDates()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .help(FileCabinetWording.clearDates)
                .accessibilityLabel(FileCabinetWording.clearDates)
            }
        }
        .labelsHidden()
        .datePickerStyle(.field)
        .font(.system(size: 13))
        .fixedSize()
    }

    private func date(_ end: WritableKeyPath<FiledDates, CalendarDay?>, shown: CalendarDay) -> Binding<
        Date
    > {
        Binding(
            get: { shown.noon(in: .current) },
            set: { dates[keyPath: end] = CalendarDay($0, in: .current) })
    }
}

/// A tag in the filters: outlined, and tinted like a tag chip while it's chosen.
private struct FilterChip: View {
    let tag: String
    let chosen: Chosen
    let toggle: () -> Void

    enum Chosen {
        case chosen, notChosen
    }

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: WindowMetrics.Cabinet.filterChipCornerRadius)
        Button(action: toggle) {
            Text(tag)
                .font(WindowMetrics.Tags.chipFont)
                .lineLimit(1)
                .padding(.horizontal, WindowMetrics.Cabinet.filterChipPadding)
                .frame(height: WindowMetrics.Tags.chipHeight)
                .background(
                    chosen == .chosen ? Color.accentColor.opacity(WindowMetrics.Tags.chipOpacity) : .white,
                    in: shape
                )
                .overlay(
                    shape.strokeBorder(chosen == .chosen ? Color.accentColor : WindowMetrics.Scenes.line)
                )
                .contentShape(shape)
        }
        .buttonStyle(.plain)
        .help(chosen == .chosen ? FileCabinetWording.tagChosenHelp : FileCabinetWording.tagHelp)
        .accessibilityAddTraits(chosen == .chosen ? .isSelected : [])
    }
}

/// The cards, or what stands in for them.
private struct CabinetGrid: View {
    let book: AppOpenBook
    let cards: [FiledCopy]
    let model: FileCabinetModel
    let actions: FileCabinetActions

    var body: some View {
        VStack(alignment: .leading, spacing: WindowMetrics.Scenes.gap) {
            if book.archive.copies.isEmpty {
                GridMessage(text: FileCabinetWording.noCopies, hint: FileCabinetWording.noCopiesHint)
            } else if cards.isEmpty {
                GridMessage(text: FileCabinetWording.noMatches, hint: FileCabinetWording.noMatchesHint)
            }
            LazyVGrid(columns: columns, alignment: .leading, spacing: WindowMetrics.Scenes.gap) {
                ForEach(cards, id: \.number) { copy in
                    FiledCopyCard(
                        copy: copy, age: FiledAge(of: copy.filed, today: model.today),
                        selection: copy.number == model.selected ? .focused : .unfocused,
                        editability: Editability(book, for: .archive), actions: actions)
                }
            }
        }
        .padding(WindowMetrics.Scenes.gridPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var columns: [GridItem] {
        [
            GridItem(
                .adaptive(minimum: WindowMetrics.Scenes.cardWidth), spacing: WindowMetrics.Scenes.gap,
                alignment: .top)
        ]
    }
}

/// A filed copy's card (mockup 12): the date; how long ago, and its scenes, words and comments;
/// its tags, with × and + tag while the index can be changed; its note. White and outlined like a
/// scene card, with the focus ring while it's selected.
private struct FiledCopyCard: View {
    let copy: FiledCopy
    let age: FiledAge
    let selection: SceneCardContent.KeyFocus
    let editability: Editability
    let actions: FileCabinetActions
    @State private var hovering = Hovering.away

    var body: some View {
        let shape = RoundedRectangle(cornerRadius: WindowMetrics.Scenes.cornerRadius)
        VStack(alignment: .leading, spacing: WindowMetrics.Cabinet.cardSpacing) {
            Text(FileCabinetWording.date(copy.filed))
                .font(.system(size: WindowMetrics.Cabinet.dateSize, weight: .semibold))
            Text(FileCabinetWording.details(age, copy.counts))
                .font(.system(size: WindowMetrics.Scenes.metaSize))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            tags
            if !copy.note.isEmpty {
                Text(copy.note)
                    .font(.system(size: WindowMetrics.Cabinet.noteSize))
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(WindowMetrics.Scenes.padding(.cards))
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.white, in: shape)
        .overlay(
            shape.strokeBorder(
                hovering == .hovering ? WindowMetrics.Scenes.hoverLine : WindowMetrics.Scenes.line)
        )
        .overlay {
            if selection == .focused {
                shape.inset(by: -WindowMetrics.Scenes.focusRing)
                    .stroke(
                        Color(nsColor: .keyboardFocusIndicatorColor),
                        lineWidth: WindowMetrics.Scenes.focusRing)
            }
        }
        .contentShape(shape)
        .cardClicks { actions.click($0, on: copy.number) }
        .onHover { hovering = $0 ? .hovering : .away }
        .help(FileCabinetWording.openHelp)
        .accessibilityElement(children: .contain)
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { actions.open(copy.number) }
    }

    @ViewBuilder private var tags: some View {
        let entry: CardNewTag.Entry = actions.model.tagging == copy.number ? .open : .closed
        let offersTag = editability == .editable
        if !copy.tags.isEmpty || offersTag {
            ChipFlow(spacing: ChipSpacing(points: WindowMetrics.Tags.chipGap)) {
                ForEach(Array(copy.tags.enumerated()), id: \.offset) { _, tag in
                    TagChip(label: tag, remove: removal(of: tag))
                }
                if offersTag {
                    CardNewTag(entry: entry, start: { actions.startTagging(copy.number) }) {
                        NewTagField(
                            book: actions.book, kind: .archive, add: { actions.addTag($0, to: copy.number) },
                            leave: { actions.returnKeys(from: $0) },
                            opening: entry == .open ? .focused : .unfocused,
                            ended: { actions.stopTagging(copy.number) })
                    }
                }
            }
        }
    }

    private func removal(of tag: String) -> TagChip.Removal? {
        guard editability == .editable else { return nil }
        return TagChip.Removal(label: TagWording.removeHelp(tag)) {
            actions.removeTag(tag, from: copy.number)
        }
    }
}

extension WindowMetrics {
    /// The File Cabinet sheet, from mockup 12, in the Scenes sheet's look where the two share a
    /// part: the header, the grid, the cards' frame and the tag chips.
    enum Cabinet {
        static let filterSpacing: CGFloat = 12
        static let filterChipPadding: CGFloat = 10
        /// The mockup's pill.
        static let filterChipCornerRadius: CGFloat = WindowMetrics.Tags.chipHeight / 2
        static let cardSpacing: CGFloat = 8
        static let dateSize: CGFloat = 15
        static let noteSize: CGFloat = 13
    }
}
