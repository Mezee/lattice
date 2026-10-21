import Cocoa
import AVFoundation
import Carbon
import Speech

/// Debug logging is off unless enabled with: defaults write io.github.mezee.lattice debug -bool true
let debugLogging = UserDefaults.standard.bool(forKey: "debug")
func log(_ m: String) {
    guard debugLogging else { return }
    let line = "\(Date()) \(m)\n"
    let p = NSHomeDirectory() + "/Library/Logs/Lattice.log"
    if let h = FileHandle(forWritingAtPath: p) { h.seekToEndOfFile(); h.write(line.data(using: .utf8)!) }
    else { try? line.write(toFile: p, atomically: true, encoding: .utf8) }
}

let pttsPath = ["/opt/homebrew/bin/ptts", "/usr/local/bin/ptts", NSHomeDirectory() + "/.cargo/bin/ptts", NSHomeDirectory() + "/.local/bin/ptts"]
    .first { FileManager.default.isExecutableFile(atPath: $0) }

enum Pronounce {
    static let dictURL: URL = {
        let d = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0].appendingPathComponent("Lattice")
        try? FileManager.default.createDirectory(at: d, withIntermediateDirectories: true)
        return d.appendingPathComponent("pronunciations.txt")
    }()

    static let template = """
    # Pronunciation fixes. One per line:  word = how it should be said
    # Matching ignores case and punctuation around the word. Lines starting with # are ignored.
    # Example:
    # Nginx = engine X
    # Gradium = grah dee um

    """

    static let symbols: [Character: String] = [
        "⌘": "Command", "⇧": "Shift", "⌥": "Option", "⌃": "Control", "⎋": "Escape", "⇥": "Tab", "⏎": "Return", "↩": "Return",
        "⌫": "Delete", "⌦": "Forward Delete", "⇪": "Caps Lock", "␣": "Space", "⏏": "Eject", "⎈": "Control",
        "←": "left arrow", "→": "right arrow", "↑": "up arrow", "↓": "down arrow",
        "&": "and", "§": "section", "©": "copyright", "®": "registered", "™": "trademark", "°": "degrees",
        "•": "", "·": "", "▪": "", "◦": "", "✓": "check", "✔": "check", "✗": "cross", "✘": "cross", "×": "times", "÷": "divided by", "≈": "approximately", "≠": "not equal to", "≤": "less than or equal to", "≥": "greater than or equal to",
    ]

    static func loadDictionary() -> [String: String] {
        if !FileManager.default.fileExists(atPath: dictURL.path) { try? template.write(to: dictURL, atomically: true, encoding: .utf8) }
        var out: [String: String] = [:]
        for line in ((try? String(contentsOf: dictURL, encoding: .utf8)) ?? "").split(whereSeparator: \.isNewline) {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("#") { continue }
            let parts = t.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2, !parts[0].isEmpty { out[parts[0].lowercased()] = parts[1] }
        }
        return out
    }

    /// What should be spoken for one whitespace-separated token.
    static func spoken(_ token: String, dict: [String: String]) -> String {
        var chars = Array(token)
        var lead = "", trail = ""
        while let c = chars.first, !(c.isLetter || c.isNumber), symbols[c] == nil { lead.append(c); chars.removeFirst() }
        while let c = chars.last, !(c.isLetter || c.isNumber), symbols[c] == nil { trail = String(c) + trail; chars.removeLast() }
        let core = String(chars)
        if let r = dict[core.lowercased()] { return lead + r + trail }
        // Expand symbols, and read "+" between keys or numbers as "plus".
        var out = ""
        for (i, c) in chars.enumerated() {
            if let w = symbols[c] { out += " \(w) " }
            else if c == "+", i > 0, i < chars.count - 1 { out += " plus " }
            else { out.append(c) }
        }
        let cleaned = out.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
        return lead + cleaned + trail
    }
}

