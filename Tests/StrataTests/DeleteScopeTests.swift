import Foundation
import Testing
@testable import Strata

/// What deletes everything in a folder, or replaces what's at a path, must only ever reach the folder or path it's for:
/// Empty Trash only Trash folders, the bucket never as a whole, the `strata` command only its own link.
struct DeleteScopeTests {
    @Test func emptyTrashOnlyEverEmptiesTrashFolders() {
        let home = FileManager.default.homeDirectoryForCurrentUser
        #expect(Trash.home.path == home.appending(path: ".Trash").standardizedFileURL.path)
        for folder in Trash.folders() {
            let isHomeTrash = folder.standardizedFileURL.path == Trash.home.path
            let isDiskTrash = folder.lastPathComponent == String(getuid())
                && folder.deletingLastPathComponent().lastPathComponent == ".Trashes"
            #expect(isHomeTrash || isDiskTrash, "\(folder.path)")
            #expect(Trash.isTrash(folder), "\(folder.path)")
        }
    }

    @Test func noOtherFolderCountsAsATrash() throws {
        let uid = String(getuid())
        let tree = try TestTree(".Trash/", ".Trashes/", ".Trashes/\(uid)/", "home link -> \(Trash.home.deletingLastPathComponent().path)")
        let home = FileManager.default.homeDirectoryForCurrentUser
        for folder in [home, URL(fileURLWithPath: "/"), home.appending(path: "Documents"), home.appending(path: "Desktop"),
                       URL(fileURLWithPath: "/Users"), URL(fileURLWithPath: "/Volumes"), tree.root, tree.url(".Trash"),
                       tree.url(".Trashes"), tree.url(".Trashes/\(uid)"), tree.url("home link")] {
            #expect(!Trash.isTrash(folder), "\(folder.path)")
        }
    }

    @Test func aTrashIsNeverTrashedOrDeletedItself() throws {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let tree = try TestTree("a.txt", ".Trash/", "trash link -> \(Trash.home.path)", "home link -> \(home.path)")
        // The Trash however it's spelled (through a link to the home folder too), and anything in it.
        for url in [Trash.home, home.appending(path: ".TRASH"), home.appending(path: "./.Trash"), tree.url("home link/.Trash"),
                    Trash.home.appending(path: "a.txt")] {
            #expect(!FileOps.canTrash(url), "\(url.path)")
        }
        // A folder only named like one, and a link to it, are ordinary items.
        for path in ["a.txt", ".Trash", "trash link"] { #expect(FileOps.canTrash(tree.url(path)), "\(path)") }
        // Delete Immediately refuses it up front, and goes on with the rest.
        let plan = BrowserViewController.deletionPlan([Trash.home, tree.url("home link/.Trash"), tree.url("a.txt")])
        #expect(plan.refused.map(\.standardizedFileURL.path) == [Trash.home, tree.url("home link/.Trash")].map(\.standardizedFileURL.path))
        #expect(plan.candidates.map(\.path) == [tree.url("a.txt").standardizedFileURL.path])
        #expect(tree.snapshot() == [".Trash/", "a.txt", "home link -> \(home.path)", "trash link -> \(Trash.home.path)"])
    }

    @Test func removeDownloadFreesOnlyWhatsAlsoInTheCloud() throws {
        let tree = try TestTree("here.txt", "cloud.txt", "uploading.txt", "waiting.txt", "only cloud.txt", "plain.txt")
        let status: [String: CloudStatus] = ["here.txt": .downloaded, "cloud.txt": .downloaded, "uploading.txt": .uploading,
                                             "waiting.txt": .waitingToUpload, "only cloud.txt": .cloudOnly]
        let urls = tree.snapshot().map(tree.url)
        #expect(CloudActions.removable(urls) { status[$0.lastPathComponent] } == [tree.url("cloud.txt"), tree.url("here.txt")])
        // Outside a cloud folder, asking anyway changes nothing: each item is reported, and stays.
        #expect(CloudActions.removeDownload([tree.url("plain.txt")]).map(\.0) == [tree.url("plain.txt")])
        #expect(tree.text("plain.txt") == "plain.txt")
    }

    @Test func testsKeepToCachesOfTheirOwn() {
        // The app's caches hold the copies it has open (archives, servers, containers): tests never prune, sweep or
        // set aside those.
        let own = SecureStorage.directory.standardizedFileURL.path + "/"
        for root in [ArchiveCache.root, RemoteCopies.root, ContainerCopies.root, LazyCopies.clipboardRoot] {
            #expect(root.standardizedFileURL.path.hasPrefix(own), "\(root.path)")
        }
    }

    @Test func theCommandReplacesOnlyItsOwnLink() throws {
        let tree = try TestTree("tool", "folder/", "old -> /Applications/Strata.app/Contents/Helpers/strata",
                                "moved -> /Users/someone/Apps/Strata Beta.app/Contents/Helpers/strata",
                                "other -> /opt/homebrew/bin/strata", "lookalike -> /Applications/Strata.app/Contents/Helpers/strata-old")
        #expect(CommandLineTool.mayReplace(tree.url("nothing here").path))
        #expect(CommandLineTool.mayReplace(tree.url("old").path))
        #expect(CommandLineTool.mayReplace(tree.url("moved").path))
        for path in ["tool", "folder", "other", "lookalike"] {
            #expect(!CommandLineTool.mayReplace(tree.url(path).path), "\(path)")
        }
    }
}

/// Deleting on S3, against `FakeS3` holding a small bucket. There's no Trash there: a folder (a key prefix) goes with
/// exactly the keys under it, never a key that only starts the same.
extension S3Tests {
    /// Keys `FakeS3` answers from. `sloppy`: listings ignore the prefix asked for (a service that misbehaves).
    nonisolated final class Bucket: @unchecked Sendable {
        var keys: Set<String>
        var sloppy = false
        init(_ keys: Set<String>) { self.keys = keys }
    }

