//
//  AgentExternalFileTools.swift
//  WillDeep
//
//  Exact-target host-native file operations that intentionally cross the
//  workspace boundary after AgentExternalFileWritePolicy authorization.
//

import Foundation
import WillDeepCore

nonisolated enum AgentExternalFileTools {
    /// Repeat authorization invariants at dispatch time, atomically write the
    /// exact canonical target, and verify the bytes from that same disk path.
    static func writeFile(
        arguments: [String: AgentJSONValue],
        context: AgentToolContext
    ) async throws -> AgentToolResult {
        guard let rawPath = arguments["path"]?.stringValue()?
            .trimmingCharacters(in: .whitespacesAndNewlines),
            !rawPath.isEmpty else {
            throw AgentToolError.missingArgument("path")
        }
        guard let content = arguments["content"]?.stringValue() else {
            throw AgentToolError.missingArgument("content")
        }
        guard let lexicalURL = AgentExternalFileWritePolicy.resolveAbsolutePath(rawPath) else {
            throw AgentToolError.invalidArgument(
                "write_file requires an absolute or home-relative external path; use create_file/edit_file for workspace-relative paths."
            )
        }
        if let values = try? lexicalURL.resourceValues(forKeys: [.isSymbolicLinkKey]),
           values.isSymbolicLink == true {
            throw AgentToolError.invalidArgument(
                "write_file refuses a symbolic-link target because it would not verify the exact requested path."
            )
        }
        guard let target = AgentExternalFileWritePolicy.target(
            arguments: arguments,
            rootDirectory: context.rootDirectory
        ) else {
            throw AgentToolError.invalidArgument(
                "External target must be a regular file path outside the workspace with an existing parent directory."
            )
        }
        // 宿主自己的数据目录：任何审批档位都不写，包括完全访问。审批层
        // 已把它标成敏感路径，这里是执行时的最后一道，防止绕过审批的路径。
        if let protectedRoot = AgentHostDataPathPolicy.protectedRoot(
            containing: target.url,
            nativeFileWritesOnly: true
        ) {
            throw AgentToolError.protectedHostDataPath(
                path: target.url.path,
                protectedRoot: protectedRoot.path
            )
        }

        let fileManager = FileManager.default
        guard target.parentExists else {
            throw AgentToolError.notFound(target.url.deletingLastPathComponent().path)
        }
        let parentPath = target.url.deletingLastPathComponent().path
        guard fileManager.isWritableFile(atPath: parentPath) else {
            throw AgentToolError.invalidArgument(
                "External target directory is not writable: \(parentPath)"
            )
        }
        if target.existedBeforeWrite && !target.overwriteRequested {
            throw AgentToolError.invalidArgument(
                "External target already exists. Set overwrite=true only when replacement is intended: \(target.url.path)"
            )
        }

        let expectedData = Data(content.utf8)
        let originalPermissions = target.existedBeforeWrite
            ? (try? fileManager.attributesOfItem(atPath: target.url.path)[.posixPermissions])
            : nil
        do {
            try expectedData.write(to: target.url, options: .atomic)
            if let originalPermissions {
                try? fileManager.setAttributes(
                    [.posixPermissions: originalPermissions],
                    ofItemAtPath: target.url.path
                )
            }
            guard try Data(contentsOf: target.url) == expectedData else {
                throw AgentToolError.invalidArgument(
                    "External write verification failed for exact target: \(target.url.path)"
                )
            }
        } catch let error as AgentToolError {
            throw error
        } catch {
            throw AgentToolError.invalidArgument(
                "Could not write and verify external target \(target.url.path): \(error.localizedDescription)"
            )
        }

        let action = target.existedBeforeWrite ? "replaced" : "created"
        return AgentToolResult(
            summary: "external file \(action) and verified",
            payload: """
            External file \(action) and verified on disk.
            Exact path: \(target.url.path)
            UTF-8 bytes: \(expectedData.count)
            Verification: byte-for-byte readback succeeded
            """
        )
    }
}
