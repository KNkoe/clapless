import SwiftUI

/// What is known about a take, in words, for the list and the line under the record button.
struct TakeSummary {
    let take: TakeRecord
    let progress: Downloader.Progress?
    let linked: Bool

    var finished: Bool { take.status == .ready || take.status == .failed }
    var troubled: Bool { progress?.problem != nil || take.status == .failed }

    var when: String {
        take.created.formatted(.dateTime.day().month(.abbreviated).hour().minute())
    }

    var fraction: Double? {
        guard let progress, progress.listed > 0 else { return nil }
        return min(1, Double(progress.received) / Double(progress.listed))
    }

    var title: String {
        if troubled { return "Take has a problem" }
        if take.status == .ready { return "Saved on this Mac" }
        if progress?.checking == true { return "Checking the file" }
        if progress?.recording == true { return "Sending while recording" }
        if take.status == .recording { return "Recording" }
        return linked && progress != nil ? "Sending to Mac" : "Waiting for the iPhone"
    }

    var tint: Color {
        if troubled { return Brand.red }
        if take.status == .ready { return Brand.green }
        return linked ? Brand.bone : Brand.amber
    }

    var syncWords: String? {
        guard take.mic != nil else { return "No Mac mic" }
        guard let sync = take.sync, sync.tried == true else { return "Lining up by sound…" }
        if !sync.matchedBySound { return "Not synced: the sound did not match" }
        if sync.weak == true { return "Sync is weak: check lip sync" }
        return sync.driftMeasured == true ? "Synced by sound, drift measured" : "Synced by sound"
    }

    var detail: String {
        if let problem = progress?.problem { return problem }
        if take.status == .failed { return take.warnings.last ?? "Something went wrong" }
        if take.status == .ready, let camera = take.camera {
            let screen = take.screen == nil ? " · no screen" : ""
            let note = take.warnings.first.map { "\n\($0)" } ?? ""
            let total = camera.bytes + (take.mic?.bytes ?? 0) + (take.screen?.bytes ?? 0)
            return "\(timecode(camera.seconds)) · \(bytes(total))\(screen)\n\(syncWords ?? "")\(note)"
        }
        guard let progress else { return "Open Clapless on the iPhone" }
        if progress.checking { return "\(bytes(progress.listed)) · making sure nothing is missing" }
        if !linked { return "\(bytes(progress.received)) of \(bytes(progress.listed)) · open Clapless on the iPhone" }
        let speed = progress.bytesPerSecond > 1000 ? " · \(bytes(Int(progress.bytesPerSecond)))/s" : ""
        if progress.recording { return "\(bytes(progress.listed - progress.received)) behind\(speed)" }
        return "\(bytes(progress.received)) of \(bytes(progress.listed))\(speed)\(timeLeft.map { " · \($0)" } ?? "")"
    }

    var timeLeft: String? {
        guard let progress, progress.bytesPerSecond > 1000 else { return nil }
        let seconds = Int((Double(progress.listed - progress.received) / progress.bytesPerSecond).rounded(.up))
        return seconds >= 90 ? "about \((seconds + 30) / 60) min left" : "\(seconds) s left"
    }

    private func bytes(_ count: Int) -> String { fileSize(count) }
}

private func fileSize(_ count: Int) -> String {
    ByteCountFormatter.string(fromByteCount: Int64(max(0, count)), countStyle: .file)
}

/// Every take, newest first, ruled like a parts list. Drawn over the picture.
struct TakesView: View {
    @ObservedObject var model: MacModel
    @State private var asking: String?          // the take whose delete is waiting for a yes
    @State private var sizes: [String: Int] = [:]

    var body: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                HStack {
                    Caption(text: model.takes.isEmpty ? "Takes" : "Takes · \(fileSize(sizes.values.reduce(0, +)))")
                    Spacer()
                    Caption(text: "Movies › Clapless")
                }
                .padding(14)
                Rule()
                if let problem = model.deleteProblem {
                    note(problem, colour: Brand.amber)
                }
                if model.deletesWaiting > 0 {
                    let count = model.deletesWaiting == 1 ? "1 deleted take is" : "\(model.deletesWaiting) deleted takes are"
                    note("\(count) still on the iPhone. Open Clapless there to free the space.", colour: Brand.grey)
                }
                if model.takes.isEmpty {
                    Text("Takes appear here.")
                        .font(Brand.font(13))
                        .foregroundStyle(Brand.grey)
                        .padding(.top, 48)
                }
                ForEach(model.takes) { take in
                    TakeRow(summary: TakeSummary(take: take, progress: model.progress[take.take],
                                                 linked: model.linked),
                            deletable: model.canDelete(take),
                            reveal: { model.reveal(take) },
                            askDelete: { asking = asking == take.take ? nil : take.take })
                    if asking == take.take, model.canDelete(take) {
                        DeleteQuestion(take: take, size: sizes[take.take] ?? 0, linked: model.linked,
                                       delete: { toTrash in asking = nil; model.delete(take, toTrash: toTrash) },
                                       cancel: { asking = nil })
                    }
                    Rule()
                }
            }
        }
        .background(Brand.ink.opacity(0.97))
        // Measured when the list opens or a take changes, not on every redraw.
        .task(id: model.takes.map { "\($0.take) \($0.status.rawValue)" }) {
            sizes = Dictionary(uniqueKeysWithValues: model.takes.map { ($0.take, model.size(of: $0)) })
        }
    }

    @ViewBuilder private func note(_ text: String, colour: Color) -> some View {
        Text(text)
            .font(Brand.font(11.5, 500))
            .foregroundStyle(colour)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(14)
        Rule()
    }
}

