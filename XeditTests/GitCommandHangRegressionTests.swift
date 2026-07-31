//
//  GitCommandHangRegressionTests.swift
//  WillDeepTests
//
//  Guards the subprocess-output failure that previously stranded the main
//  thread while waiting for Git pipe readers to observe EOF.
//

import Foundation
import Testing
@testable import WillDeep

@Suite(.serialized)
struct GitCommandHangRegressionTests {
    @Test("并发 Git 输出读取会全部结束且保留完整输出")
    func concurrentGitOutputDrainsComplete() async throws {
        let repository = FileManager.default.temporaryDirectory
            .appendingPathComponent(
                "willdeep-git-output-regression-\(UUID().uuidString)",
                isDirectory: true
            )
        try FileManager.default.createDirectory(
            at: repository,
            withIntermediateDirectories: true
        )
        defer { try? FileManager.default.removeItem(at: repository) }

        let initialization = AppState.runGitCommand(
            arguments: ["init"],
            in: repository,
            timeout: 5
        )
        try #require(initialization.succeeded)

        let results = await withTaskGroup(
            of: Bool.self,
            returning: [Bool].self
        ) { group in
            for _ in 0..<24 {
                group.addTask {
                    let result = AppState.runGitCommand(
                        arguments: ["rev-parse", "--show-toplevel"],
                        in: repository,
                        timeout: 5
                    )
                    return result.succeeded
                        && !result.stdout
                            .trimmingCharacters(in: .whitespacesAndNewlines)
                            .isEmpty
                }
            }

            var completed: [Bool] = []
            for await result in group {
                completed.append(result)
            }
            return completed
        }

        #expect(results.count == 24)
        #expect(results.allSatisfy { $0 })
    }
}
