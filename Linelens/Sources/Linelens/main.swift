import AppKit
import Carbon
import Vision
import AVFoundation
import NaturalLanguage
import ServiceManagement


enum LoginItem {
    static var isEnabled: Bool {
        get { SMAppService.mainApp.status == .enabled }
        set {
            do {
                if newValue {
                    if SMAppService.mainApp.status == .enabled { return }
                    try SMAppService.mainApp.register()
                } else {
                    try SMAppService.mainApp.unregister()
                }
            } catch {
                NSLog("Linelens: failed to update login item: \(error)")
            }
        }
    }
}


final class Hotkey {
    private var ref: EventHotKeyRef?
    private let id: UInt32
    private let handler: () -> Void
    private static var instances: [UInt32: Hotkey] = [:]
    private static var nextID: UInt32 = 1
    private static var handlerInstalled = false

    init(handler: @escaping () -> Void) {
        self.handler = handler
        self.id = Hotkey.nextID; Hotkey.nextID += 1
        Hotkey.instances[id] = self
        Hotkey.installHandlerIfNeeded()
    }

    private static func installHandlerIfNeeded() {
        guard !handlerInstalled else { return }
        handlerInstalled = true
        var eventType = EventTypeSpec(eventClass: OSType(kEventClassKeyboard),
                                      eventKind: UInt32(kEventHotKeyPressed))
        InstallEventHandler(GetApplicationEventTarget(), { _, event, _ -> OSStatus in
            var hkID = EventHotKeyID()
            GetEventParameter(event, EventParamName(kEventParamDirectObject),
                              EventParamType(typeEventHotKeyID), nil,
                              MemoryLayout<EventHotKeyID>.size, nil, &hkID)
            Hotkey.instances[hkID.id]?.handler()
            return noErr
        }, 1, &eventType, nil, nil)
    }

    func setShortcut(keyCode: UInt32, modifiers: UInt32) {
        if let existing = ref { UnregisterEventHotKey(existing); ref = nil }
        let hkID = EventHotKeyID(signature: OSType(0x54534E50), id: id)
        RegisterEventHotKey(keyCode, modifiers, hkID,
                            GetApplicationEventTarget(), 0, &ref)
    }
}


struct Shortcut {
    var keyCode: UInt32
    var carbonModifiers: UInt32

    static let `default` = Shortcut(keyCode: UInt32(kVK_ANSI_2),
                                    carbonModifiers: UInt32(cmdKey | shiftKey))

    static func load() -> Shortcut {
        let d = UserDefaults.standard
        guard d.object(forKey: "hotkeyKeyCode") != nil else { return .default }
        return Shortcut(keyCode: UInt32(d.integer(forKey: "hotkeyKeyCode")),
                        carbonModifiers: UInt32(d.integer(forKey: "hotkeyModifiers")))
    }
    func save() {
        let d = UserDefaults.standard
        d.set(Int(keyCode), forKey: "hotkeyKeyCode")
        d.set(Int(carbonModifiers), forKey: "hotkeyModifiers")
    }

    static func carbonModifiers(from flags: NSEvent.ModifierFlags) -> UInt32 {
        var m: UInt32 = 0
        if flags.contains(.control) { m |= UInt32(controlKey) }
        if flags.contains(.option)  { m |= UInt32(optionKey) }
        if flags.contains(.shift)   { m |= UInt32(shiftKey) }
        if flags.contains(.command) { m |= UInt32(cmdKey) }
        return m
    }

    var display: String {
        var s = ""
        if carbonModifiers & UInt32(controlKey) != 0 { s += "⌃" }
        if carbonModifiers & UInt32(optionKey)  != 0 { s += "⌥" }
        if carbonModifiers & UInt32(shiftKey)   != 0 { s += "⇧" }
        if carbonModifiers & UInt32(cmdKey)     != 0 { s += "⌘" }
        return s + Shortcut.keyName(keyCode)
    }

