// ConfigureSheet.swift
//
// The configure sheet shown when the user clicks "Screen Saver
// Options…" in System Settings. We avoid XIBs and SwiftUI here so the
// sheet works regardless of how the legacyScreenSaver host loads us
// (XIB owners and SwiftUI hosting controllers can be fragile inside
// .saver bundles).
//
// First pass: resource folder picker only. The other plan controls
// (sound, animation speed, story day, force holiday, fidelity mode,
// debug overlay) are stubbed for follow-up work — the structure here
// is wired so they can be dropped in without re-architecting.

import AppKit
import ScreenSaver

@MainActor
final class ConfigureSheetController: NSObject {

    static let shared = ConfigureSheetController()

    private(set) lazy var window: NSWindow = makeWindow()

    private var statusLabel: NSTextField!
    private var pathLabel:   NSTextField!

    // ---------------------------------------------------------------
    // MARK: Window construction
    // ---------------------------------------------------------------

    private func makeWindow() -> NSWindow {
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 220),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        win.title = "Johnny Castaway"
        win.isReleasedWhenClosed = false

        let content = NSView(frame: win.contentLayoutRect)
        win.contentView = content

        // Title
        let title = NSTextField(labelWithString: "Sierra Resource Files")
        title.font = NSFont.boldSystemFont(ofSize: 14)
        title.frame = NSRect(x: 20, y: 178, width: 440, height: 20)
        content.addSubview(title)

        // Description
        let desc = NSTextField(wrappingLabelWithString:
            "Johnny Castaway requires the original Sierra resource files. "
          + "Choose the folder that contains RESOURCE.MAP and RESOURCE.001."
        )
        desc.frame = NSRect(x: 20, y: 130, width: 440, height: 40)
        content.addSubview(desc)

        // Currently configured path
        pathLabel = NSTextField(labelWithString: "")
        pathLabel.font = NSFont.systemFont(ofSize: 11)
        pathLabel.textColor = .secondaryLabelColor
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.frame = NSRect(x: 20, y: 100, width: 440, height: 16)
        content.addSubview(pathLabel)

        // Status (errors)
        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = .systemRed
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.frame = NSRect(x: 20, y: 76, width: 440, height: 16)
        content.addSubview(statusLabel)

        // Choose button
        let choose = NSButton(
            title: "Choose Folder…",
            target: self,
            action: #selector(chooseClicked)
        )
        choose.bezelStyle = .rounded
        choose.frame = NSRect(x: 20, y: 16, width: 140, height: 32)
        content.addSubview(choose)

        // Done button
        let done = NSButton(
            title: "Done",
            target: self,
            action: #selector(doneClicked)
        )
        done.bezelStyle = .rounded
        done.keyEquivalent = "\r"
        done.frame = NSRect(x: 360, y: 16, width: 100, height: 32)
        content.addSubview(done)

        refreshLabels()
        return win
    }

    private func refreshLabels() {
        if let path = ResourceFolder.displayPath {
            pathLabel.stringValue = "Configured: \(path)"
            pathLabel.textColor   = .secondaryLabelColor
        } else {
            pathLabel.stringValue = "Not configured."
            pathLabel.textColor   = .systemOrange
        }
        statusLabel.stringValue = ""
    }

    // ---------------------------------------------------------------
    // MARK: Actions
    // ---------------------------------------------------------------

    @objc private func chooseClicked() {
        let panel = NSOpenPanel()
        panel.message                = "Select the folder containing RESOURCE.MAP and RESOURCE.001"
        panel.prompt                 = "Choose"
        panel.canChooseFiles         = false
        panel.canChooseDirectories   = true
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try ResourceFolder.save(folder: url)
            refreshLabels()
        } catch {
            statusLabel.stringValue = error.localizedDescription
        }
    }

    @objc private func doneClicked() {
        NSApp.endSheet(window)
        window.orderOut(nil)
    }
}
