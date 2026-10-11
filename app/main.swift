// Save.TV Downloader – macOS-App (AppKit), Version 4
// Seitenleiste: Archiv · Programm · Geplant · Abos · Protokoll. Detailansicht, Vorschaubilder,
// Statusbadges, Kontextmenü, Toolbar, Mitteilungen, Speicherplatz, intelligenter Hintergrundlauf.
// Steuert das Python-Skript savetv_dl.py. Build: ./build.sh

import AppKit
import Foundation
import UserNotifications

// MARK: - Hilfen

let accent = NSColor(srgbRed: 0.12, green: 0.47, blue: 0.86, alpha: 1)

func symbol(_ name: String, _ size: CGFloat = 14, weight: NSFont.Weight = .regular) -> NSImage? {
    guard let img = NSImage(systemSymbolName: name, accessibilityDescription: nil) else { return nil }
    return img.withSymbolConfiguration(NSImage.SymbolConfiguration(pointSize: size, weight: weight)) ?? img
}

func button(_ title: String, _ sym: String?, target: AnyObject?, action: Selector) -> NSButton {
    let b = NSButton(title: title, target: target, action: action)
    b.bezelStyle = .rounded
    if let s = sym, let img = symbol(s) { b.image = img; b.imagePosition = .imageLeading }
    return b
}

func germanDate(_ s: String) -> String {
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"; f.locale = Locale(identifier: "de_DE")
    guard let d = f.date(from: s) else { return s }
    let o = DateFormatter(); o.dateFormat = "EE dd.MM. HH:mm"; o.locale = Locale(identifier: "de_DE")
    return o.string(from: d)
}

func parseDate(_ s: String) -> Date? {
    let f = DateFormatter(); f.dateFormat = "yyyy-MM-dd HH:mm"; f.locale = Locale(identifier: "de_DE"); return f.date(from: s)
}

func humanSize(_ bytes: Double) -> String {
    if bytes >= 1e9 { return String(format: "%.1f GB", bytes / 1e9) }
    return String(format: "%.0f MB", bytes / 1e6)
}

// Bildcache
final class ImageCache {
    static let shared = ImageCache()
    private let cache = NSCache<NSString, NSImage>()
    private var loading = Set<String>()
    func image(_ urlString: String, completion: @escaping (NSImage) -> Void) -> NSImage? {
        guard !urlString.isEmpty else { return nil }
        let u = urlString.hasPrefix("//") ? "https:" + urlString : urlString
        if let img = cache.object(forKey: u as NSString) { return img }
        guard !loading.contains(u), let url = URL(string: u) else { return nil }
        loading.insert(u)
        URLSession.shared.dataTask(with: url) { data, _, _ in
            DispatchQueue.main.async {
                self.loading.remove(u)
                if let d = data, let img = NSImage(data: d) {
                    self.cache.setObject(img, forKey: u as NSString)
                    completion(img)
                }
            }
        }.resume()
        return nil
    }
}

// Badge
final class BadgeView: NSView {
    let label = NSTextField(labelWithString: "")
    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.cornerRadius = 9
        label.font = NSFont.systemFont(ofSize: 10.5, weight: .semibold)
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false
        addSubview(label)
        NSLayoutConstraint.activate([
            label.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 8),
            label.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -8),
            label.centerYAnchor.constraint(equalTo: centerYAnchor),
            heightAnchor.constraint(equalToConstant: 18),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    func set(_ text: String, _ color: NSColor) {
        label.stringValue = text
        label.textColor = color
        layer?.backgroundColor = color.withAlphaComponent(0.16).cgColor
        isHidden = text.isEmpty
    }
}

// Tabellenzelle mit Bild + zwei Zeilen
final class RichCell: NSTableCellView {
    let thumb = NSImageView()
    let title = NSTextField(labelWithString: "")
    let sub = NSTextField(labelWithString: "")
    var imageURL = ""
    override init(frame: NSRect) {
        super.init(frame: frame)
        thumb.imageScaling = .scaleProportionallyUpOrDown
        thumb.wantsLayer = true; thumb.layer?.cornerRadius = 4; thumb.layer?.masksToBounds = true
        thumb.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        title.font = NSFont.systemFont(ofSize: 13, weight: .medium); title.lineBreakMode = .byTruncatingTail
        sub.font = NSFont.systemFont(ofSize: 11); sub.textColor = .secondaryLabelColor; sub.lineBreakMode = .byTruncatingTail
        for v in [thumb, title, sub] { v.translatesAutoresizingMaskIntoConstraints = false; addSubview(v) }
        NSLayoutConstraint.activate([
            thumb.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 4),
            thumb.centerYAnchor.constraint(equalTo: centerYAnchor),
            thumb.widthAnchor.constraint(equalToConstant: 64), thumb.heightAnchor.constraint(equalToConstant: 36),
            title.leadingAnchor.constraint(equalTo: thumb.trailingAnchor, constant: 8),
            title.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -4),
            title.topAnchor.constraint(equalTo: topAnchor, constant: 5),
            sub.leadingAnchor.constraint(equalTo: title.leadingAnchor),
            sub.trailingAnchor.constraint(equalTo: title.trailingAnchor),
            sub.topAnchor.constraint(equalTo: title.bottomAnchor, constant: 1),
        ])
    }
    required init?(coder: NSCoder) { fatalError() }
    func setImage(_ url: String) {
        imageURL = url
        thumb.image = ImageCache.shared.image(url) { [weak self] img in
            if self?.imageURL == url { self?.thumb.image = img }
        }
    }
}

func labelCell(_ tableView: NSTableView, _ colId: String) -> NSTableCellView {
    let id = NSUserInterfaceItemIdentifier("cell_" + colId)
    if let c = tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView { return c }
    let c = NSTableCellView(); c.identifier = id
    let tf = NSTextField(labelWithString: ""); tf.lineBreakMode = .byTruncatingTail
    tf.translatesAutoresizingMaskIntoConstraints = false
    c.textField = tf; c.addSubview(tf)
    NSLayoutConstraint.activate([
        tf.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 4),
        tf.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -4),
        tf.centerYAnchor.constraint(equalTo: c.centerYAnchor),
    ])
    return c
}

func badgeCell(_ tableView: NSTableView, _ colId: String) -> (NSTableCellView, BadgeView) {
    let id = NSUserInterfaceItemIdentifier("badge_" + colId)
    if let c = tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView, let b = c.subviews.first as? BadgeView { return (c, b) }
    let c = NSTableCellView(); c.identifier = id
    let b = BadgeView(frame: .zero); b.translatesAutoresizingMaskIntoConstraints = false
    c.addSubview(b)
    NSLayoutConstraint.activate([b.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 4), b.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                                 b.trailingAnchor.constraint(lessThanOrEqualTo: c.trailingAnchor, constant: -4)])
    return (c, b)
}

func richCell(_ tableView: NSTableView) -> RichCell {
    let id = NSUserInterfaceItemIdentifier("rich")
    if let c = tableView.makeView(withIdentifier: id, owner: nil) as? RichCell { return c }
    let c = RichCell(frame: .zero); c.identifier = id; return c
}

func makeTable(_ cols: [(String, String, CGFloat)], rowHeight: CGFloat = 24) -> (NSTableView, NSScrollView) {
    let table = NSTableView()
    for (id, name, width) in cols {
        let c = NSTableColumn(identifier: NSUserInterfaceItemIdentifier(id))
        c.title = name; c.width = width; c.minWidth = 40
        c.resizingMask = (id == "title") ? [.autoresizingMask, .userResizingMask] : .userResizingMask
        table.addTableColumn(c)
    }
    table.usesAlternatingRowBackgroundColors = true
    table.rowHeight = rowHeight
    table.columnAutoresizingStyle = .lastColumnOnlyAutoresizingStyle
    table.allowsMultipleSelection = true
    table.style = .inset
    let scroll = NSScrollView()
    scroll.documentView = table; scroll.hasVerticalScroller = true; scroll.borderType = .noBorder
    scroll.translatesAutoresizingMaskIntoConstraints = false
    return (table, scroll)
}

// MARK: - Modelle

struct Recording {
    let id: Int; let title: String; let subtitle: String; let episode: String; let station: String
    let start: String; let status: String; let stateMsg: String; let adfree: Bool; let formats: [String]
    let markedDownloaded: Bool; let done: Bool; let file: String?; let failed: String?
    let image: String; let stationImage: String; let daysLeft: Int
    init(_ d: [String: Any]) {
        id = d["id"] as? Int ?? 0; title = d["title"] as? String ?? ""; subtitle = d["subtitle"] as? String ?? ""
        episode = d["episode"] as? String ?? ""; station = d["station"] as? String ?? ""; start = d["start"] as? String ?? ""
        status = d["status"] as? String ?? ""; stateMsg = d["state_msg"] as? String ?? ""; adfree = d["adfree"] as? Bool ?? false
        formats = d["formats"] as? [String] ?? []; markedDownloaded = d["marked_downloaded"] as? Bool ?? false
        done = d["done"] as? Bool ?? false; file = d["file"] as? String; failed = d["failed"] as? String
        image = d["image"] as? String ?? ""; stationImage = d["station_image"] as? String ?? ""; daysLeft = d["days_left"] as? Int ?? 0
    }
    var displayTitle: String { subtitle.isEmpty || subtitle == title ? title : title + " – " + subtitle }
    var isReady: Bool { !done && status == "OK" && adfree && !markedDownloaded }
    var badge: (String, NSColor) {
        if done { return file != nil ? ("Geladen", .systemBlue) : ("Übersprungen", .systemGray) }
        if status != "OK" { return ("Wartet", .systemGray) }
        if failed != nil { return ("Fehler", .systemRed) }
        if markedDownloaded { return ("Schon geladen", .systemGray) }
        return adfree ? ("Bereit", .systemGreen) : ("Schnittliste fehlt", .systemOrange) }
    var detailText: String {
        var l: [String] = []
        if !stateMsg.isEmpty { l.append(stateMsg) }
        if let f = failed { l.append("Letzter Fehler: " + f) }
        if !formats.isEmpty { l.append("Formate: " + formats.joined(separator: ", ")) }
        l.append(adfree ? "Werbefreie Fassung verfügbar" : "Schnittliste noch nicht verfügbar")
        if daysLeft > 0 { l.append("Noch \(daysLeft) Tage bei Save.TV") }
        if let f = file { l.append("Datei: " + f) }
        return l.joined(separator: "\n")
    }
}

struct Telecast {
    let id: Int; let title: String; let subtitle: String; let episode: String; let station: String
    let start: String; let end: String; let category: String; let description: String; var recorded: Bool; let highlight: Bool
    let image: String; let stationImage: String
    init(_ d: [String: Any]) {
        id = d["id"] as? Int ?? 0; title = d["title"] as? String ?? ""; subtitle = d["subtitle"] as? String ?? ""
        episode = d["episode"] as? String ?? ""; station = d["station"] as? String ?? ""; start = d["start"] as? String ?? ""
        end = d["end"] as? String ?? ""; category = d["category"] as? String ?? ""; description = d["description"] as? String ?? ""
        recorded = d["recorded"] as? Bool ?? false; highlight = d["highlight"] as? Bool ?? false
        image = d["image"] as? String ?? ""; stationImage = d["station_image"] as? String ?? ""
    }
    var displayTitle: String { subtitle.isEmpty ? title : title + " – " + subtitle }
}

struct Planned {
    let id: Int; let title: String; let subtitle: String; let episode: String; let station: String; let start: String; let end: String; let stateMsg: String
    init(_ d: [String: Any]) {
        id = d["id"] as? Int ?? 0; title = d["title"] as? String ?? ""; subtitle = d["subtitle"] as? String ?? ""
        episode = d["episode"] as? String ?? ""; station = d["station"] as? String ?? ""; start = d["start"] as? String ?? ""
        end = d["end"] as? String ?? ""; stateMsg = d["state_msg"] as? String ?? ""
    }
    var displayTitle: String { subtitle.isEmpty || subtitle == title ? title : title + " – " + subtitle }
    var endDate: Date? {
        guard let s = parseDate(start), !end.isEmpty else { return nil }
        let day = String(start.prefix(10))
        guard var e = parseDate(day + " " + end) else { return nil }
        if e < s { e = e.addingTimeInterval(86400) }
        return e
    }
}

struct Channel {
    let id: Int; let name: String; let type: Int; let count: Int
    init(_ d: [String: Any]) { id = d["id"] as? Int ?? 0; name = d["name"] as? String ?? ""; type = d["type"] as? Int ?? 0; count = d["count"] as? Int ?? 0 }
    var typeText: String { type == 3 ? "Titel-Abo" : (type == 4 ? "Sendungs-Abo" : (type == 1 ? "Sender/Zeitraum" : "Typ \(type)")) }
}

// MARK: - Backend