    static func keyName(_ code: UInt32) -> String {
        let special: [UInt32: String] = [
            49: "Space", 36: "↩", 48: "⇥", 51: "⌫", 53: "⎋",
            123: "←", 124: "→", 125: "↓", 126: "↑",
            122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        ]
        if let s = special[code] { return s }
        let src = TISCopyCurrentASCIICapableKeyboardLayoutInputSource().takeRetainedValue()
        if let ptr = TISGetInputSourceProperty(src, kTISPropertyUnicodeKeyLayoutData) {
            let data = Unmanaged<CFData>.fromOpaque(ptr).takeUnretainedValue() as Data
            var dead: UInt32 = 0
            var chars = [UniChar](repeating: 0, count: 4)
            var len = 0
            let ok = data.withUnsafeBytes { raw -> OSStatus in
                let layout = raw.bindMemory(to: UCKeyboardLayout.self).baseAddress!
                return UCKeyTranslate(layout, UInt16(code), UInt16(kUCKeyActionDisplay), 0,
                                      UInt32(LMGetKbdType()), OptionBits(kUCKeyTranslateNoDeadKeysBit),
                                      &dead, chars.count, &len, &chars)
            }
            if ok == noErr, len > 0 {
                return String(utf16CodeUnits: chars, count: len).uppercased()
            }
        }
        return "key\(code)"
    }
}

final class CaptureHUD {
    private var prompt: NSPanel?
    private var toast: NSPanel?

    private var reduceMotion: Bool {
        NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
    }

    func showPrompt(on screen: NSScreen?, hint: String) {
        let win = pill(symbol: "character.cursor.ibeam", text: "Select text to copy",
                       hint: hint)
        place(win, on: screen, fromTop: 64)
        animateIn(win, rise: 10, pop: false)
        prompt = win
    }

    func hidePrompt() {
        guard let win = prompt else { return }
        prompt = nil
        animateOut(win, drop: 6)
    }

    func showToast(symbol: String, text: String, on screen: NSScreen?) {
        toast?.orderOut(nil)
        let win = pill(symbol: symbol, text: text, hint: nil)
        place(win, on: screen, fromTop: 64)
        animateIn(win, rise: 12, pop: true)
        toast = win
        let hold: TimeInterval = 1.15
        DispatchQueue.main.asyncAfter(deadline: .now() + hold) { [weak self] in
            guard self?.toast === win else { return }
            self?.toast = nil
            self?.animateOut(win, drop: 8)
        }
    }

    private func pill(symbol: String, text: String, hint: String?) -> NSPanel {
        let blur = NSVisualEffectView()
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 17
        blur.layer?.borderWidth = 1
        blur.layer?.borderColor = NSColor(white: 1, alpha: 0.10).cgColor
        blur.maskImage = roundedMask(radius: 17)

        let icon = NSImageView(image:
            NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = NSColor(white: 0.94, alpha: 1)
        icon.symbolConfiguration = .init(pointSize: 14, weight: .medium)

        let label = NSTextField(labelWithString: text)
        label.font = .systemFont(ofSize: 13.5, weight: .medium)
        label.textColor = NSColor(white: 0.96, alpha: 1)

        var views = [icon, label]
        if let hint {
            let chip = NSTextField(labelWithString: hint)
            chip.font = .monospacedDigitSystemFont(ofSize: 11.5, weight: .semibold)
            chip.textColor = NSColor(white: 0.62, alpha: 1)
            views.append(chip)
        }

        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.spacing = 8
        if hint != nil { stack.setCustomSpacing(12, after: label) }
        stack.edgeInsets = NSEdgeInsets(top: 9, left: 16, bottom: 9, right: 16)
        stack.translatesAutoresizingMaskIntoConstraints = false
        blur.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: blur.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: blur.trailingAnchor),
            stack.topAnchor.constraint(equalTo: blur.topAnchor),
            stack.bottomAnchor.constraint(equalTo: blur.bottomAnchor),
        ])

        let size = stack.fittingSize
        let win = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                          styleMask: [.borderless, .nonactivatingPanel],
                          backing: .buffered, defer: false)
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = true
        win.ignoresMouseEvents = true
        win.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        win.level = NSWindow.Level(rawValue: Int(CGShieldingWindowLevel()) + 1)
        blur.frame = NSRect(origin: .zero, size: size)
        win.contentView = blur
        return win
    }

    private func place(_ win: NSWindow, on screen: NSScreen?, fromTop: CGFloat) {
        guard let screen = screen ?? NSScreen.main else { return }
        let f = screen.frame, s = win.frame.size
        win.setFrameOrigin(NSPoint(x: f.midX - s.width/2,
                                   y: f.maxY - s.height - fromTop))
    }

    private func animateIn(_ win: NSWindow, rise: CGFloat, pop: Bool) {
        let end = win.frame.origin
        if reduceMotion { win.alphaValue = 1; win.orderFrontRegardless(); return }
        win.alphaValue = 0
        win.setFrameOrigin(NSPoint(x: end.x, y: end.y - rise))
        win.orderFrontRegardless()

        let ease = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
        NSAnimationContext.runAnimationGroup { c in
            c.duration = 0.32
            c.timingFunction = ease
            win.animator().alphaValue = 1
            win.animator().setFrameOrigin(end)
        }
        if pop, let layer = win.contentView?.layer {
            let scale = CABasicAnimation(keyPath: "transform.scale")
            scale.fromValue = 0.92
            scale.toValue = 1.0
            scale.duration = 0.34
            scale.timingFunction = ease
            layer.add(scale, forKey: "pop")
        }
    }

    private func animateOut(_ win: NSWindow, drop: CGFloat) {
        if reduceMotion { win.orderOut(nil); return }
        let start = win.frame.origin
        NSAnimationContext.runAnimationGroup({ c in
            c.duration = 0.26
            c.timingFunction = CAMediaTimingFunction(name: .easeIn)
            win.animator().alphaValue = 0
            win.animator().setFrameOrigin(NSPoint(x: start.x, y: start.y - drop))
        }, completionHandler: { win.orderOut(nil) })
    }

    private func roundedMask(radius: CGFloat) -> NSImage {
        let img = NSImage(size: NSSize(width: radius*2 + 1, height: radius*2 + 1),
                          flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        img.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        img.resizingMode = .stretch
        return img
    }
}


