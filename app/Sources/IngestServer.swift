import Foundation
import Network
import Observation

/// Receives title assets over the local network.
///
/// Deliberately not `devicectl`: that is macOS-only, and its recursive
/// directory copy is broken. One file per request keeps the protocol trivial
/// and avoids needing an archive extractor on-device, where there is no shell.
///
///     PUT /ingest?pkg=<package>&path=<relative/path>
@Observable
final class IngestServer {
    private(set) var isRunning = false
    private(set) var received = 0

    private var listener: NWListener?
    private let port: NWEndpoint.Port = 8787
    private var onComplete: (() -> Void)?

    private var documents: URL {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
    }

    func start(onComplete: @escaping () -> Void) {
        guard listener == nil else { return }
        self.onComplete = onComplete
        do {
            let listener = try NWListener(using: .tcp, on: port)
            listener.newConnectionHandler = { [weak self] in self?.accept($0) }
            listener.stateUpdateHandler = { [weak self] state in
                if case .ready = state { self?.isRunning = true }
                if case .failed = state { self?.isRunning = false }
            }
            listener.start(queue: .global(qos: .utility))
            self.listener = listener
        } catch {
            isRunning = false
        }
    }

    func stop() {
        listener?.cancel()
        listener = nil
        isRunning = false
    }

    private func accept(_ connection: NWConnection) {
        connection.start(queue: .global(qos: .utility))
        receive(connection, buffer: Data())
    }

    private func receive(_ connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1 << 20) {
            [weak self] chunk, _, isComplete, error in
            guard let self, error == nil else { connection.cancel(); return }

            var buffer = buffer
            if let chunk { buffer.append(chunk) }

            if isComplete {
                let ok = self.write(buffer)
                let response = ok ? "HTTP/1.1 200 OK\r\nContent-Length: 0\r\n\r\n"
                                  : "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n"
                connection.send(content: Data(response.utf8),
                                completion: .contentProcessed { _ in connection.cancel() })
                if ok {
                    Task { @MainActor in
                        self.received += 1
                        self.onComplete?()
                    }
                }
            } else {
                self.receive(connection, buffer: buffer)
            }
        }
    }

    /// Splits headers from body and writes the payload to Documents/titles/<pkg>/<path>.
    private func write(_ request: Data) -> Bool {
        let separator = Data("\r\n\r\n".utf8)
        guard let range = request.range(of: separator),
              let head = String(data: request[..<range.lowerBound], encoding: .utf8),
              let requestLine = head.split(separator: "\r\n").first,
              let target = requestLine.split(separator: " ").dropFirst().first,
              let components = URLComponents(string: String(target)),
              let pkg = components.queryItems?.first(where: { $0.name == "pkg" })?.value,
              let path = components.queryItems?.first(where: { $0.name == "path" })?.value
        else { return false }

        // Reject traversal: the sender is trusted, the wire is not.
        guard !path.contains(".."), !pkg.contains("/"), !pkg.contains("..") else { return false }

        let destination = documents
            .appending(path: "titles/\(pkg)")
            .appending(path: path)
        do {
            try FileManager.default.createDirectory(
                at: destination.deletingLastPathComponent(),
                withIntermediateDirectories: true)
            try request[range.upperBound...].write(to: destination)
            return true
        } catch {
            return false
        }
    }
}
