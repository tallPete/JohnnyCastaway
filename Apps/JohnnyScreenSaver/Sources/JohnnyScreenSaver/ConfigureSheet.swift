// ConfigureSheet.swift
//
// The configure sheet shown when the user clicks "Screen Saver
// Options…" in System Settings. Programmatic AppKit — no XIBs, no
// SwiftUI — so it works reliably inside .saver bundles.
//
// Controls implemented so far:
//   • Resource folder picker (required to run)
//   • Sound on/off checkbox
//
// Remaining plan controls (animation speed, story day, force holiday,
// fidelity mode, debug overlay) are wired for drop-in addition.

import AppKit
import ScreenSaver

@MainActor
final class ConfigureSheetController: NSObject {

    static let shared = ConfigureSheetController()

    private(set) lazy var window: NSWindow = makeWindow()

    private var statusLabel:   NSTextField!
    private var pathLabel:     NSTextField!
    private var soundCheckbox: NSButton!

    // ---------------------------------------------------------------
    // MARK: Window construction
    // ---------------------------------------------------------------

    private func makeWindow() -> NSWindow {
        // Height: 278 = original 220 + 58 for the Sound section.
        let win = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 278),
            styleMask: [.titled],
            backing: .buffered,
            defer: false
        )
        win.title = "Johnny Castaway"
        win.isReleasedWhenClosed = false

        let content = NSView(frame: win.contentLayoutRect)
        win.contentView = content

        // ---- Resources section ----------------------------------------

        let resourcesTitle = NSTextField(labelWithString: "Sierra Resource Files")
        resourcesTitle.font = NSFont.boldSystemFont(ofSize: 14)
        resourcesTitle.frame = NSRect(x: 20, y: 236, width: 440, height: 20)
        content.addSubview(resourcesTitle)

        let desc = NSTextField(wrappingLabelWithString:
            "Johnny Castaway requires the original Sierra resource files. "
          + "Choose the folder that contains RESOURCE.MAP and RESOURCE.001."
        )
        desc.frame = NSRect(x: 20, y: 188, width: 440, height: 40)
        content.addSubview(desc)

        pathLabel = NSTextField(labelWithString: "")
        pathLabel.font = NSFont.systemFont(ofSize: 11)
        pathLabel.textColor = .secondaryLabelColor
        pathLabel.lineBreakMode = .byTruncatingMiddle
        pathLabel.frame = NSRect(x: 20, y: 158, width: 440, height: 16)
        content.addSubview(pathLabel)

        statusLabel = NSTextField(labelWithString: "")
        statusLabel.font = NSFont.systemFont(ofSize: 11)
        statusLabel.textColor = .systemRed
        statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.frame = NSRect(x: 20, y: 134, width: 440, height: 16)
        content.addSubview(statusLabel)

        // ---- Separator ------------------------------------------------

        let sep = NSBox()
        sep.boxType = .separator
        sep.frame = NSRect(x: 20, y: 118, width: 440, height: 1)
        content.addSubview(sep)

        // ---- Audio section --------------------------------------------

        let audioTitle = NSTextField(labelWithString: "Audio")
        audioTitle.font = NSFont.boldSystemFont(ofSize: 14)
        audioTitle.frame = NSRect(x: 20, y: 90, width: 440, height: 20)
        content.addSubview(audioTitle)

        soundCheckbox = NSButton(
            checkboxWithTitle: "Enable sounds",
            target: self,
            action: #selector(soundToggled)
        )
        soundCheckbox.frame = NSRect(x: 20, y: 64, width: 440, height: 22)
        soundCheckbox.state = ResourceFolder.soundEnabled ? .on : .off
        content.addSubview(soundCheckbox)

        let soundNote = NSTextField(labelWithString:
            "Sound changes take effect when the screensaver next starts."
        )
        soundNote.font = NSFont.systemFont(ofSize: 11)
        soundNote.textColor = .secondaryLabelColor
        soundNote.frame = NSRect(x: 20, y: 44, width: 440, height: 16)
        content.addSubview(soundNote)

        // ---- Action buttons ------------------------------------------

        let choose = NSButton(
            title: "Choose Folder…",
            target: self,
            action: #selector(chooseClicked)
        )
        choose.bezelStyle = .rounded
        choose.frame = NSRect(x: 20, y: 10, width: 140, height: 32)
        content.addSubview(choose)

        let done = NSButton(
            title: "Done",
            target: self,
            action: #selector(doneClicked)
        )
        done.bezelStyle = .rounded
        done.keyEquivalent = "\r"
        done.frame = NSRect(x: 360, y: 10, width: 100, height: 32)
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
        soundCheckbox.state = ResourceFolder.soundEnabled ? .on : .off
    }

    // ---------------------------------------------------------------
    // MARK: Actions
    // ---------------------------------------------------------------

    @objc private func chooseClicked() {
        let panel = NSOpenPanel()
        panel.message                 = "Select the folder containing RESOURCE.MAP and RESOURCE.001"
        panel.prompt                  = "Choose"
        panel.canChooseFiles          = false
        panel.canChooseDirectories    = true
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try ResourceFolder.save(folder: url)
            refreshLabels()
        } catch {
            statusLabel.stringValue = error.localizedDescription
        }
    }

    @objc private func soundToggled() {
        ResourceFolder.soundEnabled = (soundCheckbox.state == .on)
    }

    @objc private func doneClicked() {
        window.sheetParent?.endSheet(window)
        window.orderOut(nil)
    }
}
