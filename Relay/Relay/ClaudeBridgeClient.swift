//
//  ClaudeBridgeClient.swift
//  Relay
//
//  Created by Codex on 4/4/26.
//

import Foundation

@MainActor
final class ClaudeBridgeClient: VoiceAssistantBridgeClient {
    let assistant: VoiceAssistant = .claude

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
            throw ClaudeBridgeClientError.workspaceValidationFailed(message)
        }

        return resolvedPath
    }

    func sendTurn(
        _ prompt: String,
        workspacePath: String,
        onEvent: @escaping @MainActor (VoiceAssistantBridgeEvent) -> Void
    ) async throws {
        let trimmedPrompt = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedPrompt.isEmpty else {
            throw ClaudeBridgeClientError.emptyPrompt
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

        let emit: @Sendable (VoiceAssistantBridgeEvent) -> Void = { event in
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
                emit(.error(message: output.isEmpty ? "Claude bridge exited with status \(result.exitStatus)." : output, recoverable: true))
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
                throw ClaudeBridgeClientError.installationFailed(
                    output.isEmpty ? "Relay could not install the Claude voice bridge on the remote host." : output
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
    private static func parseBridgeEvent(from line: String) -> VoiceAssistantBridgeEvent? {
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
            let message = (object["message"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "Claude bridge failed."
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
        test -x \(remoteBridgePathShell) && command -v python3 >/dev/null 2>&1 && command -v claude >/dev/null 2>&1 && [ "$(python3 -u \(remoteBridgePathShell) --bridge-version)" = "\(bridgeVersion)" ]
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
        cat > \(remoteBridgePathShell) <<'__RELAY_CLAUDE_BRIDGE__'
        \(remoteBridgeScript)
        __RELAY_CLAUDE_BRIDGE__
        chmod 700 \(remoteBridgePathShell)
        if ! command -v python3 >/dev/null 2>&1; then
          printf '%s\n' 'python3 is not available on the remote host.'
          exit 127
        fi
        if ! command -v claude >/dev/null 2>&1; then
          printf '%s\n' 'claude is not available on the remote host. Relay looked in PATH and common Homebrew/local bin locations.'
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
    private static let remoteBridgePathShell = "\"$HOME/.relay/bin/relay-claude-bridge.py\""
    private static let bridgeVersion = "2026-04-04.1"
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
import threading
import uuid


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
        if node_type == "text":
            text = node.get("text")
            if isinstance(text, str):
                stripped = text.strip()
                if stripped:
                    values.append(stripped)
            return values
        for key in ("message", "content"):
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


def build_claude_command(prompt, session_id):
    return [
        "claude",
        "--print",
        "--verbose",
        "--output-format",
        "stream-json",
        "--include-partial-messages",
        "--session-id",
        session_id,
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

    session_id = (args.session_id or "").strip() or str(uuid.uuid4())
    emit("session_ready", session_id=session_id, cwd=cwd)

    command = build_claude_command(prompt, session_id)
    delivered_text = ""
    emitted_error = False

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
        emit("error", message=f"Relay could not launch Claude: {error}", recoverable=True)
        return 2

    emit("process_started", pid=process.pid)

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
                emit("tool_status", text=line)
                continue

            event_type = event.get("type")

            if event_type == "system" and event.get("subtype") == "init":
                session_id = event.get("session_id") or session_id
                emit("session_ready", session_id=session_id, cwd=cwd)
                continue

            if event_type == "assistant":
                if event.get("error"):
                    message_parts = collect_assistant_strings(event.get("message"))
                    message = message_parts[0] if message_parts else "Claude reported an error."
                    emit("error", message=message, recoverable=True)
                    emitted_error = True
                    continue

                for candidate in collect_assistant_strings(event.get("message")):
                    increment = normalize_increment(candidate, delivered_text)
                    if not increment:
                        continue
                    delivered_text += increment if not delivered_text else (" " + increment if not increment.startswith((" ", "\n")) else increment)
                    emit("assistant_delta", text=increment)
                continue

            if event_type == "result":
                result_text = str(event.get("result") or "").strip()
                if event.get("is_error") and not emitted_error:
                    errors = event.get("errors")
                    if isinstance(errors, list) and errors:
                        message = str(errors[0]).strip()
                    else:
                        message = result_text or "Claude exited with an error."
                    emit("error", message=message, recoverable=True)
                    emitted_error = True
                elif result_text:
                    increment = normalize_increment(result_text, delivered_text)
                    if increment:
                        delivered_text += increment if not delivered_text else (" " + increment if not increment.startswith((" ", "\n")) else increment)
                        emit("assistant_delta", text=increment)

                emit("assistant_done")
                return 0 if not event.get("is_error") else 1

    reader_thread.join(timeout=0.1)
    return_code = process.wait()

    if return_code in (-signal.SIGINT, -signal.SIGTERM):
        emit("assistant_done")
        return 0

    if return_code != 0 and not emitted_error:
        emit("error", message=f"Claude exited with status {return_code}.", recoverable=True)

    emit("assistant_done")
    return return_code


if __name__ == "__main__":
    raise SystemExit(main())
"""#
}

enum ClaudeBridgeClientError: LocalizedError {
    case emptyPrompt
    case workspaceValidationFailed(String)
    case installationFailed(String)

    var errorDescription: String? {
        switch self {
        case .emptyPrompt:
            return "Relay couldn't send an empty prompt to Claude."
        case .workspaceValidationFailed(let message):
            return message
        case .installationFailed(let message):
            return message
        }
    }
}