enum Aligner {
    /// Word start/end times (seconds) as heard in the audio, from the on-device speech analyzer.
    static func words(in url: URL) async -> [(word: String, start: Double, end: Double)] {
        do {
            let transcriber = SpeechTranscriber(locale: Locale(identifier: "en-US"), transcriptionOptions: [], reportingOptions: [], attributeOptions: [.audioTimeRange])
            if let req = try await AssetInstallationRequestHelper.request(for: transcriber) { try await req.downloadAndInstall() }
            let analyzer = SpeechAnalyzer(modules: [transcriber])
            let file = try AVAudioFile(forReading: url)
            async let collected: [(word: String, start: Double, end: Double)] = {
                var out: [(word: String, start: Double, end: Double)] = []
                for try await r in transcriber.results {
                    for run in r.text.runs {
                        if let tr = run.audioTimeRange {
                            out.append((String(r.text[run.range].characters).trimmingCharacters(in: .whitespaces), tr.start.seconds, tr.end.seconds))
                        }
                    }
                }
                return out
            }()
            if let last = try await analyzer.analyzeSequence(from: file) { try await analyzer.finalizeAndFinish(through: last) }
            else { await analyzer.cancelAndFinishNow() }
            return try await collected
        } catch { log("align failed: \(error)"); return [] }
    }

    /// Start time of each word in `text`, mapped from what the analyzer heard by cumulative letter count.
    static func starts(for text: [String], heard: [(word: String, start: Double, end: Double)]) -> [Double]? {
        func letters(_ w: String) -> Int { max(1, w.reduce(0) { $1.isLetter || $1.isNumber ? $0 + 1 : $0 }) }
        let heard = heard.filter { !$0.word.isEmpty }
        guard !text.isEmpty, !heard.isEmpty else { return nil }
        let hl = heard.map { Double(letters($0.word)) }, htotal = hl.reduce(0, +)
        let ol = text.map { Double(letters($0)) }, ototal = ol.reduce(0, +)
        func time(at f: Double) -> Double {
            let p = f * htotal; var before = 0.0
            for (k, l) in hl.enumerated() {
                if p < before + l || k == hl.count - 1 {
                    let frac = min(1, max(0, (p - before) / l))
                    return heard[k].start + frac * (heard[k].end - heard[k].start)
                }
                before += l
            }
            return heard[0].start
        }
        var out: [Double] = [], acc = 0.0
        for l in ol { out.append(time(at: acc / ototal)); acc += l }
        out[0] = heard[0].start
        return out
    }
}

enum AssetInstallationRequestHelper {
    static func request(for t: SpeechTranscriber) async throws -> AssetInstallationRequest? {
        try await AssetInventory.assetInstallationRequest(supporting: [t])
    }
}

final class Reader: NSObject, AVAudioPlayerDelegate {
    var sentences: [String] = []
    var index = 0
    var player: AVAudioPlayer?
    var session = 0
    var cache: [Int: URL] = [:]
    var starts: [Int: [Double]] = [:]
    var inflight: Set<Int> = []
    var waiters: [Int: () -> Void] = [:]
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("lattice-\(getpid())")
    var voice: String? { UserDefaults.standard.string(forKey: "voice") }
    var isActive: Bool { !sentences.isEmpty }
    var isPaused = false
    var onChange: () -> Void = {}

