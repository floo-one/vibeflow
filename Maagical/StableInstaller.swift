import AppKit
import OSLog
import Security
import MaagicalCore

/// Leaves a broken nightly for the newest release in one click (Settings > General and the menu).
/// Sparkle cannot do this: its installer refuses any build number below the installed one, and
/// every nightly (<release build>.<commits on main>) is above the release it came after. So this
/// downloads the release DMG, checks that the app inside is Maagical, signed with our Developer
/// ID and notarized, puts it in place of the running copy and opens it; the new copy quits this
/// one (AppDelegate.quitOlderCopies). The channel goes to Stable first, so Sparkle does not
/// update straight back to a nightly. Nightly again later is a normal Sparkle update.
@MainActor @Observable
final class StableInstaller {
    static let shared = StableInstaller()

    /// The step in progress, for the button and the menu item; nil when idle.
    private(set) var step: String?

    /// The release's identity: our bundle id, a Developer ID certificate from team X7UXDLS9F7,
    /// and a notarization ticket (release.sh staples it to the app).
    private static let requirement = """
        identifier "one.floo.vibeflow" and anchor apple generic \
        and certificate 1[field.1.2.840.113635.100.6.2.6] \
        and certificate leaf[field.1.2.840.113635.100.6.1.13] \
        and certificate leaf[subject.OU] = "X7UXDLS9F7" and notarized
        """

    private let log = Logger(subsystem: "one.floo.vibeflow", category: "update")

    func install(preferences: Preferences) {
        guard step == nil else { return }
        Task {
            do {
                try await run(preferences: preferences)
            } catch {
                log.error("back to stable: \(error.localizedDescription, privacy: .public)")
                step = nil
                NSApp.activate()
                let alert = NSAlert()
                alert.messageText = "Could not go back to the release"
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }

    private func run(preferences: Preferences) async throws {
        let target = Bundle.main.bundleURL
        let files = FileManager.default
        // Next to the installed app, so the final swap is a rename on the same volume.
        let work = try files.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: target, create: true)
        defer { try? files.removeItem(at: work) }

        step = "Downloading the release…"
        log.notice("back to stable: downloading \(Updater.releaseDMG.absoluteString, privacy: .public)")
        let (download, response) = try await URLSession.shared.download(from: Updater.releaseDMG)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard status == 200 else { throw Failure("GitHub answered \(status) for the release download.") }
        let dmg = work.appending(path: "Maagical.dmg")
        try files.moveItem(at: download, to: dmg)

        step = "Checking the release…"
        let mount = work.appending(path: "mount")
        try await Self.exec("/usr/bin/hdiutil", "attach", dmg.path, "-nobrowse", "-readonly", "-noautoopen", "-mountpoint", mount.path)
        let staged = work.appending(path: "Maagical.app")
        let copied = Result { try files.copyItem(at: mount.appending(path: "Maagical.app"), to: staged) }
        _ = try? await Self.exec("/usr/bin/hdiutil", "detach", mount.path, "-force")
        try copied.get()
        try Self.verify(staged)

        step = "Installing…"
        preferences.updateToNewestMain = false
        _ = try files.replaceItemAt(target, withItemAt: staged)
        log.notice("back to stable: installed at \(target.path, privacy: .public), reopening")

        let configuration = NSWorkspace.OpenConfiguration()
        configuration.createsNewApplicationInstance = true
        do {
            try await NSWorkspace.shared.openApplication(at: target, configuration: configuration)
        } catch {
            throw Failure("The release is installed, but did not open: \(error.localizedDescription) Quit Maagical and open it again.")
        }
    }

    private static func verify(_ app: URL) throws {
        var code: SecStaticCode?
        var requirement: SecRequirement?
        guard SecStaticCodeCreateWithPath(app as CFURL, [], &code) == errSecSuccess, let code,
              SecRequirementCreateWithString(Self.requirement as CFString, [], &requirement) == errSecSuccess, let requirement
        else { throw Failure("Could not read the signature of the downloaded app.") }
        let flags = SecCSFlags(rawValue: kSecCSCheckAllArchitectures | kSecCSStrictValidate | kSecCSCheckNestedCode)
        let status = SecStaticCodeCheckValidity(code, flags, requirement)
        guard status == errSecSuccess else {
            throw Failure("The download is not a signed and notarized Maagical release (\(status)). Nothing was changed.")
        }
    }

    /// Runs a command line tool off the main thread; throws with its error output when it fails.
    private static func exec(_ tool: String, _ arguments: String...) async throws {
        let process = Process()
        process.executableURL = URL(filePath: tool)
        process.arguments = arguments
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        try await withCheckedThrowingContinuation { (done: CheckedContinuation<Void, Error>) in
            process.terminationHandler = { finished in
                let output = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
                if finished.terminationStatus == 0 {
                    done.resume()
                } else {
                    done.resume(throwing: Failure("\((tool as NSString).lastPathComponent) failed: \(output.trimmingCharacters(in: .whitespacesAndNewlines))"))
                }
            }
            do { try process.run() } catch { done.resume(throwing: error) }
        }
    }

    private struct Failure: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
}
