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

/// Best-effort read of the user's current selection via the Accessibility API.
/// No clipboard involved, so it works even where simulated Cmd+C is swallowed
/// (terminals, remote sessions, some IDEs). Returns nil when nothing exposes a selection.
func axElement(_ ref: CFTypeRef?) -> AXUIElement? {
    guard let ref, CFGetTypeID(ref) == AXUIElementGetTypeID() else { return nil }
    return ref as! AXUIElement
}

func axSelectedText(verbose: Bool = true) -> String? {
    func vlog(_ m: String) { if verbose { log(m) } }
    let front = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
    let system = AXUIElementCreateSystemWide()
    var appRef: CFTypeRef?
    let e1 = AXUIElementCopyAttributeValue(system, kAXFocusedApplicationAttribute as CFString, &appRef)
    guard e1 == .success, let app = axElement(appRef) else { vlog("ax[\(front)]: no focused app (err \(e1.rawValue))"); return nil }
    var focusedRef: CFTypeRef?
    let e2 = AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &focusedRef)
    guard e2 == .success, let focused = axElement(focusedRef) else { vlog("ax[\(front)]: no focused element (err \(e2.rawValue))"); return nil }
    // The focused element usually holds the selection; some apps put it one level up.
    var candidates = [focused]
    var parentRef: CFTypeRef?
    if AXUIElementCopyAttributeValue(focused, kAXParentAttribute as CFString, &parentRef) == .success,
       let parent = axElement(parentRef) { candidates.append(parent) }
    for (i, el) in candidates.enumerated() {
        var roleRef: CFTypeRef?
        _ = AXUIElementCopyAttributeValue(el, kAXRoleAttribute as CFString, &roleRef)
        var selRef: CFTypeRef?
        let e3 = AXUIElementCopyAttributeValue(el, "AXSelectedText" as CFString, &selRef)
        let s = selRef as? String
        vlog("ax[\(front)]: candidate \(i) role=\((roleRef as? String) ?? "?") AXSelectedText err=\(e3.rawValue) chars=\(s?.count ?? -1)")
        if e3 == .success, let s, !s.isEmpty { return s }
        // Some apps (Terminal) report the selection only as a range into the element's text.
        var rangeRef: CFTypeRef?, valueRef: CFTypeRef?
        let e4 = AXUIElementCopyAttributeValue(el, "AXSelectedTextRange" as CFString, &rangeRef)
        let e5 = AXUIElementCopyAttributeValue(el, kAXValueAttribute as CFString, &valueRef)
        var range = CFRange(location: 0, length: 0)
        let haveRange = e4 == .success && rangeRef != nil && CFGetTypeID(rangeRef!) == AXValueGetTypeID()
            && AXValueGetValue(rangeRef as! AXValue, .cfRange, &range)
        let text = valueRef as? String
        vlog("ax[\(front)]: candidate \(i) range err=\(e4.rawValue) loc=\(range.location) len=\(range.length) value err=\(e5.rawValue) chars=\(text?.count ?? -1)")
        if haveRange, range.length > 0, let text {
            let ns = text as NSString
            if range.location >= 0, range.location + range.length <= ns.length {
                let sub = ns.substring(with: NSRange(location: range.location, length: range.length))
                if !sub.isEmpty { return sub }
            }
        }
    }
    return nil
}

/// Terminals don't expose their selection and ignore the simulated Cmd+C, so for them Lattice reads what you
/// just copied yourself. To keep that safe, it only applies in terminal apps and only to a recent copy.
let terminalBundleIDs: Set<String> = [
    "com.apple.Terminal", "com.mitchellh.ghostty", "com.googlecode.iterm2", "net.kovidgoyal.kitty",
    "org.alacritty", "com.github.wez.wezterm", "dev.warp.Warp-Stable", "co.zeit.hyper", "com.raphaelamorim.rio",
    "org.tabby", "io.alacritty",
]
let recentCopyWindow: TimeInterval = 90
var lastPasteboardCount = NSPasteboard.general.changeCount
var lastPasteboardChange = Date.distantPast

