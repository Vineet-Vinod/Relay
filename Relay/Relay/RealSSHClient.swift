//
//  RealSSHClient.swift
//  Relay
//
//  Created by Codex on 4/4/26.
//

import Foundation
import NIOCore
import NIOSSH
import NIOTransportServices

@MainActor
final class RealSSHClient: SSHClient {
    private let credentials: SSHCredentialStore
    private var session: SSHConnectionSession?
    private var eventHandler: (@MainActor @Sendable (TerminalEvent) -> Void)?

    init(credentials: SSHCredentialStore = RelayServices.sshCredentials) {
        self.credentials = credentials
    }

    func setEventHandler(_ handler: (@MainActor @Sendable (TerminalEvent) -> Void)?) {
        self.eventHandler = handler
    }

    func connect(to host: Host) async throws {
        if let session {
            await session.close()
            self.session = nil
        }

        let authentication = try resolveAuthentication(for: host)
        let emit = eventEmitter()
        let timeoutSeconds = RelayPreferences.shared.connectionTimeoutSeconds

        self.session = try await withTimeout(seconds: timeoutSeconds) {
            try await SSHConnectionSession.connect(
                to: host,
                authentication: authentication,
                trustStore: self.credentials,
                eventSink: emit
            )
        }

        emit(.status(authentication.connectedMessage))
    }

    func provisionSavedKey(for host: Host) async throws {
        guard let password = host.password, !password.isEmpty else {
            throw SSHClientError.missingPassword
        }

        let keyPair = SSHGeneratedKeyPair.generate(comment: host.savedKeyComment)
        let installCommand = SSHAuthorizedKeysInstaller.installCommand(for: keyPair.authorizedKey)
        let timeoutSeconds = RelayPreferences.shared.connectionTimeoutSeconds
        let installResult = try await withTimeout(seconds: timeoutSeconds) {
            try await SSHConnectionSession.runCommand(
                to: host,
                authentication: .password(password),
                trustStore: self.credentials,
                command: installCommand
            )
        }

        guard installResult.exitStatus == 0 else {
            let stderr = installResult.stderr.trimmingCharacters(in: .whitespacesAndNewlines)
            let details = stderr.isEmpty ? installResult.stdout : stderr
            throw SSHClientError.keyProvisioningFailed(
                details.isEmpty
                    ? "Relay could not install the public key on the remote device."
                    : "Relay could not install the public key: \(details)"
            )
        }

        do {
            try await withTimeout(seconds: timeoutSeconds) {
                try await SSHConnectionSession.verifyConnection(
                    to: host,
                    authentication: .privateKey(keyPair.nioPrivateKey),
                    trustStore: self.credentials
                )
            }
        } catch let error as SSHClientError {
            switch error {
            case .hostKeyMismatch, .unsupportedHostKey:
                throw error
            default:
                throw SSHClientError.publicKeyVerificationFailed
            }
        } catch {
            throw SSHClientError.publicKeyVerificationFailed
        }

        try credentials.save(keyPair, for: host.remoteIdentity)
    }

    func sendRawInput(_ bytes: [UInt8]) async throws {
        guard !bytes.isEmpty else {
            throw SSHClientError.emptyCommand
        }

        guard let session else {
            throw SSHClientError.notConnected
        }

        try await session.sendInput(bytes)
    }

    func resizeTerminal(columns: Int, rows: Int) async {
        guard let session else { return }
        await session.resizeTerminal(columns: columns, rows: rows)
    }

    func disconnect() async {
        guard let session else { return }
        await session.close()
        self.session = nil
    }

    private func resolveAuthentication(for host: Host) throws -> SSHConnectionAuthentication {
        switch host.authentication {
        case .password(let password):
            guard !password.isEmpty else {
                throw SSHClientError.missingPassword
            }

            return .password(password)
        case .automatic:
            guard let privateKey = try credentials.privateKey(for: host.remoteIdentity) else {
                throw SSHClientError.missingPrivateKey
            }

            return .privateKey(privateKey)
        }
    }

    private func eventEmitter() -> @Sendable (TerminalEvent) -> Void {
        { [eventHandler] event in
            guard let eventHandler else { return }
            Task { @MainActor in
                eventHandler(event)
            }
        }
    }

    private func withTimeout<T: Sendable>(
        seconds: Int,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }

            group.addTask {
                try await Task.sleep(for: .seconds(seconds))
                throw SSHClientError.connectionTimedOut(seconds: seconds)
            }

            guard let result = try await group.next() else {
                throw SSHClientError.connectionTimedOut(seconds: seconds)
            }

            group.cancelAll()
            return result
        }
    }
}

private enum SSHConnectionAuthentication {
    case password(String)
    case privateKey(NIOSSHPrivateKey)

    var connectedMessage: String {
        switch self {
        case .password:
            return "Connected."
        case .privateKey:
            return "Connected using saved SSH key."
        }
    }
}

private struct SSHCommandResult: Sendable {
    let stdout: String
    let stderr: String
    let exitStatus: Int32
}

private struct ConnectedRoot {
    let group: NIOTSEventLoopGroup
    let rootChannel: Channel
    let sshHandler: SSHHandlerBox
}

private final class SSHConnectionSession: @unchecked Sendable {
    private let group: NIOTSEventLoopGroup
    private let rootChannel: Channel
    private let shellChannel: Channel

    private init(group: NIOTSEventLoopGroup, rootChannel: Channel, shellChannel: Channel) {
        self.group = group
        self.rootChannel = rootChannel
        self.shellChannel = shellChannel
    }

    static func connect(
        to host: Host,
        authentication: SSHConnectionAuthentication,
        trustStore: SSHCredentialStore,
        eventSink: @escaping @Sendable (TerminalEvent) -> Void
    ) async throws -> SSHConnectionSession {
        let root = try await openRootConnection(to: host, authentication: authentication, trustStore: trustStore)

        do {
            let shellChannel = try await openShellChannel(
                rootChannel: root.rootChannel,
                sshHandler: root.sshHandler,
                eventSink: eventSink
            )
            return SSHConnectionSession(group: root.group, rootChannel: root.rootChannel, shellChannel: shellChannel)
        } catch {
            try? await close(root: root)
            throw error
        }
    }

    static func runCommand(
        to host: Host,
        authentication: SSHConnectionAuthentication,
        trustStore: SSHCredentialStore,
        command: String
    ) async throws -> SSHCommandResult {
        let root = try await openRootConnection(to: host, authentication: authentication, trustStore: trustStore)

        do {
            let result = try await openExecChannel(
                rootChannel: root.rootChannel,
                sshHandler: root.sshHandler,
                command: command
            )
            try? await close(root: root)
            return result
        } catch {
            try? await close(root: root)
            throw error
        }
    }

    static func verifyConnection(
        to host: Host,
        authentication: SSHConnectionAuthentication,
        trustStore: SSHCredentialStore
    ) async throws {
        let root = try await openRootConnection(to: host, authentication: authentication, trustStore: trustStore)
        try await close(root: root)
    }

    func sendInput(_ bytes: [UInt8]) async throws {
        guard self.shellChannel.isActive else {
            throw SSHClientError.notConnected
        }

        var buffer = self.shellChannel.allocator.buffer(capacity: bytes.count)
        buffer.writeBytes(bytes)
        let data = SSHChannelData(type: .channel, data: .byteBuffer(buffer))
        try await self.shellChannel.writeAndFlush(data).get()
    }

    func resizeTerminal(columns: Int, rows: Int) async {
        guard self.shellChannel.isActive, columns > 0, rows > 0 else { return }

        let request = SSHChannelRequestEvent.WindowChangeRequest(
            terminalCharacterWidth: columns,
            terminalRowHeight: rows,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0
        )
        try? await self.shellChannel.triggerUserOutboundEvent(request).get()
    }

    func close() async {
        try? await self.shellChannel.close().get()
        try? await self.rootChannel.close().get()
        try? await self.group.shutdownGracefully()
    }

