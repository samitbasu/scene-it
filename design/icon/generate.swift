// Writes Scene It's app icon as an Icon Composer document: icon.json plus one flat SVG per layer.
// The system draws the tile fill, the glass, the shadows and every appearance (light, dark, tinted,
// clear) from these layers. Usage: swift design/icon/generate.swift SceneIt/AppIcon.icon

import CoreGraphics
import CoreText
import Foundation

// Coordinates are on the 1024 macOS icon grid (tile 824 at 100,100, y down), as in the concept
// sketches. Icon Composer's canvas is the tile alone, so toCanvas scales the tile up to fill it.
let tileOrigin: CGFloat = 100
let tileSide: CGFloat = 824
let canvasSide: CGFloat = 1024
let toCanvas = CGAffineTransform(scaleX: canvasSide / tileSide, y: canvasSide / tileSide)
    .translatedBy(x: -tileOrigin, y: -tileOrigin)

struct Color {
    let hex: UInt32
    let alpha: CGFloat

    init(_ hex: UInt32, alpha: CGFloat = 1) {
        self.hex = hex
        self.alpha = alpha
    }

    private func component(_ shift: UInt32) -> CGFloat { CGFloat((hex >> shift) & 0xFF) / 255 }

    var iconJSON: String {
        String(format: "srgb:%.5f,%.5f,%.5f,%.5f", component(16), component(8), component(0), alpha)
    }
    var svg: String { String(format: "#%06X", hex) }
}

// MARK: geometry

let cardSize = CGSize(width: 600, height: 396)
let cardRadius: CGFloat = 22
let stackCenter = CGPoint(x: 512, y: 532)

struct Placement {
    let degrees: CGFloat
    let offset: CGVector

    var transform: CGAffineTransform {
        CGAffineTransform(translationX: stackCenter.x + offset.dx, y: stackCenter.y + offset.dy)
            .rotated(by: degrees * .pi / 180)
    }
}

// The cards fan out, and step down in tone towards the back, far enough that they still read as a
// stack at 16 px, where the system draws this same artwork about 14 px wide.
let rearPlacement = Placement(degrees: -12, offset: CGVector(dx: -36, dy: -80))
let middlePlacement = Placement(degrees: 9, offset: CGVector(dx: 32, dy: -56))
let frontPlacement = Placement(degrees: -2, offset: CGVector(dx: 0, dy: 64))

let cardRect = CGRect(
    x: -cardSize.width / 2, y: -cardSize.height / 2, width: cardSize.width, height: cardSize.height)

func card(_ placement: Placement) -> CGPath {
    var t = placement.transform
    return CGPath(
        roundedRect: cardRect, cornerWidth: cardRadius, cornerHeight: cardRadius, transform: &t)
}

/// A horizontal rule across the card at `y` (card space), as a filled outline.
func rule(y: CGFloat, from x0: CGFloat, to x1: CGFloat, weight: CGFloat, cap: CGLineCap) -> CGPath {
    let p = CGMutablePath()
    p.move(to: CGPoint(x: x0, y: y))
    p.addLine(to: CGPoint(x: x1, y: y))
    return p.copy(strokingWithWidth: weight, lineCap: cap, lineJoin: .round, miterLimit: 10)
}

func onFront(_ path: CGPath) -> CGPath {
    var t = frontPlacement.transform
    return path.copy(using: &t)!.intersection(card(frontPlacement))
}

func glyphOutline(_ text: String, font: String, size: CGFloat, center: CGPoint) -> CGPath {
    let f = CTFontCreateWithName(font as CFString, size, nil)
    let line = CTLineCreateWithAttributedString(
        NSAttributedString(string: text, attributes: [.init(kCTFontAttributeName as String): f]))
    let path = CGMutablePath()
    for run in CTLineGetGlyphRuns(line) as! [CTRun] {
        let n = CTRunGetGlyphCount(run)
        var glyphs = [CGGlyph](repeating: 0, count: n)
        var positions = [CGPoint](repeating: .zero, count: n)
        CTRunGetGlyphs(run, CFRange(location: 0, length: n), &glyphs)
        CTRunGetPositions(run, CFRange(location: 0, length: n), &positions)
        for i in 0..<n {
            if let g = CTFontCreatePathForGlyph(f, glyphs[i], nil) {
                path.addPath(
                    g, transform: CGAffineTransform(translationX: positions[i].x, y: positions[i].y))
            }
        }
    }
    let box = path.boundingBoxOfPath
    var t = CGAffineTransform(translationX: center.x, y: center.y).scaledBy(x: 1, y: -1)
        .translatedBy(x: -box.midX, y: -box.midY)
    return path.copy(using: &t)!
}

let redRuleY = cardRect.minY + 112

/// The red top rule: the one detail heavy enough to survive at 32 px and tint the card at 16 px.
func redRule() -> CGPath {
    onFront(rule(y: redRuleY, from: cardRect.minX - 10, to: cardRect.maxX + 10, weight: 20, cap: .butt))
}

func blueRules() -> CGPath {
    let p = CGMutablePath()
    for i in 1...4 {
        p.addPath(
            rule(
                y: redRuleY + CGFloat(i) * 60, from: cardRect.minX - 10, to: cardRect.maxX + 10,
                weight: 4, cap: .butt))
    }
    return onFront(p)
}

func writing() -> CGPath {
    let p = CGMutablePath()
    let left = cardRect.minX + 56
    let span = cardSize.width - 112
    for (i, fraction) in [0.80, 0.88, 0.52].enumerated() {
        let y = redRuleY + CGFloat(i + 1) * 60 - 16
        p.addPath(rule(y: y, from: left, to: left + span * fraction, weight: 18, cap: .round))
    }
    return onFront(p)
}

