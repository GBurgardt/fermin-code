import SwiftUI
import SwiftData
import UIKit
import Combine
import AVFoundation

// MARK: - Design Constants
// Cambio #1 — Color: warm off-white background instead of cold gray
// Cambio #2 — Color: warm white cards instead of pure white
// Cambio #3 — Color: near-black with subtle blue undertone for depth

private enum S {
    // Cambio #1 — warm off-white replaces Color(white: 0.965).
    // The red/green/blue channels add warmth that pure gray lacks.
    // This creates the feeling of high-quality paper, not a screen.
    static let bg      = Color(red: 0.975, green: 0.965, blue: 0.950)

    // Cambio #2 — warm white replaces Color.white.
    // Cards belong to the ecosystem instead of floating cold on warm bg.
    static let card    = Color(red: 0.995, green: 0.988, blue: 0.978)

    // Cambio #3 — near-black with imperceptible blue undertone.
    // Creates depth that flat black (0.05) cannot achieve.
    static let ink     = Color(red: 0.12, green: 0.12, blue: 0.14)

    static let mid     = Color(white: 0.30)
    static let hint    = Color(white: 0.45)        // Cambio #8 — slightly lighter hint for better placeholder contrast
    static let field   = Color(white: 0.935)
    static let chip    = Color(white: 0.91)         // Slightly more visible chip bg
    static let danger  = Color(red: 0.85, green: 0.25, blue: 0.20)  // Cambio #4 — softer, more intentional red
    // Cambio4B #2 — amber desaturado, mas natural, menos señal de transito
    static let amber   = Color(red: 0.78, green: 0.62, blue: 0.22)
    // Cambio4B #18 — source row shadow: minimal elevation, subordinate
    static let shadow  = Color.black.opacity(0.03)
    // Cambio4B #19 — draft area shadow: dominant elevation, protagonist
    static let shadowDraft = Color.black.opacity(0.12)
    static let focusStroke = Color(white: 0.05).opacity(0.35)
    static let focusShadow = Color.black.opacity(0.12)
    // Cambio4B #1 — CTA blue refined: 2% mas saturado, 4% mas luminoso. Pide ser tocado.
    static let cta     = Color(red: 0.20, green: 0.55, blue: 0.92)
    // Cambio4B #3 — success green para feedback positivo con personalidad
    static let success = Color(red: 0.15, green: 0.58, blue: 0.42)
}

// MARK: - Haptic Helpers
// Cambio #24, #25, #26 — Centralized haptic feedback

private enum Haptic {
    // Cambio #24 — light impact for Generate button
    static func light() {
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
    }
    // Cambio #25 — soft impact for Copy action
    static func soft() {
        UIImpactFeedbackGenerator(style: .soft).impactOccurred()
    }
    // Cambio #26 — selection feedback for version switching
    static func selection() {
        UISelectionFeedbackGenerator().selectionChanged()
    }
    // Cambio4B #21 — medium impact for Reply on X. You FEEL you're about to publish.
    static func medium() {
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }
    static func success() {
        UINotificationFeedbackGenerator().notificationOccurred(.success)
    }
    static func warning() {
        UINotificationFeedbackGenerator().notificationOccurred(.warning)
    }
    // Cambio4B #30 — triple light haptic with 80ms delay for first-generation delight
    static func confetti() {
        let gen = UIImpactFeedbackGenerator(style: .light)
        gen.impactOccurred()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.08) { gen.impactOccurred() }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.16) { gen.impactOccurred() }
    }
}

// MARK: - Bouncing Dots Loader
// Cambio #28 — Custom bouncing dots replaces generic ProgressView.
// Three dots pulse with staggered delays, creating a "thinking" personality.

private struct BouncingDotsView: View {
    @State private var animate = false

    var body: some View {
        // Cambio4B #12 — dots reduced from 7pt/6sp to 6pt/5sp: more subtle, more delicate
        HStack(spacing: 5) {
            ForEach(0..<3, id: \.self) { index in
                Circle()
                    .fill(S.ink.opacity(animate ? 0.8 : 0.25))
                    .frame(width: 6, height: 6)
                    .animation(
                        .easeInOut(duration: 0.45)
                        .repeatForever(autoreverses: true)
                        .delay(Double(index) * 0.15),
                        value: animate
                    )
            }
        }
        .onAppear { animate = true }
    }
}

// MARK: - Shimmer Effect
// Cambio #30 — Single-pass shimmer that sweeps left-to-right when generation completes.
// A gradient highlight moves across the draft card once, celebrating completion.

private struct ShimmerModifier: ViewModifier {
    let active: Bool
    @State private var phase: CGFloat = -1

    func body(content: Content) -> some View {
        content
            .overlay(
                GeometryReader { geo in
                    if active {
                        // Cambio4B #11 — shimmer opacity from 0.15 to 0.08: a whisper of light
                        LinearGradient(
                            colors: [
                                Color.clear,
                                Color.white.opacity(0.08),
                                Color.clear
                            ],
                            startPoint: .leading,
                            endPoint: .trailing
                        )
                        // The gradient is narrow (30% of width) for a focused beam effect
                        .frame(width: geo.size.width * 0.3)
                        .offset(x: phase * geo.size.width)
                        .clipShape(RoundedRectangle(cornerRadius: 20, style: .continuous))
                    }
                }
            )
            .onChange(of: active) { _, isActive in
                if isActive {
                    // Start off-screen left
                    phase = -0.3
                    // Cambio4B #10 — 400ms: faster = more subliminal = more premium
                    withAnimation(.easeInOut(duration: 0.4)) {
                        phase = 1.3
                    }
                }
            }
    }
}

// MARK: - Custom Chip Picker
// Cambio #23 — Replaces system segmented controls with custom chips.
// All controls now speak the same visual language: capsules with consistent styling.