/// Asked in place, under the take it is about, saying exactly what goes.
private struct DeleteQuestion: View {
    let take: TakeRecord
    let size: Int
    let linked: Bool
    let delete: (_ toTrash: Bool) -> Void
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Delete this take?").font(Brand.font(13, 700)).foregroundStyle(Brand.bone)
            Text(what).font(Brand.digits(11.5, 500)).foregroundStyle(Brand.bone)
            if take.camera == nil {
                Text("The camera file never arrived here, so the iPhone may hold the only full copy.")
                    .font(Brand.font(11.5, 600)).foregroundStyle(Brand.amber)
            }
            HStack(spacing: 8) {
                button("Delete", fill: Brand.red, text: Brand.ink,
                       help: "Frees the space now. This cannot be undone.") { delete(false) }
                button("Move to Trash", help: "The Mac files stay in the Trash until you empty it") { delete(true) }
                Spacer(minLength: 0)
                button("Cancel", help: "Keep the take", run: cancel)
            }
            Text("Delete cannot be undone. The Trash frees no Mac space until you empty it.")
                .font(Brand.font(10.5, 500)).foregroundStyle(Brand.grey)
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .leading) { Rectangle().fill(Brand.red).frame(width: 2) }
        .accessibilityElement(children: .contain)
    }

    private var what: String {
        linked ? "Removes \(fileSize(size)) from this Mac, and the iPhone's copy."
            : "Removes \(fileSize(size)) from this Mac. The iPhone's copy goes when it next connects."
    }

    private func button(_ title: String, fill: Color = .clear, text: Color = Brand.bone, help: String,
                        run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Caption(text: title, colour: text)
                .padding(.horizontal, 10)
                .frame(height: 28)
                .background(fill)
                .overlay(Rectangle().strokeBorder(fill == .clear ? Brand.rule : fill, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .help(help)
    }
}

private struct TakeRow: View {
    let summary: TakeSummary
    let deletable: Bool
    let reveal: () -> Void
    let askDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Rectangle().fill(summary.tint).frame(width: 6, height: 6)
                Text(summary.when).font(Brand.digits(13, 700)).foregroundStyle(Brand.bone)
                Spacer()
                if let fraction = summary.fraction, summary.progress?.recording == false {
                    Text("\(Int(fraction * 100))%").font(Brand.digits(13, 700)).foregroundStyle(Brand.bone)
                }
                if summary.finished {
                    Button(action: reveal) {
                        Caption(text: "Show", colour: Brand.bone)
                            .padding(.horizontal, 10)
                            .frame(height: 24)
                            .overlay(Rectangle().strokeBorder(Brand.rule, lineWidth: 1))
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(PressStyle())
                    .help("Show in Finder")
                }
                Button(action: askDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(Brand.bone)
                        .frame(width: 28, height: 24)
                        .overlay(Rectangle().strokeBorder(Brand.rule, lineWidth: 1))
                        .contentShape(Rectangle())
                }
                .buttonStyle(PressStyle())
                .disabled(!deletable)
                .opacity(deletable ? 1 : 0.35)
                .help(deletable ? "Delete this take" : "This take is still being recorded or checked")
                .accessibilityLabel("Delete take from \(summary.when)")
            }
            if !summary.finished {
                Text(summary.title).font(Brand.font(12, 600)).foregroundStyle(Brand.bone)
                ProgressRule(fraction: summary.progress?.checking == true ? nil : summary.fraction, tint: summary.tint)
            }
            Text(summary.detail)
                .font(Brand.digits(11.5, 500))
                .foregroundStyle(Brand.grey)
                .lineLimit(3)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(14)
        .help(summary.take.warnings.joined(separator: "\n"))
        .accessibilityElement(children: .contain)
    }
}

