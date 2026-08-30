import UIKit

enum AppHapticEvent: String, CaseIterable, Hashable {
    case newSession
    case connectionPanelOpen
    case connectionPanelClose
    case profileSelection
    case conversationSelection
    case messageSendSuccess
    case messageSendError
    case voiceButtonPress
    case voiceRecordingStart
    case voiceRecordingStop
    case voiceStateTransition
    case destructiveDiscard
    case promptImproverToggle
    case explainerToggle
    case goalModeToggle
    case reconnectRequest
    case sessionDeleteRequest
    case sessionDeleteSuccess
    case sessionDeleteError
}

enum AppHapticPattern: String, Equatable {
    case impactLight
    case impactMedium
    case impactRigid
    case impactSoft
    case selection
    case notificationSuccess
    case notificationWarning
    case notificationError
}

struct AppHapticDescriptor: Equatable {
    let number: Int
    let pattern: AppHapticPattern
    let intensity: CGFloat?
    let purpose: String
}

enum AppHapticCatalog {
    static let descriptors: [AppHapticEvent: AppHapticDescriptor] = [
        .newSession: .init(
            number: 1,
            pattern: .impactMedium,
            intensity: 0.86,
            purpose: "Abrir un nuevo espacio de trabajo"
        ),
        .connectionPanelOpen: .init(
            number: 2,
            pattern: .impactLight,
            intensity: 0.64,
            purpose: "Materializar la llegada de una capa liviana"
        ),
        .connectionPanelClose: .init(
            number: 3,
            pattern: .impactSoft,
            intensity: 0.66,
            purpose: "Cerrar la capa con un aterrizaje amortiguado"
        ),
        .profileSelection: .init(
            number: 4,
            pattern: .selection,
            intensity: nil,
            purpose: "Confirmar un cambio discreto de perfil"
        ),
        .conversationSelection: .init(
            number: 5,
            pattern: .selection,
            intensity: nil,
            purpose: "Confirmar la conversacion que pasa a ser activa"
        ),
        .messageSendSuccess: .init(
            number: 6,
            pattern: .notificationSuccess,
            intensity: nil,
            purpose: "Confirmar que el backend acepto el mensaje"
        ),
        .messageSendError: .init(
            number: 7,
            pattern: .notificationError,
            intensity: nil,
            purpose: "Hacer perceptible un fallo de entrega"
        ),
        .voiceButtonPress: .init(
            number: 14,
            pattern: .impactLight,
            intensity: 0.58,
            purpose: "Confirmar el contacto inmediato con el microfono"
        ),
        .voiceRecordingStart: .init(
            number: 8,
            pattern: .impactRigid,
            intensity: 0.82,
            purpose: "Dar un click preciso antes de abrir el microfono"
        ),
        .voiceRecordingStop: .init(
            number: 9,
            pattern: .impactSoft,
            intensity: 0.74,
            purpose: "Cerrar la captura con un contacto suave"
        ),
        .voiceStateTransition: .init(
            number: 15,
            pattern: .selection,
            intensity: nil,
            purpose: "Marcar el paso de grabacion a transcripcion"
        ),
        .destructiveDiscard: .init(
            number: 10,
            pattern: .notificationWarning,
            intensity: nil,
            purpose: "Comunicar el descarte intencional de audio"
        ),
        .promptImproverToggle: .init(
            number: 11,
            pattern: .selection,
            intensity: nil,
            purpose: "Confirmar el cambio del Prompt Improver custom"
        ),
        .explainerToggle: .init(
            number: 12,
            pattern: .selection,
            intensity: nil,
            purpose: "Confirmar el cambio del Explainer custom"
        ),
        .goalModeToggle: .init(
            number: 19,
            pattern: .impactRigid,
            intensity: 0.72,
            purpose: "Confirmar el cambio de Goal Mode de la sesión"
        ),
        .reconnectRequest: .init(
            number: 13,
            pattern: .impactMedium,
            intensity: 0.76,
            purpose: "Dar peso al compromiso de reintentar"
        ),
        .sessionDeleteRequest: .init(
            number: 16,
            pattern: .notificationWarning,
            intensity: nil,
            purpose: "Confirmar una accion destructiva deliberada"
        ),
        .sessionDeleteSuccess: .init(
            number: 17,
            pattern: .notificationSuccess,
            intensity: nil,
            purpose: "Confirmar que la sesion fue eliminada"
        ),
        .sessionDeleteError: .init(
            number: 18,
            pattern: .notificationError,
            intensity: nil,
            purpose: "Hacer perceptible que el borrado no se completo"
        )
    ]

