import Testing
@testable import JohnnyMetalRenderer

@Suite("JohnnyMetalRenderer skeleton")
struct JohnnyMetalRendererSkeletonTests {

    @Test("Module is importable and exposes a version marker")
    func versionMarker() {
        #expect(JohnnyMetalRenderer.version == "0.0.0-phase0")
    }

    @Test("JohnnyEngine dependency resolves")
    func engineDependency() {
        #expect(JohnnyMetalRenderer.engineVersion == "0.0.0-phase3")
    }
}
