import Testing
@testable import JohnnyDebug

@Suite("JohnnyDebug skeleton")
struct JohnnyDebugSkeletonTests {

    @Test("Module is importable and exposes a version marker")
    func versionMarker() {
        #expect(JohnnyDebug.version == "0.0.0-phase0")
    }

    @Test("Engine and renderer dependencies resolve")
    func dependenciesResolve() {
        let versions = JohnnyDebug.dependencyVersions
        #expect(versions.engine == "0.0.0-phase3")
        #expect(versions.renderer == "0.0.0-phase4")
    }
}