    override init() {
        super.init()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    func start(text: String) {
        stop()
        var out: [String] = []
        text.enumerateSubstrings(in: text.startIndex..., options: .bySentences) { s, _, _, _ in
            if let s = s?.trimmingCharacters(in: .whitespacesAndNewlines), s.contains(where: { $0.isLetter || $0.isNumber }) { out.append(s) }
        }
        guard !out.isEmpty else { return }
        sentences = out
        index = 0
        play(0)
    }

    func stop() {
        session += 1
        player?.stop(); player = nil
        sentences = []; cache = [:]; starts = [:]; inflight = []; waiters = [:]
        isPaused = false
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        onChange()
    }

    func togglePause() {
        guard isActive else { return }
        if isPaused { player?.play(); isPaused = false }
        else { player?.pause(); isPaused = true }
        onChange()
    }

    func jump(by delta: Int) {
        guard isActive else { return }
        let target = index + delta
        if target >= sentences.count { stop(); return }
        play(max(0, target))
    }

    func clearCache() { cache = [:]; starts = [:] }

    private func synth(_ i: Int, done: @escaping () -> Void) {
        if cache[i] != nil { done(); return }
        waiters[i] = done
        if inflight.contains(i) { return }
        inflight.insert(i)
        let s = session, original = sentences[i], voice = voice, out = dir.appendingPathComponent("\(i)-\(UUID().uuidString).wav")
        DispatchQueue.global(qos: .userInitiated).async {
            let dict = Pronounce.loadDictionary()
            let tokens = original.split(whereSeparator: { $0.isWhitespace }).map(String.init)
            let spokenTokens = tokens.map { Pronounce.spoken($0, dict: dict) }
            let text = spokenTokens.joined(separator: " ")
            log("spoken: \(text)")
            let p = Process()
            p.executableURL = URL(fileURLWithPath: pttsPath ?? "/usr/bin/false")
            var args = ["--lang", "en", "--rewrites", "all", "-o", out.path]
            if let v = voice { args += ["--voice", v] }
            args += ["--", text]
            p.arguments = args
            p.standardError = FileHandle.nullDevice; p.standardOutput = FileHandle.nullDevice
            do { try p.run() } catch { log("ptts launch failed: \(error)") }
            p.waitUntilExit()
            log("ptts exit \(p.terminationStatus) for sentence \(i)")
            var st: [Double]? = nil
            if p.terminationStatus == 0 {
                let sem = DispatchSemaphore(value: 0)
                Task { st = Aligner.starts(for: spokenTokens, heard: await Aligner.words(in: out)); sem.signal() }
                sem.wait()
                log("aligned sentence \(i): \(st == nil ? "no" : "yes")")
            }
            DispatchQueue.main.async {
                guard s == self.session else { return }
                self.inflight.remove(i)
                if p.terminationStatus == 0 { self.cache[i] = out; if let st { self.starts[i] = st } }
                self.waiters.removeValue(forKey: i)?()
            }
        }
    }

    private func play(_ i: Int) {
        player?.stop(); player = nil
        index = i; isPaused = false
        let s = session
        onChange()
        synth(i) { [weak self] in
            guard let self, s == self.session, self.index == i else { return }
            if let url = self.cache[i], let p = try? AVAudioPlayer(contentsOf: url) {
                p.delegate = self; self.player = p; p.play()
            } else { self.next(from: i) }
            if i + 1 < self.sentences.count { self.synth(i + 1) {} }
        }
    }

    private func next(from i: Int) {
        if i + 1 < sentences.count { play(i + 1) } else { stop() }
    }

    func audioPlayerDidFinishPlaying(_ p: AVAudioPlayer, successfully ok: Bool) {
        guard p === player else { return }
        next(from: index)
    }
}

func selectedText() -> String? {
    let pb = NSPasteboard.general
    let saved = pb.string(forType: .string)
    let before = pb.changeCount
    log("selectedText: trusted=\(AXIsProcessTrusted())")
    let src = CGEventSource(stateID: .combinedSessionState)
    for down in [true, false] {
        let e = CGEvent(keyboardEventSource: src, virtualKey: 8, keyDown: down) // C
        e?.flags = .maskCommand
        e?.post(tap: .cghidEventTap)
    }
    for _ in 0..<20 where pb.changeCount == before { Thread.sleep(forTimeInterval: 0.025) }
    let text = pb.changeCount != before ? pb.string(forType: .string) : nil
    log("selectedText: got \(text?.count ?? -1) chars")
    if let saved, text != nil { pb.clearContents(); pb.setString(saved, forType: .string) }
    return text
}

final class App: NSObject, NSApplicationDelegate {
    let reader = Reader()
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    var voiceMenu = NSMenu()
    var hud: HUD?
    lazy var voiceItem: NSMenuItem = { let v = NSMenuItem(title: "Voice", action: nil, keyEquivalent: ""); v.submenu = voiceMenu; return v }()
    let mainMenu = NSMenu()

    func applicationDidFinishLaunching(_ n: Notification) {
        if pttsPath == nil { missingPtts() }
        else if !AXIsProcessTrusted() { _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary) }
        buildMenu()
        hud = HUD(reader: reader)
        reader.onChange = { [weak self] in self?.refreshTitle(); self?.hud?.sync() }
        refreshTitle()
        registerHotKeys()
        DispatchQueue.global().async { self.loadVoices() }
    }