    private static func openRootConnection(
        to host: Host,
        authentication: SSHConnectionAuthentication,
        trustStore: SSHCredentialStore
    ) async throws -> ConnectedRoot {
        let group = NIOTSEventLoopGroup(loopCount: 1)
        let authDelegate = CredentialAuthenticationDelegate(username: host.username, authentication: authentication)
        let hostKeyDelegate = TrustOnFirstUseHostKeysDelegate(endpoint: host.endpointIdentity, store: trustStore)
        let sshHandler = NIOSSHHandler(
            role: .client(
                .init(
                    userAuthDelegate: authDelegate,
                    serverAuthDelegate: hostKeyDelegate
                )
            ),
            allocator: ByteBufferAllocator(),
            inboundChildChannelInitializer: nil
        )
        let sshHandlerBox = SSHHandlerBox(handler: sshHandler)
        let authenticationPromise = group.next().makePromise(of: Void.self)
        let authenticationHandler = SSHAuthenticationStateHandler(authenticationPromise: authenticationPromise)

        let bootstrap = NIOTSConnectionBootstrap(group: group)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(sshHandlerBox.handler)
                    try channel.pipeline.syncOperations.addHandler(authenticationHandler)
                    try channel.pipeline.syncOperations.addHandler(SSHErrorHandler())
                }
            }

        do {
            let rootChannel = try await bootstrap.connect(host: host.hostname, port: host.port).get()
            try await authenticationPromise.futureResult.get()
            return ConnectedRoot(group: group, rootChannel: rootChannel, sshHandler: sshHandlerBox)
        } catch {
            try? await group.shutdownGracefully()
            throw error
        }
    }

    private static func close(root: ConnectedRoot) async throws {
        try await root.rootChannel.close().get()
        try await root.group.shutdownGracefully()
    }

    private static func openShellChannel(
        rootChannel: Channel,
        sshHandler: SSHHandlerBox,
        eventSink: @escaping @Sendable (TerminalEvent) -> Void
    ) async throws -> Channel {
        let readyPromise = rootChannel.eventLoop.makePromise(of: Void.self)
        let childPromise = rootChannel.eventLoop.makePromise(of: Channel.self)

        rootChannel.eventLoop.execute {
            sshHandler.handler.createChannel(childPromise) { childChannel, channelType in
                guard channelType == .session else {
                    return childChannel.eventLoop.makeFailedFuture(SSHClientError.invalidChannelType)
                }

                return childChannel.eventLoop.makeCompletedFuture {
                    let handler = InteractiveShellHandler(eventSink: eventSink, readyPromise: readyPromise)
                    try childChannel.pipeline.syncOperations.addHandler(handler)
                }
            }
        }

        let childChannel = try await childPromise.futureResult.get()
        try await readyPromise.futureResult.get()
        return childChannel
    }

    private static func openExecChannel(
        rootChannel: Channel,
        sshHandler: SSHHandlerBox,
        command: String
    ) async throws -> SSHCommandResult {
        let resultPromise = rootChannel.eventLoop.makePromise(of: SSHCommandResult.self)
        let childPromise = rootChannel.eventLoop.makePromise(of: Channel.self)

        rootChannel.eventLoop.execute {
            sshHandler.handler.createChannel(childPromise) { childChannel, channelType in
                guard channelType == .session else {
                    return childChannel.eventLoop.makeFailedFuture(SSHClientError.invalidChannelType)
                }

                return childChannel.eventLoop.makeCompletedFuture {
                    let handler = ExecCommandHandler(command: command, resultPromise: resultPromise)
                    try childChannel.pipeline.syncOperations.addHandler(handler)
                }
            }
        }

        _ = try await childPromise.futureResult.get()
        return try await resultPromise.futureResult.get()
    }
}

private final class SSHHandlerBox: @unchecked Sendable {
    let handler: NIOSSHHandler

    init(handler: NIOSSHHandler) {
        self.handler = handler
    }
}

private nonisolated final class CredentialAuthenticationDelegate: NIOSSHClientUserAuthenticationDelegate {
    private var authRequest: NIOSSHUserAuthenticationOffer?
    private let requestedMethod: NIOSSHAvailableUserAuthenticationMethods

    init(username: String, authentication: SSHConnectionAuthentication) {
        switch authentication {
        case .password(let password):
            self.authRequest = NIOSSHUserAuthenticationOffer(
                username: username,
                serviceName: "",
                offer: .password(.init(password: password))
            )
            self.requestedMethod = .password
        case .privateKey(let privateKey):
            self.authRequest = NIOSSHUserAuthenticationOffer(
                username: username,
                serviceName: "",
                offer: .privateKey(.init(privateKey: privateKey))
            )
            self.requestedMethod = .publicKey
        }
    }

    nonisolated
    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        guard let authRequest else {
            nextChallengePromise.succeed(nil)
            return
        }

        guard availableMethods.contains(requestedMethod) else {
            nextChallengePromise.fail(SSHClientError.authenticationFailed)
            return
        }

        self.authRequest = nil
        nextChallengePromise.succeed(authRequest)
    }
}

