import AppKit
import SwiftUI

/// Opt-in capture support for repository documentation. Normal launches do
/// nothing; maintainers enable it with `FERMIN_REPOSITORY_SCREENSHOT_PATH`.
struct FerminCodeDesktopRepositoryScreenshotCapture: NSViewRepresentable {
    final class Coordinator {
        var scheduled = false
        var attempts = 0
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> NSView {
        let view = NSView(frame: .zero)
        schedule(from: view, coordinator: context.coordinator)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        schedule(from: view, coordinator: context.coordinator)
    }

    private func schedule(from view: NSView, coordinator: Coordinator) {
        guard !coordinator.scheduled, outputURL != nil else { return }
        coordinator.scheduled = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 7) {
            capture(from: view, coordinator: coordinator)
        }
    }

    private func capture(from view: NSView, coordinator: Coordinator) {
        let contentView = ProcessInfo.processInfo.environment["FERMIN_REPOSITORY_SCREENSHOT_MODE"] == "history"
            ? NSApp.keyWindow?.contentView
            : view.window?.contentView
        guard let outputURL,
              let contentView,
              contentView.bounds.width >= 900,
              contentView.bounds.height >= 600,
              let bitmap = contentView.bitmapImageRepForCachingDisplay(in: contentView.bounds)
        else {
            retry(from: view, coordinator: coordinator)
            return
        }

        contentView.layoutSubtreeIfNeeded()
        contentView.cacheDisplay(in: contentView.bounds, to: bitmap)
        guard let png = bitmap.representation(using: .png, properties: [:]) else { return }

        do {
            try FileManager.default.createDirectory(
                at: outputURL.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try png.write(to: outputURL, options: .atomic)
        } catch {
            retry(from: view, coordinator: coordinator)
        }
    }

    private func retry(from view: NSView, coordinator: Coordinator) {
        guard coordinator.attempts < 8 else { return }
        coordinator.attempts += 1
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            capture(from: view, coordinator: coordinator)
        }
    }

    private var outputURL: URL? {
        guard let path = ProcessInfo.processInfo.environment["FERMIN_REPOSITORY_SCREENSHOT_PATH"],
              !path.isEmpty else { return nil }
        return URL(fileURLWithPath: path)
    }
}
