//
//  CodexBridgeClient.swift
//  Relay
//
//  Created by Codex on 4/4/26.
//

import Foundation
import NIOCore
import NIOSSH
import NIOTransportServices

enum CodexBridgeEvent: Sendable {
    case sessionReady(sessionID: String?, cwd: String?)
    case cwdResolved(String)
    case processStarted(Int32)
    case assistantDelta(String)
    case assistantDone
    case toolStatus(String)
    case error(message: String, recoverable: Bool)
}

@MainActor
final class CodexBridgeClient {
    private let host: Host
    private let credentials: SSHCredentialStore

    private var hasVerifiedBridgeInstallation = false
    private var activeSessionID: String?
    private var activeTurnSession: BridgeSSHStreamingCommandSession?
    private var activeRemoteProcessID: Int32?
    private var isInterruptingTurn = false

    init(host: Host, credentials: SSHCredentialStore = RelayServices.sshCredentials) {
        self.host = host
        self.credentials = credentials
    }

    func prepare(workspacePath: String) async throws -> String {
        try await ensureBridgeInstalled()
        activeSessionID = nil

        let result = try await runBufferedCommand(
            command: Self.bridgeValidationCommand(workspacePath: workspacePath)
        )

        let resolvedPath = parseResolvedWorkingDirectory(from: result.stdout)
        guard result.exitStatus == 0, let resolvedPath else {
            let message = parseBridgeError(from: result.stdout) ?? Self.sanitizedBridgeOutput(from: result.stderr + "\n" + result.stdout)
            throw CodexBridgeClientError.workspaceValidationFailed(message)
        }

        return resolvedPath
    }

    func sendTurn(
        _ prompt: String,
        workspacePath: String,
        onEvent: @escaping @MainActor (CodexBridgeEvent) -> Void
    ) async throws {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else {
            throw CodexBridgeClientError.emptyPrompt
        }

        try await ensureBridgeInstalled()
        let command = Self.bridgeInvocationCommand(
            workspacePath: workspacePath,
            sessionID: activeSessionID,
            prompt: trimmedPrompt
        )

        let stdoutBuffer = BridgeLineBuffer()
        let stderrBuffer = BridgeLineBuffer()
        isInterruptingTurn = false

        let emit: @Sendable (CodexBridgeEvent) -> Void = { event in
            Task { @MainActor in
                onEvent(event)
            }
        }

        let session = try await BridgeSSHCommandExecutor.startStreamingCommand(
            to: host,
            credentials: credentials,
            command: command,
            stdoutSink: { bytes in
                stdoutBuffer.consume(bytes: bytes) { line in
                    if let event = Self.parseBridgeEvent(from: line) {
                        switch event {
                        case .sessionReady(let sessionID, _):
                            if let sessionID {
                                Task { @MainActor in
                                    self.activeSessionID = sessionID
                                }
                            }
                        case .processStarted(let processID):
                            Task { @MainActor in
                                self.activeRemoteProcessID = processID
                            }
                        default:
                            break
                        }
                        emit(event)
                    }
                }
            },
            stderrSink: { bytes in
                stderrBuffer.consume(bytes: bytes) { line in
                    let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else { return }
                    emit(.toolStatus(trimmed))
                }
            }
        )

        activeTurnSession = session

        defer {
            activeTurnSession = nil
            activeRemoteProcessID = nil
            isInterruptingTurn = false
        }

        try await withTaskCancellationHandler {
            let result = try await session.waitForCompletion()

            stdoutBuffer.flush { line in
                if let event = Self.parseBridgeEvent(from: line) {
                    switch event {
                    case .sessionReady(let sessionID, _):
                        if let sessionID {
                            Task { @MainActor in
                                self.activeSessionID = sessionID
                            }
                        }
                    case .processStarted(let processID):
                        Task { @MainActor in
                            self.activeRemoteProcessID = processID
                        }
                    default:
                        break
                    }
                    emit(event)
                }
            }

            stderrBuffer.flush { line in
                let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else { return }
                emit(.toolStatus(trimmed))
            }

            guard result.exitStatus == 0 || isInterruptingTurn else {
                let output = Self.sanitizedBridgeOutput(from: result.stderr + "\n" + result.stdout)
                emit(.error(message: output.isEmpty ? "Codex bridge exited with status \(result.exitStatus)." : output, recoverable: true))
                return
            }
        } onCancel: {
            Task {
                await session.close()
            }
        }
    }

