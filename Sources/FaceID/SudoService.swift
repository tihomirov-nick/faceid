import AppKit
import Darwin
import FaceCore
import Foundation
import SwiftUI

/// Answers sudo: the PAM module connects to ~/Library/Application Support/FaceID/sudo.sock, FaceID shows a small
/// prompt with the command and recognizes the face. Being in front of the camera is not consent, so by default
/// the prompt also waits for a click on "Allow" (or Return) once the face is recognized.
@MainActor
final class SudoService {
    private weak var model: AppModel?
    private var server: SudoServer?
    private var current: Request?

    private final class Request {
        let connection: SudoConnection
        let prompt: SudoPrompt
        var session: ScanSession?
        var timeout: DispatchWorkItem?

        init(connection: SudoConnection, prompt: SudoPrompt) {
            self.connection = connection
            self.prompt = prompt
        }
    }

    /// The whole request, scans and the click included.
    static let requestTimeout: TimeInterval = 35
    static let scanTimeout: TimeInterval = 8

    func start(model: AppModel) {
        self.model = model
        let server = SudoServer { request, connection in
            DispatchQueue.main.async {
                MainActor.assumeIsolated { self.handle(request, connection: connection) }
            }
        }
        if server.start() {
            self.server = server
        } else {
            Log.write("sudo: can't listen on \(SudoProtocol.socketURL.path)")
        }
    }

    private func handle(_ request: SudoProtocol.Request, connection: SudoConnection) {
        guard let model else { return connection.finish(SudoProtocol.deny("")) }
        Log.write("sudo: request from \(request.tty.isEmpty ? "?" : request.tty)")
        guard request.user == NSUserName() else { return connection.finish(SudoProtocol.deny("")) }
        guard model.isEnrolled else { return connection.finish(SudoProtocol.deny(L("FaceID: лицо не настроено"))) }
        guard model.cameraStatus == .authorized else { return connection.finish(SudoProtocol.deny(L("FaceID: нет доступа к камере"))) }
        guard !LockScreen.isLocked else { return connection.finish(SudoProtocol.deny(L("FaceID: экран заблокирован"))) }
        guard current == nil else { return connection.finish(SudoProtocol.deny(L("FaceID: уже идет другой запрос"))) }
        if case .enroll = Island.shared.content {
            return connection.finish(SudoProtocol.deny(L("FaceID: идет настройка лица")))
        }

        let requester = Requester.find(from: request.pid)
        let prompt = SudoPrompt(command: request.command, requester: requester,
                                needsConfirmation: model.settings.sudoNeedsConfirmation)
        let item = Request(connection: connection, prompt: prompt)
        current = item
        connection.send(SudoProtocol.info(L("FaceID: посмотрите в камеру или нажмите «Пароль» в вырезе")))
        prompt.onAllow = { [weak self] in self?.finish(item, allowed: true) }
        prompt.onPassword = { [weak self] in self?.finish(item, allowed: false) }
        prompt.onRetry = { [weak self] in self?.scan(item) }
        connection.onHangUp = { [weak self] in
            DispatchQueue.main.async {
                MainActor.assumeIsolated {
                    Log.write("sudo: cancelled in the terminal")
                    self?.finish(item, allowed: false, notify: false)
                }
            }
        }
        let timeout = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.finish(item, allowed: false) }
        }
        item.timeout = timeout
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.requestTimeout, execute: timeout)
        prompt.show()
        scan(item)
    }

    private func scan(_ item: Request) {
        guard let model, current === item, let session = model.makeScan(timeout: Self.scanTimeout) else { return }
        item.session?.cancel()
        item.session = session
        item.prompt.state.phase = .scanning
        model.scanStarted()
        Task {
            let outcome = await session.run()
            model.scanEnded()
            guard current === item, item.session === session else { return }
            item.session = nil
            switch outcome {
            case let .recognized(similarity, embedding):
                Log.write(String(format: "sudo: recognized (similarity %.2f)", similarity))
                model.learn(embedding, similarity: similarity)
                Haptics.success()
                if item.prompt.needsConfirmation {
                    item.prompt.state.phase = .recognized
                } else {
                    item.prompt.state.phase = .allowed
                    try? await Task.sleep(for: .milliseconds(450))
                    finish(item, allowed: true)
                }
            case let .failed(hint):
                Log.write("sudo: not recognized (\(hint))")
                Haptics.failure()
                item.prompt.state.phase = .failed(hint.message)
            case let .cameraError(message):
                item.prompt.state.phase = .failed(message)
            case .cancelled:
                break
            }
        }
    }

    private func finish(_ item: Request, allowed: Bool, notify: Bool = true) {
        guard current === item else { return }
        current = nil
        item.timeout?.cancel()
        item.session?.cancel()
        item.session = nil
        item.prompt.close()
        if notify {
            item.connection.finish(allowed ? SudoProtocol.ok : SudoProtocol.deny(""))
        } else {
            item.connection.close()
        }
        Log.write("sudo: \(allowed ? "allowed" : "falls back to the password")")
    }
}

