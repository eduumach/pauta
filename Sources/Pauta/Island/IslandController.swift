import AppKit
import Observation
import SwiftUI

/// What the island is currently showing, derived from app state.
enum IslandContent: Equatable {
    case hidden
    case starting
    case recording
    case processing(String)
    case finished(UUID)
}

@MainActor
@Observable
final class IslandModel {
    var expanded = false
    /// Size of the hardware notch, or a menu-bar-height stand-in on screens without one.
    var notch = CGSize(width: 190, height: 32)
    var hasNotch = false

    @ObservationIgnored let app: AppState

    init(app: AppState) { self.app = app }

    var content: IslandContent {
        guard Pref.bool(Pref.showIsland) else { return .hidden }
        switch app.phase {
        case .starting, .stopping: return .starting
        case .recording: return .recording
        case .idle: break
        }
        if let id = app.justFinished { return .finished(id) }
        if let meeting = app.processing.first {
            return .processing(meeting.status == .analyzing ? "Analisando" : "Transcrevendo")
        }
        return .hidden
    }

    static let wing: CGFloat = 48

    /// Persistent one-line caption under the notch while live transcription runs.
    var showsCaption: Bool {
        content == .recording && app.isLiveTranscribing && Pref.bool(Pref.showLiveCaption)
    }

    var collapsedSize: CGSize {
        CGSize(width: notch.width + Self.wing * 2, height: notch.height)
    }

    var size: CGSize {
        switch content {
        case .hidden:
            return .zero
        case .starting:
            return collapsedSize
        case .recording:
            let caption: CGFloat = app.isLiveTranscribing ? 34 : 0
            if expanded { return CGSize(width: max(notch.width + 140, 380), height: notch.height + 100 + caption) }
            if showsCaption { return CGSize(width: max(collapsedSize.width + 110, 380), height: notch.height + 24) }
            return collapsedSize
        case .processing:
            return expanded ? CGSize(width: max(notch.width + 100, 320), height: notch.height + 48) : collapsedSize
        case .finished:
            return CGSize(width: max(notch.width + 120, 340), height: notch.height + 76)
        }
    }
}

/// Borderless panel hugging the top-center of the screen, drawn as an extension of the notch.
final class IslandPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class IslandController {
    static let canvas = CGSize(width: 640, height: 320)

    private let panel: IslandPanel
    private let model: IslandModel
    private var monitors: [Any] = []
    private var collapseTask: Task<Void, Never>?

    init(app: AppState) {
        model = IslandModel(app: app)
        panel = IslandPanel(
            contentRect: NSRect(origin: .zero, size: Self.canvas),
            styleMask: [.borderless, .nonactivatingPanel],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .statusBar + 1
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary, .ignoresCycle]
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false
        panel.isMovable = false
        panel.ignoresMouseEvents = true
        panel.acceptsMouseMovedEvents = true

        let host = NSHostingView(rootView: IslandView(model: model).environment(app))
        host.sizingOptions = []
        panel.contentView = host

        reposition()
        panel.orderFrontRegardless()

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.reposition() }
        }

        let handler: (NSEvent) -> Void = { [weak self] _ in
            MainActor.assumeIsolated { self?.mouseMoved() }
        }
        if let global = NSEvent.addGlobalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: handler) {
            monitors.append(global)
        }
        if let local = NSEvent.addLocalMonitorForEvents(matching: [.mouseMoved, .leftMouseDragged], handler: {
            handler($0)
            return $0
        }) {
            monitors.append(local)
        }
    }

    private var targetScreen: NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 } ?? NSScreen.main
    }

    private func reposition() {
        guard let screen = targetScreen else { return }
        let frame = screen.frame
        if screen.safeAreaInsets.top > 0,
           let left = screen.auxiliaryTopLeftArea, let right = screen.auxiliaryTopRightArea {
            model.notch = CGSize(width: frame.width - left.width - right.width, height: screen.safeAreaInsets.top)
            model.hasNotch = true
        } else {
            let menuBar = frame.maxY - screen.visibleFrame.maxY
            model.notch = CGSize(width: 190, height: max(menuBar, 28))
            model.hasNotch = false
        }
        panel.setFrame(
            NSRect(x: frame.midX - Self.canvas.width / 2, y: frame.maxY - Self.canvas.height,
                   width: Self.canvas.width, height: Self.canvas.height),
            display: true
        )
    }

    /// Rect (in screen coordinates) currently covered by the island for a given size.
    private func screenRect(for size: CGSize) -> NSRect {
        let frame = panel.frame
        return NSRect(x: frame.midX - size.width / 2, y: frame.maxY - size.height,
                      width: size.width, height: size.height)
    }

    private func mouseMoved() {
        let location = NSEvent.mouseLocation
        let content = model.content
        let inside = content != .hidden && screenRect(for: model.size).insetBy(dx: -4, dy: -4).contains(location)
        panel.ignoresMouseEvents = !inside

        let canExpand: Bool = switch content {
        case .recording, .processing: true
        default: false
        }

        if inside && canExpand {
            collapseTask?.cancel()
            if !model.expanded {
                withAnimation(.snappy(duration: 0.22)) { model.expanded = true }
            }
        } else if model.expanded && !inside {
            collapseTask?.cancel()
            collapseTask = Task { [weak self] in
                try? await Task.sleep(for: .milliseconds(250))
                guard let self, !Task.isCancelled else { return }
                // Keep it open while the user is typing a note.
                if self.panel.isKeyWindow, self.panel.firstResponder is NSTextView { return }
                withAnimation(.snappy(duration: 0.2)) { self.model.expanded = false }
            }
        }
    }
}
