import Foundation
import Testing
@testable import Strata

/// Delete Immediately (⌥⌘⌫) and Empty Trash: only what was chosen goes, never anything beside, above or behind it.
struct DeleteTests {
    private func delete(_ urls: [URL]) async -> (refused: [URL], failures: [(url: URL, error: Error)]) {
        let plan = BrowserViewController.deletionPlan(urls)
        return (plan.refused, await BrowserViewController.deleteAll(plan.candidates))
    }

    @Test func onlyTheSelectedItemsGo() async throws {
        let tree = try TestTree("a/", "a/inner.txt", "b.txt", "ab.txt", "abc/", "abc/keep.txt", "c/", "c/b.txt")
        let result = await delete([tree.url("a"), tree.url("b.txt")])
        #expect(result.refused.isEmpty && result.failures.isEmpty)
        // Names that start the same ("ab.txt", "abc") and the same name elsewhere ("c/b.txt") stay.
        #expect(tree.snapshot() == ["ab.txt", "abc/", "abc/keep.txt", "c/", "c/b.txt"])
    }

    @Test func itemsInsideSelectedFoldersAreLeftToTheirFolder() async throws {
        let tree = try TestTree("a/", "a/b/", "a/b/c.txt", "a/d.txt", "e.txt")
        let plan = BrowserViewController.deletionPlan([tree.url("a/b/c.txt"), tree.url("a"), tree.url("a/b")])
        #expect(plan.candidates.map(\.lastPathComponent) == ["a"])
        let failures = await BrowserViewController.deleteAll(plan.candidates)
        #expect(failures.isEmpty)
        #expect(tree.snapshot() == ["e.txt"])
    }

    @Test func aSelectedLinkGoesNotWhatItPointsTo() async throws {
        let tree = try TestTree("target/", "target/precious.txt", "file.txt", "folder link -> target", "file link -> file.txt",
                                "dangling -> nowhere")
        let result = await delete([tree.url("folder link"), tree.url("file link"), tree.url("dangling")])
        #expect(result.refused.isEmpty && result.failures.isEmpty)
        #expect(tree.snapshot() == ["file.txt", "target/", "target/precious.txt"])
    }

    @Test func aFolderHoldingLinksDeletesTheLinksNotTheirTargets() async throws {
        let tree = try TestTree("outside/", "outside/precious.txt", "doomed/", "doomed/escape -> outside",
                                "doomed/deep/", "doomed/deep/up -> outside/precious.txt")
        let result = await delete([tree.url("doomed")])
        #expect(result.failures.isEmpty)
        #expect(tree.snapshot() == ["outside/", "outside/precious.txt"])
    }

    @Test func oddNamesAreTakenLiterally() async throws {
        let tree = try TestTree("*", "-rf", "a b", "a", "b", "über.txt", "uber.txt", "..dots", "[x]", "x")
        let result = await delete([tree.url("*"), tree.url("a b"), tree.url("über.txt"), tree.url("[x]")])
        #expect(result.failures.isEmpty)
        #expect(tree.snapshot() == ["-rf", "..dots", "a", "b", "uber.txt", "x"])
    }

    @Test func disksAreRefused() {
        let plan = BrowserViewController.deletionPlan([URL(fileURLWithPath: "/")])
        #expect(plan.candidates.isEmpty)
        #expect(plan.refused.map(\.path) == ["/"])
    }

    @Test func itemsInFoldersThatCantChangeAreRefusedWhole() async throws {
        let tree = try TestTree("locked/", "locked/inside/", "locked/inside/file.txt", "free.txt")
        chmod(tree.url("locked").path, 0o555)
        let result = await delete([tree.url("locked/inside"), tree.url("free.txt")])
        #expect(result.refused.map(\.lastPathComponent) == ["inside"])
        #expect(result.failures.isEmpty)
        // Refused up front: deleting "inside" would have emptied it before failing on the folder itself.
        #expect(tree.snapshot() == ["locked/", "locked/inside/", "locked/inside/file.txt"])
    }

    @Test func aLockedFileFailsAloneAndTheRestGo() async throws {
        let tree = try TestTree("a.txt", "locked.txt", "b.txt", "keep.txt")
        #expect(chflags(tree.url("locked.txt").path, UInt32(UF_IMMUTABLE)) == 0)
        let result = await delete([tree.url("a.txt"), tree.url("locked.txt"), tree.url("b.txt")])
        #expect(result.failures.map(\.url.lastPathComponent) == ["locked.txt"])
        #expect(tree.snapshot() == ["keep.txt", "locked.txt"])
    }

    @Test func somethingAlreadyGoneIsReportedAndNothingElseIsTouched() async throws {
        let tree = try TestTree("a.txt", "b.txt")
        let result = await delete([tree.url("gone.txt"), tree.url("a.txt")])
        #expect(result.failures.map(\.url.lastPathComponent) == ["gone.txt"])
        #expect(tree.snapshot() == ["b.txt"])
    }

    // MARK: - Empty Trash

    @Test func emptyingATrashDeletesWhatsInItAndNothingElse() throws {
        let tree = try TestTree("Trash/", "Trash/old.txt", "Trash/folder/", "Trash/folder/inner.txt",
                                "Trash/link to outside -> outside", "Trash/folder/escape -> outside/precious.txt",
                                "outside/", "outside/precious.txt", "sibling.txt")
        let failures = Trash.empty([tree.url("Trash")])
        #expect(failures.isEmpty)
        // The Trash itself stays; links in it go, what they point to doesn't.
        #expect(tree.snapshot() == ["Trash/", "outside/", "outside/precious.txt", "sibling.txt"])
    }

    @Test func aTrashThatIsALinkIsNeverFollowed() throws {
        let tree = try TestTree("elsewhere/", "elsewhere/precious.txt", "Trash -> elsewhere")
        _ = Trash.empty([tree.url("Trash")])
        #expect(tree.snapshot() == ["Trash -> elsewhere", "elsewhere/", "elsewhere/precious.txt"])
    }

    @Test func aLockedItemInTheTrashIsReportedAndTheRestGo() throws {
        let tree = try TestTree("Trash/", "Trash/locked.txt", "Trash/a.txt", "Trash/b/", "Trash/b/c.txt")
        #expect(chflags(tree.url("Trash/locked.txt").path, UInt32(UF_IMMUTABLE)) == 0)
        let failures = Trash.empty([tree.url("Trash")])
        #expect(failures.map(\.url.lastPathComponent) == ["locked.txt"])
        #expect(tree.snapshot() == ["Trash/", "Trash/locked.txt"])
    }

    // MARK: - Test runs

    @Test func testRunsKeepHistoryAndIndexesOutOfYourOwn() {
        #expect(SecureStorage.isTestRun)
        #expect(SecureStorage.directory.path.hasPrefix(FileManager.default.temporaryDirectory.path))
        #expect(!SecureStorage.directory.path.contains("/Library/Application Support/"))
    }
}
