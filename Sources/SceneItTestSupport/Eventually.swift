import Testing

/// Gives `condition` a number of polls, not a wall-clock deadline: polls are at least 5 ms apart,
/// so it waits at least 30 s, but while a loaded machine or another test holds the main actor,
/// the work the condition waits for is held too, and that costs one poll instead of the budget.
/// A suite's time limit still ends a real hang.
@MainActor
public func eventually(_ condition: () -> Bool, sourceLocation: SourceLocation = #_sourceLocation) async {
    for _ in 0..<6000 {
        if condition() { return }
        try? await Task.sleep(for: .milliseconds(5))
    }
    if condition() { return }
    Issue.record("the condition never held", sourceLocation: sourceLocation)
}
