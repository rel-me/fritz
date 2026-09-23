import Foundation
import XCTest
@testable import Fritz

final class CommandLineInstallerTests: XCTestCase {
    func testInstallsInFirstWritableDirectoryInPath() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let firstDirectory = try fixture.createDirectory(named: "usr-local-bin")
        let secondDirectory = try fixture.createDirectory(named: "local-bin")

        let result = CommandLineInstaller(
            environment: ["PATH": "\(firstDirectory.path):\(secondDirectory.path)"],
            cliURL: fixture.cliURL
        ).install()

        let linkURL = firstDirectory.appendingPathComponent("fritz")
        XCTAssertEqual(result, .installed(linkURL))
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: linkURL.path),
            fixture.cliURL.path
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: secondDirectory.appendingPathComponent("fritz").path
            )
        )
    }

    func testReturnsExistingMatchingSymlink() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let directory = try fixture.createDirectory(named: "bin")
        let linkURL = directory.appendingPathComponent("fritz")
        try FileManager.default.createSymbolicLink(
            at: linkURL,
            withDestinationURL: fixture.cliURL
        )

        let result = CommandLineInstaller(
            environment: ["PATH": directory.path],
            cliURL: fixture.cliURL
        ).install()

        XCTAssertEqual(result, .alreadyInstalled(linkURL))
    }

    func testRewritesMatchingSymlinkWithCanonicalBundleCasing() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let directory = try fixture.createDirectory(named: "bin")
        let linkURL = directory.appendingPathComponent("fritz")
        let differentlyCasedCLIURL = fixture.rootURL
            .appendingPathComponent("fritz.app/Contents/Resources/fritz")
        try FileManager.default.createSymbolicLink(
            atPath: linkURL.path,
            withDestinationPath: differentlyCasedCLIURL.path
        )

        let result = CommandLineInstaller(
            environment: ["PATH": directory.path],
            cliURL: fixture.cliURL
        ).install()

        XCTAssertEqual(result, .installed(linkURL))
        XCTAssertEqual(
            try FileManager.default.destinationOfSymbolicLink(atPath: linkURL.path),
            fixture.cliURL.path
        )
    }

    func testPrefersConventionalUserBinDirectoryInPath() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let firstDirectory = try fixture.createDirectory(named: "tool-specific-bin")
        let homeDirectory = try fixture.createDirectory(named: "home")
        let preferredDirectory = try fixture.createDirectory(named: "home/bin")

        let result = CommandLineInstaller(
            environment: [
                "PATH": "\(firstDirectory.path):\(preferredDirectory.path)"
            ],
            cliURL: fixture.cliURL,
            homeDirectory: homeDirectory
        ).install()

        XCTAssertEqual(
            result,
            .installed(preferredDirectory.appendingPathComponent("fritz"))
        )
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: firstDirectory.appendingPathComponent("fritz").path
            )
        )
    }

    func testSkipsOccupiedNameAndUsesNextPathDirectory() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let occupiedDirectory = try fixture.createDirectory(named: "occupied-bin")
        let availableDirectory = try fixture.createDirectory(named: "available-bin")
        let occupiedURL = occupiedDirectory.appendingPathComponent("fritz")
        try Data("different executable".utf8).write(to: occupiedURL)

        let result = CommandLineInstaller(
            environment: [
                "PATH": "\(occupiedDirectory.path):\(availableDirectory.path)"
            ],
            cliURL: fixture.cliURL
        ).install()

        XCTAssertEqual(
            result,
            .installed(availableDirectory.appendingPathComponent("fritz"))
        )
        XCTAssertEqual(try Data(contentsOf: occupiedURL), Data("different executable".utf8))
    }

    func testDoesNotCreateMissingPathDirectory() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let missingDirectory = fixture.rootURL.appendingPathComponent("missing-bin")

        let result = CommandLineInstaller(
            environment: ["PATH": missingDirectory.path],
            cliURL: fixture.cliURL
        ).install()

        XCTAssertEqual(result, .noAvailableDirectory)
        XCTAssertFalse(FileManager.default.fileExists(atPath: missingDirectory.path))
    }

    func testRequiresInstalledApplicationCLI() throws {
        let fixture = try Fixture(createCLI: false)
        defer { fixture.remove() }
        let directory = try fixture.createDirectory(named: "bin")

        let result = CommandLineInstaller(
            environment: ["PATH": directory.path],
            cliURL: fixture.cliURL
        ).install()

        XCTAssertEqual(result, .appNotInstalled)
        XCTAssertFalse(
            FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("fritz").path
            )
        )
    }
}

private struct Fixture {
    let rootURL: URL
    let cliURL: URL

    init(createCLI: Bool = true) throws {
        rootURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("CommandLineInstallerTests-\(UUID().uuidString)")
        cliURL = rootURL.appendingPathComponent("Fritz.app/Contents/Resources/fritz")
        try FileManager.default.createDirectory(
            at: cliURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if createCLI {
            XCTAssertTrue(
                FileManager.default.createFile(atPath: cliURL.path, contents: Data())
            )
            try FileManager.default.setAttributes(
                [.posixPermissions: 0o755],
                ofItemAtPath: cliURL.path
            )
        }
    }

    func createDirectory(named name: String) throws -> URL {
        let url = rootURL.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func remove() {
        try? FileManager.default.removeItem(at: rootURL)
    }
}