/// The app that runs the terminal in which sudo was typed (Terminal, iTerm, VS Code…).
struct Requester {
    let name: String
    let icon: NSImage?

    static func find(from pid: pid_t?) -> Requester? {
        var current = pid
        for _ in 0..<16 {
            guard let pid = current, pid > 1 else { return nil }
            if let app = NSRunningApplication(processIdentifier: pid), app.activationPolicy == .regular {
                return Requester(name: app.localizedName ?? "", icon: app.icon)
            }
            current = parent(of: pid)
        }
        return nil
    }

    static func parent(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        guard sysctl(&mib, 4, &info, &size, nil, 0) == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }
}

// MARK: - Socket

/// The Unix socket the PAM module connects to. Only root clients that are /usr/bin/sudo are served.
final class SudoServer: @unchecked Sendable {
    private let queue = DispatchQueue(label: "com.faceid.sudo")
    private var listener: Int32 = -1
    private var source: DispatchSourceRead?
    private let onRequest: (SudoProtocol.Request, SudoConnection) -> Void

    init(onRequest: @escaping (SudoProtocol.Request, SudoConnection) -> Void) {
        self.onRequest = onRequest
    }

    func start() -> Bool {
        let url = SudoProtocol.socketURL
        // Only the user (and root) may reach the socket.
        chmod(url.deletingLastPathComponent().path, 0o700)
        unlink(url.path)
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let path = Array(url.path.utf8)
        guard path.count < MemoryLayout.size(ofValue: address.sun_path) else {
            close(fd)
            return false
        }
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: path) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard bound == 0, chmod(url.path, 0o600) == 0, listen(fd, 8) == 0 else {
            close(fd)
            return false
        }
        _ = fcntl(fd, F_SETFL, O_NONBLOCK)
        listener = fd
        let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: queue)
        source.setEventHandler { [weak self] in self?.acceptClients() }
        source.resume()
        self.source = source
        return true
    }

    private func acceptClients() {
        while true {
            let client = accept(listener, nil, nil)
            guard client >= 0 else { return }
            var nosigpipe: Int32 = 1
            setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &nosigpipe, socklen_t(MemoryLayout<Int32>.size))
            guard Self.clientIsSudo(client) else {
                close(client)
                continue
            }
            guard let request = Self.readRequest(client) else {
                close(client)
                continue
            }
            onRequest(request, SudoConnection(fd: client))
        }
    }

    static func clientIsSudo(_ fd: Int32) -> Bool {
        var credentials = xucred()
        var length = socklen_t(MemoryLayout<xucred>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERCRED, &credentials, &length) == 0 else { return false }
        var pid: pid_t = 0
        length = socklen_t(MemoryLayout<pid_t>.size)
        guard getsockopt(fd, SOL_LOCAL, LOCAL_PEERPID, &pid, &length) == 0 else { return false }
        #if DEBUG
        // Development builds: scripts/test_pam.sh drives the module from an ordinary process.
        if ProcessInfo.processInfo.environment["FACEID_SUDO_TEST"] == "1" { return true }
        #endif
        guard credentials.cr_uid == 0 else { return false }
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 else { return false }
        return String(cString: buffer) == "/usr/bin/sudo"
    }

    /// The request, read with a two-second limit.
    static func readRequest(_ fd: Int32) -> SudoProtocol.Request? {
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) & ~O_NONBLOCK)
        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var data = Data()
        var chunk = [UInt8](repeating: 0, count: 1024)
        while data.count < 4096 {
            let count = read(fd, &chunk, chunk.count)
            guard count > 0 else { return nil }
            data.append(contentsOf: chunk[0..<count])
            if let text = String(data: data, encoding: .utf8), let request = SudoProtocol.parse(text) { return request }
        }
        return nil
    }
}