    func interruptCurrentTurn() async {
        guard let activeTurnSession else { return }
        isInterruptingTurn = true
        if let activeRemoteProcessID {
            _ = try? await runBufferedCommand(command: Self.bridgeInterruptCommand(processID: activeRemoteProcessID))
        }
        await activeTurnSession.close()
    }

    func endSession() async {
        activeSessionID = nil
        await interruptCurrentTurn()
    }

    private func ensureBridgeInstalled() async throws {
        if hasVerifiedBridgeInstallation {
            return
        }

        let checkResult = try await runBufferedCommand(command: Self.bridgePresenceCheckCommand())
        if checkResult.exitStatus != 0 {
            let installResult = try await runBufferedCommand(command: Self.bridgeInstallationCommand())
            guard installResult.exitStatus == 0 else {
                let output = Self.sanitizedBridgeOutput(from: installResult.stderr + "\n" + installResult.stdout)
                throw CodexBridgeClientError.installationFailed(
                    output.isEmpty ? "Relay could not install the Codex voice bridge on the remote host." : output
                )
            }
        }

        hasVerifiedBridgeInstallation = true
    }

    private func runBufferedCommand(command: String) async throws -> BridgeSSHCommandResult {
        let timeoutSeconds = RelayPreferences.shared.connectionTimeoutSeconds
        let host = self.host
        let credentials = self.credentials
        return try await withThrowingTaskGroup(of: BridgeSSHCommandResult.self) { group in
            group.addTask {
                try await BridgeSSHCommandExecutor.runCommand(
                    to: host,
                    credentials: credentials,
                    command: command
                )
            }

            group.addTask {
                try await Task.sleep(for: .seconds(timeoutSeconds))
                throw SSHClientError.connectionTimedOut(seconds: timeoutSeconds)
            }

            guard let result = try await group.next() else {
                throw SSHClientError.connectionTimedOut(seconds: timeoutSeconds)
            }

            group.cancelAll()
            return result
        }
    }

    private func parseResolvedWorkingDirectory(from output: String) -> String? {
        output
            .split(whereSeparator: \.isNewline)
            .compactMap { Self.parseBridgeEvent(from: String($0)) }
            .compactMap { event -> String? in
                if case .cwdResolved(let cwd) = event {
                    return cwd
                }
                return nil
            }
            .last
    }

    private func parseBridgeError(from output: String) -> String? {
        output
            .split(whereSeparator: \.isNewline)
            .compactMap { Self.parseBridgeEvent(from: String($0)) }
            .compactMap { event -> String? in
                if case .error(let message, _) = event {
                    return message
                }
                return nil
            }
            .last
    }

