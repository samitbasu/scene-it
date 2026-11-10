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
        #expect(RequestRecorder.urls == [], "no request was made")
    }

    /// Every kind of reference a page can make: a style sheet, an imported one, a background, an
    /// image over HTTPS, HTTP and by host name, a frame and a script, and one remote image.
    static func html(referencing port: UInt16) -> String {
        let https = "https://127.0.0.1:\(port)"
        let http = "http://localhost:\(port)"
        return """
            <html><head>
            <link rel="stylesheet" href="\(https)/sheet.css">
            <style>@import url("\(http)/imported.css"); p { background: url("\(https)/bg.png") }</style>
            <script src="\(https)/script.js"></script>
            </head><body><p><b>Bold</b> and <i>italic</i>
            <img src="\(https)/a.png"> <img src="\(http)/b.png"> <img src="https://example.com/c.png">
            <iframe src="\(https)/frame.html"></iframe></p></body></html>
            """
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
/// process, and answers each with 404.
private nonisolated final class LoopbackServer: Sendable {
    let port: UInt16
    private let socketFD: Int32
    private let accepted = Mutex(0)

    var connections: Int { accepted.withLock { $0 } }

    init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw ServerError.socket }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
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

    private func serve(_ fd: Int32) {
        while true {
            let client = accept(fd, nil, nil)
            guard client >= 0 else { return }
            accepted.withLock { $0 += 1 }
            var request = [UInt8](repeating: 0, count: 1024)
            _ = read(client, &request, request.count)
            let reply = Array("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".utf8)
            _ = write(client, reply, reply.count)
            close(client)
        }
    }

    /// Connects once and checks the server counted it, so a count of zero means something.
    func expectReachable() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        defer { close(fd) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        address.sin_port = port.bigEndian
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        try #require(connected == 0, "precondition: the server takes connections")
        for _ in 0..<200 where connections == 0 { usleep(5000) }
        try #require(connections == 1, "precondition: the server counts connections")
        accepted.withLock { $0 = 0 }
    }

    func stop() {
        shutdown(socketFD, SHUT_RDWR)
        close(socketFD)
    }

    enum ServerError: Error {
        case socket
    }
}
