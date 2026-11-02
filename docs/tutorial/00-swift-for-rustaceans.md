# 00 — Swift for Rustaceans

You know Rust well. This chapter maps what you already know onto Swift 6, using
Scene It's own types as the examples, and spends most of its words on the places
where the mapping breaks. It isn't a Swift tour: anything that works the way you
would guess is skipped.

The examples come from PLAN [§5.3](../../novel-app-build-bundle/PLAN.md) (the
model sketch) and [§3](../../novel-app-build-bundle/PLAN.md) (architecture),
because no app code exists yet. Later chapters quote real files instead.

**How the snippets were checked.** Every Swift block was extracted from this file
into a scratch SwiftPM package and built with Swift 6.4 in the Swift 6 language
mode (macOS 26 deployment target). Blocks marked `// DOES NOT COMPILE` were
compiled one at a time against the same package and fail with the error quoted
in the block. Rust blocks were built with `cargo build` (serde and serde_json as
the only dependencies). Swift blocks assume `import Foundation`, as every file in
`SceneItCore` will have.

---

## 1. SwiftPM is Cargo

| Cargo | SwiftPM |
| --- | --- |
| `Cargo.toml` | `Package.swift`, written in Swift and evaluated in a sandbox |
| crate | *module* (a target); a *product* is what other packages can depend on |
| `cargo build` / `test` / `run` | `swift build` / `swift test` / `swift run` |
| `edition = "2024"` | `// swift-tools-version: 6.2`; tools version 6.x selects the Swift 6 language mode |
| `#[test]` + `assert!` | Swift Testing: `@Test` + `#expect` / `#require` (XCTest is the older framework) |
| `rustfmt`, `clippy` | `swift format` (ships with the toolchain), plus compiler warnings as errors |
| `[features]` | `swiftSettings: [.enableUpcomingFeature(...)]` for *language* features; no Cargo-style feature flags |

```swift
// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SceneItCore",
    platforms: [.macOS(.v26)],
    products: [.library(name: "SceneItCore", targets: ["SceneItCore"])],
    targets: [
        .target(name: "SceneItCore"),
        .testTarget(name: "SceneItCoreTests", dependencies: ["SceneItCore"]),
    ]
)
```

An `.app` can't be built by SwiftPM alone (see
[decision 0002](../decisions/0002-project-structure.md)). That's why the app is a
thin Xcode target over this package.

**Access control** matters as soon as the app imports `SceneItCore`:

| Rust | Swift |
| --- | --- |
| `pub` | `public` (and `open`, which also allows subclassing or overriding from other modules) |
| `pub(crate)` | `internal`, **the default** |
| — | `package`: visible to other modules in the same package |
| private (module, usually one file) | `fileprivate` |
| — | `private`: the enclosing declaration, plus its extensions in the same file |

A `public struct` does **not** get a public memberwise initializer. If the app
needs to construct it, write `public init(...)` yourself.

```swift
// Tests/SceneItCoreTests/TextColorTests.swift
import Foundation
import Testing

@testable import SceneItCore

@Test func misspelledColorIsRejected() throws {
    let ok = try JSONDecoder().decode(TextColor.self, from: Data(#""purple""#.utf8))
    #expect(ok == .purple)
    #expect(throws: DecodingError.self) {
        try JSONDecoder().decode(TextColor.self, from: Data(#""purpel""#.utf8))
    }
}
```

`@testable import` is the test-only door into `internal` declarations, the way a
Rust `#[cfg(test)] mod tests` can see private items. `#""…""#` is a raw string,
like `r#"…"#`.

---

## 2. Value types and reference types

Swift's split isn't owned versus borrowed. It's **value versus reference**:

- `struct` and `enum` are values. Assignment, argument passing and returning
  copy them. There's no `Copy`/`Clone` distinction and no move-by-default: a
  struct is always implicitly copyable (unless it opts out, see §7.4).
- `class` (and `actor`) are references. Assignment copies a pointer and bumps an
  atomic reference count. Every class reference behaves like an `Arc<T>` whose
  interior is freely mutable, with no `Mutex` and no borrow check.

```rust
#[derive(Clone)]
pub struct Scene {
    pub id: String,
    pub tags: Vec<String>,
}

pub fn clone_demo(original: &Scene) {
    let mut draft = original.clone(); // explicit, and deep: the Vec is copied now
    draft.tags.push("Mara".into());
}
```

```swift
public enum TextColor: String, Codable, CaseIterable, Sendable {
    case black, purple, red, blue, green, gray, pink
}

public struct Run: Codable, Hashable, Sendable {
    public var text: String
    public var italic: Bool? = nil
    public var color: TextColor? = nil
    public var comments: Set<Comment.ID>? = nil

    public init(text: String) { self.text = text }
}

public typealias Paragraph = [Run]

public struct Comment: Codable, Identifiable, Hashable, Sendable {
    public var id: String
    public var color: TextColor
    public var text: String
    public var created: Date
}

public struct Scene: Codable, Identifiable, Sendable {
    public var id: String
    public var title: Paragraph
    public var tags: [String]
    public var body: [Paragraph]
    public var comments: [Comment]
}

func valueSemanticsDemo(_ original: Scene) {
    var draft = original
    draft.tags.append("Mara")
    assert(original.tags.count + 1 == draft.tags.count)
}
```

`var draft = original` is cheap but not free. It copies `Scene`'s inline fields
(here, five buffer pointers) and retains each buffer. No element is copied. The
`tags` buffer is copied only at `append`, because `Array`, `Dictionary`, `Set`
and `String` are **copy-on-write**: before mutating, they check whether their
heap buffer is uniquely referenced and clone it if it isn't. That's
`Rc::make_mut`, applied implicitly on every mutation.

Where the analogy breaks:

- **CoW is a property of those collection types, not of structs.** Your own
  struct is a memberwise copy. A struct with twenty inline `Double`s copies 160
  bytes on every assignment, and a struct holding a `class` reference shares that
  object between copies, so value semantics are only as deep as the fields. To
  give your own type CoW, write it the way the stdlib does:

  ```swift
  final class Storage {
      var words: [String] = []
  }

  struct WordList {
      private var storage = Storage()

      mutating func append(_ word: String) {
          if !isKnownUniquelyReferenced(&storage) {
              let copy = Storage()
              copy.words = storage.words
              storage = copy
          }
          storage.words.append(word)
      }

      var words: [String] { storage.words }
  }
  ```

- **`let` means different things.** `let scene: Scene` freezes the whole value,
  nested arrays included, like an immutable Rust binding. `let store: BookStore`
  (a class) freezes only the *reference*:

  ```swift
  final class Counter {
      var n = 0
  }

  func referenceDemo() {
      let a = Counter()
      let b = a
      b.n += 1
      assert(a.n == 1)
  }
  ```

- **`mutating`** marks a struct method that takes `self` as `inout` (§7.3), the
  same as `&mut self`. Non-mutating methods take `self` by value, conceptually.
  Classes have no `mutating`, because every method can mutate.
- **Identity** exists only for classes: `===` compares references. Structs have
  only `==`, and only if they're `Equatable`.

A naming trap specific to this app: SwiftUI declares a protocol named `Scene`.
Inside `SceneItCore` that's no problem. In the app target, which imports both
SwiftUI and `SceneItCore`, a bare `Scene` is an error:

```swift
// SceneIt (app target)
import SceneItCore
import SwiftUI

typealias ManuscriptScene = SceneItCore.Scene

func titleOf(_ s: ManuscriptScene) -> String { s.title.map(\.text).joined() }
```

```swift
// DOES NOT COMPILE (app target): error: 'Scene' is ambiguous for type lookup in this context
import SceneItCore
import SwiftUI

func ambiguous(_ s: Scene) {}
```

---

## 3. Enums and pattern matching

Swift enums are Rust enums: tagged unions with payloads and exhaustive `switch`.
`Codable` corresponds to serde's derive, synthesized by the compiler instead of a
proc macro.

```rust
use serde::{Deserialize, Serialize};

#[derive(Serialize, Deserialize, Clone, Copy, PartialEq, Eq, Debug)]
#[serde(rename_all = "lowercase")]
pub enum TextColor { Black, Purple, Red, Blue, Green, Gray, Pink }

pub fn decode() -> TextColor {
    serde_json::from_str("\"purple\"").unwrap()
}
```

`enum TextColor: String, Codable, CaseIterable` (§2) does the same. The `: String`
gives each case a *raw value* (by default the case name), `Codable` encodes the
raw value, and `CaseIterable` synthesizes `TextColor.allCases`, which in Rust
takes a crate such as `strum`. Decoding `"purpel"` throws `DecodingError`, which
is the strictness PLAN §5.2 relies on.

Payload enums and `switch`:

```swift
public enum Selection: Sendable {
    case none
    case scene(Scene.ID)
    case comment(scene: Scene.ID, comment: Comment.ID)
}

func describe(_ s: Selection) -> String {
    switch s {
    case .none: "nothing"
    case .scene(let id): "scene \(id)"
    case let .comment(scene, comment): "comment \(comment) in \(scene)"
    }
}
```

`switch` (and `if`) are expressions when every branch is a single expression.
`.none` is resolved against the expected type, so `.purple` alone is a
`TextColor` wherever one is expected.

Differences from serde that matter for `book.json`:

- **Unknown keys are ignored**, and there's no `deny_unknown_fields`. Strictness
  comes from types (enums, non-optional fields) and explicit validation.
- **Optionals are omitted on encode.** A synthesized `Codable` uses
  `encodeIfPresent`, so `Run(text: "x")` encodes as `{"text":"x"}` without
  `"bold": null`. That's serde's `skip_serializing_if = "Option::is_none"` by
  default. A missing key decodes to `nil`.
- Renaming uses a nested `enum CodingKeys: String, CodingKey`, not attributes.
- Enums from Apple's frameworks are usually *non-frozen*: switching over one
  needs `@unknown default:`. That's `#[non_exhaustive]` from the consumer's side.
- Recursive enums need `indirect`, which plays the role of `Box`.

---

## 4. `Optional` is `Option`, but `?` isn't `?`

`T?` is sugar for `Optional<T>`, an ordinary enum with cases `.none` and
`.some(T)`.

| Rust | Swift |
| --- | --- |
| `if let Some(x) = o` | `if let x = o` (or `if let o`, which shadows) |
| `let Some(x) = o else { return None };` | `guard let x = o else { return nil }` |
| `o.unwrap_or(d)` | `o ?? d` |
| `o.unwrap()` | `o!` (traps on `nil`) |
| `o.map(f)` / `o.and_then(f)` | `o.map(f)` / `o.flatMap(f)` |
| `o?` inside a fn returning `Option` | **no direct equivalent**; use `guard let` |

The trap: **`?.` is optional chaining, not early return.** `a?.b` evaluates to
`nil` if `a` is `nil` and the rest of the chain is skipped, but the *expression*
is still optional, and the function keeps running. Rust's `?` leaves the
function.

```swift
struct Book {
    var title: String
    var scenes: [Scene]
}

extension Book {
    func scene(withID id: Scene.ID) -> Scene? {
        scenes.first { $0.id == id }
    }

    func firstCommentText(inScene id: Scene.ID) -> String? {
        scene(withID: id)?.comments.first?.text
    }

    func titleText(ofScene id: Scene.ID) -> String? {
        guard let scene = scene(withID: id) else { return nil }
        return scene.title.map(\.text).joined()
    }

    func tagCount(ofScene id: Scene.ID) -> Int {
        scene(withID: id)?.tags.count ?? 0
    }
}
```

