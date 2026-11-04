/// Page magnification, 50–300% (PLAN §4.1). An app-wide preference, not book data (ADR 0022).
public typealias Zoom = Bounded<ZoomBounds>

public enum ZoomBounds: ScalarBounds {
    public static let range: ClosedRange<Double> = 0.5...3.0
    public static let standard = 1.0
}

extension Double {
    public init(_ zoom: Zoom) {
        self = zoom.value
    }
}

extension Bounded where Bounds == ZoomBounds {
    /// The magnifications Zoom In and Zoom Out step through: the ladder browsers use, closer
    /// together near 100%, where a writer reads, and covering the whole range.
    public static let steps: [Zoom] = [0.5, 0.67, 0.75, 0.8, 0.9, 1, 1.1, 1.25, 1.5, 1.75, 2, 2.5, 3].map(
        Zoom.init(clamping:))

    /// The next step up; 300% stays 300%. A zoom between steps (a pinch, Fit Width) goes to
    /// the step above it.
    public var zoomedIn: Zoom {
        Self.steps.first { $0.value > value + Self.tolerance } ?? Self(clamping: Bounds.range.upperBound)
    }

    /// The next step down; 50% stays 50%.
    public var zoomedOut: Zoom {
        Self.steps.last { $0.value < value - Self.tolerance } ?? Self(clamping: Bounds.range.lowerBound)
    }

    public var canZoomIn: Bool { zoomedIn != self }
    public var canZoomOut: Bool { zoomedOut != self }

    /// The zoom one `step` away.
    public func stepped(_ step: ZoomStep) -> Zoom {
        switch step {
        case .zoomIn: zoomedIn
        case .zoomOut: zoomedOut
        }
    }

    /// A pinch that ends within this of a step counts as that step.
    private static let tolerance = 0.005
}

/// Zoom In and Zoom Out, in the View menu and on the toolbar.
public enum ZoomStep: Hashable, Sendable, CaseIterable {
    case zoomIn, zoomOut
}
