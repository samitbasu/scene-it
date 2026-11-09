import SceneItCore
import SwiftUI

/// The Scenes sheet (PLAN §7.2, §7.3, mockups 07–09): the header, then the story as cards or as a
/// light table, with a dashed tile that adds a scene at the end, then the Boneyard. Clicking a
/// card or tile opens its scene; dragging moves, cuts or restores it. Esc or × closes it.
/// Read-only, it changes nothing.
struct ScenesSheet: View {
    let book: AppOpenBook
    let preferences: AppPreferences
    @Bindable var model: ScenesSheetModel
    let actions: ScenesActions
    @Binding var mode: WindowMode
    @Environment(\.windowKeys) private var keys
    @Environment(\.self) private var environment

    var body: some View {
        let editability = Editability(book, for: .manuscript, in: environment)
        VStack(spacing: 0) {
            ScenesHeader(book: book, preferences: preferences, model: model, actions: actions, mode: $mode)
            Divider()
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    ScenesGrid(
                        book: book, view: preferences.scenesView, model: model, actions: actions,
                        editability: editability)
                }
                .background(WindowMetrics.Scenes.background)
                .onChange(of: model.titling) {
                    guard let scene = model.titling else { return }
                    proxy.scrollTo(scene)
                }
                .onChange(of: model.focused) {
                    guard let scene = model.focused else { return }
                    proxy.scrollTo(scene)
                }
            }
            BoneyardTray(book: book, model: model, actions: actions, editability: editability)
        }
        .background(.background)
        .background(
            UndoFocusHolder(
                role: .sheet, anchor: model.keyFocus,
                keyHandler: { event in CardKey(event).map(actions.handle) ?? .passedOn },
                focusChanged: { model.sheetKeys($0) })
        )
        .onChange(of: book.book.scenes.map(\.id)) { model.keepToTheStory(of: book.book) }
        .background(EscapeKey(keys: keys, inner: { model.closeCardField() }))
        .task { await model.ticker.run() }
    }
}

/// The mockup's header: title and totals, then + New scene, Cards / Light table, the filter
/// and ×.
private struct ScenesHeader: View {
    let book: AppOpenBook
    let preferences: AppPreferences
    @Bindable var model: ScenesSheetModel
    let actions: ScenesActions
    @Binding var mode: WindowMode
    @Environment(\.self) private var environment