`firstCommentText` is the closest thing to a chain of `?`s, and it only works
because the whole function is one expression. `guard let … else` is the general
early exit. The `else` block must leave the scope (`return`, `throw`, `break`, or
a call to a `Never`-returning function), and the compiler checks that.

```swift
func optionalForms(_ book: Book, _ id: Scene.ID) {
    if let scene = book.scene(withID: id) {
        print(scene.tags)
    }
    if let firstTag = book.scene(withID: id)?.tags.first, firstTag.hasPrefix("M") {
        print(firstTag)
    }
    let upper: String? = book.titleText(ofScene: id).map { $0.uppercased() }
    _ = upper
}
```

About traps: `!`, an out-of-bounds index, `fatalError` and **integer overflow**
all trap, and they do so in optimized builds too. Arithmetic is checked in
release, unlike Rust's wrapping release default. Use `&+`, `&-` and `&*` for
wrapping. A trap kills the process and there's no `catch_unwind`, so in this app
every trap is a crash report (chapter 11).

---

## 5. Protocols are traits, mostly

```rust
pub struct SearchHit { pub scene: String, pub paragraph: usize }

pub trait SearchIndex {
    fn index(&mut self, scenes: &[String]);
    fn search(&self, query: &str) -> Vec<SearchHit>;
}

pub fn make_index() -> impl SearchIndex { Keyword(Vec::new()) }
pub fn count(index: &impl SearchIndex, q: &str) -> usize { index.search(q).len() }
pub struct Store { pub search: Box<dyn SearchIndex> }

struct Keyword(Vec<String>);
impl SearchIndex for Keyword {
    fn index(&mut self, scenes: &[String]) { self.0 = scenes.to_vec(); }
    fn search(&self, q: &str) -> Vec<SearchHit> {
        self.0.iter().filter(|s| s.contains(q))
            .map(|s| SearchHit { scene: s.clone(), paragraph: 0 }).collect()
    }
}
```

```swift
public struct SearchHit: Hashable, Sendable {
    public var scene: Scene.ID
    public var paragraph: Int
}

public protocol SearchIndex {
    mutating func index(_ scenes: [Scene])
    func search(_ query: String) -> [SearchHit]
}

public struct KeywordSearch: SearchIndex {
    private var scenes: [Scene] = []
    public init() {}

    public mutating func index(_ scenes: [Scene]) { self.scenes = scenes }

    public func search(_ query: String) -> [SearchHit] {
        scenes.flatMap { scene in
            scene.body.enumerated().compactMap { i, paragraph in
                paragraph.contains { $0.text.localizedCaseInsensitiveContains(query) }
                    ? SearchHit(scene: scene.id, paragraph: i) : nil
            }
        }
    }
}

func makeIndex() -> some SearchIndex { KeywordSearch() }

func count(in index: some SearchIndex, _ q: String) -> Int { index.search(q).count }

func countGeneric<I: SearchIndex>(in index: I, _ q: String) -> Int { index.search(q).count }

final class StoreSketch {
    var search: any SearchIndex = KeywordSearch()

    func reindex(_ scenes: [Scene]) {
        search.index(scenes)
    }
}
```

- **`some P` is `impl Trait`**, in both positions. As a parameter it's an
  anonymous generic parameter (`count` and `countGeneric` are the same function).
  As a return type it's an opaque type fixed by the implementation.
- **`any P` is `dyn Trait`**, but it's a value, not something behind a pointer. An
  existential is an inline three-word buffer plus type metadata and a witness
  table, and it heap-allocates only when the value doesn't fit. It has value
  semantics if the underlying type does, so `search.index(...)` mutates the
  existential in place. There's no `Box`.
- Write `any` every time. Swift 6 doesn't yet require it for every protocol: bare
  `Hashable` as a type produces "use of protocol 'Hashable' as a type must be
  written 'any Hashable'; this will be an error in a future Swift language mode",
  and bare `CustomStringConvertible` produces no diagnostic at all. The
  `ExistentialAny` upcoming feature will make it mandatory.
- **No object safety.** Protocols with associated types or `Self` requirements
  can still be existentials. Members that mention an associated type become
  unavailable or type-erased on `any P`. Passing an `any P` to a `some P`
  parameter *opens* the existential, so the generic function sees the concrete
  type.
- **Generics aren't monomorphized by default.** Unspecialized generic code
  receives type metadata and witness tables at runtime (dictionary passing,
  closer to `dyn` without the box), and the optimizer specializes where it can
  see the body. Across module boundaries that requires `@inlinable`. This affects
  performance, never semantics.

Associated types and constrained existentials look the way you'd expect.
*Primary* associated types (`Archive<Entry>`) let you write `any Archive<E>`, the
analogue of `dyn Iterator<Item = E>`:

```swift
public protocol Archive<Entry> {
    associatedtype Entry: Identifiable
    func entries() -> [Entry]
}

func newest<E>(_ archive: any Archive<E>) -> E? { archive.entries().last }
```

Conditional conformance works like `impl<T: WordCountable> WordCountable for
Vec<T>`:

```swift
protocol WordCountable { var wordCount: Int { get } }

extension Run: WordCountable {
    var wordCount: Int { text.split(whereSeparator: \.isWhitespace).count }
}

extension Array: WordCountable where Element: WordCountable {
    var wordCount: Int { reduce(0) { $0 + $1.wordCount } }
}

func paragraphWords(_ p: Paragraph) -> Int { p.wordCount }
```

**The dispatch gotcha.** Default implementations live in `extension P { ... }`.
A method that's a *requirement* (declared in the protocol body) dispatches
dynamically through the witness table. A method that exists *only* in the
extension dispatches statically, on the static type:

```swift
protocol Greeter {
    func required() -> String
}

extension Greeter {
    func required() -> String { "default" }
    func extra() -> String { "extension" }
}

struct Loud: Greeter {
    func required() -> String { "LOUD" }
    func extra() -> String { "LOUD EXTRA" }
}

func dispatchDemo() {
    let g: any Greeter = Loud()
    assert(g.required() == "LOUD")
    assert(g.extra() == "extension")
}
```

`Loud.extra` doesn't override anything. It shadows the extension method, and the
existential never sees it. Rust has no equivalent footgun, because trait methods
are either in the trait or not callable through `dyn`. Rule: if conformers may
customize it, declare it in the protocol body.

---

## 6. Errors: `throws` is not `Result`

```rust
#[derive(Debug)]
pub enum LoadError { Malformed(serde_json::Error), UnknownComment { scene: String, comment: String } }

impl From<serde_json::Error> for LoadError {
    fn from(e: serde_json::Error) -> Self { LoadError::Malformed(e) }
}

pub fn load(data: &str) -> Result<Vec<String>, LoadError> {
    let tags: Vec<String> = serde_json::from_str(data)?;
    Ok(tags)
}
```

Swift functions are marked `throws`, and every call site of a throwing function
is marked `try`. That's like `?` in that it propagates, and unlike `?` in that
there's no `From`-based conversion. By default the error type is **untyped**: a
plain `throws` throws `any Error`, an existential of the `Error` protocol, and
callers can't match it exhaustively.

Swift 6 added **typed throws**, `throws(E)`:

```swift
public enum LoadError: Error {
    case unreadable(URL, underlying: any Error)
    case malformed(underlying: any Error)
    case unknownComment(scene: Scene.ID, comment: Comment.ID)
}

func decodeScene(_ data: Data) throws(LoadError) -> Scene {
    do {
        return try JSONDecoder().decode(Scene.self, from: data)
    } catch {
        throw .malformed(underlying: error)
    }
}

func validate(_ scene: Scene) throws(LoadError) {
    let known = Set(scene.comments.map(\.id))
    for paragraph in scene.body {
        for run in paragraph {
            for id in run.comments ?? [] where !known.contains(id) {
                throw .unknownComment(scene: scene.id, comment: id)
            }
        }
    }
}

func loadScene(_ data: Data) throws(LoadError) -> Scene {
    let scene = try decodeScene(data)
    try validate(scene)
    return scene
}

func caller(_ data: Data) {
    do {
        let scene = try loadScene(data)
        print(scene.id)
    } catch {
        switch error {
        case .malformed(let underlying): print("bad JSON: \(underlying)")
        case .unknownComment(_, let c): print("dangling comment \(c)")
        case .unreadable: print("unreadable")
        }
    }
    let maybe: Scene? = try? loadScene(data)
    let result: Result<Scene, LoadError> = Result { () throws(LoadError) in try loadScene(data) }
    _ = (maybe, result)
}
```

Points that aren't obvious:

- `JSONDecoder.decode` throws untyped, so `decodeScene` has to catch and wrap the
  error. That's the hand-written `From`. Nothing converts automatically.
