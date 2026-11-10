import AppKit
import Darwin
import SceneItCore
import SceneItTestSupport
import Synchronization
import Testing

@testable import SceneIt

/// ADR 0049: pasting HTML never touches the network. The HTML importer is WebKit's, and pasted
/// HTML can name images, style sheets and frames on a server; none of them is fetched.
@MainActor
@Suite(.serialized, .timeLimit(.minutes(2)))
struct HTMLPasteTests {
    @Test func pastedHTMLFetchesNothingItReferences() async throws {
        let server = try LoopbackServer()
        defer { server.stop() }
        try server.expectReachable()
        URLProtocol.registerClass(RequestRecorder.self)
        defer { URLProtocol.unregisterClass(RequestRecorder.self) }
        RequestRecorder.reset()

        let html = Data(Self.html(referencing: server.port).utf8)
        let imported = try #require(NSAttributedString(html: html, documentAttributes: nil))
        #expect(
            imported.string.filter { $0 == "\u{FFFC}" }.count >= 3,
            "precondition: the importer read the three images")

        try await withPage([scene("One", [[Run("Start.")]])]) { page in
            try await PageHarness.withPasteboard { pasteboard in
                pasteboard.clearContents()
                pasteboard.setData(html, forType: .html)
                page.focusPage(at: 6)
                #expect(page.page.readSelection(from: pasteboard, type: .html))
                #expect(page.storage.string.contains("Bold and italic"), "precondition: the HTML was pasted")
                try await Task.sleep(for: .seconds(2))
            }
        }
        #expect(server.connections == 0, "no connection reached the server")
        // The recorder hears the whole test host, where other tests load pages of their own; a
        // request the paste could have caused names one of the pasted HTML's origins.
        let origins = Self.origins(port: server.port)
        let pasted = RequestRecorder.urls.filter { url in origins.contains { url.hasPrefix($0 + "/") } }
        #expect(pasted == [], "no request was made to anything the HTML names")
    }

    /// Every kind of reference a page can make, each at the loopback server: a style sheet, an
    /// imported one, a background, images over HTTPS and HTTP, by address and by host name, a
    /// frame and a script.
    static func html(referencing port: UInt16) -> String {
        let named = origins(port: port)
        let (https, http, plain) = (named[0], named[1], named[2])
        return """
            <html><head>
            <link rel="stylesheet" href="\(https)/sheet.css">
            <style>@import url("\(http)/imported.css"); p { background: url("\(https)/bg.png") }</style>
            <script src="\(https)/script.js"></script>
            </head><body><p><b>Bold</b> and <i>italic</i>
            <img src="\(https)/a.png"> <img src="\(http)/b.png"> <img src="\(plain)/c.png">
            <iframe src="\(https)/frame.html"></iframe></p></body></html>
            """
    }

    /// Every origin the pasted HTML names: the loopback server, by address and by host name.
    static func origins(port: UInt16) -> [String] {
        ["https://127.0.0.1:\(port)", "http://localhost:\(port)", "http://127.0.0.1:\(port)"]
    }
}

/// Records every request the URL loading system is asked to make in this process, and handles
/// none of them.
private nonisolated final class RequestRecorder: URLProtocol {
    private static let seen = Mutex<[String]>([])

    static var urls: [String] { seen.withLock { $0 } }

    static func reset() {
        seen.withLock { $0 = [] }
    }

    override class func canInit(with request: URLRequest) -> Bool {
        seen.withLock { $0.append(request.url?.absoluteString ?? "") }
        return false
    }
}

/// A TCP server on the loopback interface that counts the connections it accepts from any
/// process, and answers each with 404. `stop()` returns once its thread has ended.
private nonisolated final class LoopbackServer: Sendable {
    let port: UInt16
    private let socketFD: Int32
    private let accepted = Mutex(0)
    private let stopping = Mutex(false)
    private let ended = DispatchSemaphore(value: 0)

    var connections: Int { accepted.withLock { $0 } }

    init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ServerError.socket }
        var address = Self.loopback(port: 0)
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard bound == 0, listen(fd, 16) == 0 else {
            close(fd)
            throw ServerError.socket
        }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) }
        }
        socketFD = fd
        port = UInt16(bigEndian: address.sin_port)
        Thread.detachNewThread { [self] in serve(fd) }
    }

    private static func loopback(port: UInt16) -> sockaddr_in {
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = port.bigEndian
        return address
    }

    private func serve(_ fd: Int32) {
        defer { ended.signal() }
        while true {
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return }
            if stopping.withLock({ $0 }) {
                close(client)
                return
            }
            accepted.withLock { $0 += 1 }
            var request = [UInt8](repeating: 0, count: 1024)
            _ = read(client, &request, request.count)
            let reply = Array("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
            _ = write(client, reply, reply.count)
            close(client)
        }
    }

    /// Whether a connection to the server was made.
    private func connectOnce() -> Bool {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = Self.loopback(port: port)
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        } == 0
    }

    /// Connects once and checks the server counted it, so a count of zero means something.
    func expectReachable() throws {
        try #require(connectOnce(), "precondition: the server takes connections")
        for _ in 0..<200 where connections == 0 { usleep(5000) }
        try #require(connections == 1, "precondition: the server counts connections")
        accepted.withLock { $0 = 0 }
    }

    /// Wakes the thread blocked in `accept` with a connection of its own, then waits for it to end.
    func stop() {
        stopping.withLock { $0 = true }
        if connectOnce() {
            #expect(ended.wait(timeout: .now() + 10) == .success, "the server's thread ended")
        }
        close(socketFD)
    }

    enum ServerError: Error {
        case socket
    }
}