private struct ChipPicker<T: Hashable & Identifiable>: View where T: CaseIterable, T.AllCases: RandomAccessCollection {
    let selection: Binding<T>
    let label: (T) -> String

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(T.allCases)) { option in
                Button {
                    // Cambio #26 — haptic on selection change
                    Haptic.selection()
                    withAnimation(.easeInOut(duration: 0.2)) {
                        selection.wrappedValue = option
                    }
                } label: {
                    Text(label(option))
                        .font(.system(size: 12, weight: .semibold, design: .rounded))
                        // Selected: white on dark. Unselected: ink with reduced opacity.
                        .foregroundStyle(selection.wrappedValue == option ? .white : S.ink.opacity(0.55))
                        // Iter3: slightly larger chips — 13h/8v for better touch targets
                        .padding(.horizontal, 13)
                        .padding(.vertical, 8)
                        .background(
                            selection.wrappedValue == option ? S.ink : S.chip,
                            in: Capsule()
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Version Tooltip
// Cambio #32 — Long press on version pill shows ephemeral tooltip with metadata.

private struct VersionTooltip: View {
    let model: String?
    let date: Date

    private var dateFormatted: String {
        let f = DateFormatter()
        f.dateStyle = .short
        f.timeStyle = .short
        return f.string(from: date)
    }

    var body: some View {
        VStack(spacing: 2) {
            if let model {
                Text(model)
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
            }
            Text(dateFormatted)
                .font(.system(size: 10, weight: .regular, design: .rounded))
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        // Cambio4B #32 — tooltip: lighter (0.78), rounder (12). Floats. Feels ephemeral.
        .background(S.ink.opacity(0.78), in: RoundedRectangle(cornerRadius: 12, style: .continuous))
    }
}

// MARK: - Main View

struct ShareTweetGeneratorView: View {
    let tweetURL: String
    let initialTweetText: String
    let initialConversationID: UUID?
    let hostMode: HostMode
    let onClose: () -> Void
    let onRequestVoiceRedirect: ((VoiceRedirectPayload) async throws -> Void)?

    @Environment(\.modelContext) private var modelContext
    @Environment(\.openURL) private var openURL
    @Environment(\.scenePhase) private var scenePhase
    @EnvironmentObject private var jobSyncStore: TweetGenerationSyncStore

    enum HostMode {
        case shareExtension
        case app
    }

    struct VoiceRedirectPayload {
        let tweetURL: String
        let initialTweetText: String
    }

    private enum Lang: String, CaseIterable, Identifiable {
        case es = "ES", en = "EN"
        var id: String { rawValue }
    }

    private enum Mode: String, CaseIterable, Identifiable {
        case reply, quote
        var id: String { rawValue }
        var label: String { rawValue.capitalized }
    }

    private enum PromptInputMode: String, CaseIterable, Identifiable {
        case voice
        case text

        var id: String { rawValue }

        var label: String {
            switch self {
            case .voice:
                return "Mic"
            case .text:
                return "Write"
            }
        }

        var icon: String {
            switch self {
            case .voice:
                return "mic.fill"
            case .text:
                return "text.alignleft"
            }
        }
    }

    private enum LineBreakMode: String, CaseIterable, Identifiable {
        case single = "1x", double = "2x"
        var id: String { rawValue }
    }

    private enum DraftCountOption: Int, CaseIterable, Identifiable {
        case one = 1
        case three = 3
        case four = 4

        var id: Int { rawValue }
        var label: String { "\(rawValue)x" }
    }

    private struct Ver: Identifiable {
        let id: UUID
        let num: Int
        let createdAt: Date
        let mode: Mode
        let intention: String?
        let feedback: String?
        let modelRawValue: String?
        let usedFullThread: Bool
        let sourceSnapshot: String
        let es: String
        let en: String
    }

    private struct PersistedConversationSnapshot {
        let id: UUID
        let sourceTweetText: String
        let lastModeRawValue: String
        let lastIntention: String?
        let versions: [Ver]
        let latestVersionID: UUID?
    }

    private struct GenerationRequest {
        let intention: String?
        let feedback: String?
        let previousDraft: String?
        let notes: String?
        let draftCount: Int
        let variationSeed: String
    }

    private enum InputField: Hashable {
        case intention
        case refine
    }

    @State private var service = ShareTweetGenerationService()
    @State private var mode: Mode = .reply
    @State private var lang: Lang = .en
    @State private var selectedModel: ShareTweetModel
    @State private var draftCount: DraftCountOption = .three
    @State private var promptInputMode: PromptInputMode = .voice
    @State private var includeFullThread = false
    @State private var intention = ""
    @State private var feedback = ""
    @State private var sourceTweetText = ""
    @State private var cachedSingle = ""
    @State private var cachedThread: String?
    @State private var loadingSource = false
    @State private var sourceError: String?
    @State private var tweetEs = ""
    @State private var tweetEn = ""
    @State private var localStatusMsg: String?
    @State private var localErrorMsg: String?
    @State private var srcTask: Task<Void, Never>?
    @State private var activeConvId: UUID?
    @State private var versions: [Ver] = []
    @State private var selectedVerId: UUID?
    @State private var showCopied = false
    @State private var showSourceSheet = false
    @State private var showAdvancedSheet = false
    @State private var keyboardOverlap: CGFloat = 0
    // Cambio #30 — shimmer triggers once after generation completes
    @State private var showShimmer = false
    // Stage 3 — Line break formatting state
    @State private var lineBreakMode: LineBreakMode = .single
    @State private var formattingLineBreaks = false
    // Cambio4B #25 — toast for line break success
    @State private var showFormatted = false
    // Cambio4B #30 — track first generation for confetti delight
    @State private var isFirstGenInSession = true
    // Cambio #32 — tooltip state for version long-press
    @State private var tooltipVerId: UUID?
    // Cambio #31 — CTA breathing pulse state
    @State private var ctaBreathing = false
    @State private var voiceTranscribing = false
    @State private var voiceTask: Task<Void, Never>?
    @State private var trackedJobID: UUID?
    @State private var showCancelAlert = false
    @State private var suppressSourceReload = false
    @StateObject private var voiceRecorder = VoiceRecorderController()
    @FocusState private var focusedField: InputField?

    init(
        tweetURL: String,
        initialTweetText: String,
        initialConversationID: UUID? = nil,
        hostMode: HostMode = .shareExtension,
        onRequestVoiceRedirect: ((VoiceRedirectPayload) async throws -> Void)? = nil,
        onClose: @escaping () -> Void
    ) {
        self.tweetURL = tweetURL
        self.initialTweetText = initialTweetText
        self.initialConversationID = initialConversationID
        self.hostMode = hostMode
        self.onRequestVoiceRedirect = onRequestVoiceRedirect
        self.onClose = onClose
        _selectedModel = State(initialValue: ShareTweetModel.preferred())
    }

    private var src: String { sourceTweetText.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var sourceURLTrimmed: String { tweetURL.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var draft: String { lang == .es ? tweetEs : tweetEn }
    private var draftTrimmed: String { draft.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var hasDraft: Bool { !tweetEs.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !tweetEn.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !versions.isEmpty }
    private var trackedJobSnapshot: TweetGenerationJobSnapshot? {
        if let trackedJobID, let snapshot = jobSyncStore.snapshot(jobID: trackedJobID) {
            return snapshot
        }
        return jobSyncStore.latestJob(conversationID: activeConvId, tweetURL: tweetURL)
    }
    private var activeBackgroundJobID: UUID? {
        guard let snapshot = trackedJobSnapshot, snapshot.status.isActive else { return nil }
        return snapshot.id
    }
    private var generating: Bool {
        trackedJobSnapshot?.status.isActive ?? false
    }
    private var statusMsg: String? {
        if let localStatusMsg, !localStatusMsg.isEmpty {
            return localStatusMsg
        }
        if hostMode == .shareExtension, generating {
            return "Safe to close."
        }
        return trackedJobSnapshot?.statusMessage
    }
    private var errorMsg: String? {
        if let localErrorMsg, !localErrorMsg.isEmpty {
            return localErrorMsg
        }
        guard trackedJobSnapshot?.status == .failed else { return nil }
        return trackedJobSnapshot?.errorMessage ?? "Could not generate. Try again."
    }
    private var canGen: Bool { !generating && !loadingSource && !src.isEmpty }
    private var canPostOnX: Bool {
        guard !generating, !draftTrimmed.isEmpty else { return false }
        switch mode {
        case .reply:
            return tweetID != nil
        case .quote:
            return !sourceURLTrimmed.isEmpty
        }
    }
    private var postOnXLabel: String { mode == .reply ? "Reply on X" : "Quote on X" }
    private var chars: Int { draft.count }

    // Cambio #4 — Character count color: gradual transition from invisible to amber to red.
    // 0-200: quiet gray. 201-270: amber warning. 271+: danger red.
    private var charCountColor: Color {
        if chars > 270 { return S.danger }
        if chars > 200 { return S.amber }
        return S.ink.opacity(0.35)
    }

    // Cambio #4 — Character count weight increases with count for visual urgency
    private var charCountWeight: Font.Weight {
        if chars > 270 { return .bold }
        if chars > 200 { return .semibold }
        return .medium
    }

    private var tweetID: String? {
        guard let regex = try? NSRegularExpression(pattern: "/status/(\\d+)"),
              let m = regex.firstMatch(in: tweetURL, range: NSRange(tweetURL.startIndex..<tweetURL.endIndex, in: tweetURL)),
              m.numberOfRanges > 1, let r = Range(m.range(at: 1), in: tweetURL) else { return nil }
        return String(tweetURL[r])
    }

    private var draftBinding: Binding<String> {
        Binding(
            get: { lang == .es ? tweetEs : tweetEn },
            set: { if lang == .es { tweetEs = $0 } else { tweetEn = $0 } }
        )
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            S.bg.ignoresSafeArea()

            ScrollView(.vertical, showsIndicators: false) {
                VStack(spacing: 0) {
                    minimalistTopBar
                        .padding(.bottom, 14)

                    tweetBlock

                    Spacer().frame(height: 34)

                    voiceBlock

                    if shouldShowReplyBlock {
                        Spacer().frame(height: 28)
                        subtleDivider
                        Spacer().frame(height: 24)
                        replyBlock
                    }

                    Spacer().frame(height: 18)

                    messages
                }
                .padding(.horizontal, 24)
                .padding(.top, 10)
                .padding(.bottom, max(32, keyboardOverlap + 24))
                .frame(maxWidth: .infinity, alignment: .top)
            }
            .scrollDismissesKeyboard(.interactively)

            // Cambio4B #24 — Toast: checkmark only, no text. The checkmark IS the message.
            if showCopied {
                VStack {
                    Spacer()
                    Image(systemName: "checkmark")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(S.ink.opacity(0.92), in: Circle())
                        .padding(.bottom, 28)
                }
                .transition(
                    .asymmetric(
                        insertion: .scale(scale: 0.85).combined(with: .opacity),
                        removal: .opacity
                    )
                )
                .allowsHitTesting(false)
            }

            // Cambio4B #25 — Toast for line break formatting success
            if showFormatted {
                VStack {
                    Spacer()
                    Image(systemName: "text.line.first.and.arrowtriangle.forward")
                        .font(.system(size: 16, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 44, height: 44)
                        .background(S.ink.opacity(0.92), in: Circle())
                        .padding(.bottom, 28)
                }
                .transition(
                    .asymmetric(
                        insertion: .scale(scale: 0.85).combined(with: .opacity),
                        removal: .opacity
                    )
                )
                .allowsHitTesting(false)
            }

            // Cambio #32 — Version tooltip overlay
            if let tooltipVerId, let ver = versions.first(where: { $0.id == tooltipVerId }) {
                VStack {
                    Spacer()
                    VersionTooltip(model: ver.modelRawValue, date: ver.createdAt)
                        .padding(.bottom, 60)
                }
                .transition(.opacity)
                .allowsHitTesting(false)
            }
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .preferredColorScheme(.light)
        .sheet(isPresented: $showSourceSheet) { sourceSheet }
        .sheet(isPresented: $showAdvancedSheet) { advancedSheet }
        .alert("Cancel Generation?", isPresented: $showCancelAlert) {
            Button("Keep Working", role: .cancel) { }
            Button("Cancel", role: .destructive) {
                cancelActiveJob()
            }
        } message: {
            Text("This stops the current tweet generation. Closing the screen does not cancel it.")
        }
        .toolbar {
            ToolbarItemGroup(placement: .keyboard) {
                if focusedField == .intention && hasDraft {
                    Button("Next") { focusedField = .refine }
                }
                Spacer()
                Button("Done") { focusedField = nil }
            }
        }
        .onAppear { bootstrap() }
        .onChange(of: includeFullThread) { _, _ in
            if suppressSourceReload {
                suppressSourceReload = false
                return
            }
            loadSource()
        }
        .onChange(of: selectedModel) { _, v in v.persistAsPreferred() }
        .onChange(of: hasDraft) { _, newValue in
            if !newValue, focusedField == .refine {
                focusedField = nil
            }
            // Cambio4B #27 — breathing pulse uses 2.0s scale animation
            if !newValue {
                withAnimation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true)) {
                    ctaBreathing = true
                }
            } else {
                withAnimation(.easeOut(duration: 0.3)) {
                    ctaBreathing = false
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillChangeFrameNotification)) { notification in
            handleKeyboardNotification(notification)
        }
        .onReceive(NotificationCenter.default.publisher(for: UIResponder.keyboardWillHideNotification)) { _ in
            withAnimation(.easeOut(duration: 0.2)) {
                keyboardOverlap = 0
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didEnterBackgroundNotification)) { _ in
            handleAppDidEnterBackground()
        }
        .onReceive(NotificationCenter.default.publisher(for: UIApplication.didBecomeActiveNotification)) { _ in
            jobSyncStore.refreshNow()
            refreshComposerStateFromPersistence()
        }
        .onChange(of: scenePhase) { _, newValue in
            if newValue == .active {
                jobSyncStore.refreshNow()
                refreshComposerStateFromPersistence()
            }
        }
        .onChange(of: jobSyncStore.refreshSequence) { _, _ in
            refreshComposerStateFromPersistence()
        }
        .onDisappear {
            srcTask?.cancel()
            voiceTask?.cancel()
            voiceRecorder.cancel()
        }
    }

    private var promptTrimmed: String {
        intention.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var shouldShowReplyBlock: Bool {
        switch promptInputMode {
        case .voice:
            return voiceTranscribing || generating || activeBackgroundJobID != nil || !promptTrimmed.isEmpty || hasDraft
        case .text:
            return generating || activeBackgroundJobID != nil || hasDraft
        }
    }

    private var shouldDisableVoiceCapture: Bool {
        loadingSource || voiceTranscribing || generating
    }

    private var canSubmitTypedPrompt: Bool {
        canGen && !promptTrimmed.isEmpty
    }

    private var canInteractWithVoiceCapture: Bool {
        !shouldDisableVoiceCapture || voiceRecorder.isRecording
    }

    private var voiceCaptureAvailableInCurrentHost: Bool {
#if targetEnvironment(simulator)
        true
#else
        hostMode == .app
#endif
    }

    private var replyStatusCopy: String {
        if let statusMsg, !statusMsg.isEmpty {
            return statusMsg
        }
        return generating ? "Generating" : "Crafting your reply."
    }

    private var minimalistTopBar: some View {
        HStack {
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(S.ink.opacity(0.45))
                    .frame(width: 34, height: 34)
                    .background(S.card.opacity(0.72), in: Circle())
            }
            .buttonStyle(.plain)

            Spacer()

            if generating {
                Button {
                    showCancelAlert = true
                } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(S.danger.opacity(0.82))
                        .frame(width: 34, height: 34)
                        .background(S.card.opacity(0.72), in: Circle())
                }
                .buttonStyle(.plain)
            }

            Button {
                showAdvancedSheet = true
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 17, weight: .semibold))
                    .foregroundStyle(S.ink.opacity(0.55))
                    .frame(width: 34, height: 34)
                    .background(S.card.opacity(0.72), in: Circle())
            }
            .buttonStyle(.plain)
        }
    }

    private var tweetBlock: some View {
        Group {
            if src.isEmpty {
                if loadingSource {
                    HStack(spacing: 10) {
                        ProgressView()
                            .scaleEffect(0.8)
                        Text("Loading")
                            .font(.system(size: 14, weight: .medium, design: .rounded))
                            .foregroundStyle(S.ink.opacity(0.42))
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.vertical, 28)
                } else {
                    Text(sourceError ?? "Could not load the tweet.")
                        .font(.system(size: 15, weight: .medium, design: .rounded))
                        .foregroundStyle(sourceError == nil ? S.ink.opacity(0.28) : S.danger)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.vertical, 24)
                }
            } else {
                Text(sourceTweetText)
                    .font(.system(size: 26, weight: .regular, design: .default))
                    .foregroundStyle(S.ink)
                    .lineSpacing(7)
                    .tracking(-0.3)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
                    .onTapGesture { showSourceSheet = true }
            }
        }
    }

    private var voiceBlock: some View {
        VStack(spacing: 16) {
            inputModeToggle

            if promptInputMode == .voice {
                voiceCaptureBlock
                    .transition(.opacity.combined(with: .move(edge: .top)))
            } else {
                typedPromptBlock
                    .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
        .animation(.spring(response: 0.28, dampingFraction: 0.86), value: promptInputMode)
        .frame(maxWidth: .infinity)
    }

    private var inputModeToggle: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Intent Input")
                .font(.system(size: 11, weight: .bold, design: .rounded))
                .foregroundStyle(S.ink.opacity(0.42))
                .textCase(.uppercase)

            HStack(spacing: 8) {
                ForEach(PromptInputMode.allCases) { option in
                    Button {
                        setPromptInputMode(option)
                    } label: {
                        HStack(spacing: 8) {
                            Image(systemName: option.icon)
                                .font(.system(size: 12, weight: .semibold))

                            Text(option.label)
                                .font(.system(size: 13, weight: .semibold, design: .rounded))
                        }
                        .foregroundStyle(promptInputMode == option ? .white : S.ink.opacity(0.62))
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 12)
                        .background(
                            promptInputMode == option ? S.ink : S.card,
                            in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                        )
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel(option == .voice ? "Use microphone input" : "Use typed input")
                    .accessibilityHint(option == .voice ? "Record your intention as before." : "Write your intention in a text area.")
                }
            }
        }
        .padding(.horizontal, 18)
        .padding(.vertical, 18)
        .background(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .fill(S.card.opacity(0.92))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 24, style: .continuous)
                .stroke(Color.white.opacity(0.52), lineWidth: 1)
        )
        .shadow(color: S.shadow.opacity(0.14), radius: 14, y: 6)
    }

    private var voiceCaptureBlock: some View {
        Group {
            if activeBackgroundJobID != nil && !voiceTranscribing && !hasDraft && !voiceRecorder.isRecording {
                VStack(spacing: 14) {
                    ZStack {
                        Circle()
                            .fill(S.card)
                            .frame(width: 118, height: 118)
                            .shadow(color: S.shadowDraft.opacity(0.28), radius: 18, y: 8)

                        BouncingDotsView()
                            .scaleEffect(1.35)
                    }

                    Text("Working in back.")
                        .font(.system(size: 14, weight: .semibold, design: .rounded))
                        .foregroundStyle(S.ink.opacity(0.56))
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            } else if voiceTranscribing {
                VStack(spacing: 14) {
                    ZStack {
                        Circle()
                            .fill(S.card)
                            .frame(width: 118, height: 118)
                            .shadow(color: S.shadowDraft.opacity(0.35), radius: 18, y: 8)

                        BouncingDotsView()
                            .scaleEffect(1.35)
                    }

                    if !promptTrimmed.isEmpty {
                        Text(promptTrimmed)
                            .font(.system(size: 17, weight: .regular, design: .rounded))
                            .foregroundStyle(S.ink.opacity(0.86))
                            .lineSpacing(5)
                            .multilineTextAlignment(.center)
                            .padding(.horizontal, 18)
                    }
                }
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
                .transition(.opacity.combined(with: .scale(scale: 0.96)))
            } else if !promptTrimmed.isEmpty && !voiceRecorder.isRecording {
                VStack(alignment: .leading, spacing: 16) {
                    Text(promptTrimmed)
                        .font(.system(size: 18, weight: .regular, design: .rounded))
                        .foregroundStyle(S.ink)
                        .lineSpacing(5)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    HStack(spacing: 10) {
                        Button {
                            intention = ""
                            localErrorMsg = nil
                        } label: {
                            Image(systemName: "xmark")
                                .font(.system(size: 12, weight: .bold))
                                .foregroundStyle(S.ink.opacity(0.45))
                                .frame(width: 30, height: 30)
                                .background(S.chip, in: Circle())
                        }
                        .buttonStyle(.plain)

                        Spacer()

                        Button {
                            handleMicrophoneTap()
                        } label: {
                            Image(systemName: "mic.fill")
                                .font(.system(size: 16, weight: .semibold))
                                .foregroundStyle(S.ink)
                                .frame(width: 40, height: 40)
                                .background(S.card, in: Circle())
                                .shadow(color: S.shadowDraft.opacity(0.22), radius: 12, y: 4)
                        }
                        .buttonStyle(.plain)
                        .disabled(shouldDisableVoiceCapture)
                    }
                }
                .padding(.horizontal, 20)
                .padding(.vertical, 22)
                .background(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .fill(S.card)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 28, style: .continuous)
                        .stroke(Color.white.opacity(0.55), lineWidth: 1)
                )
                .shadow(color: S.shadowDraft.opacity(0.25), radius: 18, y: 8)
                .transition(.asymmetric(
                    insertion: .move(edge: .bottom).combined(with: .opacity),
                    removal: .opacity
                ))
            } else {
                VStack(spacing: 14) {
                    microphoneOrb

                    if voiceRecorder.isRecording {
                        HStack(spacing: 8) {
                            Text(voiceRecorder.formattedDuration)
                                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                                .foregroundStyle(S.ink.opacity(0.52))

                            if voiceRecorder.isLocked {
                                Image(systemName: "lock.fill")
                                    .font(.system(size: 11, weight: .bold))
                                    .foregroundStyle(S.ink.opacity(0.46))
                            }
                        }
                        .transition(.opacity)
                    }
                }
                .frame(maxWidth: .infinity)
            }
        }
        .frame(maxWidth: .infinity)
    }

    private var typedPromptBlock: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Write the intention and generate when ready.")
                .font(.system(size: 14, weight: .medium, design: .rounded))
                .foregroundStyle(S.ink.opacity(0.56))

            ZStack(alignment: .topLeading) {
                if promptTrimmed.isEmpty {
                    Text("Example: answer with a sharp take, make it concise, and keep it in English.")
                        .font(.system(size: 16, weight: .regular, design: .rounded))
                        .foregroundStyle(S.ink.opacity(0.22))
                        .padding(.horizontal, 20)
                        .padding(.vertical, 18)
                        .allowsHitTesting(false)
                }

                TextEditor(text: $intention)
                    .font(.system(size: 17, weight: .regular, design: .rounded))
                    .foregroundStyle(S.ink)
                    .lineSpacing(5)
                    .scrollContentBackground(.hidden)
                    .focused($focusedField, equals: .intention)
                    .padding(.horizontal, 16)
                    .padding(.vertical, 14)
                    .frame(minHeight: 172)
                    .background(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .fill(S.field)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 22, style: .continuous)
                            .stroke(focusedField == .intention ? S.focusStroke : Color.clear, lineWidth: 1.25)
                    )
                    .shadow(color: focusedField == .intention ? S.focusShadow : Color.clear, radius: 6, y: 2)
                    .disabled(generating)
            }

            Button(action: submitTypedPrompt) {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 14, weight: .semibold))
                    Text("Generate from Text")
                        .font(.system(size: 15, weight: .semibold, design: .rounded))
                }
                .foregroundStyle(canSubmitTypedPrompt ? S.ink : S.ink.opacity(0.35))
                .frame(maxWidth: .infinity)
                .padding(.vertical, 15)
                .background(
                    canSubmitTypedPrompt ? S.ink.opacity(0.08) : S.ink.opacity(0.04),
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )
            }
            .buttonStyle(GenerateButtonStyle())
            .disabled(!canSubmitTypedPrompt)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 22)
        .background(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .fill(S.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 28, style: .continuous)
                .stroke(Color.white.opacity(0.55), lineWidth: 1)
        )
        .shadow(color: S.shadowDraft.opacity(0.18), radius: 18, y: 8)
    }

    private var microphoneOrb: some View {
        let level = voiceRecorder.level

        return Button(action: handleMicrophoneTap) {
            ZStack {
                Circle()
                    .fill(S.ink.opacity(voiceRecorder.isRecording ? 0.06 : 0.035))
                    .frame(width: 190 + level * 18, height: 190 + level * 18)
                    .blur(radius: voiceRecorder.isRecording ? 0 : 1.5)
                    .animation(.easeOut(duration: 0.18), value: level)

                Circle()
                    .stroke(S.ink.opacity(voiceRecorder.isRecording ? 0.13 : 0.08), lineWidth: 1)
                    .frame(width: 160 + level * 10, height: 160 + level * 10)
                    .animation(.easeOut(duration: 0.18), value: level)

                Circle()
                    .fill(
                        LinearGradient(
                            colors: [
                                S.card.opacity(0.98),
                                S.field.opacity(0.95)
                            ],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 132, height: 132)
                    .shadow(color: S.shadowDraft.opacity(voiceRecorder.isRecording ? 0.36 : 0.18), radius: 24, y: 10)

                Image(systemName: voiceRecorder.isLocked ? "stop.fill" : "mic.fill")
                    .font(.system(size: 34, weight: .semibold))
                    .foregroundStyle(voiceRecorder.isRecording ? S.cta : S.ink)
                    .scaleEffect(voiceRecorder.isRecording ? 1.02 + level * 0.05 : 1)
                    .animation(.easeOut(duration: 0.16), value: level)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 8)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(!canInteractWithVoiceCapture)
        .opacity(canInteractWithVoiceCapture ? 1 : 0.55)
    }

    private var subtleDivider: some View {
        Rectangle()
            .fill(S.ink.opacity(0.08))
            .frame(height: 1)
    }

    private var replyBlock: some View {
        VStack(alignment: .leading, spacing: 18) {
            ZStack(alignment: .topLeading) {
                TextEditor(text: draftBinding)
                    .font(.system(size: 19, weight: .regular, design: .default))
                    .foregroundStyle(S.ink)
                    .lineSpacing(5)
                    .scrollContentBackground(.hidden)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 16)
                    .frame(minHeight: 196)
                    .background(
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .fill(S.card)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 28, style: .continuous)
                            .stroke(Color.white.opacity(0.55), lineWidth: 1)
                    )
                    .shadow(color: S.shadowDraft.opacity(0.18), radius: 18, y: 8)
                    .disabled(generating)

                if draftTrimmed.isEmpty {
                    if generating {
                        VStack(spacing: 10) {
                            Spacer()
                            BouncingDotsView()
                                .scaleEffect(1.2)
                            Text(replyStatusCopy)
                                .font(.system(size: 12, weight: .semibold, design: .rounded))
                                .foregroundStyle(S.ink.opacity(0.34))
                            Spacer()
                        }
                        .frame(maxWidth: .infinity, minHeight: 196)
                    } else {
                        Text(draftPlaceholderCopy)
                            .font(.system(size: 16, weight: .regular, design: .rounded))
                            .foregroundStyle(S.ink.opacity(0.2))
                            .padding(.horizontal, 24)
                            .padding(.vertical, 24)
                            .allowsHitTesting(false)
                    }
                }
            }

            HStack(spacing: 12) {
                if versions.count > 1 {
                    inlineVersionSwitcher
                }

                if hasDraft {
                    inlineLanguageSwitcher
                }

                Spacer(minLength: 0)

                Text("\(chars)/280")
                    .font(.system(size: 12, weight: .semibold, design: .monospaced))
                    .foregroundStyle(charCountColor)

                Button {
                    copyDraft()
                } label: {
                    Image(systemName: showCopied ? "checkmark" : "doc.on.doc")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(draftTrimmed.isEmpty ? S.ink.opacity(0.22) : S.ink.opacity(0.5))
                        .frame(width: 34, height: 34)
                        .background(S.chip.opacity(0.9), in: Circle())
                }
                .buttonStyle(.plain)
                .disabled(draftTrimmed.isEmpty)
            }

            Button(action: {
                Haptic.medium()
                postOnX()
            }) {
                HStack(spacing: 8) {
                    Image(systemName: mode == .reply ? "arrowshape.turn.up.right.fill" : "quote.opening")
                        .font(.system(size: 15, weight: .semibold))
                    Text(postOnXLabel)
                        .font(.system(size: 18, weight: .bold, design: .rounded))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 18)
                .background(
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .fill(canPostOnX ? S.cta : S.cta.opacity(0.24))
                )
            }
            .buttonStyle(ReplyButtonStyle())
            .disabled(!canPostOnX)
        }
    }

    private var advancedSheet: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Prompt", text: $intention, axis: .vertical)
                        .lineLimit(2...4)

                    Toggle("Full Thread", isOn: $includeFullThread)
                }

                Section("Reply") {
                    Picker("Mode", selection: $mode) {
                        ForEach(Mode.allCases) { option in
                            Text(option.label).tag(option)
                        }
                    }

                    Picker("Language", selection: $lang) {
                        ForEach(Lang.allCases) { option in
                            Text(option.rawValue).tag(option)
                        }
                    }

                    Picker("Model", selection: $selectedModel) {
                        ForEach(ShareTweetModel.allCases) { option in
                            Text(option.displayName).tag(option)
                        }
                    }

                    Picker("Options", selection: $draftCount) {
                        ForEach(DraftCountOption.allCases) { option in
                            Text(option.label).tag(option)
                        }
                    }
                }

                if hasDraft {
                    Section("Refine") {
                        TextField("What should improve?", text: $feedback, axis: .vertical)
                            .lineLimit(2...4)

                        Button("Generate New Version") {
                            generate(regen: true)
                            showAdvancedSheet = false
                        }
                        .disabled(!canGen)
                    }
                }

                if versions.count > 1 {
                    Section("Versions") {
                        ForEach(versions) { version in
                            Button("Version \(version.num)") {
                                applyVersion(version)
                                showAdvancedSheet = false
                            }
                        }
                    }
                }

                Section("Actions") {
                    Button(hasDraft ? "Regenerate Reply" : "Generate Reply") {
                        generate(regen: false)
                        showAdvancedSheet = false
                    }
                    .disabled(!canGen)

                    Button("Format Current Draft") {
                        formatWithLineBreaks()
                    }
                    .disabled(draftTrimmed.isEmpty || formattingLineBreaks)

                    Button("Reset", role: .destructive) {
                        resetComposer()
                        showAdvancedSheet = false
                    }
                }
            }
            .navigationTitle("Options")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { showAdvancedSheet = false }
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            // Cambio4B #17 — close button: xmark.circle for better recognition
            Button(action: close) {
                Image(systemName: "xmark.circle")
                    .font(.system(size: 13, weight: .regular))
                    .foregroundStyle(S.ink.opacity(0.4))
                    .frame(width: 30, height: 30)
                    .contentShape(Circle())
            }

            Spacer()

            // Cambio4B #6 — tracking from -0.4 to -0.6: more compact, more confident
            Text("KyCode")
                .font(.system(size: 17, weight: .bold, design: .rounded))
                .tracking(-0.6)
                .foregroundStyle(S.ink)

            Spacer()

            Color.clear.frame(width: 30, height: 30)
        }
    }

    // MARK: - Source Row

    private var sourceRow: some View {
        HStack(spacing: 10) {
            // Iter10: quote icon slightly more present — anchors the source card
            Image(systemName: "quote.opening")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(S.ink.opacity(0.3))

            Group {
                if src.isEmpty {
                    if loadingSource {
                        HStack(spacing: 6) {
                            ProgressView().scaleEffect(0.7)
                            Text("Loading...").foregroundStyle(S.ink.opacity(0.5))
                        }
                        .font(.system(size: 14, weight: .regular, design: .rounded))
                    } else {
                        // Cambio #8 — placeholder uses .light weight for visual subordination
                        Text("Share a tweet from X")
                            .foregroundStyle(S.hint)
                            .font(.system(size: 14, weight: .light, design: .rounded))
                    }
                } else {
                    // Cambio #6 — Source tweet: default font with italic instead of serif.
                    // Italic distinguishes quoted content while staying in the SF Pro family.
                    Text(sourceTweetText)
                        .font(.system(size: 14, weight: .regular).italic())
                        .foregroundStyle(S.ink)
                        .lineLimit(2)
                        .onTapGesture { showSourceSheet = true }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                withAnimation(.easeOut(duration: 0.2)) { includeFullThread.toggle() }
            } label: {
                Text(includeFullThread ? "Thread" : "Single")
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .foregroundStyle(includeFullThread ? .white : S.ink.opacity(0.6))
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(includeFullThread ? S.ink : S.chip, in: Capsule())
            }
            .buttonStyle(.plain)
            .disabled(loadingSource)
        }
        // Iter3: 16pt padding for more generous inner breathing
        .padding(16)
        .background(S.card, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
        // Iter3: slightly stronger shadow for card presence
        .shadow(color: S.shadow, radius: 8, y: 2)
    }

    // MARK: - Controls Row
    // Cambio #23 — Custom ChipPicker replaces system segmented controls.
    // All controls now share the same visual DNA: capsules with dark/light states.

    private var controlsRow: some View {
        // Iter3: 6pt spacing between chip groups for visual grouping
        HStack(spacing: 6) {
            // Mode picker
            ChipPicker(selection: $mode) { $0.label }

            // Iter3: 2pt extra gap between mode and lang groups
            Spacer().frame(width: 2)

            // Language picker
            ChipPicker(selection: $lang) { $0.rawValue }

            Spacer(minLength: 0)

            Menu {
                Picker("Model", selection: $selectedModel) {
                    ForEach(ShareTweetModel.allCases) { Text($0.displayName).tag($0) }
                }
            } label: {
                Text(selectedModel.displayName)
                    // Iter3: slightly larger model label for consistency
                    .font(.system(size: 12, weight: .medium, design: .rounded))
                    .foregroundStyle(S.ink.opacity(0.6))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .background(S.field, in: Capsule())
            }
        }
    }

    // MARK: - Intention Field

    // Iter9: intention field — slightly smaller, more like a secondary input
    private var intentionField: some View {
        TextField("What should this tweet achieve?", text: $intention, axis: .vertical)
            .font(.system(size: 14, weight: .regular, design: .rounded))
            .foregroundStyle(S.ink)
            .lineLimit(2...3)
            .focused($focusedField, equals: .intention)
            .submitLabel(hasDraft ? .next : .done)
            .onSubmit {
                if hasDraft {
                    focusedField = .refine
                } else {
                    focusedField = nil
                }
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(minHeight: 56, alignment: .topLeading)
            .background(inputBackground(isFocused: focusedField == .intention))
    }

    private var backgroundGenerationRow: some View {
        EmptyView()
    }

    // MARK: - Draft Area

    private var draftArea: some View {
        ZStack(alignment: .topLeading) {
            TextEditor(text: draftBinding)
                // Iter4: 18pt — balanced: large enough to be protagonist, not overwhelming
                .font(.system(size: 18, weight: .regular, design: .default))
                .foregroundStyle(S.ink)
                // Iter4: 5pt line spacing — tighter, more editorial
                .lineSpacing(5)
                .scrollContentBackground(.hidden)
                .tint(S.ink)
                // Iter4: 18pt padding — generous breathing inside draft card
                .padding(18)
                .frame(minHeight: 140)
                .background(S.card, in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                // Cambio4B #19 — draft shadow dominant: radius 22, opacity 0.12
                .shadow(
                    color: generating ? S.shadowDraft.opacity(1.3) : S.shadowDraft,
                    radius: generating ? 26 : 22,
                    y: generating ? 6 : 4
                )
                // Cambio #16 — Animate shadow changes smoothly
                .animation(.easeInOut(duration: 0.4), value: generating)
                .disabled(generating)
            // Cambio #30 — Shimmer sweep on generation complete
            .modifier(ShimmerModifier(active: showShimmer))

            if draftTrimmed.isEmpty && !generating {
                // Iter7: warmer placeholder — slightly visible, inviting
                Text("Tap Generate to start")
                    .font(.system(size: 16, weight: .regular, design: .rounded))
                    .foregroundStyle(S.ink.opacity(0.22))
                    .padding(24)
                    .allowsHitTesting(false)
            }

            // Cambio4B #13 — "Thinking..." removed: dots communicate alone. Less noise.
            if generating {
                VStack {
                    Spacer()
                    BouncingDotsView()
                    Spacer()
                }
                .frame(maxWidth: .infinity, minHeight: 150)
                .background(S.card.opacity(0.92), in: RoundedRectangle(cornerRadius: 20, style: .continuous))
                // Cambio #14 — Fade in the overlay instead of instant appear
                .transition(.opacity.animation(.easeInOut(duration: 0.25)))
            }
        }
    }

    // MARK: - Actions Row

    private var actionsRow: some View {
        // Iter2: 10pt gap between action elements
        VStack(spacing: 10) {
            // Iter2: Row 1 — char count left, utility icons right (clean, minimal)
            HStack(spacing: 0) {
                // Character counter
                HStack(spacing: 0) {
                    Text("\(chars)")
                        .font(.system(size: 13, weight: charCountWeight, design: .monospaced))
                        .foregroundStyle(charCountColor)
                        .contentTransition(.numericText())
                        .animation(.easeInOut(duration: 0.2), value: chars)
                    Text("/280")
                        .font(.system(size: 11, weight: .regular, design: .monospaced))
                        .foregroundStyle(S.ink.opacity(0.25))
                }

                Spacer()

                // Iter2: Line break controls — only when draft exists, spacious layout
                if !draftTrimmed.isEmpty {
                    HStack(spacing: 6) {
                        ChipPicker(selection: $lineBreakMode) { $0.rawValue }

                        Button(action: formatWithLineBreaks) {
                            if formattingLineBreaks {
                                ProgressView()
                                    .scaleEffect(0.55)
                                    .tint(S.ink)
                            } else {
                                Image(systemName: "text.line.first.and.arrowtriangle.forward")
                                    .font(.system(size: 12, weight: .medium))
                            }
                        }
                        .foregroundStyle(S.ink.opacity(0.5))
                        .frame(width: 32, height: 28)
                        .background(S.chip, in: Capsule())
                        .buttonStyle(.plain)
                        .disabled(formattingLineBreaks || generating)
                    }
                    .transition(.opacity.combined(with: .scale(scale: 0.9)))
                }

                // Iter2: Utility icons — copy + reset, 16pt spacing for touch targets
                HStack(spacing: 16) {
                    Button(action: copyDraft) {
                        Image(systemName: "doc.on.doc")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(draftTrimmed.isEmpty ? S.hint : S.ink.opacity(0.4))
                    }
                    .buttonStyle(.plain)
                    .disabled(draftTrimmed.isEmpty)

                    Button(action: resetComposer) {
                        Image(systemName: "arrow.counterclockwise")
                            .font(.system(size: 13, weight: .medium))
                            .foregroundStyle(
                                generating
                                    ? S.hint
                                    : (hasDraft || !intention.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !feedback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? S.danger : S.hint)
                            )
                    }
                    .buttonStyle(.plain)
                    .disabled(generating || (!hasDraft && intention.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && feedback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                }
                .padding(.leading, 12)
            }

            // Stage 1 + Cambio4B #16, #21, #23, #31 — Reply on X: THE dominant action.
            Button(action: {
                // Cambio4B #21 — medium haptic: you FEEL you're about to publish
                Haptic.medium()
                postOnX()
            }) {
                HStack(spacing: 8) {
                    // Cambio4B #16 — arrowshape icon: semantically "reply", not "send"
                    Image(systemName: mode == .reply ? "arrowshape.turn.up.right.fill" : "quote.opening")
                        .font(.system(size: 15, weight: .semibold))
                    Text(postOnXLabel)
                        .font(.system(size: 16, weight: .bold, design: .rounded))
                }
                .foregroundStyle(.white)
                .frame(maxWidth: .infinity)
                // Iter5: 17pt vertical padding — more luxurious CTA
                .padding(.vertical, 17)
                .background(
                    ZStack {
                        // Iter5: corner radius 16 for softer, more Apple-like feel
                        RoundedRectangle(cornerRadius: 16, style: .continuous)
                            .fill(canPostOnX ? S.cta : S.cta.opacity(0.25))
                        if canPostOnX {
                            RoundedRectangle(cornerRadius: 16, style: .continuous)
                                .fill(
                                    LinearGradient(
                                        colors: [Color.white.opacity(0.12), Color.clear],
                                        startPoint: .top,
                                        endPoint: .bottom
                                    )
                                )
                        }
                    }
                )
            }
            // Cambio4B #23 — scale 0.95: the most important button gets the most satisfying feedback
            .buttonStyle(ReplyButtonStyle())
            .disabled(!canPostOnX)

            // Generate / Regen — subordinate to Reply on X, with draft-count selector attached
            HStack(spacing: 8) {
                Menu {
                    ForEach(DraftCountOption.allCases) { option in
                        Button {
                            Haptic.selection()
                            draftCount = option
                        } label: {
                            if draftCount == option {
                                Label("\(option.rawValue) tweets", systemImage: "checkmark")
                            } else {
                                Text("\(option.rawValue) tweets")
                            }
                        }
                    }
                } label: {
                    HStack(spacing: 5) {
                        Text(draftCount.label)
                            .font(.system(size: 14, weight: .bold, design: .rounded))
                        Image(systemName: "chevron.down")
                            .font(.system(size: 10, weight: .semibold))
                    }
                    .foregroundStyle(canGen ? S.ink : S.ink.opacity(0.35))
                    .frame(width: 62)
                    .padding(.vertical, 15)
                    .background(
                        canGen ? S.ink.opacity(0.08) : S.ink.opacity(0.04),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                    )
                }
                .disabled(generating)

                Button(action: {
                    Haptic.light()
                    generate(regen: false)
                }) {
                    HStack(spacing: 6) {
                        if generating {
                            Image(systemName: "sparkles")
                                .font(.system(size: 14, weight: .semibold))
                                .symbolEffect(.pulse, isActive: generating)
                        } else {
                            Image(systemName: "sparkles")
                                .font(.system(size: 14, weight: .semibold))
                        }
                        Text(hasDraft ? "Regen" : "Generate")
                            .font(.system(size: 15, weight: .semibold, design: .rounded))
                    }
                    .foregroundStyle(canGen ? S.ink : S.ink.opacity(0.35))
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 15)
                    .background(
                        canGen ? S.ink.opacity(0.08) : S.ink.opacity(0.04),
                        in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                    )
                    .scaleEffect(!hasDraft && canGen && ctaBreathing ? 1.012 : 1.0)
                }
                .buttonStyle(GenerateButtonStyle())
                .disabled(!canGen)
            }
        }
    }

    // MARK: - Refine Row

    // Iter6: Refine row — cleaner, more integrated
    private var refineRow: some View {
        HStack(spacing: 10) {
            TextField("What should improve in this version?", text: $feedback, axis: .vertical)
                .font(.system(size: 14, weight: .regular, design: .rounded))
                .foregroundStyle(S.ink)
                .lineLimit(2...3)
                .focused($focusedField, equals: .refine)
                .submitLabel(.done)
                .onSubmit { focusedField = nil }
                .padding(.horizontal, 14)
                .padding(.vertical, 12)
                .frame(minHeight: 56, alignment: .topLeading)
                .background(inputBackground(isFocused: focusedField == .refine))
                .disabled(generating)

            Button(action: { generate(regen: true) }) {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(canGen ? S.ink.opacity(0.6) : S.ink.opacity(0.2))
                    .frame(width: 40, height: 40)
                    .background(S.field, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
            .buttonStyle(.plain)
            .disabled(!canGen)
        }
    }

    // MARK: - Versions Row

    private var versionsRow: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(versions) { v in
                    Button {
                        // Cambio #26 — haptic on version switch
                        Haptic.selection()
                        // Cambio #14 — easeInOut for version transitions (smoother than easeOut)
                        withAnimation(.easeInOut(duration: 0.25)) { applyVersion(v) }
                    } label: {
                        Text("v\(v.num)")
                            .font(.system(size: 13, weight: .semibold, design: .rounded))
                            .foregroundStyle(v.id == selectedVerId ? .white : S.ink)
                            // Cambio #12 — Larger pills: 14x9 padding for proper touch targets
                            .padding(.horizontal, 14)
                            .padding(.vertical, 9)
                            .background(v.id == selectedVerId ? S.ink : S.chip, in: Capsule())
                    }
                    .buttonStyle(.plain)
                    // Cambio #32 — Long press shows tooltip with model/date info
                    .simultaneousGesture(
                        LongPressGesture(minimumDuration: 0.5)
                            .onEnded { _ in
                                Haptic.soft()
                                withAnimation(.easeIn(duration: 0.2)) { tooltipVerId = v.id }
                                // Auto-dismiss after 2 seconds
                                DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
                                    withAnimation(.easeOut(duration: 0.2)) { tooltipVerId = nil }
                                }
                            }
                    )
                }
            }
        }
    }

    private var inlineVersionSwitcher: some View {
        HStack(spacing: 6) {
            ForEach(Array(versions.prefix(3))) { version in
                Button {
                    Haptic.selection()
                    withAnimation(.easeInOut(duration: 0.22)) {
                        applyVersion(version)
                    }
                } label: {
                    Text("B\(version.num)")
                        .font(.system(size: 11, weight: .bold, design: .rounded))
                        .foregroundStyle(version.id == selectedVerId ? S.cta : S.ink.opacity(0.56))
                        .frame(minWidth: 34)
                        .padding(.horizontal, 2)
                        .padding(.vertical, 8)
                        .background(
                            version.id == selectedVerId ? S.cta.opacity(0.14) : S.chip.opacity(0.82),
                            in: Capsule()
                        )
                }
                .buttonStyle(.plain)
                .disabled(generating)
            }
        }
    }

    private var inlineLanguageSwitcher: some View {
        HStack(spacing: 4) {
            ForEach(Lang.allCases) { option in
                Button {
                    guard lang != option else { return }
                    Haptic.selection()
                    withAnimation(.easeInOut(duration: 0.18)) {
                        lang = option
                    }
                } label: {
                    Text(option.rawValue)
                        .font(.system(size: 10, weight: .bold, design: .rounded))
                        .foregroundStyle(lang == option ? S.ink.opacity(0.82) : S.ink.opacity(0.4))
                        .padding(.horizontal, 8)
                        .padding(.vertical, 7)
                        .background(
                            lang == option ? S.card.opacity(0.94) : S.chip.opacity(0.56),
                            in: Capsule()
                        )
                }
                .buttonStyle(.plain)
                .disabled(generating)
            }
        }
    }

    // MARK: - Messages

    // Iter10: messages aligned right — cleaner, less intrusive
    @ViewBuilder
    private var messages: some View {
        if let sourceError {
            HStack { Spacer(); Text(sourceError)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(S.danger) }
        }
        if let statusMsg {
            HStack { Spacer(); Text(statusMsg)
                .font(.system(size: 12, weight: .semibold, design: .rounded))
                .foregroundStyle(S.success) }
        }
        if let errorMsg {
            HStack { Spacer(); Text(errorMsg)
                .font(.system(size: 12, weight: .medium, design: .rounded))
                .foregroundStyle(S.danger) }
        }
    }

    // MARK: - Source Sheet

    private var sourceSheet: some View {
        NavigationStack {
            ScrollView {
                // Cambio #6 — Consistent italic style in source sheet too
                Text(sourceTweetText)
                    .font(.system(size: 16, weight: .regular).italic())
                    .foregroundStyle(S.ink)
                    .lineSpacing(5)
                    .textSelection(.enabled)
                    .padding(24)
            }
            .background(S.bg)
            .navigationTitle("Original Tweet")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button("Done") { showSourceSheet = false }
                }
            }
        }
    }

    private func inputBackground(isFocused: Bool) -> some View {
        RoundedRectangle(cornerRadius: 12, style: .continuous)
            .fill(S.field)
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .stroke(isFocused ? S.focusStroke : Color.clear, lineWidth: 1.25)
            )
            .shadow(color: isFocused ? S.focusShadow : Color.clear, radius: 6, y: 2)
    }

    private func handleKeyboardNotification(_ notification: Notification) {
        guard let endFrame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect else { return }
        let duration = notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey] as? Double ?? 0.25
        let screenHeight = UIScreen.main.bounds.height
        let overlap = max(0, screenHeight - endFrame.minY)
        withAnimation(.easeOut(duration: max(0.18, duration))) {
            keyboardOverlap = overlap
        }
    }

    // MARK: - Actions

    private func handleMicrophoneTap() {
        guard canInteractWithVoiceCapture else { return }

        guard voiceCaptureAvailableInCurrentHost else {
            guard let onRequestVoiceRedirect else {
                localErrorMsg = "Voice works in the app, not the share sheet."
                Haptic.warning()
                return
            }

            let payload = VoiceRedirectPayload(
                tweetURL: tweetURL,
                initialTweetText: src.isEmpty
                    ? initialTweetText.trimmingCharacters(in: .whitespacesAndNewlines)
                    : src
            )

            localStatusMsg = "Open KyCode to record."
            localErrorMsg = nil
            voiceTask?.cancel()
            voiceTask = Task {
                do {
                    try await onRequestVoiceRedirect(payload)
                    await MainActor.run { Haptic.medium() }
                } catch {
                    if Task.isCancelled { return }
                    await MainActor.run {
                        localStatusMsg = nil
                        localErrorMsg = localizedError(error)
                        Haptic.warning()
                    }
                }
            }
            return
        }

        localErrorMsg = nil
        toggleLockedVoiceCapture()
    }

    private var draftPlaceholderCopy: String {
        if promptTrimmed.isEmpty {
            return promptInputMode == .voice ? "Speak to start." : "Write your intention to start."
        }
        return "Crafting your reply."
    }

    private func setPromptInputMode(_ mode: PromptInputMode) {
        guard promptInputMode != mode else { return }

        if mode == .text {
            voiceTask?.cancel()
            voiceRecorder.cancel()
            voiceTranscribing = false
            localStatusMsg = nil
        }

        withAnimation(.easeInOut(duration: 0.2)) {
            promptInputMode = mode
        }

        if mode == .text {
            DispatchQueue.main.async {
                focusedField = .intention
            }
        } else {
            focusedField = nil
        }
    }

    private func submitTypedPrompt() {
        guard canSubmitTypedPrompt else { return }
        focusedField = nil
        localErrorMsg = nil
        Haptic.light()
        generate(regen: false)
    }

    private func toggleLockedVoiceCapture() {
        guard canInteractWithVoiceCapture else { return }

        voiceTask?.cancel()
        voiceTask = Task {
            do {
                if voiceRecorder.isRecording {
                    let fileURL = try await voiceRecorder.stop()
                    await transcribeVoicePrompt(from: fileURL)
                } else {
                    try await voiceRecorder.start()
                    await MainActor.run { Haptic.medium() }
                }
            } catch {
                await MainActor.run {
                    localErrorMsg = voiceRecorderErrorMessage(for: error)
                    Haptic.warning()
                }
            }
        }
    }

    private func transcribeVoicePrompt(from fileURL: URL) async {
        await MainActor.run {
            voiceTranscribing = true
            localErrorMsg = nil
            localStatusMsg = nil
        }

        defer {
            try? FileManager.default.removeItem(at: fileURL)
        }

        do {
            let transcript = try await service.transcribeAudio(fileURL: fileURL)
            try Task.checkCancellation()

            await MainActor.run {
                withAnimation(.spring(response: 0.34, dampingFraction: 0.86)) {
                    intention = transcript
                }
                voiceTranscribing = false
                Haptic.success()
            }

            await MainActor.run {
                generate(regen: false)
            }
        } catch {
            if Task.isCancelled { return }
            await MainActor.run {
                voiceTranscribing = false
                localErrorMsg = localizedError(error)
                Haptic.warning()
            }
        }
    }

    private func voiceRecorderErrorMessage(for error: Error) -> String {
        if let error = error as? VoiceRecorderController.ErrorState {
            return error.message
        }
        return "Could not capture your voice."
    }

    private func close() {
        srcTask?.cancel()
        voiceTask?.cancel()
        voiceRecorder.cancel()
        focusedField = nil
        onClose()
    }

    // Cambio4B #24 — shorter toast: 0.8s. Instant feedback, no interruption.
    private func copyDraft() {
        guard !draftTrimmed.isEmpty else { return }
        UIPasteboard.general.string = draftTrimmed
        Haptic.soft()
        withAnimation(.spring(response: 0.35, dampingFraction: 0.72)) { showCopied = true }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
            withAnimation(.easeOut(duration: 0.2)) { showCopied = false }
        }
    }

    // Stage 3 — Format current draft with line breaks using Sonnet 4.5
    private func formatWithLineBreaks() {
        guard !generating, !draftTrimmed.isEmpty else { return }
        formattingLineBreaks = true
        let text = draftTrimmed
        let langStr = lang.rawValue.lowercased()
        let modeStr = lineBreakMode == .single ? "single" : "double"

        LoggingService.logToFile(level: .info, message: "[ShareTweetUI] formatWithLineBreaks lang=\(langStr) mode=\(modeStr)")

        Task {
            do {
                let formatted = try await service.formatLineBreaks(
                    tweetText: text,
                    language: langStr,
                    lineBreakMode: modeStr
                )
                await MainActor.run {
                    withAnimation(.easeInOut(duration: 0.25)) {
                        if lang == .es {
                            tweetEs = formatted
                        } else {
                            tweetEn = formatted
                        }
                    }
                    formattingLineBreaks = false
                    Haptic.soft()
                    // Cambio4B #25 — show formatted toast
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.72)) { showFormatted = true }
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                        withAnimation(.easeOut(duration: 0.2)) { showFormatted = false }
                    }
                    LoggingService.logToFile(level: .info, message: "[ShareTweetUI] Line break formatting complete")
                }
            } catch {
                await MainActor.run {
                    formattingLineBreaks = false
                    localErrorMsg = "Could not format line breaks."
                    LoggingService.logToFile(level: .error, message: "[ShareTweetUI] Line break formatting failed: \(error)")
                }
            }
        }
    }

    private func postOnX() {
        guard canPostOnX, let primaryURL = makeTweetIntentURL(host: "twitter.com") else { return }
        let fallbackURL = makeTweetIntentURL(host: "x.com")
        openURL(primaryURL) { opened in
            if !opened, let fallbackURL {
                openURL(fallbackURL)
            }
        }
    }

    private func makeTweetIntentURL(host: String) -> URL? {
        var components = URLComponents(string: "https://\(host)/intent/tweet")
        var queryItems = [URLQueryItem(name: "text", value: draftTrimmed)]

        switch mode {
        case .reply:
            guard let id = tweetID else { return nil }
            queryItems.append(URLQueryItem(name: "in_reply_to", value: id))
        case .quote:
            guard !sourceURLTrimmed.isEmpty else { return nil }
            queryItems.append(URLQueryItem(name: "url", value: sourceURLTrimmed))
        }

        components?.queryItems = queryItems
        return components?.url
    }

    private func resetComposer() {
        guard !generating else { return }
        voiceTask?.cancel()
        voiceRecorder.cancel()
        voiceTranscribing = false
        localStatusMsg = nil
        localErrorMsg = nil
        sourceError = nil
        feedback = ""
        intention = ""
        promptInputMode = .voice
        focusedField = nil
        tweetEs = ""
        tweetEn = ""
        draftCount = .three
        versions = []
        selectedVerId = nil
        trackedJobID = nil
        mode = .reply
        lang = .en

        if includeFullThread {
            includeFullThread = false
        } else if !cachedSingle.isEmpty {
            sourceTweetText = cachedSingle
        }

        do {
            try clearConversationHistory()
            localStatusMsg = "Reset"
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.6) {
                withAnimation {
                    if localStatusMsg == "Reset" {
                        localStatusMsg = nil
                    }
                }
            }
        } catch {
            localErrorMsg = "Could not fully reset stored versions."
            LoggingService.logToFile(level: .error, message: "[ShareTweetUI] reset failed: \(error)")
        }
    }

    private func clearConversationHistory() throws {
        let url = tweetURL
        let descriptor = FetchDescriptor<TweetConversation>(
            predicate: #Predicate<TweetConversation> { $0.sourceTweetURL == url }
        )
        let conversations = try modelContext.fetch(descriptor)
        let conversationIDs = Set(conversations.map(\.id))

        let jobsDescriptor = FetchDescriptor<TweetGenerationJob>(
            predicate: #Predicate<TweetGenerationJob> { job in
                job.sourceTweetURL == url
            }
        )
        let jobs = try modelContext.fetch(jobsDescriptor)

        guard !conversations.isEmpty else {
            for job in jobs {
                if let conversationID = job.conversationID, conversationIDs.contains(conversationID) {
                    modelContext.delete(job)
                    continue
                }
                if job.sourceTweetURL == url {
                    modelContext.delete(job)
                }
            }
            try modelContext.save()
            jobSyncStore.refreshNow()
            activeConvId = nil
            trackedJobID = nil
            return
        }
        for conversation in conversations {
            modelContext.delete(conversation)
        }
        for job in jobs {
            modelContext.delete(job)
        }
        try modelContext.save()
        jobSyncStore.refreshNow()
        activeConvId = nil
        trackedJobID = nil
    }

    // MARK: - State

    private func bootstrap() {
        LoggingService.logToFile(level: .info, message: "[ShareTweetUI] onAppear URL=\(tweetURL)")
        jobSyncStore.start()
        if activeConvId == nil {
            activeConvId = initialConversationID
        }
        let initial = initialTweetText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !initial.isEmpty { sourceTweetText = initial; cachedSingle = initial }
        refreshComposerStateFromPersistence()
        if src.isEmpty { loadSource() }
        // Cambio4B #27 — breathing as scale animation (2.0s), not opacity
        if !hasDraft {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                withAnimation(.easeInOut(duration: 2.0).repeatForever(autoreverses: true)) {
                    ctaBreathing = true
                }
            }
        }
    }

    private func loadSource() {
        srcTask?.cancel(); srcTask = nil
        sourceError = nil; localStatusMsg = nil
        if includeFullThread, let cachedThread { sourceTweetText = cachedThread; return }
        if !includeFullThread, !cachedSingle.isEmpty { sourceTweetText = cachedSingle; return }
        let thread = includeFullThread
        loadingSource = true
        srcTask = Task {
            do {
                let text = try await service.fetchSourceTweet(tweetURL: tweetURL, includeThread: thread)
                if Task.isCancelled { return }
                await MainActor.run {
                    if thread { cachedThread = text } else { cachedSingle = text }
                    sourceTweetText = text; loadingSource = false
                }
            } catch {
                if Task.isCancelled { return }
                await MainActor.run {
                    loadingSource = false; includeFullThread = false
                    sourceError = "Could not refresh tweet context."
                    if !cachedSingle.isEmpty { sourceTweetText = cachedSingle }
                    LoggingService.logToFile(level: .error, message: "[ShareTweetUI] fetch source failed: \(error)")
                }
            }
        }
    }

    private func generate(regen: Bool) {
        guard !src.isEmpty else {
            localErrorMsg = "No tweet source available."
            return
        }

        let cleanInt = sanitize(intention)
        let cleanFb = sanitize(feedback)
        let prev = regen ? sanitize(draftTrimmed) : nil
        let request = GenerationRequest(
            intention: cleanInt,
            feedback: cleanFb,
            previousDraft: prev,
            notes: nil,
            draftCount: regen ? 1 : draftCount.rawValue,
            variationSeed: UUID().uuidString
        )

        localStatusMsg = nil
        localErrorMsg = nil
        showShimmer = false
        queueBackgroundGeneration(request: request)
    }

    private func localizedError(_ error: Error) -> String {
        if let e = error as? ShareHTTPError {
            return e.errorDescription ?? "Network request failed."
        }
        if let e = error as? ShareTweetGenerationError {
            switch e {
            case .missingSecrets: return "Missing Secrets.plist."
            case .missingAnthropicKey: return "ANTHROPIC_API_KEY is missing."
            case .missingGroqKey: return "GROQ_API_KEY is missing."
            case .emptySourceTweet: return "Could not read the source tweet."
            case .emptyModelOutput: return "Model returned an empty draft."
            case .emptyTranscription: return "The transcript came back empty."
            case .timedOut: return "Timed out. Try again."
            }
        }
        return "Could not generate. Try again."
    }

    private func queueBackgroundGeneration(request: GenerationRequest) {
        let conversation: TweetConversation
        let job: TweetGenerationJob

        do {
            conversation = try persistConversationCheckpoint(sourceSnapshot: src, intention: request.intention)

            job = TweetGenerationJob(
                sourceTweetURL: tweetURL,
                sourceTweetTextSnapshot: src,
                modeRawValue: mode.rawValue,
                intention: request.intention,
                feedback: request.feedback,
                previousDraft: request.previousDraft,
                notes: request.notes,
                modelRawValue: selectedModel.rawValue,
                includeFullThread: includeFullThread,
                draftCount: request.draftCount,
                variationSeed: request.variationSeed,
                conversationID: conversation.id
            )
            modelContext.insert(job)
            try modelContext.save()
            activeConvId = conversation.id
            trackedJobID = job.id
            jobSyncStore.upsert(job: job)
        } catch {
            localErrorMsg = "Could not prepare the background job."
            LoggingService.logToFile(level: .error, message: "[ShareTweetUI] background bootstrap failed: \(error)")
            return
        }

        localStatusMsg = nil
        localErrorMsg = nil

        let snapshot = TweetGenerationBackgroundRequestSnapshot(
            jobID: job.id,
            sourceTweetURL: tweetURL,
            sourceTweetText: src,
            modeRawValue: mode.rawValue,
            intention: request.intention,
            feedback: request.feedback,
            previousDraft: request.previousDraft,
            notes: request.notes,
            model: selectedModel,
            draftCount: request.draftCount,
            variationSeed: request.variationSeed
        )

        Task {
            do {
                let scheduled = try await TweetGenerationBackgroundCoordinator.shared.schedule(snapshot: snapshot)
                await MainActor.run {
                    job.backgroundTaskIdentifier = scheduled.taskIdentifier
                    job.requestBodyFileName = scheduled.requestBodyFileName
                    job.status = .queued
                    job.updatedAt = Date()

                    do {
                        try modelContext.save()
                        jobSyncStore.upsert(job: job)
                        LoggingService.logToFile(
                            level: .info,
                            message: "[ShareTweetUI] queued background generation job=\(job.id.uuidString) task=\(scheduled.taskIdentifier)"
                        )
                    } catch {
                        localErrorMsg = "Background job started but could not be saved."
                        LoggingService.logToFile(level: .error, message: "[ShareTweetUI] background save failed: \(error)")
                    }
                }
            } catch {
                await MainActor.run {
                    job.status = .failed
                    job.errorMessage = localizedError(error)
                    job.updatedAt = Date()
                    try? modelContext.save()
                    trackedJobID = job.id
                    jobSyncStore.upsert(job: job)
                    localErrorMsg = "Could not queue background generation."
                    LoggingService.logToFile(level: .error, message: "[ShareTweetUI] background queue failed: \(error)")
                }
            }
        }
    }

    private func loadPersistedConv() {
        guard let snapshot = fetchPersistedConversationSnapshot() else {
            versions = []
            selectedVerId = nil
            return
        }

        activeConvId = snapshot.id
        if src.isEmpty {
            let s = snapshot.sourceTweetText.trimmingCharacters(in: .whitespacesAndNewlines)
            if !s.isEmpty { sourceTweetText = s; cachedSingle = s }
        }
        versions = snapshot.versions

        guard !versions.isEmpty else {
            selectedVerId = nil
            if let persistedMode = Mode(rawValue: snapshot.lastModeRawValue) {
                mode = persistedMode
            }
            intention = snapshot.lastIntention ?? ""
            feedback = ""
            return
        }

        let sel = versions.first(where: { $0.id == snapshot.latestVersionID })
            ?? versions.first(where: { $0.id == selectedVerId })
            ?? versions.last
        if let sel { applyVersion(sel) }
    }

    private func applyVersion(_ v: Ver) {
        selectedVerId = v.id; mode = v.mode
        intention = v.intention ?? ""; feedback = v.feedback ?? ""
        tweetEs = v.es; tweetEn = v.en
        suppressSourceReload = true
        includeFullThread = v.usedFullThread
        let s = v.sourceSnapshot.trimmingCharacters(in: .whitespacesAndNewlines)
        if !s.isEmpty {
            sourceTweetText = s
            if v.usedFullThread { cachedThread = s } else { cachedSingle = s }
        }
    }

    private func applyJobSnapshot(_ snapshot: TweetGenerationJobSnapshot) {
        trackedJobID = snapshot.id

        if let persistedMode = Mode(rawValue: snapshot.modeRawValue) {
            mode = persistedMode
        }
        if let persistedModel = ShareTweetModel(rawValue: snapshot.modelRawValue) {
            selectedModel = persistedModel
        }
        if let persistedDraftCount = DraftCountOption(rawValue: snapshot.draftCount) {
            draftCount = persistedDraftCount
        }

        suppressSourceReload = true
        includeFullThread = snapshot.includeFullThread
        intention = snapshot.intention ?? ""
        feedback = snapshot.feedback ?? ""

        let source = snapshot.sourceTweetTextSnapshot.trimmingCharacters(in: .whitespacesAndNewlines)
        if !source.isEmpty {
            sourceTweetText = source
            if snapshot.includeFullThread {
                cachedThread = source
            } else {
                cachedSingle = source
            }
        }
    }

    private func persistGeneratedDrafts(_ drafts: [GeneratedTweetDraft], intention: String?, feedback: String?, usedThread: Bool) {
        let cleanedDrafts = drafts.compactMap { draft -> GeneratedTweetDraft? in
            let cES = draft.es.trimmingCharacters(in: .whitespacesAndNewlines)
            let cEN = draft.en.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !cES.isEmpty || !cEN.isEmpty else { return nil }
            return GeneratedTweetDraft(es: cES, en: cEN.isEmpty ? cES : cEN)
        }
        guard !cleanedDrafts.isEmpty else { return }

        do {
            let conv = try resolveConvWrite()
            conv.updatedAt = Date()
            conv.sourceTweetText = src
            conv.lastModeRawValue = mode.rawValue
            conv.lastIntention = sanitize(intention)

            var firstInsertedId: UUID?
            for draft in cleanedDrafts {
                let ver = TweetVersion(
                    modeRawValue: mode.rawValue,
                    intention: sanitize(intention),
                    feedback: sanitize(feedback),
                    modelRawValue: selectedModel.rawValue,
                    usedFullThread: usedThread,
                    sourceTweetTextSnapshot: src,
                    contentES: draft.es,
                    contentEN: draft.en,
                    conversation: conv
                )
                if firstInsertedId == nil {
                    firstInsertedId = ver.id
                }
                modelContext.insert(ver)
            }

            try modelContext.save()
            activeConvId = conv.id
            trackedJobID = nil
            loadPersistedConv()
            if let firstInsertedId,
               let selectedVersion = versions.first(where: { $0.id == firstInsertedId }) {
                applyVersion(selectedVersion)
            }
        } catch {
            localErrorMsg = "Generated but could not save."
            LoggingService.logToFile(level: .error, message: "[ShareTweetUI] persist failed: \(error)")
        }
    }

    @discardableResult
    private func persistConversationCheckpoint(sourceSnapshot: String, intention: String?) throws -> TweetConversation {
        let conversation = try resolveConvWrite()
        conversation.updatedAt = Date()
        conversation.sourceTweetText = sourceSnapshot
        conversation.lastModeRawValue = mode.rawValue
        conversation.lastIntention = sanitize(intention)
        try modelContext.save()
        activeConvId = conversation.id
        return conversation
    }

    private func fetchPersistedConversationSnapshot() -> PersistedConversationSnapshot? {
        do {
            let container = try TweetGeneratorModelStore.makeSharedModelContainer()
            let context = ModelContext(container)

            let conversation: TweetConversation?
            if let activeConvId {
                let descriptor = FetchDescriptor<TweetConversation>(
                    predicate: #Predicate<TweetConversation> { $0.id == activeConvId }
                )
                conversation = try context.fetch(descriptor).first
            } else {
                let descriptor = FetchDescriptor<TweetConversation>(
                    predicate: #Predicate<TweetConversation> { $0.sourceTweetURL == tweetURL }
                )
                conversation = try context.fetch(descriptor).max(by: { $0.updatedAt < $1.updatedAt })
            }

            guard let conversation else { return nil }

            let versions = conversation.sortedVersionsAscending.enumerated().map { index, version in
                Ver(
                    id: version.id,
                    num: index + 1,
                    createdAt: version.createdAt,
                    mode: Mode(rawValue: version.modeRawValue) ?? .reply,
                    intention: version.intention,
                    feedback: version.feedback,
                    modelRawValue: version.modelRawValue,
                    usedFullThread: version.usedFullThread,
                    sourceSnapshot: version.sourceTweetTextSnapshot,
                    es: version.contentES,
                    en: version.contentEN
                )
            }

            return PersistedConversationSnapshot(
                id: conversation.id,
                sourceTweetText: conversation.sourceTweetText,
                lastModeRawValue: conversation.lastModeRawValue,
                lastIntention: conversation.lastIntention,
                versions: versions,
                latestVersionID: conversation.latestVersion?.id
            )
        } catch {
            LoggingService.logToFile(level: .error, message: "[ShareTweetUI] snapshot read failed: \(error)")
            return nil
        }
    }

    private func resolveConvRead() -> TweetConversation? {
        if let id = activeConvId, let c = fetchConv(id: id) { return c }
        return fetchConvByURL(tweetURL)
    }

    private func resolveConvWrite() throws -> TweetConversation {
        if let c = resolveConvRead() { activeConvId = c.id; return c }
        let c = TweetConversation(sourceTweetURL: tweetURL, sourceTweetText: src, lastModeRawValue: mode.rawValue, lastIntention: sanitize(intention))
        modelContext.insert(c); try modelContext.save(); activeConvId = c.id; return c
    }

    private func fetchConv(id: UUID) -> TweetConversation? {
        let d = FetchDescriptor<TweetConversation>(predicate: #Predicate<TweetConversation> { $0.id == id })
        return try? modelContext.fetch(d).first
    }

    private func fetchConvByURL(_ url: String) -> TweetConversation? {
        let d = FetchDescriptor<TweetConversation>(predicate: #Predicate<TweetConversation> { $0.sourceTweetURL == url })
        return (try? modelContext.fetch(d))?.max(by: { $0.updatedAt < $1.updatedAt })
    }

    private func fetchLatestRelevantJob() -> TweetGenerationJob? {
        let descriptor: FetchDescriptor<TweetGenerationJob>

        if let activeConvId {
            descriptor = FetchDescriptor<TweetGenerationJob>(
                predicate: #Predicate<TweetGenerationJob> { $0.conversationID == activeConvId },
                sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
            )
        } else {
            descriptor = FetchDescriptor<TweetGenerationJob>(
                predicate: #Predicate<TweetGenerationJob> { $0.sourceTweetURL == tweetURL },
                sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
            )
        }

        return try? modelContext.fetch(descriptor).first
    }

    private func refreshComposerStateFromPersistence() {
        loadPersistedConv()

        let latestJobSnapshot = trackedJobSnapshot ?? {
            guard let latestJob = fetchLatestRelevantJob() else { return nil }
            trackedJobID = latestJob.id
            jobSyncStore.upsert(job: latestJob)
            return jobSyncStore.snapshot(jobID: latestJob.id)
        }()

        guard let latestJobSnapshot else {
            if hostMode == .app, hasDraft {
                markLatestVersionAsSeenIfPossible()
            }
            return
        }

        applyJobSnapshot(latestJobSnapshot)

        switch latestJobSnapshot.status {
        case .queued, .running:
            localErrorMsg = nil
        case .completed:
            loadPersistedConv()
            localErrorMsg = nil
            if hostMode == .app {
                markLatestVersionAsSeenIfPossible()
            }
        case .failed:
            if !hasDraft {
                localErrorMsg = nil
            } else {
                localErrorMsg = nil
            }
        case .cancelled:
            localErrorMsg = nil
        }
    }

    private func cancelActiveJob() {
        guard let snapshot = trackedJobSnapshot else { return }

        Task {
            await TweetGenerationBackgroundCoordinator.shared.cancel(
                jobID: snapshot.id,
                taskIdentifier: snapshot.backgroundTaskIdentifier
            )
            await MainActor.run {
                jobSyncStore.refreshNow()
                refreshComposerStateFromPersistence()
            }
        }
    }

    private func handleAppDidEnterBackground() {
        jobSyncStore.refreshNow()
    }

    private func markLatestVersionAsSeenIfPossible() {
        guard hostMode == .app,
              let snapshot = fetchPersistedConversationSnapshot(),
              let latestVersionID = snapshot.latestVersionID else {
            return
        }
        TweetConversationReadStore.markSeen(conversationID: snapshot.id, versionID: latestVersionID)
    }

    private func sanitize(_ v: String?) -> String? {
        guard let v else { return nil }
        let t = v.trimmingCharacters(in: .whitespacesAndNewlines)
        return t.isEmpty ? nil : t
    }
}

// MARK: - Button Styles

// Cambio4B #22 — Generate: scale 0.96, damping 0.72 (professional, not playful)
private struct GenerateButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.96 : 1.0)
            .animation(
                .spring(response: 0.2, dampingFraction: 0.72),
                value: configuration.isPressed
            )
    }
}

