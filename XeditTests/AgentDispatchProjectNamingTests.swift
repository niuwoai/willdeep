import Foundation
import Testing
@testable import WillDeep

/// The board used to derive its own project name from the folder path, so a
/// renamed project showed one name in the sidebar and another on the board.
/// These pin the unified naming and the exact same-project comparison it
/// enables.
@Suite
@MainActor
struct AgentDispatchProjectNamingTests {
    private let folder = "/Users/rocky/Sites/tokenhub"
    private let secondFolder = "/Users/rocky/Sites/tokenhub-web"

    private func managed(name: String = "TokenHub") -> AgentProject {
        AgentProject(displayName: name, folderPaths: [folder, secondFolder])
    }

    // MARK: Naming

    @Test("without a managed project the board still derives from the path")
    func fallsBackToPathDerivedName() {
        let resolved = AgentDispatchLogicalProjectResolver.resolve(
            location: .local(path: folder)
        )

        #expect(resolved.displayName == "tokenhub")
        #expect(resolved.managedProjectID == nil)
    }

    @Test("a managed project supplies the board's name")
    func managedProjectNamesTheBoard() {
        let project = managed(name: "TokenHub 网关")

        let resolved = AgentDispatchLogicalProjectResolver.resolve(
            location: .local(path: folder),
            managedProject: project
        )

        // The sidebar shows "TokenHub 网关"; the board must not say "tokenhub".
        #expect(resolved.displayName == "TokenHub 网关")
        #expect(resolved.managedProjectID == project.id)
    }

    @Test("an unnamed project falls back to its primary folder, not the session's")
    func unnamedProjectUsesPrimaryFolder() {
        let project = AgentProject(displayName: "  ", folderPaths: [folder, secondFolder])

        let resolved = AgentDispatchLogicalProjectResolver.resolve(
            // Session runs in the second folder…
            location: .local(path: secondFolder),
            managedProject: project
        )

        // …but the project's own primary folder names it.
        #expect(resolved.displayName == "tokenhub")
    }

    @Test("the board anchors on the project's primary folder")
    func primaryPathComesFromTheProject() {
        let project = managed()

        let resolved = AgentDispatchLogicalProjectResolver.resolve(
            location: .local(path: secondFolder),
            managedProject: project
        )

        // A project spans folders; the board must anchor where the sidebar does.
        #expect(resolved.primaryWorkspacePath == folder)
    }

    // MARK: Same-project comparison

    @Test("two folders of one project compare as the same project")
    func managedIDMakesFoldersEquivalent() {
        let project = managed()
        let fromBackend = AgentDispatchLogicalProjectResolver.resolve(
            location: .local(path: folder),
            managedProject: project
        )
        let fromFrontend = AgentDispatchLogicalProjectResolver.resolve(
            location: .local(path: secondFolder),
            managedProject: project
        )

        // Separate repos with different fingerprints — only the managed id
        // can tell they are one project.
        #expect(AgentDispatchLogicalProjectResolver.representsSameProject(fromBackend, fromFrontend))
    }

    @Test("different managed projects never compare as the same")
    func differentManagedProjectsDiffer() {
        let a = AgentDispatchLogicalProjectResolver.resolve(
            location: .local(path: folder),
            managedProject: managed(name: "A")
        )
        let b = AgentDispatchLogicalProjectResolver.resolve(
            location: .local(path: folder),
            managedProject: AgentProject(displayName: "B", folderPaths: [folder])
        )

        // Same folder, deliberately split into two projects by the user.
        #expect(!AgentDispatchLogicalProjectResolver.representsSameProject(a, b))
    }

    @Test("unmanaged comparison keeps the previous path and fingerprint rules")
    func unmanagedComparisonUnchanged() {
        let lhs = AgentDispatchLogicalProjectResolver.resolve(location: .local(path: folder))
        let rhs = AgentDispatchLogicalProjectResolver.resolve(location: .local(path: folder))
        let other = AgentDispatchLogicalProjectResolver.resolve(location: .local(path: secondFolder))

        #expect(AgentDispatchLogicalProjectResolver.representsSameProject(lhs, rhs))
        #expect(!AgentDispatchLogicalProjectResolver.representsSameProject(lhs, other))
    }

    @Test("a managed side and an unmanaged side fall through to the old rules")
    func mixedComparisonDoesNotShortCircuit() {
        // Only one side has an id, so the exact test cannot apply; the
        // path/fingerprint rules must still decide rather than returning false.
        let managedSide = AgentDispatchLogicalProjectResolver.resolve(
            location: .local(path: folder),
            managedProject: managed()
        )
        let plainSide = AgentDispatchLogicalProjectResolver.resolve(location: .local(path: folder))

        #expect(AgentDispatchLogicalProjectResolver.representsSameProject(managedSide, plainSide))
    }

    // MARK: Persistence

    @Test("the managed id survives encoding, and older records decode without one")
    func codableCompatibility() throws {
        let project = managed()
        let resolved = AgentDispatchLogicalProjectResolver.resolve(
            location: .local(path: folder),
            managedProject: project
        )

        let decoded = try JSONDecoder().decode(
            AgentDispatchLogicalProject.self,
            from: try JSONEncoder().encode(resolved)
        )
        #expect(decoded.managedProjectID == project.id)

        let legacy = """
        {
          "id": "\(UUID().uuidString)",
          "displayName": "tokenhub",
          "primaryWorkspacePath": "\(folder)"
        }
        """
        let legacyDecoded = try JSONDecoder().decode(
            AgentDispatchLogicalProject.self,
            from: Data(legacy.utf8)
        )
        #expect(legacyDecoded.managedProjectID == nil)
        #expect(legacyDecoded.displayName == "tokenhub")
    }
}
