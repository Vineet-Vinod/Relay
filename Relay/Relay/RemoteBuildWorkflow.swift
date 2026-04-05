//
//  RemoteBuildWorkflow.swift
//  Relay
//
//  Created by Codex on 4/4/26.
//

import Foundation

struct RemoteBuildWorkflowHostIdentity: Hashable, Codable, Sendable {
    let hostname: String
    let port: Int
    let username: String

    init(hostname: String, port: Int = 22, username: String) {
        self.hostname = hostname
        self.port = port
        self.username = username
    }

    var storageKey: String {
        "\(hostname.lowercased()):\(port):\(username.lowercased())"
    }
}

enum RemoteBuildWorkflowKind: String, CaseIterable, Codable, Hashable, Sendable {
    case build
    case test
    case lint
    case custom

    var title: String {
        switch self {
        case .build:
            return "Build"
        case .test:
            return "Test"
        case .lint:
            return "Lint"
        case .custom:
            return "Custom"
        }
    }
}

enum RemoteBuildWorkflowCommand: Hashable, Sendable {
    case make(arguments: [String])
    case shell(script: String)

    var summary: String {
        switch self {
        case .make(let arguments):
            let suffix = arguments.joined(separator: " ")
            return suffix.isEmpty ? "make" : "make \(suffix)"
        case .shell(let script):
            return script
        }
    }

    func invocationCommand(workingDirectory: String?) -> String? {
        let trimmedWorkingDirectory = workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines)
        let workingDirectoryPrefix: String
        if let trimmedWorkingDirectory, !trimmedWorkingDirectory.isEmpty {
            workingDirectoryPrefix = "cd -- \(Self.shellQuoted(trimmedWorkingDirectory)) && "
        } else {
            workingDirectoryPrefix = ""
        }

        switch self {
        case .make(let arguments):
            let command = ([ "/usr/bin/make" ] + arguments)
                .map(Self.shellQuoted)
                .joined(separator: " ")
            return workingDirectoryPrefix + command
        case .shell(let script):
            let trimmedScript = script.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedScript.isEmpty else {
                return nil
            }

            let strictScript = "set -euo pipefail\n\(trimmedScript)"
            return workingDirectoryPrefix + "/usr/bin/env bash -lc \(Self.shellQuoted(strictScript))"
        }
    }

    private static func shellQuoted(_ value: String) -> String {
        "'\(value.replacingOccurrences(of: "'", with: "'\"'\"'"))'"
    }
}

extension RemoteBuildWorkflowCommand: Codable {
    private enum CodingKeys: String, CodingKey {
        case type
        case arguments
        case script
    }

    private enum CommandType: String, Codable {
        case make
        case shell
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(CommandType.self, forKey: .type)

        switch type {
        case .make:
            let arguments = try container.decodeIfPresent([String].self, forKey: .arguments) ?? []
            self = .make(arguments: arguments)
        case .shell:
            let script = try container.decode(String.self, forKey: .script)
            self = .shell(script: script)
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)

        switch self {
        case .make(let arguments):
            try container.encode(CommandType.make, forKey: .type)
            try container.encode(arguments, forKey: .arguments)
        case .shell(let script):
            try container.encode(CommandType.shell, forKey: .type)
            try container.encode(script, forKey: .script)
        }
    }
}

struct RemoteBuildWorkflow: Identifiable, Hashable, Codable, Sendable {
    let id: UUID
    var name: String
    var kind: RemoteBuildWorkflowKind
    var workingDirectory: String?
    var command: RemoteBuildWorkflowCommand

    init(
        id: UUID = UUID(),
        name: String,
        kind: RemoteBuildWorkflowKind,
        workingDirectory: String? = nil,
        command: RemoteBuildWorkflowCommand
    ) {
        self.id = id
        self.name = name
        self.kind = kind
        self.workingDirectory = workingDirectory
        self.command = command
    }

    var displaySubtitle: String {
        command.summary
    }

    func invocationCommand(defaultWorkingDirectory: String? = nil) -> String? {
        let resolvedWorkingDirectory = resolvedWorkingDirectory(defaultWorkingDirectory: defaultWorkingDirectory)
        return command.invocationCommand(workingDirectory: resolvedWorkingDirectory)
    }

    func resolvedWorkingDirectory(defaultWorkingDirectory: String?) -> String? {
        let trimmedWorkflowDirectory = workingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let trimmedWorkflowDirectory, !trimmedWorkflowDirectory.isEmpty {
            return trimmedWorkflowDirectory
        }

        let trimmedDefaultDirectory = defaultWorkingDirectory?.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let trimmedDefaultDirectory, !trimmedDefaultDirectory.isEmpty else {
            return nil
        }

        return trimmedDefaultDirectory
    }
}

actor RemoteBuildWorkflowStore {
    static let shared = RemoteBuildWorkflowStore()

    private struct HostRecord: Codable, Hashable, Sendable {
        var host: RemoteBuildWorkflowHostIdentity
        var workflows: [RemoteBuildWorkflow]
    }

    private let defaults: UserDefaults
    private let storageKey = "relay.remote-build-workflows.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func workflows(for host: RemoteBuildWorkflowHostIdentity) -> [RemoteBuildWorkflow] {
        records()
            .first(where: { $0.host == host })?
            .workflows
            .sorted { lhs, rhs in
                lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
            } ?? []
    }

    func replaceWorkflows(_ workflows: [RemoteBuildWorkflow], for host: RemoteBuildWorkflowHostIdentity) {
        var currentRecords = records()

        if let index = currentRecords.firstIndex(where: { $0.host == host }) {
            currentRecords[index].workflows = workflows
        } else {
            currentRecords.append(HostRecord(host: host, workflows: workflows))
        }

        persist(currentRecords)
    }

    func upsert(_ workflow: RemoteBuildWorkflow, for host: RemoteBuildWorkflowHostIdentity) {
        var hostWorkflows = workflows(for: host)

        if let index = hostWorkflows.firstIndex(where: { $0.id == workflow.id }) {
            hostWorkflows[index] = workflow
        } else {
            hostWorkflows.append(workflow)
        }

        replaceWorkflows(hostWorkflows, for: host)
    }

    func removeWorkflow(id: RemoteBuildWorkflow.ID, for host: RemoteBuildWorkflowHostIdentity) {
        let filteredWorkflows = workflows(for: host).filter { $0.id != id }
        replaceWorkflows(filteredWorkflows, for: host)
    }

    func removeAll(for host: RemoteBuildWorkflowHostIdentity) {
        let filteredRecords = records().filter { $0.host != host }
        persist(filteredRecords)
    }

    private func persist(_ records: [HostRecord]) {
        guard let data = try? JSONEncoder().encode(records) else {
            return
        }

        defaults.set(data, forKey: storageKey)
    }

    private func records() -> [HostRecord] {
        guard let data = defaults.data(forKey: storageKey),
              let records = try? JSONDecoder().decode([HostRecord].self, from: data) else {
            return []
        }

        return records
    }
}
