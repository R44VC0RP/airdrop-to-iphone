import AppKit
import ApplicationServices
import FinderSync
import OSLog

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSSharingServiceDelegate {
    private let recipient = "Ryan iPhone"
    private let logger = Logger(subsystem: "net.ryanvogel.airdrop-to-iphone", category: "transfer")
    private var launched = false
    private var pendingFiles: [URL] = []
    private var service: NSSharingService?
    private var timer: Timer?
    private var discoveryDeadline = Date.distantPast
    private var pressedRecipient = false
    private var observedPicker = false

    func applicationDidFinishLaunching(_ notification: Notification) {
        launched = true
        if pendingFiles.isEmpty {
            showSetup()
        } else {
            beginTransfer()
        }
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        guard service == nil, pendingFiles.isEmpty else {
            logger.notice("Ignored an additional request while a transfer is active.")
            NSSound.beep()
            return
        }
        do {
            pendingFiles = try filesFromRequest(urls)
        } catch {
            fail("Could not read the Finder selection. Please select the files again and retry.")
            return
        }
        if launched { beginTransfer() }
    }

    private func filesFromRequest(_ urls: [URL]) throws -> [URL] {
        guard urls.count == 1, let request = urls.first,
              request.pathExtension == "iphone-airdrop" else { return urls }
        let directory = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Containers/net.ryanvogel.airdrop-to-iphone.finder/Data/Library/Application Support/AirdropToIPhoneRequests", isDirectory: true)
        guard request.isFileURL,
              UUID(uuidString: request.deletingPathExtension().lastPathComponent) != nil,
              request.deletingLastPathComponent().resolvingSymlinksInPath() == directory.resolvingSymlinksInPath(),
              try request.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey]).isRegularFile == true,
              try request.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
            throw CocoaError(.fileReadNoPermission)
        }
        // Consume once. A replay cannot send the same request a second time.
        let data = try Data(contentsOf: request)
        try FileManager.default.removeItem(at: request)
        let files = try JSONDecoder().decode([URL].self, from: data)
        guard !files.isEmpty, files.allSatisfy(\.isFileURL) else { throw CocoaError(.fileReadCorruptFile) }
        logger.notice("Consumed Finder request for \(files.count) items.")
        return files
    }

    private func showSetup() {
        let alert = NSAlert()
        alert.messageText = "Airdrop to iPhone"
        alert.informativeText = "Enable the Finder extension and Accessibility access for this app. Then right-click files in Finder and choose “Airdrop to iPhone”."
        alert.addButton(withTitle: "Finder Extensions")
        alert.addButton(withTitle: "Accessibility Settings")
        alert.addButton(withTitle: "Done")
        NSApp.activate(ignoringOtherApps: true)
        switch alert.runModal() {
        case .alertFirstButtonReturn:
            FIFinderSyncController.showExtensionManagementInterface()
        case .alertSecondButtonReturn:
            openAccessibilitySettings()
        default: break
        }
        NSApp.terminate(nil)
    }

    private func beginTransfer() {
        guard !pendingFiles.isEmpty, pendingFiles.allSatisfy({ $0.isFileURL && FileManager.default.fileExists(atPath: $0.path) }) else {
            fail("The selected files are no longer available.")
            return
        }
        guard AXIsProcessTrusted() else {
            let alert = NSAlert()
            alert.messageText = "Allow Accessibility access"
            alert.informativeText = "Enable “Airdrop to iPhone” in Accessibility settings so it can select Ryan iPhone in the AirDrop picker. Then choose the Finder action again. Nothing has been sent."
            alert.addButton(withTitle: "Open Settings")
            alert.addButton(withTitle: "Cancel")
            NSApp.activate(ignoringOtherApps: true)
            if alert.runModal() == .alertFirstButtonReturn { openAccessibilitySettings() }
            NSApp.terminate(nil)
            return
        }
        // ShareKit checks access without prompting for protected folders. An actual
        // read-open lets macOS request consent first; it does not load file contents.
        do {
            for url in pendingFiles {
                if try url.resourceValues(forKeys: [.isDirectoryKey]).isDirectory == true {
                    _ = try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
                } else {
                    let handle = try FileHandle(forReadingFrom: url)
                    try handle.close()
                }
            }
            logger.notice("Read access confirmed for \(self.pendingFiles.count) selected items.")
        } catch {
            fail("Could not read the selected files. If you denied folder access, allow Airdrop to iPhone in System Settings → Privacy & Security → Files & Folders, then try again. Nothing was sent.\n\n\(error.localizedDescription)")
            return
        }
        guard let sharingService = NSSharingService(named: .sendViaAirDrop),
              sharingService.canPerform(withItems: pendingFiles) else {
            fail("AirDrop cannot share this selection.")
            return
        }
        service = sharingService
        sharingService.delegate = self
        discoveryDeadline = Date().addingTimeInterval(20)
        logger.notice("Opening AirDrop for \(self.pendingFiles.count) selected items.")
        sharingService.perform(withItems: pendingFiles)
        timer = Timer.scheduledTimer(withTimeInterval: 0.3, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.checkPicker() }
        }
    }

    private func openAccessibilitySettings() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(options)
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
    }

    private func attribute(_ element: AXUIElement, _ name: String) -> CFTypeRef? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, name as CFString, &value) == .success else { return nil }
        return value
    }

    private func descendants(of element: AXUIElement, depth: Int = 0) -> [AXUIElement] {
        guard depth < 16 else { return [] }
        let children = attribute(element, kAXChildrenAttribute) as? [AXUIElement] ?? []
        return [element] + children.flatMap { descendants(of: $0, depth: depth + 1) }
    }

    private func checkPicker() {
        // Never inspect or click another app's AirDrop dialog, including Finder's.
        let application = AXUIElementCreateApplication(ProcessInfo.processInfo.processIdentifier)
        let windows = attribute(application, kAXWindowsAttribute) as? [AXUIElement] ?? []
        let pickers = windows.filter { attribute($0, kAXTitleAttribute) as? String == "AirDrop" }
        if !pickers.isEmpty { observedPicker = true }
        if observedPicker && pickers.isEmpty {
            logger.notice("AirDrop picker closed; no retry.")
            finish()
            return
        }
        let buttons = pickers.flatMap { descendants(of: $0) }.filter {
            attribute($0, kAXRoleAttribute) as? String == kAXButtonRole &&
            attribute($0, kAXIdentifierAttribute) as? String == "dd.nodeBody"
        }
        if pressedRecipient {
            if buttons.contains(where: { attribute($0, kAXDescriptionAttribute) as? String == "\(recipient), Sent" }) {
                logger.notice("AirDrop reports Sent for the configured iPhone.")
                finish()
            }
            return
        }
        // Exact name only: no substring, first-device, or device-type fallback.
        let matches = buttons.filter { attribute($0, kAXDescriptionAttribute) as? String == recipient }
        if matches.count > 1 {
            fail("More than one device is named Ryan iPhone. Nothing was sent.")
            return
        }
        if let button = matches.first {
            // Mark before dispatch: an uncertain AX result must never trigger a duplicate send.
            pressedRecipient = true
            let result = AXUIElementPerformAction(button, kAXPressAction as CFString)
            logger.notice("Recipient press returned AX status \(result.rawValue).")
            if result != .success {
                fail("Could not confirm selection of Ryan iPhone. Check your phone before trying again.")
            }
        } else if Date() >= discoveryDeadline {
            fail("Ryan iPhone did not appear in AirDrop. Unlock your iPhone and check that Wi-Fi, Bluetooth, and AirDrop receiving are enabled, then try again. Nothing was sent.")
        }
    }

    func sharingService(_ sharingService: NSSharingService, didShareItems items: [Any]) {
        logger.notice("AirDrop reported success for \(items.count) items.")
        finish()
    }

    func sharingService(_ sharingService: NSSharingService, didFailToShareItems items: [Any], error: Error) {
        let error = error as NSError
        if error.domain == NSCocoaErrorDomain && error.code == NSUserCancelledError {
            finish()
        } else {
            fail("AirDrop could not complete the transfer: \(error.localizedDescription)")
        }
    }

    private func fail(_ message: String) {
        timer?.invalidate()
        timer = nil
        service?.delegate = nil
        logger.error("Transfer stopped; no automatic retry.")
        let alert = NSAlert()
        alert.messageText = "Airdrop to iPhone"
        alert.informativeText = message
        alert.addButton(withTitle: "OK")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
        NSApp.terminate(nil)
    }

    private func finish() {
        timer?.invalidate()
        timer = nil
        service?.delegate = nil
        NSApp.terminate(nil)
    }
}

@main
struct AirdropToIPhone {
    @MainActor
    static func main() {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.accessory)
        withExtendedLifetime(delegate) { app.run() }
    }
}
