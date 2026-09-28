// SPDX-License-Identifier: GPL-3.0-or-later
// Copyright (C) 2026 Vorssaint

import AppKit
import SwiftUI

/// The pill shown while OpenScribe listens and transcribes: a live level
/// meter, the elapsed time, and buttons to finish or cancel. It never takes
/// focus, so the caret stays where the text is going.
final class OpenScribeRecordingPanel {
    static let shared = OpenScribeRecordingPanel()

    private var panel: NSPanel?

    func show() {
        let panel = self.panel ?? makePanel()
        self.panel = panel
        position(panel)
        panel.alphaValue = 0
        panel.orderFrontRegardless()
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.12
            panel.animator().alphaValue = 1
        }
    }

    func hide() {
        guard let panel, panel.isVisible else { return }
        NSAnimationContext.runAnimationGroup({ context in
            context.duration = 0.12
            panel.animator().alphaValue = 0
        }, completionHandler: {
            // A new dictation may have shown it again during the fade.
            if !OpenScribeService.shared.phase.isBusy { panel.orderOut(nil) }
        })
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 260, height: 44),
                            styleMask: [.borderless, .nonactivatingPanel],
                            backing: .buffered, defer: true)
        panel.isFloatingPanel = true
        panel.level = .statusBar
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isReleasedWhenClosed = false
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .stationary, .ignoresCycle]
        let host = NSHostingView(rootView: OpenScribeRecordingView())
        host.frame = panel.contentRect(forFrameRect: panel.frame)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        return panel
    }

    /// Bottom centre of the screen with the pointer, above the Dock.
    private func position(_ panel: NSPanel) {
        guard let screen = NSScreen.withMouse ?? NSScreen.main else { return }
        let size = panel.frame.size
        let frame = screen.visibleFrame
        panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.minY + 36))
    }
}

private struct OpenScribeRecordingView: View {
    @ObservedObject private var service = OpenScribeService.shared
    @ObservedObject private var l10n = L10n.shared

    private var strings: OpenScribeFeatureStrings { FeatureStrings.openScribe(l10n.language) }

    var body: some View {
        HStack(spacing: 10) {
            switch service.phase {
            case .recording(let since):
                Button { service.cancel() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 22, height: 22)
                        .background(Color.primary.opacity(0.1), in: Circle())
                }
                .buttonStyle(.plain)
                .help(strings.cancel)
                LevelBars(level: service.level)
                TimelineView(.periodic(from: since, by: 1)) { context in
                    Text(Self.elapsed(context.date.timeIntervalSince(since)))
                        .font(.system(size: 12, weight: .semibold).monospacedDigit())
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                Button { service.finish() } label: {
                    Image(systemName: "stop.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white)
                        .frame(width: 22, height: 22)
                        .background(Color.red, in: Circle())
                }
                .buttonStyle(.plain)
                .help(strings.stop)
            case .transcribing, .polishing:
                ProgressView().controlSize(.small)
                Text(service.phase == .polishing ? strings.polishing : strings.transcribing)
                    .font(.system(size: 12, weight: .semibold))
                Spacer(minLength: 0)
                Button { service.cancel() } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 22, height: 22)
                        .background(Color.primary.opacity(0.1), in: Circle())
                }
                .buttonStyle(.plain)
                .help(strings.cancel)
            case .idle:
                EmptyView()
            }
        }
        .padding(.horizontal, 11)
        .frame(width: 260, height: 44)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
        .accessibilityElement(children: .contain)
        .accessibilityLabel(strings.title)
    }

    static func elapsed(_ interval: TimeInterval) -> String {
        let seconds = max(0, Int(interval))
        return String(format: "%d:%02d", seconds / 60, seconds % 60)
    }
}

/// A short rolling meter: each bar follows the level with its own damping so
/// speech reads as movement rather than one bouncing block.
private struct LevelBars: View {
    let level: Float
    private static let weights: [CGFloat] = [0.45, 0.7, 1, 0.8, 0.55, 0.9, 0.6]

    var body: some View {
        HStack(alignment: .center, spacing: 3) {
            ForEach(Self.weights.indices, id: \.self) { index in
                Capsule()
                    .fill(Color.accentColor)
                    .frame(width: 3, height: 4 + 16 * CGFloat(level) * Self.weights[index])
            }
        }
        .frame(height: 22)
        .animation(.easeOut(duration: 0.08), value: level)
        .accessibilityHidden(true)
    }
}
