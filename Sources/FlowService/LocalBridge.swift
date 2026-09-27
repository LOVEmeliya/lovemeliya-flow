import Foundation
import CryptoKit
import Darwin

public enum LocalBridge {
    public static func directory(support: URL) -> URL {
        let hash = SHA256.hash(data: Data(support.standardizedFileURL.path.utf8)).prefix(8).map { String(format: "%02x", $0) }.joined()
        return URL(fileURLWithPath: "/tmp/lovemeliya-flow-\(getuid())-\(hash)", isDirectory: true)
    }
    public static func prepare(support: URL) throws -> URL {
        let dir = directory(support: support)
        if mkdir(dir.path, 0o700) != 0 && errno != EEXIST { throw FlowError("BRIDGE_UNAVAILABLE", "无法创建本地通信目录。") }
        var s = stat()
        guard lstat(dir.path, &s) == 0, s.st_uid == getuid(), (s.st_mode & S_IFMT) == S_IFDIR, (s.st_mode & 0o077) == 0 else {
            throw FlowError("BRIDGE_PERMISSION", "本地通信目录权限无效。")
        }
        return dir
    }
    static func address(_ path: String) throws -> sockaddr_un {
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        guard path.utf8.count < MemoryLayout.size(ofValue: address.sun_path) else { throw FlowError("BRIDGE_PATH", "通信路径过长。") }
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        withUnsafeMutableBytes(of: &address.sun_path) { bytes in
            bytes.initializeMemory(as: UInt8.self, repeating: 0)
            for (i, value) in path.utf8.enumerated() { bytes[i] = value }
        }
        return address
    }
    static func configure(_ fd: Int32) {
        var one: Int32 = 1; setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout.size(ofValue: one)))
        var timeout = timeval(tv_sec: 660, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout.size(ofValue: timeout)))
    }
    static func verifyPeer(_ fd: Int32) throws {
        var uid: uid_t = 0; var gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0 && uid == getuid() else { throw FlowError("BRIDGE_PERMISSION", "通信进程不属于当前用户。") }
    }
    static func readLine(_ fd: Int32, maxBytes: Int) throws -> Data {
        var result = Data(); var buffer = [UInt8](repeating: 0, count: 8192)
        while true {
            let n = recv(fd, &buffer, buffer.count, 0)
            if n < 0 && errno == EINTR { continue }
            guard n > 0 else { throw FlowError("BRIDGE_DISCONNECTED", "APP 连接断开或超时；请检查 APP，再用相同 request_id 重试提交。") }
            if let end = buffer.prefix(n).firstIndex(of: 10) { result.append(contentsOf: buffer[..<end]); break }
            result.append(contentsOf: buffer.prefix(n))
            guard result.count <= maxBytes else { throw FlowError("MESSAGE_TOO_LARGE", "通信消息过大。") }
        }
        guard result.count <= maxBytes else { throw FlowError("MESSAGE_TOO_LARGE", "通信消息过大。") }; return result
    }
    static func writeLine(_ fd: Int32, data: Data) throws {
        let bytes = data + Data([10])
        try bytes.withUnsafeBytes { raw in
            var offset = 0
            while offset < bytes.count {
                let n = send(fd, raw.baseAddress!.advanced(by: offset), bytes.count - offset, 0)
                if n < 0 && errno == EINTR { continue }
                guard n > 0 else { throw FlowError("BRIDGE_DISCONNECTED", "无法写入 APP 连接。") }; offset += n
            }
        }
    }
    public static func request(_ request: BridgeRequest, support: URL = FlowPaths.support) async throws -> BridgeResponse {
        try await withCheckedThrowingContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                do {
                    let directory = try prepare(support: support)
                    let fd = socket(AF_UNIX, SOCK_STREAM, 0)
                    guard fd >= 0 else { throw FlowError("APP_NOT_RUNNING", "无法创建本地连接。") }
                    defer { close(fd) }; configure(fd)
                    var address = try address(directory.appendingPathComponent("bridge.sock").path)
                    let connected = withUnsafePointer(to: &address) { pointer in pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
                    guard connected == 0 else { throw FlowError("APP_NOT_RUNNING", "请打开 LOVEmeliya Flow 1.1 或更高版本。") }
                    try verifyPeer(fd)
                    try writeLine(fd, data: JSONEncoder().encode(request))
                    let result = try JSONDecoder().decode(BridgeResponse.self, from: readLine(fd, maxBytes: 2 * 1024 * 1024))
                    continuation.resume(returning: result)
                } catch { continuation.resume(throwing: error) }
            }
        }
    }
}

public final class BridgeServer: @unchecked Sendable {
    private let support: URL
    private var descriptor: Int32 = -1
    private var lockFD: Int32 = -1
    private let handlers = DispatchSemaphore(value: 8)
    private let handler: @Sendable (BridgeRequest) async -> BridgeResponse
    public init(support: URL = FlowPaths.support, handler: @escaping @Sendable (BridgeRequest) async -> BridgeResponse) { self.support = support; self.handler = handler }
    public func start() throws {
        let directory = try LocalBridge.prepare(support: support)
        lockFD = open(directory.appendingPathComponent("server.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard lockFD >= 0 else { throw FlowError("BRIDGE_UNAVAILABLE", "无法创建单实例锁。") }
        guard flock(lockFD, LOCK_EX | LOCK_NB) == 0 else { close(lockFD); lockFD = -1; throw FlowError("APP_ALREADY_RUNNING", "另一份 Flow 正在持有任务服务，请使用已打开的应用。") }
        let path = directory.appendingPathComponent("bridge.sock").path
        unlink(path)
        descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { stop(); throw FlowError("BRIDGE_UNAVAILABLE", "无法创建本地服务。") }
        var address = try LocalBridge.address(path)
        let bound = withUnsafePointer(to: &address) { pointer in pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard bound == 0, chmod(path, 0o600) == 0, listen(descriptor, 8) == 0 else { stop(); throw FlowError("BRIDGE_UNAVAILABLE", "无法启动本地服务。") }
        let fd = descriptor
        DispatchQueue.global(qos: .utility).async { [self] in
            while true {
                let client = accept(fd, nil, nil)
                if client < 0 { if errno == EINTR { continue }; break }
                guard handlers.wait(timeout: .now()) == .success else { close(client); continue }
                DispatchQueue.global(qos: .utility).async { [self] in
                    LocalBridge.configure(client)
                    do {
                        try LocalBridge.verifyPeer(client)
                        let data = try LocalBridge.readLine(client, maxBytes: 256 * 1024)
                        let request = try JSONDecoder().decode(BridgeRequest.self, from: data)
                        guard request.session.count <= 128, request.client.count <= 128, request.name.count <= 64 else { throw FlowError("INVALID_REQUEST", "请求字段过长。") }
                        Task {
                            let response = await handler(request)
                            try? LocalBridge.writeLine(client, data: JSONEncoder().encode(response))
                            close(client); handlers.signal()
                        }
                    } catch {
                        try? LocalBridge.writeLine(client, data: JSONEncoder().encode(BridgeResponse.failure(error)))
                        close(client); handlers.signal()
                    }
                }
            }
        }
    }
    public func stop() {
        if descriptor >= 0 { shutdown(descriptor, SHUT_RDWR); close(descriptor); descriptor = -1 }
        if lockFD >= 0 { unlink(LocalBridge.directory(support: support).appendingPathComponent("bridge.sock").path); flock(lockFD, LOCK_UN); close(lockFD); lockFD = -1 }
    }
}