    static func descriptor(for event: AppHapticEvent) -> AppHapticDescriptor {
        guard let descriptor = descriptors[event] else {
            preconditionFailure("Falta descriptor haptico para \(event.rawValue)")
        }
        return descriptor
    }

}

@MainActor
final class AppHaptics {
    static let shared = AppHaptics()
    nonisolated static let enabledDefaultsKey = "fermin.haptics.enabled"

    private let defaults: UserDefaults
    private var impactGenerators: [AppHapticPattern: UIImpactFeedbackGenerator] = [:]
    private lazy var selectionGenerator = makeSelectionGenerator()
    private lazy var notificationGenerator = makeNotificationGenerator()

    private(set) var lastPlayedEvent: AppHapticEvent?

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var isEnabled: Bool {
        guard defaults.object(forKey: Self.enabledDefaultsKey) != nil else {
            return true
        }
        return defaults.bool(forKey: Self.enabledDefaultsKey)
    }

    func prepare(_ event: AppHapticEvent) {
        guard isEnabled else { return }
        let descriptor = AppHapticCatalog.descriptor(for: event)
        switch descriptor.pattern {
        case .impactLight, .impactMedium, .impactRigid, .impactSoft:
            impactGenerator(for: descriptor.pattern).prepare()
        case .selection:
            selectionGenerator.prepare()
        case .notificationSuccess, .notificationWarning, .notificationError:
            notificationGenerator.prepare()
        }
    }

    func play(_ event: AppHapticEvent) {
        guard isEnabled else { return }
        let descriptor = AppHapticCatalog.descriptor(for: event)
        lastPlayedEvent = event

        switch descriptor.pattern {
        case .impactLight, .impactMedium, .impactRigid, .impactSoft:
            let generator = impactGenerator(for: descriptor.pattern)
            generator.impactOccurred(intensity: descriptor.intensity ?? 1)
            generator.prepare()
        case .selection:
            selectionGenerator.selectionChanged()
            selectionGenerator.prepare()
        case .notificationSuccess:
            playNotification(.success)
        case .notificationWarning:
            playNotification(.warning)
        case .notificationError:
            playNotification(.error)
        }
    }

    private func playNotification(_ type: UINotificationFeedbackGenerator.FeedbackType) {
        notificationGenerator.notificationOccurred(type)
        notificationGenerator.prepare()
    }

    private func impactGenerator(for pattern: AppHapticPattern) -> UIImpactFeedbackGenerator {
        if let generator = impactGenerators[pattern] {
            return generator
        }

        let style: UIImpactFeedbackGenerator.FeedbackStyle
        switch pattern {
        case .impactLight:
            style = .light
        case .impactMedium:
            style = .medium
        case .impactRigid:
            style = .rigid
        case .impactSoft:
            style = .soft
        default:
            preconditionFailure("\(pattern.rawValue) no es un patron de impacto")
        }

        let generator = makeImpactGenerator(style: style)
        generator.prepare()
        impactGenerators[pattern] = generator
        return generator
    }

    private func makeImpactGenerator(style: UIImpactFeedbackGenerator.FeedbackStyle) -> UIImpactFeedbackGenerator {
        if #available(iOS 17.5, *), let view = activeHostView {
            return UIImpactFeedbackGenerator(style: style, view: view)
        }
        return UIImpactFeedbackGenerator(style: style)
    }

    private func makeSelectionGenerator() -> UISelectionFeedbackGenerator {
        if #available(iOS 17.5, *), let view = activeHostView {
            return UISelectionFeedbackGenerator(view: view)
        }
        return UISelectionFeedbackGenerator()
    }

    private func makeNotificationGenerator() -> UINotificationFeedbackGenerator {
        if #available(iOS 17.5, *), let view = activeHostView {
            return UINotificationFeedbackGenerator(view: view)
        }
        return UINotificationFeedbackGenerator()
    }

    private var activeHostView: UIView? {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .first(where: \.isKeyWindow)?
            .rootViewController?
            .view
    }
}