private nonisolated final class TrustOnFirstUseHostKeysDelegate: NIOSSHClientServerAuthenticationDelegate {
    private let endpoint: SSHHostEndpointIdentity
    private let store: SSHCredentialStore

    init(endpoint: SSHHostEndpointIdentity, store: SSHCredentialStore) {
        self.endpoint = endpoint
        self.store = store
    }

    nonisolated
    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        do {
            let payload = try SSHPublicKeyPayload.hostKey(hostKey)
            let trusted = store.trustedHostKey(for: endpoint)

            if let trusted {
                guard trusted.algorithm == payload.algorithm, trusted.base64Payload == payload.base64Payload else {
                    validationCompletePromise.fail(
                        SSHClientError.hostKeyMismatch(
                            expected: trusted.fingerprint,
                            actual: payload.fingerprint
                        )
                    )
                    return
                }

                validationCompletePromise.succeed(())
                return
            }

            validationCompletePromise.fail(
                SSHClientError.untrustedHostKey(
                    SSHHostTrustChallenge(
                        algorithm: payload.algorithm,
                        base64Payload: payload.base64Payload,
                        fingerprint: payload.fingerprint,
                        firstSeenAt: Date()
                    )
                )
            )
        } catch {
            validationCompletePromise.fail(error)
        }
    }
}

private nonisolated final class SSHErrorHandler: ChannelInboundHandler {
    typealias InboundIn = Any

    nonisolated
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}

private nonisolated final class SSHAuthenticationStateHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = Any

    private let authenticationPromise: EventLoopPromise<Void>
    private var hasCompleted = false

    init(authenticationPromise: EventLoopPromise<Void>) {
        self.authenticationPromise = authenticationPromise
    }

    nonisolated
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is UserAuthSuccessEvent {
            self.succeedIfNeeded()
        }

        context.fireUserInboundEventTriggered(event)
    }

    nonisolated
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        self.failIfNeeded(error)
        context.fireErrorCaught(error)
    }

    nonisolated
    func channelInactive(context: ChannelHandlerContext) {
        self.failIfNeeded(SSHClientError.authenticationFailed)
        context.fireChannelInactive()
    }

    nonisolated
    func handlerRemoved(context: ChannelHandlerContext) {
        self.failIfNeeded(SSHClientError.authenticationFailed)
    }

    nonisolated
    private func succeedIfNeeded() {
        guard !self.hasCompleted else { return }
        self.hasCompleted = true
        self.authenticationPromise.succeed(())
    }

    nonisolated
    private func failIfNeeded(_ error: Error) {
        guard !self.hasCompleted else { return }
        self.hasCompleted = true
        self.authenticationPromise.fail(self.normalize(error))
    }

    nonisolated
    private func normalize(_ error: Error) -> Error {
        if error is SSHClientError {
            return error
        }

        let message = String(describing: error).lowercased()
        if message.contains("user auth") || message.contains("authentication") {
            return SSHClientError.authenticationFailed
        }

        return error
    }
}