// Cambio4B #23 — Reply on X: scale 0.95, spring 0.18. Maximum feedback for maximum button.
private struct ReplyButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .animation(
                .spring(response: 0.18, dampingFraction: 0.72),
                value: configuration.isPressed
            )
    }
}

@MainActor
private final class VoiceRecorderController: NSObject, ObservableObject, AVAudioRecorderDelegate {
    enum CaptureMode {
        case idle
        case locked
    }

    enum ErrorState: Swift.Error {
        case microphoneDenied
        case cannotConfigureSession
        case cannotStartRecording
        case noRecordingAvailable

        var message: String {
            switch self {
            case .microphoneDenied:
                return "Microphone access is required."
            case .cannotConfigureSession:
                return "Could not prepare the microphone."
            case .cannotStartRecording:
                return "Could not start recording."
            case .noRecordingAvailable:
                return "No voice note was captured."
            }
        }
    }

    @Published private(set) var captureMode: CaptureMode = .idle
    @Published private(set) var level: CGFloat = 0
    @Published private(set) var duration: TimeInterval = 0

    var isRecording: Bool { captureMode != .idle }
    var isLocked: Bool { captureMode == .locked }
    var formattedDuration: String {
        let totalSeconds = Int(duration.rounded(.down))
        return String(format: "%02d:%02d", totalSeconds / 60, totalSeconds % 60)
    }