- `do`/`catch` **infers** the thrown type when every `try` in the body throws the
  same type, so in `caller`, `error` is a `LoadError` and the `switch` is
  exhaustive. With an untyped `throws` the same `switch` fails, because `error`
  is `any Error`. (With Foundation imported, the diagnostic names an internal
  protocol instead of `any Error`. Without Foundation it reads "type 'any Error'
  has no member 'bad'".)

  ```swift
  // DOES NOT COMPILE: error: type '_ErrorCodeProtocol' has no member 'bad'
  enum UntypedLoadError: Error { case bad, worse }
  func untypedLoad() throws -> Int { throw UntypedLoadError.bad }
  func untypedCaller() {
      do { _ = try untypedLoad() } catch {
          switch error {
          case .bad: break
          case .worse: break
          }
      }
  }
  ```

- **Closures don't infer typed throws.** `Result { try loadScene(data) }` fails
  with "invalid conversion of thrown error type 'any Error' to 'LoadError'". The
  closure needs the explicit `() throws(LoadError) in` shown above.
- `try?` turns any error into `nil`, discarding it. In this app's trust code
  (loading, saving, archiving) that's almost always wrong. `try!` traps.
- `throws(Never)` means non-throwing and `throws(any Error)` means plain
  `throws`, so a generic `throws(E)` replaces most uses of the older `rethrows`.
- The Swift Evolution proposal (SE-0413) recommends untyped `throws` as the
  default, and typed throws where the error set is closed and callers will
  handle it exhaustively. Chapter 02 decides which `SceneItCore` uses.
- `defer { … }` runs at scope exit on every path. It's the usual stand-in for a
  scope guard.

---

## 7. Memory: ARC, exclusivity, and the closest thing to moves

### 7.1 ARC and cycles

Every class instance is reference-counted, and the compiler inserts the retains
and releases. That's `Arc` everywhere, implicit, and with the same weakness: **a
cycle leaks.** The usual cycle in UI code is an object that stores a closure that
captures the object:

```swift
final class Autosaver {
    var onFire: (() -> Void)?
}

final class SaveCoordinator {
    let autosaver = Autosaver()
    var saves = 0

    func wireUpLeaky() {
        autosaver.onFire = { self.saves += 1 }
    }

    func wireUp() {
        autosaver.onFire = { [weak self] in
            guard let self else { return }
            saves += 1
        }
    }
}
```

`wireUpLeaky` forms the cycle self → autosaver → closure → self. (A test in the
verification package confirmed that the coordinator outlives its last external
reference after `wireUpLeaky` and is freed after `wireUp`.) The capture list
`[weak self]` captures a `Weak<Self>`, and `guard let self` is `upgrade()`.

- `weak var x: T?` is always optional and becomes `nil` when the object dies.
  Delegates are `weak` by convention, which is why delegate protocols are
  constrained to `AnyObject` (classes only):

  ```swift
  protocol EditorDelegate: AnyObject {
      func editorDidChange()
  }

  final class Editor {
      weak var delegate: (any EditorDelegate)?
  }
  ```

- `unowned let x: T` is a non-optional weak reference that **traps** if it's used
  after the object dies. Use it only when the referent provably outlives the
  holder (a child pointing at its owner). `unowned(unsafe)` is a raw pointer,
  undefined behaviour after the referent is freed.

  ```swift
  final class SceneCard {
      unowned let owner: SaveCoordinator
      init(owner: SaveCoordinator) { self.owner = owner }
  }
  ```

- **Lifetimes end at last use, not at end of scope.** `deinit` runs when the last
  strong reference is released, and the optimizer may release a local right after
  its last use. RAII guards of the form `let guard = Lock(); doWork()` aren't
  reliable. Use `defer`, a `with…` closure API, or `withExtendedLifetime(x) { … }`.
  Rust's drop-at-scope-end has no equivalent for classes.

### 7.2 Structs inside classes

A struct stored in a class property is mutated in place through the class:
`store.book.scenes[0].tags.append("x")` doesn't copy the `Scene`. Element access
through subscripts and properties uses a `_modify` coroutine (like a `&mut`
yielded briefly), and the CoW buffers are uniquely referenced. Copying out first
(`var s = store.book.scenes[0]`) makes a second reference to the buffers, and the
next mutation of `s` copies them.

### 7.3 No borrow checker, but a law of exclusivity

Swift has no lifetimes and you can't hold a reference into an array. What it has
is the **law of exclusivity**: a *modification* of a variable (an `inout`
argument, a `mutating` call, an assignment) needs exclusive access for its whole
duration. Overlapping accesses are rejected at compile time when the compiler can
see them:

```swift
func appendTag(_ tag: String, to scene: inout Scene) {
    scene.tags.append(tag)
}

func inoutDemo(_ book: inout Book) {
    appendTag("Mara", to: &book.scenes[0])
    book.scenes.swapAt(0, 1)
}
```

```swift
// DOES NOT COMPILE: error: overlapping accesses to 'tags', but modification requires exclusive access; consider calling MutableCollection.swapAt(_:_:)
func exclusivityError() {
    var tags = ["opening", "Mara"]
    swap(&tags[0], &tags[1])
}
```

`inout` reads as `&mut` and is specified as copy-in/copy-out. It can therefore
bind a computed property (get, mutate, set), and the compiler passes a pointer
when the storage is addressable.

When the compiler *can't* prove exclusivity (class properties, globals, captures
in escaping closures), it inserts **runtime checks**, and they stay on in release
builds. This compiles and then traps with "Simultaneous accesses to 0x…, but
modification requires exclusive access":

```swift
final class Holder { var tags = ["a"] }

func modify(_ tags: inout [String], _ holder: Holder) {
    holder.tags.append("x")
    tags.append("y")
}

func runtimeExclusivityTrap() {
    let h = Holder()
    modify(&h.tags, h)
}
```

In Rust the equivalent can't be written without `RefCell`, and `RefCell` panics
in the same place. Swift treats every class property as an implicit
`RefCell` for `inout` purposes.

### 7.4 `~Copyable`: real move semantics

Since Swift 5.9 a type can opt out of implicit copying with `~Copyable`. That's
an affine type, which is Rust's default:

```swift
struct SaveTicket: ~Copyable {
    let generation: Int

    consuming func commit() -> Int {
        generation
    }
}

func issueTicket(_ generation: Int) -> SaveTicket { SaveTicket(generation: generation) }

func inspect(_ ticket: borrowing SaveTicket) -> Int { ticket.generation }

func moveDemo() {
    let a = issueTicket(1)
    _ = inspect(a)
    let b = a
    _ = b.commit()
}
```

```swift
// DOES NOT COMPILE: error: 'ticket' consumed more than once
func doubleCommit() {
    let ticket = issueTicket(7)
    _ = ticket.commit()
    _ = ticket.commit()
}
```

- `borrowing` is `&T`, `consuming` is by-value `T`, and `inout` is `&mut T`.
  These parameter modifiers also work on copyable types, where they're
  performance hints.
- A `~Copyable` struct can have a `deinit` (like `Drop`), and a `consuming`
  method can end with `discard self` to skip it, like `mem::forget`.