func startPasteboardTracker() {
    let t = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
        let c = NSPasteboard.general.changeCount
        if c != lastPasteboardCount { lastPasteboardCount = c; lastPasteboardChange = Date() }
    }
    RunLoop.main.add(t, forMode: .common)
}

func recentTerminalCopy() -> String? {
    guard let id = NSWorkspace.shared.frontmostApplication?.bundleIdentifier, terminalBundleIDs.contains(id),
          Date().timeIntervalSince(lastPasteboardChange) < recentCopyWindow,
          let text = NSPasteboard.general.string(forType: .string),
          !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
    log("selectedText: terminal, using the clipboard copied \(Int(Date().timeIntervalSince(lastPasteboardChange)))s ago (\(text.count) chars)")
    return text
}

/// Terminals clear their selection on the shortcut's own keypress (Ghostty: selection-clear-on-typing), before Lattice
/// can read it. So while a terminal is in front, remember its latest selection for a moment and use that.
let selectionLock = NSLock()
var cachedSelection: (text: String, app: String, time: Date)?
var lastSeenSelectionLength = -1

func frontTerminalID() -> String? {
    guard let id = NSWorkspace.shared.frontmostApplication?.bundleIdentifier, terminalBundleIDs.contains(id) else { return nil }
    return id
}

func startTerminalSelectionTracker() {
    let q = DispatchQueue(label: "lattice.selection-tracker", qos: .utility)
    let t = DispatchSource.makeTimerSource(queue: q)
    t.schedule(deadline: .now(), repeating: .milliseconds(150))
    t.setEventHandler {
        guard AXIsProcessTrusted(), let id = frontTerminalID() else { return }
        let text = axSelectedText(verbose: false)
        selectionLock.lock(); defer { selectionLock.unlock() }
        if let text, !text.isEmpty {
            cachedSelection = (text, id, Date())
        }
        let len = text?.count ?? 0
        if len != lastSeenSelectionLength { lastSeenSelectionLength = len; log("watch: \(id) selection is now \(len) chars") }
    }
    t.resume()
    trackerTimer = t
}
var trackerTimer: DispatchSourceTimer?

func recentTerminalSelection() -> String? {
    guard let id = frontTerminalID() else { return nil }
    selectionLock.lock(); defer { selectionLock.unlock() }
    guard let c = cachedSelection, c.app == id, Date().timeIntervalSince(c.time) < 1 else { return nil }
    log("selectedText: terminal selection from \(Int(Date().timeIntervalSince(c.time) * 1000)) ms ago (\(c.text.count) chars)")
    return c.text
}

func selectedText() -> String? {
    // 1) Accessibility selection: no clipboard side effects, terminal-friendly.
    if let s = axSelectedText() {
        log("selectedText: ax api got \(s.count) chars")
        return s
    }
    // 2) Terminals: the selection the moment before the shortcut's keypress cleared it.
    if let s = recentTerminalSelection() { return s }
    // 3) Fallback: send Cmd+C and read the clipboard (previous behavior).
    let pb = NSPasteboard.general
    let saved = pb.string(forType: .string)
    let before = pb.changeCount
    log("selectedText: trusted=\(AXIsProcessTrusted())")
    let src = CGEventSource(stateID: .combinedSessionState)
    // The shortcut's own keys are usually still held. If they were still down, the app would see
    // e.g. Ctrl+Opt+Cmd+C instead of Cmd+C and ignore it (terminals do), so wait for release first.
    let held: CGEventFlags = [.maskShift, .maskControl, .maskAlternate, .maskCommand]
    var waited = 0
    while !CGEventSource.flagsState(.combinedSessionState).intersection(held).isEmpty && waited < 60 {
        Thread.sleep(forTimeInterval: 0.025); waited += 1
    }
    log("selectedText: waited \(waited * 25) ms for modifier release")
    for down in [true, false] {
        let e = CGEvent(keyboardEventSource: src, virtualKey: 8, keyDown: down) // C
        e?.flags = .maskCommand
        e?.post(tap: .cghidEventTap)
    }
    for _ in 0..<20 where pb.changeCount == before { Thread.sleep(forTimeInterval: 0.025) }
    let text = pb.changeCount != before ? pb.string(forType: .string) : nil
    log("selectedText: clip fallback got \(text?.count ?? -1) chars")
    if text == nil { return recentTerminalCopy() }
    if let saved { pb.clearContents(); pb.setString(saved, forType: .string) }
    lastPasteboardCount = pb.changeCount   // our own copy and restore are not a user copy
    return text
}

