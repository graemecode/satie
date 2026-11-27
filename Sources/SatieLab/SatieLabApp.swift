import AcousticCore
import AppKit
import SwiftUI

// Satie Lab: a developer-only listening room. Play any world on the real engine, jump to its
// sections, and leave a rating, tags and a note. Notes land in Lab/feedback.jsonl with the world,
// the moment and the exact build, so the next iteration can act on them. Never shipped.
// Run with scripts/lab.sh.

@main
struct SatieLabApp: App {
    @StateObject private var lab = LabModel()

    init() {
        NSApplication.shared.setActivationPolicy(.regular)
        DispatchQueue.main.async { NSApplication.shared.activate(ignoringOtherApps: true) }
    }

    var body: some Scene {
        WindowGroup("Satie Lab") {
            LabView()
                .environmentObject(lab)
                .frame(minWidth: 860, minHeight: 600)
        }
        .windowResizability(.contentMinSize)
    }
}

// MARK: - Model

struct LabNote: Codable, Identifiable {
    var id = UUID()
    var time: Date
    var build: String
    var world: String
    var worldTitle: String
    var bar: Int
    var markedBar: Int?
    var section: String
    var chord: String
    var listenedSeconds: Int
    var timeOfDay: String
    var version: String?
    var rating: Int?
    var tags: [String]
    var note: String
}

@MainActor
final class LabModel: ObservableObject {
    let engine: FocusSoundEngine
    private let ring = StereoRingBuffer()

    @Published var world: FocusSoundscape = .groove
    @Published var playing = false
    @Published var timeOfDay: CircadianPhase = .afternoon { didSet { engine.setCircadianPhase(timeOfDay) } }
    @Published var telemetry = ScoreTelemetry.empty
    @Published var pieceTitle = ""
    @Published var levelDB: Float = -80
    @Published var listened: TimeInterval = 0
    @Published var notes: [LabNote] = []
    @Published var draft = ""
    @Published var draftTags: Set<String> = []
    @Published var draftRating: Int?
    @Published var markedBar: Int?
    /// "Current" is what ships; "New" is the candidate under test.
    @Published var useNew = false {
        didSet {
            SoundCandidate.isOn = useNew
            if engine.isPlaying { engine.jumpToBar(bar) } // recompose from here so the switch is heard now
        }
    }

    static let tagChoices = [
        "Love it", "Would keep this on", "Good for deep work", "Groove feels good",
        "Groove feels off", "Too busy", "Too sparse", "Repetitive", "Boring", "Distracting",
        "Too dark", "Too bright", "Muddy", "Harsh", "Too loud", "Too quiet",
    ]

    let feedbackURL: URL
    let build: String
    private var timer: Timer?
    private var lastTick = Date()