- The `consume x` operator ends a *local's* lifetime, even for a copyable type,
  like an explicit `drop` or a move into a new binding. It can't be applied to a
  stored property of a copyable type ("'consume' can only be used to partially
  consume storage of a noncopyable type").
- Support is still partial. Generics and `Optional` accept noncopyable types
  (`<T: ~Copyable>`), but `Array`, `Dictionary` and most of the standard library
  don't:

  ```swift
  // DOES NOT COMPILE: error: type 'SaveTicket' does not conform to protocol 'Copyable'
  let tickets: [SaveTicket] = []
  ```

You'll rarely need `~Copyable` in app code. Know that it exists for
use-once tokens.

---

## 8. Concurrency: `Sendable`, actors, `@MainActor`

### 8.1 `Sendable` is not `Send + Sync`

`Sendable` is a single marker protocol meaning "safe to pass across isolation
domains". There's no separate `Sync`: sending a class reference *is* sharing it,
so for reference types `Sendable` means roughly `Send + Sync`.

| | Rust | Swift |
| --- | --- | --- |
| Inference | auto trait, inferred structurally, leaks through `pub` | inferred structurally **only for non-`public`** structs and enums; a `public` type must declare `Sendable` |
| Escape hatch | `unsafe impl Send` | `@unchecked Sendable` |
| Classes | — | `final`, and every stored property a `let` of `Sendable` type; otherwise `@unchecked` |
| Enforcement | always | Swift 6 language mode: errors; Swift 5 mode: optional warnings |

That's why the model types in §2 say `Sendable` explicitly: they're `public` so
the app can use them, and public types get no inference. An internal type with
the same fields would be inferred `Sendable`:

```swift
struct InternalSnapshot {
    var scenes: [Scene]
}

func sendInternal(_ s: InternalSnapshot) async {
    await Task.detached { print(s.scenes.count) }.value
}
```

```swift
// DOES NOT COMPILE: error: passing closure as a 'sending' parameter risks causing data races between code in the current isolation context and concurrent execution of the closure
public struct PublicSnapshot { public var tags: [String] }
func sendPublic(_ s: PublicSnapshot) async {
    await Task.detached { print(s.tags.count) }.value
}
```

```swift
final class LaunchRecord: Sendable {
    let started: Date
    init(started: Date) { self.started = started }
}

final class LegacyCache: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [String: Data] = [:]

    func insert(_ data: Data, for key: String) {
        lock.withLock { entries[key] = data }
    }
}
```

**Region-based isolation** goes beyond Rust in one respect. The compiler tracks
*regions* of non-`Sendable` values, and lets you send a non-`Sendable` value to
another isolation domain if it's provably disconnected and unused afterwards. If
`sendPublic` above constructs `PublicSnapshot` locally instead of taking it as a
parameter, it compiles. Use the value again after the send and it fails ("sending
value of non-Sendable type … risks causing data races"). It's a move of a
non-thread-safe value, which Rust allows only if the type is `Send`. The `sending`
keyword on parameters and results is how APIs express it.

### 8.2 Actors

An `actor` is a class whose mutable state is reachable only on its own serial
executor. Calls from outside are `async` and must be `await`ed, and their
arguments and results must be `Sendable` (or `sending`):

```swift
public struct BookSnapshot: Sendable {
    public var scenes: [Scene]
}

actor BackupWriter {
    private var written = 0

    func write(_ snapshot: BookSnapshot, to url: URL) throws {
        let data = try JSONEncoder().encode(snapshot.scenes)
        try data.write(to: url, options: .atomic)
        written += 1
    }

    var count: Int { written }
}
```

Think of it as a task that owns its state behind an `mpsc` channel, with the
compiler writing the message enum and the `await` on the reply.

### 8.3 `@MainActor`: thread confinement, checked

`@MainActor` is a *global actor*: annotating a type puts all its members on the
main thread's executor. PLAN §3 makes `BookStore` `@MainActor`. The Rust analogue
is a `!Send` type confined to the UI thread, with one difference: in Swift you can
*hold* a reference anywhere (a `@MainActor` class is implicitly `Sendable`), and
the compiler checks each *access*:

```swift
import Observation

@MainActor
@Observable
final class BookStore {
    var scenes: [Scene] = []
    private(set) var lastSaved: [Scene] = []
    var lastError: (any Error)?
    @ObservationIgnored private let writer = BackupWriter()

    func saveBuggy(to url: URL) async throws {
        try await writer.write(BookSnapshot(scenes: scenes), to: url)
        lastSaved = scenes
    }

    func save(to url: URL) async throws {
        let snapshot = scenes
        try await writer.write(BookSnapshot(scenes: snapshot), to: url)
        lastSaved = snapshot
    }
}

nonisolated func offMain(_ store: BookStore) async -> Int {
    await store.scenes.count
}
```

```swift
// DOES NOT COMPILE: error: main actor-isolated property 'scenes' can not be referenced from a nonisolated context
nonisolated func peek(_ store: BookStore) -> Int { store.scenes.count }
```

### 8.4 Reentrancy, the big one

`saveBuggy` compiles cleanly and is wrong. **An actor gives up isolation at every
`await`.** While `writer.write` runs, the main actor is free: the author keeps
typing, a menu command fires, and `scenes` changes. After the `await`, `lastSaved =
scenes` records text that was never written, the book looks clean, and the next
autosave is skipped. `save` captures the snapshot first and records exactly what
was written.

In Rust, `async fn save(&mut self)` holds the exclusive borrow across `.await`, so
nothing else can touch the store until the future completes. The borrow checker
makes this bug unrepresentable. Swift actors aren't locks, and their guarantee is
weaker:

- **Synchronous stretches are atomic.** Between two `await`s, no other code runs
  on that actor.
- **Every `await` is a point where any invariant may have been broken.**
  Re-validate state after it, or capture what you need before it.
- Two concurrent calls to the same actor method can interleave at their awaits.
  If an operation mustn't overlap itself (saving), track that in state
  (`enum SaveState { case idle, saving }`), not in the shape of the code.

### 8.5 Tasks and isolation defaults

- `Task { … }` is roughly `tokio::spawn`, except that it **inherits the current
  actor**: a `Task` created in a `@MainActor` method runs its body on the main
  actor. `Task.detached` doesn't inherit. Structured forms are `async let` and
  `withTaskGroup`. Cancellation is cooperative (`try Task.checkCancellation()`),
  like dropping a future, except that the task keeps running until it checks.
- Swift 6.4 warns when a throwing `Task` is discarded unused ("unstructured
  throwing task … is not used, which may accidentally ignore errors"). Handle the
  error inside the task:

  ```swift
  @MainActor
  func useStore(_ store: BookStore, _ url: URL) {
      Task {
          do {
              try await store.save(to: url)
          } catch {
              store.lastError = error
          }
      }
  }
  ```

- Where a `nonisolated async` function runs depends on the build settings. In
  plain Swift 6 mode it runs on the global concurrent executor, even when it's
  called from the main actor (verified). With the upcoming feature
  `NonisolatedNonsendingByDefault` it runs on the caller's actor. A target can
  also set `.defaultIsolation(MainActor.self)`, which makes unannotated code
  `@MainActor`. Chapter 01 records which settings Scene It uses. Until you've
  read it, don't assume either way.

### 8.6 `Duration`

The standard library's `Duration` (`.seconds(2)`, `.milliseconds(250)`) is
`core::time::Duration`, and `ContinuousClock` and `SuspendingClock` play the role
of `Instant`. Foundation's `TimeInterval` is a `typealias` for `Double`, which is
exactly the naked float CLAUDE.md bans. Keep `Duration` everywhere and convert at
the API boundary:

```swift
struct AutosavePolicy {
    var idle: Duration = .seconds(2)
    var maxInterval: Duration = .seconds(30)
}

func waitIdle(_ policy: AutosavePolicy) async throws {
    try await Task.sleep(for: policy.idle)
}

func timeInterval(_ d: Duration) -> TimeInterval { d / .seconds(1) }
```

`Duration / Duration` yields a `Double` ratio (2.5 for 2500 ms / 1 s).

---

## 9. Extensions, and no orphan rule

`extension T { … }` adds methods, computed properties, initializers, nested types
and protocol conformances to *any* type, including ones from other modules. It's
an inherent `impl` and a trait `impl` in one construct, and it never adds stored
properties.

```swift
extension Scene {
    var wordCount: Int { body.wordCount }

    func hasTag(_ tag: String) -> Bool { tags.contains(tag) }

    enum Section { case title, body, notes }
}

extension TextColor: CustomStringConvertible {
    public var description: String { rawValue.capitalized }
}

extension Collection where Element == Scene {
    func tagged(_ tag: String) -> [Scene] { filter { $0.hasTag(tag) } }
}
```

- Methods added to a foreign type (`Collection`) need no extension trait and no
  `use`. They're visible wherever your module is imported.
- **There's no orphan rule.** You may conform a type you don't own to a protocol
  you don't own. Rust forbids this to keep coherence, and Swift permits it at the
  cost of coherence: if Foundation later adds the same conformance, which one
  wins at runtime is unspecified. Swift 6 warns ("extension declares a
  conformance of imported type 'URL' to imported protocol 'Identifiable'; this
  will not behave correctly if the owners of 'Foundation' introduce this
  conformance in the future"), and `@retroactive` acknowledges the risk and
  silences the warning:

  ```swift
  extension URL: @retroactive Identifiable {
      public var id: String { absoluteString }
  }
  ```

  Prefer the Rust answer, a wrapper type, unless you have a reason not to.

---

## 10. Property wrappers and macros

### 10.1 Property wrappers

A property wrapper is a type with a `wrappedValue`, and `@Wrapper var x` desugars
into a hidden stored `_x: Wrapper` plus an accessor that forwards to it. An
optional `projectedValue` is reachable as `$x`:

```swift
@propertyWrapper
struct Trimmed {
    private var value = ""
    var wrappedValue: String {
        get { value }
        set { value = newValue.trimmingCharacters(in: .whitespacesAndNewlines) }
    }
    var projectedValue: Bool { value.isEmpty }
    init(wrappedValue: String) { self.wrappedValue = wrappedValue }
}

struct TagEditor {
    @Trimmed var draft: String = ""

    func canCommit() -> Bool { !$draft }
}
```

SwiftUI's `@State`, `@Binding` and `@Environment` are property wrappers, and
`$name` there projects a `Binding`. Rust has no direct analogue. The nearest is
a newtype with `Deref`, but the wrapper is invisible to the property's users.

That invisibility is why CLAUDE.md prefers newtypes for constrained values. The
`Trimmed` guarantee lives on the *property*. As soon as `draft` is passed to a
`func f(_ s: String)`, it's a plain `String` again. A `TagName` newtype carries
the guarantee through every signature.

### 10.2 Macros

Swift macros are compiler plugins built on `swift-syntax`, run in a sandboxed
separate process, and they see syntax, not types. That's a proc macro.
*Freestanding* macros start with `#` (`#expect`, `#Preview`). *Attached* macros
use `@` and look like attributes, so check the docs to tell `@Observable` (a
macro) from `@State` (a property wrapper).

`@Observable` on `BookStore` (§8.3) is the important one. It rewrites the class.
Here's the real expansion for `@Observable final class Probe { var title = "" }`, trimmed (dump it with
`-Xfrontend -dump-macro-expansions`, or use *Expand Macro* in Xcode):

```text
@ObservationIgnored private let _$observationRegistrar = Observation.ObservationRegistrar()

@ObservationIgnored private var _title = ""

var title {
    get {
        access(keyPath: \.title)          // registers a read with any active tracker
        return _title
    }
    set {
        guard shouldNotifyObservers(_title, newValue) else { _title = newValue; return }
        withMutation(keyPath: \.title) { _title = newValue }
    }
    _modify { … willSet … yield &_title … didSet … }
}

extension Probe: nonisolated Observation.Observable {}
```

Every stored property becomes a computed property that reports reads and writes
to a registrar. SwiftUI records which properties a view's `body` *read* and
re-renders the view when one of them is *written*. Two consequences:

- `@ObservationIgnored` opts a property out. Use it for collaborators that aren't
  UI state (the `writer` above).
- For `Equatable` properties, assigning an equal value doesn't notify (that's the
  `shouldNotifyObservers` overload). Mutating an array in place goes through
  `_modify` and always notifies.

Chapter 04 covers how SwiftUI consumes this.

---

## 11. Strings are not `&str`

`String` is Unicode-correct and indexed by `String.Index`, not by integers.
`count` counts grapheme clusters, which is O(n). There are three views, and
AppKit uses the third:

```swift
func stringsDemo() {
    let title = "Café 👩‍👩‍👧"
    assert(title.count == 6)
    assert(title.utf8.count == 24)
    assert(title.utf16.count == 13)

    let i = title.index(title.startIndex, offsetBy: 3)
    assert(title[i] == "é")
    let prefix: Substring = title[..<i]
    let owned = String(prefix)
    _ = owned

    let range = title.range(of: "é")!
    let ns = NSRange(range, in: title)
    assert(ns.location == 3 && ns.length == 1)
    let back = Range(ns, in: title)
    assert(back == range)
}
```

`NSString`, `NSAttributedString`, `NSRange` and therefore all of `NSTextView`
count **UTF-16 code units**. Convert with `NSRange(_:in:)` and `Range(_:in:)`
rather than doing arithmetic on offsets. This matters again in the RunCodec
(chapter 06) and in search highlighting (chapter 08). `Substring` is `&str`-like:
it shares storage with its base and keeps it alive. Convert it to `String` before
storing it.

---

## 12. CLAUDE.md's rules in Swift

**No naked `Bool` parameters.** Argument labels make call sites readable
(`setRightPanel(open: true)`), but they don't survive into function types or
closures, and the type still admits any `Bool`. Use a two-case enum:

```swift
enum PanelVisibility { case open, closed }

func setRightPanel(_ visibility: PanelVisibility) { _ = visibility }

func rulesCallSite() {
    setRightPanel(.open)
}
```

(The `Bool?` fields on `Run` are data in a serialized schema, not parameters.)

**No naked `Double`/`Float` parameters.** Write a newtype that enforces its
constraint in the initializer, implements its operators once, and converts out
explicitly. Rust's `impl From<Zoom> for f64` becomes an initializer on `Double`:

```swift
struct Zoom: Comparable, Sendable {
    static let range: ClosedRange<Double> = 0.5...3.0
    let value: Double

    init(_ raw: Double) {
        value = raw.isNaN ? 1.0 : min(max(raw, Self.range.lowerBound), Self.range.upperBound)
    }

    static func < (a: Zoom, b: Zoom) -> Bool { a.value < b.value }

    static func * (a: Zoom, step: ZoomStep) -> Zoom { Zoom(a.value * step.factor) }
}

struct ZoomStep: Sendable {
    let factor: Double
    static let `in` = ZoomStep(factor: 1.1)
    static let out = ZoomStep(factor: 1 / 1.1)
}

extension Double {
    init(_ zoom: Zoom) { self = zoom.value }
}

func zoomDemo() -> Double {
    Double(Zoom(1.0) * .in * .in)
}
```

For a newtype that has to appear in `book.json` as a bare number (serde's
`#[serde(transparent)]`), conform it to `RawRepresentable` with a `Codable` raw
value, and the standard library supplies the `Codable` implementation:

```swift
struct ZoomSetting: RawRepresentable, Codable, Sendable {
    let rawValue: Double
    init(rawValue: Double) { self.rawValue = min(max(rawValue, 0.5), 3.0) }
}
```

(Encoding `ZoomSetting(rawValue: 9)` inside a struct gives `{"zoom":3}`. Whether
decoding should clamp or *reject* an out-of-range value is a strict-decoding
question for chapter 02.)

**Durations are `Duration`.** See §8.6. `TimeInterval` appears only at
Foundation and AppKit call sites.

**Illegal states unrepresentable.** Swift enums with payloads, and `Optional` of a
struct, are the tools, the same as in Rust:

```swift
enum SaveState: Sendable {
    case clean
    case dirty(since: ContinuousClock.Instant)
    case saving
    case failed(reason: String)
}

struct Press { var origin: CGPoint }

struct DragTracker {
    var press: Press?
}
```

**Zero warnings.** `scripts/check.sh` builds with warnings as errors
([decision 0008](../decisions/0008-local-ci.md)). Several of the diagnostics
quoted above (`ExistentialAny`, retroactive conformance, unused throwing `Task`)
are warnings, so they fail the gate too.

---

## 13. Cheat sheet

| Rust | Swift | Note |
| --- | --- | --- |
| `struct` (move) | `struct` (implicit copy) | collections are CoW (§2) |
| `Arc<T>` (+ interior mutability) | `final class` | ARC; cycles leak (§7.1) |
| `Weak<T>` | `weak var` / `unowned let` | |
| `&mut T` | `inout T` / `mutating` | law of exclusivity (§7.3) |
| move-only type | `~Copyable`, `consuming`, `borrowing` | partial stdlib support (§7.4) |
| `Option<T>` | `T?` | `?.` doesn't return early (§4) |
| `Result<T, E>` + `?` | `throws` / `throws(E)` + `try` | no `From` (§6) |
| `panic!` | trap (`fatalError`, `!`, overflow) | no unwinding |
| `trait` | `protocol` | extension-only methods dispatch statically (§5) |
| `impl Trait` | `some P` | |
| `dyn Trait` | `any P` | inline existential, no object safety (§5) |
| `impl Foo for Bar` | `extension Bar: Foo` | no orphan rule (§9) |
| `Send` / `Sync` | `Sendable` | not inferred for `public` types (§8.1) |
| `!Send` + UI thread | `@MainActor` | reentrant at `await` (§8.4) |
| `tokio::spawn` | `Task { }` | inherits the actor (§8.5) |
| `Duration` | `Duration` | `TimeInterval` is a `Double` (§8.6) |
| proc macro | macro (`@Observable`, `#expect`) | |
| `serde` derive | `Codable` | ignores unknown keys (§3) |
| `&str` byte indexing | `String.Index`; UTF-16 for AppKit | (§11) |
| Cargo | SwiftPM | (§1) |
