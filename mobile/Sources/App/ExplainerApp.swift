import SwiftUI
import UIKit

final class AppDelegate: NSObject, UIApplicationDelegate {
    static let backgroundColor = UIColor(red: 0.016, green: 0.020, blue: 0.027, alpha: 1.0)

    func application(
        _ application: UIApplication,
        didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]? = nil
    ) -> Bool {
        UIWindow.appearance().backgroundColor = Self.backgroundColor
        return true
    }
}

@main
struct ExplainerApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    @StateObject private var backgroundRecording = BackgroundRecordingState()

    init() {
#if DEBUG
        Self.seedLiveConnectionsForUITestIfRequested()
#endif
        UIView.appearance(whenContainedInInstancesOf: [UIAlertController.self]).tintColor = UIColor(AppTheme.ink)
        UIWindow.appearance().backgroundColor = AppDelegate.backgroundColor
    }

#if DEBUG
    private static func seedLiveConnectionsForUITestIfRequested() {
        let environment = ProcessInfo.processInfo.environment
        let pukyToken = environment["KYCODE_UI_TEST_LIVE_PUKY_TOKEN"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let personalToken = environment["KYCODE_UI_TEST_LIVE_PERSONAL_TOKEN"]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let shouldSeedPuky = environment["KYCODE_UI_TEST_LIVE_PUKY"] == "1" && pukyToken?.isEmpty == false
        let shouldSeedPersonal = environment["KYCODE_UI_TEST_LIVE_PERSONAL"] == "1" && personalToken?.isEmpty == false
        guard shouldSeedPuky || shouldSeedPersonal else { return }

        // A live QA launch must never inherit mock or stale profile endpoints
        // left by another test. Rebuild the canonical profile list while
        // preserving the per-profile Keychain entries used by the real app.
        UserDefaults.standard.removeObject(forKey: "kycode.mobile.connectionProfiles")
        UserDefaults.standard.removeObject(forKey: "kycode.mobile.baseURL")
        UserDefaults.standard.removeObject(forKey: "kycode.mobile.cachedSessions.v1")
        UserDefaults.standard.removeObject(forKey: "kycode.mobile.recentCreatedSessions")
        UserDefaults.standard.removeObject(forKey: "kycode.mobile.sessionDisplayOrders.v1")
        UserDefaults.standard.removeObject(forKey: "kycode.mobile.dashboardSearch")
        UserDefaults.standard.removeObject(forKey: "kycode.mobile.dashboardFilter")
        UserDefaults.standard.removeObject(forKey: "kycode.mobile.showMinimizedSessions")
        UserDefaults.standard.removeObject(forKey: "kycode.mobile.pinnedWindowIds")
        UserDefaults.standard.removeObject(forKey: "kycode.mobile.unpinnedWindowIds.v1")
        if shouldSeedPuky, let pukyToken {
            KycodeKeychain.saveAuthToken(pukyToken, profileId: "puky")
        }
        if shouldSeedPersonal, let personalToken {
            KycodeKeychain.saveAuthToken(personalToken, profileId: "personal")
        }
        let requestedProfile = environment["KYCODE_UI_TEST_SELECTED_PROFILE"]
        let selectedProfile = ["puky", "personal", "all"].contains(requestedProfile ?? "")
            ? requestedProfile!
            : (shouldSeedPuky ? "puky" : "personal")
        UserDefaults.standard.set(selectedProfile, forKey: "kycode.mobile.selectedProfileId")
    }

#endif

    var body: some Scene {
        WindowGroup {
            rootContent
        }
    }

    @ViewBuilder
    private var rootContent: some View {
#if DEBUG
        if ProcessInfo.processInfo.environment["KYCODE_UI_TEST_SUBAGENT_PARENT_NOTE"] == "1" {
            SubagentParentNoteEditorUITestHarness()
                .preferredColorScheme(.dark)
        } else if ProcessInfo.processInfo.environment["KYCODE_UI_TEST_RENAME_EDITOR"] == "1" {
            SessionNameEditorUITestHarness()
                .preferredColorScheme(.dark)
        } else if ProcessInfo.processInfo.environment["KYCODE_UI_TEST_PENDING_SESSION"] == "1" {
            PendingCreatedSessionUITestHarness()
                .preferredColorScheme(.dark)
        } else if ProcessInfo.processInfo.environment["KYCODE_UI_TEST_COMPACT_ACTION_TARGETS"] == "1" {
            CompactActionTouchTargetsUITestHarness()
                .preferredColorScheme(.dark)
        } else if ProcessInfo.processInfo.environment["KYCODE_UI_TEST_EXPLANATION_VIEWER"] == "1" {
            ExplanationViewerUITestHarness()
                .preferredColorScheme(.dark)
        } else if ProcessInfo.processInfo.environment["KYCODE_UI_TEST_PROMPT_RECONCILIATION"] == "1" {
            PromptImproverReconciliationUITestHarness()
                .preferredColorScheme(.dark)
        } else if ProcessInfo.processInfo.environment["KYCODE_UI_TEST_PROMPT_TIMEOUT"] == "1" {
            PromptImproverTimeoutUITestHarness()
                .preferredColorScheme(.dark)
        } else if ProcessInfo.processInfo.environment["KYCODE_UI_TEST_PROMPT_RETRY_FALLBACK"] == "1" {
            PromptImproverFallbackRetryUITestHarness(startsWithStaleFallback: false)
                .preferredColorScheme(.dark)
        } else if ProcessInfo.processInfo.environment["KYCODE_UI_TEST_PROMPT_RETRY_STALE_FALLBACK"] == "1" {
            PromptImproverFallbackRetryUITestHarness(startsWithStaleFallback: true)
                .preferredColorScheme(.dark)
        } else if ProcessInfo.processInfo.environment["KYCODE_UI_TEST_PROMPT_FAILURE"] == "1" {
            PromptImproverFailureUITestHarness()
                .preferredColorScheme(.dark)
        } else if ProcessInfo.processInfo.environment["KYCODE_UI_TEST_PROMPT_READER"] == "1" {
            PromptImproverUITestHarness()
                .preferredColorScheme(.dark)
        } else if ProcessInfo.processInfo.environment["KYCODE_UI_TEST_HISTORY_RETRY"] == "1" {
            SessionHistoryRetryUITestHarness()
                .preferredColorScheme(.dark)
        } else if ProcessInfo.processInfo.environment["KYCODE_UI_TEST_COMPOSER_OVERLAP"] == "1" {
            ComposerOverlapUITestHarness()
                .preferredColorScheme(.dark)
        } else if ProcessInfo.processInfo.environment["KYCODE_UI_TEST_COMPOSER_ACTION_PRIORITY"] == "1" {
            ComposerActionPriorityUITestHarness()
                .preferredColorScheme(.dark)
        } else if ProcessInfo.processInfo.environment["KYCODE_UI_TEST_SESSION_METADATA"] == "1" {
            DashboardSessionMetadataUITestHarness()
                .preferredColorScheme(.dark)
        } else if ProcessInfo.processInfo.environment["KYCODE_UI_TEST_VOICE_CAPTURE_LATENCY"] == "1" {
            VoiceCaptureLatencyUITestHarness()
                .preferredColorScheme(.dark)
        } else if ProcessInfo.processInfo.environment["KYCODE_UI_TEST_PHONE_RECORDING_PARITY"] == "1" {
            PhoneRecordingParityUITestHarness()
                .preferredColorScheme(.dark)
        } else if ProcessInfo.processInfo.environment["KYCODE_UI_TEST_SERVER_SWITCHER"] == "1" {
            ServerSwitcherUITestHarness()
                .preferredColorScheme(.dark)
        } else if ProcessInfo.processInfo.environment["KYCODE_UI_TEST_FULL_SCREEN_EDITOR"] == "1" {
            FullScreenTextEditorUITestHarness()
                .preferredColorScheme(.dark)
        } else if ProcessInfo.processInfo.environment["KYCODE_UI_TEST_TRANSCRIPT_BOTTOM_JUMP"] == "1" {
            TranscriptBottomJumpUITestHarness()
                .preferredColorScheme(.dark)
        } else if ProcessInfo.processInfo.environment["KYCODE_UI_TEST_TRANSCRIPT_AVAILABILITY"] == "1" {
            TranscriptAvailabilityUITestHarness()
                .preferredColorScheme(.dark)
        } else if ProcessInfo.processInfo.environment["KYCODE_UI_TEST_VOICE_ISOLATION"] == "1" {
            VoiceIsolationUITestHarness()
                .preferredColorScheme(.dark)
        } else if ProcessInfo.processInfo.environment["KYCODE_UI_TEST_GOAL_MODE"] == "1" {
            GoalModeUITestHarness()
                .preferredColorScheme(.dark)
        } else if ProcessInfo.processInfo.environment["KYCODE_UI_TEST_FEATURE_TOGGLES"] == "1" {
            FeatureToggleMutationUITestHarness()
                .preferredColorScheme(.dark)
        } else if ProcessInfo.processInfo.environment["KYCODE_UI_TEST_RUNTIME_SWITCHER"] == "1" {
            RuntimeModelSwitcherUITestHarness()
                .preferredColorScheme(.dark)
        } else if ProcessInfo.processInfo.environment["KYCODE_UI_TEST_FILE_VIEWER"] == "1"
            || ProcessInfo.processInfo.environment["KYCODE_UI_TEST_MARKDOWN_VIEWER"] == "1" {
            FileViewerUITestHarness(
                autoOpenMarkdown:
                    ProcessInfo.processInfo.environment["KYCODE_UI_TEST_MARKDOWN_VIEWER"] == "1"
            )
                .preferredColorScheme(.dark)
        } else {
            productionRoot
        }
#else
        productionRoot
#endif
    }

    private var productionRoot: some View {
        KycodeRootView()
            .environmentObject(backgroundRecording)
            .background(AppTheme.background.ignoresSafeArea(.all))
            .preferredColorScheme(.dark)
    }
}