    init() {
        engine = FocusSoundEngine(ringBuffer: ring)
        // Sources/SatieLab/SatieLabApp.swift -> repository root
        let root = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        feedbackURL = root.appendingPathComponent("Lab/feedback.jsonl")
        build = Bundle.main.object(forInfoDictionaryKey: "SatieLabBuild") as? String ?? "dev"
        try? FileManager.default.createDirectory(at: feedbackURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        loadNotes()
        engine.setVolume(0.75)
        timeOfDay = CircadianPhase.current()
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.tick() }
        }
    }

    private func tick() {
        let now = Date()
        if engine.isPlaying { listened += now.timeIntervalSince(lastTick) }
        lastTick = now
        telemetry = engine.scoreTelemetry
        pieceTitle = engine.currentPieceTitle
        playing = engine.isPlaying
        let rms = ring.recentRMS(frameCount: 9600)
        levelDB = rms > 0 ? 20 * log10(rms) : -80
    }

    var bar: Int { telemetry.pass * 32 + telemetry.barInForm }

    var sectionLabel: String {
        if !pieceTitle.isEmpty { return pieceTitle }
        guard world == .groove else { return "Pass \(telemetry.pass + 1), section \(telemetry.barInForm / 8 + 1) of 4" }
        let pass = telemetry.pass, section = telemetry.barInForm / 8
        if bar < 4 { return "Intro: keys only" }
        if bar < 8 { return "Intro: light kit" }
        if pass % 12 == 11 && section >= 2 { return "Breakdown, no drums" }
        if pass % 4 == 0 || (pass % 4 == 3 && section == 3) { return "Light section" }
        return "Full groove"
    }

    /// What the New version changes in each world, so you know what to listen for.
    var whatsNew: String {
        switch world {
        case .focus: return "New: the full melody plays on the first pass and every fourth pass; in between it continues as a quiet whisper, so it never snaps back in. The arpeggio breathes a little more outside the climax. Try Second or Third pass."
        case .pulse: return "New: after the first pass the arpeggio rotates between full, open and sparse by section, and every third pass ends with an 8-bar breath. The fast pad tremolo fades after 20 minutes. Try Third pass and 25 minutes in."
        case .rain: return "New: the rain is a real, audible bed (it was ~30 dB under the instruments) and the pad is a little fuller, so it swells half as much (6.3 → 3.3 LU)."
        case .still: return "New: about every 4 minutes, a soft two-note glow rises and fades, so it never goes fully static."
        case .groove: return "New: a second, 8-bar beatless break halfway between breakdowns; the drums fade back in over a bar after every break instead of snapping on; after 20 minutes every other full section uses lighter 8th-note hats. Try Short break and 25 minutes in."
        case .drift: return "New: its rests keep one soft note on the downbeat instead of going silent, so the piano never drops out."
        case .dive: return "No changes in New for this world."
        case .lateLight: return "A new piece built like Soft Light: 32 bars in F major at 68 BPM, a descending B♭maj9–Am7–Gm9–Fmaj7 line, a written melody, a continuous arpeggio and strings that swell into the middle. Compare it with Soft Light."
        case .soirDete: return "Winner of 12 synthesized Impressionist candidates graded against the 21 MIDI files in samples/impressionist/: 32 bars in E♭ major (A♭ Lydian) at 62 BPM, mediant/whole-step 9th & #11 harmony, written quote-free melody, felt piano + concert harp + soft vibe arabesques and bowed cello."
        case .loops: return "Six short piano phrases in Satie's harmony, each repeating on its own loop (17 to 37 seconds), so they drift into new combinations for hours, over a soft floor that never stops. Every few minutes one loop swaps to another phrase. Tell me which phrases you love or would cut."
        case .furniture: return "Your verdict: a knockoff of Gymnopédie. Kept only for comparison. New music composed endlessly in Satie's language: his harmony, voicings, accompaniment and melodic habits, measured from his scores, never one of his pieces (any run that matches his melodies is rewritten). Compare it with the real Gymnopédies below."
        case .gymnopedies, .gnossiennes, .sarabandes, .debussy, .faure, .scriabin: return "Benchmark: the composer's own pieces, played endlessly (Lab only, never shipped). Current and New are the same."
        }
    }

    /// Places worth hearing in each world, as (label, bar).
    var jumps: [(String, Int)] {
        let perMinute = 60.0 / SatieScore.secondsPerBar(for: world)
        let minutes = { (m: Double) in Int(m * perMinute) }
        if SatieRepertoire.collection(for: world) != nil {
            return SatieRepertoire.pieceStarts(for: world).map { ($0.0, max(1, $0.1)) }
        }
        switch world {
        case .groove:
            return [("Start", 0), ("Full groove", 40), ("Light section", 128), ("Short break", 5 * 32 + 22),
                    ("Breakdown", 11 * 32 + 14), ("25 minutes in", minutes(25))]
        default:
            return [("Start", 0), ("Second pass", 32), ("Third pass", 64), ("Fifth pass", 128), ("25 minutes in", minutes(25))]
        }
    }

    func toggle() {
        if engine.isPlaying {
            engine.stop()
        } else {
            engine.start(mode: world)
            engine.setCircadianPhase(timeOfDay)
        }
        playing = engine.isPlaying
    }

    func select(_ mode: FocusSoundscape) {
        guard mode != world else { return }
        world = mode
        listened = 0
        markedBar = nil
        engine.setMode(mode)
    }

    func jump(to target: Int) {
        if !engine.isPlaying { toggle() }
        engine.jumpToBar(target)
    }

    func mark() { markedBar = bar }

    func saveNote() {
        let text = draft.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty || !draftTags.isEmpty || draftRating != nil else { return }
        let note = LabNote(
            time: Date(), build: build, world: world.rawValue, worldTitle: world.title,
            bar: bar, markedBar: markedBar, section: sectionLabel, chord: pieceTitle.isEmpty ? telemetry.chordLabel : pieceTitle,
            listenedSeconds: Int(listened), timeOfDay: timeOfDay.label, version: useNew ? "new" : "current",
            rating: draftRating, tags: draftTags.sorted(), note: text
        )
        let enc = JSONEncoder()
        enc.dateEncodingStrategy = .iso8601
        enc.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        if let data = try? enc.encode(note), let line = String(data: data, encoding: .utf8).map({ $0 + "\n" }) {
            if let h = try? FileHandle(forWritingTo: feedbackURL) {
                h.seekToEndOfFile(); h.write(Data(line.utf8)); try? h.close()
            } else {
                try? Data(line.utf8).write(to: feedbackURL)
            }
        }
        notes.insert(note, at: 0)
        draft = ""; draftTags = []; draftRating = nil; markedBar = nil
    }

    private func loadNotes() {
        guard let text = try? String(contentsOf: feedbackURL, encoding: .utf8) else { return }
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        notes = text.split(separator: "\n").compactMap { try? dec.decode(LabNote.self, from: Data($0.utf8)) }.reversed()
    }

    func lastRating(for mode: FocusSoundscape) -> Int? {
        notes.first { $0.world == mode.rawValue && $0.rating != nil }?.rating
    }
}

