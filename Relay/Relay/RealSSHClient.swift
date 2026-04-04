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
    private var session: SSHConnectionSession?
    private var eventHandler: (@MainActor @Sendable (TerminalEvent) -> Void)?

    func setEventHandler(_ handler: (@MainActor @Sendable (TerminalEvent) -> Void)?) {
        self.eventHandler = handler
    }

    func connect(to host: Host) async throws {
        if let session {
            await session.close()
            self.session = nil
        }

        guard let password = host.password, !password.isEmpty else {
            throw SSHClientError.missingPassword
        }

        let emit: @Sendable (TerminalEvent) -> Void = { [eventHandler] event in
            guard let eventHandler else { return }
            Task { @MainActor in
                eventHandler(event)
            }
        }

        self.session = try await SSHConnectionSession.connect(to: host, password: password, eventSink: emit)
        emit(.status("Connected."))
    }

    func sendInput(_ text: String) async throws {
        let trimmed = text.trimmingCharacters(in: .newlines)
        guard !trimmed.isEmpty else {
            throw SSHClientError.emptyCommand
        }

        guard let session else {
            throw SSHClientError.notConnected
        }

        try await session.sendInput(text + "\n")
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
}

private final class SSHConnectionSession {
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
        password: String,
        eventSink: @escaping @Sendable (TerminalEvent) -> Void
    ) async throws -> SSHConnectionSession {
        let group = NIOTSEventLoopGroup(loopCount: 1)
        let authDelegate = PasswordAuthenticationDelegate(username: host.username, password: password)
        let hostKeyDelegate = AcceptAllHostKeysDelegate()
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
            let shellChannel = try await Self.openShellChannel(
                rootChannel: rootChannel,
                sshHandler: sshHandler,
                eventSink: eventSink
            )
            return SSHConnectionSession(group: group, rootChannel: rootChannel, shellChannel: shellChannel)
        } catch {
            try? await group.shutdownGracefully()
            throw error
        }
    }

    func sendInput(_ text: String) async throws {
        guard self.shellChannel.isActive else {
            throw SSHClientError.notConnected
        }

        var buffer = self.shellChannel.allocator.buffer(capacity: text.utf8.count)
        buffer.writeString(text)
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

    private static func openShellChannel(
        rootChannel: Channel,
        sshHandler: NIOSSHHandler,
        eventSink: @escaping @Sendable (TerminalEvent) -> Void
    ) async throws -> Channel {
        let readyPromise = rootChannel.eventLoop.makePromise(of: Void.self)
        let childPromise = rootChannel.eventLoop.makePromise(of: Channel.self)

        rootChannel.eventLoop.execute {
            sshHandler.createChannel(childPromise) { childChannel, channelType in
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
}

private final class SSHHandlerBox: @unchecked Sendable {
    let handler: NIOSSHHandler

    init(handler: NIOSSHHandler) {
        self.handler = handler
    }
}

private nonisolated final class PasswordAuthenticationDelegate: NIOSSHClientUserAuthenticationDelegate {
    private let username: String
    private let password: String

    init(username: String, password: String) {
        self.username = username
        self.password = password
    }

    nonisolated
    func nextAuthenticationType(
        availableMethods: NIOSSHAvailableUserAuthenticationMethods,
        nextChallengePromise: EventLoopPromise<NIOSSHUserAuthenticationOffer?>
    ) {
        guard availableMethods.contains(.password) else {
            nextChallengePromise.fail(SSHClientError.missingPassword)
            return
        }

        nextChallengePromise.succeed(
            NIOSSHUserAuthenticationOffer(
                username: self.username,
                serviceName: "",
                offer: .password(.init(password: self.password))
            )
        )
    }
}

private nonisolated final class AcceptAllHostKeysDelegate: NIOSSHClientServerAuthenticationDelegate {
    nonisolated
    func validateHostKey(hostKey: NIOSSHPublicKey, validationCompletePromise: EventLoopPromise<Void>) {
        validationCompletePromise.succeed(())
    }
}

private nonisolated final class SSHErrorHandler: ChannelInboundHandler {
    typealias InboundIn = Any

    nonisolated
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}

private nonisolated final class SSHAuthenticationStateHandler: ChannelInboundHandler {
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

private nonisolated final class InteractiveShellHandler: ChannelDuplexHandler {
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
            term: "xterm-256color",
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

        let text = String(decoding: buffer.readableBytesView, as: UTF8.self)
        guard !text.isEmpty else { return }

        switch data.type {
        case .channel, .stdErr:
            self.eventSink(.output(text))
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

        self.eventSink(.error(self.describe(error)))
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
            self.eventSink(.error(self.describe(underlyingError)))
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
    private func describe(_ error: Error) -> String {
        if let localizedError = error as? LocalizedError, let description = localizedError.errorDescription {
            return description
        }

        return String(describing: error)
    }
}