/// The single line under the record button: what stops a take, what is on its way, or the last one.
struct StatusLine: View {
    @ObservedObject var model: MacModel
    @ObservedObject var mic: MicMonitor
    @Environment(\.unit) private var u

    var body: some View {
        HStack(spacing: 8 * u) {
            content
        }
        .padding(.horizontal, 12 * u)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .overlay(alignment: .top) {
            if let sending {
                ProgressRule(fraction: sending.progress?.checking == true ? nil : sending.fraction, tint: sending.tint)
                    .offset(y: -1)
            }
        }
    }

    /// The take still on its way, if any.
    private var sending: TakeSummary? {
        model.takes.first { model.progress[$0.take] != nil && $0.status != .ready }.map(summary)
    }

    private func summary(_ take: TakeRecord) -> TakeSummary {
        TakeSummary(take: take, progress: model.progress[take.take], linked: model.linked)
    }

    @ViewBuilder private var content: some View {
        if model.leaving {
            line("Disconnecting when the take has arrived")
            Spacer(minLength: 0)
            if let left = sending?.timeLeft { Caption(text: left, size: 9.5 * u) }
        } else if model.disconnected {
            line("Disconnected from the iPhone", colour: Brand.grey)
            Spacer(minLength: 0)
            action("Connect", help: "Open Clapless on the iPhone first") { model.connect() }
        } else if model.phase == .idle, let blocker = model.deviceBlocker {
            line(blocker, colour: Brand.amber)
        } else if model.phase != .idle {
            line(model.recordScreen ? "Recording camera, mic and \(model.screenName)" : "Recording camera and mic")
        } else if let sending, !sending.troubled {
            let share = sending.progress?.recording == false ? sending.fraction.map { " \(Int($0 * 100))%" } : nil
            line("\(sending.title)\(share ?? "")", colour: sending.tint)
            Spacer(minLength: 0)
            if let left = sending.timeLeft { Caption(text: left, size: 9.5 * u) }
        } else if model.lensThanks {
            line("Lens wiped", colour: Brand.green)
        } else if model.linked, !model.lensReminded {
            line("Wipe the iPhone lens")
            Spacer(minLength: 0)
            action("Done", help: "Click once it is clean") { model.lensReminded = true }
        } else if let note = mic.standInNote {
            line(note, colour: Brand.grey)
        } else if let take = model.takes.first {
            let last = summary(take)
            line(last.troubled ? last.detail : "\(last.when) · \(last.syncWords ?? last.title)",
                 colour: last.troubled ? Brand.red : Brand.grey)
            Spacer(minLength: 0)
            if last.finished { action("Show", help: "Show in Finder") { model.reveal(take) } }
        } else {
            line("Record asks what to capture", colour: Brand.grey)
        }
    }

    private func line(_ text: String, colour: Color = Brand.bone) -> some View {
        Text(text)
            .font(Brand.digits(11 * u, 500))
            .foregroundStyle(colour)
            .lineLimit(1)
            .truncationMode(.tail)
            .help(text)
    }

    private func action(_ title: String, help: String, run: @escaping () -> Void) -> some View {
        Button(action: run) {
            Caption(text: title, size: 9.5 * u, colour: Brand.bone)
                .padding(.horizontal, 8 * u)
                .frame(height: 19 * u)
                .overlay(Rectangle().strokeBorder(Brand.rule, lineWidth: 1))
                .contentShape(Rectangle())
        }
        .buttonStyle(PressStyle())
        .help(help)
    }
}

/// A two-point bar, or a travelling one when there is no number to show.
private struct ProgressRule: View {
    let fraction: Double?
    let tint: Color
    @Environment(\.accessibilityReduceMotion) private var still

    var body: some View {
        GeometryReader { bar in
            ZStack(alignment: .leading) {
                Rectangle().fill(Brand.rule)
                if let fraction {
                    Rectangle().fill(tint)
                        .frame(width: max(5, bar.size.width * fraction))
                        .animation(.linear(duration: 0.25), value: fraction)
                } else {
                    TimelineView(.animation(paused: still)) { time in
                        let phase = still ? 0.35 : time.date.timeIntervalSinceReferenceDate.truncatingRemainder(dividingBy: 1.2) / 1.2
                        Rectangle().fill(tint)
                            .frame(width: bar.size.width * 0.3)
                            .offset(x: bar.size.width * (phase * 1.3 - 0.3))
                    }
                }
            }
            .clipped()
        }
        .frame(height: 2)
        .accessibilityElement()
        .accessibilityLabel("Progress")
        .accessibilityValue(fraction.map { "\(Int($0 * 100)) percent" } ?? "working")
    }
}