enum CaptureAction: String, CaseIterable {
    case copy, lookUp, search, speak

    var title: String {
        switch self {
        case .copy:   return "Copy"
        case .lookUp: return "Look Up"
        case .search: return "Search"
        case .speak:  return "Speak"
        }
    }
    var symbol: String {
        switch self {
        case .copy:   return "doc.on.doc"
        case .lookUp: return "character.book.closed"
        case .search: return "magnifyingglass"
        case .speak:  return "speaker.wave.2"
        }
    }

    func run(text: String, anchor: NSView?, at point: NSPoint,
             synth: AVSpeechSynthesizer) {
        switch self {
        case .copy:
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(text, forType: .string)
        case .lookUp:
            NSApp.activate(ignoringOtherApps: true)
            anchor?.showDefinition(for: NSAttributedString(string: text), at: point)
        case .search:
            let q = text.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? ""
            if let url = URL(string: "https://www.google.com/search?q=\(q)") {
                NSWorkspace.shared.open(url)
            }
        case .speak:
            if synth.isSpeaking { synth.stopSpeaking(at: .immediate); return }
            let u = AVSpeechUtterance(string: text)
            let rec = NLLanguageRecognizer(); rec.processString(text)
            if let lang = rec.dominantLanguage?.rawValue {
                u.voice = AVSpeechSynthesisVoice(language: lang)
            }
            synth.speak(u)
        }
    }
}


final class ActionButton: NSView {
    private let onClick: () -> Void
    private let bg = CALayer()
    private var hovered = false { didSet { refresh() } }
    let titleField = NSTextField(labelWithString: "")

    init(title: String, symbol: String, onClick: @escaping () -> Void) {
        self.onClick = onClick
        super.init(frame: .zero)
        wantsLayer = true
        layer?.cornerRadius = 9
        layer?.masksToBounds = true

        let icon = NSImageView(image:
            NSImage(systemSymbolName: symbol, accessibilityDescription: nil) ?? NSImage())
        icon.contentTintColor = NSColor(white: 0.95, alpha: 1)
        icon.symbolConfiguration = .init(pointSize: 12, weight: .medium)

        titleField.stringValue = title
        titleField.font = .systemFont(ofSize: 12.5, weight: .medium)
        titleField.textColor = NSColor(white: 0.95, alpha: 1)

        let stack = NSStackView(views: [icon, titleField])
        stack.spacing = 5
        stack.edgeInsets = NSEdgeInsets(top: 6, left: 10, bottom: 6, right: 11)
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor),
            stack.topAnchor.constraint(equalTo: topAnchor),
            stack.bottomAnchor.constraint(equalTo: bottomAnchor),
        ])
        refresh()
    }
    required init?(coder: NSCoder) { fatalError() }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        trackingAreas.forEach(removeTrackingArea)
        addTrackingArea(NSTrackingArea(rect: .zero,
            options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
            owner: self))
    }
    override func mouseEntered(with e: NSEvent) { hovered = true }
    override func mouseExited(with e: NSEvent)  { hovered = false }
    override func mouseUp(with e: NSEvent)      { onClick() }

    private func refresh() {
        layer?.backgroundColor = NSColor(white: 1, alpha: hovered ? 0.16 : 0.07).cgColor
    }
}