private nonisolated final class InteractiveShellHandler: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData
    typealias OutboundIn = SSHChannelData
    typealias OutboundOut = SSHChannelData

    private enum State: Equatable {
        case requestingPseudoTerminal
        case requestingShell
        case running
        case closed
    }

    private let eventSink: @Sendable (TerminalEvent) -> Void
    private let readyPromise: EventLoopPromise<Void>
    private let environment: [(name: String, value: String)] = [
        ("TERM", "xterm-256color"),
        ("COLORTERM", "truecolor"),
        ("LANG", "en_US.UTF-8"),
        ("LC_CTYPE", "en_US.UTF-8"),
    ]
    private var state: State = .requestingPseudoTerminal
    private var hasCompletedReady = false
    private var didEmitDisconnect = false

    init(
        eventSink: @escaping @Sendable (TerminalEvent) -> Void,
        readyPromise: EventLoopPromise<Void>
    ) {
        self.eventSink = eventSink
        self.readyPromise = readyPromise
    }

    nonisolated
    func handlerAdded(context: ChannelHandlerContext) {
        context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).whenFailure { error in
            context.fireErrorCaught(error)
        }
    }

    nonisolated
    func channelActive(context: ChannelHandlerContext) {
        let request = SSHChannelRequestEvent.PseudoTerminalRequest(
            wantReply: true,
            term: environmentTermName,
            terminalCharacterWidth: 120,
            terminalRowHeight: 32,
            terminalPixelWidth: 0,
            terminalPixelHeight: 0,
            terminalModes: SSHTerminalModes([:])
        )

        context.triggerUserOutboundEvent(request).whenFailure { error in
            self.failSetup(SSHClientError.pseudoTerminalRequestFailed, context: context, underlyingError: error)
        }
    }

    nonisolated
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let data = self.unwrapInboundIn(data)

        guard case .byteBuffer(let buffer) = data.data else {
            return
        }

        let bytes = Array(buffer.readableBytesView)
        guard !bytes.isEmpty else { return }

        switch data.type {
        case .channel, .stdErr:
            self.eventSink(.output(bytes))
        default:
            break
        }
    }

    nonisolated
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case is ChannelSuccessEvent:
            switch self.state {
            case .requestingPseudoTerminal:
                self.state = .requestingShell
                self.sendShellEnvironment(into: context)
                let request = SSHChannelRequestEvent.ShellRequest(wantReply: true)
                context.triggerUserOutboundEvent(request).whenFailure { error in
                    self.failSetup(SSHClientError.shellRequestFailed, context: context, underlyingError: error)
                }
            case .requestingShell:
                self.state = .running
                self.succeedIfNeeded()
            case .running, .closed:
                break
            }
        case is ChannelFailureEvent:
            let error: SSHClientError = self.state == .requestingPseudoTerminal
                ? .pseudoTerminalRequestFailed
                : .shellRequestFailed
            self.failSetup(error, context: context, underlyingError: nil)
        case let exitStatus as SSHChannelRequestEvent.ExitStatus:
            self.eventSink(.status("Shell exited with status \(exitStatus.exitStatus)."))
        case let exitSignal as SSHChannelRequestEvent.ExitSignal:
            self.eventSink(.error("Shell terminated by signal \(exitSignal.signalName)."))
        case ChannelEvent.inputClosed:
            context.close(promise: nil)
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    nonisolated
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        if !self.hasCompletedReady {
            self.failSetup(error, context: context, underlyingError: nil)
            return
        }

        self.eventSink(.error(Self.describe(error)))
        context.close(promise: nil)
    }

    nonisolated
    func channelInactive(context: ChannelHandlerContext) {
        self.finish()
    }

    nonisolated
    func handlerRemoved(context: ChannelHandlerContext) {
        self.finish()
    }

    nonisolated
    private func succeedIfNeeded() {
        guard !self.hasCompletedReady else { return }
        self.hasCompletedReady = true
        self.readyPromise.succeed(())
    }

    nonisolated
    private func failSetup(_ error: Error, context: ChannelHandlerContext, underlyingError: Error?) {
        guard !self.hasCompletedReady else {
            context.close(promise: nil)
            return
        }

        self.hasCompletedReady = true
        self.readyPromise.fail(error)

        if let underlyingError {
            self.eventSink(.error(Self.describe(underlyingError)))
        }

        context.close(promise: nil)
    }

    nonisolated
    private func finish() {
        guard self.state != .closed else { return }
        self.state = .closed

        if !self.hasCompletedReady {
            self.hasCompletedReady = true
            self.readyPromise.fail(SSHClientError.notConnected)
        }

        guard !self.didEmitDisconnect else { return }
        self.didEmitDisconnect = true
        self.eventSink(.disconnected)
    }

    nonisolated
    private static func describe(_ error: Error) -> String {
        if let localizedError = error as? LocalizedError, let description = localizedError.errorDescription {
            return description
        }

        return String(describing: error)
    }

    private var environmentTermName: String {
        environment.first { $0.name == "TERM" }?.value ?? "xterm-256color"
    }

    private func sendShellEnvironment(into context: ChannelHandlerContext) {
        for variable in environment {
            let request = SSHChannelRequestEvent.EnvironmentRequest(
                wantReply: false,
                name: variable.name,
                value: variable.value
            )
            context.triggerUserOutboundEvent(request).whenFailure { error in
                self.eventSink(.error(Self.describe(error)))
            }
        }
    }
}