// MARK: - Views

struct LabView: View {
    @EnvironmentObject var lab: LabModel

    var body: some View {
        HStack(spacing: 0) {
            worldColumn.frame(width: 230)
            Divider()
            VStack(spacing: 0) {
                nowPlaying
                Divider()
                feedback
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var worldColumn: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Worlds").font(.headline).padding(.bottom, 4)
            ScrollView {
            VStack(alignment: .leading, spacing: 6) {
            ForEach(FocusSoundscape.allCases) { mode in
                if mode == .lateLight {
                    Text("New, Lab only").font(.caption).foregroundStyle(.secondary).padding(.top, 8)
                }
                if mode == .gymnopedies {
                    Text("Benchmarks: the real pieces").font(.caption).foregroundStyle(.secondary).padding(.top, 8)
                }
                Button { lab.select(mode) } label: {
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 1) {
                            Text(mode.title).fontWeight(lab.world == mode ? .semibold : .regular)
                            Text(mode.subtitle).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                        }
                        Spacer()
                        if let r = lab.lastRating(for: mode) {
                            Text("\(r)/5").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                    .padding(.vertical, 6).padding(.horizontal, 8)
                    .background(RoundedRectangle(cornerRadius: 7).fill(lab.world == mode ? Color.accentColor.opacity(0.18) : .clear))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            }
            }
            Picker("Time of day", selection: $lab.timeOfDay) {
                ForEach([CircadianPhase.morning, .afternoon, .night], id: \.self) { Text($0.label).tag($0) }
            }
            Text("Build \(lab.build)").font(.caption2).foregroundStyle(.secondary)
        }
        .padding(14)
    }

    private var nowPlaying: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .center, spacing: 16) {
                Button { lab.toggle() } label: {
                    Image(systemName: lab.playing ? "pause.fill" : "play.fill")
                        .font(.system(size: 22))
                        .frame(width: 56, height: 56)
                        .background(Circle().fill(Color.accentColor.opacity(0.2)))
                }
                .buttonStyle(.plain)
                .keyboardShortcut("p", modifiers: .command)
                .help("Play or pause (⌘P)")
                VStack(alignment: .leading, spacing: 3) {
                    Text(lab.world.title).font(.title2).fontWeight(.semibold)
                    Text(lab.pieceTitle.isEmpty ? "\(lab.sectionLabel) · bar \(lab.bar + 1) · \(lab.telemetry.chordLabel)" : "\(lab.pieceTitle) · bar \(lab.bar + 1)")
                        .foregroundStyle(.secondary)
                    Text("Listened \(Self.clock(lab.listened))").font(.caption).foregroundStyle(.secondary).monospacedDigit()
                }
                Spacer()
                VStack(alignment: .trailing, spacing: 6) {
                    Picker("", selection: $lab.useNew) {
                        Text("Current").tag(false)
                        Text("New").tag(true)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 150)
                    .help("Current is what ships. New is the candidate under test; switching keeps your place.")
                    meter
                }
            }
            if lab.useNew {
                Text(lab.whatsNew).font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 6) {
                Text("Jump to").foregroundStyle(.secondary)
                ForEach(lab.jumps, id: \.1) { item in
                    Button(item.0) { lab.jump(to: item.1) }
                }
            }
        }
        .padding(16)
    }

