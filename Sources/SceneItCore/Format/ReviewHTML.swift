/// A review report as HTML (review format §6.1–§6.2, §7): Copy Review's clipboard HTML, and Save
/// Review…'s standalone page, whose body is the clipboard HTML with a checkbox for each ☐. Both are
/// ASCII, with inline styles only, and load nothing from anywhere.
public enum ReviewHTML {
    /// Copy Review's HTML (review format §6.2), for pasting into an email.
    public static func clipboard(_ report: ReviewReport, look: ReviewLook = .standard) -> String {
        body(report, look: look, box: .symbol)
    }

    /// Save Review…'s page (review format §7): the report with real checkboxes, whose ticks the
    /// browser keeps under the review's id.
    public static func page(_ report: ReviewReport, review: ReviewID, look: ReviewLook = .standard) -> String
    {
        """
        <!DOCTYPE html>
        <html lang="en">
        <head>
        <meta charset="utf-8">
        <meta http-equiv="Content-Security-Policy" content="default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'">
        <meta name="viewport" content="width=device-width, initial-scale=1">
        <title>\(escaped(ReviewOutputWording.heading(report.title)))</title>
        </head>
        <body style="\(look.page)">
        <div style="\(look.column)">
        <noscript><p style="\(look.pageNotice)">\(escaped(ReviewOutputWording.noScript))</p></noscript>
        <p id="no-storage" hidden style="\(look.pageNotice)">\(escaped(ReviewOutputWording.noStorage))</p>
        \(body(report, look: look, box: .checkbox))</div>
        <script>
        \(script(review))
        </script>
        </body>
        </html>

        """
    }

    /// What starts an item: the ☐ symbol in an email, a checkbox on the page.
    enum ItemBox {
        case symbol, checkbox
    }

    static func body(_ report: ReviewReport, look: ReviewLook, box: ItemBox) -> String {
        var lines = ["<div style=\"\(look.report)\">"]
        lines.append(paragraph(look.title, escaped(ReviewOutputWording.heading(report.title))))
        lines.append(paragraph(look.date, escaped(ReviewOutputWording.date(report.day))))
        if !report.notes.isEmpty {
            lines.append(paragraph(look.generalNotesHeading, escaped(ReviewOutputWording.generalNotes)))
            lines += report.notes.map { paragraph(look.paragraph, html($0)) }
        }
        for scene in report.scenes {
            lines.append(paragraph(look.sceneHeading, escaped(scene.title)))
            for item in scene.items {
                lines.append("<div style=\"\(look.item)\">")
                let start = start(of: item, box, look)
                if let quote = item.quote {
                    lines.append(paragraph(look.quote, start + html(quote, look)))
                    if !item.comment.isEmpty { lines.append(paragraph(look.comment, comment(item.comment))) }
                } else {
                    lines.append(paragraph(look.quote, start + comment(item.comment)))
                }
                lines.append("</div>")
            }
            if !scene.notes.isEmpty {
                lines.append(paragraph(look.notesHeading, escaped(ReviewOutputWording.sceneNotes)))
                lines += scene.notes.map { paragraph(look.paragraph, html($0)) }
            }
        }
        lines.append("</div>")
        return lines.joined(separator: "\n") + "\n"
    }

    private static func start(of item: ReviewReport.Item, _ box: ItemBox, _ look: ReviewLook) -> String {
        switch box {
        case .symbol: escaped("\u{2610} ")
        case .checkbox:
            "<input type=\"checkbox\" data-item=\"\(escaped(item.key.description))\" "
                + "aria-label=\"\(escaped(ReviewOutputWording.checkboxLabel))\" style=\"\(look.checkbox)\">"
        }
    }

    private static func paragraph(_ style: String, _ content: String) -> String {
        "<p style=\"\(style)\">\(content)</p>"
    }

    private static func html(_ quote: ReviewReport.Quote, _ look: ReviewLook) -> String {
        [(quote.before, look.context), (quote.passage, look.passage), (quote.after, look.context)]
            .filter { !$0.0.runs.isEmpty }
            .map { "<span style=\"\($0.1)\">\(html($0.0))</span>" }
            .joined()
    }

    /// Each run in its styles, outermost first; an empty paragraph is a line break.
    private static func html(_ text: ReportText) -> String {
        guard !text.runs.isEmpty else { return "<br>" }
        return text.runs.map { run in
            let tags = TextStyle.allCases.filter(run.styles.contains).map(tag)
            return tags.map(\.open).joined() + escaped(run.text) + tags.reversed().map(\.close).joined()
        }.joined()
    }

    private static func tag(_ style: TextStyle) -> (open: String, close: String) {
        switch style {
        case .bold: ("<b>", "</b>")
        case .italic: ("<i>", "</i>")
        case .strike: ("<span style=\"text-decoration:line-through;\">", "</span>")
        }
    }

