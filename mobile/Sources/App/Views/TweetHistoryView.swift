import SwiftUI
import SwiftData
import UIKit

struct TweetHistoryView: View {
    @Query(sort: \TweetConversation.updatedAt, order: .reverse)
    private var conversations: [TweetConversation]

    @EnvironmentObject private var routeStore: TweetAppRouteStore
    @EnvironmentObject private var jobSyncStore: TweetGenerationSyncStore

    @State private var searchText = ""
    @State private var showSettings = false

    private var filtered: [TweetConversation] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !query.isEmpty else { return conversations }

        return conversations.filter { conversation in
            conversation.sourceTweetText.lowercased().contains(query)
            || conversation.sourceTweetURL.lowercased().contains(query)
            || (conversation.latestVersion?.contentES.lowercased().contains(query) ?? false)
            || (conversation.latestVersion?.contentEN.lowercased().contains(query) ?? false)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if filtered.isEmpty {
                    emptyState
                } else {
                    List {
                        ForEach(filtered) { conversation in
                            Button {
                                routeStore.presentConversation(conversation)
                            } label: {
                                ConversationRow(
                                    conversation: conversation,
                                    jobSnapshot: jobSyncStore.latestJob(conversationID: conversation.id)
                                )
                            }
                            .buttonStyle(.plain)
                            .listRowBackground(Color.clear)
                            .listRowSeparator(.hidden)
                        }
                    }
                    .listStyle(.plain)
                    .scrollContentBackground(.hidden)
                }
            }
            .background(AppTheme.background.ignoresSafeArea())
            .navigationTitle("Tweet Sessions")
            .searchable(text: $searchText, prompt: "Search in history")
            .toolbar {
                ToolbarItem(placement: .topBarLeading) {
                    PasteButton(payloadType: String.self) { strings in
                        routeStore.importTweetFromPastedStrings(strings)
                    }
                    .labelStyle(.iconOnly)
                    .tint(AppTheme.accent)
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button {
                        showSettings = true
                    } label: {
                        Image(systemName: "gearshape")
                    }
                }
            }
        }
        .tint(AppTheme.accent)
        .preferredColorScheme(.light)
        .sheet(isPresented: $showSettings) {
            TweetSettingsView()
        }
        .fullScreenCover(item: $routeStore.presentedComposer) { presentation in
            ShareTweetGeneratorView(
                tweetURL: presentation.tweetURL,
                initialTweetText: presentation.initialTweetText,
                initialConversationID: presentation.conversationID,
                hostMode: .app,
                onClose: { routeStore.dismissComposer() }
            )
        }
        .onAppear(perform: presentPendingConversationIfNeeded)
        .onChange(of: routeStore.pendingConversationID) { _, _ in
            presentPendingConversationIfNeeded()
        }
        .onChange(of: conversations.count) { _, _ in
            presentPendingConversationIfNeeded()
        }
    }

    private var emptyState: some View {
        VStack(spacing: 14) {
            Image(systemName: "bubble.left.and.bubble.right")
                .font(.system(size: 32, weight: .semibold))
                .foregroundStyle(AppTheme.inkMuted)

                Text("Sin sesiones")
                .font(.system(size: 18, weight: .semibold, design: .rounded))
                .foregroundStyle(AppTheme.ink)

            Text("Copiá un link de X para empezar.")
                .font(.system(size: 14, weight: .regular, design: .rounded))
                .foregroundStyle(AppTheme.inkSoft)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 280)

            Button {
                routeStore.importTweetFromPasteboardManually()
            } label: {
                Label("Usar link", systemImage: "link.badge.plus")
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(AppTheme.ink)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 11)
                    .background(AppTheme.cardSurface, in: Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(24)
    }

    private func presentPendingConversationIfNeeded() {
        guard let pendingConversationID = routeStore.pendingConversationID,
              let conversation = conversations.first(where: { $0.id == pendingConversationID }) else {
            return
        }

        routeStore.presentConversation(conversation)
    }
}

