//===----------------------------------------------------------------------===//
// Copyright © 2026 Apple Inc. and the container project authors.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//   https://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.
//===----------------------------------------------------------------------===//

import Darwin
import Foundation
import Testing

@testable import ContainerCommands

@Suite(.serialized)
struct LogFollowTests {
    enum Command: CaseIterable, Sendable {
        case container, machine

        func tail(_ handle: FileHandle, follow: Bool) async throws {
            switch self {
            case .container:
                try await Application.ContainerLogs.tail(fh: handle, n: nil, follow: follow)
            case .machine:
                try await Application.MachineLogs.tail(fh: handle, n: nil, follow: follow)
            }
        }
    }

    @Test(arguments: Command.allCases)
    func followsAnInitiallyEmptyLog(command: Command) async throws {
        try await assertFollowing(command: command, initial: "")
    }

    @Test(arguments: Command.allCases)
    func printsHistoryBeforeFollowing(command: Command) async throws {
        try await assertFollowing(command: command, initial: "history-\(UUID())\n")
    }

    @Test(arguments: Command.allCases)
    func emptyLogWithoutFollowReturns(command: Command) async throws {
        try await withLog(initial: "") { reader, _ in
            try await command.tail(reader, follow: false)
            #expect(reader.readabilityHandler == nil)
        }
    }

    private func assertFollowing(command: Command, initial: String) async throws {
        try await withLog(initial: initial) { reader, writer in
            try await withCapturedOutput { outputURL in
                let task = Task { try await command.tail(reader, follow: true) }
                do {
                    let ready = try await waitUntil { reader.readabilityHandler != nil }
                    try #require(ready, "Following must start even when the log is initially empty")
                    let appended = "appended-\(UUID())"
                    try writer.write(contentsOf: Data("\(appended)\n".utf8))
                    let received = try await waitUntil {
                        let output = try String(contentsOf: outputURL, encoding: .utf8)
                        return output.contains(appended)
                    }
                    #expect(received, "Follow mode must emit writes made after the initial read")
                    if !initial.isEmpty {
                        let output = try String(contentsOf: outputURL, encoding: .utf8)
                        let historyRange = try #require(output.range(of: initial))
                        let appendedRange = try #require(output.range(of: appended))
                        #expect(historyRange.upperBound <= appendedRange.lowerBound, "Follow mode must print history before new writes")
                    }
                } catch {
                    task.cancel()
                    _ = try? await task.value
                    reader.readabilityHandler = nil
                    throw error
                }
                task.cancel()
                try await task.value
                reader.readabilityHandler = nil
            }
        }
    }

    private func waitUntil(_ condition: () throws -> Bool) async throws -> Bool {
        let deadline = ContinuousClock.now.advanced(by: .seconds(3))
        while ContinuousClock.now < deadline {
            if try condition() { return true }
            try await Task.sleep(for: .milliseconds(10))
        }
        return try condition()
    }

    private func withLog(initial: String, body: (FileHandle, FileHandle) async throws -> Void) async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data(initial.utf8).write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let reader = try FileHandle(forReadingFrom: url)
        defer {
            reader.readabilityHandler = nil
            try? reader.close()
        }
        let writer = try FileHandle(forWritingTo: url)
        defer { try? writer.close() }
        _ = try writer.seekToEnd()
        try await body(reader, writer)
    }

    private func withCapturedOutput(body: (URL) async throws -> Void) async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try Data().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let output = try FileHandle(forWritingTo: url)
        defer { try? output.close() }
        fflush(stdout)
        let saved = dup(STDOUT_FILENO)
        try #require(saved >= 0)
        defer { close(saved) }
        try #require(dup2(output.fileDescriptor, STDOUT_FILENO) >= 0)
        defer {
            fflush(stdout)
            dup2(saved, STDOUT_FILENO)
        }
        try await body(url)
    }
}