func sceneNumber() -> CGPath {
    let center = CGPoint(x: cardRect.minX + 84, y: cardRect.minY + 58)
    let radius: CGFloat = 46
    let ring = CGPath(
        ellipseIn: CGRect(
            x: center.x - radius, y: center.y - radius, width: radius * 2, height: radius * 2),
        transform: nil
    ).copy(strokingWithWidth: 8, lineCap: .round, lineJoin: .round, miterLimit: 10)
    let p = CGMutablePath()
    p.addPath(ring)
    p.addPath(glyphOutline("3", font: "TimesNewRomanPS-BoldMT", size: 76, center: center))
    return onFront(p)
}

// MARK: layers and appearances

struct Layer {
    let name: String
    let path: CGPath
    let light: Color
    let dark: Color
    let opacity: CGFloat
}

enum Shadow {
    case none
    case neutral(opacity: CGFloat)
}

struct Group {
    let layers: [Layer]
    let shadow: Shadow
}

let ink = Color(0x1C1C1E)
/// Top to bottom, as Icon Composer lists them; so are each group's layers.
let groups = [
    Group(
        layers: [
            Layer(
                name: "scene-number", path: sceneNumber(), light: ink, dark: ink, opacity: 1),
            Layer(
                name: "red-rule", path: redRule(), light: Color(0xC62828), dark: Color(0xD93A36),
                opacity: 1),
            Layer(name: "writing", path: writing(), light: ink, dark: ink, opacity: 0.26),
            Layer(
                name: "blue-rules", path: blueRules(), light: Color(0x1E5BC6),
                dark: Color(0x1E5BC6), opacity: 0.2),
        ], shadow: .none),
    Group(
        layers: [
            Layer(
                name: "front-card", path: card(frontPlacement), light: Color(0xFFFEFA),
                dark: Color(0xD9D5CC), opacity: 1)
        ], shadow: .neutral(opacity: 0.5)),
    Group(
        layers: [
            Layer(
                name: "middle-card", path: card(middlePlacement), light: Color(0xEAE4D7),
                dark: Color(0xA29E96), opacity: 1),
            Layer(
                name: "rear-card", path: card(rearPlacement), light: Color(0xD3C9B5),
                dark: Color(0x77746E), opacity: 1),
        ], shadow: .neutral(opacity: 0.5)),
]

let tileLight = (top: Color(0x5A93F2), bottom: Color(0x1E5BC6))
let tileDark = (top: Color(0x3A3A3D), bottom: Color(0x1E1E20))

// MARK: output

func svgPathData(_ path: CGPath) -> String {
    var t = toCanvas
    let mapped = path.copy(using: &t)!
    var d = ""
    func pt(_ p: CGPoint) -> String { String(format: "%.2f %.2f", p.x, p.y) }
    mapped.applyWithBlock { element in
        let e = element.pointee
        switch e.type {
        case .moveToPoint: d += "M\(pt(e.points[0]))"
        case .addLineToPoint: d += "L\(pt(e.points[0]))"
        case .addQuadCurveToPoint: d += "Q\(pt(e.points[0])) \(pt(e.points[1]))"
        case .addCurveToPoint: d += "C\(pt(e.points[0])) \(pt(e.points[1])) \(pt(e.points[2]))"
        case .closeSubpath: d += "Z"
        @unknown default: fatalError("unknown path element")
        }
    }
    return d
}

func svg(_ layer: Layer) -> String {
    """
    <svg xmlns="http://www.w3.org/2000/svg" width="1024" height="1024" viewBox="0 0 1024 1024">
      <path fill="\(layer.light.svg)" fill-rule="nonzero" d="\(svgPathData(layer.path))"/>
    </svg>

    """
}

func gradient(_ colors: (top: Color, bottom: Color)) -> [String: Any] {
    [
        "linear-gradient": [colors.top.iconJSON, colors.bottom.iconJSON],
        "orientation": ["start": ["x": 0.5, "y": 0], "stop": ["x": 0.5, "y": 1]],
    ]
}

func layerJSON(_ layer: Layer) -> [String: Any] {
    [
        "name": layer.name,
        "image-name": "\(layer.name).svg",
        "glass": false,
        "opacity": layer.opacity,
        "fill-specializations": [
            ["value": ["solid": layer.light.iconJSON]],
            ["appearance": "dark", "value": ["solid": layer.dark.iconJSON]],
        ],
    ]
}

func shadowJSON(_ shadow: Shadow) -> [String: Any] {
    switch shadow {
    case .none: ["kind": "none", "opacity": 0]
    case .neutral(let opacity): ["kind": "neutral", "opacity": opacity]
    }
}

func groupJSON(_ group: Group) -> [String: Any] {
    [
        "layers": group.layers.map(layerJSON),
        "shadow": shadowJSON(group.shadow),
        "translucency": ["enabled": false, "value": 0],
        "specular": true,
    ]
}

let document: [String: Any] = [
    "fill-specializations": [
        ["value": gradient(tileLight)],
        ["appearance": "dark", "value": gradient(tileDark)],
    ],
    "groups": groups.map(groupJSON),
    "supported-platforms": ["squares": ["macOS"]],
]

let out = URL(fileURLWithPath: CommandLine.arguments[1])
let assets = out.appendingPathComponent("Assets")
try? FileManager.default.removeItem(at: assets)
try FileManager.default.createDirectory(at: assets, withIntermediateDirectories: true)
for layer in groups.flatMap(\.layers) {
    try svg(layer).write(
        to: assets.appendingPathComponent("\(layer.name).svg"), atomically: true, encoding: .utf8)
}
let json = try JSONSerialization.data(
    withJSONObject: document, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])
try (String(decoding: json, as: UTF8.self) + "\n").write(
    to: out.appendingPathComponent("icon.json"), atomically: true, encoding: .utf8)