private nonisolated final class ExecCommandHandler: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData
    typealias OutboundIn = SSHChannelData
    typealias OutboundOut = SSHChannelData

    private let command: String
    private let resultPromise: EventLoopPromise<SSHCommandResult>
    private var stdout = [UInt8]()
    private var stderr = [UInt8]()
    private var exitStatus: Int32?
    private var didAcceptRequest = false
    private var hasCompleted = false

    init(command: String, resultPromise: EventLoopPromise<SSHCommandResult>) {
        self.command = command
        self.resultPromise = resultPromise
    }

    nonisolated
    func handlerAdded(context: ChannelHandlerContext) {
        context.channel.setOption(ChannelOptions.allowRemoteHalfClosure, value: true).whenFailure { error in
            context.fireErrorCaught(error)
        }
    }

    nonisolated
    func channelActive(context: ChannelHandlerContext) {
        let request = SSHChannelRequestEvent.ExecRequest(command: command, wantReply: true)
        context.triggerUserOutboundEvent(request).whenFailure { error in
            self.fail(error, context: context)
        }
    }

    nonisolated
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let data = unwrapInboundIn(data)

        guard case .byteBuffer(let buffer) = data.data else {
            return
        }

        let bytes = Array(buffer.readableBytesView)
        guard !bytes.isEmpty else { return }

        switch data.type {
        case .channel:
            stdout += bytes
        case .stdErr:
            stderr += bytes
        default:
            break
        }
    }

    nonisolated
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case is ChannelSuccessEvent:
            didAcceptRequest = true
        case is ChannelFailureEvent:
            fail(SSHClientError.keyProvisioningFailed("The SSH server rejected Relay's bootstrap command."), context: context)
        case let exitStatus as SSHChannelRequestEvent.ExitStatus:
            self.exitStatus = Int32(exitStatus.exitStatus)
            context.close(promise: nil)
        case let exitSignal as SSHChannelRequestEvent.ExitSignal:
            let signal = "Remote command terminated by signal \(exitSignal.signalName)."
            stderr += Array(signal.utf8)
            self.exitStatus = 1
            context.close(promise: nil)
        case ChannelEvent.inputClosed:
            context.close(promise: nil)
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    nonisolated
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        fail(error, context: context)
    }

    nonisolated
    func channelInactive(context: ChannelHandlerContext) {
        completeIfPossible()
    }

    nonisolated
    func handlerRemoved(context: ChannelHandlerContext) {
        completeIfPossible()
    }

    nonisolated
    private func completeIfPossible() {
        guard !hasCompleted else { return }
        hasCompleted = true

        if let exitStatus {
            resultPromise.succeed(
                SSHCommandResult(
                    stdout: String(decoding: stdout, as: UTF8.self),
                    stderr: String(decoding: stderr, as: UTF8.self),
                    exitStatus: exitStatus
                )
            )
            return
        }

        if didAcceptRequest {
            resultPromise.succeed(
                SSHCommandResult(
                    stdout: String(decoding: stdout, as: UTF8.self),
                    stderr: String(decoding: stderr, as: UTF8.self),
                    exitStatus: 0
                )
            )
            return
        }

        resultPromise.fail(SSHClientError.notConnected)
    }

    nonisolated
    private func fail(_ error: Error, context: ChannelHandlerContext) {
        guard !hasCompleted else {
            context.close(promise: nil)
            return
        }

        hasCompleted = true
        resultPromise.fail(error)
        context.close(promise: nil)
    }
}

private enum SSHAuthorizedKeysInstaller {
    static func installCommand(for publicKey: String) -> String {
        let escapedKey = shellQuoted(publicKey)
        return """
        umask 077
        mkdir -p ~/.ssh
        touch ~/.ssh/authorized_keys
        chmod 700 ~/.ssh
        chmod 600 ~/.ssh/authorized_keys
        if ! grep -qxF \(escapedKey) ~/.ssh/authorized_keys; then
          printf '%s\\n' \(escapedKey) >> ~/.ssh/authorized_keys
        fi
        """
    }

    private static func shellQuoted(_ string: String) -> String {
        "'" + string.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }
}