/// One connected PAM module.
final class SudoConnection: @unchecked Sendable {
    private let fd: Int32
    private let lock = NSLock()
    private var closed = false
    private var source: DispatchSourceRead?
    /// The client went away (^C in the terminal).
    var onHangUp: (() -> Void)? {
        didSet { watch() }
    }

    init(fd: Int32) {
        self.fd = fd
    }

    func send(_ text: String) {
        lock.withLock {
            guard !closed else { return }
            let bytes = Array(text.utf8)
            var offset = 0
            while offset < bytes.count {
                let written = bytes[offset...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
                if written < 0 && errno == EINTR { continue }
                guard written > 0 else { return }
                offset += written
            }
        }
    }

    func finish(_ text: String) {
        send(text)
        close()
    }

    func close() {
        lock.withLock {
            guard !closed else { return }
            closed = true
            source?.cancel()
            source = nil
            Darwin.close(fd)
        }
    }

    private func watch() {
        lock.withLock {
            guard source == nil, !closed else { return }
            let source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: .global())
            source.setEventHandler { [weak self] in
                guard let self else { return }
                var byte: UInt8 = 0
                let count = recv(self.fd, &byte, 1, Int32(MSG_PEEK | MSG_DONTWAIT))
                if count == 0 {
                    self.lock.withLock { self.source?.cancel(); self.source = nil }
                    self.onHangUp?()
                }
            }
            source.resume()
            self.source = source
        }
    }
}

// MARK: - Prompt

/// The sudo request in the island: who asks, the command, the scan, and the buttons.
@MainActor
final class SudoPrompt {
    enum Phase: Equatable {
        case scanning
        case recognized
        case allowed
        case failed(String)
    }

    final class State: ObservableObject {
        @Published var phase: Phase = .scanning
    }

    let state = State()
    let command: String
    let requester: Requester?
    let needsConfirmation: Bool
    var onAllow: () -> Void = {}
    var onPassword: () -> Void = {}
    var onRetry: () -> Void = {}

    init(command: String, requester: Requester?, needsConfirmation: Bool) {
        self.command = command
        self.requester = requester
        self.needsConfirmation = needsConfirmation
    }

    func show() {
        Island.shared.show(.sudo(self))
    }

    func close() {
        if case let .sudo(prompt) = Island.shared.content, prompt === self {
            Island.shared.hide(after: state.phase == .allowed ? 0.35 : 0)
        }
    }
}

/// The request: who asks and the exact command, the Face ID glyph, two buttons.
struct SudoPromptView: View {
    let prompt: SudoPrompt
    @ObservedObject var state: SudoPrompt.State

    var body: some View {
        HStack(alignment: .center, spacing: 14) {
            FaceIDGlyph(phase: glyph, size: 42)
            VStack(alignment: .leading, spacing: 8) {
                HStack(spacing: 6) {
                    if let icon = prompt.requester?.icon {
                        Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                    }
                    Text(prompt.command.isEmpty ? "sudo" : prompt.command)
                        .font(.system(size: 12.5, weight: .medium, design: .monospaced))
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                HStack(spacing: 8) {
                    Button(L("Пароль")) { prompt.onPassword() }
                        .keyboardShortcut(.cancelAction)
                        .appButton(.secondary)
                    if case .failed = state.phase {
                        Button(L("Еще раз")) { prompt.onRetry() }
                            .keyboardShortcut(.defaultAction)
                            .appButton(.primary)
                    } else if prompt.needsConfirmation {
                        Button(L("Разрешить")) { prompt.onAllow() }
                            .keyboardShortcut(.defaultAction)
                            .appButton(.primary)
                            .disabled(state.phase != .recognized)
                    }
                }
                .controlSize(.small)
            }
            Spacer(minLength: 0)
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 18)
        .padding(.top, 8)
        .animation(.easeInOut(duration: 0.2), value: state.phase)
    }

    private var glyph: GlyphPhase {
        switch state.phase {
        case .scanning: .scanning
        case .recognized, .allowed: .success
        case .failed: .failure
        }
    }
}
