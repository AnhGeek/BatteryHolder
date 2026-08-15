import SwiftUI
import UniformTypeIdentifiers

/// Flash firmware to the board over the air — from the cloud catalog or a local file.
struct FlashView: View {
    @EnvironmentObject var appState: AppState
    @State private var firmware: [FirmwareImage] = []
    @State private var loadError: String?
    @State private var isLoading = false
    @State private var showingImporter = false
    @State private var flashError: String?

    var body: some View {
        Group {
            if let board = appState.selectedBoard {
                content(board: board)
            } else {
                ContentUnavailableViewCompat(
                    title: "No board selected",
                    message: "Choose a board on the Setup tab first.",
                    systemImage: "arrow.down.circle")
            }
        }
        .background(Theme.color.background)
        .navigationTitle("Flash")
        .fileImporter(isPresented: $showingImporter,
                      allowedContentTypes: [UTType(filenameExtension: "bin") ?? .data]) { result in
            handleImport(result)
        }
    }

    private func content(board: Board) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.spacing.lg) {
                FlashProgressCard(flasher: appState.flasher, transport: appState.activeTransport)

                SectionHeader(title: "Cloud builds", subtitle: "Firmware for \(board.name)")
                if isLoading {
                    ProgressView().frame(maxWidth: .infinity)
                } else if let loadError {
                    Callout(text: loadError, tint: Theme.color.warning, icon: "icloud.slash")
                } else if firmware.isEmpty {
                    Callout(text: "No builds found. Configure your backend in AppConfig, or flash a local file below.",
                            tint: Theme.color.brand, icon: "info.circle.fill")
                } else {
                    ForEach(firmware) { image in
                        firmwareRow(image)
                    }
                }

                Divider().padding(.vertical, Theme.spacing.sm)

                SectionHeader(title: "Local file", subtitle: "Flash a .bin from your phone")
                Button { showingImporter = true } label: {
                    Label("Choose .bin file", systemImage: "folder")
                }
                .buttonStyle(SecondaryButtonStyle())

                if let flashError {
                    Callout(text: flashError, tint: Theme.color.danger, icon: "xmark.octagon.fill")
                }
            }
            .padding(Theme.spacing.lg)
        }
        .task { await loadFirmware(board: board) }
    }

    private func firmwareRow(_ image: FirmwareImage) -> some View {
        Card {
            VStack(alignment: .leading, spacing: Theme.spacing.sm) {
                HStack {
                    Text("v\(image.version)").font(Theme.font.headline)
                        .foregroundStyle(Theme.color.textPrimary)
                    Text(image.channel.rawValue).font(Theme.font.caption)
                        .padding(.horizontal, Theme.spacing.sm).padding(.vertical, 2)
                        .background(Theme.color.accent.opacity(0.15))
                        .foregroundStyle(Theme.color.accent)
                        .clipShape(Capsule())
                    Spacer()
                    Text(image.sizeDisplay).font(Theme.font.caption)
                        .foregroundStyle(Theme.color.textSecondary)
                }
                if !image.releaseNotes.isEmpty {
                    Text(image.releaseNotes).font(Theme.font.footnote)
                        .foregroundStyle(Theme.color.textSecondary)
                }
                Button {
                    Task { await flashCloud(image) }
                } label: {
                    Text("Flash over \(appState.activeTransport.displayName)")
                }
                .buttonStyle(PrimaryButtonStyle())
                .disabled(appState.flasher.progress.isActive)
            }
        }
    }

    // MARK: Actions

    private func loadFirmware(board: Board) async {
        isLoading = true; loadError = nil
        do {
            firmware = try await appState.firmwareRepo.listFirmware(boardId: board.id)
        } catch {
            loadError = "Couldn't reach the firmware catalog. \(error.localizedDescription)"
        }
        isLoading = false
    }

    private func flashCloud(_ image: FirmwareImage) async {
        flashError = nil
        do { try await appState.flash(image) }
        catch { flashError = error.localizedDescription }
    }

    private func handleImport(_ result: Result<URL, Error>) {
        flashError = nil
        do {
            let url = try result.get()
            guard url.startAccessingSecurityScopedResource() else { return }
            defer { url.stopAccessingSecurityScopedResource() }
            let data = try Data(contentsOf: url)
            Task {
                do { try await appState.flasher.flash(data: data, over: appState.activeTransport) }
                catch { flashError = error.localizedDescription }
            }
        } catch {
            flashError = error.localizedDescription
        }
    }
}

/// Observes the flasher and renders live OTA progress.
private struct FlashProgressCard: View {
    @ObservedObject var flasher: FirmwareFlasher
    let transport: FlashTransport

    var body: some View {
        let p = flasher.progress
        return Card {
            VStack(alignment: .leading, spacing: Theme.spacing.sm) {
                HStack {
                    SectionHeader(title: "Update status", subtitle: statusText(p))
                    Spacer()
                    TransportBadge(transport: transport)
                }
                if p.isActive || p.fraction > 0 {
                    ProgressView(value: p.fraction)
                        .tint(Theme.color.brand)
                    Text("\(Int(p.fraction * 100))%").font(Theme.font.caption)
                        .foregroundStyle(Theme.color.textSecondary)
                }
            }
        }
    }

    private func statusText(_ p: FlashProgress) -> String {
        switch p.phase {
        case .idle: return "Idle"
        case .preparing: return "Preparing…"
        case .uploading: return "Uploading…"
        case .verifying: return "Verifying…"
        case .rebooting: return "Rebooting…"
        case .done: return "Complete"
        case .failed(let m): return m
        }
    }
}