    private var recorder: AVAudioRecorder?
    private var meterTimer: Timer?
    private var activeRecordingURL: URL?

    func start() async throws {
        guard !isRecording else { return }

        let granted = await requestPermission()
        guard granted else {
            throw ErrorState.microphoneDenied
        }

        let session = AVAudioSession.sharedInstance()
        do {
            var recordingOptions: AVAudioSession.CategoryOptions = [.defaultToSpeaker]
#if compiler(>=6.2)
            recordingOptions.insert(.allowBluetoothHFP)
#else
            recordingOptions.insert(.allowBluetooth)
#endif
            try session.setCategory(.playAndRecord, mode: .spokenAudio, options: recordingOptions)
            try session.setActive(true)
        } catch {
            throw ErrorState.cannotConfigureSession
        }

        let outputURL = makeRecordingURL()
        let settings: [String: Any] = [
            AVFormatIDKey: Int(kAudioFormatMPEG4AAC),
            AVSampleRateKey: 44_100,
            AVNumberOfChannelsKey: 1,
            AVEncoderAudioQualityKey: AVAudioQuality.high.rawValue
        ]

        do {
            let recorder = try AVAudioRecorder(url: outputURL, settings: settings)
            recorder.delegate = self
            recorder.isMeteringEnabled = true
            recorder.prepareToRecord()
            guard recorder.record() else {
                throw ErrorState.cannotStartRecording
            }

            self.recorder = recorder
            self.activeRecordingURL = outputURL
            self.captureMode = .locked
            self.level = 0
            self.duration = 0
            startMetering()
        } catch let state as ErrorState {
            throw state
        } catch {
            throw ErrorState.cannotStartRecording
        }
    }

