import SceneItCore
import SwiftUI

/// The Search sheet (PLAN §9.1): the query and its options above the results, grouped by
/// scene, best first, and in the File Cabinet by filed copy first. Esc or × closes it; clicking a
/// result opens it, a filed copy's read-only.
struct SearchSheet: View {
    @Bindable var model: SearchSheetModel
    @Binding var mode: WindowMode
    @FocusState private var fieldFocused: Bool
    @Environment(\.windowKeys) private var keys

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
        .background(EscapeKey(keys: keys))
        .onAppear {
            DispatchQueue.main.async { fieldFocused = true }
        }
    }

    /// The mockup's single row (owner, #31); in the File Cabinet, a second row with the copy
    /// picker and the date range.
    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            mainRow
            if model.scope == .fileCabinet, let span = FileCabinet.span(of: model.book.archive) {
                CabinetRow(model: model, span: span)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var mainRow: some View {
        HStack(spacing: WindowMetrics.Search.headerSpacing) {
            Text(SearchWording.title)
                .font(.title3.weight(.semibold))
            TextField(SearchWording.placeholder, text: $model.text)
                .textFieldStyle(.roundedBorder)
                .frame(width: WindowMetrics.Search.fieldWidth)
                .focused($fieldFocused)
            checkbox(.searchTags)
            scopes
            checkbox(.matchCase)
            checkbox(.wholeWord)
            Spacer(minLength: 0)
            close
        }
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

    private var scopes: some View {
        Picker(SearchWording.scopeLabel, selection: $model.scope) {
            ForEach(SearchScope.allCases, id: \.self) { scope in
                Text(SearchWording.scope(scope)).tag(scope)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
    }

    private var close: some View {
        Button {
            mode = mode.closingSheet
        } label: {
            Image(systemName: "xmark")
        }
        .buttonStyle(.borderless)
        .help(WindowWording.closeSheet)
    }
}

/// The File Cabinet's copy picker, all copies in the range or one, and the range itself, as the
/// File Cabinet's own date fields.
private struct CabinetRow: View {
    @Bindable var model: SearchSheetModel
    let span: ClosedRange<CalendarDay>

    var body: some View {
        let pickable = model.cabinet.pickable(in: model.book.archive)
        HStack(spacing: WindowMetrics.Search.headerSpacing) {
            Picker(SearchWording.copyPickerLabel, selection: $model.cabinet.copy) {
                Text(SearchWording.allCopies(pickable.count, model.cabinet.dates))
                    .tag(FiledCopyNumber?.none)
                Divider()
                ForEach(pickable, id: \.number) { copy in
                    Text(SearchWording.copy(copy)).tag(FiledCopyNumber?.some(copy.number))
                }
            }
            .pickerStyle(.menu)
            .labelsHidden()
            .fixedSize()
            FiledDatesField(span: span, dates: $model.cabinet.dates, label: SearchWording.filedFrom)
            Spacer(minLength: 0)
        }
    }
}

/// The summary line, then the scenes, or what stands in for them.
private struct SearchResults: View {
    let model: SearchSheetModel

    var body: some View {
        VStack(alignment: .leading, spacing: WindowMetrics.Search.groupSpacing) {
            if !model.unreadable.isEmpty {
                Label(
                    SearchWording.unreadable(model.unreadable.count), systemImage: "exclamationmark.triangle"
                )
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
            }
            switch model.state {
            case .prompt(let scope):
                summary(SearchWording.prompt(scope))
            case .noWords:
                summary(SearchWording.noWords)
            case .noSceneOpen:
                summary(SearchWording.noSceneOpen)
            case .noFiledCopies:
                summary(SearchWording.noFiledCopies)
            case .noCopiesInRange:
                summary(SearchWording.noCopiesInRange)
            case .searching:
                summary(searching, .searching)
            case .results(let listing, let staleness):
                let activity: Activity =
                    staleness == .stale || listing.progress != .complete || model.reading != nil
                    ? .searching : .done
                results(listing, activity)
            }
        }
    }

    /// "Searching…", or while filed copies are read for the first time, how many are.
    private var searching: String {
        model.reading.map { SearchWording.reading($0.read, of: $0.of) } ?? SearchWording.searching
    }

    private var isCabinet: Bool {
        model.reported?.scope == .fileCabinet
    }

    private func summaryText(_ listing: SearchListing) -> String {
        switch (listing.quality, isCabinet) {
        case (.exact, false): SearchWording.summary(matches: listing.hitCount, scenes: listing.sceneCount)
        case (.near, false): SearchWording.nearSummary(matches: listing.hitCount, scenes: listing.sceneCount)
        case (.exact, true): SearchWording.cabinetSummary(listing.cabinetCounts)
        case (.near, true): SearchWording.cabinetNearSummary(listing.cabinetCounts)
        }
    }

    /// Whether a search is still to report, which the summary shows with a spinner.
    private enum Activity {
        case searching, done
    }

    private func summary(_ text: String, _ activity: Activity = .done) -> some View {
        HStack(spacing: 8) {
            Text(text)
            if activity == .searching {
                ProgressView().controlSize(.small)
            }
        }
        .font(.system(size: 13))
        .foregroundStyle(.secondary)
    }

    @ViewBuilder private func results(_ listing: SearchListing, _ activity: Activity) -> some View {
        if listing.sceneCount == 0 {
            summary(activity == .searching ? searching : SearchWording.noMatches, activity)
        } else {
            summary(summaryText(listing), activity)
            LazyVStack(alignment: .leading, spacing: WindowMetrics.Search.groupSpacing) {
                if isCabinet {
                    ForEach(model.versions(listing), id: \.version) { version in
                        CopyHeader(copy: model.copy(version.version))
                        ForEach(version.scenes, id: \.key) { hits in
                            SceneGroup(model: model, hits: hits)
                        }
                    }
                } else {
                    ForEach(listing.scenes, id: \.key) { hits in
                        SceneGroup(model: model, hits: hits)
                    }
                }
            }
            if listing.hiddenSceneCount > 0 {
                Button(SearchWording.showAll(listing.sceneCount)) { model.showAllNearMatches() }
            }
        }
    }
}

/// The line over a filed copy's results (PLAN §9.1, mockup 11): its date and tags, and that it
/// opens read-only.
private struct CopyHeader: View {
    let copy: FiledCopy?

    var body: some View {
        if let copy {
            HStack(spacing: 6) {
                Image(systemName: "archivebox")
                Text(
                    "\(Text(SearchWording.copy(copy)).fontWeight(.semibold)) \u{00B7} \(SearchWording.opensReadOnly)"
                )
            }
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .padding(.top, 4)
        }
    }
}

/// One scene's hits: its header, its best hit, and "+N more in this scene", which shows the
/// rest (owner, #31). A filed copy's own tags show as a group of their own.
private struct SceneGroup: View {
    let model: SearchSheetModel
    let hits: SceneHits

    var body: some View {
        let expanded = model.isExpanded(hits)
        VStack(alignment: .leading, spacing: 0) {
            header
            ForEach(expanded ? hits.hits : [hits.best], id: \.unit.source) { hit in
                WindowMetrics.Search.rowLine.frame(height: 1)
                HitRow(model: model, hit: hit)
            }
            if hits.moreCount > 0 {
                WindowMetrics.Search.rowLine.frame(height: 1)
                Button(expanded ? SearchWording.fewerInScene : SearchWording.moreInScene(hits.moreCount)) {
                    model.toggleExpanded(hits)
                }
                .buttonStyle(.link)
                .font(.system(size: 12))
                .padding(WindowMetrics.Search.rowPadding)
            }
        }
        .background(Color.white)
        .clipShape(RoundedRectangle(cornerRadius: WindowMetrics.Search.groupCornerRadius))
        .overlay(
            RoundedRectangle(cornerRadius: WindowMetrics.Search.groupCornerRadius)
                .strokeBorder(WindowMetrics.Search.line))
    }

    private var header: some View {
        HStack(spacing: 8) {
            if let scene = hits.best.unit.scene {
                SceneNumber(placement: scene.placement)
                sceneTitle(scene)
            } else {
                Text(SearchWording.copyTags).fontWeight(.semibold).font(.system(size: 14))
            }
            Spacer(minLength: 0)
            Text(SearchWording.matches(hits.hits.count))
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .padding(WindowMetrics.Search.headerPadding)
        .background(WindowMetrics.Search.groupHeader)
    }

    @ViewBuilder private func sceneTitle(_ scene: SearchedScene) -> some View {
        let title = Text(SearchWording.sceneTitle(scene.title)).fontWeight(.semibold)
        if scene.placement == .boneyard {
            Text("\(title)\(Text(SearchWording.boneyardSuffix).foregroundStyle(.secondary))")
                .font(.system(size: 14))
        } else {
            title.font(.system(size: 14))
        }
    }
}

/// One hit: its field's label and its snippet, which opens it.
private struct HitRow: View {
    let model: SearchSheetModel
    let hit: SearchHit
    @State private var hovering = false

    var body: some View {
        Button {
            model.open(hit)
        } label: {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(SearchWording.field(hit.unit.source))
                    .font(.system(size: 11))
                    .tracking(0.4)
                    .foregroundStyle(.secondary)
                    .frame(minWidth: WindowMetrics.Search.labelWidth, alignment: .leading)
                    .fixedSize()
                snippet
                Spacer(minLength: 0)
            }
            .padding(WindowMetrics.Search.rowPadding)
            .contentShape(Rectangle())
            .background(hovering ? WindowMetrics.Search.hover : .clear)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    @ViewBuilder private var snippet: some View {
        if hit.unit.isTagSet {
            HStack(spacing: 6) {
                ForEach(Array(SearchSnippet.tags(hit).enumerated()), id: \.offset) { _, tag in
                    Text(Self.marked(tag))
                        .font(.system(size: 13))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(WindowMetrics.Search.groupHeader))
                }
            }
        } else {
            Text(Self.marked(SearchSnippet(hit)))
                .font(.custom("Times New Roman", size: WindowMetrics.Search.snippetSize))
                .lineLimit(1)
                .truncationMode(.tail)
        }
    }

    /// Matches in the mockup's yellow; in a near match, the words that differ underlined in
    /// orange (owner, #31).
    static func marked(_ snippet: SearchSnippet) -> AttributedString {
        var text = AttributedString(snippet.text)
        let utf16 = snippet.text.utf16
        for highlight in snippet.highlights {
            let lower = utf16.index(utf16.startIndex, offsetBy: highlight.range.lowerBound)
            let upper = utf16.index(utf16.startIndex, offsetBy: highlight.range.upperBound)
            guard let range = Range(lower..<upper, in: text) else { continue }
            switch highlight.kind {
            case .match: text[range].backgroundColor = WindowMetrics.Search.marker
            case .differs: text[range].underlineStyle = Text.LineStyle(pattern: .solid, color: .orange)
            }
        }
        return text
    }
}
