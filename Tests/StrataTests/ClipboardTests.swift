import AppKit
import Foundation
import Testing
@testable import Strata

/// Cut and paste: a paste moves only when the clipboard still holds Strata's own Cut. Once anything else is put there,
/// by Strata or another app, the next paste copies. Each test uses a pasteboard of its own, never the real one.
@Suite(.serialized) @MainActor struct ClipboardTests {
    private func withPasteboard(_ body: @MainActor (NSPasteboard) async throws -> Void) async rethrows {
        let board = NSPasteboard(name: .init("dev.strata.test.\(UUID().uuidString)"))
        Clipboard.pasteboard = board
        Clipboard.clearCut()
        defer {
            Clipboard.clearCut()
            Clipboard.pasteboard = .general
            board.releaseGlobally()
        }
        try await body(board)
    }

    private func wait(until condition: () -> Bool) async {
        for _ in 0..<100 where !condition() { try? await Task.sleep(for: .milliseconds(30)) }
    }

    @Test func aPasteAfterCutMovesOnlyWhatWasCut() async throws {
        try await withPasteboard { _ in
            let tree = try TestTree("left/", "left/a.txt", "left/ab.txt", "left/b/", "left/b/c.txt", "right/", "right/d.txt")
            let window = BrowserWindowController(location: tree.url("left"), secondPane: tree.url("right"))
            let other = try #require(window.otherBrowser)
            await wait { window.browser.itemCount == 3 && other.itemCount == 1 }
            window.browser.select([tree.url("left/a.txt"), tree.url("left/b")])
            window.browser.cut(nil)
            #expect(Clipboard.isCut(tree.url("left/a.txt")) && !Clipboard.isCut(tree.url("left/ab.txt")))
            other.paste(nil)
            await wait { tree.snapshot().contains("right/b/c.txt") }
            #expect(tree.snapshot() == ["left/", "left/ab.txt", "right/", "right/a.txt", "right/b/", "right/b/c.txt", "right/d.txt"])
            // The Cut is used up: nothing is marked any more.
            #expect(!Clipboard.read().isCut && !Clipboard.isCut(tree.url("left/a.txt")))
        }
    }

    @Test func aCopyOrAnotherAppEndsTheCut() async throws {
        try await withPasteboard { board in
            let tree = try TestTree("a.txt", "b.txt")
            Clipboard.write([tree.url("a.txt")], cut: true)
            #expect(Clipboard.read() == ([tree.url("a.txt")], true))
            // Copy in Strata: copies from now on.
            Clipboard.write([tree.url("b.txt")], cut: false)
            #expect(Clipboard.read() == ([tree.url("b.txt")], false) && !Clipboard.isCut(tree.url("a.txt")))
            // Another app puts the very same files there: still a copy, not Strata's Cut.
            Clipboard.write([tree.url("a.txt")], cut: true)
            board.clearContents()
            board.writeObjects([tree.url("a.txt") as NSURL])
            #expect(Clipboard.read() == ([tree.url("a.txt")], false) && !Clipboard.isCut(tree.url("a.txt")))
            // Or text: no files to paste at all.
            Clipboard.write([tree.url("a.txt")], cut: true)
            board.clearContents()
            board.setString(tree.url("a.txt").path, forType: .string)
            #expect(Clipboard.read().urls.isEmpty && !Clipboard.hasFiles)
            #expect(tree.snapshot() == ["a.txt", "b.txt"])
        }
    }

    @Test func aPasteAfterAnotherAppsCopyLeavesTheOriginals() async throws {
        try await withPasteboard { board in
            let tree = try TestTree("left/", "left/a.txt", "right/")
            let window = BrowserWindowController(location: tree.url("left"), secondPane: tree.url("right"))
            let other = try #require(window.otherBrowser)
            await wait { window.browser.itemCount == 1 && other.itemCount == 0 }
            window.browser.select([tree.url("left/a.txt")])
            window.browser.cut(nil)
            board.clearContents()
            board.writeObjects([tree.url("left/a.txt") as NSURL])
            other.paste(nil)
            await wait { tree.snapshot().contains("right/a.txt") }
            #expect(tree.snapshot() == ["left/", "left/a.txt", "right/", "right/a.txt"])
        }
    }
}
