import SwiftUI
import DAPSync

/// Live progress while `SyncEngine.apply` runs, then its report. Per-file
/// failures are shown alongside the successes rather than collapsing the
/// whole run into "failed" — one bad file doesn't stop the rest.
struct SyncView: View {
    @Bindable var model: AppModel
    @Binding var step: RootView.Step?

    var body: some View {
        Group {
            switch model.syncState {
            case .idle:
                ContentUnavailableView {
                    Label("Nothing syncing", systemImage: "arrow.triangle.2.circlepath")
                } description: {
                    Text("Review a plan and start a sync to see its progress here.")
                }

            case .syncing(let progress):
                syncingView(progress)

            case .done(let report):
                reportView(report)

            case .failed(let message):
                ContentUnavailableView {
                    Label("Sync failed", systemImage: "xmark.octagon")
                } description: {
                    Text(message)
                } actions: {
                    Button("Dismiss") { model.acknowledgeSyncResult() }
                }
            }
        }
        .navigationTitle("Sync")
    }

    private func syncingView(_ progress: SyncProgress) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            if let plan = model.plan {
                let overall = SyncOverallProgress(plan: plan, progress: progress)
                VStack(alignment: .leading, spacing: 6) {
                    Text("Overall").font(.headline)
                    ProgressView(value: overall.fraction)
                    HStack {
                        Text(overall.unitsTotal > 0 ? "\(overall.unitsDone) of \(overall.unitsTotal) files" : "Preparing")
                        Spacer()
                        if overall.bytesTotal > 0 {
                            Text("\(Formatting.bytes(overall.bytesDone)) of \(Formatting.bytes(overall.bytesTotal))")
                        }
                    }
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text(phaseTitle(progress.phase)).font(.subheadline)
                if case .copying = progress.phase, progress.bytesTotal > 0 {
                    ProgressView(value: Double(progress.bytesCopied), total: Double(progress.bytesTotal))
                    Text("\(Formatting.bytes(progress.bytesCopied)) of \(Formatting.bytes(progress.bytesTotal))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    ProgressView().progressViewStyle(.linear)
                }
                if let file = progress.currentFile {
                    Text(file).font(.caption).foregroundStyle(.secondary).lineLimit(1)
                }
            }

            Button("Cancel", role: .destructive) { model.cancelSync() }
        }
        .padding()
        .frame(maxWidth: 460)
    }

    private func reportView(_ report: SyncReport) -> some View {
        Form {
            Section {
                LabeledContent("Added", value: "\(report.added.count)")
                LabeledContent("Removed", value: "\(report.removed.count)")
                if report.cancelled {
                    Label("Cancelled before finishing", systemImage: "stop.circle")
                        .foregroundStyle(.orange)
                }
            }

            if let backup = report.backup {
                Section("Backup") {
                    Text(backup.directoryURL.path)
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                    Text("The previous database was saved here before anything was written. Audio files are not backed up.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            if !report.failures.isEmpty {
                Section("Failures (\(report.failures.count))") {
                    ForEach(Array(report.failures.enumerated()), id: \.offset) { _, failure in
                        VStack(alignment: .leading, spacing: 2) {
                            Text(failure.sourceFileURL?.lastPathComponent ?? "Removal")
                            Text(failure.message).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .safeAreaInset(edge: .bottom) {
            HStack {
                Button("Return to Library") {
                    model.acknowledgeSyncResult()
                    step = .localLibrary
                }
                Button("Done") {
                    model.acknowledgeSyncResult()
                    step = .device
                }
                .buttonStyle(.borderedProminent)
            }
            .padding()
        }
    }

    private func phaseTitle(_ phase: SyncProgress.Phase) -> String {
        switch phase {
        case .backingUp: return "Backing up the database…"
        case .parsingDatabase: return "Reading the DAP's database…"
        case .copying(let index, let total): return "Copying \(index + 1) of \(total)"
        case .removing(let index, let total): return "Removing \(index + 1) of \(total)"
        case .writingDatabase: return "Writing the database…"
        }
    }
}
