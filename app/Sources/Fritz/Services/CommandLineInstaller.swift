import Foundation

struct CommandLineInstaller {
    static let installedCLIURL = URL(
        fileURLWithPath: "/Applications/Fritz.app/Contents/Resources/fritz"
    )

    enum InstallResult: Equatable {
        case installed(URL)
        case alreadyInstalled(URL)
        case appNotInstalled
        case noAvailableDirectory
        case failed(String)
    }

    private let fileManager: FileManager
    private let environment: [String: String]
    private let cliURL: URL
    private let homeDirectory: URL

    init(
        fileManager: FileManager = .default,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        cliURL: URL = installedCLIURL,
        homeDirectory: URL? = nil
    ) {
        self.fileManager = fileManager
        self.environment = environment
        self.cliURL = cliURL.standardizedFileURL
        self.homeDirectory = homeDirectory ?? fileManager.homeDirectoryForCurrentUser
    }

    func install() -> InstallResult {
        guard fileManager.isExecutableFile(atPath: cliURL.path) else {
            return .appNotInstalled
        }

        var lastError: Error?
        for directory in pathDirectories() {
            let linkURL = directory.appendingPathComponent("fritz", isDirectory: false)

            if let currentDestination = symlinkDestination(at: linkURL) {
                if currentDestination.standardizedFileURL == cliURL {
                    return .alreadyInstalled(linkURL)
                }
                if currentDestination.resolvingSymlinksInPath()
                    == cliURL.resolvingSymlinksInPath()
                {
                    do {
                        try fileManager.removeItem(at: linkURL)
                        try fileManager.createSymbolicLink(
                            at: linkURL,
                            withDestinationURL: cliURL
                        )
                        return .installed(linkURL)
                    } catch {
                        lastError = error
                        continue
                    }
                }
            }
            guard !itemExists(at: linkURL),
                  fileManager.isWritableFile(atPath: directory.path) else {
                continue
            }

            do {
                try fileManager.createSymbolicLink(
                    at: linkURL,
                    withDestinationURL: cliURL
                )
                return .installed(linkURL)
            } catch {
                lastError = error
            }
        }

        if let lastError {
            return .failed(lastError.localizedDescription)
        }
        return .noAvailableDirectory
    }

    private func pathDirectories() -> [URL] {
        var seen = Set<String>()
        let pathDirectories = (environment["PATH"] ?? "")
            .split(separator: ":", omittingEmptySubsequences: false)
            .compactMap { entry -> URL? in
                guard entry.hasPrefix("/") else {
                    return nil
                }

                return URL(fileURLWithPath: String(entry), isDirectory: true)
                    .standardizedFileURL
            }
        let pathDirectorySet = Set(pathDirectories.map(\.path))
        let preferredDirectories = [
            URL(fileURLWithPath: "/usr/local/bin", isDirectory: true),
            homeDirectory.appendingPathComponent(".local/bin", isDirectory: true),
            homeDirectory.appendingPathComponent("bin", isDirectory: true),
            URL(fileURLWithPath: "/opt/homebrew/bin", isDirectory: true),
        ]
        return (preferredDirectories + pathDirectories)
            .compactMap { directory -> URL? in
                let directory = directory.standardizedFileURL
                guard pathDirectorySet.contains(directory.path),
                      seen.insert(directory.path).inserted else {
                    return nil
                }

                var isDirectory: ObjCBool = false
                guard fileManager.fileExists(
                    atPath: directory.path,
                    isDirectory: &isDirectory
                ), isDirectory.boolValue else {
                    return nil
                }
                return directory
            }
    }

    private func itemExists(at url: URL) -> Bool {
        (try? fileManager.attributesOfItem(atPath: url.path)) != nil
    }

    private func symlinkDestination(at linkURL: URL) -> URL? {
        guard let destination = try? fileManager.destinationOfSymbolicLink(
            atPath: linkURL.path
        ) else {
            return nil
        }

        if destination.hasPrefix("/") {
            return URL(fileURLWithPath: destination).standardizedFileURL
        }
        return URL(
            fileURLWithPath: destination,
            relativeTo: linkURL.deletingLastPathComponent()
        ).standardizedFileURL
    }
}
