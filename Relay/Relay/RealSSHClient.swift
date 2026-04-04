//
//  RealSSHClient.swift
//  Relay
//
//  Created by Codex on 4/4/26.
//

import Foundation
import NIOCore
import NIOTransportServices
import NIOSSH

@MainActor
final class RealSSHClient: SSHClient {
    private var session: SSHConnectionSession?

    func connect(to host: Host) async throws {
        if let session {
            await session.close()
            self.session = nil
        }

        guard let password = host.password, !password.isEmpty else {
            throw SSHClientError.missingPassword
        }

        self.session = try await SSHConnectionSession.connect(to: host, password: password)
    }

    func execute(_ command: String) async throws -> String {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw SSHClientError.emptyCommand
        }

        guard let session else {
            throw SSHClientError.notConnected
        }

        let output = try await session.execute(command: trimmed)
        return output.isEmpty ? "" : output
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
    private let sshHandler: NIOSSHHandler

    private init(group: NIOTSEventLoopGroup, rootChannel: Channel, sshHandler: NIOSSHHandler) {
        self.group = group
        self.rootChannel = rootChannel
        self.sshHandler = sshHandler
    }

    static func connect(to host: Host, password: String) async throws -> SSHConnectionSession {
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

        let bootstrap = NIOTSConnectionBootstrap(group: group)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(sshHandlerBox.handler)
                    try channel.pipeline.syncOperations.addHandler(SSHErrorHandler())
                }
            }

        do {
            let rootChannel = try await bootstrap.connect(host: host.hostname, port: host.port).get()
            return SSHConnectionSession(group: group, rootChannel: rootChannel, sshHandler: sshHandler)
        } catch {
            try? await group.shutdownGracefully()
            throw error
        }
    }

    func execute(command: String) async throws -> String {
        let promise = self.rootChannel.eventLoop.makePromise(of: SSHCommandResult.self)

        self.rootChannel.eventLoop.execute {
            let childPromise = self.rootChannel.eventLoop.makePromise(of: Channel.self)
            childPromise.futureResult.whenFailure { error in
                promise.fail(error)
            }

            self.sshHandler.createChannel(childPromise) { childChannel, channelType in
                guard channelType == .session else {
                    return childChannel.eventLoop.makeFailedFuture(SSHClientError.invalidChannelType)
                }

                return childChannel.eventLoop.makeCompletedFuture {
                    let handler = CommandExecutionHandler(command: command, resultPromise: promise)
                    try childChannel.pipeline.syncOperations.addHandler(handler)
                }
            }
        }

        let result = try await promise.futureResult.get()
        return result.combinedOutput
    }

    func close() async {
        try? await self.rootChannel.close().get()
        try? await self.group.shutdownGracefully()
    }
}

private struct SSHCommandResult: Sendable {
    var standardOutput = ""
    var standardError = ""
    var exitStatus: Int?

    var combinedOutput: String {
        if standardOutput.isEmpty {
            return standardError
        }

        if standardError.isEmpty {
            return standardOutput
        }

        return standardOutput + "\n" + standardError
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

private nonisolated final class CommandExecutionHandler: ChannelDuplexHandler {
    typealias InboundIn = SSHChannelData
    typealias OutboundIn = SSHChannelData
    typealias OutboundOut = SSHChannelData

    private let command: String
    private let resultPromise: EventLoopPromise<SSHCommandResult>

    private var result = SSHCommandResult()
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
        let execRequest = SSHChannelRequestEvent.ExecRequest(command: self.command, wantReply: false)
        context.triggerUserOutboundEvent(execRequest).whenFailure { error in
            self.fail(error, context: context)
        }
    }

    nonisolated
    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let data = self.unwrapInboundIn(data)

        guard case .byteBuffer(let buffer) = data.data else {
            return
        }

        let text = String(decoding: buffer.readableBytesView, as: UTF8.self)

        switch data.type {
        case .channel:
            self.result.standardOutput += text
        case .stdErr:
            self.result.standardError += text
        default:
            break
        }
    }

    nonisolated
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case let event as SSHChannelRequestEvent.ExitStatus:
            self.result.exitStatus = event.exitStatus
        case ChannelEvent.inputClosed:
            context.close(promise: nil)
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    nonisolated
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        self.fail(error, context: context)
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
    private func finish() {
        guard !self.hasCompleted else { return }
        self.hasCompleted = true
        self.resultPromise.succeed(self.result)
    }

    nonisolated
    private func fail(_ error: Error, context: ChannelHandlerContext) {
        guard !self.hasCompleted else { return }
        self.hasCompleted = true
        self.resultPromise.fail(error)
        context.close(promise: nil)
    }
}