final class ActionBar {
    private var panel: NSPanel?
    private var hideItem: DispatchWorkItem?
    private let synth = AVSpeechSynthesizer()
    private var text = ""

    func show(text: String, on screen: NSScreen?, actions: [CaptureAction]) {
        self.text = text
        panel?.orderOut(nil)

        let blur = NSVisualEffectView()
        blur.material = .hudWindow
        blur.blendingMode = .behindWindow
        blur.state = .active
        blur.wantsLayer = true
        blur.layer?.cornerRadius = 18
        blur.layer?.borderWidth = 1
        blur.layer?.borderColor = NSColor(white: 1, alpha: 0.10).cgColor
        blur.maskImage = roundedMask(radius: 18)

        let brand = NSImageView(image: AppDelegate.statusIcon())
        brand.contentTintColor = NSColor(white: 0.55, alpha: 1)

        var views: [NSView] = [brand]
        for action in actions {
            views.append(ActionButton(title: action.title, symbol: action.symbol) {
                [weak self] in self?.perform(action) })
        }

        let stack = NSStackView(views: views)
        stack.orientation = .horizontal
        stack.spacing = 6
        stack.setCustomSpacing(10, after: brand)
        stack.edgeInsets = NSEdgeInsets(top: 7, left: 13, bottom: 7, right: 9)
        stack.translatesAutoresizingMaskIntoConstraints = false
        blur.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: blur.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: blur.trailingAnchor),
            stack.topAnchor.constraint(equalTo: blur.topAnchor),
            stack.bottomAnchor.constraint(equalTo: blur.bottomAnchor),
        ])

        let size = stack.fittingSize
        let win = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                          styleMask: [.borderless, .nonactivatingPanel],
                          backing: .buffered, defer: false)
        win.isOpaque = false
        win.backgroundColor = .clear
        win.hasShadow = true
        win.level = .floating
        win.hidesOnDeactivate = false
        blur.frame = NSRect(origin: .zero, size: size)
        win.contentView = blur

        let scr = screen ?? NSScreen.main ?? NSScreen.screens[0]
        let end = NSPoint(x: scr.frame.midX - size.width/2,
                          y: scr.frame.maxY - size.height - 60)
        win.setFrameOrigin(end)
        panel = win
        animateIn(win, to: end)
        scheduleHide()
    }

    private func perform(_ action: CaptureAction) {
        scheduleHide()
        let anchor = panel?.contentView
        action.run(text: text, anchor: anchor,
                   at: NSPoint(x: 24, y: anchor?.bounds.midY ?? 0), synth: synth)
        if action == .copy { flashCopied() }
    }

    private func flashCopied() {
        guard let blur = panel?.contentView,
              let stack = blur.subviews.compactMap({ $0 as? NSStackView }).first,
              let btn = stack.views.compactMap({ $0 as? ActionButton }).first
        else { return }
        let original = btn.titleField.stringValue
        btn.titleField.stringValue = "Copied"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.1) {
            btn.titleField.stringValue = original
        }
    }

    private func scheduleHide() {
        hideItem?.cancel()
        let item = DispatchWorkItem { [weak self] in self?.dismiss() }
        hideItem = item
        DispatchQueue.main.asyncAfter(deadline: .now() + 4.5, execute: item)
    }

    private func dismiss() {
        guard let win = panel else { return }
        panel = nil
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion { win.orderOut(nil); return }
        let o = win.frame.origin
        NSAnimationContext.runAnimationGroup({ c in
            c.duration = 0.24
            c.timingFunction = CAMediaTimingFunction(name: .easeIn)
            win.animator().alphaValue = 0
            win.animator().setFrameOrigin(NSPoint(x: o.x, y: o.y - 8))
        }, completionHandler: { win.orderOut(nil) })
    }

    private func animateIn(_ win: NSWindow, to end: NSPoint) {
        if NSWorkspace.shared.accessibilityDisplayShouldReduceMotion {
            win.alphaValue = 1; win.orderFrontRegardless(); return
        }
        win.alphaValue = 0
        win.setFrameOrigin(NSPoint(x: end.x, y: end.y - 12))
        win.orderFrontRegardless()
        let ease = CAMediaTimingFunction(controlPoints: 0.16, 1, 0.3, 1)
        NSAnimationContext.runAnimationGroup { c in
            c.duration = 0.34; c.timingFunction = ease
            win.animator().alphaValue = 1
            win.animator().setFrameOrigin(end)
        }
        if let layer = win.contentView?.layer {
            let pop = CABasicAnimation(keyPath: "transform.scale")
            pop.fromValue = 0.93; pop.toValue = 1.0
            pop.duration = 0.36; pop.timingFunction = ease
            layer.add(pop, forKey: "pop")
        }
    }

    private func roundedMask(radius: CGFloat) -> NSImage {
        let img = NSImage(size: NSSize(width: radius*2 + 1, height: radius*2 + 1),
                          flipped: false) { rect in
            NSColor.black.setFill()
            NSBezierPath(roundedRect: rect, xRadius: radius, yRadius: radius).fill()
            return true
        }
        img.capInsets = NSEdgeInsets(top: radius, left: radius, bottom: radius, right: radius)
        img.resizingMode = .stretch
        return img
    }
}


