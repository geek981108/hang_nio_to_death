import CoreImage
import Darwin
import Foundation
import Network
import Security
import UIKit

@MainActor
final class TVPairingServer: ObservableObject {
    enum State: Equatable {
        case idle
        case starting
        case listening(code: String, host: String, port: UInt16)
        case paired
        case failed(String)
    }

    @Published private(set) var state: State = .idle
    @Published private(set) var qrImage: UIImage?

    private var listener: NWListener?
    private let queue = DispatchQueue(label: "com.shuto.happyvalley.tv.pairing")
    private var activeCode: String = ""
    private var failedAttempts = 0
    private var expiryTask: Task<Void, Never>?
    private var onPaired: ((TVPairingPayload) -> Void)?

    func start(onPaired: @escaping (TVPairingPayload) -> Void) {
        stop()
        self.onPaired = onPaired
        self.state = .starting
        self.failedAttempts = 0
        let code = Self.generateCode()
        self.activeCode = code

        do {
            let params = NWParameters.tcp
            params.includePeerToPeer = false
            let listener = try NWListener(using: params)
            let tvName = UIDevice.current.name
            listener.service = NWListener.Service(
                name: tvName,
                type: TVPairingConstants.bonjourType,
                domain: TVPairingConstants.bonjourDomain
            )

            listener.stateUpdateHandler = { [weak self] newState in
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    switch newState {
                    case .ready:
                        guard let port = listener.port?.rawValue, port > 0 else {
                            self.state = .failed("无法分配局域网配对端口")
                            return
                        }
                        let host = Self.localLANIPv4Address() ?? "127.0.0.1"
                        // Publish direct LAN IPv4 + port in Bonjour TXT record so iOS can connect immediately
                        // without waiting for secondary mDNS resolution races.
                        var txt = NWTXTRecord()
                        txt["host"] = host
                        txt["port"] = String(port)
                        listener.service = NWListener.Service(
                            name: tvName,
                            type: TVPairingConstants.bonjourType,
                            domain: TVPairingConstants.bonjourDomain,
                            txtRecord: txt
                        )
                        self.state = .listening(code: code, host: host, port: port)
                        if let endpoint = TVPairingEndpoint(host: host, port: port, code: code, tvName: tvName),
                           let url = endpoint.pairingURL {
                            self.qrImage = Self.makeQRCode(from: url.absoluteString)
                        }
                        self.scheduleExpiry()
                    case .failed(let error):
                        self.state = .failed("局域网配对服务启动失败：\(error.localizedDescription)")
                    case .cancelled:
                        break
                    default:
                        break
                    }
                }
            }

            listener.newConnectionHandler = { [weak self] connection in
                self?.handleConnection(connection)
            }

            self.listener = listener
            listener.start(queue: queue)
        } catch {
            self.state = .failed("无法启动配对监听：\(error.localizedDescription)")
        }
    }

    func regenerateCode() {
        guard let handler = onPaired else { return }
        start(onPaired: handler)
    }

    func stop() {
        expiryTask?.cancel()
        expiryTask = nil
        listener?.cancel()
        listener = nil
        qrImage = nil
        if case .paired = state {
            // Preserve paired status until view dismisses or restarts.
        } else {
            state = .idle
        }
    }

    private func scheduleExpiry() {
        expiryTask?.cancel()
        expiryTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(TVPairingConstants.sessionTTLSeconds))
            guard !Task.isCancelled, let self else { return }
            if case .listening = self.state {
                self.stop()
                self.state = .failed("配对码已过期，请点击「刷新配对码」重新生成。")
            }
        }
    }

    nonisolated private func handleConnection(_ connection: NWConnection) {
        connection.start(queue: queue)
        receiveLoop(connection: connection, buffer: Data())
    }

    nonisolated private func receiveLoop(connection: NWConnection, buffer: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 16_384) { [weak self] data, _, isComplete, error in
            guard let self else {
                connection.cancel()
                return
            }
            if error != nil {
                connection.cancel()
                return
            }
            var accumulated = buffer
            if let data {
                accumulated.append(data)
            }

            switch TVPairingWire.parseHTTPRequest(from: accumulated) {
            case .success(let request):
                Task { @MainActor [weak self] in
                    self?.processPairRequest(request, on: connection)
                }
            case .failure(.incomplete):
                if isComplete || accumulated.count > TVPairingConstants.maxBodyBytes + 16_384 {
                    self.sendAndClose(
                        connection,
                        status: 400,
                        text: "Bad Request",
                        json: #"{"error":"invalid_request","message":"Incomplete pairing payload"}"#
                    )
                } else {
                    self.receiveLoop(connection: connection, buffer: accumulated)
                }
            case .failure(.bodyTooLarge):
                self.sendAndClose(
                    connection,
                    status: 413,
                    text: "Payload Too Large",
                    json: #"{"error":"payload_too_large","message":"Payload exceeds limit"}"#
                )
            case .failure(.unsupportedMethod):
                self.sendAndClose(
                    connection,
                    status: 405,
                    text: "Method Not Allowed",
                    json: #"{"error":"method_not_allowed","message":"Only POST is supported"}"#
                )
            case .failure(.notFound):
                self.sendAndClose(
                    connection,
                    status: 404,
                    text: "Not Found",
                    json: #"{"error":"not_found","message":"Unknown path"}"#
                )
            case .failure(.invalidRequest):
                self.sendAndClose(
                    connection,
                    status: 400,
                    text: "Bad Request",
                    json: #"{"error":"invalid_request","message":"Malformed HTTP request"}"#
                )
            }
        }
    }

    private func processPairRequest(_ request: TVPairingWire.ParsedHTTPRequest, on connection: NWConnection) {
        guard case .listening = state else {
            sendAndClose(
                connection,
                status: 410,
                text: "Gone",
                json: #"{"error":"pairing_closed","message":"Pairing session is no longer active"}"#
            )
            return
        }

        let envelope: TVPairingEnvelope
        do {
            envelope = try JSONDecoder().decode(TVPairingEnvelope.self, from: request.body)
        } catch {
            sendAndClose(
                connection,
                status: 400,
                text: "Bad Request",
                json: #"{"error":"invalid_json","message":"Invalid pairing JSON"}"#
            )
            return
        }

        guard TVPairingWire.constantTimeEquals(envelope.code.trimmingCharacters(in: .whitespacesAndNewlines), activeCode) else {
            failedAttempts += 1
            sendAndClose(
                connection,
                status: 403,
                text: "Forbidden",
                json: #"{"error":"invalid_code","message":"配对码不正确"}"#
            )
            if failedAttempts >= TVPairingConstants.maxFailedAttempts {
                regenerateCode()
            }
            return
        }

        do {
            _ = try BackendConfiguration(
                baseURLString: envelope.payload.baseURLString,
                apiKey: envelope.payload.apiKey
            )
        } catch {
            sendAndClose(
                connection,
                status: 400,
                text: "Bad Request",
                json: #"{"error":"invalid_configuration","message":"后端地址或 API Key 无效"}"#
            )
            return
        }

        sendAndClose(
            connection,
            status: 200,
            text: "OK",
            json: #"{"status":"paired"}"#
        )

        let callback = onPaired
        state = .paired
        stop()
        callback?(envelope.payload)
    }

    nonisolated private func sendAndClose(_ connection: NWConnection, status: Int, text: String, json: String) {
        let data = TVPairingWire.makeHTTPResponse(statusCode: status, statusText: text, jsonBody: json)
        connection.send(content: data, completion: .contentProcessed { _ in
            connection.cancel()
        })
    }

    private static func generateCode() -> String {
        var value: UInt32 = 0
        _ = SecRandomCopyBytes(kSecRandomDefault, MemoryLayout<UInt32>.size, &value)
        return String(format: "%06u", value % 1_000_000)
    }

    private static func makeQRCode(from string: String) -> UIImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(string.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage else { return nil }
        let scaled = output.transformed(by: CGAffineTransform(scaleX: 10, y: 10))
        let context = CIContext()
        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else { return nil }
        return UIImage(cgImage: cgImage)
    }

    private static func localLANIPv4Address() -> String? {
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else { return nil }
        defer { freeifaddrs(ifaddr) }

        var fallback: String?
        var pointer: UnsafeMutablePointer<ifaddrs>? = first
        while let current = pointer {
            defer { pointer = current.pointee.ifa_next }
            let flags = Int32(current.pointee.ifa_flags)
            guard (flags & IFF_UP) != 0,
                  (flags & IFF_LOOPBACK) == 0,
                  let addr = current.pointee.ifa_addr,
                  addr.pointee.sa_family == UInt8(AF_INET) else {
                continue
            }
            var hostBuffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            let result = getnameinfo(
                addr,
                socklen_t(addr.pointee.sa_len),
                &hostBuffer,
                socklen_t(hostBuffer.count),
                nil,
                0,
                NI_NUMERICHOST
            )
            guard result == 0 else { continue }
            let ip = String(cString: hostBuffer)
            let name = String(cString: current.pointee.ifa_name)
            if name == "en0" || name == "en1" {
                return ip
            }
            fallback = fallback ?? ip
        }
        return fallback
    }
}