    func refreshTitle() {
        let r = reader
        item.button?.title = !r.isActive ? "🔈" : r.isPaused ? "⏸" : "🔊"
        item.button?.toolTip = r.isActive ? "Sentence \(r.index + 1) of \(r.sentences.count)" : "Lattice"
    }

    func buildMenu() {
        let m = mainMenu
        m.removeAllItems()
        func add(_ t: String, _ sel: Selector, _ key: String) {
            let mi = NSMenuItem(title: t, action: sel, keyEquivalent: ""); mi.target = self
            mi.toolTip = key; m.addItem(mi)
        }
        for a in Shortcut.actions { add("\(a.title)   \(Shortcut.load(a.key).display)", #selector(readSel), "") }
        add("Pause / Resume", #selector(pause), "")
        add("Previous Sentence", #selector(prev), "")
        add("Next Sentence", #selector(nextS), "")
        add("Stop", #selector(stopS), "")
        m.addItem(.separator())
        add("Shortcuts…", #selector(showShortcuts), "")
        add("Edit Pronunciations…", #selector(editPron), "")
        m.addItem(voiceItem)
        m.addItem(.separator())
        m.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        if item.menu !== m { item.menu = m }
    }

    func loadVoices() {
        let p = Process(); p.executableURL = URL(fileURLWithPath: pttsPath ?? "/usr/bin/false"); p.arguments = ["--list-voices"]
        let pipe = Pipe(); p.standardOutput = pipe; p.standardError = FileHandle.nullDevice
        try? p.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile(); p.waitUntilExit()
        let names = String(decoding: data, as: UTF8.self).split(separator: "\n").compactMap { l -> String? in
            let c = l.split(separator: "\t"); return c.count > 1 && c[1] == "en" ? String(c[0]) : nil
        }
        log("voices loaded: \(names.count), raw bytes \(data.count)")
        DispatchQueue.main.async {
            let cur = UserDefaults.standard.string(forKey: "voice")
            self.voiceMenu.removeAllItems()
            let d = NSMenuItem(title: "Default", action: #selector(self.pickVoice(_:)), keyEquivalent: ""); d.target = self
            d.state = cur == nil ? .on : .off; self.voiceMenu.addItem(d)
            for n in names {
                let mi = NSMenuItem(title: n, action: #selector(self.pickVoice(_:)), keyEquivalent: ""); mi.target = self
                mi.state = n == cur ? .on : .off; self.voiceMenu.addItem(mi)
            }
        }
    }

    @objc func pickVoice(_ s: NSMenuItem) {
        if s.title == "Default" { UserDefaults.standard.removeObject(forKey: "voice") }
        else { UserDefaults.standard.set(s.title, forKey: "voice") }
        voiceMenu.items.forEach { $0.state = ($0 === s) ? .on : .off }
        reader.clearCache()
    }

    func missingPtts() {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "The Phonon speech engine isn't installed"
        a.informativeText = "Install it with Homebrew, then reopen this app:\n\nbrew install gradium-ai/tap/ptts"
        a.addButton(withTitle: "Copy Command"); a.addButton(withTitle: "Quit")
        if a.runModal() == .alertFirstButtonReturn {
            NSPasteboard.general.clearContents(); NSPasteboard.general.setString("brew install gradium-ai/tap/ptts", forType: .string)
        }
        NSApp.terminate(nil)
    }

    func needAccessibility() {
        NSApp.activate(ignoringOtherApps: true)
        let a = NSAlert()
        a.messageText = "Allow Accessibility to read your selection"
        a.informativeText = "The app copies the text you highlight so it can read it aloud. Turn on Lattice in System Settings → Privacy & Security → Accessibility, then try again."
        a.addButton(withTitle: "Open Settings"); a.addButton(withTitle: "Cancel")
        if a.runModal() == .alertFirstButtonReturn {
            NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!)
        }
    }

    @objc func readSel() {
        if reader.isActive && !reader.isPaused { reader.stop(); return }
        guard AXIsProcessTrusted() else { needAccessibility(); return }
        DispatchQueue.global().async {
            if let t = selectedText(), !t.isEmpty { DispatchQueue.main.async { self.reader.start(text: t) } }
        }
    }
    @objc func pause() { reader.togglePause() }
    @objc func prev() { reader.jump(by: -1) }
    @objc func nextS() { reader.jump(by: 1) }
    @objc func stopS() { reader.stop() }

    func registerHotKeys() {
        var spec = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
        let ist = InstallEventHandler(GetApplicationEventTarget(), { _, ev, ud in
            var hk = EventHotKeyID()
            GetEventParameter(ev, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil, MemoryLayout<EventHotKeyID>.size, nil, &hk)
            let app = Unmanaged<App>.fromOpaque(ud!).takeUnretainedValue()
            log("hotkey \(hk.id)")
            DispatchQueue.main.async {
                switch hk.id {
                case 1: app.readSel()
                case 2: app.pause()
                case 3: app.prev()
                case 4: app.nextS()
                default: break
                }
            }
            return noErr
        }, 1, &spec, Unmanaged.passUnretained(self).toOpaque(), nil)
        log("install handler status=\(ist) trusted=\(AXIsProcessTrusted())")
        applyHotKeys()
    }

    var hotKeyRefs: [EventHotKeyRef] = []

    func applyHotKeys() {
        hotKeyRefs.forEach { UnregisterEventHotKey($0) }
        hotKeyRefs = []
        for (i, a) in Shortcut.actions.enumerated() {
            let s = Shortcut.load(a.key)
            var ref: EventHotKeyRef?
            let st = RegisterEventHotKey(s.code, s.mods, EventHotKeyID(signature: 0x50484E52, id: UInt32(i + 1)), GetApplicationEventTarget(), 0, &ref)
            log("register \(a.key) \(s.display) status=\(st)")
            if st == noErr, let ref { hotKeyRefs.append(ref) }
        }
        buildMenu()
    }

    @objc func editPron() {
        _ = Pronounce.loadDictionary()
        NSWorkspace.shared.open(Pronounce.dictURL)
        reader.clearCache()
    }

    var shortcutsWindow: ShortcutsWindow?
    @objc func showShortcuts() {
        if shortcutsWindow == nil {
            shortcutsWindow = ShortcutsWindow { [weak self] on in
                guard let self else { return }
                if on { self.hotKeyRefs.forEach { UnregisterEventHotKey($0) }; self.hotKeyRefs = [] } else { self.applyHotKeys() }
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        shortcutsWindow?.makeKeyAndOrderFront(nil)
    }
}

func serifFont(_ size: CGFloat) -> NSFont {
    let base = NSFont.systemFont(ofSize: size, weight: .regular)
    if let d = base.fontDescriptor.withDesign(.serif), let f = NSFont(descriptor: d, size: size) { return f }
    return base
}

func focusSplit(_ word: String) -> (String, String, String) {
    let ch = Array(word)
    guard !ch.isEmpty else { return ("", "", "") }
    let first = ch.firstIndex(where: { $0.isLetter || $0.isNumber }) ?? 0
    let letters = ch.reduce(0) { $1.isLetter || $1.isNumber ? $0 + 1 : $0 }
    let offset: Int
    switch letters {
    case 0...1: offset = 0
    case 2...5: offset = 1
    case 6...9: offset = 2
    case 10...13: offset = 3
    default: offset = 4
    }
    let f = min(first + offset, ch.count - 1)
    return (String(ch[..<f]), String(ch[f]), String(ch[(f + 1)...]))
}

final class WordView: NSView {
    var word = "" { didSet { needsDisplay = true } }
    let ink = NSColor(srgbRed: 0.90, green: 0.89, blue: 0.86, alpha: 1)
    let focus = NSColor(srgbRed: 218.0 / 255, green: 1.0, blue: 82.0 / 255, alpha: 1) // #DAFF52
    let guide = NSColor(white: 1, alpha: 0.18)

    override func draw(_ dirty: NSRect) {
        let cx = bounds.midX, margin: CGFloat = 20
        guide.setFill()
        let top = bounds.maxY - 6, bottom: CGFloat = 6
        NSRect(x: margin, y: top, width: bounds.width - margin * 2, height: 1).fill()
        NSRect(x: cx - 1, y: top - 12, width: 2, height: 12).fill()
        NSRect(x: margin, y: bottom, width: bounds.width - margin * 2, height: 1).fill()
        NSRect(x: cx - 1, y: bottom, width: 2, height: 12).fill()

        let (before, mid, after) = focusSplit(word)
        guard !mid.isEmpty else { return }
        var size: CGFloat = 38
        func w(_ t: String, _ f: NSFont) -> CGFloat { (t as NSString).size(withAttributes: [.font: f]).width }
        var font = serifFont(size)
        let half = cx - margin - 8
        let needed = max(w(before, font), w(after, font)) + w(mid, font) / 2
        if needed > half { size = max(14, size * half / needed); font = serifFont(size) }
        let fw = w(mid, font)
        let y = bounds.midY - (font.ascender - font.descender) / 2 - font.descender * 0
        func draw(_ t: String, _ x: CGFloat, _ c: NSColor) {
            (t as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: [.font: font, .foregroundColor: c])
        }
        draw(before, cx - fw / 2 - w(before, font), ink)
        draw(mid, cx - fw / 2, focus)
        draw(after, cx + fw / 2, ink)
    }
}

final class HUD: NSPanel {
    let reader: Reader
    let wordView = WordView(frame: NSRect(x: 0, y: 56, width: 440, height: 84))
    let progress = NSTextField(labelWithString: "")
    var playPauseButton: NSButton?
    var shown = false
    var timer: Timer?
    var boundsFor = -1
    var words: [String] = []
    var cum: [Double] = []

    init(reader: Reader) {
        self.reader = reader
        super.init(contentRect: NSRect(x: 0, y: 0, width: 440, height: 150),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
        isFloatingPanel = true
        level = .floating
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        isMovableByWindowBackground = true
        appearance = NSAppearance(named: .darkAqua)
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]
        if UserDefaults.standard.string(forKey: "NSWindow Frame PhononReaderHUD") == nil, let scr = NSScreen.main {
            let f = scr.visibleFrame
            setFrameOrigin(NSPoint(x: f.midX - 220, y: f.minY + 60))
        }
        setFrameAutosaveName("PhononReaderHUD")
        setContentSize(NSSize(width: 440, height: 150))

        let bg = NSVisualEffectView(frame: NSRect(x: 0, y: 0, width: 440, height: 150))
        bg.material = .hudWindow; bg.state = .active; bg.blendingMode = .behindWindow
        let r: CGFloat = 18
        let mask = NSImage(size: NSSize(width: r * 2 + 1, height: r * 2 + 1), flipped: false) { rect in
            NSColor.black.setFill(); NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill(); return true
        }
        mask.capInsets = NSEdgeInsets(top: r, left: r, bottom: r, right: r)
        mask.resizingMode = .stretch
        bg.maskImage = mask
        contentView = bg
        let tint = NSView(frame: bg.bounds)
        tint.autoresizingMask = [.width, .height]
        tint.wantsLayer = true
        tint.layer?.backgroundColor = NSColor(srgbRed: 0.106, green: 0.106, blue: 0.114, alpha: 0.93).cgColor
        tint.layer?.cornerRadius = r; tint.layer?.masksToBounds = true
        bg.addSubview(tint)
        bg.addSubview(wordView)

        progress.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular); progress.textColor = .tertiaryLabelColor
        progress.frame = NSRect(x: 20, y: 20, width: 90, height: 16)
        bg.addSubview(progress)

        func make(_ symbol: String, _ x: CGFloat, _ size: CGFloat, _ action: Selector) -> NSButton {
            let b = NSButton(frame: NSRect(x: x, y: 12, width: size, height: 36))
            b.isBordered = false; b.bezelStyle = .regularSquare; b.imagePosition = .imageOnly
            b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: size > 40 ? 24 : 18, weight: .regular))
            b.contentTintColor = .labelColor; b.target = self; b.action = action
            bg.addSubview(b); return b
        }
        _ = make("backward.fill", 150, 44, #selector(back))
        playPauseButton = make("pause.fill", 198, 44, #selector(toggle))
        _ = make("forward.fill", 246, 44, #selector(fwd))
        _ = make("xmark", 388, 36, #selector(close2))
    }

    override var canBecomeKey: Bool { false }
    override var canBecomeMain: Bool { false }

    @objc func back() { reader.jump(by: -1) }
    @objc func fwd() { reader.jump(by: 1) }
    @objc func toggle() { reader.togglePause() }
    @objc func close2() { reader.stop() }

    /// Estimates when each word is spoken inside the sentence's audio, by word length and punctuation.
    func prepareWords() {
        guard reader.index < reader.sentences.count else { return }
        boundsFor = reader.index
        words = reader.sentences[reader.index].split(whereSeparator: { $0.isWhitespace }).map(String.init)
        var total = 0.0, weights: [Double] = []
        for w in words {
            let letters = w.reduce(0) { $1.isLetter || $1.isNumber ? $0 + 1 : $0 }
            var x = Double(max(letters, 2)) + 1.0
            if let m = w.last(where: { !"\"'”’)]}".contains($0) }) {
                if ".!?…".contains(m) { x += 4 } else if ",;:—–".contains(m) { x += 2.5 }
            }
            weights.append(x); total += x
        }
        var acc = 0.0
        cum = weights.map { acc += $0; return acc / max(total, 0.001) }
    }

    func tick() {
        guard reader.isActive else { return }
        if boundsFor != reader.index { prepareWords() }
        guard !words.isEmpty else { return }
        guard let p = reader.player, p.duration > 0 else { return }
        let i: Int
        if let st = reader.starts[reader.index], st.count == words.count {
            let t = p.currentTime
            i = st.lastIndex(where: { $0 <= t }) ?? 0
        } else {
            let frac = p.currentTime / p.duration
            i = cum.firstIndex(where: { frac < $0 }) ?? words.count - 1
        }
        if wordView.word != words[i] { wordView.word = words[i] }
    }

    func sync() {
        if reader.isActive {
            let sym = reader.isPaused ? "play.fill" : "pause.fill"
            playPauseButton?.image = NSImage(systemSymbolName: sym, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: 24, weight: .regular))
            progress.stringValue = "\(reader.index + 1) / \(reader.sentences.count)"
            if boundsFor != reader.index { prepareWords(); if let f = words.first { wordView.word = f } }
            if timer == nil {
                timer = Timer.scheduledTimer(withTimeInterval: 0.03, repeats: true) { [weak self] _ in self?.tick() }
            }
            if !shown {
                shown = true
                if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }), let scr = NSScreen.main {
                    let f = scr.visibleFrame
                    setFrameOrigin(NSPoint(x: f.midX - frame.width / 2, y: f.minY + 60))
                }
                alphaValue = 0; orderFrontRegardless(); invalidateShadow()
                NSAnimationContext.runAnimationGroup { $0.duration = 0.15; self.animator().alphaValue = 1 }
            }
        } else if shown {
            shown = false
            timer?.invalidate(); timer = nil; boundsFor = -1
            NSAnimationContext.runAnimationGroup({ $0.duration = 0.25; self.animator().alphaValue = 0 }) {
                if !self.shown { self.orderOut(nil) }
            }
        }
    }
}

struct Shortcut {
    var code: UInt32, mods: UInt32, label: String

    static let actions: [(key: String, title: String, def: Shortcut)] = [
        ("read", "Read selection / stop", Shortcut(code: 15, mods: UInt32(controlKey | optionKey), label: "R")),
    ]

    static func load(_ key: String) -> Shortcut {
        if let d = UserDefaults.standard.dictionary(forKey: "sc-" + key),
           let c = d["code"] as? Int, let m = d["mods"] as? Int, let l = d["label"] as? String {
            return Shortcut(code: UInt32(c), mods: UInt32(m), label: l)
        }
        return actions.first { $0.key == key }!.def
    }
    func save(_ key: String) {
        UserDefaults.standard.set(["code": Int(code), "mods": Int(mods), "label": label], forKey: "sc-" + key)
    }
    var display: String {
        (mods & UInt32(controlKey) != 0 ? "⌃" : "") + (mods & UInt32(optionKey) != 0 ? "⌥" : "") +
        (mods & UInt32(shiftKey) != 0 ? "⇧" : "") + (mods & UInt32(cmdKey) != 0 ? "⌘" : "") + label
    }
    static func from(_ e: NSEvent) -> Shortcut? {
        var m: UInt32 = 0
        let f = e.modifierFlags
        if f.contains(.control) { m |= UInt32(controlKey) }
        if f.contains(.option) { m |= UInt32(optionKey) }
        if f.contains(.shift) { m |= UInt32(shiftKey) }
        if f.contains(.command) { m |= UInt32(cmdKey) }
        guard m != 0 else { return nil }
        let special: [UInt16: String] = [49: "Space", 123: "←", 124: "→", 125: "↓", 126: "↑", 36: "Return", 48: "Tab", 51: "⌫",
                                         122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6", 98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12"]
        let label = special[e.keyCode] ?? (e.charactersIgnoringModifiers ?? "?").uppercased()
        return Shortcut(code: UInt32(e.keyCode), mods: m, label: label)
    }
}

final class ShortcutsWindow: NSWindow {
    var buttons: [String: NSButton] = [:]
    var recording: String?
    var monitor: Any?
    let onRecording: (Bool) -> Void

    init(onRecording: @escaping (Bool) -> Void) {
        self.onRecording = onRecording
        super.init(contentRect: NSRect(x: 0, y: 0, width: 380, height: 64 + 36 * Shortcut.actions.count + 40),
                   styleMask: [.titled, .closable], backing: .buffered, defer: false)
        title = "Lattice Shortcuts"
        isReleasedWhenClosed = false
        center()
        let h = contentRect(forFrameRect: frame).height
        for (i, a) in Shortcut.actions.enumerated() {
            let y = h - 58 - CGFloat(i) * 36
            let l = NSTextField(labelWithString: a.title); l.frame = NSRect(x: 20, y: y, width: 170, height: 22)
            let b = NSButton(title: "", target: self, action: #selector(record(_:)))
            b.frame = NSRect(x: 200, y: y - 3, width: 160, height: 28); b.identifier = NSUserInterfaceItemIdentifier(a.key)
            b.bezelStyle = .rounded
            contentView?.addSubview(l); contentView?.addSubview(b)
            buttons[a.key] = b
        }
        let hint = NSTextField(labelWithString: "Click a shortcut, then press new keys (with a modifier). Esc cancels.")
        hint.font = .systemFont(ofSize: 11); hint.textColor = .secondaryLabelColor
        hint.frame = NSRect(x: 20, y: 10, width: 340, height: 16); contentView?.addSubview(hint)
        refresh()
    }

    func refresh() {
        for a in Shortcut.actions { buttons[a.key]?.title = recording == a.key ? "Press keys…" : Shortcut.load(a.key).display }
    }

    @objc func record(_ s: NSButton) {
        log("record clicked: \(s.identifier?.rawValue ?? "?")")
        stopRecording()
        recording = s.identifier!.rawValue
        onRecording(true)
        refresh()
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] e in
            log("keyDown code=\(e.keyCode) flags=\(e.modifierFlags.rawValue) recording=\(self?.recording ?? "nil")")
            guard let self, let key = self.recording else { return e }
            if e.keyCode == 53 { self.stopRecording(); return nil }
            if let sc = Shortcut.from(e) {
                sc.save(key)
                self.stopRecording()
            } else {
                NSSound.beep()
                self.buttons[key]?.title = "Add a modifier key"
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { if self.recording == key { self.refresh() } }
            }
            return nil
        }
    }

    func stopRecording() {
        let was = recording != nil
        if let m = monitor { NSEvent.removeMonitor(m) }
        monitor = nil; recording = nil; refresh()
        if was { onRecording(false) }
    }

    override func close() { stopRecording(); super.close() }
}

let app = NSApplication.shared
let delegate = App()
app.delegate = delegate
app.setActivationPolicy(.accessory)
app.run()
