import Testing
@testable import PortlightKit

/// The data-protection class the stores request. It is checked here as requested because the iOS Simulator reports
/// completeUntilFirstUserAuthentication for every file whatever was asked for; the hosted `FileProtectionHostedTests`
/// check the class files actually get.
@Suite("Persistence: file protection")
struct PersistenceFileProtectionTests {
    @Test func everyWriteIsAtomic() {
        #expect(PersistenceFileProtection.writesAtomically)
    }

    #if os(iOS)
    @Test func filesAndTheirDirectoryStayReadableAfterTheFirstUnlock() {
        #expect(PersistenceFileProtection.fileWrite == "completeUntilFirstUserAuthentication")
        #expect(PersistenceFileProtection.directory == "completeUntilFirstUserAuthentication")
    }
    #else
    @Test func macOSRequestsNoProtectionClass() {
        #expect(PersistenceFileProtection.fileWrite == "none")
        #expect(PersistenceFileProtection.directory == "none")
    }
    #endif
}
