import SwiftUI

// =============================================================================
// APP THEME — Fermín Code V2.
//
// Scope decisions form defines a restrained physical grammar: near-black
// ground, 3 pt bevels, a one-pixel top light on raised planes and a shallow
// inset treatment for fields. The geometry stays precise rather than soft.
//
// Los nombres legacy (cloudCyan, terminalGreen, electricGlow, glassStroke, …)
// se conservan pero se RE-APUNTAN a los tokens nuevos, de modo que todas las
// superficies de la app heredan la paleta calma sin tocar cada call-site.
// =============================================================================
enum AppTheme {
    // -------------------------------------------------------------------------
    // GROUND & SURFACES
    // -------------------------------------------------------------------------
    static let backgroundSolid   = Color(red: 0.016, green: 0.020, blue: 0.027) // #040507
    static let cardSurface       = Color(red: 0.043, green: 0.051, blue: 0.067) // #0B0D11
    static let inputSurface      = Color(red: 0.031, green: 0.035, blue: 0.051) // #08090D
    static let cardSurfaceRaised = Color(red: 0.071, green: 0.082, blue: 0.102) // #12151A
    static let codeSurface       = Color(red: 0.047, green: 0.055, blue: 0.075) // #0C0E13
    static let selectedSurface   = Color(red: 0.078, green: 0.094, blue: 0.149) // #141826

    // -------------------------------------------------------------------------
    // INK
    // -------------------------------------------------------------------------
    static let ink      = Color(red: 0.980, green: 0.984, blue: 0.992) // #FAFBFD
    static let inkSoft  = Color(red: 0.788, green: 0.808, blue: 0.851) // #C9CED9
    static let inkMuted = Color(red: 0.635, green: 0.663, blue: 0.718) // #A2A9B7
    static let inkTertiary = Color(red: 0.494, green: 0.522, blue: 0.576) // #7E8593

    // -------------------------------------------------------------------------
    // ACCENT — Iris (acción principal + "lo tuyo")
    // -------------------------------------------------------------------------
    static let accent      = Color(red: 0.376, green: 0.408, blue: 0.914) // #6068E9
    static let accentPress = Color(red: 0.310, green: 0.345, blue: 0.824) // #4F58D2
    static let userBubble  = accentPress

    // -------------------------------------------------------------------------
    // ESTADOS (desaturados, no neón)
    // -------------------------------------------------------------------------
    static let statusBusy  = Color(red: 1.000, green: 0.690, blue: 0.250)
    static let statusReady = Color(red: 0.345, green: 0.875, blue: 0.580)
    static let statusError = Color(red: 1.000, green: 0.430, blue: 0.400)
    // idle / offline → inkMuted

    // -------------------------------------------------------------------------
    // LÍNEAS (hairlines)
    // -------------------------------------------------------------------------
    static let line     = Color.white.opacity(0.055)
    static let lineSoft = Color.white.opacity(0.032)
    static let surfaceTopLight = Color.white.opacity(0.075)
    static let surfaceTopLightStrong = Color.white.opacity(0.12)
    static let insetEdge = Color.black.opacity(0.72)

    // -------------------------------------------------------------------------
    // FONDO — casi plano (sin gradiente navy)
    // -------------------------------------------------------------------------
    static let backgroundGradient = Gradient(colors: [backgroundSolid, backgroundSolid])

    static let background = LinearGradient(
        gradient: backgroundGradient,
        startPoint: .top,
        endPoint: .bottom
    )

    // -------------------------------------------------------------------------
    // LEGACY ALIASES — re-apuntados a la paleta calma. No usar en código nuevo.
    // (se conservan sólo para que los call-sites existentes hereden lo nuevo)
    // -------------------------------------------------------------------------
    static let accentSend          = accent
    static let accentGreen         = statusReady
    static let gold                = accent
    static let terminalAccent      = accent
    static let cloudCyan           = accent
    static let cloudMint           = statusReady
    static let cloudBlueDeep       = accentPress
    static let terminalGreen       = statusReady
    static let cloudAccentSoft     = accent.opacity(0.18)

    static let highlightBackground = cardSurfaceRaised
    static let cardSurfaceGlass    = cardSurfaceRaised
    static let commandSurface      = cardSurface
    static let commandBubble       = userBubble
    static let cloudAbyss          = backgroundSolid
    static let cloudPanel          = cardSurface
    static let cloudPanelRaised    = cardSurfaceRaised
    static let cloudComposer       = cardSurface

    static let cardBorder          = line
    static let cardBorderActive    = Color.clear
    static let glassStroke         = line
    static let divider             = line

    static let cloudDanger            = statusError
    static let cloudDangerBackground  = Color(red: 0.149, green: 0.094, blue: 0.094)
    static let cloudWarning           = statusBusy
    static let cloudSuccessBackground = Color(red: 0.090, green: 0.137, blue: 0.118)

    static let chromeHighlight       = surfaceTopLight
    static let chromeHighlightStrong = surfaceTopLightStrong