final class ShortcutRecorder: NSView {
    var onChange: ((Shortcut) -> Void)?
    private var shortcut: Shortcut
    private var recording = false { didSet { needsDisplay = true } }

    init(shortcut: Shortcut) {
        self.shortcut = shortcut
        super.init(frame: NSRect(x: 0, y: 0, width: 150, height: 30))
        wantsLayer = true
    }
    required init?(coder: NSCoder) { fatalError() }

    override var acceptsFirstResponder: Bool { true }
    override var intrinsicContentSize: NSSize { NSSize(width: 150, height: 30) }

    override func mouseDown(with e: NSEvent) {
        recording = true
        window?.makeFirstResponder(self)
    }
    override func resignFirstResponder() -> Bool { recording = false; return true }

    override func keyDown(with e: NSEvent) {
        guard recording else { super.keyDown(with: e); return }
        if e.keyCode == 53 { recording = false; return }
        shortcut = Shortcut(keyCode: UInt32(e.keyCode),
                            carbonModifiers: Shortcut.carbonModifiers(from: e.modifierFlags))
        recording = false
        onChange?(shortcut)
    }

    override func draw(_ dirty: NSRect) {
        let r = bounds.insetBy(dx: 1, dy: 1)
        let path = NSBezierPath(roundedRect: r, xRadius: 7, yRadius: 7)
        (recording ? NSColor.controlAccentColor.withAlphaComponent(0.18)
                   : NSColor.white.withAlphaComponent(0.06)).setFill()
        path.fill()
        (recording ? NSColor.controlAccentColor
                   : NSColor.white.withAlphaComponent(0.18)).setStroke()
        path.lineWidth = 1; path.stroke()

        let text = recording ? "Press shortcut…" : shortcut.display
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.systemFont(ofSize: 14, weight: .medium),
            .foregroundColor: recording ? NSColor.secondaryLabelColor : NSColor.labelColor,
        ]
        let size = (text as NSString).size(withAttributes: attrs)
        (text as NSString).draw(at: NSPoint(x: r.midX - size.width/2,
                                            y: r.midY - size.height/2), withAttributes: attrs)
    }
}


final class PreferencesWindowController: NSWindowController {
    var onShortcutChange: ((Shortcut) -> Void)?