final class App: NSObject, NSApplicationDelegate, NSMenuDelegate {
    let reader = Reader()
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    var voiceMenu = NSMenu()
    var hud: HUD?
    lazy var voiceItem: NSMenuItem = { let v = NSMenuItem(title: "Voice", action: nil, keyEquivalent: ""); v.submenu = voiceMenu; return v }()
    let mainMenu = NSMenu()

    func applicationDidFinishLaunching(_ n: Notification) {
        if pttsPath == nil { missingPtts() }
        else if !AXIsProcessTrusted() { _ = AXIsProcessTrustedWithOptions([kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary) }
        mainMenu.delegate = self
        buildMenu()
        hud = HUD(reader: reader)
        reader.onChange = { [weak self] in self?.refreshTitle(); self?.hud?.sync() }
        refreshTitle()
        registerHotKeys()
        startPasteboardTracker()
        startTerminalSelectionTracker()
        DispatchQueue.global().async { self.loadVoices() }
    }

    func refreshTitle() {
        let r = reader
        item.button?.title = ""
        item.button?.image = menuBarGlyph(!r.isActive ? 0 : r.isPaused ? 2 : 1)
        item.button?.toolTip = r.isActive ? "Sentence \(r.index + 1) of \(r.sentences.count)" : "Lattice"
    }

    /// Menu key-equivalent for a recorded shortcut, so macOS right-aligns it like any native shortcut.
    func keyEquivalent(for sc: Shortcut) -> (String, NSEvent.ModifierFlags)? {
        var flags: NSEvent.ModifierFlags = []
        if sc.mods & UInt32(controlKey) != 0 { flags.insert(.control) }
        if sc.mods & UInt32(optionKey) != 0 { flags.insert(.option) }
        if sc.mods & UInt32(shiftKey) != 0 { flags.insert(.shift) }
        if sc.mods & UInt32(cmdKey) != 0 { flags.insert(.command) }
        let special: [String: Int] = ["←": NSLeftArrowFunctionKey, "→": NSRightArrowFunctionKey, "↑": NSUpArrowFunctionKey, "↓": NSDownArrowFunctionKey]
        switch sc.label {
        case "Space": return (" ", flags)
        case "Return": return ("\r", flags)
        case "Tab": return ("\t", flags)
        case let l where special[l] != nil: return (String(UnicodeScalar(special[l]!)!), flags)
        case let l where l.count == 1: return (l.lowercased(), flags)
        default: return nil
        }
    }

    func buildMenu() {
        let m = mainMenu
        m.removeAllItems()
        func add(_ t: String, _ sel: Selector, to menu: NSMenu? = nil) {
            let mi = NSMenuItem(title: t, action: sel, keyEquivalent: ""); mi.target = self
            (menu ?? m).addItem(mi)
        }

        // Reading
        let read = NSMenuItem(title: reader.isActive && !reader.isPaused ? "Stop Reading" : "Read Selection", action: #selector(readSel), keyEquivalent: "")
        read.target = self
        let sc = Shortcut.load("read")
        if let (k, flags) = keyEquivalent(for: sc) { read.keyEquivalent = k; read.keyEquivalentModifierMask = flags }
        else { read.title += "   \(sc.display)" }
        m.addItem(read)

        // Playback controls are on the floating bar, so the menu only offers them while reading.
        if reader.isActive {
            m.addItem(.separator())
            add(reader.isPaused ? "Resume" : "Pause", #selector(pause))
            add("Previous Sentence", #selector(prev))
            add("Next Sentence", #selector(nextS))
        }

        // Settings
        m.addItem(.separator())
        m.addItem(voiceItem)
        let accent = NSMenuItem(title: "Accent Color", action: nil, keyEquivalent: ""); let am = NSMenu()
        add("Choose…", #selector(pickAccent), to: am); add("Reset to Default", #selector(resetAccent), to: am)
        accent.submenu = am; m.addItem(accent)
        let glassItem = NSMenuItem(title: "Liquid Glass Bar", action: #selector(toggleGlass), keyEquivalent: ""); glassItem.target = self
        glassItem.state = (UserDefaults.standard.object(forKey: "glass") as? Bool ?? true) ? .on : .off
        m.addItem(glassItem)
        add("Shortcuts…", #selector(showShortcuts))
        add("Pronunciations…", #selector(editPron))

        m.addItem(.separator())
        let quit = NSMenuItem(title: "Quit Lattice", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        m.addItem(quit)
        if item.menu !== m { item.menu = m }
    }

    func menuNeedsUpdate(_ menu: NSMenu) { if menu === mainMenu { buildMenu() } }

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
        let frontName = NSWorkspace.shared.frontmostApplication?.localizedName ?? "?"
        log("readSel: front=\(frontName) trusted=\(AXIsProcessTrusted())")
        if reader.isActive && !reader.isPaused { reader.stop(); return }
        guard AXIsProcessTrusted() else { needAccessibility(); return }
        DispatchQueue.global().async {
            if let t = selectedText(), !t.isEmpty { DispatchQueue.main.async { self.reader.start(text: t) } }
            else { DispatchQueue.main.async { NSSound.beep() } }
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

    var colorObserver: Any?
    @objc func pickAccent() {
        NSApp.activate(ignoringOtherApps: true)
        let p = NSColorPanel.shared
        p.showsAlpha = false
        p.color = accentColor()
        p.setTarget(self); p.setAction(#selector(accentChanged(_:))); p.isContinuous = true
        if colorObserver == nil {
            colorObserver = NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: p, queue: .main) { [weak self] _ in
                self?.hud?.sync()
            }
        }
        hud?.preview()
        p.makeKeyAndOrderFront(nil)
    }

    @objc func accentChanged(_ p: NSColorPanel) {
        saveAccent(p.color)
        hud?.wordView.needsDisplay = true
    }

    @objc func toggleGlass() {
        let on = UserDefaults.standard.object(forKey: "glass") as? Bool ?? true
        UserDefaults.standard.set(!on, forKey: "glass")
        hud?.applyStyle()
    }

    @objc func resetAccent() {
        UserDefaults.standard.removeObject(forKey: "accent")
        NSColorPanel.shared.color = defaultAccent
        hud?.wordView.needsDisplay = true
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

func serifFont(_ size: CGFloat, _ weight: NSFont.Weight = .regular) -> NSFont {
    let base = NSFont.systemFont(ofSize: size, weight: weight)
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

let defaultAccent = NSColor(srgbRed: 218.0 / 255, green: 1.0, blue: 82.0 / 255, alpha: 1) // #DAFF52

func accentColor() -> NSColor {
    if let hex = UserDefaults.standard.string(forKey: "accent"), hex.count == 7, hex.hasPrefix("#"),
       let v = UInt32(hex.dropFirst(), radix: 16) {
        return NSColor(srgbRed: CGFloat((v >> 16) & 255) / 255, green: CGFloat((v >> 8) & 255) / 255, blue: CGFloat(v & 255) / 255, alpha: 1)
    }
    return defaultAccent
}

func saveAccent(_ c: NSColor) {
    guard let c = c.usingColorSpace(.sRGB) else { return }
    let hex = String(format: "#%02X%02X%02X", Int(round(c.redComponent * 255)), Int(round(c.greenComponent * 255)), Int(round(c.blueComponent * 255)))
    UserDefaults.standard.set(hex, forKey: "accent")
}

/// Menu-bar icon: the Lattice cube with its speech bubble, as a template image so macOS tints it. State: 0 idle, 1 reading, 2 paused.
func menuBarGlyph(_ state: Int) -> NSImage {
    let name = ["menubar-idle", "menubar-reading", "menubar-paused"][state]
    if let url = Bundle.main.url(forResource: name, withExtension: "png"), let img = NSImage(contentsOf: url) {
        img.size = NSSize(width: 18, height: 18)
        img.isTemplate = true
        return img
    }
    return fallbackGlyph(state)
}

/// Drawn stand-in used only if the bundled images are missing.
func fallbackGlyph(_ state: Int) -> NSImage {
    let img = NSImage(size: NSSize(width: 18, height: 18), flipped: false) { _ in
        let c = NSPoint(x: 9, y: 9), r: CGFloat = 8.2
        let hex = NSBezierPath()
        for i in 0..<6 {
            let a = (90.0 - 60.0 * Double(i)) * .pi / 180
            let p = NSPoint(x: c.x + r * CGFloat(cos(a)), y: c.y + r * CGFloat(sin(a)))
            i == 0 ? hex.move(to: p) : hex.line(to: p)
        }
        hex.close(); hex.lineJoinStyle = .round; hex.lineWidth = 1.4
        NSColor.black.setFill(); NSColor.black.setStroke()
        hex.fill(); hex.stroke()

        let bubble = NSBezierPath(roundedRect: NSRect(x: 4.6, y: 6.4, width: 8.8, height: 6.0), xRadius: 1.6, yRadius: 1.6)
        bubble.move(to: NSPoint(x: 6.0, y: 6.6)); bubble.line(to: NSPoint(x: 5.6, y: 4.6)); bubble.line(to: NSPoint(x: 8.0, y: 6.6)); bubble.close()
        NSGraphicsContext.current?.compositingOperation = .clear
        bubble.fill()
        NSGraphicsContext.current?.compositingOperation = .sourceOver

        NSColor.black.setFill()
        func bar(_ x: CGFloat, _ h: CGFloat) { NSBezierPath(roundedRect: NSRect(x: x, y: 9.4 - h / 2, width: 1.2, height: h), xRadius: 0.6, yRadius: 0.6).fill() }
        if state == 1 { bar(6.6, 2.0); bar(8.4, 3.6); bar(10.2, 2.6) }
        if state == 2 { bar(7.4, 3.4); bar(9.8, 3.4) }
        return true
    }
    img.isTemplate = true
    return img
}

final class WordView: NSView {
    var word = "" { didSet { needsDisplay = true } }
    let ink = NSColor(srgbRed: 0.90, green: 0.89, blue: 0.86, alpha: 1)
    var focus: NSColor { accentColor() }
    let guide = NSColor(white: 1, alpha: 0.35)

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
        var font = serifFont(size, .medium), bold = serifFont(size, .bold)
        let half = cx - margin - 8
        let needed = max(w(before, font), w(after, font)) + w(mid, bold) / 2
        if needed > half { size = max(14, size * half / needed); font = serifFont(size, .medium); bold = serifFont(size, .bold) }
        let fw = w(mid, bold)
        let y = bounds.midY - (font.ascender - font.descender) / 2
        func draw(_ t: String, _ x: CGFloat, _ c: NSColor, _ f: NSFont) {
            (t as NSString).draw(at: NSPoint(x: x, y: y), withAttributes: [.font: f, .foregroundColor: c])
        }
        draw(before, cx - fw / 2 - w(before, font), ink, font)
        draw(mid, cx - fw / 2, focus, bold)
        draw(after, cx + fw / 2, ink, font)
    }
}

final class HUD: NSPanel {
    let reader: Reader
    let wordView = WordView(frame: NSRect(x: 0, y: 56, width: 440, height: 84))
    let progress = NSTextField(labelWithString: "")
    var playPauseButton: NSButton?
    let container = NSView(frame: NSRect(x: 0, y: 0, width: 440, height: 150))
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

        container.addSubview(wordView)

        progress.font = .monospacedDigitSystemFont(ofSize: 11, weight: .regular); progress.textColor = NSColor(white: 1, alpha: 0.6)
        progress.frame = NSRect(x: 20, y: 20, width: 90, height: 16)
        container.addSubview(progress)

        func make(_ symbol: String, _ x: CGFloat, _ size: CGFloat, _ action: Selector) -> NSButton {
            let b = NSButton(frame: NSRect(x: x, y: 12, width: size, height: 36))
            b.isBordered = false; b.bezelStyle = .regularSquare; b.imagePosition = .imageOnly
            b.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)?
                .withSymbolConfiguration(.init(pointSize: size > 40 ? 24 : 18, weight: .regular))
            b.contentTintColor = .labelColor; b.target = self; b.action = action
            container.addSubview(b); return b
        }
        _ = make("backward.fill", 150, 44, #selector(back))
        playPauseButton = make("pause.fill", 198, 44, #selector(toggle))
        _ = make("forward.fill", 246, 44, #selector(fwd))
        _ = make("xmark", 388, 36, #selector(close2))
        applyStyle()
    }

    /// Liquid Glass (macOS 26) by default; a solid dark bar if switched off in the menu.
    func applyStyle() {
        container.removeFromSuperview()
        let frame = NSRect(x: 0, y: 0, width: 440, height: 150)
        if UserDefaults.standard.object(forKey: "glass") as? Bool ?? true {
            let g = NSGlassEffectView(frame: frame)
            g.cornerRadius = 22
            g.tintColor = NSColor(srgbRed: 0.06, green: 0.06, blue: 0.07, alpha: 0.88)
            hasShadow = false   // the glass draws its own edge; the window shadow showed as an outline at the corners
            // The glass ignores most of its tint, so a dark layer under the controls guarantees contrast.
            container.wantsLayer = true
            container.layer?.backgroundColor = NSColor(srgbRed: 0.06, green: 0.06, blue: 0.07, alpha: 0.80).cgColor
            container.layer?.cornerRadius = 22; container.layer?.masksToBounds = true
            g.contentView = container
            contentView = g
        } else {
            hasShadow = true
            let bg = NSVisualEffectView(frame: frame)
            bg.material = .hudWindow; bg.state = .active; bg.blendingMode = .behindWindow
            let r: CGFloat = 18
            let mask = NSImage(size: NSSize(width: r * 2 + 1, height: r * 2 + 1), flipped: false) { rect in
                NSColor.black.setFill(); NSBezierPath(roundedRect: rect, xRadius: r, yRadius: r).fill(); return true
            }
            mask.capInsets = NSEdgeInsets(top: r, left: r, bottom: r, right: r)
            mask.resizingMode = .stretch
            bg.maskImage = mask
            let tint = NSView(frame: frame)
            tint.autoresizingMask = [.width, .height]
            tint.wantsLayer = true
            tint.layer?.backgroundColor = NSColor(srgbRed: 0.106, green: 0.106, blue: 0.114, alpha: 0.93).cgColor
            tint.layer?.cornerRadius = r; tint.layer?.masksToBounds = true
            bg.addSubview(tint)
            container.wantsLayer = true
            container.layer?.backgroundColor = nil
            container.frame = frame
            bg.addSubview(container)
            contentView = bg
        }
        invalidateShadow()
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

    /// Shows the bar with a sample word while the colour picker is open.
    func preview() {
        guard !reader.isActive else { return }
        wordView.word = "universally"; progress.stringValue = "1 / 1"
        if !shown {
            shown = true
            if !NSScreen.screens.contains(where: { $0.visibleFrame.intersects(frame) }), let scr = NSScreen.main {
                let f = scr.visibleFrame
                setFrameOrigin(NSPoint(x: f.midX - frame.width / 2, y: f.minY + 60))
            }
            alphaValue = 1; orderFrontRegardless(); invalidateShadow()
        }
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
        if let old = contentView {
            let g = NSGlassEffectView(frame: old.frame)
            contentView = NSView()
            g.contentView = old
            contentView = g
        }
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