    /// Nonisolated: URLSession asks from its own thread.
    nonisolated private func serve(_ bucket: Bucket) {
        FakeS3.answer = { request in
            let key = String((request.url?.path ?? "/").dropFirst())
            switch request.httpMethod {
            case "HEAD":
                return (bucket.keys.contains(key) ? 200 : 404, ["Content-Length": "1"], Data())
            case "DELETE":
                bucket.keys.remove(key)
                return (204, [:], Data())
            default:
                let query = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)?.queryItems ?? []
                let prefix = query.first { $0.name == "prefix" }?.value ?? ""
                let listed = bucket.keys.sorted().filter { bucket.sloppy || $0.hasPrefix(prefix) }
                let contents = listed.map { "<Contents><Key>\($0)</Key><Size>1</Size></Contents>" }.joined()
                return (200, [:], Data("<ListBucketResult><IsTruncated>false</IsTruncated>\(contents)</ListBucketResult>".utf8))
            }
        }
    }

    @Test func deletingAFolderTakesOnlyTheKeysInIt() async throws {
        for sloppy in [false, true] {
            let bucket = Bucket(["photos/a.jpg", "photos/sub/b.jpg", "photos-old/c.jpg", "photos.txt", "other/photos/d.jpg"])
            bucket.sloppy = sloppy
            serve(bucket)
            try await S3Backend(client: client()).remove("/photos")
            #expect(bucket.keys == ["photos-old/c.jpg", "photos.txt", "other/photos/d.jpg"], "sloppy: \(sloppy)")
        }
    }

    @Test func deletingAFileTakesOnlyThatKey() async throws {
        let bucket = Bucket(["photos", "photos/a.jpg", "photos.txt"])
        serve(bucket)
        try await S3Backend(client: client()).remove("/photos.txt")
        #expect(bucket.keys == ["photos", "photos/a.jpg"])
        // A file and a folder of the same name: deleting the file leaves the folder.
        try await S3Backend(client: client()).remove("/photos")
        #expect(bucket.keys == ["photos/a.jpg"])
    }

    @Test func theBucketItselfIsNeverDeleted() async {
        let bucket = Bucket(["a.txt", "b/c.txt"])
        bucket.sloppy = true
        serve(bucket)
        for path in ["/", "", "//"] {
            await #expect(throws: (any Error).self, "\(path)") { try await S3Backend(client: client()).remove(path) }
        }
        #expect(bucket.keys == ["a.txt", "b/c.txt"])
    }
}