    convenience init(shortcut: Shortcut) {
        let win = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 340, height: 190),
                           styleMask: [.titled, .closable], backing: .buffered, defer: false)
        win.title = "Linelens Settings"
        win.isReleasedWhenClosed = false
        win.center()
        self.init(window: win)

        let shortcutLabel = NSTextField(labelWithString: "Capture Shortcut")
        shortcutLabel.font = .systemFont(ofSize: 13, weight: .medium)

        let recorder = ShortcutRecorder(shortcut: shortcut)
        recorder.onChange = { [weak self] in self?.onShortcutChange?($0) }

        let shortcutRow = NSStackView(views: [shortcutLabel, NSView(), recorder])
        shortcutRow.orientation = .horizontal
        shortcutRow.distribution = .fill
        shortcutRow.spacing = 8

        let sub = NSTextField(labelWithString: "Click the field, then press your keys.")
        sub.font = .systemFont(ofSize: 11)
        sub.textColor = .secondaryLabelColor

        let separator = NSBox()
        separator.boxType = .separator

        let loginCheck = NSButton(checkboxWithTitle: "Open Linelens at Login",
                                  target: self, action: #selector(toggleLoginItem(_:)))
        loginCheck.font = .systemFont(ofSize: 13)
        loginCheck.state = LoginItem.isEnabled ? .on : .off

        let stack = NSStackView(views: [shortcutRow, sub, separator, loginCheck])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 14
        stack.translatesAutoresizingMaskIntoConstraints = false
        win.contentView?.addSubview(stack)
        if let c = win.contentView {
            shortcutRow.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            separator.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
            NSLayoutConstraint.activate([
                stack.topAnchor.constraint(equalTo: c.topAnchor, constant: 24),
                stack.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 24),
                stack.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -24),
            ])
        }
    }

    @objc private func toggleLoginItem(_ sender: NSButton) {
        LoginItem.isEnabled = (sender.state == .on)
    }
}