    func stop() async throws -> URL {
        guard let recorder, let outputURL = activeRecordingURL else {
            throw ErrorState.noRecordingAvailable
        }

        recorder.stop()
        stopMetering()
        self.recorder = nil
        self.captureMode = .idle
        self.level = 0
        self.duration = 0
        self.activeRecordingURL = nil

        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            LoggingService.logToFile(level: .error, message: "[VoiceRecorder] Failed to deactivate session: \(error)")
        }

        guard FileManager.default.fileExists(atPath: outputURL.path) else {
            throw ErrorState.noRecordingAvailable
        }
        return outputURL
    }

    func cancel() {
        recorder?.stop()
        if let activeRecordingURL {
            try? FileManager.default.removeItem(at: activeRecordingURL)
        }
        recorder = nil
        activeRecordingURL = nil
        captureMode = .idle
        level = 0
        duration = 0
        stopMetering()
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }

    nonisolated func audioRecorderEncodeErrorDidOccur(_ recorder: AVAudioRecorder, error: Swift.Error?) {
        if let error {
            LoggingService.logToFile(level: .error, message: "[VoiceRecorder] Encode error: \(error)")
        }
    }

    private func requestPermission() async -> Bool {
        await AVAudioApplication.requestRecordPermission()
    }

    private func makeRecordingURL() -> URL {
        let directory = (try? SharedInbox.ensureDirectory(named: "VoiceRecordings")) ?? FileManager.default.temporaryDirectory
        return directory.appendingPathComponent("voice-\(UUID().uuidString).m4a")
    }

    private func startMetering() {
        stopMetering()
        meterTimer = Timer.scheduledTimer(withTimeInterval: 0.06, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.refreshMetering()
            }
        }
        RunLoop.main.add(meterTimer!, forMode: .common)
    }

    private func stopMetering() {
        meterTimer?.invalidate()
        meterTimer = nil
    }

    private func refreshMetering() {
        guard let recorder else { return }
        recorder.updateMeters()
        let power = recorder.averagePower(forChannel: 0)
        let normalized = max(0, min(1, (power + 50) / 50))
        level = CGFloat(normalized)
        duration = recorder.currentTime
    }
}