final class Backend {
    static let shared = Backend()
    let confDir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".savetv-dl")
    var configURL: URL { confDir.appendingPathComponent("config.json") }
    var logURL: URL { confDir.appendingPathComponent("savetv-dl.log") }
    var isConfigured: Bool { FileManager.default.fileExists(atPath: configURL.path) }

    /// Skript: bevorzugt eine neuere Datei neben der App (../savetv_dl.py) oder in ~/.savetv-dl, sonst die eingebettete.
    var scriptPath: String {
        let bundled = Bundle.main.path(forResource: "savetv_dl", ofType: "py") ?? ""
        var candidates = [confDir.appendingPathComponent("savetv_dl.py").path]
        let appDir = Bundle.main.bundleURL.deletingLastPathComponent()
        candidates.append(appDir.appendingPathComponent("savetv_dl.py").path)
        candidates.append(appDir.deletingLastPathComponent().appendingPathComponent("savetv_dl.py").path)
        let fm = FileManager.default
        let bundledDate = (try? fm.attributesOfItem(atPath: bundled)[.modificationDate] as? Date) ?? .distantPast
        for c in candidates where fm.fileExists(atPath: c) {
            let d = (try? fm.attributesOfItem(atPath: c)[.modificationDate] as? Date) ?? .distantPast
            if d > bundledDate { return c }
        }
        return bundled
    }

    func loadConfig() -> [String: Any] {
        if let d = try? Data(contentsOf: configURL), let j = try? JSONSerialization.jsonObject(with: d) as? [String: Any] { return j }
        return [:]
    }
    func saveConfig(_ cfg: [String: Any]) throws {
        try FileManager.default.createDirectory(at: confDir, withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: cfg, options: [.prettyPrinted, .sortedKeys])
        try data.write(to: configURL)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: configURL.path)
    }
    var targetDir: String {
        let t = (loadConfig()["target_dir"] as? String) ?? "~/Movies/Save.TV"
        return (t as NSString).expandingTildeInPath
    }
    var minAgeMinutes: Int { loadConfig()["min_age_minutes"] as? Int ?? 30 }

    func freeSpace() -> (free: Double, total: Double)? {
        let path = FileManager.default.fileExists(atPath: targetDir) ? targetDir : NSHomeDirectory()
        guard let a = try? FileManager.default.attributesOfFileSystem(forPath: path),
              let free = a[.systemFreeSize] as? NSNumber, let total = a[.systemSize] as? NSNumber else { return nil }
        return (free.doubleValue, total.doubleValue)
    }

    private func security(_ args: [String]) -> Bool {
        let p = Process(); p.executableURL = URL(fileURLWithPath: "/usr/bin/security"); p.arguments = args
        p.standardOutput = Pipe(); p.standardError = Pipe()
        do { try p.run(); p.waitUntilExit(); return p.terminationStatus == 0 } catch { return false }
    }
    func keychainSet(user: String, password: String) -> Bool {
        security(["add-generic-password", "-U", "-s", "savetv-dl", "-a", user, "-w", password, "-l", "Save.TV Downloader"])
    }
    func keychainHas(user: String) -> Bool { security(["find-generic-password", "-s", "savetv-dl", "-a", user]) }

    @discardableResult
    func run(_ args: [String], progress: ((String) -> Void)? = nil, timeout: TimeInterval = 180,
             completion: @escaping (String, String, Int32) -> Void) -> Process? {
        let script = scriptPath
        guard !script.isEmpty else { completion("", "savetv_dl.py nicht gefunden.", 1); return nil }
        let p = Process()
        if progress == nil {   // Abfragen dürfen nicht ewig hängen
            DispatchQueue.main.asyncAfter(deadline: .now() + timeout) { if p.isRunning { p.terminate() } }
        }
        p.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
        p.arguments = [script] + args
        var env = ProcessInfo.processInfo.environment
        env["PYTHONIOENCODING"] = "utf-8"; env["LANG"] = "de_DE.UTF-8"; env["PYTHONUNBUFFERED"] = "1"
        p.environment = env
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err
        var collected = ""
        let lock = NSLock()
        if progress != nil {
            var buffer = ""
            out.fileHandleForReading.readabilityHandler = { h in
                let d = h.availableData
                guard !d.isEmpty, let s = String(data: d, encoding: .utf8) else { return }
                lock.lock(); collected += s; lock.unlock()
                buffer += s
                while let r = buffer.range(of: "\n") {
                    let line = String(buffer[buffer.startIndex..<r.lowerBound])
                    buffer = String(buffer[r.upperBound...])
                    DispatchQueue.main.async { progress?(line) }
                }
            }
        }
        DispatchQueue.global(qos: .userInitiated).async {
            do { try p.run() } catch {
                DispatchQueue.main.async { completion("", "Start fehlgeschlagen: \(error)", 1) }; return
            }
            var o = ""
            if progress == nil { o = String(data: out.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? "" }
            let e = String(data: err.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            p.waitUntilExit()
            if progress != nil {
                out.fileHandleForReading.readabilityHandler = nil
                let rest = out.fileHandleForReading.readDataToEndOfFile()
                lock.lock(); o = collected + (String(data: rest, encoding: .utf8) ?? ""); lock.unlock()
            }
            DispatchQueue.main.async { completion(o, e, p.terminationStatus) }
        }
        return p
    }

    func json(_ s: String) -> [String: Any]? {
        guard let i = s.firstIndex(of: "{"), let data = String(s[i...]).data(using: .utf8) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }
    /// Lesbare Fehlerbeschreibung aus Skriptausgabe/Exit-Code.
    func describeError(_ out: String, _ err: String, _ code: Int32) -> String {
        if let j = json(out), let e = j["error"] as? String {
            if e == "login" { return "Anmeldung bei Save.TV fehlgeschlagen. Bitte Zugangsdaten prüfen." }
            return j["message"] as? String ?? e
        }
        if code == 15 || code == -15 { return "Zeitüberschreitung – Save.TV hat nicht rechtzeitig geantwortet." }
        let lines = err.split(separator: "\n").map(String.init).filter { $0.contains("ERROR") || $0.contains("Error") || $0.contains("Traceback") || $0.contains("fehlgeschlagen") }
        if let l = lines.last { return l }
        return err.isEmpty ? "Unbekannter Fehler (Exit \(code))." : String(err.suffix(300))
    }
}

// MARK: - Detailansicht

final class DetailPane: NSView {
    let image = NSImageView()
    let stationImg = NSImageView()
    let title = NSTextField(wrappingLabelWithString: "")
    let meta = NSTextField(wrappingLabelWithString: "")
    let body = NSTextView()
    let buttons = NSStackView()
    let placeholder = NSTextField(labelWithString: "Keine Auswahl")
    private var imageURL = ""

    override init(frame: NSRect) {
        super.init(frame: frame)
        wantsLayer = true
        layer?.backgroundColor = NSColor.controlBackgroundColor.withAlphaComponent(0.6).cgColor
        layer?.cornerRadius = 8
        image.imageScaling = .scaleProportionallyUpOrDown
        image.wantsLayer = true; image.layer?.cornerRadius = 6; image.layer?.masksToBounds = true
        image.layer?.backgroundColor = NSColor.quaternaryLabelColor.cgColor
        stationImg.imageScaling = .scaleProportionallyDown
        title.font = NSFont.systemFont(ofSize: 15, weight: .semibold)
        title.maximumNumberOfLines = 3
        meta.font = NSFont.systemFont(ofSize: 11.5); meta.textColor = .secondaryLabelColor
        body.isEditable = false; body.font = NSFont.systemFont(ofSize: 12); body.drawsBackground = false
        body.textContainerInset = NSSize(width: 0, height: 4)
        body.isVerticallyResizable = true; body.autoresizingMask = [.width]; body.textContainer?.widthTracksTextView = true
        let scroll = NSScrollView(); scroll.documentView = body; scroll.hasVerticalScroller = true; scroll.borderType = .noBorder; scroll.drawsBackground = false
        buttons.orientation = .vertical; buttons.alignment = .leading; buttons.spacing = 6
        let stack = NSStackView(views: [image, title, meta, scroll, buttons])
        stack.orientation = .vertical; stack.alignment = .leading; stack.spacing = 8
        stack.edgeInsets = NSEdgeInsets(top: 12, left: 12, bottom: 12, right: 12)
        stack.translatesAutoresizingMaskIntoConstraints = false
        placeholder.textColor = .tertiaryLabelColor; placeholder.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack); addSubview(placeholder)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: topAnchor), stack.leadingAnchor.constraint(equalTo: leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor), stack.bottomAnchor.constraint(equalTo: bottomAnchor),
            image.heightAnchor.constraint(equalTo: image.widthAnchor, multiplier: 9.0 / 16.0),
            image.widthAnchor.constraint(equalTo: stack.widthAnchor, constant: -24),
            title.widthAnchor.constraint(equalTo: image.widthAnchor), meta.widthAnchor.constraint(equalTo: image.widthAnchor),
            scroll.widthAnchor.constraint(equalTo: image.widthAnchor),
            placeholder.centerXAnchor.constraint(equalTo: centerXAnchor), placeholder.centerYAnchor.constraint(equalTo: centerYAnchor),
            widthAnchor.constraint(equalToConstant: 280),
        ])
        clear()
    }
    required init?(coder: NSCoder) { fatalError() }

    func clear() {
        placeholder.isHidden = false
        for v in [image, title, meta, body.enclosingScrollView, buttons] { v?.isHidden = true }
    }
    func show(imageURL url: String, title t: String, meta m: String, text: String, actions: [NSButton]) {
        placeholder.isHidden = true
        for v in [image, title, meta, body.enclosingScrollView, buttons] { v?.isHidden = false }
        imageURL = url
        image.image = ImageCache.shared.image(url) { [weak self] img in if self?.imageURL == url { self?.image.image = img } }
        if url.isEmpty { image.image = symbol("tv", 40, weight: .light) }
        title.stringValue = t; meta.stringValue = m; body.string = text
        for v in buttons.arrangedSubviews { buttons.removeArrangedSubview(v); v.removeFromSuperview() }
        for b in actions { buttons.addArrangedSubview(b) }
    }
}

// MARK: - Hauptfenster

final class MainWindowController: NSWindowController, NSTableViewDataSource, NSTableViewDelegate, NSSearchFieldDelegate, NSToolbarDelegate, NSMenuDelegate {
    private var records: [Recording] = []
    private var filteredRecords: [Recording] = []
    private var telecasts: [Telecast] = []
    var planned: [Planned] = []
    private var channels: [Channel] = []
    private var channelUse = (0, 0)

    private let sidebar = NSTableView()
    private let sections: [(String, String)] = [("Archiv", "tray.full"), ("Programm", "tv"), ("Geplant", "calendar.badge.clock"), ("Abos", "star.circle"), ("Protokoll", "doc.text")]
    private let pages = NSTabView()

    private var archiveTable: NSTableView!
    private let archiveFilter = NSSearchField()
    private let archiveDetail = DetailPane(frame: .zero)
    private var loadSelButton: NSButton!
    private let archiveMenu = NSMenu()

    private var epgTable: NSTableView!
    private let epgMode = NSSegmentedControl(labels: ["Jetzt", "Gleich", "20:15", "22:15", "Highlights", "Genres", "Suche"], trackingMode: .selectOne, target: nil, action: nil)
    private let stationPopup = NSPopUpButton()
    private var stations: [(Int, String)] = []
    private let genrePopup = NSPopUpButton()
    private let subgenrePopup = NSPopUpButton()
    private var categories: [[String: Any]] = []
    private let epgSearch = NSSearchField()
    private let epgDays = NSPopUpButton()
    private let epgAllText = NSButton(checkboxWithTitle: "in Beschreibungen", target: nil, action: nil)
    private let epgDetail = DetailPane(frame: .zero)
    private let epgCount = NSTextField(labelWithString: "")
    private var epgRecordButton: NSButton!

    private var plannedTable: NSTableView!
    private var cancelButton: NSButton!

    private var channelTable: NSTableView!
    private var channelDeleteButton: NSButton!
    private let channelInfo = NSTextField(labelWithString: "")

    private let logView = NSTextView()

    private let statusLabel = NSTextField(labelWithString: "Bereit")
    private let spaceLabel = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private let progressBar = NSProgressIndicator()
    private var cancelDLButton: NSButton!
    private var currentProcess: Process?
    private var currentDownloadId = 0
    private var progressText: [Int: String] = [:]
    private var active: [Int: (label: String, pct: Double, done: Double, total: Double, speed: Double)] = [:]
    private func updateDownloadStatus() {
        let items = active.values
        guard !items.isEmpty else { return }
        let done = items.reduce(0.0) { $0 + $1.done }, total = items.reduce(0.0) { $0 + $1.total }, speed = items.reduce(0.0) { $0 + $1.speed }
        let pct = total > 0 ? done / total * 100 : -1
        if pct >= 0 { progressBar.isIndeterminate = false; progressBar.doubleValue = pct } else { progressBar.isIndeterminate = true }
        var rest = ""
        if speed > 0 && total > done { let s = Int((total - done) / speed); rest = s >= 60 ? " · noch \(s / 60) min" : " · noch \(s) s" }
        let names = items.map { $0.label }.prefix(2).joined(separator: ", ") + (items.count > 2 ? " …" : "")
        setStatus("\(items.count) Download\(items.count == 1 ? "" : "s"): \(names) – \(humanSize(done))\(total > 0 ? " von " + humanSize(total) : "")\(pct >= 0 ? " (\(Int(pct)) %)" : "") · \(humanSize(speed))/s\(rest)")
    }