final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var hotkey: Hotkey?
    private var captureItem: NSMenuItem!
    private var prefs: PreferencesWindowController?
    private var shortcut = Shortcut.load()
    private var capturing = false
    private let hud = CaptureHUD()
    private let actionBar = ActionBar()
    private let synth = AVSpeechSynthesizer()
    private var activeScreen: NSScreen?

    private var primaryAction: CaptureAction {
        CaptureAction(rawValue: UserDefaults.standard.string(forKey: "primaryAction") ?? "copy")
            ?? .copy
    }

    static func focusedScreen() -> NSScreen? {
        let mouse = NSEvent.mouseLocation
        return NSScreen.screens.first { NSMouseInRect(mouse, $0.frame, false) }
            ?? NSScreen.main
    }

    func applicationDidFinishLaunching(_ note: Notification) {
        UserDefaults.standard.register(defaults: ["primaryAction": "copy"])

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.image = AppDelegate.statusIcon()
        }

        let menu = NSMenu()
        captureItem = menu.addItem(withTitle: "Capture Text",
                                   action: #selector(capture), keyEquivalent: "")
        captureItem.target = self
        menu.addItem(.separator())

        let onCapture = menu.addItem(withTitle: "On Capture", action: nil, keyEquivalent: "")
        let submenu = NSMenu()
        for action in CaptureAction.allCases {
            let item = submenu.addItem(withTitle: action.title,
                                       action: #selector(setPrimary(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = action.rawValue
            item.state = (action == primaryAction) ? .on : .off
        }
        submenu.addItem(.separator())
        let tip = submenu.addItem(withTitle: "Hold ⌘ while selecting to choose",
                                  action: nil, keyEquivalent: "")
        tip.isEnabled = false
        onCapture.submenu = submenu

        let shortcutItem = menu.addItem(withTitle: "Customize Shortcut…",
                                        action: #selector(openPreferences), keyEquivalent: "")
        shortcutItem.target = self
        menu.addItem(.separator())

        let quitItem = menu.addItem(withTitle: "Quit Linelens",
                                    action: #selector(quit), keyEquivalent: "q")
        quitItem.target = self
        statusItem.menu = menu

        hotkey = Hotkey { [weak self] in
            DispatchQueue.main.async { self?.capture() }
        }
        applyShortcut(shortcut)
    }

    private func applyShortcut(_ s: Shortcut) {
        shortcut = s
        s.save()
        hotkey?.setShortcut(keyCode: s.keyCode, modifiers: s.carbonModifiers)
        captureItem.title = "Capture Text  \(s.display)"
    }

    @objc private func openPreferences() {
        if prefs == nil {
            prefs = PreferencesWindowController(shortcut: shortcut)
            prefs?.onShortcutChange = { [weak self] in self?.applyShortcut($0) }
        }
        NSApp.activate(ignoringOtherApps: true)
        prefs?.showWindow(nil)
        prefs?.window?.makeKeyAndOrderFront(nil)
    }


    @objc private func capture() {
        guard !capturing else { return }
        capturing = true
        activeScreen = AppDelegate.focusedScreen()
        hud.showPrompt(on: activeScreen, hint: shortcut.display)

        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("linelens-\(ProcessInfo.processInfo.globallyUniqueString).png")

        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
        task.arguments = ["-i", "-x", "-o", tmp.path]
        task.terminationHandler = { [weak self] _ in
            let chooser = NSEvent.modifierFlags.contains(.command)
            DispatchQueue.main.async {
                self?.capturing = false
                self?.hud.hidePrompt()
                guard FileManager.default.fileExists(atPath: tmp.path),
                      let img = NSImage(contentsOf: tmp),
                      let cg = img.cgImage(forProposedRect: nil, context: nil, hints: nil)
                else { return }
                try? FileManager.default.removeItem(at: tmp)
                self?.recognize(cg, chooser: chooser)
            }
        }
        try? task.run()
    }

    private func recognize(_ cg: CGImage, chooser: Bool) {
        let request = VNRecognizeTextRequest { [weak self] req, _ in
            let lines = (req.results as? [VNRecognizedTextObservation] ?? [])
                .compactMap { $0.topCandidates(1).first?.string }
            let text = lines.joined(separator: "\n")
            DispatchQueue.main.async { self?.finish(text, chooser: chooser) }
        }
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.recognitionLanguages =
            (try? request.supportedRecognitionLanguages()) ?? ["en-US"]
        if #available(macOS 13.0, *) {
            request.automaticallyDetectsLanguage = true
        }

        DispatchQueue.global(qos: .userInitiated).async {
            try? VNImageRequestHandler(cgImage: cg, options: [:]).perform([request])
        }
    }

    private func finish(_ text: String, chooser: Bool) {
        let screen = activeScreen ?? AppDelegate.focusedScreen()
        guard !text.isEmpty else {
            return hud.showToast(symbol: "text.badge.xmark",
                                 text: "No text found", on: screen)
        }
        CaptureAction.copy.run(text: text, anchor: nil, at: .zero, synth: synth)
        flashIcon()

        if chooser {
            actionBar.show(text: text, on: screen, actions: CaptureAction.allCases)
            return
        }

        let action = primaryAction
        if action != .copy {
            let b = statusItem.button
            action.run(text: text, anchor: b,
                       at: NSPoint(x: b?.bounds.midX ?? 0, y: b?.bounds.minY ?? 0),
                       synth: synth)
        }

        let n = text.count
        let label: String
        switch action {
        case .copy:   label = "Copied \(n) character\(n == 1 ? "" : "s")"
        case .lookUp: label = "Copied · Looking up"
        case .search: label = "Copied · Searching"
        case .speak:  label = synth.isSpeaking ? "Copied · Speaking" : "Copied \(n) characters"
        }
        let symbol = action == .copy ? "checkmark.circle.fill" : action.symbol
        hud.showToast(symbol: symbol, text: label, on: screen)
    }

    @objc private func setPrimary(_ item: NSMenuItem) {
        guard let raw = item.representedObject as? String else { return }
        UserDefaults.standard.set(raw, forKey: "primaryAction")
        item.menu?.items.forEach {
            if $0.representedObject is String {
                $0.state = ($0.representedObject as? String == raw) ? .on : .off
            }
        }
    }

    @objc private func quit() {
        synth.stopSpeaking(at: .immediate)
        NSApp.terminate(nil)
    }

    static func statusIcon() -> NSImage {
        let P: CGFloat = 18
        let img = NSImage(size: NSSize(width: P, height: P), flipped: false) { _ in
            guard let c = NSGraphicsContext.current?.cgContext else { return false }
            c.setStrokeColor(NSColor.black.cgColor)
            c.setLineCap(.butt)
            c.setLineJoin(.miter)
            c.setLineWidth(1.5)
            let frame = CGRect(x: 4.2, y: 4.2, width: 9.6, height: 9.6)
            let framePath = CGPath(roundedRect: frame, cornerWidth: 1.8, cornerHeight: 1.8, transform: nil)
            c.addPath(framePath)
            c.strokePath()
            c.move(to: CGPoint(x: 5.8, y: P / 2))
            c.addLine(to: CGPoint(x: 12.2, y: P / 2))
            c.strokePath()
            return true
        }
        img.isTemplate = true
        return img
    }


    private func flashIcon() {
        guard let button = statusItem.button else { return }
        let original = button.image
        button.image = NSImage(systemSymbolName: "checkmark.circle.fill",
                               accessibilityDescription: nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9) {
            button.image = original
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