private enum TweetGeneratorModelPreference: String, CaseIterable, Identifiable {
    case claudeOpus
    case claudeSonnet

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .claudeOpus:
            return "Opus"
        case .claudeSonnet:
            return "Sonnet"
        }
    }
}

private enum TweetGeneratorPreferences {
    static let defaultsKey = "TweetGenerator.DefaultModel"

    static func loadModel() -> TweetGeneratorModelPreference {
        let defaults = UserDefaults(suiteName: SharedInbox.appGroupId)
        guard let raw = defaults?.string(forKey: defaultsKey),
              let model = TweetGeneratorModelPreference(rawValue: raw) else {
            return .claudeOpus
        }
        return model
    }

    static func saveModel(_ model: TweetGeneratorModelPreference) {
        let defaults = UserDefaults(suiteName: SharedInbox.appGroupId)
        defaults?.set(model.rawValue, forKey: defaultsKey)
    }
}

private struct TweetSettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var selectedModel: TweetGeneratorModelPreference = TweetGeneratorPreferences.loadModel()

    var body: some View {
        NavigationStack {
            Form {
                Section("Tweet Generator") {
                    Picker("Default model", selection: $selectedModel) {
                        ForEach(TweetGeneratorModelPreference.allCases) { model in
                            Text(model.displayName).tag(model)
                        }
                    }
                    .pickerStyle(.segmented)

                    Text("This model is used by default when generating from the share extension.")
                        .font(.system(size: 12, weight: .regular, design: .rounded))
                        .foregroundStyle(.secondary)
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") {
                        dismiss()
                    }
                }
            }
        }
        .onChange(of: selectedModel) { _, newValue in
            TweetGeneratorPreferences.saveModel(newValue)
        }
    }
}

private struct ConversationRow: View {
    let conversation: TweetConversation
    let jobSnapshot: TweetGenerationJobSnapshot?

    private var isUnread: Bool {
        TweetConversationReadStore.isUnread(conversation: conversation)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 10) {
                Text(conversation.sourcePreview)
                    .font(.system(size: 14, weight: .medium, design: .rounded))
                    .foregroundStyle(AppTheme.ink)
                    .lineLimit(3)

                Spacer()

                if isUnread {
                    Circle()
                        .fill(AppTheme.accent)
                        .frame(width: 9, height: 9)
                        .padding(.top, 5)
                }
            }

            HStack(spacing: 8) {
                Label("\(conversation.versionsCount)", systemImage: "clock.arrow.circlepath")
                Text(conversation.formattedUpdatedAt)
                if let jobSnapshot, shouldShowJobBadge(for: jobSnapshot) {
                    Label(jobSnapshot.status.displayLabel, systemImage: jobSnapshot.status.systemImageName)
                        .foregroundStyle(jobTint(for: jobSnapshot.status))
                }
                if isUnread {
                    Text("New")
                        .foregroundStyle(AppTheme.accent)
                }
                Spacer()
            }
            .font(.system(size: 11, weight: .medium, design: .rounded))
            .foregroundStyle(AppTheme.inkMuted)
        }
        .padding(14)
        .background(AppTheme.cardSurface, in: Rectangle())
    }

    private func jobTint(for status: TweetGenerationJobStatus) -> Color {
        switch status {
        case .queued:
            return AppTheme.inkMuted
        case .running:
            return AppTheme.accent
        case .completed:
            return AppTheme.inkMuted
        case .failed:
            return Color.red.opacity(0.8)
        case .cancelled:
            return AppTheme.inkMuted
        }
    }

    private func shouldShowJobBadge(for job: TweetGenerationJobSnapshot) -> Bool {
        switch job.status {
        case .queued, .running:
            return true
        case .failed:
            return conversation.versionsCount == 0
        case .completed, .cancelled:
            return false
        }
    }
}

private struct TweetConversationDetailView: View {
    let conversationId: UUID

    @Environment(\.modelContext) private var modelContext

    @State private var showDeleteAlert = false

