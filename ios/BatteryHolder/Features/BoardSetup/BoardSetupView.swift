import SwiftUI

/// Pick the board you're using and the transport you'll talk to it over.
struct BoardSetupView: View {
    @EnvironmentObject var appState: AppState

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Theme.spacing.lg) {
                SectionHeader(title: "Choose your board",
                              subtitle: "Pick the module you wired the battery to.")

                ForEach(appState.boards) { board in
                    boardCard(board)
                }

                if let board = appState.selectedBoard {
                    transportSection(for: board)
                    NavigationLink {
                        PinConfigView()
                    } label: {
                        Text("Configure pins")
                    }
                    .buttonStyle(PrimaryButtonStyle())
                    .padding(.top, Theme.spacing.sm)
                }
            }
            .padding(Theme.spacing.lg)
        }
        .background(Theme.color.background)
        .navigationTitle("Setup")
    }

    private func boardCard(_ board: Board) -> some View {
        let isSelected = appState.selectedBoard?.id == board.id
        return Button {
            appState.selectBoard(board)
        } label: {
            Card {
                HStack(alignment: .top, spacing: Theme.spacing.md) {
                    VStack(alignment: .leading, spacing: Theme.spacing.xs) {
                        Text(board.name).font(Theme.font.headline)
                            .foregroundStyle(Theme.color.textPrimary)
                        Text(board.chip.displayName).font(Theme.font.caption)
                            .foregroundStyle(Theme.color.brand)
                        Text(board.summary).font(Theme.font.footnote)
                            .foregroundStyle(Theme.color.textSecondary)
                        HStack(spacing: Theme.spacing.xs) {
                            ForEach(board.supportedTransports) { TransportBadge(transport: $0) }
                        }
                        .padding(.top, Theme.spacing.xxs)
                    }
                    Spacer()
                    Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(isSelected ? Theme.color.brand : Theme.color.border)
                        .font(.title2)
                }
            }
        }
        .buttonStyle(.plain)
    }

    private func transportSection(for board: Board) -> some View {
        VStack(alignment: .leading, spacing: Theme.spacing.sm) {
            SectionHeader(title: "Transport",
                          subtitle: "How the app talks to this board.")
            Picker("Transport", selection: $appState.activeTransport) {
                ForEach(board.supportedTransports) { t in
                    Text(t.displayName).tag(t)
                }
            }
            .pickerStyle(.segmented)
        }
    }
}

#if DEBUG
struct BoardSetupView_Previews: PreviewProvider {
    static var previews: some View {
        Group {
            NavigationStack { BoardSetupView() }
                .environmentObject(AppState.preview)
                .previewDisplayName("Board selected")

            NavigationStack { BoardSetupView() }
                .environmentObject(AppState.previewEmpty)
                .previewDisplayName("Nothing selected")

            NavigationStack { BoardSetupView() }
                .environmentObject(AppState.preview)
                .preferredColorScheme(.dark)
                .previewDisplayName("Dark")
        }
        .tint(Theme.color.brand)
    }
}
#endif
