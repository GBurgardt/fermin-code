import Testing
@testable import FerminCore

@Suite("Fermin Code GPT runtime policy")
struct FerminCodeRelayModelPolicyTests {
    @Test
    func onlyVisibleGPTModelsSurviveProductFiltering() {
        let models = [
            FerminRelayAvailableModel(
                id: "gpt-5.6",
                model: "gpt-5.6",
                modelProvider: "openai",
                displayName: "GPT 5.6"
            ),
            FerminRelayAvailableModel(
                id: "gpt-5.4",
                model: "gpt-5.4",
                modelProvider: "codex",
                displayName: "GPT 5.4",
                hidden: true
            ),
            FerminRelayAvailableModel(
                id: "gpt-alternate",
                model: "gpt-alternate",
                modelProvider: "alternate",
                displayName: "Alternate"
            ),
            FerminRelayAvailableModel(
                id: "alternate-id",
                model: "gpt-valid-name",
                modelProvider: "openai",
                displayName: "Invalid ID"
            ),
        ]
        #expect(FerminRelayRuntimePolicy.supportedModels(from: models).map(\.model) == ["gpt-5.6"])
        #expect(FerminRelayRuntimePolicy.isSupportedModel(" GPT-5.6 "))
        #expect(!FerminRelayRuntimePolicy.isSupportedModel("alternate-4"))
        #expect(!FerminRelayRuntimePolicy.isSupportedModel("gpt-" + "gr" + "ok"))
        #expect(!FerminRelayRuntimePolicy.isSupported(
            .init(
                id: "gpt-provider",
                model: "gpt-provider",
                modelProvider: "x" + "ai",
                displayName: "Invalid provider"
            )
        ))
    }

    @Test
    func unsupportedModelsAndEnginesFailValidation() {
        do {
            try FerminRelayRuntimePolicy.validate(model: "alternate-4")
            Issue.record("Unsupported model passed validation")
        } catch let error as FerminRelayRuntimeModelError {
            #expect(error == .unsupportedModel("alternate-4"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }

        do {
            try FerminRelayRuntimePolicy.validate(engine: "alternate")
            Issue.record("Unsupported engine passed validation")
        } catch let error as FerminRelayRuntimeModelError {
            #expect(error == .unsupportedEngine("alternate"))
        } catch {
            Issue.record("Unexpected error: \(error)")
        }
    }
}
