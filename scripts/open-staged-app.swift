import AppKit

private func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(1)
}

guard CommandLine.arguments.count == 2 else {
    fail("usage: swift scripts/open-staged-app.swift /path/to/Fritz.app")
}

let appURL = URL(fileURLWithPath: CommandLine.arguments[1]).resolvingSymlinksInPath()
guard let bundleID = Bundle(url: appURL)?.bundleIdentifier else {
    fail("Could not read the staged app’s bundle identifier at \(appURL.path).")
}

let stagingDirectory = appURL.deletingLastPathComponent().path
let previousInstances = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).filter { app in
    guard let runningBundle = app.bundleURL?.resolvingSymlinksInPath() else { return false }
    return runningBundle.pathExtension == "app"
        && runningBundle.deletingLastPathComponent().path == stagingDirectory
}

for app in previousInstances where !app.isTerminated {
    app.terminate()
}

let timeout = ProcessInfo.processInfo.systemUptime + 10
while previousInstances.contains(where: { !$0.isTerminated }),
      ProcessInfo.processInfo.systemUptime < timeout {
    RunLoop.current.run(until: Date(timeIntervalSinceNow: 0.1))
}
let stillRunning = previousInstances.filter { !$0.isTerminated }
if !stillRunning.isEmpty {
    let pids = stillRunning.map { String($0.processIdentifier) }.joined(separator: ", ")
    fail("Fritz did not quit (PID \(pids)). Close the remaining instance and retry.")
}

let launcher = Process()
launcher.executableURL = URL(fileURLWithPath: "/usr/bin/open")
var arguments = ["-n"]
for name in ["FRITZ_DATA_DIR", "FRITZ_MODELS_DIR"] {
    if let value = ProcessInfo.processInfo.environment[name], !value.isEmpty {
        arguments += ["--env", "\(name)=\(value)"]
    }
}
launcher.arguments = arguments + [appURL.path]
do {
    try launcher.run()
    launcher.waitUntilExit()
    exit(launcher.terminationStatus)
} catch {
    fail("Could not open the staged app: \(error.localizedDescription)")
}