    var busy = false { didSet { updateBusy() } }
    var onRunFinished: ((Int, Int32, String) -> Void)?
    var onPlannedLoaded: (() -> Void)?
    private var queue: [() -> Void] = []
    /// Führt op sofort aus oder stellt sie hinten an, wenn gerade etwas läuft.
    private func enqueue(_ op: @escaping () -> Void) {
        if busy { queue.append(op); setStatus("Warte … (\(queue.count) in Warteschlange)") } else { op() }
    }
    private func drainQueue() {
        guard !busy, !queue.isEmpty else { return }
        let op = queue.removeFirst()
        DispatchQueue.main.async { op() }
    }
    var lastRunText = "" { didSet { updateSpace() } }

    init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1180, height: 700),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                         backing: .buffered, defer: false)
        w.title = "Save.TV Downloader"
        w.minSize = NSSize(width: 980, height: 520)
        w.center(); w.isReleasedWhenClosed = false
        w.setFrameAutosaveName("MainWindow4")
        w.toolbarStyle = .unified
        super.init(window: w)
        let tb = NSToolbar(identifier: "main"); tb.delegate = self; tb.displayMode = .iconAndLabel
        w.toolbar = tb
        buildUI()
    }
    required init?(coder: NSCoder) { fatalError() }

    // MARK: Toolbar
    private let tbRun = NSToolbarItem.Identifier("run"), tbRefresh = NSToolbarItem.Identifier("refresh"), tbSettings = NSToolbarItem.Identifier("settings"), tbFolder = NSToolbarItem.Identifier("folder")
    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.flexibleSpace, tbRefresh, tbFolder, tbRun, tbSettings] }
    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] { [.flexibleSpace, .space, tbRefresh, tbFolder, tbRun, tbSettings] }
    func toolbar(_ toolbar: NSToolbar, itemForItemIdentifier id: NSToolbarItem.Identifier, willBeInsertedIntoToolbar flag: Bool) -> NSToolbarItem? {
        let item = NSToolbarItem(itemIdentifier: id)
        switch id {
        case tbRun: item.label = "Prüfen & laden"; item.image = symbol("arrow.down.circle.fill", 16); item.action = #selector(runNow)
        case tbRefresh: item.label = "Aktualisieren"; item.image = symbol("arrow.clockwise", 16); item.action = #selector(refreshCurrent)
        case tbFolder: item.label = "Zielordner"; item.image = symbol("folder", 16); item.action = #selector(openTarget)
        case tbSettings: item.label = "Einstellungen"; item.image = symbol("gearshape", 16); item.action = #selector(AppDelegate.showSettings)
        default: return nil
        }
        item.target = (id == tbSettings) ? nil : self
        item.isBordered = true
        return item
    }

    // MARK: Aufbau
    private func buildUI() {
        guard let content = window?.contentView else { return }
        let col = NSTableColumn(identifier: NSUserInterfaceItemIdentifier("side"))
        sidebar.addTableColumn(col)
        sidebar.headerView = nil; sidebar.rowHeight = 30
        sidebar.style = .sourceList
        sidebar.dataSource = self; sidebar.delegate = self
        sidebar.allowsEmptySelection = false; sidebar.backgroundColor = .clear
        let sideScroll = NSScrollView(); sideScroll.documentView = sidebar; sideScroll.drawsBackground = false
        sideScroll.translatesAutoresizingMaskIntoConstraints = false
        let sideBox = NSVisualEffectView(); sideBox.material = .sidebar; sideBox.blendingMode = .behindWindow
        sideBox.translatesAutoresizingMaskIntoConstraints = false
        sideBox.addSubview(sideScroll)
        NSLayoutConstraint.activate([
            sideScroll.topAnchor.constraint(equalTo: sideBox.topAnchor, constant: 52),
            sideScroll.leadingAnchor.constraint(equalTo: sideBox.leadingAnchor, constant: 8),
            sideScroll.trailingAnchor.constraint(equalTo: sideBox.trailingAnchor, constant: -8),
            sideScroll.bottomAnchor.constraint(equalTo: sideBox.bottomAnchor),
        ])

        pages.tabViewType = .noTabsNoBorder
        pages.translatesAutoresizingMaskIntoConstraints = false
        pages.addTabViewItem(item("archive", buildArchivePage()))
        pages.addTabViewItem(item("epg", buildEpgPage()))
        pages.addTabViewItem(item("planned", buildPlannedPage()))
        pages.addTabViewItem(item("channels", buildChannelsPage()))
        pages.addTabViewItem(item("log", buildLogPage()))

        spinner.style = .spinning; spinner.controlSize = .small; spinner.isDisplayedWhenStopped = false
        progressBar.style = .bar; progressBar.isIndeterminate = false; progressBar.minValue = 0; progressBar.maxValue = 100; progressBar.isHidden = true
        progressBar.widthAnchor.constraint(equalToConstant: 180).isActive = true
        statusLabel.textColor = .secondaryLabelColor; statusLabel.lineBreakMode = .byTruncatingTail
        statusLabel.setContentHuggingPriority(.defaultLow, for: .horizontal)
        statusLabel.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        spaceLabel.textColor = .tertiaryLabelColor; spaceLabel.font = NSFont.systemFont(ofSize: 11)
        cancelDLButton = button("Abbrechen", "xmark.circle", target: self, action: #selector(cancelRun)); cancelDLButton.isHidden = true
        let status = NSStackView(views: [spinner, progressBar, statusLabel, cancelDLButton, spaceLabel])
        status.orientation = .horizontal; status.spacing = 10; status.alignment = .centerY
        status.edgeInsets = NSEdgeInsets(top: 6, left: 16, bottom: 8, right: 16)
        status.translatesAutoresizingMaskIntoConstraints = false
        let line = NSBox(); line.boxType = .separator; line.translatesAutoresizingMaskIntoConstraints = false

        content.addSubview(sideBox); content.addSubview(pages); content.addSubview(line); content.addSubview(status)
        NSLayoutConstraint.activate([
            sideBox.topAnchor.constraint(equalTo: content.topAnchor), sideBox.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            sideBox.bottomAnchor.constraint(equalTo: content.bottomAnchor), sideBox.widthAnchor.constraint(equalToConstant: 180),
            pages.topAnchor.constraint(equalTo: content.topAnchor, constant: 52),
            pages.leadingAnchor.constraint(equalTo: sideBox.trailingAnchor), pages.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            line.topAnchor.constraint(equalTo: pages.bottomAnchor), line.leadingAnchor.constraint(equalTo: sideBox.trailingAnchor),
            line.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            status.topAnchor.constraint(equalTo: line.bottomAnchor), status.leadingAnchor.constraint(equalTo: sideBox.trailingAnchor),
            status.trailingAnchor.constraint(equalTo: content.trailingAnchor), status.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        sidebar.selectRowIndexes(IndexSet(integer: 0), byExtendingSelection: false)
        updateSpace()
    }

    private func item(_ id: String, _ view: NSView) -> NSTabViewItem { let it = NSTabViewItem(identifier: id); it.view = view; return it }

    private func header(_ title: String, _ subtitle: String, _ controls: [NSView]) -> NSView {
        let t = NSTextField(labelWithString: title); t.font = NSFont.systemFont(ofSize: 22, weight: .bold)
        let s = NSTextField(labelWithString: subtitle); s.textColor = .secondaryLabelColor; s.font = NSFont.systemFont(ofSize: 12)
        let titles = NSStackView(views: [t, s]); titles.orientation = .vertical; titles.alignment = .leading; titles.spacing = 2
        let spacer = NSView(); spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        let row = NSStackView(views: [titles, spacer] + controls)
        row.orientation = .horizontal; row.alignment = .centerY; row.spacing = 8
        row.edgeInsets = NSEdgeInsets(top: 4, left: 20, bottom: 10, right: 20)
        row.translatesAutoresizingMaskIntoConstraints = false
        return row
    }

    private func page(_ head: NSView, _ body: NSView, _ footer: NSView? = nil) -> NSView {
        let v = NSView()
        v.addSubview(head); v.addSubview(body)
        var c = [head.topAnchor.constraint(equalTo: v.topAnchor), head.leadingAnchor.constraint(equalTo: v.leadingAnchor),
                 head.trailingAnchor.constraint(equalTo: v.trailingAnchor), body.topAnchor.constraint(equalTo: head.bottomAnchor),
                 body.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 20), body.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -20)]
        if let f = footer {
            v.addSubview(f)
            c += [f.topAnchor.constraint(equalTo: body.bottomAnchor, constant: 6), f.leadingAnchor.constraint(equalTo: v.leadingAnchor, constant: 20),
                  f.trailingAnchor.constraint(equalTo: v.trailingAnchor, constant: -20), f.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -10)]
        } else { c.append(body.bottomAnchor.constraint(equalTo: v.bottomAnchor, constant: -12)) }
        NSLayoutConstraint.activate(c)
        return v
    }

    private func withDetail(_ scroll: NSView, _ detail: NSView) -> NSView {
        let row = NSStackView(views: [scroll, detail])
        row.orientation = .horizontal; row.spacing = 12; row.alignment = .top
        row.translatesAutoresizingMaskIntoConstraints = false
        detail.translatesAutoresizingMaskIntoConstraints = false
        detail.heightAnchor.constraint(equalTo: row.heightAnchor).isActive = true
        scroll.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        return row
    }

    private func buildArchivePage() -> NSView {
        loadSelButton = button("Ausgewählte laden", "square.and.arrow.down", target: self, action: #selector(loadSelected)); loadSelButton.isEnabled = false
        archiveFilter.placeholderString = "Filtern"; archiveFilter.delegate = self
        archiveFilter.widthAnchor.constraint(equalToConstant: 170).isActive = true
        let head = header("Archiv", "Aufgenommene Sendungen bei Save.TV", [archiveFilter, loadSelButton])
        let (t, scroll) = makeTable([("title", "Sendung", 360), ("station", "Sender", 80), ("start", "Datum", 120), ("adfree", "Werbefrei", 70), ("state", "Status", 150)], rowHeight: 46)
        archiveTable = t; t.dataSource = self; t.delegate = self
        t.doubleAction = #selector(archiveDoubleClick); t.target = self
        archiveMenu.delegate = self; t.menu = archiveMenu
        let hint = NSTextField(labelWithString: "Doppelklick: geladene Aufnahme abspielen, sonst sofort laden. Rechtsklick für weitere Aktionen. Automatisch werden nur werbefreie Fassungen geladen.")
        hint.font = NSFont.systemFont(ofSize: 11); hint.textColor = .tertiaryLabelColor; hint.translatesAutoresizingMaskIntoConstraints = false
        return page(head, withDetail(scroll, archiveDetail), hint)
    }

    private func buildEpgPage() -> NSView {
        epgMode.target = self; epgMode.action = #selector(epgModeChanged); epgMode.selectedSegment = 2
        epgSearch.placeholderString = "Sendung suchen"; epgSearch.target = self; epgSearch.action = #selector(searchEpg)
        epgSearch.sendsWholeSearchString = true
        epgSearch.widthAnchor.constraint(equalToConstant: 200).isActive = true
        epgDays.addItems(withTitles: ["heute+morgen", "7 Tage", "14 Tage", "28 Tage"]); epgDays.selectItem(at: 1)
        epgDays.target = self; epgDays.action = #selector(daysChanged)
        epgRecordButton = button("Aufnehmen", "record.circle", target: self, action: #selector(recordSelected)); epgRecordButton.isEnabled = false
        genrePopup.target = self; genrePopup.action = #selector(genreChanged)
        subgenrePopup.target = self; subgenrePopup.action = #selector(subgenreChanged)
        genrePopup.isHidden = true; subgenrePopup.isHidden = true
        stationPopup.addItem(withTitle: "Alle Sender"); stationPopup.target = self; stationPopup.action = #selector(stationChanged)
        let head = header("Programm", "Programmübersicht, Genres, Suche und Aufnahmen programmieren", [epgMode, stationPopup, genrePopup, subgenrePopup, epgSearch, epgDays, epgAllText, epgRecordButton])
        let (t, scroll) = makeTable([("title", "Sendung", 360), ("station", "Sender", 80), ("start", "Sendezeit", 150), ("category", "Genre", 130), ("rec", "Aufnahme", 110)], rowHeight: 46)
        epgTable = t; t.dataSource = self; t.delegate = self
        t.doubleAction = #selector(recordSelected); t.target = self
        epgCount.font = NSFont.systemFont(ofSize: 11); epgCount.textColor = .tertiaryLabelColor; epgCount.translatesAutoresizingMaskIntoConstraints = false
        epgSearch.isHidden = true; epgDays.isHidden = true; epgAllText.isHidden = true
        return page(head, withDetail(scroll, epgDetail), epgCount)
    }

    private func buildPlannedPage() -> NSView {
        cancelButton = button("Aufnahme löschen", "trash", target: self, action: #selector(cancelSelected)); cancelButton.isEnabled = false
        let head = header("Geplant", "Programmierte, noch nicht aufgenommene Sendungen", [cancelButton])
        let (t, scroll) = makeTable([("start", "Sendung", 150), ("station", "Sender", 90), ("title", "Titel", 360), ("episode", "Folge", 70), ("state", "Status", 200)])
        plannedTable = t; t.dataSource = self; t.delegate = self
        return page(head, scroll)
    }

    private func buildChannelsPage() -> NSView {
        channelDeleteButton = button("Abo löschen", "trash", target: self, action: #selector(deleteChannel)); channelDeleteButton.isEnabled = false
        let add = button("Abo anlegen…", "plus.circle", target: self, action: #selector(addChannel))
        let head = header("Abos", "Save.TV-Channels: neue Folgen werden automatisch aufgenommen und geladen", [add, channelDeleteButton])
        let (t, scroll) = makeTable([("name", "Abo", 320), ("type", "Art", 140), ("count", "Aufnahmen", 90)])
        channelTable = t; t.dataSource = self; t.delegate = self
        channelInfo.font = NSFont.systemFont(ofSize: 11); channelInfo.textColor = .tertiaryLabelColor; channelInfo.translatesAutoresizingMaskIntoConstraints = false
        return page(head, scroll, channelInfo)
    }

    private func buildLogPage() -> NSView {
        let open = button("Log-Ordner", "folder", target: self, action: #selector(openConfDir))
        let head = header("Protokoll", "Ausgaben des Download-Skripts", [open])
        logView.isEditable = false; logView.font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
        logView.autoresizingMask = [.width]; logView.textContainer?.widthTracksTextView = true; logView.isVerticallyResizable = true
        logView.minSize = NSSize(width: 0, height: 0)
        logView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        let scroll = NSScrollView(); scroll.documentView = logView; scroll.hasVerticalScroller = true; scroll.borderType = .lineBorder
        scroll.translatesAutoresizingMaskIntoConstraints = false
        return page(head, scroll)
    }

    // MARK: Zustand
    private func updateBusy() {
        loadSelButton.isEnabled = !busy && archiveTable.selectedRow >= 0
        epgRecordButton.isEnabled = !busy && epgTable.selectedRow >= 0
        cancelButton.isEnabled = !busy && plannedTable.selectedRow >= 0
        channelDeleteButton.isEnabled = !busy && channelTable.selectedRow >= 0
        if busy { spinner.startAnimation(nil) } else {
            spinner.stopAnimation(nil); progressBar.isHidden = true; cancelDLButton.isHidden = true; updateSpace()
            if let p = pendingEpg { pendingEpg = nil; DispatchQueue.main.async { self.loadEpg(p.0, label: p.1) } }
            else { drainQueue() }
        }
    }
    func setStatus(_ s: String) { statusLabel.stringValue = s }
    func updateSpace() {
        var t = ""
        if let s = Backend.shared.freeSpace() { t = "Frei: \(humanSize(s.free))" }
        if !lastRunText.isEmpty { t += (t.isEmpty ? "" : " · ") + lastRunText }
        spaceLabel.stringValue = t
    }
    func showError(_ title: String, _ out: String, _ err: String, _ code: Int32) {
        let msg = Backend.shared.describeError(out, err, code)
        setStatus(title + ": " + msg)
        appendLog(err)
        if msg.contains("Anmeldung") { alert(title, msg) }
    }
    private func guardConfigured() -> Bool {
        if Backend.shared.isConfigured { return true }
        NSApp.sendAction(#selector(AppDelegate.showWizard), to: nil, from: nil); return false
    }
    private func handleLogin(_ j: [String: Any]?) -> Bool {
        if j?["error"] as? String == "login" {
            setStatus("Login fehlgeschlagen – Zugangsdaten prüfen.")
            alert("Login bei Save.TV fehlgeschlagen", "Bitte Benutzername und Passwort in den Einstellungen prüfen."); return false
        }
        return true
    }
    private var currentSection: Int { max(0, sidebar.selectedRow) }

    @objc func refreshCurrent() {
        switch currentSection {
        case 0: refresh()
        case 1: epgModeChanged()
        case 2: refreshPlanned()
        case 3: refreshChannels()
        default: reloadLog()
        }
    }

    // MARK: Archiv
    @objc func refresh() {
        guard guardConfigured() else { return }
        if busy { enqueue { self.refresh() }; return }
        busy = true; setStatus("Lade Archivliste …")
        Backend.shared.run(["--json"]) { out, err, code in
            self.busy = false; self.reloadLog()
            guard let j = Backend.shared.json(out), j["error"] == nil || j["error"] as? String == "login" else { self.showError("Archiv", out, err, code); return }
            guard self.handleLogin(j) else { return }
            self.records = (j["records"] as? [[String: Any]] ?? []).map(Recording.init)
            self.applyFilter()
            let ready = self.records.filter { $0.isReady }.count
            self.setStatus("\(self.records.count) Aufnahmen im Archiv, \(ready) neu zum Laden bereit.")
        }
    }
    private func applyFilter() {
        let q = archiveFilter.stringValue.lowercased()
        filteredRecords = q.isEmpty ? records : records.filter { ($0.displayTitle + " " + $0.station + " " + $0.episode).lowercased().contains(q) }
        archiveTable.reloadData(); showArchiveDetail()
    }
    func controlTextDidChange(_ obj: Notification) { if (obj.object as? NSSearchField) === archiveFilter { applyFilter() } }

    private var selectedRecording: Recording? { archiveTable.selectedRow >= 0 && archiveTable.selectedRow < filteredRecords.count ? filteredRecords[archiveTable.selectedRow] : nil }

    private func localFile(_ r: Recording) -> URL? {
        guard let f = r.file else { return nil }
        let u = URL(fileURLWithPath: Backend.shared.targetDir).appendingPathComponent(f)
        return FileManager.default.fileExists(atPath: u.path) ? u : nil
    }

    private func showArchiveDetail() {
        guard let r = selectedRecording else { archiveDetail.clear(); return }
        var actions: [NSButton] = []
        if let _ = localFile(r) {
            actions.append(button("Abspielen", "play.circle", target: self, action: #selector(playSelected)))
            actions.append(button("Im Finder zeigen", "magnifyingglass", target: self, action: #selector(revealSelected)))
            actions.append(button("Erneut laden", "arrow.down.circle", target: self, action: #selector(loadSelected)))
            actions.append(button("Lokale Datei löschen", "trash", target: self, action: #selector(deleteLocalSelected)))
        } else {
            actions.append(button(r.adfree ? "Jetzt laden (werbefrei)" : "Jetzt laden (mit Werbung)", "arrow.down.circle", target: self, action: #selector(loadSelected)))
        }
        actions.append(button("Bei Save.TV löschen", "xmark.bin", target: self, action: #selector(deleteRemoteSelected)))
        archiveDetail.show(imageURL: r.image, title: r.displayTitle,
                           meta: "\(r.station) · \(germanDate(r.start))\(r.episode.isEmpty ? "" : " · " + r.episode)", text: r.detailText, actions: actions)
    }

    @objc func archiveDoubleClick() {
        guard let r = selectedRecording else { return }
        if localFile(r) != nil { playSelected() } else { loadSelected() }
    }
    @objc func playSelected() { if let r = selectedRecording, let u = localFile(r) { NSWorkspace.shared.open(u) } }
    @objc func revealSelected() { if let r = selectedRecording, let u = localFile(r) { NSWorkspace.shared.activateFileViewerSelecting([u]) } }
    @objc func deleteLocalSelected() {
        guard let r = selectedRecording, let u = localFile(r) else { return }
        let a = NSAlert(); a.messageText = "Lokale Datei in den Papierkorb legen?"; a.informativeText = u.lastPathComponent; a.alertStyle = .warning
        a.addButton(withTitle: "Papierkorb"); a.addButton(withTitle: "Abbrechen")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        try? FileManager.default.trashItem(at: u, resultingItemURL: nil)
        showArchiveDetail(); updateSpace()
    }
    @objc func deleteRemoteSelected() {
        let ids = archiveTable.selectedRowIndexes.map { filteredRecords[$0].id }
        guard !busy, !ids.isEmpty else { return }
        let a = NSAlert(); a.messageText = ids.count == 1 ? "Aufnahme bei Save.TV löschen?" : "\(ids.count) Aufnahmen bei Save.TV löschen?"
        a.informativeText = "Die Aufnahme wird aus deinem Save.TV-Archiv entfernt. Lokale Dateien bleiben erhalten."; a.alertStyle = .warning
        a.addButton(withTitle: "Löschen"); a.addButton(withTitle: "Abbrechen")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        busy = true; setStatus("Lösche bei Save.TV …")
        Backend.shared.run(ids.flatMap { ["--cancel", String($0)] }) { _, _, _ in self.busy = false; self.refresh() }
    }

    @objc func runNow() { runDownload(args: []) }
    @objc func loadSelected() {
        let ids = archiveTable.selectedRowIndexes.map { filteredRecords[$0].id }
        guard !ids.isEmpty else { return }
        runDownload(args: ids.flatMap { ["--id", String($0)] })
    }

    func runDownload(args: [String]) {
        guard guardConfigured() else { return }
        if busy { enqueue { self.runDownload(args: args) }; return }
        busy = true
        progressBar.isHidden = false; progressBar.doubleValue = 0; cancelDLButton.isHidden = false
        setStatus(args.isEmpty ? "Prüfe Save.TV-Archiv und lade neue Aufnahmen …" : "Lade ausgewählte Aufnahmen …")
        progressText = [:]; active = [:]
        currentProcess = Backend.shared.run(args, progress: { line in
            if line.hasPrefix("START ") {
                let rest = line.dropFirst(6)
                let parts = rest.split(separator: " ", maxSplits: 1).map(String.init)
                let id = Int(parts.first ?? "") ?? 0
                self.active[id] = (parts.count > 1 ? parts[1] : "Aufnahme", 0, 0, 0, 0)
                self.progressText[id] = "0 %"; self.reloadRow(id: id)
                self.updateDownloadStatus()
            } else if line.hasPrefix("PROGRESS ") {
                let p = line.split(separator: " ")
                if p.count >= 6, let pct = Double(p[1]), let done = Double(p[2]), let total = Double(p[3]), let speed = Double(p[4]), let id = Int(p[5]) {
                    let label = self.active[id]?.label ?? "Aufnahme"
                    self.active[id] = (label, pct, done, total, speed)
                    self.progressText[id] = "\(Int(max(pct, 0))) %"; self.reloadRow(id: id)
                    self.updateDownloadStatus()
                }
            } else if line.hasPrefix("DONE ") {
                let id = Int(line.dropFirst(5).trimmingCharacters(in: .whitespaces)) ?? 0
                self.active.removeValue(forKey: id)
                self.progressText[id] = "Fertig"; self.reloadRow(id: id)
                if self.active.isEmpty { self.progressBar.doubleValue = 100 } else { self.updateDownloadStatus() }
            }
        }) { out, err, code in
            self.busy = false; self.currentProcess = nil; self.progressText = [:]
            let n = out.components(separatedBy: "Fertig: ").count - 1
            self.reloadLog()
            self.active = [:]
            if code == 130 || code == 143 || code == 2 && out.contains("Abgebrochen") { self.setStatus("Abgebrochen – wird beim nächsten Lauf fortgesetzt.") }
            else if code != 0 { self.setStatus("Fehler – siehe Protokoll.") }
            else if n > 0 { self.setStatus("\(n) Aufnahme\(n == 1 ? "" : "n") geladen.") }
            else { self.setStatus("Keine neuen Aufnahmen geladen.") }
            self.onRunFinished?(n, code, out + err)
            self.refresh()
        }
    }
    private func reloadRow(id: Int) {
        if let i = filteredRecords.firstIndex(where: { $0.id == id }) {
            archiveTable.reloadData(forRowIndexes: IndexSet(integer: i), columnIndexes: IndexSet(integer: archiveTable.tableColumns.count - 1))
        }
    }
    @objc func cancelRun() { currentProcess?.interrupt(); setStatus("Breche ab …") }
    @objc func openTarget() {
        let path = Backend.shared.targetDir
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        NSWorkspace.shared.open(URL(fileURLWithPath: path))
    }
    @objc func openConfDir() { NSWorkspace.shared.open(Backend.shared.confDir) }

    @objc func runDiagnose() {
        guard guardConfigured() else { return }
        if busy { enqueue { self.runDiagnose() }; return }
        busy = true; setStatus("Diagnose läuft …")
        Backend.shared.run(["--selftest"], timeout: 300) { out, err, code in
            self.busy = false
            var lines: [String] = []
            if let j = Backend.shared.json(out), let checks = j["checks"] as? [[String: Any]] {
                for c in checks {
                    let ok = c["ok"] as? Bool ?? false
                    lines.append("\(ok ? "✅" : "❌") \(c["name"] as? String ?? "?"): \(c["detail"] as? String ?? "") (\(c["ms"] as? Int ?? 0) ms)")
                }
                lines.append(""); lines.append("Skript \(j["version"] as? String ?? "?") · Python \(j["python"] as? String ?? "?") · \(Backend.shared.scriptPath)")
            } else {
                lines.append("Diagnose konnte nicht ausgeführt werden: " + Backend.shared.describeError(out, err, code))
            }
            self.setStatus(code == 0 ? "Diagnose: alles in Ordnung." : "Diagnose: Probleme gefunden.")
            let a = NSAlert(); a.messageText = "Diagnose"; a.informativeText = lines.joined(separator: "\n")
            a.addButton(withTitle: "OK"); a.addButton(withTitle: "Protokoll öffnen")
            if a.runModal() == .alertSecondButtonReturn { self.showSection(4) }
        }
    }

    // Kontextmenü Archiv
    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let row = archiveTable.clickedRow
        if row >= 0 && !archiveTable.selectedRowIndexes.contains(row) { archiveTable.selectRowIndexes(IndexSet(integer: row), byExtendingSelection: false) }
        guard let r = selectedRecording else { return }
        if localFile(r) != nil {
            menu.addItem(NSMenuItem(title: "Abspielen", action: #selector(playSelected), keyEquivalent: ""))
            menu.addItem(NSMenuItem(title: "Im Finder zeigen", action: #selector(revealSelected), keyEquivalent: ""))
            menu.addItem(NSMenuItem(title: "Erneut laden", action: #selector(loadSelected), keyEquivalent: ""))
            menu.addItem(NSMenuItem(title: "Lokale Datei löschen", action: #selector(deleteLocalSelected), keyEquivalent: ""))
        } else {
            menu.addItem(NSMenuItem(title: "Jetzt laden", action: #selector(loadSelected), keyEquivalent: ""))
        }
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Bei Save.TV löschen", action: #selector(deleteRemoteSelected), keyEquivalent: ""))
    }

    // MARK: Programm
    private var stationArgs: [String] {
        let i = stationPopup.indexOfSelectedItem - 1
        return (i >= 0 && i < stations.count) ? ["--station", String(stations[i].0)] : []
    }
    @objc func stationChanged() { epgModeChanged() }
    private func loadStations() {
        Backend.shared.run(["--stations"]) { out, _, _ in
            guard let j = Backend.shared.json(out), let arr = j["stations"] as? [[String: Any]] else { return }
            let sel = self.stationPopup.titleOfSelectedItem
            self.stations = arr.map { ($0["id"] as? Int ?? 0, $0["name"] as? String ?? "") }
            self.stationPopup.removeAllItems(); self.stationPopup.addItem(withTitle: "Alle Sender")
            for (_, n) in self.stations { self.stationPopup.addItem(withTitle: n) }
            if let t = sel { self.stationPopup.selectItem(withTitle: t) }
        }
    }
    @objc func epgModeChanged() {
        if stations.isEmpty && Backend.shared.isConfigured { loadStations() }
        let seg = epgMode.selectedSegment
        let isSearch = seg == 6, isGenre = seg == 5
        epgSearch.isHidden = !isSearch; epgAllText.isHidden = !isSearch
        epgDays.isHidden = !(isSearch || isGenre)
        genrePopup.isHidden = !isGenre; subgenrePopup.isHidden = !isGenre
        if isSearch { window?.makeFirstResponder(epgSearch); if epgSearch.stringValue.isEmpty { return } ; searchEpg(); return }
        if isGenre { if categories.isEmpty { loadCategories() } else { loadGenre() }; return }
        let modes = ["now", "next", "prime", "late", "highlights"]
        loadEpg(["--epg", modes[seg]] + stationArgs, label: epgMode.label(forSegment: seg) ?? "")
    }
    private func loadCategories() {
        guard guardConfigured() else { return }
        if busy { enqueue { self.loadCategories() }; return }
        busy = true; setStatus("Lade Genres …")
        Backend.shared.run(["--categories"]) { out, err, code in
            self.busy = false
            guard let j = Backend.shared.json(out), let cats = j["categories"] as? [[String: Any]] else { self.setStatus("Genres konnten nicht geladen werden."); self.appendLog(err); return }
            self.categories = cats
            self.genrePopup.removeAllItems()
            for c in cats { self.genrePopup.addItem(withTitle: c["name"] as? String ?? "?") }
            self.genreChanged()
        }
    }
    @objc func genreChanged() {
        subgenrePopup.removeAllItems()
        subgenrePopup.addItem(withTitle: "Alle Subgenres")
        let i = genrePopup.indexOfSelectedItem
        if i >= 0 && i < categories.count, let subs = categories[i]["subcategories"] as? [[String: Any]] {
            for s in subs { subgenrePopup.addItem(withTitle: s["name"] as? String ?? "?") }
        }
        loadGenre()
    }
    @objc func subgenreChanged() { loadGenre() }
    @objc func daysChanged() { if epgMode.selectedSegment == 5 { loadGenre() } else if epgMode.selectedSegment == 6 { searchEpg() } }
    private func loadGenre() {
        let i = genrePopup.indexOfSelectedItem
        guard i >= 0 && i < categories.count else { return }
        let cat = categories[i]
        let catId = cat["id"] as? Int ?? 0
        var subId = 0; var label = cat["name"] as? String ?? ""
        let si = subgenrePopup.indexOfSelectedItem - 1
        if si >= 0, let subs = cat["subcategories"] as? [[String: Any]], si < subs.count {
            subId = subs[si]["id"] as? Int ?? 0; label += " › " + (subs[si]["name"] as? String ?? "")
        }
        let days = [2, 7, 14, 28][epgDays.indexOfSelectedItem]
        loadEpg(["--epg", "genre", "--category", String(catId), "--subcategory", String(subId), "--days", String(days)] + stationArgs, label: label)
    }
    @objc func searchEpg() {
        let q = epgSearch.stringValue.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return }
        if epgMode.selectedSegment != 6 { epgMode.selectedSegment = 6; epgModeChanged(); return }
        let days = [2, 7, 14, 28][epgDays.indexOfSelectedItem]
        var args = ["--epg-search", q, "--days", String(days)] + stationArgs
        if epgAllText.state == .on { args.append("--all-text") }
        loadEpg(args, label: "„\(q)“")
    }
    private var pendingEpg: ([String], String)?
    private func loadEpg(_ args: [String], label: String) {
        guard guardConfigured() else { return }
        if busy { pendingEpg = (args, label); setStatus("Warte … lade danach: \(label)"); return }
        busy = true; setStatus("Lade Programm: \(label) …")
        Backend.shared.run(args + ["--per-page", "80"]) { out, err, code in
            self.busy = false
            guard let j = Backend.shared.json(out), j["error"] == nil || j["error"] as? String == "login" else { self.showError("Programm", out, err, code); return }
            guard self.handleLogin(j) else { return }
            self.telecasts = (j["results"] as? [[String: Any]] ?? []).map(Telecast.init)
            self.epgTable.reloadData(); self.epgDetail.clear()
            let total = j["total"] as? Int ?? self.telecasts.count
            self.epgCount.stringValue = "\(self.telecasts.count) von \(total) Sendungen · Doppelklick programmiert die Aufnahme"
            self.setStatus(total == 0 ? "Keine Sendungen für \(label) gefunden." : "\(total) Sendungen: \(label).")
            if let p = self.pendingEpg { self.pendingEpg = nil; self.loadEpg(p.0, label: p.1) }
        }
    }
    private var selectedTelecast: Telecast? { epgTable.selectedRow >= 0 && epgTable.selectedRow < telecasts.count ? telecasts[epgTable.selectedRow] : nil }
    private func showEpgDetail() {
        guard let x = selectedTelecast else { epgDetail.clear(); return }
        let rec = button(x.recorded ? "Bereits programmiert" : "Aufnehmen", "record.circle", target: self, action: #selector(recordSelected)); rec.isEnabled = !x.recorded
        let abo = button("Alle Folgen aufnehmen (Abo)", "star.circle", target: self, action: #selector(addChannelFromTelecast))
        epgDetail.show(imageURL: x.image, title: x.displayTitle,
                       meta: "\(x.station) · \(germanDate(x.start))–\(x.end) · \(x.category)\(x.episode.isEmpty ? "" : " · " + x.episode)",
                       text: x.description.isEmpty ? "(keine Beschreibung)" : x.description, actions: [rec, abo])
    }

    @objc func recordSelected() {
        let rows = epgTable.selectedRowIndexes
        let ids = rows.map { telecasts[$0].id }
        guard guardConfigured(), !busy, !ids.isEmpty else { return }
        let names = rows.map { telecasts[$0].displayTitle + " (" + germanDate(telecasts[$0].start) + ")" }
        let a = NSAlert()
        a.messageText = ids.count == 1 ? "Aufnahme programmieren?" : "\(ids.count) Aufnahmen programmieren?"
        a.informativeText = names.prefix(8).joined(separator: "\n") + (names.count > 8 ? "\n…" : "")
        a.addButton(withTitle: "Aufnehmen"); a.addButton(withTitle: "Abbrechen")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        busy = true; setStatus("Programmiere Aufnahme …")
        Backend.shared.run(ids.flatMap { ["--record", String($0)] }) { out, err, code in
            self.busy = false; self.reloadLog()
            guard let j = Backend.shared.json(out), let res = j["results"] as? [[String: Any]] else { self.setStatus("Programmieren fehlgeschlagen (\(code))."); self.appendLog(err); return }
            var okCount = 0; var msgs: [String] = []
            for r in res {
                let ok = r["ok"] as? Bool ?? false
                if ok { okCount += 1 }
                if let id = r["id"] as? Int, let i = self.telecasts.firstIndex(where: { $0.id == id }) {
                    if ok { self.telecasts[i].recorded = true }
                    msgs.append(self.telecasts[i].title + ": " + (r["message"] as? String ?? (ok ? "ok" : "Fehler")))
                }
            }
            self.epgTable.reloadData(); self.showEpgDetail()
            self.setStatus("\(okCount) von \(res.count) Aufnahme\(res.count == 1 ? "" : "n") programmiert.")
            if okCount < res.count { self.alert("Nicht alle Aufnahmen programmiert", msgs.joined(separator: "\n")) }
            self.planned = []; self.refreshPlanned()
        }
    }

    // MARK: Geplant
    @objc func refreshPlanned() {
        guard guardConfigured() else { return }
        if busy { enqueue { self.refreshPlanned() }; return }
        busy = true; setStatus("Lade geplante Aufnahmen …")
        Backend.shared.run(["--planned"]) { out, err, code in
            self.busy = false
            guard let j = Backend.shared.json(out), j["error"] == nil || j["error"] as? String == "login" else { self.showError("Geplant", out, err, code); return }
            guard self.handleLogin(j) else { return }
            self.planned = (j["planned"] as? [[String: Any]] ?? []).map(Planned.init)
            self.plannedTable.reloadData()
            self.setStatus("\(self.planned.count) programmierte Aufnahme\(self.planned.count == 1 ? "" : "n").")
            self.onPlannedLoaded?()
        }
    }
    @objc func cancelSelected() {
        let rows = plannedTable.selectedRowIndexes
        let ids = rows.map { planned[$0].id }
        guard !busy, !ids.isEmpty else { return }
        let a = NSAlert(); a.messageText = ids.count == 1 ? "Programmierte Aufnahme löschen?" : "\(ids.count) programmierte Aufnahmen löschen?"
        a.informativeText = rows.map { planned[$0].displayTitle }.prefix(8).joined(separator: "\n"); a.alertStyle = .warning
        a.addButton(withTitle: "Löschen"); a.addButton(withTitle: "Abbrechen")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        busy = true; setStatus("Lösche Aufnahme …")
        Backend.shared.run(ids.flatMap { ["--cancel", String($0)] }) { _, _, _ in self.busy = false; self.reloadLog(); self.refreshPlanned() }
    }

    // MARK: Abos
    @objc func refreshChannels() {
        guard guardConfigured() else { return }
        if busy { enqueue { self.refreshChannels() }; return }
        busy = true; setStatus("Lade Abos …")
        Backend.shared.run(["--channels"]) { out, err, code in
            self.busy = false
            guard let j = Backend.shared.json(out), j["error"] == nil || j["error"] as? String == "login" else { self.showError("Abos", out, err, code); return }
            guard self.handleLogin(j) else { return }
            self.channels = (j["channels"] as? [[String: Any]] ?? []).map(Channel.init)
            self.channelUse = (j["used"] as? Int ?? self.channels.count, j["max"] as? Int ?? 0)
            self.channelTable.reloadData()
            self.channelInfo.stringValue = "\(self.channelUse.0) von \(self.channelUse.1) Abos belegt · Ein Abo nimmt automatisch alle Sendungen mit passendem Titel auf."
            self.setStatus("\(self.channels.count) Abos.")
        }
    }
    @objc func addChannel() {
        guard guardConfigured(), !busy else { return }
        let a = NSAlert(); a.messageText = "Abo anlegen"; a.informativeText = "Titel der Sendung (alle Sendungen mit diesem Titel werden automatisch aufgenommen):"
        let tf = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24)); tf.placeholderString = "z. B. Tatort"
        a.accessoryView = tf; a.addButton(withTitle: "Anlegen"); a.addButton(withTitle: "Abbrechen")
        a.window.initialFirstResponder = tf
        guard a.runModal() == .alertFirstButtonReturn else { return }
        let t = tf.stringValue.trimmingCharacters(in: .whitespaces)
        guard !t.isEmpty else { return }
        createChannel(["--channel-add", t], label: t)
    }
    @objc func addChannelFromTelecast() {
        guard let x = selectedTelecast, !busy else { return }
        let a = NSAlert(); a.messageText = "Alle Folgen von „\(x.title)“ aufnehmen?"
        a.informativeText = "Legt ein Save.TV-Abo (Channel) an. Neue Folgen werden automatisch aufgenommen und – sobald werbefrei – heruntergeladen."
        a.addButton(withTitle: "Abo anlegen"); a.addButton(withTitle: "Abbrechen")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        createChannel(["--channel-add-telecast", String(x.id), "--channel-add", x.title], label: x.title)
    }
    private func createChannel(_ args: [String], label: String) {
        busy = true; setStatus("Lege Abo „\(label)“ an …")
        Backend.shared.run(args) { out, err, code in
            self.busy = false; self.reloadLog()
            let j = Backend.shared.json(out)
            let ok = j?["ok"] as? Bool ?? false
            let msg = j?["message"] as? String ?? ""
            self.setStatus(ok ? "Abo „\(label)“ angelegt." : "Abo konnte nicht angelegt werden.")
            if !ok { self.alert("Abo nicht angelegt", msg.isEmpty ? (err.isEmpty ? "Unbekannter Fehler." : err) : msg) }
            else if !msg.isEmpty { self.notifyInfo("Abo angelegt", msg) }
            self.refreshChannels()
        }
    }
    @objc func deleteChannel() {
        guard channelTable.selectedRow >= 0, !busy else { return }
        let c = channels[channelTable.selectedRow]
        let a = NSAlert(); a.messageText = "Abo „\(c.name)“ löschen?"; a.alertStyle = .warning
        let cb = NSButton(checkboxWithTitle: "Auch bereits programmierte Aufnahmen dieses Abos löschen", target: nil, action: nil)
        a.accessoryView = cb
        a.addButton(withTitle: "Löschen"); a.addButton(withTitle: "Abbrechen")
        guard a.runModal() == .alertFirstButtonReturn else { return }
        busy = true; setStatus("Lösche Abo …")
        var args = ["--channel-delete", String(c.id)]
        if cb.state == .on { args.append("--delete-planned") }
        Backend.shared.run(args) { _, _, _ in self.busy = false; self.refreshChannels() }
    }
    func notifyInfo(_ title: String, _ text: String) { (NSApp.delegate as? AppDelegate)?.notify(title, text) }

    // MARK: Protokoll
    @objc func reloadLog() {
        let txt = (try? String(contentsOf: Backend.shared.logURL, encoding: .utf8)) ?? ""
        logView.string = txt.split(separator: "\n").suffix(500).joined(separator: "\n")
        logView.scrollToEndOfDocument(nil)
    }
    func appendLog(_ s: String) { guard !s.isEmpty else { return }; logView.string += "\n" + s; logView.scrollToEndOfDocument(nil) }
    func alert(_ title: String, _ text: String) {
        let a = NSAlert(); a.messageText = title; a.informativeText = text
        if let w = window, w.isVisible { a.beginSheetModal(for: w, completionHandler: nil) } else { a.runModal() }
    }
    func showSection(_ index: Int) { sidebar.selectRowIndexes(IndexSet(integer: index), byExtendingSelection: false) }

    // MARK: Tabellen
    func numberOfRows(in tableView: NSTableView) -> Int {
        if tableView === sidebar { return sections.count }
        if tableView === archiveTable { return filteredRecords.count }
        if tableView === epgTable { return telecasts.count }
        if tableView === plannedTable { return planned.count }
        if tableView === channelTable { return channels.count }
        return 0
    }

    func tableView(_ tableView: NSTableView, viewFor tableColumn: NSTableColumn?, row: Int) -> NSView? {
        if tableView === sidebar {
            let id = NSUserInterfaceItemIdentifier("sidecell")
            let cell = (tableView.makeView(withIdentifier: id, owner: nil) as? NSTableCellView) ?? {
                let c = NSTableCellView(); c.identifier = id
                let iv = NSImageView(); iv.translatesAutoresizingMaskIntoConstraints = false
                let tf = NSTextField(labelWithString: ""); tf.translatesAutoresizingMaskIntoConstraints = false; tf.font = NSFont.systemFont(ofSize: 13)
                c.imageView = iv; c.textField = tf; c.addSubview(iv); c.addSubview(tf)
                NSLayoutConstraint.activate([
                    iv.leadingAnchor.constraint(equalTo: c.leadingAnchor, constant: 8), iv.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                    iv.widthAnchor.constraint(equalToConstant: 20), iv.heightAnchor.constraint(equalToConstant: 20),
                    tf.leadingAnchor.constraint(equalTo: iv.trailingAnchor, constant: 8), tf.centerYAnchor.constraint(equalTo: c.centerYAnchor),
                    tf.trailingAnchor.constraint(equalTo: c.trailingAnchor, constant: -4)])
                return c
            }()
            cell.textField?.stringValue = sections[row].0
            cell.imageView?.image = symbol(sections[row].1, 15, weight: .medium)
            cell.imageView?.contentTintColor = accent
            return cell
        }
        guard let col = tableColumn else { return nil }
        let key = col.identifier.rawValue

        if tableView === archiveTable {
            let r = filteredRecords[row]
            switch key {
            case "title":
                let c = richCell(tableView)
                c.title.stringValue = r.displayTitle
                c.sub.stringValue = [r.episode, r.formats.joined(separator: "/"), r.daysLeft > 0 ? "noch \(r.daysLeft) Tage" : ""].filter { !$0.isEmpty }.joined(separator: " · ")
                c.setImage(r.image); return c
            case "state":
                let (c, b) = badgeCell(tableView, key)
                if let p = progressText[r.id] { b.set("Lädt \(p)", accent) } else { let (t, col) = r.badge; b.set(t, col) }
                return c
            case "adfree":
                let c = labelCell(tableView, key); c.textField?.stringValue = r.adfree ? "✓" : "–"; c.textField?.alignment = .center
                c.textField?.textColor = r.adfree ? .systemGreen : .tertiaryLabelColor; return c
            case "start": let c = labelCell(tableView, key); c.textField?.stringValue = germanDate(r.start); c.textField?.textColor = .secondaryLabelColor; return c
            default: let c = labelCell(tableView, key); c.textField?.stringValue = r.station; c.textField?.textColor = .secondaryLabelColor; return c
            }
        }
        if tableView === epgTable {
            let t = telecasts[row]
            switch key {
            case "title":
                let c = richCell(tableView)
                c.title.stringValue = (t.highlight ? "★ " : "") + t.displayTitle
                c.sub.stringValue = [t.episode, String(t.description.prefix(90))].filter { !$0.isEmpty }.joined(separator: " · ")
                c.setImage(t.image); return c
            case "rec":
                let (c, b) = badgeCell(tableView, key); b.set(t.recorded ? "Programmiert" : "", .systemGreen); return c
            case "start": let c = labelCell(tableView, key); c.textField?.stringValue = germanDate(t.start) + (t.end.isEmpty ? "" : "–" + t.end); c.textField?.textColor = .secondaryLabelColor; return c
            case "category": let c = labelCell(tableView, key); c.textField?.stringValue = t.category; c.textField?.textColor = .secondaryLabelColor; return c
            default: let c = labelCell(tableView, key); c.textField?.stringValue = t.station; c.textField?.textColor = .secondaryLabelColor; return c
            }
        }
        let c = labelCell(tableView, key)
        var text = ""; var color = NSColor.labelColor
        if tableView === plannedTable {
            let p = planned[row]
            switch key {
            case "start": text = germanDate(p.start) + (p.end.isEmpty ? "" : "–" + p.end)
            case "station": text = p.station
            case "title": text = p.displayTitle
            case "episode": text = p.episode
            default: text = p.stateMsg; color = .secondaryLabelColor
            }
        } else if tableView === channelTable {
            let ch = channels[row]
            switch key {
            case "name": text = ch.name
            case "type": text = ch.typeText; color = .secondaryLabelColor
            default: text = String(ch.count); color = .secondaryLabelColor
            }
        }
        c.textField?.stringValue = text; c.textField?.textColor = color
        return c
    }

    func tableViewSelectionDidChange(_ notification: Notification) {
        guard let t = notification.object as? NSTableView else { return }
        if t === sidebar {
            let i = currentSection
            pages.selectTabViewItem(at: i)
            if i == 1 && telecasts.isEmpty && Backend.shared.isConfigured { epgModeChanged() }
            if i == 2 && planned.isEmpty { refreshPlanned() }
            if i == 3 && channels.isEmpty { refreshChannels() }
            if i == 4 { reloadLog() }
        } else if t === archiveTable {
            loadSelButton.isEnabled = !busy && archiveTable.selectedRow >= 0; showArchiveDetail()
        } else if t === epgTable {
            epgRecordButton.isEnabled = !busy && epgTable.selectedRow >= 0; showEpgDetail()
        } else if t === plannedTable {
            cancelButton.isEnabled = !busy && plannedTable.selectedRow >= 0
        } else if t === channelTable {
            channelDeleteButton.isEnabled = !busy && channelTable.selectedRow >= 0
        }
    }
}

// MARK: - Einstellungen

final class SettingsWindowController: NSWindowController {
    private let user = NSTextField(), pass = NSSecureTextField(), target = NSTextField()
    private let format = NSPopUpButton(), interval = NSPopUpButton()
    private let adfreeOnly = NSButton(checkboxWithTitle: "Nur werbefreie Fassung laden (sonst auf Schnittliste warten)", target: nil, action: nil)
    private let deleteAfter = NSButton(checkboxWithTitle: "Aufnahme nach dem Download bei Save.TV löschen", target: nil, action: nil)
    private let skipMarked = NSButton(checkboxWithTitle: "Aufnahmen überspringen, die Save.TV schon als geladen markiert", target: nil, action: nil)
    private let autoCheck = NSButton(checkboxWithTitle: "Automatisch im Hintergrund prüfen", target: nil, action: nil)
    private let smartCheck = NSButton(checkboxWithTitle: "Zusätzlich sofort prüfen, wenn eine geplante Aufnahme geendet hat", target: nil, action: nil)
    private let loginItem = NSButton(checkboxWithTitle: "App bei der Anmeldung starten", target: nil, action: nil)
    private let writeMeta = NSButton(checkboxWithTitle: "Titel, Folge und Beschreibung in die MP4 schreiben (AtomicParsley/ffmpeg)", target: nil, action: nil)
    private let parallel = NSPopUpButton()
    private let maxPerRun = NSTextField(), minAge = NSTextField(), cleanupDays = NSTextField(), cleanupFree = NSTextField()
    private let passHint = NSTextField(labelWithString: "")
    var onSaved: (() -> Void)?

    init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 680, height: 700), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Einstellungen"; w.center(); w.isReleasedWhenClosed = false
        super.init(window: w)
        buildUI()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func label(_ s: String) -> NSTextField { let l = NSTextField(labelWithString: s); l.alignment = .right; return l }
    private func section(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s.uppercased()); l.font = NSFont.systemFont(ofSize: 11, weight: .semibold); l.textColor = .secondaryLabelColor; return l
    }
    private func num(_ f: NSTextField, _ ph: String) -> NSTextField { f.placeholderString = ph; f.formatter = NumberFormatter(); f.widthAnchor.constraint(equalToConstant: 70).isActive = true; return f }

    private func buildUI() {
        guard let content = window?.contentView else { return }
        user.placeholderString = "E-Mail-Adresse / Benutzername"; pass.placeholderString = "Passwort"
        passHint.font = NSFont.systemFont(ofSize: 11); passHint.textColor = .secondaryLabelColor
        target.placeholderString = "~/Movies/Save.TV"
        let choose = button("Wählen…", nil, target: self, action: #selector(chooseFolder))
        let targetRow = NSStackView(views: [target, choose]); targetRow.orientation = .horizontal
        target.setContentHuggingPriority(.defaultLow, for: .horizontal)
        format.addItems(withTitles: ["HD (falls im Paket), sonst SD", "SD", "Mobil"])
        interval.addItems(withTitles: ["alle 30 Minuten", "stündlich", "alle 2 Stunden", "alle 4 Stunden", "alle 6 Stunden"])
        let cleanupRow = NSStackView(views: [label("älter als"), num(cleanupDays, "0"), label("Tage löschen · mind."), num(cleanupFree, "0"), label("GB frei halten")])
        cleanupRow.orientation = .horizontal

        let e = NSGridCell.emptyContentView
        let grid = NSGridView(views: [
            [e, section("Konto")], [label("Benutzername:"), user], [label("Passwort:"), pass], [e, passHint],
            [e, section("Downloads")], [label("Zielordner:"), targetRow], [label("Format:"), format],
            [e, adfreeOnly], [e, deleteAfter], [e, skipMarked], [e, writeMeta],
            [label("Gleichzeitige Downloads:"), parallel],
            [label("Max. Downloads pro Lauf:"), num(maxPerRun, "10")], [label("Wartezeit nach Sendeende (Min.):"), num(minAge, "30")],
            [e, section("Aufräumen (0 = aus)")], [label("Lokale Aufnahmen:"), cleanupRow],
            [e, section("Automatik")], [e, autoCheck], [label("Intervall:"), interval], [e, smartCheck], [e, loginItem],
        ])
        grid.rowSpacing = 9; grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).width = 420
        parallel.addItems(withTitles: ["1", "2", "3"])
        for i in [4, 14, 16] { grid.row(at: i).topPadding = 10 }
        grid.translatesAutoresizingMaskIntoConstraints = false

        let save = button("Speichern", nil, target: self, action: #selector(save(_:))); save.keyEquivalent = "\r"
        let cancel = button("Abbrechen", nil, target: self, action: #selector(cancel(_:))); cancel.keyEquivalent = "\u{1b}"
        let test = button("Login testen", "person.badge.key", target: self, action: #selector(testLogin))
        let spacer = NSView(); spacer.setContentHuggingPriority(NSLayoutConstraint.Priority(1), for: .horizontal)
        spacer.widthAnchor.constraint(greaterThanOrEqualToConstant: 20).isActive = true
        let buttons = NSStackView(views: [test, spacer, cancel, save]); buttons.orientation = .horizontal; buttons.distribution = .fill
        buttons.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(grid); content.addSubview(buttons)
        NSLayoutConstraint.activate([
            grid.topAnchor.constraint(equalTo: content.topAnchor, constant: 20), grid.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            grid.trailingAnchor.constraint(lessThanOrEqualTo: content.trailingAnchor, constant: -20),
            buttons.topAnchor.constraint(equalTo: grid.bottomAnchor, constant: 24), buttons.leadingAnchor.constraint(equalTo: content.leadingAnchor, constant: 20),
            buttons.trailingAnchor.constraint(equalTo: content.trailingAnchor, constant: -20), buttons.bottomAnchor.constraint(equalTo: content.bottomAnchor, constant: -20),
        ])
    }

    func load() {
        let cfg = Backend.shared.loadConfig(); let d = UserDefaults.standard
        user.stringValue = cfg["username"] as? String ?? ""; pass.stringValue = ""
        let has = !user.stringValue.isEmpty && Backend.shared.keychainHas(user: user.stringValue)
        passHint.stringValue = has ? "Passwort ist im Schlüsselbund gespeichert – leer lassen, um es zu behalten." : "Wird sicher im macOS-Schlüsselbund gespeichert."
        target.stringValue = cfg["target_dir"] as? String ?? "~/Movies/Save.TV"
        let prio = (cfg["format_priority"] as? [String])?.first?.lowercased() ?? "hd"
        format.selectItem(at: prio == "sd" ? 1 : (prio.hasPrefix("mobil") ? 2 : 0))
        adfreeOnly.state = (cfg["adfree_only"] as? Bool ?? true) ? .on : .off
        deleteAfter.state = (cfg["delete_after_download"] as? Bool ?? false) ? .on : .off
        skipMarked.state = (cfg["skip_marked_downloaded"] as? Bool ?? true) ? .on : .off
        maxPerRun.stringValue = String(cfg["max_downloads_per_run"] as? Int ?? 10)
        minAge.stringValue = String(cfg["min_age_minutes"] as? Int ?? 30)
        writeMeta.state = (cfg["write_metadata"] as? Bool ?? true) ? .on : .off
        parallel.selectItem(at: max(0, min(2, (cfg["parallel_downloads"] as? Int ?? 2) - 1)))
        cleanupDays.stringValue = String(cfg["cleanup_days"] as? Int ?? 0)
        cleanupFree.stringValue = String(cfg["cleanup_min_free_gb"] as? Int ?? Int((cfg["cleanup_min_free_gb"] as? Double) ?? 0))
        autoCheck.state = (d.object(forKey: "autoEnabled") == nil ? true : d.bool(forKey: "autoEnabled")) ? .on : .off
        smartCheck.state = (d.object(forKey: "smartEnabled") == nil ? true : d.bool(forKey: "smartEnabled")) ? .on : .off
        let mins = d.object(forKey: "intervalMinutes") == nil ? 120 : d.integer(forKey: "intervalMinutes")
        interval.selectItem(at: [30, 60, 120, 240, 360].firstIndex(of: mins) ?? 2)
        loginItem.state = AppDelegate.isLoginItem() ? .on : .off
    }

    @objc func chooseFolder() {
        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true; p.prompt = "Auswählen"
        if p.runModal() == .OK, let u = p.url { target.stringValue = u.path }
    }
    @objc func testLogin() {
        guard applyToConfig(requirePassword: true) else { return }
        Backend.shared.run(["--check-login"]) { out, err, code in
            let a = NSAlert(); a.messageText = code == 0 ? "Login erfolgreich" : "Login fehlgeschlagen"
            a.informativeText = code == 0 ? "Die Zugangsdaten sind gültig." : (err.isEmpty ? out : err); a.runModal()
        }
    }
    @discardableResult
    private func applyToConfig(requirePassword: Bool) -> Bool {
        let u = user.stringValue.trimmingCharacters(in: .whitespaces)
        guard !u.isEmpty else { fail("Bitte Benutzername eingeben."); return false }
        let pw = pass.stringValue
        if !pw.isEmpty { if !Backend.shared.keychainSet(user: u, password: pw) { fail("Passwort konnte nicht im Schlüsselbund gespeichert werden."); return false } }
        else if requirePassword && !Backend.shared.keychainHas(user: u) { fail("Bitte Passwort eingeben."); return false }
        var cfg = Backend.shared.loadConfig()
        cfg["username"] = u; cfg["password"] = ""; cfg["use_keychain"] = true
        cfg["target_dir"] = target.stringValue.isEmpty ? "~/Movies/Save.TV" : target.stringValue
        let f = format.indexOfSelectedItem
        cfg["format_priority"] = f == 1 ? ["sd", "mobil"] : (f == 2 ? ["mobil", "sd"] : ["hd", "sd", "mobil"])
        cfg["adfree"] = true
        cfg["adfree_only"] = adfreeOnly.state == .on
        cfg["delete_after_download"] = deleteAfter.state == .on
        cfg["skip_marked_downloaded"] = skipMarked.state == .on
        cfg["max_downloads_per_run"] = Int(maxPerRun.stringValue) ?? 10
        cfg["min_age_minutes"] = Int(minAge.stringValue) ?? 30
        cfg["write_metadata"] = writeMeta.state == .on
        cfg["parallel_downloads"] = parallel.indexOfSelectedItem + 1
        cfg["cleanup_days"] = Int(cleanupDays.stringValue) ?? 0
        cfg["cleanup_min_free_gb"] = Int(cleanupFree.stringValue) ?? 0
        do { try Backend.shared.saveConfig(cfg) } catch { fail("Konfiguration konnte nicht gespeichert werden: \(error)"); return false }
        let d = UserDefaults.standard
        d.set(autoCheck.state == .on, forKey: "autoEnabled")
        d.set(smartCheck.state == .on, forKey: "smartEnabled")
        d.set([30, 60, 120, 240, 360][interval.indexOfSelectedItem], forKey: "intervalMinutes")
        AppDelegate.setLoginItem(loginItem.state == .on)
        pass.stringValue = ""
        return true
    }
    @objc func save(_ sender: Any?) { guard applyToConfig(requirePassword: true) else { return }; window?.close(); onSaved?() }
    @objc func cancel(_ sender: Any?) { window?.close() }
    private func fail(_ msg: String) { let a = NSAlert(); a.messageText = "Eingabe unvollständig"; a.informativeText = msg; a.alertStyle = .warning; a.runModal() }
}

// MARK: - Einrichtungsassistent

final class SetupWizardController: NSWindowController {
    private let user = NSTextField(), pass = NSSecureTextField(), target = NSTextField()
    private let adfreeOnly = NSButton(checkboxWithTitle: "Nur werbefreie Fassungen laden (empfohlen)", target: nil, action: nil)
    private let autoCheck = NSButton(checkboxWithTitle: "Automatisch im Hintergrund prüfen und laden", target: nil, action: nil)
    private let loginItem = NSButton(checkboxWithTitle: "App bei der Anmeldung starten", target: nil, action: nil)
    private let steps = NSTabView()
    private let stepLabel = NSTextField(labelWithString: "")
    private var nextButton: NSButton!, backButton: NSButton!
    private let status = NSTextField(labelWithString: "")
    private let spinner = NSProgressIndicator()
    private var step = 0
    var onFinished: (() -> Void)?

    init() {
        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 420), styleMask: [.titled, .closable], backing: .buffered, defer: false)
        w.title = "Save.TV Downloader einrichten"; w.center(); w.isReleasedWhenClosed = false
        super.init(window: w)
        buildUI()
    }
    required init?(coder: NSCoder) { fatalError() }

    private func textBlock(_ title: String, _ text: String) -> NSStackView {
        let t = NSTextField(labelWithString: title); t.font = NSFont.systemFont(ofSize: 20, weight: .bold)
        let b = NSTextField(wrappingLabelWithString: text); b.textColor = .secondaryLabelColor
        b.preferredMaxLayoutWidth = 500
        let st = NSStackView(views: [t, b]); st.orientation = .vertical; st.alignment = .leading; st.spacing = 6
        return st
    }
    private func pageView(_ views: [NSView]) -> NSView {
        let st = NSStackView(views: views); st.orientation = .vertical; st.alignment = .leading; st.spacing = 14
        st.edgeInsets = NSEdgeInsets(top: 24, left: 28, bottom: 12, right: 28)
        st.translatesAutoresizingMaskIntoConstraints = false
        let v = NSView(); v.addSubview(st)
        NSLayoutConstraint.activate([st.topAnchor.constraint(equalTo: v.topAnchor), st.leadingAnchor.constraint(equalTo: v.leadingAnchor), st.trailingAnchor.constraint(equalTo: v.trailingAnchor)])
        for x in views where x is NSTextField || x is NSStackView { x.widthAnchor.constraint(equalTo: st.widthAnchor, constant: -56).isActive = true }
        return v
    }
    private func buildUI() {
        guard let content = window?.contentView else { return }
        steps.tabViewType = .noTabsNoBorder; steps.translatesAutoresizingMaskIntoConstraints = false
        user.placeholderString = "E-Mail-Adresse / Benutzername"; pass.placeholderString = "Passwort"
        let acc = NSGridView(views: [[NSTextField(labelWithString: "Benutzername:"), user], [NSTextField(labelWithString: "Passwort:"), pass]])
        acc.rowSpacing = 8; acc.columnSpacing = 10; acc.column(at: 1).width = 300
        let p1 = pageView([textBlock("Willkommen", "Die App lädt deine Save.TV-Aufnahmen automatisch auf den Mac und lässt dich Sendungen programmieren. Zuerst brauchen wir dein Save.TV-Konto. Das Passwort wird nur im macOS-Schlüsselbund gespeichert."), acc])
        target.placeholderString = "~/Movies/Save.TV"; target.stringValue = "~/Movies/Save.TV"
        let choose = button("Wählen…", nil, target: self, action: #selector(chooseFolder))
        let row = NSStackView(views: [target, choose]); row.orientation = .horizontal
        target.setContentHuggingPriority(.defaultLow, for: .horizontal)
        adfreeOnly.state = .on; autoCheck.state = .on; loginItem.state = .on
        let p2 = pageView([textBlock("Downloads", "Wohin sollen die Aufnahmen? Werbefreie Fassungen sind meist 30–60 Minuten nach Sendeende verfügbar; die App wartet darauf, statt die Fassung mit Werbung zu laden."), row, adfreeOnly, autoCheck, loginItem])
        let p3 = pageView([textBlock("Fertig", "Alles eingerichtet. Beim ersten Start erscheint eine Nachfrage für Mitteilungen – bitte erlauben, dann meldet sich die App, wenn neue Aufnahmen geladen wurden.\n\nTipp: Über „Programm“ kannst du Sendungen aufnehmen und mit „Alle Folgen aufnehmen (Abo)“ ganze Serien automatisch sammeln lassen. Mit ⌘D läuft jederzeit eine Diagnose.")])
        for (i, v) in [p1, p2, p3].enumerated() { let it = NSTabViewItem(identifier: String(i)); it.view = v; steps.addTabViewItem(it) }

        backButton = button("Zurück", nil, target: self, action: #selector(back))
        nextButton = button("Weiter", nil, target: self, action: #selector(next)); nextButton.keyEquivalent = "\r"
        spinner.style = .spinning; spinner.controlSize = .small; spinner.isDisplayedWhenStopped = false
        status.textColor = .secondaryLabelColor; status.lineBreakMode = .byTruncatingTail
        status.setContentHuggingPriority(.defaultLow, for: .horizontal); status.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        stepLabel.textColor = .tertiaryLabelColor; stepLabel.font = NSFont.systemFont(ofSize: 11)
        let bar = NSStackView(views: [stepLabel, spinner, status, backButton, nextButton]); bar.orientation = .horizontal; bar.spacing = 8
        bar.edgeInsets = NSEdgeInsets(top: 8, left: 20, bottom: 16, right: 20); bar.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(steps); content.addSubview(bar)
        NSLayoutConstraint.activate([
            steps.topAnchor.constraint(equalTo: content.topAnchor), steps.leadingAnchor.constraint(equalTo: content.leadingAnchor), steps.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            bar.topAnchor.constraint(equalTo: steps.bottomAnchor), bar.leadingAnchor.constraint(equalTo: content.leadingAnchor), bar.trailingAnchor.constraint(equalTo: content.trailingAnchor), bar.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
        show(0)
    }
    private func show(_ i: Int) {
        step = i; steps.selectTabViewItem(at: i)
        stepLabel.stringValue = "Schritt \(i + 1) von 3"
        backButton.isHidden = i == 0
        nextButton.title = i == 0 ? "Login testen und weiter" : (i == 2 ? "Los geht's" : "Weiter")
        status.stringValue = ""
        if i == 0 { window?.makeFirstResponder(user) }
    }
    @objc func chooseFolder() {
        let p = NSOpenPanel(); p.canChooseDirectories = true; p.canChooseFiles = false; p.canCreateDirectories = true; p.prompt = "Auswählen"
        if p.runModal() == .OK, let u = p.url { target.stringValue = u.path }
    }
    @objc func back() { show(max(0, step - 1)) }
    @objc func next() {
        switch step {
        case 0:
            let u = user.stringValue.trimmingCharacters(in: .whitespaces), pw = pass.stringValue
            guard !u.isEmpty, !pw.isEmpty else { status.stringValue = "Bitte Benutzername und Passwort eingeben."; return }
            guard Backend.shared.keychainSet(user: u, password: pw) else { status.stringValue = "Schlüsselbund verweigert das Speichern."; return }
            var cfg = Backend.shared.loadConfig()
            cfg["username"] = u; cfg["password"] = ""; cfg["use_keychain"] = true
            cfg["target_dir"] = cfg["target_dir"] ?? "~/Movies/Save.TV"
            try? Backend.shared.saveConfig(cfg)
            nextButton.isEnabled = false; spinner.startAnimation(nil); status.stringValue = "Prüfe Login bei Save.TV …"
            Backend.shared.run(["--check-login"]) { out, err, code in
                self.nextButton.isEnabled = true; self.spinner.stopAnimation(nil)
                if code == 0 { self.status.stringValue = ""; self.show(1) }
                else { self.status.stringValue = "Login fehlgeschlagen: " + Backend.shared.describeError(out, err, code) }
            }
        case 1:
            var cfg = Backend.shared.loadConfig()
            cfg["target_dir"] = target.stringValue.isEmpty ? "~/Movies/Save.TV" : target.stringValue
            cfg["adfree"] = true; cfg["adfree_only"] = adfreeOnly.state == .on
            cfg["format_priority"] = ["hd", "sd", "mobil"]; cfg["skip_marked_downloaded"] = true
            try? Backend.shared.saveConfig(cfg)
            UserDefaults.standard.set(autoCheck.state == .on, forKey: "autoEnabled")
            AppDelegate.setLoginItem(loginItem.state == .on)
            show(2)
        default:
            window?.close(); onFinished?()
        }
    }
}

// MARK: - App

final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var lastRun = Date.distantPast
    private var notificationsOK = false
    let main = MainWindowController()
    let settings = SettingsWindowController()
    let wizard = SetupWizardController()

    func applicationDidFinishLaunching(_ notification: Notification) {
        buildMainMenu(); buildStatusItem(); setupNotifications()
        main.onRunFinished = { n, code, _ in
            self.lastRun = Date()
            let f = DateFormatter(); f.dateFormat = "HH:mm"
            let mins = UserDefaults.standard.object(forKey: "intervalMinutes") == nil ? 120 : UserDefaults.standard.integer(forKey: "intervalMinutes")
            self.main.lastRunText = "Letzter Lauf \(f.string(from: self.lastRun))\(code == 0 ? "" : " (Fehler)") · nächster spätestens \(f.string(from: self.lastRun.addingTimeInterval(TimeInterval(mins * 60))))"
            if n > 0 { self.notify("Save.TV Downloader", "\(n) neue Aufnahme\(n == 1 ? "" : "n") heruntergeladen.") }
            if code != 0 && code != 130 { self.notify("Save.TV Downloader", "Lauf mit Fehler beendet – Protokoll prüfen.") }
        }
        settings.onSaved = { self.scheduleTimer(); self.main.refresh() }
        scheduleTimer()
        showMain()
        wizard.onFinished = { self.scheduleTimer(); self.main.refresh(); self.main.refreshPlannedSilently() }
        if Backend.shared.isConfigured { main.refresh(); main.refreshPlannedSilently() }
        else { DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { self.showWizard() } }
    }
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool { showMain(); return true }
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    @objc func showMain() { NSApp.setActivationPolicy(.regular); NSApp.activate(ignoringOtherApps: true); main.showWindow(nil); main.window?.makeKeyAndOrderFront(nil) }
    @objc func showWizard() { NSApp.activate(ignoringOtherApps: true); wizard.showWindow(nil); wizard.window?.makeKeyAndOrderFront(nil) }
    @objc func showSettings() { settings.load(); NSApp.activate(ignoringOtherApps: true); settings.showWindow(nil); settings.window?.makeKeyAndOrderFront(nil) }
    @objc func runNow() { showMain(); main.runNow() }
    @objc func showArchive() { showMain(); main.showSection(0) }
    @objc func showEpg() { showMain(); main.showSection(1) }
    @objc func showPlanned() { showMain(); main.showSection(2) }
    @objc func showChannels() { showMain(); main.showSection(3) }

    private func buildMainMenu() {
        let menubar = NSMenu()
        let appItem = NSMenuItem(); menubar.addItem(appItem)
        let appMenu = NSMenu()
        appMenu.addItem(NSMenuItem(title: "Über Save.TV Downloader", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: ""))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Einstellungen…", action: #selector(showSettings), keyEquivalent: ","))
        appMenu.addItem(NSMenuItem(title: "Einrichtungsassistent…", action: #selector(showWizard), keyEquivalent: ""))
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Fenster schließen", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        appMenu.addItem(NSMenuItem(title: "Save.TV Downloader beenden", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        appItem.submenu = appMenu
        let actItem = NSMenuItem(); menubar.addItem(actItem)
        let act = NSMenu(title: "Aktionen")
        act.addItem(NSMenuItem(title: "Jetzt prüfen und laden", action: #selector(runNow), keyEquivalent: "r"))
        act.addItem(NSMenuItem(title: "Aktualisieren", action: #selector(MainWindowController.refreshCurrent), keyEquivalent: "R"))
        act.addItem(NSMenuItem(title: "Zielordner öffnen", action: #selector(MainWindowController.openTarget), keyEquivalent: "o"))
        act.addItem(NSMenuItem(title: "Diagnose…", action: #selector(MainWindowController.runDiagnose), keyEquivalent: "d"))
        act.addItem(.separator())
        act.addItem(NSMenuItem(title: "Archiv", action: #selector(showArchive), keyEquivalent: "1"))
        act.addItem(NSMenuItem(title: "Programm", action: #selector(showEpg), keyEquivalent: "2"))
        act.addItem(NSMenuItem(title: "Geplant", action: #selector(showPlanned), keyEquivalent: "3"))
        act.addItem(NSMenuItem(title: "Abos", action: #selector(showChannels), keyEquivalent: "4"))
        actItem.submenu = act
        let editItem = NSMenuItem(); menubar.addItem(editItem)
        let edit = NSMenu(title: "Bearbeiten")
        edit.addItem(NSMenuItem(title: "Ausschneiden", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        edit.addItem(NSMenuItem(title: "Kopieren", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        edit.addItem(NSMenuItem(title: "Einsetzen", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        edit.addItem(NSMenuItem(title: "Alles auswählen", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        editItem.submenu = edit
        NSApp.mainMenu = menubar
    }

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let b = statusItem.button {
            if let img = NSImage(systemSymbolName: "arrow.down.circle", accessibilityDescription: "Save.TV") { img.isTemplate = true; b.image = img } else { b.title = "STV" }
        }
        let m = NSMenu()
        m.addItem(NSMenuItem(title: "Fenster anzeigen", action: #selector(showMain), keyEquivalent: ""))
        m.addItem(NSMenuItem(title: "Jetzt prüfen und laden", action: #selector(runNow), keyEquivalent: ""))
        m.addItem(NSMenuItem(title: "Programm…", action: #selector(showEpg), keyEquivalent: ""))
        m.addItem(NSMenuItem(title: "Einstellungen…", action: #selector(showSettings), keyEquivalent: ""))
        m.addItem(.separator())
        m.addItem(NSMenuItem(title: "Beenden", action: #selector(NSApplication.terminate(_:)), keyEquivalent: ""))
        statusItem.menu = m
    }

    // Hintergrund: alle 10 min prüfen, ob ein Lauf fällig ist (Intervall oder geplante Aufnahme geendet)
    func scheduleTimer() {
        timer?.invalidate()
        guard Backend.shared.isConfigured else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 600, repeats: true) { _ in self.tick() }
        timer?.tolerance = 60
    }
    private func tick() {
        let d = UserDefaults.standard
        let auto = d.object(forKey: "autoEnabled") == nil ? true : d.bool(forKey: "autoEnabled")
        let smart = d.object(forKey: "smartEnabled") == nil ? true : d.bool(forKey: "smartEnabled")
        let mins = d.object(forKey: "intervalMinutes") == nil ? 120 : d.integer(forKey: "intervalMinutes")
        guard auto, !main.busy else { return }
        let since = Date().timeIntervalSince(lastRun)
        var due = since >= TimeInterval(max(mins, 5) * 60)
        if !due && smart && since >= 900 {
            let minAge = TimeInterval(Backend.shared.minAgeMinutes * 60)
            let ready = Date().addingTimeInterval(-minAge)
            due = main.planned.contains { p in if let e = p.endDate { return e <= ready && e > lastRun.addingTimeInterval(-minAge) } ; return false }
        }
        if due { main.runNow(); main.refreshPlannedSilently() }
    }

    // Mitteilungen
    private func setupNotifications() {
        guard Bundle.main.bundleIdentifier != nil, Bundle.main.bundlePath.hasSuffix(".app") else { return }
        let c = UNUserNotificationCenter.current()
        c.delegate = self
        c.requestAuthorization(options: [.alert, .sound]) { ok, _ in DispatchQueue.main.async { self.notificationsOK = ok } }
    }
    func notify(_ title: String, _ body: String) {
        if notificationsOK {
            let content = UNMutableNotificationContent(); content.title = title; content.body = body; content.sound = .default
            let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
            UNUserNotificationCenter.current().add(req) { err in
                if err != nil { self.notifyFallback(title, body) }
            }
        } else { notifyFallback(title, body) }
    }
    private func notifyFallback(_ title: String, _ body: String) {
        let s = "display notification \"\(body.replacingOccurrences(of: "\"", with: "'"))\" with title \"\(title)\""
        NSAppleScript(source: s)?.executeAndReturnError(nil)
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        showMain(); main.openTarget(); completionHandler()
    }
    func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound])
    }

    static func isLoginItem() -> Bool {
        let s = "tell application \"System Events\" to get the name of every login item"
        guard let r = NSAppleScript(source: s)?.executeAndReturnError(nil) else { return false }
        for i in 0..<r.numberOfItems where r.atIndex(i + 1)?.stringValue == "Save.TV Downloader" { return true }
        return false
    }
    static func setLoginItem(_ on: Bool) {
        if on == isLoginItem() { return }
        let path = Bundle.main.bundlePath
        let s = on
            ? "tell application \"System Events\" to make login item at end with properties {path:\"\(path)\", hidden:false, name:\"Save.TV Downloader\"}"
            : "tell application \"System Events\" to delete login item \"Save.TV Downloader\""
        NSAppleScript(source: s)?.executeAndReturnError(nil)
    }
}

extension MainWindowController {
    /// Geplante Aufnahmen im Hintergrund laden (für den intelligenten Hintergrundlauf), ohne Statuszeile zu stören.
    func refreshPlannedSilently() {
        guard Backend.shared.isConfigured else { return }
        Backend.shared.run(["--planned"]) { out, _, _ in
            if let j = Backend.shared.json(out), let arr = j["planned"] as? [[String: Any]] {
                self.planned = arr.map(Planned.init)
                self.plannedTable.reloadData()
            }
        }
    }
}

let app = NSApplication.shared
let delegate = AppDelegate()
app.delegate = delegate
app.setActivationPolicy(.regular)
app.run()