    private static func clock(_ t: TimeInterval) -> String {
        let s = Int(t)
        return String(format: "%d:%02d", s / 60, s % 60)
    }

    private var meter: some View {
        let norm = CGFloat(max(0, min(1, (lab.levelDB + 40) / 40)))
        return ZStack(alignment: .leading) {
            Capsule().fill(Color.secondary.opacity(0.2))
            Capsule().fill(Color.green.opacity(0.8)).frame(width: 80 * norm)
        }
        .frame(width: 80, height: 6)
        .help(String(format: "%.0f dBFS RMS", lab.levelDB))
    }

    private var feedback: some View {
        HStack(alignment: .top, spacing: 0) {
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("How is it?").font(.headline)
                    Spacer()
                    Button(lab.markedBar.map { "Marked bar \($0 + 1)" } ?? "Mark this moment") { lab.mark() }
                        .keyboardShortcut("m", modifiers: .command)
                        .help("Remember where you are, then write the note (⌘M)")
                }
                HStack(spacing: 4) {
                    ForEach(1...5, id: \.self) { n in
                        Button { lab.draftRating = (lab.draftRating == n ? nil : n) } label: {
                            Image(systemName: (lab.draftRating ?? 0) >= n ? "star.fill" : "star").font(.title3)
                        }
                        .buttonStyle(.borderless)
                    }
                }
                TagGrid(selection: $lab.draftTags, tags: LabModel.tagChoices)
                TextEditor(text: $lab.draft)
                    .font(.body)
                    .frame(minHeight: 90)
                    .overlay(alignment: .topLeading) {
                        if lab.draft.isEmpty {
                            Text("What did you notice? Anything you'd change?")
                                .foregroundStyle(.tertiary).padding(.top, 1).padding(.leading, 5).allowsHitTesting(false)
                        }
                    }
                    .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.secondary.opacity(0.3)))
                    .onChange(of: lab.draft) { _, new in if lab.markedBar == nil && !new.isEmpty { lab.mark() } }
                HStack {
                    Button("Save note") { lab.saveNote() }
                        .keyboardShortcut(.return, modifiers: .command)
                    Text("⌘↩").font(.caption).foregroundStyle(.secondary)
                }
            }
            .padding(16)
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                Text("Your notes").font(.headline)
                if lab.notes.isEmpty {
                    Text("Nothing yet.").foregroundStyle(.secondary)
                }
                List(lab.notes.prefix(60)) { note in
                    VStack(alignment: .leading, spacing: 2) {
                        Text("\(note.worldTitle)\(note.version == "new" ? " (new)" : "") · bar \((note.markedBar ?? note.bar) + 1) · \(note.section)")
                            .font(.caption).foregroundStyle(.secondary)
                        let meta = ([note.rating.map { "\($0)/5" }].compactMap { $0 } + note.tags).joined(separator: " · ")
                        if !meta.isEmpty { Text(meta).font(.caption) }
                        if !note.note.isEmpty { Text(note.note) }
                    }
                    .padding(.vertical, 2)
                }
                .listStyle(.plain)
            }
            .padding(16)
            .frame(width: 280)
        }
    }
}

struct TagGrid: View {
    @Binding var selection: Set<String>
    let tags: [String]

    var body: some View {
        LazyVGrid(columns: [GridItem(.adaptive(minimum: 128), spacing: 6, alignment: .leading)], alignment: .leading, spacing: 6) {
            ForEach(tags, id: \.self) { tag in
                let on = selection.contains(tag)
                Button {
                    if on { selection.remove(tag) } else { selection.insert(tag) }
                } label: {
                    Text(tag).font(.caption)
                        .padding(.horizontal, 8).padding(.vertical, 4)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Capsule().fill(on ? Color.accentColor.opacity(0.85) : Color.secondary.opacity(0.15)))
                        .foregroundStyle(on ? Color.white : Color.primary)
                }
                .buttonStyle(.plain)
            }
        }
    }
}
