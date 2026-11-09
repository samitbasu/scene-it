/// A click on a sheet's card, counted as the system counts them.
public enum CardClick: Hashable, Sendable {
    case single, double
}

/// How the cards of the Scenes sheet and the File Cabinet take clicks (ADR 0043, 0046), as in the
/// Finder: a single click selects a card at once, so the first click of a double click does too,
/// and a double click opens it.
///
/// A double click opens only the item its first click landed on. A click on a control inside a
/// card never reaches here, so it isn't a first click; if it moved another item under the
/// pointer, the second click on that one counts as a first click and opens nothing. Whatever
/// moves the items forgets the last click.
public struct CardClicks<Item: Hashable & Sendable>: Hashable, Sendable {
    /// The item the last single click landed on, while nothing has moved since.
    public private(set) var last: Item?

    public enum Outcome: Hashable, Sendable {
        case open(Item)
        case select(Item)
    }

    public init() {}

    public mutating func take(_ click: CardClick, on item: Item) -> Outcome {
        if click == .double, last == item { return .open(item) }
        last = item
        return .select(item)
    }

    public mutating func forget() {
        last = nil
    }
}