    var body: some View {
        HStack(spacing: WindowMetrics.Scenes.headerSpacing) {
            Text(ScenesWording.title)
                .font(.title3.weight(.semibold))
            Text(ScenesWording.totals(scenes: book.book.scenes.count, words: book.manuscriptWordCount))
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
            Button(ScenesWording.newScene) { actions.add(.afterOpenScene) }
                .disabled(Editability(book, for: .manuscript, in: environment) == .readOnly)
                .help(ScenesWording.newSceneHelp)
            Picker(ScenesWording.viewLabel, selection: view) {
                ForEach(ScenesView.allCases, id: \.self) { view in
                    Text(ScenesWording.view(view)).tag(view)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
            TextField(ScenesWording.filterPlaceholder, text: $model.filter)
                .textFieldStyle(.roundedBorder)
                .frame(width: WindowMetrics.Scenes.filterWidth)
            Button {
                mode = mode.closingSheet
            } label: {
                Image(systemName: "xmark")
            }
            .buttonStyle(.borderless)
            .help(WindowWording.closeSheet)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var view: Binding<ScenesView> {
        Binding(get: { preferences.scenesView }, set: { actions.show($0) })
    }
}

/// The story's scenes the filter shows, in story order, each numbered by its place in the whole
/// story; then the dashed tile, while scenes can be added. Or what stands in for them.
private struct ScenesGrid: View {
    let book: AppOpenBook
    let view: ScenesView
    let model: ScenesSheetModel
    let actions: ScenesActions
    let editability: Editability

    var body: some View {
        let shown = model.cards(of: book.book)
        let entries = GridEntry.entries(shown, drag: model.drop.drag, slot: model.drop.slot(in: book.book))
        VStack(alignment: .leading, spacing: WindowMetrics.Scenes.gap) {
            if book.book.scenes.isEmpty {
                message(
                    ScenesWording.noScenes, hint: editability == .editable ? ScenesWording.noScenesHint : nil)
            } else if shown.isEmpty {
                message(ScenesWording.noMatches(model.filter), hint: ScenesWording.noMatchesHint)
            }
            LazyVGrid(columns: columns, alignment: .leading, spacing: WindowMetrics.Scenes.gap) {
                ForEach(entries) { entry in
                    switch entry {
                    case .card(let card):
                        self.card(card.scene, number: card.number)
                            .sceneDropZone(.card(card.scene.id), actions: actions, editability: editability)
                            .id(card.scene.id)
                    case .slot(let drag):
                        DropSlot(drag: drag, view: view)
                            .sceneDropZone(.slot, actions: actions, editability: editability)
                    }
                }
                if editability == .editable {
                    NewSceneTile(view: view) { actions.add(.atEnd) }
                        .sceneDropZone(.end, actions: actions, editability: editability)
                }
            }
            .onGeometryChange(for: CGSize.self) {
                $0.size
            } action: {
                model.gridSize = $0
            }
        }
        .padding(WindowMetrics.Scenes.gridPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var columns: [GridItem] {
        [
            GridItem(
                .adaptive(minimum: WindowMetrics.Scenes.minimumCardWidth(view)),
                spacing: WindowMetrics.Scenes.gap,
                alignment: .top)
        ]
    }

    @ViewBuilder private func card(_ scene: BookScene, number: Int) -> some View {
        let content = SceneCardContent(
            scene: scene, number: number, isOpen: scene.id == book.openScene ? .open : .notOpen,
            titling: scene.id == model.titling && editability == .editable ? .typing : .done,
            focus: scene.id == model.focused ? .focused : .unfocused,
            dragging: model.drop.drag == .card(scene.id) ? .dragged : .still)
        switch view {
        case .cards:
            SceneCard(
                content: content, words: book.wordCounts[scene.id], ticker: model.ticker, actions: actions,
                editability: editability)
        case .lightTable:
            LightTableCard(content: content, actions: actions, editability: editability)
        }
    }

    @ViewBuilder private func message(_ text: String, hint: String?) -> some View {
        switch WindowMetrics.Scenes.look.messages {
        case .withHint:
            VStack(alignment: .leading, spacing: 4) {
                Text(text).font(.system(size: 13, weight: .medium))
                if let hint { Text(hint).font(.system(size: 12)).foregroundStyle(.secondary) }
            }
        case .plain:
            Text(text).font(.system(size: 13)).foregroundStyle(.secondary)
        }
    }
}

/// What the grid shows, in order: the cards, and the slot where a dragged scene will land.
private enum GridEntry: Identifiable {
    case card(ScenesSheetModel.Card)
    case slot(SceneDrag)

    enum ID: Hashable {
        case card(SceneID)
        case slot
    }

    var id: ID {
        switch self {
        case .card(let card): .card(card.scene.id)
        case .slot: .slot
        }
    }

    /// The cards, with the slot before the card the drag is over, or after the last.
    static func entries(_ cards: [ScenesSheetModel.Card], drag: SceneDrag?, slot: StorySlot?) -> [GridEntry] {
        var entries = cards.map(GridEntry.card)
        guard let drag, let slot else { return entries }
        let index: Int? =
            switch slot {
            case .end: entries.endIndex
            case .before(let scene): cards.firstIndex { $0.scene.id == scene }
            }
        if let index { entries.insert(.slot(drag), at: index) }
        return entries
    }
}

extension WindowMetrics {
    /// The Scenes sheet, from mockups 07–09.
    enum Scenes {
        static let headerSpacing: CGFloat = 12
        static let filterWidth: CGFloat = 240
        static let gridPadding: CGFloat = 16
        static let gap: CGFloat = 12
        /// The narrowest a card may be: five across in the default window, as in mockup 07.
        static let cardWidth: CGFloat = 240
        /// The narrowest a light-table tile may be: eight across, as in mockup 08.
        static let tileWidth: CGFloat = 150
        /// Inside a card; the light table's are tighter, so two tags fit on a line (mockup 08).
        static func padding(_ view: ScenesView) -> CGFloat {
            switch view {
            case .cards: 12
            case .lightTable: 8
            }
        }
        static let excerptLineSpacing: CGFloat = 3
        static let cornerRadius: CGFloat = 8
        static let lightTableHeight: CGFloat = 84
        static let newTileHeight: CGFloat = 46
        /// The slot is as tall as the row it's in, and at least this.
        static func slotHeight(_ view: ScenesView) -> CGFloat {
            switch view {
            case .cards: 120
            case .lightTable: lightTableHeight
            }
        }
        static let slotFillOpacity = 0.08
        static let focusRing: CGFloat = 3
        static let draggedOpacity = 0.4
        /// How often a drag outside every zone looks for the mouse button's release.
        static let releaseCheck = Interval(clamping: .milliseconds(100))

        /// How many columns the grid's adaptive layout makes across `size`, as `LazyVGrid` counts
        /// them.
        static func columns(fitting size: CGSize, _ view: ScenesView) -> Int {
            max(1, Int(((size.width + gap) / (minimumCardWidth(view) + gap)).rounded(.down)))
        }

        static func minimumCardWidth(_ view: ScenesView) -> CGFloat {
            switch view {
            case .cards: cardWidth
            case .lightTable: tileWidth
            }
        }
        static let excerptSize: CGFloat = 15
        static let titleSize: CGFloat = 14
        static let metaSize: CGFloat = 12
        static let openBorder: CGFloat = 2
        static let background = Search.background
        static let line = Search.line
        static let hoverLine = Color(red: 0xB8 / 255, green: 0xB6 / 255, blue: 0xAF / 255)
        static let openFill = Tags.onSceneFill

        /// The drag handle's dots, from mockup 07.
        enum Grip {
            static let dot: CGFloat = 3
            static let gap: CGFloat = 3
            static let color = Color(red: 0xB4 / 255, green: 0xB2 / 255, blue: 0xAC / 255)
        }
        /// The Boneyard tray, from mockup 07.
        enum Boneyard {
            static let spacing: CGFloat = 8
            static let verticalPadding: CGFloat = 10
            static let titleSize: CGFloat = 13
            static let tileWidth: CGFloat = 180
            static let tileHeight: CGFloat = 36
            static let tileGap: CGFloat = 8
            static let tileCornerRadius: CGFloat = 6
            static let tileTitleSize: CGFloat = 13
            static let tileWordsSize: CGFloat = 11
            static let fill = Color(red: 0xEC / 255, green: 0xEA / 255, blue: 0xE4 / 255)
            static let tileFill = Color(red: 0xF7 / 255, green: 0xF6 / 255, blue: 0xF3 / 255)
            static let tileLine = Color(red: 0xB4 / 255, green: 0xB2 / 255, blue: 0xAC / 255)
            static let litFill = Color(red: 0xFB / 255, green: 0xE4 / 255, blue: 0xE1 / 255)
            static let litLine = Color(red: 0xD9 / 255, green: 0x3B / 255, blue: 0x30 / 255)
        }
        /// The look while the owner hasn't picked (#28, #29): the recommended candidate.
        static var look = ScenesLook.recommended
    }
}

/// The Scenes sheet's look candidates (#28), until the owner picks.
struct ScenesLook {
    /// How a card offers + tag.
    enum TagEntry {
        /// A small dashed "+ tag" chip that opens the Tags tab's field on the card (mockup 07).
        case chipOpensField
        /// The Tags tab's field, always shown.
        case alwaysField
    }

    /// What the grid says with no scenes, or none the filter matches.
    enum Messages {
        /// A line and a hint below it.
        case withHint
        /// The line alone.
        case plain
    }

    /// How the slot where a dragged scene will land is drawn.
    enum Slot {
        /// Dashed and tinted in the accent color.
        case accent
        /// Dashed in gray, like the + New scene tile.
        case neutral
    }

    /// How the Boneyard lights while a card is over it.
    enum TrayLight {
        /// A pale red fill inside a red outline.
        case fillAndOutline
        /// A pale red fill and a dashed red outline inset from its edges.
        case fillAndDashedOutline
    }

    /// When a Boneyard tile shows its ↩.
    enum RestoreButton {
        case always
        case onHover
    }

    var tagEntry: TagEntry
    var messages: Messages
    var slot: Slot
    var trayLight: TrayLight
    var restoreButton: RestoreButton

    static let recommended = ScenesLook(
        tagEntry: .chipOpensField, messages: .withHint, slot: .accent, trayLight: .fillAndOutline,
        restoreButton: .always)
}