    nonisolated
    private static func parseBridgeEvent(from line: String) -> CodexBridgeEvent? {
        guard let data = line.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let type = object["type"] as? String else {
            return nil
        }

        switch type {
        case "session_ready":
            return .sessionReady(
                sessionID: object["session_id"] as? String,
                cwd: object["cwd"] as? String
            )
        case "cwd_resolved":
            guard let cwd = object["cwd"] as? String else { return nil }
            return .cwdResolved(cwd)
        case "process_started":
            guard let pid = object["pid"] as? Int else { return nil }
            return .processStarted(Int32(pid))
        case "assistant_delta":
            guard let text = object["text"] as? String, !text.isEmpty else { return nil }
            return .assistantDelta(text)
        case "assistant_done":
            return .assistantDone
        case "tool_status":
            guard let text = object["text"] as? String, !text.isEmpty else { return nil }
            return .toolStatus(text)
        case "error":
            let message = (object["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Codex bridge failed."
            let recoverable = object["recoverable"] as? Bool ?? true
            return .error(message: message, recoverable: recoverable)
        default:
            return nil
        }
    }

    nonisolated
    private static func sanitizedBridgeOutput(from rawOutput: String) -> String {
        rawOutput
            .split(whereSeparator: \.isNewline)
            .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { line in
                !line.isEmpty &&
                !line.hasPrefix("{\"type\":\"cwd_resolved\"") &&
                !line.hasPrefix("{\"type\":\"session_ready\"") &&
                !line.hasPrefix("{\"type\":\"assistant_done\"")
            }
            .joined(separator: "\n")
    }

    nonisolated
    private static func bridgePresenceCheckCommand() -> String {
        remoteShellCommand("""
        set -eu
        \(remoteEnvironmentBootstrap)
        test -x \(remoteBridgePathShell) && command -v python3 >/dev/null 2>&1 && command -v codex >/dev/null 2>&1 && [ "$(python3 -u \(remoteBridgePathShell) --bridge-version)" = "\(bridgeVersion)" ]
        """)
    }

    nonisolated
    private static func bridgeValidationCommand(workspacePath: String) -> String {
        remoteShellCommand("""
        set -eu
        \(remoteEnvironmentBootstrap)
        python3 -u \(remoteBridgePathShell) --check --cwd \(shellQuoted(workspacePath))
        """)
    }

    nonisolated
    private static func bridgeInvocationCommand(
        workspacePath: String,
        sessionID: String?,
        prompt: String
    ) -> String {
        var command = """
        set -eu
        \(remoteEnvironmentBootstrap)
        python3 -u \(remoteBridgePathShell) --cwd \(shellQuoted(workspacePath)) --prompt \(shellQuoted(prompt))
        """

        if let sessionID, !sessionID.isEmpty {
            command += " --session-id \(shellQuoted(sessionID))"
        }

        return remoteShellCommand(command)
    }

    nonisolated
    private static func bridgeInterruptCommand(processID: Int32) -> String {
        remoteShellCommand("""
        set -eu
        kill -INT -- -\(processID) >/dev/null 2>&1 || kill -INT \(processID) >/dev/null 2>&1 || true
        """)
    }

    nonisolated
    private static func bridgeInstallationCommand() -> String {
        remoteShellCommand("""
        set -eu
        \(remoteEnvironmentBootstrap)
        umask 077
        mkdir -p \(remoteBridgeDirectoryShell)
        cat > \(remoteBridgePathShell) <<'__RELAY_CODEX_BRIDGE__'
        \(remoteBridgeScript)
        __RELAY_CODEX_BRIDGE__
        chmod 700 \(remoteBridgePathShell)
        if ! command -v python3 >/dev/null 2>&1; then
          printf '%s\n' 'python3 is not available on the remote host.'
          exit 127
        fi
        if ! command -v codex >/dev/null 2>&1; then
          printf '%s\n' 'codex is not available on the remote host. Relay looked in PATH and common Homebrew/local bin locations.'
          exit 127
        fi
        """)
    }

    nonisolated
    private static func shellQuoted(_ string: String) -> String {
        "'" + string.replacingOccurrences(of: "'", with: "'\"'\"'") + "'"
    }

    nonisolated
    private static func remoteShellCommand(_ script: String) -> String {
        "/bin/sh -lc \(shellQuoted(script))"
    }

    private static let remoteBridgeDirectoryShell = "\"$HOME/.relay/bin\""
    private static let remoteBridgePathShell = "\"$HOME/.relay/bin/relay-codex-bridge.py\""
    private static let bridgeVersion = "2026-04-04.6"
    private static let remoteEnvironmentBootstrap = """
    export PATH="$PATH:/opt/homebrew/bin:/usr/local/bin:$HOME/.local/bin:$HOME/bin"
    """

    private static let remoteBridgeScript = #"""
#!/usr/bin/env python3
import argparse
import json
import os
import queue
import signal
import subprocess
import sys
import tempfile
import threading
import time
import threading
import time


def emit(event_type, **fields):
    payload = {"type": event_type}
    payload.update(fields)
    sys.stdout.write(json.dumps(payload) + "\n")
    sys.stdout.flush()


def resolve_cwd(raw_cwd):
    expanded = os.path.expanduser(raw_cwd)
    resolved = os.path.abspath(expanded)
    if not os.path.isdir(resolved):
        raise RuntimeError(f"Workspace does not exist: {resolved}")
    return resolved


def collect_assistant_strings(node):
    values = []
    if isinstance(node, str):
        stripped = node.strip()
        if stripped:
            values.append(stripped)
        return values
    if isinstance(node, list):
        for item in node:
            values.extend(collect_assistant_strings(item))
        return values
    if isinstance(node, dict):
        role = node.get("role")
        if role not in (None, "assistant"):
            return values
        node_type = str(node.get("type") or "")
        if node_type.startswith("tool") or node_type in {"thread.started", "turn.started"}:
            return values
        for key in ("delta", "text", "output_text"):
            value = node.get(key)
            if isinstance(value, str):
                stripped = value.strip()
                if stripped:
                    values.append(stripped)
        for key in ("content", "message", "item", "parts"):
            value = node.get(key)
            if isinstance(value, (dict, list)):
                values.extend(collect_assistant_strings(value))
        return values
    return values


def normalize_increment(text, delivered_text):
    stripped = text.strip()
    if not stripped:
        return ""
    if delivered_text and stripped.startswith(delivered_text):
        stripped = stripped[len(delivered_text):].lstrip()
    if not stripped:
        return ""
    return stripped


def build_codex_command(cwd, prompt, session_id, output_path):
    if session_id:
        return [
            "codex",
            "exec",
            "resume",
            "--full-auto",
            "--json",
            "--skip-git-repo-check",
            "-o",
            output_path,
            session_id,
            prompt,
        ]
    return [
        "codex",
        "exec",
        "--full-auto",
        "--json",
        "--skip-git-repo-check",
        "-C",
        cwd,
        "-o",
        output_path,
        prompt,
    ]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--cwd")
    parser.add_argument("--prompt")
    parser.add_argument("--session-id")
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--bridge-version", action="store_true")
    args = parser.parse_args()

    if args.bridge_version:
        print("\#(bridgeVersion)")
        return 0

    if not args.cwd:
        emit("error", message="No workspace was provided.", recoverable=True)
        return 2

    try:
        cwd = resolve_cwd(args.cwd)
    except RuntimeError as error:
        emit("error", message=str(error), recoverable=True)
        return 2

    emit("cwd_resolved", cwd=cwd)

    if args.check:
        return 0

    prompt = (args.prompt or "").strip()
    if not prompt:
        emit("error", message="No prompt was provided.", recoverable=True)
        return 2

    with tempfile.NamedTemporaryFile(prefix="relay-codex-", suffix=".txt", delete=False) as output_file:
        output_path = output_file.name

    command = build_codex_command(cwd, prompt, args.session_id, output_path)
    delivered_text = ""
    session_id = args.session_id

    try:
        process = subprocess.Popen(
            command,
            cwd=cwd,
            stdin=subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
            start_new_session=True,
        )
    except OSError as error:
        emit("error", message=f"Relay could not launch Codex: {error}", recoverable=True)
        return 2

    emit("process_started", pid=process.pid)

    if session_id:
        emit("session_ready", session_id=session_id, cwd=cwd)

    line_queue = queue.Queue()

    def pump_output(stream, output_queue):
        if stream is None:
            output_queue.put(None)
            return
        for raw_line in stream:
            output_queue.put(raw_line)
        output_queue.put(None)

    reader_thread = threading.Thread(
        target=pump_output,
        args=(process.stdout, line_queue),
        daemon=True,
    )
    reader_thread.start()

    if process.stdout is not None:
        while True:
            try:
                raw_line = line_queue.get(timeout=1)
            except queue.Empty:
                if process.poll() is not None:
                    break
                continue

            if raw_line is None:
                break

            line = raw_line.strip()
            if not line:
                continue

            try:
                event = json.loads(line)
            except json.JSONDecodeError:
                if line.startswith("WARNING:"):
                    continue
                emit("tool_status", text=line)
                continue

            event_type = event.get("type")
            if event_type == "thread.started":
                session_id = event.get("thread_id") or session_id
                emit("session_ready", session_id=session_id, cwd=cwd)
                continue

            if event_type == "error":
                message = str(event.get("message") or "Codex reported an error.")
                emit("error", message=message, recoverable=True)
                continue

            if event_type == "turn.started":
                continue

            for candidate in collect_assistant_strings(event):
                increment = normalize_increment(candidate, delivered_text)
                if not increment:
                    continue
                delivered_text += increment if not delivered_text else (" " + increment if not increment.startswith((" ", "\n")) else increment)
                emit("assistant_delta", text=increment)

    reader_thread.join(timeout=0.1)
    return_code = process.wait()

    try:
        with open(output_path, "r", encoding="utf-8") as handle:
            final_text = handle.read().strip()
    except OSError:
        final_text = ""
    finally:
        try:
            os.unlink(output_path)
        except OSError:
            pass

    increment = normalize_increment(final_text, delivered_text)
    if increment:
        emit("assistant_delta", text=increment)

    if return_code in (-signal.SIGINT, -signal.SIGTERM):
        emit("assistant_done")
        return 0

    if return_code != 0:
        emit("error", message=f"Codex exited with status {return_code}.", recoverable=True)

    emit("assistant_done")
    return return_code


if __name__ == "__main__":
    raise SystemExit(main())
"""#
}

enum CodexBridgeClientError: LocalizedError {
    case emptyPrompt
    case workspaceValidationFailed(String)
    case installationFailed(String)

    var errorDescription: String? {
        switch self {
        case .emptyPrompt:
            return "Relay couldn't send an empty prompt to Codex."
        case .workspaceValidationFailed(let message):
            return message
        case .installationFailed(let message):
            return message
        }
    }
}

private struct BridgeSSHCommandResult: Sendable {
    let stdout: String
    let stderr: String
    let exitStatus: Int32
}

private struct BridgeSSHConnectedRoot {
    let group: NIOTSEventLoopGroup
    let rootChannel: Channel
    let sshHandler: BridgeSSHHandlerBox
}

private enum BridgeSSHAuthentication {
    case password(String)
    case privateKey(NIOSSHPrivateKey)
}

private enum BridgeSSHCommandExecutor {
    static func runCommand(
        to host: Host,
        credentials: SSHCredentialStore,
        command: String
    ) async throws -> BridgeSSHCommandResult {
        let resultBox = BridgeSSHStreamingResultBox()
        let session = try await startStreamingCommand(
            to: host,
            credentials: credentials,
            command: command,
            stdoutSink: { bytes in
                resultBox.appendStdout(bytes)
            },
            stderrSink: { bytes in
                resultBox.appendStderr(bytes)
            }
        )

        defer {
            Task {
                await session.close()
            }
        }

        let result = try await session.waitForCompletion()
        return BridgeSSHCommandResult(
            stdout: resultBox.stdoutString,
            stderr: resultBox.stderrString,
            exitStatus: result.exitStatus
        )
    }

    static func startStreamingCommand(
        to host: Host,
        credentials: SSHCredentialStore,
        command: String,
        stdoutSink: @escaping @Sendable ([UInt8]) -> Void,
        stderrSink: @escaping @Sendable ([UInt8]) -> Void
    ) async throws -> BridgeSSHStreamingCommandSession {
        let authentication = try resolveAuthentication(for: host, credentials: credentials)
        let root = try await openRootConnection(
            to: host,
            authentication: authentication,
            trustStore: credentials
        )

        do {
            return try await openExecChannel(
                root: root,
                command: command,
                stdoutSink: stdoutSink,
                stderrSink: stderrSink
            )
        } catch {
            try? await close(root: root)
            throw error
        }
    }

    private static func resolveAuthentication(
        for host: Host,
        credentials: SSHCredentialStore
    ) throws -> BridgeSSHAuthentication {
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

    private static func openRootConnection(
        to host: Host,
        authentication: BridgeSSHAuthentication,
        trustStore: SSHCredentialStore
    ) async throws -> BridgeSSHConnectedRoot {
        let group = NIOTSEventLoopGroup(loopCount: 1)
        let authDelegate = BridgeCredentialAuthenticationDelegate(username: host.username, authentication: authentication)
        let hostKeyDelegate = BridgeTrustOnFirstUseHostKeysDelegate(endpoint: host.endpointIdentity, store: trustStore)
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
        let sshHandlerBox = BridgeSSHHandlerBox(handler: sshHandler)
        let authenticationPromise = group.next().makePromise(of: Void.self)
        let authenticationHandler = BridgeSSHAuthenticationStateHandler(authenticationPromise: authenticationPromise)

        let bootstrap = NIOTSConnectionBootstrap(group: group)
            .channelInitializer { channel in
                channel.eventLoop.makeCompletedFuture {
                    try channel.pipeline.syncOperations.addHandler(sshHandlerBox.handler)
                    try channel.pipeline.syncOperations.addHandler(authenticationHandler)
                    try channel.pipeline.syncOperations.addHandler(BridgeSSHErrorHandler())
                }
            }

        do {
            let rootChannel = try await bootstrap.connect(host: host.hostname, port: host.port).get()
            try await authenticationPromise.futureResult.get()
            return BridgeSSHConnectedRoot(group: group, rootChannel: rootChannel, sshHandler: sshHandlerBox)
        } catch {
            try? await group.shutdownGracefully()
            throw error
        }
    }

    private static func close(root: BridgeSSHConnectedRoot) async throws {
        try await root.rootChannel.close().get()
        try await root.group.shutdownGracefully()
    }

    private static func openExecChannel(
        root: BridgeSSHConnectedRoot,
        command: String,
        stdoutSink: @escaping @Sendable ([UInt8]) -> Void,
        stderrSink: @escaping @Sendable ([UInt8]) -> Void
    ) async throws -> BridgeSSHStreamingCommandSession {
        let readyPromise = root.rootChannel.eventLoop.makePromise(of: Void.self)
        let resultPromise = root.rootChannel.eventLoop.makePromise(of: BridgeSSHCommandResult.self)
        let childPromise = root.rootChannel.eventLoop.makePromise(of: Channel.self)

        root.rootChannel.eventLoop.execute {
            root.sshHandler.handler.createChannel(childPromise) { childChannel, channelType in
                guard channelType == .session else {
                    return childChannel.eventLoop.makeFailedFuture(SSHClientError.invalidChannelType)
                }

                return childChannel.eventLoop.makeCompletedFuture {
                    let handler = BridgeStreamingExecCommandHandler(
                        command: command,
                        readyPromise: readyPromise,
                        resultPromise: resultPromise,
                        stdoutSink: stdoutSink,
                        stderrSink: stderrSink
                    )
                    try childChannel.pipeline.syncOperations.addHandler(handler)
                }
            }
        }

        let childChannel = try await childPromise.futureResult.get()
        try await readyPromise.futureResult.get()
        return BridgeSSHStreamingCommandSession(
            group: root.group,
            rootChannel: root.rootChannel,
            commandChannel: childChannel,
            resultPromise: resultPromise
        )
    }
}

private final class BridgeSSHStreamingResultBox: @unchecked Sendable {
    private let lock = NSLock()
    private var stdout = [UInt8]()
    private var stderr = [UInt8]()

    func appendStdout(_ bytes: [UInt8]) {
        lock.withLock {
            stdout += bytes
        }
    }

    func appendStderr(_ bytes: [UInt8]) {
        lock.withLock {
            stderr += bytes
        }
    }

    var stdoutString: String {
        lock.withLock {
            String(decoding: stdout, as: UTF8.self)
        }
    }

    var stderrString: String {
        lock.withLock {
            String(decoding: stderr, as: UTF8.self)
        }
    }
}

private final class BridgeLineBuffer: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()

    func consume(bytes: [UInt8], onLine: (String) -> Void) {
        lock.withLock {
            if !bytes.isEmpty {
                buffer.append(contentsOf: bytes)
            }

            while let newlineIndex = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer.prefix(upTo: newlineIndex)
                buffer.removeSubrange(...newlineIndex)

                guard let line = String(data: lineData, encoding: .utf8) else {
                    continue
                }

                let trimmed = line.trimmingCharacters(in: .newlines)
                guard !trimmed.isEmpty else { continue }
                onLine(trimmed)
            }
        }
    }

    func flush(onLine: (String) -> Void) {
        lock.withLock {
            guard !buffer.isEmpty, let line = String(data: buffer, encoding: .utf8) else {
                buffer.removeAll(keepingCapacity: false)
                return
            }

            let trimmed = line.trimmingCharacters(in: .newlines)
            if !trimmed.isEmpty {
                onLine(trimmed)
            }
            buffer.removeAll(keepingCapacity: false)
        }
    }
}

private final class BridgeSSHStreamingCommandSession: @unchecked Sendable {
    private let group: NIOTSEventLoopGroup
    private let rootChannel: Channel
    private let commandChannel: Channel
    private let resultPromise: EventLoopPromise<BridgeSSHCommandResult>

    init(
        group: NIOTSEventLoopGroup,
        rootChannel: Channel,
        commandChannel: Channel,
        resultPromise: EventLoopPromise<BridgeSSHCommandResult>
    ) {
        self.group = group
        self.rootChannel = rootChannel
        self.commandChannel = commandChannel
        self.resultPromise = resultPromise
    }

    func waitForCompletion() async throws -> BridgeSSHCommandResult {
        try await resultPromise.futureResult.get()
    }

    func close() async {
        try? await commandChannel.close().get()
        try? await rootChannel.close().get()
        try? await group.shutdownGracefully()
    }
}

private final class BridgeSSHHandlerBox: @unchecked Sendable {
    let handler: NIOSSHHandler

    init(handler: NIOSSHHandler) {
        self.handler = handler
    }
}

private nonisolated final class BridgeCredentialAuthenticationDelegate: NIOSSHClientUserAuthenticationDelegate {
    private var authRequest: NIOSSHUserAuthenticationOffer?
    private let requestedMethod: NIOSSHAvailableUserAuthenticationMethods

    init(username: String, authentication: BridgeSSHAuthentication) {
        switch authentication {
        case .password(let password):
            authRequest = NIOSSHUserAuthenticationOffer(
                username: username,
                serviceName: "",
                offer: .password(.init(password: password))
            )
            requestedMethod = .password
        case .privateKey(let privateKey):
            authRequest = NIOSSHUserAuthenticationOffer(
                username: username,
                serviceName: "",
                offer: .privateKey(.init(privateKey: privateKey))
            )
            requestedMethod = .publicKey
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

private nonisolated final class BridgeTrustOnFirstUseHostKeysDelegate: NIOSSHClientServerAuthenticationDelegate {
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

private nonisolated final class BridgeSSHErrorHandler: ChannelInboundHandler {
    typealias InboundIn = Any

    nonisolated
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }
}

private nonisolated final class BridgeSSHAuthenticationStateHandler: ChannelInboundHandler, @unchecked Sendable {
    typealias InboundIn = Any

    private let authenticationPromise: EventLoopPromise<Void>
    private var hasCompleted = false

    init(authenticationPromise: EventLoopPromise<Void>) {
        self.authenticationPromise = authenticationPromise
    }

    nonisolated
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        if event is UserAuthSuccessEvent {
            succeedIfNeeded()
        }

        context.fireUserInboundEventTriggered(event)
    }

    nonisolated
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        failIfNeeded(error)
        context.fireErrorCaught(error)
    }

    nonisolated
    func channelInactive(context: ChannelHandlerContext) {
        failIfNeeded(SSHClientError.authenticationFailed)
        context.fireChannelInactive()
    }

    nonisolated
    func handlerRemoved(context: ChannelHandlerContext) {
        failIfNeeded(SSHClientError.authenticationFailed)
    }

    nonisolated
    private func succeedIfNeeded() {
        guard !hasCompleted else { return }
        hasCompleted = true
        authenticationPromise.succeed(())
    }

    nonisolated
    private func failIfNeeded(_ error: Error) {
        guard !hasCompleted else { return }
        hasCompleted = true
        authenticationPromise.fail(normalize(error))
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

private nonisolated final class BridgeStreamingExecCommandHandler: ChannelDuplexHandler, @unchecked Sendable {
    typealias InboundIn = SSHChannelData
    typealias OutboundIn = SSHChannelData
    typealias OutboundOut = SSHChannelData

    private let command: String
    private let readyPromise: EventLoopPromise<Void>
    private let resultPromise: EventLoopPromise<BridgeSSHCommandResult>
    private let stdoutSink: @Sendable ([UInt8]) -> Void
    private let stderrSink: @Sendable ([UInt8]) -> Void

    private var stdout = [UInt8]()
    private var stderr = [UInt8]()
    private var exitStatus: Int32?
    private var didAcceptRequest = false
    private var hasCompleted = false
    private var hasCompletedReady = false

    init(
        command: String,
        readyPromise: EventLoopPromise<Void>,
        resultPromise: EventLoopPromise<BridgeSSHCommandResult>,
        stdoutSink: @escaping @Sendable ([UInt8]) -> Void,
        stderrSink: @escaping @Sendable ([UInt8]) -> Void
    ) {
        self.command = command
        self.readyPromise = readyPromise
        self.resultPromise = resultPromise
        self.stdoutSink = stdoutSink
        self.stderrSink = stderrSink
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
            stdoutSink(bytes)
        case .stdErr:
            stderr += bytes
            stderrSink(bytes)
        default:
            break
        }
    }

    nonisolated
    func userInboundEventTriggered(context: ChannelHandlerContext, event: Any) {
        switch event {
        case is ChannelSuccessEvent:
            didAcceptRequest = true
            succeedReadyIfNeeded()
        case is ChannelFailureEvent:
            let error = SSHClientError.keyProvisioningFailed("The SSH server rejected Relay's Codex bridge command.")
            failReadyIfNeeded(error)
            fail(error, context: context)
        case let exitStatus as SSHChannelRequestEvent.ExitStatus:
            self.exitStatus = Int32(exitStatus.exitStatus)
            context.close(promise: nil)
        case let exitSignal as SSHChannelRequestEvent.ExitSignal:
            let signal = "Remote command terminated by signal \(exitSignal.signalName)."
            let bytes = Array(signal.utf8)
            stderr += bytes
            stderrSink(bytes)
            exitStatus = 1
            context.close(promise: nil)
        case ChannelEvent.inputClosed:
            context.close(promise: nil)
        default:
            context.fireUserInboundEventTriggered(event)
        }
    }

    nonisolated
    func errorCaught(context: ChannelHandlerContext, error: Error) {
        failReadyIfNeeded(error)
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
        failReadyIfNeeded(SSHClientError.notConnected)

        if let exitStatus {
            resultPromise.succeed(
                BridgeSSHCommandResult(
                    stdout: String(decoding: stdout, as: UTF8.self),
                    stderr: String(decoding: stderr, as: UTF8.self),
                    exitStatus: exitStatus
                )
            )
            return
        }

        if didAcceptRequest {
            resultPromise.succeed(
                BridgeSSHCommandResult(
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
    private func succeedReadyIfNeeded() {
        guard !hasCompletedReady else { return }
        hasCompletedReady = true
        readyPromise.succeed(())
    }

    nonisolated
    private func failReadyIfNeeded(_ error: Error) {
        guard !hasCompletedReady else { return }
        hasCompletedReady = true
        readyPromise.fail(error)
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

private extension NSLock {
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer {
            unlock()
        }
        return body()
    }
}
