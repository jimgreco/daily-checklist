import Foundation
import UIKit
import XCTest

@MainActor
func setupSnapshot(_ app: XCUIApplication) {
    Snapshot.setup(app)
}

@MainActor
func snapshot(_ name: String, timeWaitingForIdle timeout: TimeInterval = 1) {
    Snapshot.capture(name, timeWaitingForIdle: timeout)
}

@MainActor
private enum Snapshot {
    private static var app: XCUIApplication?

    static func setup(_ app: XCUIApplication) {
        self.app = app
        app.launchArguments += ["-FASTLANE_SNAPSHOT", "YES", "-ui_testing"]
    }

    static func capture(_ name: String, timeWaitingForIdle timeout: TimeInterval) {
        NSLog("snapshot: \(name)")
        if timeout > 0 {
            RunLoop.current.run(until: Date().addingTimeInterval(timeout))
        }

        guard let screenshotsDirectory else { return }
        try? FileManager.default.createDirectory(at: screenshotsDirectory, withIntermediateDirectories: true)

        var simulator = ProcessInfo.processInfo.environment["SIMULATOR_DEVICE_NAME"] ?? "Simulator"
        simulator = simulator.replacingOccurrences(
            of: #"Clone [0-9]+ of "#,
            with: "",
            options: .regularExpression
        )

        let image = XCUIScreen.main.screenshot().image
        let url = screenshotsDirectory.appendingPathComponent("\(simulator)-\(name).png")
        try? image.pngData()?.write(to: url, options: .atomic)
    }

    private static var screenshotsDirectory: URL? {
        let cachePath = "Library/Caches/tools.fastlane/screenshots"
        #if targetEnvironment(simulator)
        guard let simulatorHostHome = ProcessInfo.processInfo.environment["SIMULATOR_HOST_HOME"] else {
            return nil
        }
        return URL(fileURLWithPath: simulatorHostHome).appendingPathComponent(cachePath)
        #else
        return nil
        #endif
    }
}

// Please don't remove the line below.
// It is used by Fastlane to detect outdated configuration files.
// SnapshotHelperVersion [1.30]
