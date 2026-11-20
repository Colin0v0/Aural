import Testing
@testable import AuxmoCore

struct AuxmoVersionTests {
    @Test func versionComparisonUsesNumericComponents() throws {
        let older = try #require(AuxmoVersionNumber("v0.1.9"))
        let newer = try #require(AuxmoVersionNumber("0.1.10"))
        let stable = try #require(AuxmoVersionNumber("0.2.0"))
        let prerelease = try #require(AuxmoVersionNumber("0.2.0-beta.1"))
        let betaTwo = try #require(AuxmoVersionNumber("0.2.0-beta.2"))
        let betaTen = try #require(AuxmoVersionNumber("0.2.0-beta.10"))

        #expect(older < newer)
        #expect(prerelease < stable)
        #expect(betaTwo < betaTen)
    }

    @Test(arguments: ["", "v", "1.x.0", "1..2"])
    func invalidVersionStringsAreRejected(value: String) {
        #expect(AuxmoVersionNumber(value) == nil)
    }
}
