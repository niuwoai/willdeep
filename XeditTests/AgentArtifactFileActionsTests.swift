import Foundation
import Testing
@testable import WillDeep

@Suite
struct AgentArtifactFileActionsTests {
    @Test("open-with application cache loads each content type once")
    func openWithApplicationCacheReusesLoadedApplications() {
        let cache = AgentArtifactOpenWithApplicationCache()
        let application = AgentArtifactOpenWithApplication(
            url: URL(fileURLWithPath: "/Applications/TextEdit.app")
        )
        var loadCount = 0

        let first = cache.applications(for: "content-type:public.plain-text") {
            loadCount += 1
            return [application]
        }
        let second = cache.applications(for: "content-type:public.plain-text") {
            loadCount += 1
            return []
        }

        #expect(loadCount == 1)
        #expect(first == [application])
        #expect(second == first)
    }

    @Test("open-with cache keys are case-insensitive and content-type based")
    func openWithApplicationCacheKeyUsesContentType() {
        let lowercase = AgentArtifactFileActions.openWithApplicationsCacheKey(
            for: URL(fileURLWithPath: "/tmp/report.txt")
        )
        let uppercase = AgentArtifactFileActions.openWithApplicationsCacheKey(
            for: URL(fileURLWithPath: "/tmp/report.TXT")
        )
        let markdown = AgentArtifactFileActions.openWithApplicationsCacheKey(
            for: URL(fileURLWithPath: "/tmp/report.md")
        )

        #expect(lowercase == uppercase)
        #expect(lowercase != markdown)
        #expect(lowercase.hasPrefix("content-type:"))
    }
}