    private var conversation: TweetConversation? {
        let descriptor = FetchDescriptor<TweetConversation>(
            predicate: #Predicate<TweetConversation> { item in
                item.id == conversationId
            }
        )
        return try? modelContext.fetch(descriptor).first
    }

    private var versions: [TweetVersion] {
        conversation?.sortedVersionsDescending ?? []
    }

    var body: some View {
        Group {
            if let conversation {
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        sourceCard(conversation)

                        ForEach(versions) { version in
                            versionCard(version)
                        }
                    }
                    .padding(.horizontal, 16)
                    .padding(.top, 12)
                    .padding(.bottom, 20)
                }
                .background(AppTheme.background.ignoresSafeArea())
                .navigationTitle("Session")
                .toolbar {
                    ToolbarItem(placement: .topBarTrailing) {
                        Button(role: .destructive) {
                            showDeleteAlert = true
                        } label: {
                            Image(systemName: "trash")
                        }
                    }
                }
                .alert("Delete Session", isPresented: $showDeleteAlert) {
                    Button("Delete", role: .destructive) {
                        deleteConversation(conversation)
                    }
                    Button("Cancel", role: .cancel) { }
                } message: {
                    Text("Borra toda la sesión.")
                }
            } else {
                Text("Session not found")
                    .foregroundStyle(AppTheme.inkMuted)
            }
        }
        .preferredColorScheme(.light)
    }

    private func sourceCard(_ conversation: TweetConversation) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("ORIGINAL TWEET")
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .foregroundStyle(AppTheme.inkMuted)
                .tracking(1.0)

            Text(conversation.sourceTweetText)
                .font(.system(size: 15, weight: .regular, design: .serif))
                .foregroundStyle(AppTheme.ink)
                .lineSpacing(4)
                .textSelection(.enabled)

            Text(conversation.sourceTweetURL)
                .font(.system(size: 11, weight: .regular, design: .rounded))
                .foregroundStyle(AppTheme.inkMuted)
                .textSelection(.enabled)
        }
        .padding(14)
        .background(AppTheme.cardSurface, in: Rectangle())
    }

    private func versionCard(_ version: TweetVersion) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(version.createdAt.formatted(date: .abbreviated, time: .shortened))
                    .font(.system(size: 11, weight: .medium, design: .rounded))
                    .foregroundStyle(AppTheme.inkMuted)

                Spacer()

                Text(version.modeRawValue.uppercased())
                    .font(.system(size: 10, weight: .semibold, design: .rounded))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(AppTheme.ink.opacity(0.08), in: Rectangle())
            }

            if let intention = version.intention, !intention.isEmpty {
                labeledText(label: "Intention", value: intention)
            }

            if let feedback = version.feedback, !feedback.isEmpty {
                labeledText(label: "Feedback", value: feedback)
            }

            VStack(alignment: .leading, spacing: 6) {
                labeledText(label: "Draft ES", value: version.contentES)
                copyRow(text: version.contentES)
            }

            VStack(alignment: .leading, spacing: 6) {
                labeledText(label: "Draft EN", value: version.contentEN)
                copyRow(text: version.contentEN)
            }
        }
        .padding(14)
        .background(AppTheme.cardSurface, in: Rectangle())
    }

    private func labeledText(label: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(label.uppercased())
                .font(.system(size: 10, weight: .semibold, design: .rounded))
                .foregroundStyle(AppTheme.inkMuted)
            Text(value)
                .font(.system(size: 14, weight: .regular, design: .rounded))
                .foregroundStyle(AppTheme.ink)
                .textSelection(.enabled)
        }
    }

    private func copyRow(text: String) -> some View {
        HStack {
            Spacer()
            Button {
                UIPasteboard.general.string = text
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                    .foregroundStyle(AppTheme.inkSoft)
            }
            .buttonStyle(.plain)
        }
    }

    private func deleteConversation(_ conversation: TweetConversation) {
        modelContext.delete(conversation)
        try? modelContext.save()
    }
}
