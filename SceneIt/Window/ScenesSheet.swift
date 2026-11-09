import SceneItCore
import SwiftUI

/// The Scenes sheet (PLAN §7.2, mockups 07–09): the header, then the story as cards or as a light
/// table, with a dashed tile that adds a scene at the end. Clicking a card opens its scene. Esc or
/// × closes it. Read-only, it adds and tags nothing.
struct ScenesSheet: View {
    let book: AppOpenBook
    let preferences: AppPreferences
    @Bindable var model: ScenesSheetModel
    let actions: ScenesActions
    @Binding var mode: WindowMode
    @Environment(\.windowKeys) private var keys
    @Environment(\.self) private var environment

    var body: some View {
        let editability = Editability(book, in: environment)
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
            }
            // The Boneyard tray (#29) goes below the grid.
        }
        .background(.background)
        .background(UndoFocusHolder(role: .sheet))
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
                .disabled(Editability(book, in: environment) == .readOnly)
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
        VStack(alignment: .leading, spacing: WindowMetrics.Scenes.gap) {
            if book.book.scenes.isEmpty {
                message(
                    ScenesWording.noScenes, hint: editability == .editable ? ScenesWording.noScenesHint : nil)
            } else if shown.isEmpty {
                message(ScenesWording.noMatches(model.filter), hint: ScenesWording.noMatchesHint)
            }
            LazyVGrid(columns: columns, alignment: .leading, spacing: WindowMetrics.Scenes.gap) {
                ForEach(shown, id: \.scene.id) { entry in
                    card(entry.scene, number: entry.number)
                        .id(entry.scene.id)
                }
                if editability == .editable {
                    NewSceneTile(view: view) { actions.add(.atEnd) }
                }
            }
        }
        .padding(WindowMetrics.Scenes.gridPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var columns: [GridItem] {
        let width =
            switch view {
            case .cards: WindowMetrics.Scenes.cardWidth
            case .lightTable: WindowMetrics.Scenes.tileWidth
            }
        return [GridItem(.adaptive(minimum: width), spacing: WindowMetrics.Scenes.gap, alignment: .top)]
    }

    @ViewBuilder private func card(_ scene: BookScene, number: Int) -> some View {
        let content = SceneCardContent(
            scene: scene, number: number, isOpen: scene.id == book.openScene ? .open : .notOpen,
            titling: scene.id == model.titling && editability == .editable ? .typing : .done)
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
        /// The look while the owner hasn't picked (#28): the recommended candidate.
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

    var tagEntry: TagEntry
    var messages: Messages

    static let recommended = ScenesLook(tagEntry: .chipOpensField, messages: .withHint)
}