    private static func comment(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { escaped(String($0)) }
            .joined(separator: "<br>")
    }

    /// `text` as ASCII HTML (review format §6.1): the markup characters as entities, and every
    /// character above U+007E as a hexadecimal reference.
    static func escaped(_ text: String) -> String {
        var result = ""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "&": result += "&amp;"
            case "<": result += "&lt;"
            case ">": result += "&gt;"
            case "\"": result += "&quot;"
            case _ where scalar.value > 0x7E:
                let hex = String(scalar.value, radix: 16, uppercase: true)
                result += "&#x" + String(repeating: "0", count: max(0, 4 - hex.count)) + hex + ";"
            default: result.unicodeScalars.append(scalar)
            }
        }
        return result
    }

    /// Review format §7.3, verbatim. A review id holds only id characters (book format §2.2), so
    /// it needs no escaping in the string.
    private static func script(_ review: ReviewID) -> String {
        """
        (function () {
          "use strict";
          var key = "sceneit.review.\(review)";
          var notice = document.getElementById("no-storage");
          var store = null;
          try { store = window.localStorage; store.getItem(key); } catch (e) { store = null; }
          var ticked = {};
          if (store !== null) {
            try { ticked = JSON.parse(store.getItem(key) || "{}") || {}; } catch (e) { ticked = {}; }
          } else {
            notice.hidden = false;
          }
          function show(box) { box.parentNode.parentNode.style.opacity = box.checked ? "0.5" : "1"; }
          function save(box) {
            var item = box.getAttribute("data-item");
            if (box.checked) { ticked[item] = true; } else { delete ticked[item]; }
            if (store === null) { return; }
            try { store.setItem(key, JSON.stringify(ticked)); } catch (e) { notice.hidden = false; }
          }
          var boxes = document.querySelectorAll("input[data-item]");
          for (var i = 0; i < boxes.length; i++) {
            boxes[i].checked = ticked[boxes[i].getAttribute("data-item")] === true;
            show(boxes[i]);
            boxes[i].addEventListener("change", function (event) { save(event.target); show(event.target); });
          }
        })();
        """
    }
}

/// The inline styles of a review's HTML (review format §6.2), one per part of the layout: the
/// look, as data in one place.
public struct ReviewLook: Hashable, Sendable {
    public var report: String
    public var title: String
    public var date: String
    public var generalNotesHeading: String
    public var sceneHeading: String
    public var item: String
    /// The item's first line: its box, then the quoted paragraph or a detached comment's text.
    public var quote: String
    /// The paragraph around the passage.
    public var context: String
    public var passage: String
    public var comment: String
    public var notesHeading: String
    public var paragraph: String
    public var checkbox: String
    /// The standalone page's body, its column, and its two notes about remembering ticks.
    public var page: String
    public var column: String
    public var pageNotice: String

    public init(
        report: String, title: String, date: String, generalNotesHeading: String, sceneHeading: String,
        item: String, quote: String, context: String, passage: String, comment: String, notesHeading: String,
        paragraph: String, checkbox: String, page: String, column: String, pageNotice: String
    ) {
        self.report = report
        self.title = title
        self.date = date
        self.generalNotesHeading = generalNotesHeading
        self.sceneHeading = sceneHeading
        self.item = item
        self.quote = quote
        self.context = context
        self.passage = passage
        self.comment = comment
        self.notesHeading = notesHeading
        self.paragraph = paragraph
        self.checkbox = checkbox
        self.page = page
        self.column = column
        self.pageNotice = pageNotice
    }

    static let gray = "#666666"
    static let mark = "#FFF2A8"

    /// Review format §6.2's look: Georgia, the passage on a pale yellow, the rest of its paragraph
    /// in gray, the comment indented under it.
    public static let standard = ReviewLook(
        report: "font-family:Georgia,serif;font-size:16px;line-height:1.5;color:#222222;",
        title: "margin:0 0 4px 0;font-size:22px;font-weight:bold;",
        date: "margin:0 0 24px 0;color:\(gray);",
        generalNotesHeading: "margin:0 0 8px 0;font-size:18px;font-weight:bold;",
        sceneHeading: "margin:24px 0 8px 0;font-size:18px;font-weight:bold;",
        item: "margin:0 0 16px 0;",
        quote: "margin:0;",
        context: "color:\(gray);",
        passage: "background-color:\(mark);",
        comment: "margin:4px 0 0 28px;",
        notesHeading: "margin:16px 0 4px 0;font-weight:bold;",
        paragraph: "margin:0 0 8px 0;",
        checkbox: "margin:0 8px 0 0;",
        page: "margin:0;padding:32px;background-color:#FFFFFF;",
        column: "max-width:40em;margin:0 auto;",
        pageNotice: "margin:0 0 16px 0;padding:8px 12px;background-color:#F2F2F2;font-family:Georgia,serif;")
}