    // Sombras: sólo negras y suaves. Sin glow de color.
    static let shadowWarm = Color.black.opacity(0.18)
    static let shadowCard = Color.black.opacity(0.24)
    static let shadowDeep = Color.black.opacity(0.34)

    // Glows eliminados → transparentes (los .shadow(color: …Glow) quedan no-op).
    static let electricGlow = Color.clear
    static let mintGlow     = Color.clear

    // =========================================================================
    // SPACING — base 4 → 4 · 8 · 12 · 16 · 20 · 24 · 32
    // =========================================================================
    enum Spacing {
        static let xxs: CGFloat = 4
        static let xs: CGFloat = 8
        static let s: CGFloat = 12
        static let m: CGFloat = 16
        static let ml: CGFloat = 20
        static let l: CGFloat = 24
        static let xl: CGFloat = 32
    }

    // =========================================================================
    // CORNER RADIUS — the authored V2 uses a precise 3 pt bevel.
    // =========================================================================
    enum Radius {
        static let s: CGFloat = 3
        static let m: CGFloat = 3
        static let l: CGFloat = 3
        static let xl: CGFloat = 3
        static let xxl: CGFloat = 3
        static let pill: CGFloat = 3
    }
}

// =============================================================================
// BREATHING BACKGROUND — fondo casi plano, sin highlight teal/azul animado.
// backgroundSolid + un radial muy sutil arriba a la derecha.
// =============================================================================
struct BreathingBackground: View {
    var body: some View {
        ZStack {
            AppTheme.backgroundSolid
            RadialGradient(
                gradient: Gradient(colors: [
                    Color.white.opacity(0.020),
                    Color.clear
                ]),
                center: UnitPoint(x: 0.86, y: 0.04),
                startRadius: 0,
                endRadius: 540
            )
        }
        .ignoresSafeArea(.all)
    }
}

// =============================================================================
// PRESSABLE BUTTON STYLE — respuesta inmediata, sin movimiento si Reduce Motion.
// =============================================================================
struct PressableButtonStyle: ButtonStyle {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var scale: CGFloat = 0.97
    var opacity: Double = 0.92

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed && !reduceMotion ? scale : 1.0)
            .opacity(configuration.isPressed ? opacity : 1.0)
            .animation(
                reduceMotion ? nil : .spring(response: 0.20, dampingFraction: 1.0),
                value: configuration.isPressed
            )
    }
}

// =============================================================================
// PREMIUM CARD MODIFIER — spacing only. Avoids nested visual containers.
// =============================================================================
struct PremiumCardModifier: ViewModifier {
    var padding: CGFloat = 16
    func body(content: Content) -> some View {
        content
            .padding(padding)
            .v2RaisedSurface()
    }
}

struct V2RaisedSurfaceModifier: ViewModifier {
    var fill: Color = AppTheme.cardSurface
    var radius: CGFloat = AppTheme.Radius.s
    var topLight: Color = AppTheme.surfaceTopLight

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(fill)
            )
            .overlay(alignment: .top) {
                Rectangle()
                    .fill(topLight)
                    .frame(height: 1)
                    .padding(.horizontal, radius)
                    .allowsHitTesting(false)
            }
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

struct V2InsetSurfaceModifier: ViewModifier {
    var fill: Color = AppTheme.inputSurface
    var radius: CGFloat = AppTheme.Radius.s

    func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .fill(fill)
                    .shadow(color: AppTheme.insetEdge, radius: 2, x: 0, y: 1)
            )
            .overlay {
                RoundedRectangle(cornerRadius: radius, style: .continuous)
                    .stroke(AppTheme.lineSoft, lineWidth: 1)
                    .allowsHitTesting(false)
            }
            .clipShape(RoundedRectangle(cornerRadius: radius, style: .continuous))
    }
}

extension View {
    func premiumCard(padding: CGFloat = 16) -> some View {
        modifier(PremiumCardModifier(padding: padding))
    }

    func v2RaisedSurface(
        fill: Color = AppTheme.cardSurface,
        radius: CGFloat = AppTheme.Radius.s,
        topLight: Color = AppTheme.surfaceTopLight
    ) -> some View {
        modifier(V2RaisedSurfaceModifier(fill: fill, radius: radius, topLight: topLight))
    }

    func v2InsetSurface(
        fill: Color = AppTheme.inputSurface,
        radius: CGFloat = AppTheme.Radius.s
    ) -> some View {
        modifier(V2InsetSurfaceModifier(fill: fill, radius: radius))
    }
}

// =============================================================================
// SECTION LABEL — encabezado de grupo: 12 · semibold · +tracking · UPPERCASE
// =============================================================================
struct SectionLabel: View {
    let text: String
    var count: Int? = nil

    var body: some View {
        HStack(spacing: 8) {
            Text(text.uppercased())
                .font(.system(size: 12, weight: .semibold, design: .default))
                .foregroundColor(AppTheme.inkMuted)
                .tracking(1.9)
            if let count {
                Text("\(count)")
                    .font(.system(size: 11, weight: .semibold, design: .default))
                    .foregroundColor(AppTheme.inkMuted.opacity(0.8))
            }
        }
    }
}
