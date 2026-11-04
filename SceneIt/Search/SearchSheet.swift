import SceneItCore
import SwiftUI

/// The Search sheet (PLAN §9.1): the query and its options above the results, grouped by
/// scene, best first. Esc or × closes it; clicking a result opens it.
struct SearchSheet: View {
    @Bindable var model: SearchSheetModel
    @Binding var mode: WindowMode
    @Environment(\.searchSheetLook) private var look
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView(.vertical) {
                SearchResults(model: model)
                    .padding(WindowMetrics.Search.bodyPadding)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .background(WindowMetrics.Search.background)
        }
        .background(.background)
        .background(UndoFocusHolder(role: .sheet))
        .onAppear {
            DispatchQueue.main.async { fieldFocused = true }
        }
    }

    @ViewBuilder private var header: some View {
        switch look.options {
        case .oneRow, .oneRowWithCabinet:
            HStack(spacing: WindowMetrics.Search.headerSpacing) {
                title
                field
                checkbox(.searchTags)
                scopes
                checkbox(.matchCase)
                checkbox(.wholeWord)
                Spacer(minLength: 0)
                close
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        case .twoRows:
            HStack(alignment: .top, spacing: WindowMetrics.Search.headerSpacing) {
                title
                    .frame(height: 22)
                VStack(alignment: .leading, spacing: 8) {
                    field
                    HStack(spacing: WindowMetrics.Search.headerSpacing) {
                        checkbox(.searchTags)
                        checkbox(.matchCase)
                        checkbox(.wholeWord)
                    }
                }
                scopes
                Spacer(minLength: 0)
                close
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
        }
    }

    private var title: some View {
        Text(SearchWording.title)
            .font(.title3.weight(.semibold))
    }

    private var field: some View {
        TextField(SearchWording.placeholder, text: $model.text)
            .textFieldStyle(.roundedBorder)
            .frame(width: WindowMetrics.Search.fieldWidth)
            .focused($fieldFocused)
    }

    private func checkbox(_ checkbox: SearchCheckbox) -> some View {
        Toggle(
            SearchWording.checkbox(checkbox),
            isOn: Binding(
                get: { model.isOn(checkbox) },
                set: { model.set(checkbox, $0 ? .on : .off) })
        )
        .toggleStyle(.checkbox)
        .help(checkbox == .searchTags ? SearchWording.searchTagsHelp : "")
    }

    @ViewBuilder private var scopes: some View {
        let picker = Picker(SearchWording.scopeLabel, selection: $model.scope) {
            ForEach(SearchScope.allCases, id: \.self) { scope in
                Text(SearchWording.scope(scope)).tag(scope)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        switch look.options {
        case .oneRow, .twoRows:
            picker
        case .oneRowWithCabinet:
            HStack(spacing: 0) {
                picker
                Text(SearchWording.fileCabinet)
                    .foregroundStyle(.tertiary)
                    .fixedSize()
                    .padding(.horizontal, 10)
                    .help(WindowWording.sheetComingLater)
            }
        }
    }

    private var close: some View {
        Button {
            mode = mode.closingSheet
        } label: {
            Image(systemName: "xmark")
        }
        .buttonStyle(.borderless)
        .keyboardShortcut(.cancelAction)
        .help(WindowWording.closeSheet)
    }
}

/// The summary line, then the scenes, or what stands in for them.
private struct SearchResults: View {
    let model: SearchSheetModel

    var body: some View {
        VStack(alignment: .leading, spacing: WindowMetrics.Search.groupSpacing) {
            switch model.state {
            case .prompt(let scope):
                summary(SearchWording.prompt(scope))
            case .noWords:
                summary(SearchWording.noWords)
            case .noSceneOpen:
                summary(SearchWording.noSceneOpen)
            case .searching:
                summary(SearchWording.searching, searching: true)
            case .results(let listing, let staleness):
                results(listing, searching: staleness == .stale || listing.progress != .complete)
            }
        }
    }

    private func summary(_ text: String, searching: Bool = false) -> some View {
        HStack(spacing: 8) {
            Text(text)
            if searching {
                ProgressView().controlSize(.small)
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(.secondary)
    }

    @ViewBuilder private func results(_ listing: SearchListing, searching: Bool) -> some View {
        if listing.sceneCount == 0 {
            summary(searching ? SearchWording.searching : SearchWording.noMatches, searching: searching)
        } else {
            let counts = SearchWording.summary(matches: listing.hitCount, scenes: listing.sceneCount)
            switch listing.quality {
            case .exact: summary(counts, searching: searching)
            case .near: summary("\(SearchWording.noExactMatches) · \(counts)", searching: searching)
            }
            LazyVStack(alignment: .leading, spacing: WindowMetrics.Search.groupSpacing) {
                ForEach(listing.scenes, id: \.self) { hits in
                    SceneGroup(model: model, hits: hits)
                }
            }
            if listing.hiddenSceneCount > 0 {
                Button(SearchWording.showAll(listing.sceneCount)) { model.showAllNearMatches() }
            }
        }
    }
}

/// One scene's hits: its header, its best hits, and "+N more in this scene".
private struct SceneGroup: View {
    let model: SearchSheetModel
    let hits: SceneHits
    @Environment(\.searchSheetLook) private var look

    var body: some View {
        let expanded = model.isExpanded(hits)
        let shown = expanded ? hits.hits : Array(hits.hits.prefix(look.hitsBeforeMore))
        let more = hits.hits.count - min(hits.hits.count, look.hitsBeforeMore)
        switch look.rows {
        case .bestThenMore, .firstThreeThenMore:
            VStack(alignment: .leading, spacing: 0) {
                header
                ForEach(shown, id: \.self) { hit in
                    WindowMetrics.Search.rowLine.frame(height: 1)
                    HitRow(model: model, hit: hit)
                }
                if more > 0 {
                    WindowMetrics.Search.rowLine.frame(height: 1)
                    moreButton(more, expanded: expanded)
                        .padding(WindowMetrics.Search.rowPadding)
                }
            }
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: WindowMetrics.Search.groupCornerRadius))
            .overlay(
                RoundedRectangle(cornerRadius: WindowMetrics.Search.groupCornerRadius)
                    .strokeBorder(WindowMetrics.Search.line))
        case .compact:
            VStack(alignment: .leading, spacing: 0) {
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    SceneNumber(placement: hits.best.unit.placement)
                        .alignmentGuide(.firstTextBaseline) { $0[VerticalAlignment.center] + 4 }
                    sceneTitle
                        .lineLimit(1)
                        .frame(width: WindowMetrics.Search.compactTitleWidth, alignment: .leading)
                    HitRow(model: model, hit: hits.best, padding: EdgeInsets())
                    if more > 0 {
                        moreButton(more, expanded: expanded)
                            .fixedSize()
                    }
                }
                if expanded {
                    ForEach(hits.hits.dropFirst(), id: \.self) { hit in
                        HitRow(model: model, hit: hit, padding: EdgeInsets())
                            .padding(
                                .leading,
                                WindowMetrics.Search.numberSize + 10 + WindowMetrics.Search.compactTitleWidth
                                    + 10
                            )
                            .padding(.top, 4)
                    }
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color.white)
            .clipShape(RoundedRectangle(cornerRadius: 6))
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            SceneNumber(placement: hits.best.unit.placement)
            sceneTitle
            Spacer(minLength: 0)
            Text(SearchWording.matches(hits.hits.count))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .padding(WindowMetrics.Search.headerPadding)
        .background(WindowMetrics.Search.groupHeader)
    }

    @ViewBuilder private var sceneTitle: some View {
        let title = Text(SearchWording.sceneTitle(hits.best.unit.sceneTitle)).fontWeight(.semibold)
        if hits.best.unit.placement == .boneyard {
            Text("\(title)\(Text(" · \(SearchWording.boneyard)").foregroundStyle(.secondary))")
                .font(.system(size: 14))
        } else {
            title.font(.system(size: 14))
        }
    }

    private func moreButton(_ more: Int, expanded: Bool) -> some View {
        Button(expanded ? SearchWording.fewerInScene : SearchWording.moreInScene(more)) {
            model.toggleExpanded(hits)
        }
        .buttonStyle(.link)
        .font(.system(size: 12))
    }
}

/// A scene's number in a circle, or **B** for the Boneyard.
private struct SceneNumber: View {
    let placement: ScenePlacement

    var body: some View {
        Text(SearchWording.sceneNumber(placement))
            .font(.system(size: 11, weight: .semibold))
            .frame(width: WindowMetrics.Search.numberSize, height: WindowMetrics.Search.numberSize)
            .background(Circle().fill(Color.white))
            .overlay(Circle().strokeBorder(WindowMetrics.Search.line, lineWidth: 1.5))
    }
}

/// One hit: its field's label and its snippet, which opens it.
private struct HitRow: View {
    let model: SearchSheetModel
    let hit: SearchHit
    var padding = WindowMetrics.Search.rowPadding
    @Environment(\.searchSheetLook) private var look
    @State private var hovering = false

    var body: some View {
        Button {
            model.open(hit)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(SearchWording.field(hit.unit.field))
                    .font(.system(size: 11))
                    .tracking(0.4)
                    .foregroundStyle(.secondary)
                    .frame(
                        minWidth: look.rows == .compact ? 0 : WindowMetrics.Search.labelWidth - 12,
                        alignment: .leading
                    )
                    .fixedSize()
                snippet
                Spacer(minLength: 0)
            }
            .padding(padding)
            .contentShape(Rectangle())
            .background(hovering ? WindowMetrics.Search.hover : .clear)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    @ViewBuilder private var snippet: some View {
        if hit.unit.field == .tags {
            HStack(spacing: 6) {
                ForEach(Array(SearchSnippet.tags(hit).enumerated()), id: \.offset) { _, tag in
                    Text(Self.marked(tag, look))
                        .font(.system(size: 13))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(WindowMetrics.Search.groupHeader))
                }
            }
        } else {
            Text(Self.marked(SearchSnippet(hit), look))
                .font(.custom("Times New Roman", size: WindowMetrics.Search.snippetSize))
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    static func marked(_ snippet: SearchSnippet, _ look: SearchSheetLook) -> AttributedString {
        var text = AttributedString(snippet.text)
        let utf16 = snippet.text.utf16
        for highlight in snippet.highlights {
            let lower = utf16.index(utf16.startIndex, offsetBy: highlight.range.lowerBound)
            let upper = utf16.index(utf16.startIndex, offsetBy: highlight.range.upperBound)
            guard let range = Range(lower..<upper, in: text) else { continue }
            switch highlight.kind {
            case .match: mark(&text[range], look.match)
            case .differs: mark(&text[range], look.differs)
            }
        }
        return text
    }

    private static func mark(_ text: inout AttributedSubstring, _ mark: SearchSheetLook.MatchMark) {
        switch mark {
        case .yellow:
            text.backgroundColor = WindowMetrics.Search.marker
        case .yellowBold:
            text.backgroundColor = WindowMetrics.Search.marker
            text.inlinePresentationIntent = .stronglyEmphasized
        case .accentTint:
            text.backgroundColor = Color.accentColor.opacity(0.22)
        }
    }

    private static func mark(_ text: inout AttributedSubstring, _ mark: SearchSheetLook.DiffersMark) {
        switch mark {
        case .orangeUnderline:
            text.underlineStyle = Text.LineStyle(pattern: .solid, color: .orange)
        case .dottedRed:
            text.underlineStyle = Text.LineStyle(pattern: .dot, color: .red)
        case .grayDashed:
            text.backgroundColor = WindowMetrics.Search.differsGray
            text.underlineStyle = Text.LineStyle(pattern: .dash, color: .secondary)
        }
    }
}
