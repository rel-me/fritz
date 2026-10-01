import Foundation
import NativeMarkupDevelopment
import Testing

@MainActor
struct MarkupFileLoaderTests {
    @Test func atomicSaveReadFailureAndRecovery() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Panel.xml")
        try Data("first".utf8).write(to: url)
        let loader = MarkupFileLoader()
        defer { loader.stop() }
        await loader.open(url)
        #expect(loader.source == "first")

        // Editors replace files atomically; a watcher tied only to the old inode would miss this.
        try Data("other".utf8).write(to: url, options: .atomic)
        try await eventually { loader.source == "other" }
        try FileManager.default.removeItem(at: url)
        try await eventually { loader.diagnostic != nil }
        #expect(loader.source == "other")
        try Data("fixed".utf8).write(to: url, options: .atomic)
        try await eventually { loader.source == "fixed" && loader.diagnostic == nil }
    }

    @Test func boundsEncodingAndStop() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let url = directory.appendingPathComponent("Panel.xml")
        let loader = MarkupFileLoader()
        defer { loader.stop() }
        try Data(repeating: 65, count: 256 * 1024 + 1).write(to: url)
        await loader.open(url)
        #expect(loader.source == nil)
        #expect(loader.diagnostic?.contains("256 KiB") == true)
        try Data([0xff]).write(to: url, options: .atomic)
        await loader.open(url)
        #expect(loader.diagnostic?.contains("UTF-8") == true)
        try Data("valid".utf8).write(to: url, options: .atomic)
        await loader.open(url)
        #expect(loader.source == "valid")
        loader.stop()
        try Data("after stop".utf8).write(to: url, options: .atomic)
        try await Task.sleep(for: .milliseconds(800))
        #expect(loader.source == "valid")
    }

    @Test func switchingFilesReplacesTheWatch() async throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let first = directory.appendingPathComponent("First.xml")
        let second = directory.appendingPathComponent("Second.xml")
        try Data("first".utf8).write(to: first)
        try Data("second".utf8).write(to: second)
        let loader = MarkupFileLoader()
        defer { loader.stop() }
        await loader.open(first)
        await loader.open(second)
        try Data("current".utf8).write(to: second, options: .atomic)
        try await eventually { loader.source == "current" }
        try Data("stale".utf8).write(to: first, options: .atomic)
        try await Task.sleep(for: .milliseconds(800))
        #expect(loader.source == "current")
        #expect(loader.fileURL == second)
        #expect(loader.diagnostic == nil)

        let canceled = Task { await loader.open(first) }
        canceled.cancel()
        await canceled.value
        #expect(loader.fileURL == second)
        try Data("still watching".utf8).write(to: second, options: .atomic)
        try await eventually { loader.source == "still watching" }
    }

    private func temporaryDirectory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    private func eventually(_ predicate: () -> Bool) async throws {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: .seconds(5))
        while !predicate(), clock.now < deadline {
            try await Task.sleep(for: .milliseconds(25))
        }
        #expect(predicate())
    }
}
