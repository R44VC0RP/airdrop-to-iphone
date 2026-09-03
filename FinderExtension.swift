import AppKit
import FinderSync
import OSLog

@objc(IPhoneFinderExtension)
final class IPhoneFinderExtension: FIFinderSync {
    private let logger = Logger(subsystem: "net.ryanvogel.airdrop-to-iphone", category: "finder")
    override init() {
        super.init()
        // Includes local files and mounted volumes without changing their badges.
        FIFinderSyncController.default().directoryURLs = [URL(fileURLWithPath: "/")]
    }

    override func menu(for menuKind: FIMenuKind) -> NSMenu? {
        guard menuKind == .contextualMenuForItems,
              let urls = FIFinderSyncController.default().selectedItemURLs(),
              !urls.isEmpty, urls.allSatisfy(\.isFileURL) else { return nil }

        let menu = NSMenu()
        let item = NSMenuItem(title: "Airdrop to iPhone", action: #selector(sendToIPhone(_:)), keyEquivalent: "")
        item.target = self
        menu.addItem(item)
        return menu
    }

    @objc private func sendToIPhone(_ item: NSMenuItem) {
        // Finder reconstructs menu items across processes; representedObject is not preserved.
        // Its controller provides the selected URLs during the action callback.
        guard let urls = FIFinderSyncController.default().selectedItemURLs(),
              !urls.isEmpty, urls.allSatisfy(\.isFileURL) else {
            logger.error("Finder action received no selected file URLs.")
            return
        }
        logger.notice("Opening helper for \(urls.count) selected items.")
        let appURL = Bundle.main.bundleURL
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        // Finder gives this extension the paths, not sandbox access to their contents.
        // Hand off an owned request file; only the containing app opens the selection.
        let requestURL: URL
        do {
            let directory = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
                .appendingPathComponent("AirdropToIPhoneRequests", isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            requestURL = directory.appendingPathComponent(UUID().uuidString).appendingPathExtension("iphone-airdrop")
            try JSONEncoder().encode(urls).write(to: requestURL, options: .atomic)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: requestURL.path)
        } catch {
            logger.error("Could not prepare the transfer request: \(error.localizedDescription, privacy: .public)")
            return
        }
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = true
        configuration.addsToRecentItems = false
        NSWorkspace.shared.open([requestURL], withApplicationAt: appURL, configuration: configuration) { _, error in
            if let error {
                try? FileManager.default.removeItem(at: requestURL)
                self.logger.error("Helper launch failed: \(error.localizedDescription, privacy: .public)")
            } else {
                self.logger.notice("Helper launched.")
            }
        }
    }
}
