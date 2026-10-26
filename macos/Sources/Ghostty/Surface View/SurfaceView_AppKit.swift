import AppKit
import Combine
import SwiftUI
import CoreText
import UserNotifications
import GhosttyKit

extension JTerm {
    /// The NSView implementation for a terminal surface.
    class SurfaceView: OSView, ObservableObject, Codable, Identifiable {
        typealias ID = UUID

        /// Unique ID per surface
        let id: UUID

        // The current title of the surface as defined by the pty. This can be
        // changed with escape codes. This is public because the callbacks go
        // to the app level and it is set from there.
        @Published private(set) var title: String = "" {
            didSet {
                if !title.isEmpty {
                    titleFallbackTimer?.invalidate()
                    titleFallbackTimer = nil
                }
            }
        }

        // The current pwd of the surface as defined by the pty. This can be
        // changed with escape codes.
        @Published var pwd: String? = nil

        // The cell size of this surface. This is set by the core when the
        // surface is first created and any time the cell size changes (i.e.
        // when the font size changes). This is used to allow windows to be
        // resized in discrete steps of a single cell.
        @Published var cellSize: NSSize = .zero

        // The health state of the surface. This currently only reflects the
        // renderer health. In the future we may want to make this an enum.
        @Published var healthy: Bool = true

        // Any error while initializing the surface.
        @Published var error: Error? = nil

        // The hovered URL string
        @Published var hoverUrl: String? = nil

        // The progress report (if any)
        @Published var progressReport: Action.ProgressReport? = nil {
            didSet {
                // Cancel any existing timer
                progressReportTimer?.invalidate()
                progressReportTimer = nil

                // If we have a new progress report, start a timer to remove it after 15 seconds
                if progressReport != nil {
                    progressReportTimer = Timer.scheduledTimer(withTimeInterval: 15.0, repeats: false) { [weak self] _ in
                        self?.progressReport = nil
                        self?.progressReportTimer = nil
                    }
                }
            }
        }

        // The currently active key sequence. The sequence is not active if this is empty.
        @Published var keySequence: [KeyboardShortcut] = []

        // The currently active key tables. Empty if no tables are active.
        @Published var keyTables: [String] = []

        // The current search state. When non-nil, the search overlay should be shown.
        @Published var searchState: SearchState? = nil {
            didSet {
                if let searchState {
                    // I'm not a Combine expert so if there is a better way to do this I'm
                    // all ears. What we're doing here is grabbing the latest needle. If the
                    // needle is less than 3 chars, we debounce it for a few hundred ms to
                    // avoid kicking off expensive searches.
                    searchNeedleCancellable = searchState.$needle
                        .removeDuplicates()
                        .map { needle -> AnyPublisher<String, Never> in
                            if needle.isEmpty || needle.count >= 3 {
                                return Just(needle).eraseToAnyPublisher()
                            } else {
                                return Just(needle)
                                    .delay(for: .milliseconds(300), scheduler: DispatchQueue.main)
                                    .eraseToAnyPublisher()
                            }
                        }
                        .switchToLatest()
                        .sink { [weak self] needle in
                            guard let surface = self?.surface else { return }
                            let action = "search:\(needle)"
                            ghostty_surface_binding_action(surface, action, UInt(action.lengthOfBytes(using: .utf8)))
                        }
                } else if oldValue != nil {
                    searchNeedleCancellable = nil
                    guard let surface = self.surface else { return }
                    let action = "end_search"
                    ghostty_surface_binding_action(surface, action, UInt(action.lengthOfBytes(using: .utf8)))
                }
            }
        }

        // Cancellable for search state needle changes
        private var searchNeedleCancellable: AnyCancellable?

        // The time this surface last became focused. This is a ContinuousClock.Instant
        // on supported platforms.
        @Published var focusInstant: ContinuousClock.Instant? = nil

        // Returns sizing information for the surface. This is the raw C
        // structure because I'm lazy.
        @Published var surfaceSize: ghostty_surface_size_s? = nil

        // Whether the pointer should be visible or not
        @Published private(set) var pointerStyle: CursorStyle = .horizontalText

        /// The configuration derived from the JTerm config so we don't need to rely on references.
        @Published private(set) var derivedConfig: DerivedConfig

        /// The background color within the color palette of the surface. This is only set if it is
        /// dynamically updated. Otherwise, the background color is the default background color.
        @Published private(set) var backgroundColor: Color? = nil

        /// True when the bell is active. This is set inactive on focus or event.
        @Published private(set) var bell: Bool = false

        /// True when the surface is in readonly mode.
        @Published private(set) var readonly: Bool = false

        /// True when the surface should show a highlight effect (e.g., when presented via goto_split).
        @Published private(set) var highlighted: Bool = false

        // An initial size to request for a window. This will only affect
        // then the view is moved to a new window.
        var initialSize: NSSize? = nil

        // A content size received through sizeDidChange that may in some cases
        // be different from the frame size.
        private var contentSizeBacking: NSSize?
        private var contentSize: NSSize {
            get { return contentSizeBacking ?? frame.size }
            set { contentSizeBacking = newValue }
        }

        // Set whether the surface is currently on a password input or not. This is
        // detected with the set_password_input_cb on the JTerm state.
        var passwordInput: Bool = false {
            didSet {
                // We need to update our state within the SecureInput manager.
                let input = SecureInput.shared
                let id = ObjectIdentifier(self)
                if (passwordInput) {
                    input.setScoped(id, focused: focused)
                } else {
                    input.removeScoped(id)
                }
            }
        }

        // Returns true if quit confirmation is required for this surface to
        // exit safely.
        var needsConfirmQuit: Bool {
            guard let surface = self.surface else { return false }
            return ghostty_surface_needs_confirm_quit(surface)
        }

        // Returns true if the process in this surface has exited.
        var processExited: Bool {
            guard let surface = self.surface else { return true }
            return ghostty_surface_process_exited(surface)
        }

        // Returns the inspector instance for this surface, or nil if the
        // surface has been closed or no inspector is active.
        var inspector: JTerm.Inspector? {
            guard let surface = self.surface else { return nil }
            guard let cInspector = ghostty_surface_inspector(surface) else { return nil }
            return JTerm.Inspector(cInspector: cInspector)
        }

        // True if the inspector should be visible
        @Published var inspectorVisible: Bool = false {
            didSet {
                if (oldValue && !inspectorVisible) {
                    guard let surface = self.surface else { return }
                    ghostty_inspector_free(surface)
                }
            }
        }

        /// Returns the data model for this surface.
        ///
        /// Note: eventually, all surface access will be through this, but presently its in a transition
        /// state so we're mixing this with direct surface access.
        private(set) var surfaceModel: JTerm.Surface?

        /// Returns the underlying C value for the surface. See "note" on surfaceModel.
        var surface: ghostty_surface_t? {
            surfaceModel?.unsafeCValue
        }
        /// Current scrollbar state, cached here for persistence across rebuilds
        /// of the SwiftUI view hierarchy, for example when changing splits
        var scrollbar: JTerm.Action.Scrollbar?

        // Notification identifiers associated with this surface
        var notificationIdentifiers: Set<String> = []

        private var markedText: NSMutableAttributedString
        private(set) var focused: Bool = true
        private var prevPressureStage: Int = 0
        private var appearanceObserver: NSKeyValueObservation? = nil

        // This is set to non-null during keyDown to accumulate insertText contents
        private var keyTextAccumulator: [String]? = nil

        // A small delay that is introduced before a title change to avoid flickers
        private var titleChangeTimer: Timer?

        // A timer to fallback to ghost emoji if no title is set within the grace period
        private var titleFallbackTimer: Timer?

        // Timer to remove progress report after 15 seconds
        private var progressReportTimer: Timer?

        // This is the title from the terminal. This is nil if we're currently using
        // the terminal title as the main title property. If the title is set manually
        // by the user, this is set to the prior value (which may be empty, but non-nil).
        private var titleFromTerminal: String?

        // The cached contents of the screen.
        private(set) var cachedScreenContents: CachedValue<String>
        private(set) var cachedVisibleContents: CachedValue<String>

        private struct PromptInputSnapshot {
            let x: CGFloat
            let yTop: CGFloat
            let width: CGFloat
            let height: CGFloat
            let text: String
        }

        private enum ComposeExitReason {
            case commit
            case cancel
            case blur
        }

        private enum ComposeActivationContext {
            case shellPrompt
            case claudeTui
        }

        private enum ComposeDebugMode: String {
            case full = "full"
            case appkitOnly = "appkit_only"
            case terminalOnly = "terminal_only"

            static func current() -> ComposeDebugMode {
                let value = ProcessInfo.processInfo.environment["JTERM_COMPOSE_DEBUG_MODE"]?
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .lowercased()
                switch value {
                case Self.appkitOnly.rawValue:
                    return .appkitOnly
                case Self.terminalOnly.rawValue:
                    return .terminalOnly
                default:
                    return .full
                }
            }
        }

        /// Text view used for native compose editing with a thin word-processor style caret.
        private final class ComposeTextView: NSTextView {
            var onCommit: (() -> Void)?
            var onCancel: (() -> Void)?
            var onTab: (() -> Void)?
            var onKeyDownOverride: ((NSEvent) -> Bool)?
            var onInsertionPointDraw: ((NSRect, Bool) -> Void)?
            var onMouseDownOverride: ((NSEvent) -> Bool)?
            var onMouseDraggedOverride: ((NSEvent) -> Bool)?
            var onMouseUpOverride: ((NSEvent) -> Bool)?
            override var isOpaque: Bool { true }

            override func keyDown(with event: NSEvent) {
                if onKeyDownOverride?(event) == true { return }
                switch event.keyCode {
                case 36, 76: // Return / Keypad Enter
                    let mods = event.modifierFlags.intersection([.shift, .control, .option, .command, .function])
                    if mods == [.shift] {
                        super.keyDown(with: event)
                        return
                    }
                    onCommit?()
                    return
                case 53: // Escape
                    onCancel?()
                    return
                case 48: // Tab
                    onTab?()
                    return
                default:
                    break
                }

                super.keyDown(with: event)
            }

            override func draw(_ dirtyRect: NSRect) {
                // Match terminal-like glyph crispness by avoiding subpixel glyph
                // positioning/quantization in the overlay text rasterization path.
                if let ctx = NSGraphicsContext.current?.cgContext {
                    ctx.saveGState()
                    ctx.setAllowsFontSubpixelPositioning(false)
                    ctx.setShouldSubpixelPositionFonts(false)
                    ctx.setAllowsFontSubpixelQuantization(false)
                    ctx.setShouldSubpixelQuantizeFonts(false)
                    super.draw(dirtyRect)
                    ctx.restoreGState()
                    return
                }
                super.draw(dirtyRect)
            }

            override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
                _ = rect
                _ = color
                onInsertionPointDraw?(rect, flag)
                // We render our own compose caret view to avoid stale AppKit
                // insertion-point artifacts on transparent/overlaid rows.
            }

            override func mouseDown(with event: NSEvent) {
                if onMouseDownOverride?(event) == true { return }
                super.mouseDown(with: event)
            }

            override func mouseDragged(with event: NSEvent) {
                if onMouseDraggedOverride?(event) == true { return }
                super.mouseDragged(with: event)
            }

            override func mouseUp(with event: NSEvent) {
                if onMouseUpOverride?(event) == true { return }
                super.mouseUp(with: event)
            }
        }

        /// Opaque mask that hides the underlying terminal row while compose is active.
        private final class ComposeMaskView: NSView {
            private let bottomDivider = CALayer()
            var fillColor: CGColor? {
                didSet {
                    layer?.backgroundColor = fillColor
                }
            }
            var dividerColor: CGColor? {
                didSet {
                    bottomDivider.backgroundColor = dividerColor
                }
            }
            var showsBottomDivider: Bool = false {
                didSet {
                    bottomDivider.isHidden = !showsBottomDivider
                    needsLayout = true
                }
            }

            override var isOpaque: Bool { true }

            override init(frame frameRect: NSRect) {
                super.init(frame: frameRect)
                wantsLayer = true
                layer?.masksToBounds = true
                bottomDivider.isHidden = true
                layer?.addSublayer(bottomDivider)
            }

            required init?(coder: NSCoder) {
                fatalError("init(coder:) has not been implemented")
            }

            override func layout() {
                super.layout()
                let scale = window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2.0
                let pixel = max(0.5, 1.0 / scale)
                bottomDivider.frame = CGRect(
                    x: 0,
                    y: 0,
                    width: bounds.width,
                    height: pixel
                )
            }
        }

        private final class ComposeCaretView: NSView {
            var color: NSColor = .labelColor
            override var isOpaque: Bool { false }

            override func draw(_ dirtyRect: NSRect) {
                _ = dirtyRect
                color.setFill()
                bounds.fill()
            }
        }

        /// Invisible native compose editor. This is shown only while editing input in-place.
        private var composeMaskView: ComposeMaskView?
        private var composeEditor: ComposeTextView?
        private var composeCaretView: ComposeCaretView?
        private var composeCaretBlinkTimer: Timer? = nil
        private var composeCaretBlinkVisible: Bool = true
        private var composeOriginalText: String? = nil
        private var composeEnding: Bool = false
        private var composeSyncedText: String = ""
        private var composeSyncedCursor: Int = 0
        private var composeSuppressSync: Bool = false
        private var composeSelectionAnchor: Int? = nil
        private var composeActivationContext: ComposeActivationContext? = nil
        private var composeTerminalText: String = ""
        private var composeTerminalCursor: Int = 0
        private var composeForegroundColor: NSColor = .labelColor
        private var composeBackgroundColor: NSColor = .black
        private var composeAutoActivateTimer: Timer? = nil
        private var composeAutoActivateAttempts: Int = 0
        private static let composeAutoActivateMaxAttempts: Int = 8
        private var composeTrackerTimer: Timer? = nil
        private var composeTrackerMisses: Int = 0
        private var composeTrackerLastFrame: NSRect = .null
        private var composeTrackerPausedUntilExplicitClick: Bool = false
        private var composeTerminalSelectionMode: Bool = false
        private static let composeTrackerInterval: TimeInterval = 1.0 / 30.0
        private static let composeTrackerMissTolerance: Int = 6
        private static let composeTrackerFrameDeltaEpsilon: CGFloat = 0.25
        private var composeResponderHandoff: Bool = false
        private var composeTerminalCursorHidden: Bool = false
        private var composeStabilizeUntil: TimeInterval = 0
        private static let composeLogPath = "/tmp/jterm-compose-events.log"
        private var composeInsertionTraceBudget: Int = 40
        private var composeCaretTraceBudget: Int = 40
        private var composeRowTraceBudget: Int = 60
        private var composeLocalDraftDirty: Bool = false
        private var composeVirtualTrailingGapPending: Bool = false
        private var composePendingKeydownAt: TimeInterval? = nil
        private var composeLatencySamplesMs: [Double] = []
        private var composeCommitPending: Bool = false
        private var composeClaudeStructuralNewlineCount: Int = 0
        private var composeLastResolvedClaudeSnapshot: PromptInputSnapshot? = nil

        private var surfaceContentHeight: CGFloat {
            max(1, contentSize.height)
        }

        private var surfaceContentWidth: CGFloat {
            max(1, contentSize.width)
        }

        private func composeTrace(_ message: String) {
            let tMs = Int64((ProcessInfo.processInfo.systemUptime * 1000.0).rounded())
            let line = "[compose][pid:\(ProcessInfo.processInfo.processIdentifier)][t_ms:\(tMs)] \(message)\n"
            guard let data = line.data(using: .utf8) else { return }
            FileHandle.standardError.write(data)

            let path = Self.composeLogPath
            if !FileManager.default.fileExists(atPath: path) {
                _ = FileManager.default.createFile(atPath: path, contents: nil)
            }
            guard let handle = FileHandle(forWritingAtPath: path) else { return }
            handle.seekToEndOfFile()
            handle.write(data)
            handle.closeFile()
        }

        private func composePercentile(_ p: Double, samples: [Double]) -> Double {
            guard !samples.isEmpty else { return 0 }
            let rank = Int(round((Double(samples.count - 1) * p)))
            let idx = min(max(0, rank), samples.count - 1)
            let sorted = samples.sorted()
            return sorted[idx]
        }

        private func maybeRecordComposeLatency() {
            guard let startedAt = composePendingKeydownAt else { return }
            composePendingKeydownAt = nil
            let now = ProcessInfo.processInfo.systemUptime
            let latencyMs = max(0, (now - startedAt) * 1000.0)
            composeLatencySamplesMs.append(latencyMs)
            if composeLatencySamplesMs.count > 512 {
                composeLatencySamplesMs.removeFirst(composeLatencySamplesMs.count - 512)
            }
            composeTrace(
                "latency sample_ms=\(String(format: "%.3f", latencyMs)) samples=\(composeLatencySamplesMs.count)"
            )
            if composeLatencySamplesMs.count % 25 == 0 {
                let p95 = composePercentile(0.95, samples: composeLatencySamplesMs)
                let p99 = composePercentile(0.99, samples: composeLatencySamplesMs)
                composeTrace(
                    "latency summary samples=\(composeLatencySamplesMs.count) p95_ms=\(String(format: "%.3f", p95)) p99_ms=\(String(format: "%.3f", p99))"
                )
            }
        }

        private func resetComposeState(reason: String) {
            composeTrace("reset state reason=\(reason)")
            composeOriginalText = nil
            composeEnding = false
            composeSyncedText = ""
            composeSyncedCursor = 0
            composeTerminalText = ""
            composeTerminalCursor = 0
            composeSelectionAnchor = nil
            composeActivationContext = nil
            composeSuppressSync = false
            composeTrackerMisses = 0
            composeTrackerLastFrame = .null
            composeTrackerPausedUntilExplicitClick = false
            composeTerminalSelectionMode = false
            composeLocalDraftDirty = false
            composeVirtualTrailingGapPending = false
            composePendingKeydownAt = nil
            composeLatencySamplesMs.removeAll(keepingCapacity: false)
            composeClaudeStructuralNewlineCount = 0
            composeLastResolvedClaudeSnapshot = nil
            pointerStyle = .horizontalText
            setTerminalCursorHidden(false)
            if let editor = composeEditor {
                editor.isHidden = true
            }
            if let mask = composeMaskView {
                mask.isHidden = true
            }
            stopComposeCaretBlink()
            composeCaretView?.isHidden = true
            if window?.firstResponder === composeEditor {
                _ = window?.makeFirstResponder(self)
            }
        }

        private func composeShouldLiveSync() -> Bool {
            if composeDebugMode == .appkitOnly {
                return false
            }
            switch composeActivationContext {
            case .shellPrompt:
                return true
            case .claudeTui:
                // Claude paints its own inverse-style cursor cell in the TUI.
                // Live-syncing every edit causes frequent re-renders and visual artifacts.
                // Keep editing fully native and sync only on commit/blur.
                return false
            case .none:
                return false
            }
        }

        private func shouldSyncClaudeMultilineDraft(_ draft: String) -> Bool {
            guard composeActivationContext == .claudeTui else { return false }
            guard let editor = composeEditor, !editor.isHidden else {
                return draft.contains("\n") || composeClaudeStructuralNewlineCount > 0
            }
            return composeDesiredClaudeStructuralNewlineCount(
                editor: editor,
                draft: draft
            ) > 0 || composeClaudeStructuralNewlineCount > 0
        }

        private func composeTrackerShouldIgnoreTerminalTextSnapshot() -> Bool {
            guard composeActivationContext == .claudeTui else { return false }
            if composeUsesLocalMultilineDraft() {
                return true
            }
            return composeTerminalText.contains("\n") || composeSyncedText.contains("\n")
        }

        private func composeShouldPersistAcrossBlur() -> Bool {
            switch composeActivationContext {
            case .claudeTui:
                return true
            case .shellPrompt, .none:
                return false
            }
        }

        private var composeDebugMode: ComposeDebugMode {
            ComposeDebugMode.current()
        }

        private var composeSyncToTerminalEnabled: Bool {
            composeDebugMode != .appkitOnly
        }

        private var composeOverlayTextEnabled: Bool {
            composeDebugMode != .terminalOnly
        }

        private var composeMaskEnabled: Bool {
            composeDebugMode != .terminalOnly
        }

        private var composeCaretEnabled: Bool {
            composeDebugMode != .terminalOnly
        }

        private func stopComposeAutoActivateTimer() {
            composeAutoActivateTimer?.invalidate()
            composeAutoActivateTimer = nil
        }

        private func startComposeAutoActivateTimer(reason: String) {
            _ = reason
            // Disabled for stability. Compose activates on explicit click.
        }

        private func stopComposeTrackerTimer() {
            composeTrackerTimer?.invalidate()
            composeTrackerTimer = nil
        }

        private func startComposeTrackerTimer(reason: String) {
            if composeTrackerTimer == nil {
                composeTrace("tracker start reason=\(reason)")
                let timer = Timer(timeInterval: Self.composeTrackerInterval, repeats: true) { [weak self] _ in
                    self?.tickComposeTracker(reason: "timer")
                }
                composeTrackerTimer = timer
                RunLoop.main.add(timer, forMode: .common)
            }
            tickComposeTracker(reason: "start-\(reason)")
        }

        private func trackerHasMeaningfulFrameChange(_ lhs: NSRect, _ rhs: NSRect) -> Bool {
            let lhsFinite = lhs.minX.isFinite && lhs.minY.isFinite && lhs.width.isFinite && lhs.height.isFinite
            let rhsFinite = rhs.minX.isFinite && rhs.minY.isFinite && rhs.width.isFinite && rhs.height.isFinite
            if !lhsFinite || !rhsFinite {
                return true
            }
            return abs(lhs.minX - rhs.minX) > Self.composeTrackerFrameDeltaEpsilon ||
                abs(lhs.minY - rhs.minY) > Self.composeTrackerFrameDeltaEpsilon ||
                abs(lhs.width - rhs.width) > Self.composeTrackerFrameDeltaEpsilon ||
                abs(lhs.height - rhs.height) > Self.composeTrackerFrameDeltaEpsilon
        }

        private func resolveClaudePromptSnapshot(source: String) -> PromptInputSnapshot? {
            guard let inputContext = readInputContext() else { return nil }
            guard !inputContext.cursor_at_prompt else { return nil }

            let primaryPoint = cursorClickPointInView()
            if let primaryPoint {
                let primary = fallbackPromptInputSnapshot(
                    clickPoint: primaryPoint,
                    markers: Self.composeClaudePromptMarkers,
                    requirePromptMarker: true
                )
                let expanded = expandClaudeSnapshotToCursorRows(primary)
                if let expanded {
                    cacheClaudeSnapshot(expanded, source: source)
                    return expanded
                }
            }

            guard let fallbackPoint = composeTrackerFallbackProbePointInView() else { return nil }
            if let primaryPoint {
                let dx = abs(primaryPoint.x - fallbackPoint.x)
                let dy = abs(primaryPoint.y - fallbackPoint.y)
                if dx < Self.composeTrackerFrameDeltaEpsilon &&
                    dy < Self.composeTrackerFrameDeltaEpsilon
                {
                    return nil
                }
                composeTrace(
                    "claude probe retry source=\(source) primary_x=\(primaryPoint.x) primary_y=\(primaryPoint.y) fallback_x=\(fallbackPoint.x) fallback_y=\(fallbackPoint.y)"
                )
            } else {
                composeTrace(
                    "claude probe retry source=\(source) primary=nil fallback_x=\(fallbackPoint.x) fallback_y=\(fallbackPoint.y)"
                )
            }

            let fallback = fallbackPromptInputSnapshot(
                clickPoint: fallbackPoint,
                markers: Self.composeClaudePromptMarkers,
                requirePromptMarker: true
            )
            let expanded = expandClaudeSnapshotToCursorRows(fallback)
            if let expanded {
                cacheClaudeSnapshot(expanded, source: "\(source)-fallback")
            }
            return expanded
        }

        private func trackerSnapshotForClaudeInput() -> PromptInputSnapshot? {
            resolveClaudePromptSnapshot(source: "trackerSnapshotForClaudeInput")
        }

        private func composeTrackerProbePointInView() -> NSPoint? {
            guard composeActivationContext == .claudeTui else { return nil }
            // Reacquire Claude compose from terminal state first. Using the
            // overlay's current frame as the primary probe point creates a
            // circular dependency during viewport scroll: the prompt moves, the
            // overlay stays stale, and the tracker keeps probing the stale
            // overlay location.
            if let cursorPoint = cursorClickPointInView() {
                return cursorPoint
            }
            return composeTrackerFallbackProbePointInView()
        }

        private func composeTrackerFallbackProbePointInView() -> NSPoint? {
            guard composeActivationContext == .claudeTui else { return nil }

            let cellW = max(1, cellSize.width)
            let cellH = max(1, cellSize.height)

            if let snapshot = composeLastResolvedClaudeSnapshot {
                let frame = promptInputFrame(snapshot)
                return NSPoint(
                    x: min(surfaceContentWidth - 1, frame.minX + (cellW * 0.5)),
                    y: min(surfaceContentHeight - 1, frame.midY)
                )
            }

            guard composeUsesLocalMultilineDraft() ||
                composeTerminalText.contains("\n") ||
                composeSyncedText.contains("\n")
            else { return nil }
            guard let editor = composeEditor, !editor.isHidden else { return nil }
            return NSPoint(
                x: min(surfaceContentWidth - 1, editor.frame.minX + (cellW * 0.5)),
                y: min(surfaceContentHeight - 1, editor.frame.midY)
            )
        }

        private func composeTrackerClickPoint(for snapshot: PromptInputSnapshot) -> NSPoint {
            let frame = promptInputFrame(snapshot)
            let idx = composeCursorIndexFromTerminal(snapshot: snapshot)
            let cellW = max(1, cellSize.width)
            return NSPoint(
                x: frame.minX + (CGFloat(idx) * cellW) + (cellW * 0.5),
                y: frame.midY
            )
        }

        private func applyTrackerFrame(_ snapshot: PromptInputSnapshot, reason: String) {
            guard let editor = composeEditor, !editor.isHidden else { return }
            guard composeActivationContext == .claudeTui else { return }

            let frame = composeEditorFrame(for: snapshot, context: .claudeTui)
            let overlayBefore = editor.frame
            let shouldUpdate = trackerHasMeaningfulFrameChange(frame, editor.frame) ||
                trackerHasMeaningfulFrameChange(frame, composeTrackerLastFrame)
            if shouldUpdate {
                applyComposeEditorLayout(
                    editor: editor,
                    snapshot: snapshot,
                    resetCaret: false
                )
            }
            refreshComposeCaret(resetBlink: false)
            composeTrackerLastFrame = frame

            let overlayAfter = editor.frame
            let driftX = overlayAfter.minX - frame.minX
            let driftY = overlayAfter.minY - frame.minY
            let cellW = max(1, cellSize.width)
            let cellH = max(1, cellSize.height)
            let targetCellX = snapshot.x / cellW
            let targetCellY = snapshot.yTop / cellH
            let targetCellW = snapshot.width / cellW
            let targetCellH = snapshot.height / cellH
            composeTrace(
                "tracker geom reason=\(reason) changed=\(shouldUpdate) target_cell_x=\(targetCellX) target_cell_y=\(targetCellY) target_cell_w=\(targetCellW) target_cell_h=\(targetCellH) target_px_x=\(frame.minX) target_px_y=\(frame.minY) target_px_w=\(frame.width) target_px_h=\(frame.height) overlay_before_x=\(overlayBefore.minX) overlay_before_y=\(overlayBefore.minY) overlay_before_w=\(overlayBefore.width) overlay_before_h=\(overlayBefore.height) overlay_x=\(overlayAfter.minX) overlay_y=\(overlayAfter.minY) overlay_w=\(overlayAfter.width) overlay_h=\(overlayAfter.height) drift_x=\(driftX) drift_y=\(driftY) text_len=\(snapshot.text.count)"
            )
        }

        private func syncComposeFromTrackerSnapshotIfNeeded(
            _ snapshot: PromptInputSnapshot,
            reason: String
        ) {
            guard let editor = composeEditor, !editor.isHidden else { return }
            guard composeActivationContext == .claudeTui else { return }
            guard !composeShouldLiveSync() else { return }
            if composeTrackerShouldIgnoreTerminalTextSnapshot() {
                composeTrace(
                    "tracker terminal-sync skipped reason=\(reason) multiline_snapshot_ignored=true term_len=\(snapshot.text.count)"
                )
                return
            }

            let terminalText = snapshot.text
            let terminalCursor = composeCursorIndexFromTerminal(snapshot: snapshot)
            let terminalChanged = terminalText != composeTerminalText ||
                terminalCursor != composeTerminalCursor
            guard terminalChanged else { return }

            let localDraft = editor.string
            let localCursor = min(max(0, editor.selectedRange().location), localDraft.utf16.count)
            let localDirty = composeLocalDraftDirty ||
                localDraft != composeSyncedText ||
                localCursor != composeSyncedCursor

            // If terminal state changed and local draft isn't dirty, adopt terminal
            // immediately. We also force-adopt when terminal row clears to prevent
            // stale drafts from leaking into the next Claude prompt.
            if localDirty && (!terminalText.isEmpty || composeUsesLocalMultilineDraft()) {
                composeTrace(
                    "tracker terminal-sync skipped reason=\(reason) local_dirty=true term_len=\(terminalText.count) local_len=\(localDraft.count) term_cursor=\(terminalCursor) local_cursor=\(localCursor)"
                )
                return
            }

            composeSuppressSync = true
            if editor.string != terminalText {
                editor.string = terminalText
                normalizeComposeEditorTextAttributes(editor)
            }
            editor.setSelectedRange(NSRange(location: terminalCursor, length: 0))
            composeSuppressSync = false
            composeSelectionAnchor = nil
            updateComposeSelectionAppearance(editor)
            editor.needsDisplay = true
            editor.displayIfNeeded()
            refreshComposeCaret(resetBlink: false)

            composeTerminalText = terminalText
            composeTerminalCursor = terminalCursor
            composeSyncedText = terminalText
            composeSyncedCursor = terminalCursor
            composeLocalDraftDirty = false
            composeVirtualTrailingGapPending = false
            composeTrace(
                "tracker terminal-sync reason=\(reason) adopted=true term_len=\(terminalText.count) cursor=\(terminalCursor)"
            )
        }

        private func tickComposeTracker(reason: String) {
            guard focused else { return }
            guard window?.isKeyWindow ?? false else { return }
            guard !composeEnding else { return }
            guard !composeCommitPending else { return }
            guard Date.timeIntervalSinceReferenceDate >= composeStabilizeUntil else { return }

            // Cursor visibility can be reset by terminal state changes; keep it
            // force-hidden while native compose is active.
            if composeOriginalText != nil {
                setTerminalCursorHidden(true, force: true)
            }

            if searchState != nil {
                if composeOriginalText != nil {
                    composeTrace("tracker finish reason=search-active")
                    finishCompose(.blur)
                }
                return
            }

            let claudeSnapshot = trackerSnapshotForClaudeInput()
            if composeOriginalText == nil {
                guard !composeTrackerPausedUntilExplicitClick else { return }
                guard let snapshot = claudeSnapshot else { return }
                composeActivationContext = .claudeTui
                let clickPoint = composeTrackerClickPoint(for: snapshot)
                composeTrace(
                    "tracker activate reason=\(reason) click_x=\(clickPoint.x) click_y=\(clickPoint.y) text_len=\(snapshot.text.count)"
                )
                activateComposeMode(with: snapshot, clickPoint: clickPoint)
                composeTrackerMisses = 0
                composeTrackerLastFrame = composeEditorFrame(for: snapshot, context: .claudeTui)
                return
            }

            guard composeActivationContext == .claudeTui else { return }
            guard let snapshot = claudeSnapshot else {
                if composeUsesLocalMultilineDraft() ||
                    composeTerminalText.contains("\n") ||
                    composeSyncedText.contains("\n")
                {
                    composeTrackerMisses = 0
                    composeTrace("tracker miss ignored reason=\(reason) multiline=true")
                    return
                }
                composeTrackerMisses += 1
                if composeTrackerMisses >= Self.composeTrackerMissTolerance {
                    composeTrace("tracker finish reason=miss-threshold misses=\(composeTrackerMisses)")
                    finishCompose(.blur)
                    composeTrackerMisses = 0
                    composeTrackerLastFrame = .null
                }
                return
            }

            composeTrackerMisses = 0
            applyTrackerFrame(snapshot, reason: reason)
            syncComposeFromTrackerSnapshotIfNeeded(snapshot, reason: reason)
        }

        private func attemptComposeAutoActivate(reason: String) {
            guard focused else {
                stopComposeAutoActivateTimer()
                return
            }
            guard composeOriginalText == nil else {
                stopComposeAutoActivateTimer()
                return
            }
            guard searchState == nil else { return }
            composeAutoActivateAttempts += 1
            let snapshot: PromptInputSnapshot?
            if let cursorPoint = cursorClickPointInView() {
                snapshot = resolveShellPromptSnapshot(
                    clickPoint: cursorPoint,
                    source: "auto-activate"
                )
            } else {
                snapshot = nil
            }
            guard let snapshot else {
                if composeAutoActivateAttempts < Self.composeAutoActivateMaxAttempts {
                    startComposeAutoActivateTimer(reason: "retry-\(reason)")
                }
                return
            }

            let frame = promptInputFrame(snapshot)
            let clickPoint = NSPoint(
                x: frame.maxX + max(1, cellSize.width),
                y: frame.midY
            )
            composeTrace(
                "auto activate reason=\(reason) frame_x=\(frame.minX) frame_y=\(frame.minY) frame_w=\(frame.width) frame_h=\(frame.height) text_len=\(snapshot.text.count)"
            )
            composeStabilizeUntil = Date.timeIntervalSinceReferenceDate + 0.45
            activateComposeMode(with: snapshot, clickPoint: clickPoint)
            stopComposeAutoActivateTimer()
        }

        private func setTerminalCursorHidden(_ hidden: Bool, force: Bool = false) {
            guard force || composeTerminalCursorHidden != hidden else { return }
            composeTerminalCursorHidden = hidden
            guard composeSyncToTerminalEnabled else {
                composeTrace("terminal cursor hidden skipped mode=\(composeDebugMode.rawValue) hidden=\(hidden)")
                return
            }
            guard let surfaceModel else { return }
            if hidden {
                surfaceModel.setCursorHiddenOverride(true)
            } else {
                surfaceModel.setCursorHiddenOverride(false)
            }
            if force {
                composeTrace("terminal cursor hidden=\(hidden) force=true")
            } else {
                composeTrace("terminal cursor hidden=\(hidden)")
            }
        }

        private func clearTerminalPreedit() {
            guard composeSyncToTerminalEnabled else {
                composeTrace("terminal preedit clear skipped mode=\(composeDebugMode.rawValue)")
                return
            }
            guard let surface else { return }
            if markedText.length > 0 {
                markedText.mutableString.setString("")
            }
            ghostty_surface_preedit(surface, nil, 0)
            composeTrace("terminal preedit cleared")
        }

        private func stopComposeCaretBlink() {
            composeCaretBlinkTimer?.invalidate()
            composeCaretBlinkTimer = nil
        }

        private func ensureComposeCaretView() -> ComposeCaretView {
            if let composeCaretView {
                return composeCaretView
            }

            let caret = ComposeCaretView(frame: .zero)
            caret.wantsLayer = true
            caret.layer?.zPosition = 10_001
            caret.isHidden = true
            addSubview(caret)
            composeCaretView = caret
            return caret
        }

        private func startComposeCaretBlink() {
            stopComposeCaretBlink()
            composeCaretBlinkTimer = Timer.scheduledTimer(
                withTimeInterval: 0.53,
                repeats: true
            ) { [weak self] _ in
                guard let self else { return }
                guard let editor = self.composeEditor,
                      let caret = self.composeCaretView,
                      self.composeOriginalText != nil,
                      !editor.isHidden,
                      self.window?.firstResponder === editor
                else {
                    self.composeCaretView?.isHidden = true
                    return
                }

                self.composeCaretBlinkVisible.toggle()
                caret.isHidden = !self.composeCaretBlinkVisible
            }
        }

        private func refreshComposeCaret(resetBlink: Bool) {
            guard composeOriginalText != nil,
                  let editor = composeEditor,
                  !editor.isHidden,
                  window?.firstResponder === editor
            else {
                composeCaretView?.isHidden = true
                stopComposeCaretBlink()
                return
            }

            guard composeCaretEnabled else {
                composeCaretView?.isHidden = true
                stopComposeCaretBlink()
                return
            }

            let selection = editor.selectedRange()
            guard selection.length == 0 else {
                composeCaretView?.isHidden = true
                return
            }

            let idx = min(max(0, selection.location), editor.string.utf16.count)
            var actual = NSRange(location: 0, length: 0)
            let screenRect = editor.firstRect(
                forCharacterRange: NSRange(location: idx, length: 0),
                actualRange: &actual
            )
            guard let window else { return }
            let winRect = window.convertFromScreen(screenRect)
            let viewRect = convert(winRect, from: nil)

            let fallbackLineHeight = max(1, cellSize.height)
            let lineHeight = editor.font.map {
                editor.layoutManager?.defaultLineHeight(for: $0) ?? fallbackLineHeight
            } ?? fallbackLineHeight
            let caretHeight = min(max(1, floor(lineHeight)), max(1, floor(editor.frame.height)))
            let caretWidth = max(1, min(2, Int(floor(cellSize.width * 0.2))))
            var caretX = viewRect.minX
            if composeVirtualTrailingGapPending,
               idx == editor.string.utf16.count
            {
                caretX += max(1, cellSize.width)
            }
            caretX = max(editor.frame.minX, min(editor.frame.maxX - CGFloat(caretWidth), caretX))
            let usesMultilineCaretAnchor = composeActivationContext == .claudeTui &&
                composeEditorUsesVisualMultiline(
                    editor: editor,
                    frameWidth: editor.frame.width,
                    context: composeActivationContext
                )
            let caretY: CGFloat
            if usesMultilineCaretAnchor,
               viewRect.minY.isFinite,
               viewRect.height.isFinite,
               viewRect.maxY >= editor.frame.minY - 2,
               viewRect.minY <= editor.frame.maxY + 2
            {
                let rectAnchoredY = floor(viewRect.minY)
                caretY = max(editor.frame.minY, min(editor.frame.maxY - caretHeight, rectAnchoredY))
            } else {
                // AppKit can report y=0 for empty insertion rects; anchor caret using
                // the same inset math as compose text so empty and non-empty rows align.
                let insetY = composeTextInsetY(
                    context: composeActivationContext,
                    frameHeight: editor.frame.height,
                    lineHeight: lineHeight
                )
                let insetAnchoredY = floor(editor.frame.minY + insetY)
                caretY = max(editor.frame.minY, min(editor.frame.maxY - caretHeight, insetAnchoredY))
            }

            let caret = ensureComposeCaretView()
            caret.color = composeForegroundColor
            caret.frame = NSRect(
                x: floor(caretX),
                y: floor(caretY),
                width: CGFloat(caretWidth),
                height: floor(caretHeight)
            )
            if composeCaretTraceBudget > 0 {
                composeCaretTraceBudget -= 1
                composeTrace(
                    "compose caret frame x=\(caret.frame.minX) y=\(caret.frame.minY) w=\(caret.frame.width) h=\(caret.frame.height) idx=\(idx)"
                )
            }
            addSubview(caret, positioned: .above, relativeTo: editor)

            if resetBlink {
                composeCaretBlinkVisible = true
                caret.isHidden = false
                startComposeCaretBlink()
            } else {
                caret.isHidden = !composeCaretBlinkVisible
            }
        }

        /// Event monitor (see individual events for why)
        private var eventMonitor: Any? = nil

        // During compose editing, keep first-responder ownership on the compose editor.
        // This prevents responder churn on click/drag interactions.
        override var acceptsFirstResponder: Bool { composeOriginalText == nil }
        override func acceptsFirstMouse(for event: NSEvent?) -> Bool { return true }

        init(_ app: ghostty_app_t, baseConfig: SurfaceConfiguration? = nil, uuid: UUID? = nil) {
            self.markedText = NSMutableAttributedString()
            self.id = uuid ?? .init()

            // Our initial config always is our application wide config.
            if let appDelegate = NSApplication.shared.delegate as? AppDelegate {
                self.derivedConfig = DerivedConfig(appDelegate.ghostty.config)
            } else {
                self.derivedConfig = DerivedConfig()
            }

            // We need to initialize this so it does something but we want to set
            // it back up later so we can reference `self`. This is a hack we should
            // fix at some point.
            self.cachedScreenContents = .init(duration: .milliseconds(500)) { "" }
            self.cachedVisibleContents = self.cachedScreenContents

            // Initialize with some default frame size. The important thing is that this
            // is non-zero so that our layer bounds are non-zero so that our renderer
            // can do SOMETHING.
            super.init(frame: NSMakeRect(0, 0, 800, 600))

            // Our cache of screen data
            cachedScreenContents = .init(duration: .milliseconds(500)) { [weak self] in
                guard let self else { return "" }
                guard let surface = self.surface else { return "" }
                var text = ghostty_text_s()
                let sel = ghostty_selection_s(
                    top_left: ghostty_point_s(
                        tag: GHOSTTY_POINT_SCREEN,
                        coord: GHOSTTY_POINT_COORD_TOP_LEFT,
                        x: 0,
                        y: 0),
                    bottom_right: ghostty_point_s(
                        tag: GHOSTTY_POINT_SCREEN,
                        coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT,
                        x: 0,
                        y: 0),
                    rectangle: false)
                guard ghostty_surface_read_text(surface, sel, &text) else { return "" }
                defer { ghostty_surface_free_text(surface, &text) }
                return String(cString: text.text)
            }
            cachedVisibleContents = .init(duration: .milliseconds(500)) { [weak self] in
                guard let self else { return "" }
                guard let surface = self.surface else { return "" }
                var text = ghostty_text_s()
                let sel = ghostty_selection_s(
                    top_left: ghostty_point_s(
                        tag: GHOSTTY_POINT_VIEWPORT,
                        coord: GHOSTTY_POINT_COORD_TOP_LEFT,
                        x: 0,
                        y: 0),
                    bottom_right: ghostty_point_s(
                        tag: GHOSTTY_POINT_VIEWPORT,
                        coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT,
                        x: 0,
                        y: 0),
                    rectangle: false)
                guard ghostty_surface_read_text(surface, sel, &text) else { return "" }
                defer { ghostty_surface_free_text(surface, &text) }
                return String(cString: text.text)
            }

            // Set a timer to show the ghost emoji after 500ms if no title is set
            titleFallbackTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
                if let self = self, self.title.isEmpty {
                    self.title = "👻"
                }
            }

            // Before we initialize the surface we want to register our notifications
            // so there is no window where we can't receive them.
            let center = NotificationCenter.default
            center.addObserver(
                self,
                selector: #selector(onUpdateRendererHealth),
                name: JTerm.Notification.didUpdateRendererHealth,
                object: self)
            center.addObserver(
                self,
                selector: #selector(ghosttyDidContinueKeySequence),
                name: JTerm.Notification.didContinueKeySequence,
                object: self)
            center.addObserver(
                self,
                selector: #selector(ghosttyDidEndKeySequence),
                name: JTerm.Notification.didEndKeySequence,
                object: self)
            center.addObserver(
                self,
                selector: #selector(ghosttyDidChangeKeyTable),
                name: JTerm.Notification.didChangeKeyTable,
                object: self)
            center.addObserver(
                self,
                selector: #selector(ghosttyConfigDidChange(_:)),
                name: .ghosttyConfigDidChange,
                object: self)
            center.addObserver(
                self,
                selector: #selector(ghosttyColorDidChange(_:)),
                name: .ghosttyColorDidChange,
                object: self)
            center.addObserver(
                self,
                selector: #selector(ghosttyBellDidRing(_:)),
                name: .ghosttyBellDidRing,
                object: self)
            center.addObserver(
                self,
                selector: #selector(ghosttyDidChangeReadonly(_:)),
                name: .ghosttyDidChangeReadonly,
                object: self)
            center.addObserver(
                self,
                selector: #selector(windowDidChangeScreen),
                name: NSWindow.didChangeScreenNotification,
                object: nil)
            center.addObserver(
                self,
                selector: #selector(windowDidResignKey),
                name: NSWindow.didResignKeyNotification,
                object: nil)
            center.addObserver(
                self,
                selector: #selector(appDidResignActive),
                name: NSApplication.didResignActiveNotification,
                object: nil)

            // Listen for local events that we need to know of outside of
            // single surface handlers.
            self.eventMonitor = NSEvent.addLocalMonitorForEvents(
                matching: [
                    .keyDown,
                    // We need keyUp because command+key events don't trigger keyUp.
                    .keyUp,
                    .leftMouseDown,
                    // Track compose drag selection even if AppKit routes mouse events
                    // through subviews/responder changes.
                    .leftMouseDragged,
                    .leftMouseUp,
                    .mouseMoved,
                ]
            ) { [weak self] event in self?.localEventHandler(event) }

            // Setup our surface. This will also initialize all the terminal IO.
            let surface_cfg = baseConfig ?? SurfaceConfiguration()
            let surface = surface_cfg.withCValue(view: self) { surface_cfg_c in
                ghostty_surface_new(app, &surface_cfg_c)
            }
            guard let surface = surface else {
                self.error = JTerm.Error.apiFailed
                return
            }
            self.surfaceModel = JTerm.Surface(cSurface: surface)

            // Setup our tracking area so we get mouse moved events
            updateTrackingAreas()

            // The UTTypes that can be dragged onto this view.
            registerForDraggedTypes(Array(Self.dropTypes))

            composeTrace("surface init id=\(id.uuidString)")
            DispatchQueue.main.async { [weak self] in
                self?.composeAutoActivateAttempts = 0
                self?.startComposeTrackerTimer(reason: "surface-init")
            }
        }

        required init?(coder: NSCoder) {
            fatalError("init(coder:) is not supported for this view")
        }

        deinit {
            // Remove all of our notificationcenter subscriptions
            let center = NotificationCenter.default
            center.removeObserver(self)

            // Remove our event monitor
            if let eventMonitor {
                NSEvent.removeMonitor(eventMonitor)
            }

            // Whenever the surface is removed, we need to note that our restorable
            // state is invalid to prevent the surface from being restored.
            invalidateRestorableState()

            trackingAreas.forEach { removeTrackingArea($0) }

            // Remove ourselves from secure input if we have to
            SecureInput.shared.removeScoped(ObjectIdentifier(self))

            // Remove any notifications associated with this surface
            let identifiers = Array(self.notificationIdentifiers)
            UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: identifiers)

            // Cancel progress report timer
            progressReportTimer?.invalidate()
            stopComposeAutoActivateTimer()
            stopComposeTrackerTimer()
            stopComposeCaretBlink()
            setTerminalCursorHidden(false)

            composeEditor?.removeFromSuperview()
            composeEditor = nil
            composeMaskView?.removeFromSuperview()
            composeMaskView = nil
            composeCaretView?.removeFromSuperview()
            composeCaretView = nil
        }

        func focusDidChange(_ focused: Bool) {
            guard let surface = self.surface else { return }
            guard self.focused != focused else { return }

            if !focused, composeOriginalText != nil {
                let windowIsKey = window?.isKeyWindow ?? false
                let appIsActive = NSApp.isActive
                composeTrace(
                    "focusDidChange false compose_active=true window_key=\(windowIsKey) app_active=\(appIsActive)"
                )
                if !windowIsKey || !appIsActive {
                    if composeShouldPersistAcrossBlur() {
                        composeTrace("focusDidChange preserve compose on blur")
                    } else {
                        composeTrace("finish trigger source=focusDidChange")
                        finishCompose(.blur)
                    }
                }
            }

            self.focused = focused
            ghostty_surface_set_focus(surface, focused)
            if !focused {
                stopComposeAutoActivateTimer()
                stopComposeTrackerTimer()
                if !(composeOriginalText != nil && composeShouldPersistAcrossBlur()) {
                    setTerminalCursorHidden(false)
                }
                composeCaretView?.isHidden = true
                stopComposeCaretBlink()
            }

            // Update our secure input state if we are a password input
            if (passwordInput) {
                SecureInput.shared.setScoped(ObjectIdentifier(self), focused: focused)
            }

            if (focused) {
                // On macOS 13+ we can store our continuous clock...
                focusInstant = ContinuousClock.now

                // We unset our bell state if we gained focus
                bell = false

                // Remove any notifications for this surface once we gain focus.
                if !notificationIdentifiers.isEmpty {
                    UNUserNotificationCenter.current()
                        .removeDeliveredNotifications(
                            withIdentifiers: Array(notificationIdentifiers))
                    self.notificationIdentifiers = []
                }
                if composeOriginalText != nil, composeShouldPersistAcrossBlur() {
                    setTerminalCursorHidden(true)
                    if !composeTerminalSelectionMode,
                       let editor = composeEditor, !editor.isHidden {
                        _ = window?.makeFirstResponder(editor)
                        refreshComposeCaret(resetBlink: true)
                    }
                }
                startComposeTrackerTimer(reason: "focus-gained")
            }
        }

        func sizeDidChange(_ size: CGSize) {
            if composeOriginalText != nil,
               !composeTerminalSelectionMode,
               let editor = composeEditor,
               !editor.isHidden
            {
                if let cursorPoint = cursorClickPointInView(),
                   let snapshot = resolveShellPromptSnapshot(
                    clickPoint: cursorPoint,
                    source: "sizeDidChange",
                    allowWhenCursorNotAtPrompt: true
                   )
                {
                    let frame = composeEditorFrame(
                        for: snapshot,
                        context: composeActivationContext
                    )
                    editor.frame = frame
                    composeMaskView?.frame = composeMaskFrame(
                        for: frame,
                        context: composeActivationContext
                    )
                } else if let cursorPoint = cursorClickPointInView(),
                          let snapshot = cursorOnlyPromptInputSnapshot(clickPoint: cursorPoint)
                {
                    let frame = composeEditorFrame(
                        for: snapshot,
                        context: composeActivationContext
                    )
                    editor.frame = frame
                    composeMaskView?.frame = composeMaskFrame(
                        for: frame,
                        context: composeActivationContext
                    )
                }
                refreshComposeCaret(resetBlink: false)
            }

            // JTerm wants to know the actual framebuffer size... It is very important
            // here that we use "size" and NOT the view frame. If we're in the middle of
            // an animation (i.e. a fullscreen animation), the frame will not yet be updated.
            // The size represents our final size we're going for.
            let scaledSize = self.convertToBacking(size)
            setSurfaceSize(width: UInt32(scaledSize.width), height: UInt32(scaledSize.height))
            // Store this size so we can reuse it when backing properties change
            contentSize = size
            tickComposeTracker(reason: "size-change")
        }

        private func setSurfaceSize(width: UInt32, height: UInt32) {
            guard let surface = self.surface else { return }

            // Update our core surface
            ghostty_surface_set_size(surface, width, height)

            // Update our cached size metrics
            let size = ghostty_surface_size(surface)
            DispatchQueue.main.async {
                // DispatchQueue required since this may be called by SwiftUI off
                // the main thread and Published changes need to be on the main
                // thread. This caused a crash on macOS <= 14.
                self.surfaceSize = size
            }
        }

        func setCursorShape(_ shape: ghostty_action_mouse_shape_e) {
            if composeOriginalText != nil {
                pointerStyle = .horizontalText
                NSCursor.iBeam.set()
                composeTrace("cursor shape override compose-active")
                return
            }

            switch (shape) {
            case GHOSTTY_MOUSE_SHAPE_DEFAULT:
                pointerStyle = .default

            case GHOSTTY_MOUSE_SHAPE_TEXT:
                pointerStyle = .horizontalText

            case GHOSTTY_MOUSE_SHAPE_GRAB:
                pointerStyle = .grabIdle

            case GHOSTTY_MOUSE_SHAPE_GRABBING:
                pointerStyle = .grabActive

            case GHOSTTY_MOUSE_SHAPE_POINTER:
                pointerStyle = .link

            case GHOSTTY_MOUSE_SHAPE_W_RESIZE:
                pointerStyle = .resizeLeft

            case GHOSTTY_MOUSE_SHAPE_E_RESIZE:
                pointerStyle = .resizeRight

            case GHOSTTY_MOUSE_SHAPE_N_RESIZE:
                pointerStyle = .resizeUp

            case GHOSTTY_MOUSE_SHAPE_S_RESIZE:
                pointerStyle = .resizeDown

            case GHOSTTY_MOUSE_SHAPE_NS_RESIZE:
                pointerStyle = .resizeUpDown

            case GHOSTTY_MOUSE_SHAPE_EW_RESIZE:
                pointerStyle = .resizeLeftRight

            case GHOSTTY_MOUSE_SHAPE_VERTICAL_TEXT:
                pointerStyle = .verticalText

            case GHOSTTY_MOUSE_SHAPE_CONTEXT_MENU:
                pointerStyle = .contextMenu

            case GHOSTTY_MOUSE_SHAPE_CROSSHAIR:
                pointerStyle = .crosshair

            case GHOSTTY_MOUSE_SHAPE_NOT_ALLOWED:
                pointerStyle = .operationNotAllowed

            default:
                // We ignore unknown shapes.
                return
            }
        }

        func setCursorVisibility(_ visible: Bool) {
            // Technically this action could be called anytime we want to
            // change the mouse visibility but at the time of writing this
            // mouse-hide-while-typing is the only use case so this is the
            // preferred method.
            NSCursor.setHiddenUntilMouseMoves(!visible)
        }

        /// Set the title by prompting the user.
        func promptTitle() {
            // Create an alert dialog
            let alert = NSAlert()
            alert.messageText = "Change Terminal Title"
            alert.informativeText = "Leave blank to restore the default."
            alert.alertStyle = .informational

            // Add a text field to the alert
            let textField = NSTextField(frame: NSRect(x: 0, y: 0, width: 250, height: 24))
            textField.stringValue = title
            alert.accessoryView = textField

            // Add buttons
            alert.addButton(withTitle: "OK")
            alert.addButton(withTitle: "Cancel")

            // Make the text field the first responder so it gets focus
            alert.window.initialFirstResponder = textField

            let completionHandler: (NSApplication.ModalResponse) -> Void = { [weak self] response in
                guard let self else { return }

                // Check if the user clicked "OK"
                guard response == .alertFirstButtonReturn  else { return }

                // Get the input text
                let newTitle = textField.stringValue
                if newTitle.isEmpty {
                    // Empty means that user wants the title to be set automatically
                    // We also need to reload the config for the "title" property to be
                    // used again by this tab.
                    let prevTitle = titleFromTerminal ?? "👻"
                    titleFromTerminal = nil
                    setTitle(prevTitle)
                } else {
                    // Set the title and prevent it from being changed automatically
                    titleFromTerminal = title
                    title = newTitle
                }
            }

            // We prefer to run our alert in a sheet modal if we have a window.
            if let window {
                alert.beginSheetModal(for: window, completionHandler: completionHandler)
            } else {
                // On macOS 26 RC, this codepath results in the "OK" button not being
                // visible. The above codepath should be taken most times but I'm just
                // noting this as something I noticed consistently.
                completionHandler(alert.runModal())
            }
        }

        func setTitle(_ title: String) {
            // This fixes an issue where very quick changes to the title could
            // cause an unpleasant flickering. We set a timer so that we can
            // coalesce rapid changes. The timer is short enough that it still
            // feels "instant".
            titleChangeTimer?.invalidate()
            titleChangeTimer = Timer.scheduledTimer(
                withTimeInterval: 0.075,
                repeats: false
            ) { [weak self] _ in
                // Set the title if it wasn't manually set.
                guard self?.titleFromTerminal == nil else {
                    self?.titleFromTerminal = title
                    return
                }
                self?.title = title
            }
        }

        // MARK: Local Events

        private func isFinitePoint(_ point: NSPoint) -> Bool {
            point.x.isFinite && point.y.isFinite
        }

        private func localEventHandler(_ event: NSEvent) -> NSEvent? {
            if event.type == .keyUp {
                composeTrace("local keyUp keyCode=\(event.keyCode) compose_active=\(composeOriginalText != nil)")
            }
            return switch event.type {
            case .keyDown:
                localEventKeyDown(event)
            case .keyUp:
                localEventKeyUp(event)
            case .leftMouseDown:
                localEventLeftMouseDown(event)
            case .leftMouseDragged:
                localEventLeftMouseDragged(event)
            case .leftMouseUp:
                localEventLeftMouseUp(event)
            case .mouseMoved:
                localEventMouseMoved(event)

            default:
                event
            }
        }

        private func localEventKeyDown(_ event: NSEvent) -> NSEvent? {
            guard composeOriginalText != nil else { return event }
            guard let window, event.windowNumber == window.windowNumber else { return event }
            let disallowed: NSEvent.ModifierFlags = [.command, .control, .function]
            if event.modifierFlags.intersection(disallowed).isEmpty {
                composePendingKeydownAt = ProcessInfo.processInfo.systemUptime
            }
            return event
        }

        private func localEventLeftMouseDown(_ event: NSEvent) -> NSEvent? {
            guard let window, event.windowNumber == window.windowNumber else { return event }
            let point = convert(event.locationInWindow, from: nil)
            guard isFinitePoint(point) else {
                composeTrace("local down ignored non-finite point clickCount=\(event.clickCount) compose_active=\(composeOriginalText != nil)")
                return event
            }
            if composeTerminalSelectionMode { return event }
            if composeOriginalText != nil,
               let editor = composeEditor,
               !editor.isHidden,
               editor.frame.contains(point)
            {
                composeSelectionAnchor = composeInsertionIndex(
                    for: editor,
                    clickPointInSurface: point
                )
            } else if composeOriginalText != nil {
                composeSelectionAnchor = nil
            }
            let anchor = composeSelectionAnchor.map(String.init) ?? "nil"
            composeTrace(
                "local down x=\(point.x) y=\(point.y) clickCount=\(event.clickCount) compose_active=\(composeOriginalText != nil) anchor=\(anchor)"
            )
            return event
        }

        private func localEventLeftMouseDragged(_ event: NSEvent) -> NSEvent? {
            guard composeOriginalText != nil else { return event }
            if composeTerminalSelectionMode { return event }
            guard let window, event.windowNumber == window.windowNumber else { return event }
            let point = convert(event.locationInWindow, from: nil)
            guard isFinitePoint(point) else { return event }
            guard let editor = composeEditor, !editor.isHidden else { return event }

            if composeSelectionAnchor == nil {
                composeSelectionAnchor = min(max(0, editor.selectedRange().location), editor.string.utf16.count)
            }
            let anchor = composeSelectionAnchor ?? 0
            let idx = updateComposeSelectionForDrag(
                editor: editor,
                anchor: anchor,
                pointInSurface: point
            )
            composeTrace("local drag x=\(point.x) y=\(point.y) anchor=\(anchor) idx=\(idx)")
            refreshComposeCaret(resetBlink: false)
            return event
        }

        private func localEventLeftMouseUp(_ event: NSEvent) -> NSEvent? {
            guard composeOriginalText != nil else { return event }
            if composeTerminalSelectionMode { return event }
            guard let window, event.windowNumber == window.windowNumber else { return event }
            let point = convert(event.locationInWindow, from: nil)
            let anchor = composeSelectionAnchor.map(String.init) ?? "nil"
            composeTrace("local up x=\(point.x) y=\(point.y) anchor=\(anchor)")
            composeSelectionAnchor = nil
            return event
        }

        private func localEventMouseMoved(_ event: NSEvent) -> NSEvent? {
            guard composeOriginalText != nil else { return event }
            if composeTerminalSelectionMode { return event }
            guard let window, event.windowNumber == window.windowNumber else { return event }
            let point = convert(event.locationInWindow, from: nil)
            let dragging = isLeftMouseButtonDown()
            let anchor = composeSelectionAnchor.map(String.init) ?? "nil"
            composeTrace("local moved x=\(point.x) y=\(point.y) dragging=\(dragging) anchor=\(anchor)")
            if dragging,
               let editor = composeEditor,
               !editor.isHidden,
               let anchorValue = composeSelectionAnchor,
               isFinitePoint(point)
            {
                _ = updateComposeSelectionForDrag(
                    editor: editor,
                    anchor: anchorValue,
                    pointInSurface: point
                )
                refreshComposeCaret(resetBlink: false)
            }
            return event
        }

        private func localEventKeyUp(_ event: NSEvent) -> NSEvent? {
            // While native compose editing is active, command key-up events should stay
            // in the AppKit text system and not be forwarded to the terminal.
            if composeOriginalText != nil {
                if let editor = composeEditor, !editor.isHidden {
                    composeTrace("keyup in compose keyCode=\(event.keyCode)")
                } else {
                    resetComposeState(reason: "keyup compose-without-editor")
                }
                composePendingKeydownAt = nil
                return event
            }

            // We only care about events with "command" because all others will
            // trigger the normal responder chain.
            if (!event.modifierFlags.contains(.command)) { return event }

            // Command keyUp events are never sent to the normal responder chain
            // so we send them here.
            guard focused else { return event }
            self.keyUp(with: event)
            return nil
        }

        private static let composeClaudePromptMarkers: [String] = [
            "❯ ",
            "❯\u{00A0}",
            "› ",
            "›\u{00A0}",
            "> ",
            ">\u{00A0}"
        ]
        private static let composeShellPromptMarkers: [String] = [
            "$ ",
            "% ",
            "# ",
            "λ ",
            "➜ ",
            "→ ",
        ]
        private static let composeRowMatchTolerance: Int = 0
        private static let composeMarkerSearchRadius: Int = 6
        private static let composeCursorMarkerTolerance: Int = 4

        private func composeSnapshotMatchesClickY(_ snapshot: PromptInputSnapshot, clickPoint: NSPoint) -> Bool {
            let frame = promptInputFrame(snapshot)
            let toleranceY = max(2, cellSize.height * 0.2)
            let yDistance = abs(clickPoint.y - frame.midY)
            return yDistance <= (frame.height * 0.5 + toleranceY)
        }

        private func readInputContext() -> ghostty_input_context_s? {
            guard let surface else { return nil }
            var context = ghostty_input_context_s(
                cursor_at_prompt: false,
                alternate_screen: false,
                mouse_reporting: false,
                cursor_row: 0,
                cursor_col: 0
            )
            guard ghostty_surface_read_input_context(surface, &context) else {
                return nil
            }
            return context
        }

        private func semanticPromptInputSnapshot() -> PromptInputSnapshot? {
            guard let surface else { return nil }

            var prompt = ghostty_prompt_input_s(
                x: 0,
                y: 0,
                width: 0,
                height: 0,
                text: nil,
                text_len: 0
            )
            guard ghostty_surface_read_prompt_input(surface, &prompt) else {
                return nil
            }
            defer { ghostty_surface_free_prompt_input(surface, &prompt) }

            let text: String
            if let ptr = prompt.text {
                let count = Int(prompt.text_len)
                let raw = UnsafeRawBufferPointer(start: ptr, count: count)
                text = String(decoding: raw, as: UTF8.self)
            } else {
                text = ""
            }

            return .init(
                x: CGFloat(prompt.x),
                yTop: CGFloat(prompt.y),
                width: CGFloat(prompt.width),
                height: CGFloat(prompt.height),
                text: text
            )
        }

        private func resolveShellPromptSnapshot(
            clickPoint: NSPoint,
            source: String,
            allowWhenCursorNotAtPrompt: Bool = false
        ) -> PromptInputSnapshot? {
            let semantic = semanticPromptInputSnapshot()
            let fallback = fallbackPromptInputSnapshot(
                clickPoint: clickPoint,
                markers: Self.composeShellPromptMarkers,
                requirePromptMarker: true
            )

            guard let semantic else {
                if let fallback {
                    composeTrace(
                        "shell snapshot source=\(source) mode=fallback-only len=\(fallback.text.count)"
                    )
                }
                return fallback
            }

            guard let fallback else {
                composeTrace(
                    "shell snapshot source=\(source) mode=semantic-only len=\(semantic.text.count)"
                )
                return semantic
            }

            let semanticMatchesClick = composeSnapshotMatchesClickY(semantic, clickPoint: clickPoint)
            let fallbackMatchesClick = composeSnapshotMatchesClickY(fallback, clickPoint: clickPoint)
            if !semanticMatchesClick, fallbackMatchesClick {
                composeTrace(
                    "shell snapshot source=\(source) mode=fallback-y-recovery semantic_len=\(semantic.text.count) fallback_len=\(fallback.text.count)"
                )
                return fallback
            }

            let semanticCursor = composeCursorIndexFromTerminal(snapshot: semantic)
            let fallbackCursor = composeCursorIndexFromTerminal(snapshot: fallback)
            let semanticPinnedToEnd = semanticCursor >= semantic.text.utf16.count
            let fallbackSignificantlyLonger = fallback.text.utf16.count >= semantic.text.utf16.count + 2
            if fallbackMatchesClick &&
                fallbackSignificantlyLonger &&
                (allowWhenCursorNotAtPrompt || semanticPinnedToEnd)
            {
                composeTrace(
                    "shell snapshot source=\(source) mode=fallback-truncation-recovery semantic_len=\(semantic.text.count) fallback_len=\(fallback.text.count) semantic_cursor=\(semanticCursor) fallback_cursor=\(fallbackCursor)"
                )
                return fallback
            }

            composeTrace(
                "shell snapshot source=\(source) mode=semantic-preferred semantic_len=\(semantic.text.count) fallback_len=\(fallback.text.count) semantic_cursor=\(semanticCursor) fallback_cursor=\(fallbackCursor)"
            )
            return semantic
        }

        private func visibleContentsSnapshot() -> String? {
            guard let surface else { return nil }

            var text = ghostty_text_s()
            let selection = ghostty_selection_s(
                top_left: ghostty_point_s(
                    tag: GHOSTTY_POINT_VIEWPORT,
                    coord: GHOSTTY_POINT_COORD_TOP_LEFT,
                    x: 0,
                    y: 0
                ),
                bottom_right: ghostty_point_s(
                    tag: GHOSTTY_POINT_VIEWPORT,
                    coord: GHOSTTY_POINT_COORD_BOTTOM_RIGHT,
                    x: 0,
                    y: 0
                ),
                rectangle: false
            )
            guard ghostty_surface_read_text(surface, selection, &text) else {
                return nil
            }
            defer { ghostty_surface_free_text(surface, &text) }

            return String(cString: text.text)
        }

        private func trimRightInlineWhitespace(_ value: String) -> String {
            guard !value.isEmpty else { return value }
            var end = value.endIndex
            while end > value.startIndex {
                let prev = value.index(before: end)
                let ch = value[prev]
                if ch == " " || ch == "\t" || ch == "\u{00A0}" {
                    end = prev
                } else {
                    break
                }
            }

            return String(value[..<end])
        }

        private struct PromptStartHeuristic {
            let charColumn: Int
            let displayColumn: Int
            let markerFound: Bool
        }

        // Minimal terminal-cell width estimator for prompt alignment.
        // We only need strong behavior for common prompt glyphs.
        private func terminalCellWidth(for scalar: Unicode.Scalar) -> Int {
            switch scalar.value {
            // Zero-width combining marks.
            case 0x0300...0x036F,
                0x1AB0...0x1AFF,
                0x1DC0...0x1DFF,
                0x20D0...0x20FF,
                0xFE20...0xFE2F:
                return 0

            // Common wide prompt glyphs seen in modern CLIs.
            case 0x276F, // ❯
                0x27A4, // ➤
                0x25B6, // ▶
                0x25B8: // ▸
                return 2

            default:
                return 1
            }
        }

        private func terminalDisplayColumns(_ text: Substring) -> Int {
            var total = 0
            for scalar in text.unicodeScalars {
                total += terminalCellWidth(for: scalar)
            }
            return total
        }

        private func terminalDisplayColumns(_ text: String) -> Int {
            terminalDisplayColumns(text[...])
        }

        private func heuristicInputStartColumn(
            line: String,
            cursorColumn: Int,
            markers: [String]
        ) -> PromptStartHeuristic {
            guard !line.isEmpty else {
                return .init(charColumn: 0, displayColumn: 0, markerFound: false)
            }
            let cursorBound = min(max(0, cursorColumn), line.count)
            let prefix = String(line.prefix(cursorBound))

            var bestChar = 0
            var bestDisplay = 0
            var found = false
            for marker in markers {
                guard let range = prefix.range(of: marker, options: .backwards) else {
                    continue
                }
                let idxChar = prefix.distance(from: prefix.startIndex, to: range.upperBound)
                let idxDisplay = terminalDisplayColumns(prefix[..<range.upperBound])
                if idxDisplay > bestDisplay {
                    bestDisplay = idxDisplay
                    bestChar = idxChar
                }
                found = true
            }

            return .init(charColumn: bestChar, displayColumn: bestDisplay, markerFound: found)
        }

        private func cursorClickPointInView() -> NSPoint? {
            guard let surface else { return nil }

            let cellW = max(1, cellSize.width)
            let cellH = max(1, cellSize.height)
            var cursorX: Double = 0
            var cursorY: Double = 0
            var cursorWidth: Double = cellW
            var cursorHeight: Double = cellH
            ghostty_surface_ime_point(
                surface,
                &cursorX,
                &cursorY,
                &cursorWidth,
                &cursorHeight
            )

            let cursorTop = max(0, CGFloat(cursorY - cursorHeight))
            let y = surfaceContentHeight - cursorTop - (cellH * 0.5)
            let x = max(0, CGFloat(cursorX))
            return NSPoint(x: x, y: y)
        }

        private func fallbackPromptInputSnapshot(
            clickPoint: NSPoint,
            markers: [String],
            requirePromptMarker: Bool = false
        ) -> PromptInputSnapshot? {
            guard let surface else { return nil }

            let cellW = max(1, cellSize.width)
            let cellH = max(1, cellSize.height)

            var cursorX: Double = 0
            var cursorY: Double = 0
            var cursorWidth: Double = cellW
            var cursorHeight: Double = cellH
            ghostty_surface_ime_point(
                surface,
                &cursorX,
                &cursorY,
                &cursorWidth,
                &cursorHeight
            )

            // IME Y is top-origin and points at the row bottom edge.
            let cursorTop = max(0, CGFloat(cursorY - cursorHeight))
            let cursorRow = Int(floor(cursorTop / cellH))
            let clickTop = max(0, surfaceContentHeight - clickPoint.y)
            let clickRow = Int(floor(clickTop / cellH))

            guard let visible = visibleContentsSnapshot() else {
                return nil
            }
            let rows = visible
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init)

            guard !rows.isEmpty else { return nil }
            let boundedClickRow = min(max(0, clickRow), rows.count - 1)
            let boundedCursorRow = min(max(0, cursorRow), rows.count - 1)

            var targetRow = boundedClickRow
            var markerFoundOnTarget = false
            var markerStartColumn = 0

            if requirePromptMarker {
                let start = max(0, boundedCursorRow - Self.composeMarkerSearchRadius)
                let end = min(rows.count - 1, boundedCursorRow + Self.composeMarkerSearchRadius)
                var bestRow: Int? = nil
                var bestCursorDistance = Int.max
                var bestClickDistance = Int.max
                var bestStartColumn = 0
                for rowIdx in start...end {
                    let rowText = rows[rowIdx]
                    let heuristic = heuristicInputStartColumn(
                        line: rowText,
                        cursorColumn: rowText.count,
                        markers: markers
                    )
                    guard heuristic.markerFound else { continue }
                    let cursorDistance = abs(rowIdx - boundedCursorRow)
                    let clickDistance = abs(rowIdx - boundedClickRow)
                    // Prefer the marker nearest the clicked row first, then nearest cursor row.
                    if clickDistance < bestClickDistance ||
                        (clickDistance == bestClickDistance && cursorDistance < bestCursorDistance)
                    {
                        bestCursorDistance = cursorDistance
                        bestClickDistance = clickDistance
                        bestRow = rowIdx
                        bestStartColumn = heuristic.charColumn
                    }
                }

                guard let bestRow else {
                    let clickPreview = rows[boundedClickRow].prefix(120)
                    let cursorPreview = rows[boundedCursorRow].prefix(120)
                    let markerSummary = markers.joined(separator: "|")
                    composeTrace(
                        "fallback marker miss click_row=\(boundedClickRow) cursor_row=\(boundedCursorRow) markers=\(markerSummary) click_preview=\(clickPreview) cursor_preview=\(cursorPreview)"
                    )
                    return nil
                }

                targetRow = bestRow
                markerFoundOnTarget = true
                markerStartColumn = bestStartColumn

                let cursorDistance = abs(targetRow - boundedCursorRow)
                let clickDistance = abs(targetRow - boundedClickRow)
                if cursorDistance > Self.composeCursorMarkerTolerance && clickDistance > 1 {
                    composeTrace(
                        "fallback marker row drift target_row=\(targetRow) cursor_row=\(boundedCursorRow) click_row=\(boundedClickRow) click_drift=\(clickDistance) drift=\(cursorDistance) tol=\(Self.composeCursorMarkerTolerance)"
                    )
                    return nil
                }
                if cursorDistance > Self.composeCursorMarkerTolerance {
                    composeTrace(
                        "fallback marker row drift accepted target_row=\(targetRow) cursor_row=\(boundedCursorRow) click_row=\(boundedClickRow) click_drift=\(clickDistance) drift=\(cursorDistance) tol=\(Self.composeCursorMarkerTolerance)"
                    )
                }
            }

            guard targetRow >= 0, targetRow < rows.count else {
                return nil
            }

            let row = rows[targetRow]
            let rawCursorColumn = max(0, Int(floor(CGFloat(cursorX) / cellW)))
            let cursorColumnForRow = targetRow == boundedCursorRow
                ? min(rawCursorColumn, row.count)
                : row.count
            let heuristic = markerFoundOnTarget
                ? PromptStartHeuristic(
                    charColumn: markerStartColumn,
                    displayColumn: terminalDisplayColumns(
                        row.prefix(markerStartColumn)
                    ),
                    markerFound: true
                )
                : heuristicInputStartColumn(
                    line: row,
                    cursorColumn: cursorColumnForRow,
                    markers: markers
                )
            let boundedStart = min(heuristic.charColumn, row.count)
            let startIndex = row.index(row.startIndex, offsetBy: boundedStart)
            let text = trimRightInlineWhitespace(String(row[startIndex...]))
            let textDisplayWidth = terminalDisplayColumns(text)
            let anchoredDisplayStart = max(
                heuristic.displayColumn,
                cursorColumnForRow - textDisplayWidth
            )
            let x = max(0, CGFloat(anchoredDisplayStart) * cellW)
            let targetTop = CGFloat(targetRow) * cellH
            let rowDistance = abs(boundedClickRow - boundedCursorRow)
            composeTrace(
                "fallback hit click_x=\(clickPoint.x) click_y=\(clickPoint.y) click_row=\(boundedClickRow) cursor_row=\(boundedCursorRow) row_dist=\(rowDistance) target_row=\(targetRow) start_col=\(boundedStart) effective_start=\(anchoredDisplayStart) cursor_col=\(cursorColumnForRow) text_len=\(text.count)"
            )

            return .init(
                x: x,
                yTop: targetTop,
                width: max(cellW, surfaceContentWidth - x),
                height: cellH,
                text: text
            )
        }

        private func cursorOnlyPromptInputSnapshot(clickPoint: NSPoint) -> PromptInputSnapshot? {
            guard let surface else { return nil }

            let cellW = max(1, cellSize.width)
            let cellH = max(1, cellSize.height)

            var cursorX: Double = 0
            var cursorY: Double = 0
            var cursorWidth: Double = cellW
            var cursorHeight: Double = cellH
            ghostty_surface_ime_point(
                surface,
                &cursorX,
                &cursorY,
                &cursorWidth,
                &cursorHeight
            )

            let cursorTop = max(0, CGFloat(cursorY - cursorHeight))
            let cursorRow = Int(floor(cursorTop / cellH))
            let clickTop = max(0, surfaceContentHeight - clickPoint.y)
            let clickRow = Int(floor(clickTop / cellH))
            let rowDistance = abs(clickRow - cursorRow)
            if rowDistance > Self.composeRowMatchTolerance {
                composeTrace(
                    "cursor-only row miss click_row=\(clickRow) cursor_row=\(cursorRow) dist=\(rowDistance) tol=\(Self.composeRowMatchTolerance)"
                )
                return nil
            }

            let x = max(0, CGFloat(cursorX) - (cellW * 0.5))
            composeTrace(
                "cursor-only hit click_x=\(clickPoint.x) click_y=\(clickPoint.y) click_row=\(clickRow) cursor_row=\(cursorRow) dist=\(rowDistance)"
            )
            return .init(
                x: x,
                yTop: cursorTop,
                width: max(cellW, surfaceContentWidth - x),
                height: cellH,
                text: ""
            )
        }

        private func promptInputSnapshot(
            clickPoint: NSPoint
        ) -> (context: ComposeActivationContext, snapshot: PromptInputSnapshot)? {
            guard let inputContext = readInputContext() else {
                composeTrace("snapshot gated reason=no-input-context")
                return nil
            }

            if inputContext.cursor_at_prompt {
                guard let snapshot = resolveShellPromptSnapshot(
                    clickPoint: clickPoint,
                    source: "promptInputSnapshot-shell"
                ) else {
                    composeTrace("snapshot gated reason=shell-no-semantic")
                    return nil
                }
                guard composeSnapshotMatchesClickY(snapshot, clickPoint: clickPoint) else {
                    let frame = promptInputFrame(snapshot)
                    composeTrace(
                        "shell semantic y miss click_x=\(clickPoint.x) click_y=\(clickPoint.y) frame_x=\(frame.minX) frame_y=\(frame.minY) frame_w=\(frame.width) frame_h=\(frame.height)"
                    )
                    return nil
                }
                AppDelegate.logger.debug(
                    "compose snapshot source=shell-semantic x=\(snapshot.x) y=\(snapshot.yTop) w=\(snapshot.width) h=\(snapshot.height) len=\(snapshot.text.count)"
                )
                return (.shellPrompt, snapshot)
            }

            if !inputContext.alternate_screen,
               !inputContext.mouse_reporting,
               let snapshot = resolveShellPromptSnapshot(
                clickPoint: clickPoint,
                source: "promptInputSnapshot-shell-recovery",
                allowWhenCursorNotAtPrompt: true
               ),
               composeSnapshotMatchesClickY(snapshot, clickPoint: clickPoint)
            {
                AppDelegate.logger.debug(
                    "compose snapshot source=shell-recovery x=\(snapshot.x) y=\(snapshot.yTop) w=\(snapshot.width) h=\(snapshot.height) len=\(snapshot.text.count)"
                )
                return (.shellPrompt, snapshot)
            }

            if !inputContext.cursor_at_prompt {
                guard let snapshot = fallbackPromptInputSnapshot(
                    clickPoint: clickPoint,
                    markers: Self.composeClaudePromptMarkers,
                    requirePromptMarker: true
                ) else {
                    composeTrace(
                        "snapshot gated reason=prompt-no-marker alt=\(inputContext.alternate_screen) mouse=\(inputContext.mouse_reporting) row=\(inputContext.cursor_row) col=\(inputContext.cursor_col)"
                    )
                    return nil
                }

                guard composeSnapshotMatchesClickY(snapshot, clickPoint: clickPoint) else {
                    let frame = promptInputFrame(snapshot)
                    composeTrace(
                        "claude fallback y miss click_x=\(clickPoint.x) click_y=\(clickPoint.y) frame_x=\(frame.minX) frame_y=\(frame.minY) frame_w=\(frame.width) frame_h=\(frame.height)"
                    )
                    return nil
                }
                AppDelegate.logger.debug(
                    "compose snapshot source=claude-fallback x=\(snapshot.x) y=\(snapshot.yTop) w=\(snapshot.width) h=\(snapshot.height) len=\(snapshot.text.count)"
                )
                return (.claudeTui, snapshot)
            }

            composeTrace(
                "snapshot gated reason=context cursor_at_prompt=\(inputContext.cursor_at_prompt) alt=\(inputContext.alternate_screen) mouse=\(inputContext.mouse_reporting) row=\(inputContext.cursor_row) col=\(inputContext.cursor_col) title=\(title)"
            )
            return nil
        }

        private func promptInputFrame(_ snapshot: PromptInputSnapshot) -> NSRect {
            let width = max(snapshot.width, max(1, cellSize.width))
            let height = max(snapshot.height, max(1, cellSize.height))
            let y = surfaceContentHeight - snapshot.yTop - height
            return NSRect(x: snapshot.x, y: y, width: width, height: height)
        }

        private func composeEditorFrame(
            for snapshot: PromptInputSnapshot,
            context: ComposeActivationContext?
        ) -> NSRect {
            let base = promptInputFrame(snapshot)
            guard context == .claudeTui else { return base }

            // Bias Claude compose row downward so text/caret are visually centered
            // in the bordered input box while preserving room for descenders.
            let downShift = max(3, floor(cellSize.height * 0.18))
            let minY = max(0, base.minY - downShift)
            let maxY = min(surfaceContentHeight, base.maxY)
            return NSRect(
                x: base.minX,
                y: minY,
                width: base.width,
                height: max(1, maxY - minY)
            )
        }

        private func composeMaskFrame(
            for editorFrame: NSRect,
            context: ComposeActivationContext?
        ) -> NSRect {
            guard context == .claudeTui else { return editorFrame }

            let bleedX = max(1, floor(cellSize.width * 0.15))
            let bleedDown = max(2, floor(cellSize.height * 0.1))
            // Preserve the prompt marker by avoiding leftward mask bleed in Claude mode.
            let minX = max(0, editorFrame.minX)
            // Extend only downward to suppress any terminal cursor remnants that sit
            // below Claude's baseline while keeping the top divider untouched.
            let minY = max(0, editorFrame.minY - bleedDown)
            let maxX = min(surfaceContentWidth, editorFrame.maxX + bleedX)
            let maxY = min(surfaceContentHeight, editorFrame.maxY)
            return NSRect(
                x: minX,
                y: minY,
                width: max(1, maxX - minX),
                height: max(1, maxY - minY)
            )
        }

        private func composeTextInsetX(context: ComposeActivationContext?) -> CGFloat {
            switch context {
            case .claudeTui:
                // Keep a native-looking gap between Claude's prompt marker (❯)
                // and the editable insertion point.
                return max(1, cellSize.width)
            case .shellPrompt, .none:
                return 0
            }
        }

        private func composeEditorLineMetrics(
            editor: NSTextView,
            frameWidth: CGFloat,
            context: ComposeActivationContext?
        ) -> (lineHeight: CGFloat, usedHeight: CGFloat, visualLineCount: Int) {
            let fallbackLineHeight = max(1, cellSize.height)
            let lineHeight = editor.font.map {
                editor.layoutManager?.defaultLineHeight(for: $0) ?? fallbackLineHeight
            } ?? fallbackLineHeight

            guard let layout = editor.layoutManager,
                  let container = editor.textContainer
            else {
                return (lineHeight, lineHeight, 1)
            }

            container.lineBreakMode = .byCharWrapping
            container.maximumNumberOfLines = 0
            container.containerSize = NSSize(
                width: max(1, frameWidth - composeTextInsetX(context: context)),
                height: .greatestFiniteMagnitude
            )
            layout.ensureLayout(for: container)

            let usedHeight = ceil(layout.usedRect(for: container).height)
            let normalizedHeight = max(lineHeight, usedHeight)
            let visualLineCount = max(
                1,
                Int(ceil((normalizedHeight - 0.5) / max(1, lineHeight)))
            )
            return (lineHeight, normalizedHeight, visualLineCount)
        }

        private func composeEditorUsesVisualMultiline(
            editor: NSTextView,
            frameWidth: CGFloat,
            context: ComposeActivationContext?
        ) -> Bool {
            if editor.string.contains("\n") {
                return true
            }
            guard context == .claudeTui else { return false }
            return composeEditorLineMetrics(
                editor: editor,
                frameWidth: frameWidth,
                context: context
            ).visualLineCount > 1
        }

        private func composeUsesLocalMultilineDraft() -> Bool {
            guard composeActivationContext == .claudeTui else { return false }
            guard let editor = composeEditor, !editor.isHidden else { return false }
            return composeEditorUsesVisualMultiline(
                editor: editor,
                frameWidth: max(1, editor.frame.width),
                context: composeActivationContext
            )
        }

        private func composeMultilineTopInset(context: ComposeActivationContext?) -> CGFloat {
            switch context {
            case .claudeTui:
                // Claude multiline drafts should stay visually anchored to the
                // top content row instead of being re-centered within the
                // expanded overlay.
                return max(2, floor(cellSize.height * 0.12))
            case .shellPrompt, .none:
                return 0
            }
        }

        private func composeMultilineBottomPadding(context: ComposeActivationContext?) -> CGFloat {
            switch context {
            case .claudeTui:
                // Keep a little extra room for descenders/caret without pushing
                // the first line downward.
                return max(4, floor(cellSize.height * 0.22))
            case .shellPrompt, .none:
                return 0
            }
        }

        private func composeExpandedFrame(
            baseFrame: NSRect,
            editor: NSTextView,
            context: ComposeActivationContext?
        ) -> NSRect {
            guard context == .claudeTui else { return baseFrame }

            let metrics = composeEditorLineMetrics(
                editor: editor,
                frameWidth: baseFrame.width,
                context: context
            )
            let lineHeight = metrics.lineHeight
            let usedHeight = metrics.usedHeight
            let isMultiline = composeEditorUsesVisualMultiline(
                editor: editor,
                frameWidth: baseFrame.width,
                context: context
            )
            let desiredHeight: CGFloat
            if isMultiline {
                let topInset = composeMultilineTopInset(context: context)
                let bottomPadding = composeMultilineBottomPadding(context: context)
                desiredHeight = max(baseFrame.height, ceil(usedHeight + topInset + bottomPadding))
            } else {
                let insetY = composeTextInsetY(
                    context: context,
                    frameHeight: baseFrame.height,
                    lineHeight: lineHeight
                )
                desiredHeight = max(baseFrame.height, ceil(usedHeight + insetY * 2))
            }
            let extraHeight = max(0, desiredHeight - baseFrame.height)
            guard extraHeight > 0 else { return baseFrame }

            return NSRect(
                x: baseFrame.minX,
                y: max(0, baseFrame.minY - extraHeight),
                width: baseFrame.width,
                height: baseFrame.height + extraHeight
            )
        }

        private func composeShouldRevealUnderlyingPrompt(editor: NSTextView) -> Bool {
            composeActivationContext == .shellPrompt && editor.string.isEmpty
        }

        private func updateComposeBackgroundVisibility(_ editor: NSTextView) {
            let revealPrompt = composeShouldRevealUnderlyingPrompt(editor: editor)
            let showsBackground = composeMaskEnabled && !revealPrompt
            editor.drawsBackground = showsBackground
            editor.backgroundColor = showsBackground ? composeBackgroundColor : .clear
            editor.layer?.backgroundColor = showsBackground
                ? composeBackgroundColor.cgColor
                : NSColor.clear.cgColor

            if let mask = composeMaskView {
                mask.isHidden = !composeMaskEnabled || revealPrompt
                mask.fillColor = showsBackground
                    ? composeBackgroundColor.cgColor
                    : NSColor.clear.cgColor
            }
        }

        private func applyComposeEditorLayout(
            editor: NSTextView,
            snapshot: PromptInputSnapshot?,
            resetCaret: Bool
        ) {
            let context = composeActivationContext
            let baseFrame: NSRect
            if let snapshot {
                baseFrame = composeEditorFrame(for: snapshot, context: context)
            } else {
                baseFrame = editor.frame
            }

            let frame = composeExpandedFrame(
                baseFrame: baseFrame,
                editor: editor,
                context: context
            )
            let usesVisualMultiline = composeEditorUsesVisualMultiline(
                editor: editor,
                frameWidth: frame.width,
                context: context
            )
            editor.frame = frame
            composeMaskView?.frame = composeMaskFrame(for: frame, context: context)
            composeMaskView?.showsBottomDivider = context == .claudeTui &&
                usesVisualMultiline
            composeMaskView?.needsLayout = true
            updateComposeBackgroundVisibility(editor)

            if let font = editor.font {
                let lineHeight = editor.layoutManager?.defaultLineHeight(for: font) ?? font.pointSize
                let insetY: CGFloat
                if context == .claudeTui, usesVisualMultiline {
                    insetY = composeMultilineTopInset(context: context)
                } else {
                    insetY = composeTextInsetY(
                        context: context,
                        frameHeight: frame.height,
                        lineHeight: lineHeight
                    )
                }
                editor.textContainerInset = NSSize(
                    width: composeTextInsetX(context: context),
                    height: insetY
                )
            }

            editor.needsDisplay = true
            editor.displayIfNeeded()
            refreshComposeCaret(resetBlink: resetCaret)
        }

        private func composeTextInsetY(
            context: ComposeActivationContext?,
            frameHeight: CGFloat,
            lineHeight: CGFloat
        ) -> CGFloat {
            let maxInset = max(0, floor(frameHeight - lineHeight))
            let centered = max(0, floor((frameHeight - lineHeight) * 0.5))
            switch context {
            case .claudeTui:
                // Slight downward bias matches Claude's visual baseline better.
                let nudged = centered + 3
                // Keep at least 1 px of room to avoid descender clipping.
                let safeMaxInset = max(0, maxInset - 1)
                return min(safeMaxInset, nudged)
            case .shellPrompt, .none:
                return centered
            }
        }

        private func composeAdjustedFont(_ font: NSFont, context: ComposeActivationContext?) -> NSFont {
            guard context == .claudeTui else { return font }
            // Claude overlay text can read a touch heavier than the underlying
            // TUI rasterization. Trim size aggressively to match perceived weight.
            return font.withSize(max(1, font.pointSize - 0.7))
        }

        private func composeLetterSpacing(context: ComposeActivationContext?) -> CGFloat {
            switch context {
            case .claudeTui:
                // Slightly loosen tracking to match Claude's terminal glyph spacing.
                return 0.2
            case .shellPrompt, .none:
                return 0
            }
        }

        private func composeHitFrame(for editor: NSTextView) -> NSRect {
            let base = editor.frame
            let slopX = max(cellSize.width * 1.5, 12)
            let slopY = max(cellSize.height * 0.6, 12)
            return base.insetBy(dx: -slopX, dy: -slopY)
        }

        private func ensureComposeEditor() -> ComposeTextView {
            _ = ensureComposeMaskView()
            _ = ensureComposeCaretView()
            if let composeEditor {
                return composeEditor
            }

            let editor = ComposeTextView(frame: .zero)
            editor.delegate = self
            editor.isEditable = true
            editor.isSelectable = true
            editor.onCommit = { [weak self] in
                self?.finishCompose(.commit)
            }
            editor.onCancel = { [weak self] in
                self?.finishCompose(.cancel)
            }
            editor.onTab = { [weak self] in
                self?.handleComposeTab()
            }
            editor.onKeyDownOverride = { [weak self] event in
                self?.handleComposeEditorKeyDown(event) ?? false
            }
            editor.onInsertionPointDraw = { [weak self] rect, turnedOn in
                guard let self else { return }
                guard self.composeInsertionTraceBudget > 0 else { return }
                self.composeInsertionTraceBudget -= 1
                self.composeTrace(
                    "compose insertion-point draw x=\(rect.minX) y=\(rect.minY) w=\(rect.width) h=\(rect.height) on=\(turnedOn)"
                )
            }
            editor.onMouseDownOverride = { [weak self] event in
                self?.handleComposeEditorMouseDown(event) ?? false
            }
            editor.onMouseDraggedOverride = { [weak self] event in
                self?.handleComposeEditorMouseDragged(event) ?? false
            }
            editor.onMouseUpOverride = { [weak self] event in
                self?.handleComposeEditorMouseUp(event) ?? false
            }
            editor.wantsLayer = true
            editor.layer?.zPosition = 10_000
            editor.layer?.backgroundColor = composeBackgroundColor.cgColor
            editor.drawsBackground = true
            editor.backgroundColor = composeBackgroundColor
            editor.isRichText = false
            editor.importsGraphics = false
            editor.isHorizontallyResizable = false
            editor.isVerticallyResizable = false
            editor.usesFindBar = false
            editor.isContinuousSpellCheckingEnabled = false
            editor.isGrammarCheckingEnabled = false
            editor.isAutomaticTextCompletionEnabled = false
            editor.isAutomaticQuoteSubstitutionEnabled = false
            editor.isAutomaticDashSubstitutionEnabled = false
            editor.isAutomaticDataDetectionEnabled = false
            editor.isAutomaticLinkDetectionEnabled = false
            editor.isAutomaticTextReplacementEnabled = false
            editor.textColor = .labelColor
            editor.insertionPointColor = .clear
            updateComposeSelectionAppearance(editor)
            editor.markedTextAttributes = [
                .foregroundColor: NSColor.labelColor,
                .backgroundColor: NSColor.clear,
                .underlineStyle: 0,
            ]
            editor.textContainerInset = .zero
            editor.textContainer?.lineFragmentPadding = 0
            editor.textContainer?.lineBreakMode = .byCharWrapping
            editor.textContainer?.maximumNumberOfLines = 0
            editor.textContainer?.widthTracksTextView = true
            editor.textContainer?.heightTracksTextView = true
            editor.isHidden = true

            addSubview(editor)
            composeEditor = editor
            return editor
        }

        private func ensureComposeMaskView() -> ComposeMaskView {
            if let composeMaskView {
                return composeMaskView
            }

            let mask = ComposeMaskView(frame: .zero)
            mask.wantsLayer = true
            mask.layer?.zPosition = 9_999
            mask.isHidden = true
            addSubview(mask)
            composeMaskView = mask
            return mask
        }

        private func configureComposeEditorAppearance(_ editor: ComposeTextView) {
            if let surface, let fontRaw = ghostty_surface_quicklook_font(surface) {
                let font = Unmanaged<CTFont>.fromOpaque(fontRaw)
                editor.font = font.takeUnretainedValue()
                font.release()
            } else if cellSize.height > 0 {
                editor.font = .monospacedSystemFont(ofSize: max(12, cellSize.height * 0.8), weight: .regular)
            }
            if let font = editor.font {
                editor.font = composeAdjustedFont(font, context: composeActivationContext)
            }

            let bg: NSColor = {
                if let dynamic = backgroundColor {
                    return NSColor(dynamic).usingColorSpace(.sRGB) ??
                        NSColor(derivedConfig.backgroundColor).usingColorSpace(.sRGB) ??
                        .black
                }
                return NSColor(derivedConfig.backgroundColor).usingColorSpace(.sRGB) ?? .black
            }()
            let lum = 0.2126 * bg.redComponent + 0.7152 * bg.greenComponent + 0.0722 * bg.blueComponent
            let fg: NSColor = lum < 0.5 ? .white : .black
            composeBackgroundColor = bg
            composeForegroundColor = fg
            editor.textColor = composeOverlayTextEnabled ? composeForegroundColor : .clear
            editor.insertionPointColor = .clear
            editor.drawsBackground = composeMaskEnabled
            editor.backgroundColor = composeMaskEnabled ? composeBackgroundColor : .clear
            if let layer = editor.layer {
                layer.zPosition = 10_000
                layer.backgroundColor = composeMaskEnabled
                    ? composeBackgroundColor.cgColor
                    : NSColor.clear.cgColor
            }
            let mask = ensureComposeMaskView()
            mask.fillColor = composeMaskEnabled
                ? composeBackgroundColor.cgColor
                : NSColor.clear.cgColor
            mask.dividerColor = composeForegroundColor
                .withAlphaComponent(0.35)
                .cgColor
            mask.showsBottomDivider = composeActivationContext == .claudeTui &&
                composeEditorUsesVisualMultiline(
                    editor: editor,
                    frameWidth: max(1, editor.frame.width),
                    context: composeActivationContext
                )
            let caret = ensureComposeCaretView()
            caret.color = composeForegroundColor
            updateComposeBackgroundVisibility(editor)

            var typing: [NSAttributedString.Key: Any] = [
                .foregroundColor: composeOverlayTextEnabled ? composeForegroundColor : NSColor.clear,
                .backgroundColor: NSColor.clear,
                .underlineStyle: 0,
                .kern: composeLetterSpacing(context: composeActivationContext),
            ]
            if let font = editor.font {
                typing[.font] = font
            }
            editor.typingAttributes = typing
            updateComposeSelectionAppearance(editor)
            editor.markedTextAttributes = [
                .foregroundColor: composeOverlayTextEnabled ? composeForegroundColor : NSColor.clear,
                .backgroundColor: NSColor.clear,
                .underlineStyle: 0,
                .kern: composeLetterSpacing(context: composeActivationContext),
            ]
            editor.alphaValue = composeOverlayTextEnabled ? 1.0 : 0.01
        }

        private func composeSelectionBackgroundColor() -> NSColor {
            // Match iTerm's light selection blue more closely than AppKit's default.
            NSColor(
                calibratedRed: 0.78,
                green: 0.87,
                blue: 0.98,
                alpha: 1.0
            )
        }

        private func updateComposeSelectionAppearance(_ editor: NSTextView) {
            let hasSelection = editor.selectedRange().length > 0
            let selectionBlue = composeSelectionBackgroundColor()
            editor.selectedTextAttributes = [
                .foregroundColor: hasSelection ? NSColor.black : composeForegroundColor,
                .backgroundColor: hasSelection ? selectionBlue : NSColor.clear,
            ]
        }

        private func normalizeComposeEditorTextAttributes(_ editor: NSTextView) {
            var attrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: composeForegroundColor,
                .backgroundColor: NSColor.clear,
                .underlineStyle: 0,
                .kern: composeLetterSpacing(context: composeActivationContext),
            ]
            if let font = editor.font {
                attrs[.font] = font
            }

            if let storage = editor.textStorage {
                storage.setAttributes(attrs, range: NSRange(location: 0, length: storage.length))
            }

            editor.typingAttributes = attrs
            updateComposeSelectionAppearance(editor)
        }

        private func traceComposeEditorUnderlineState(_ editor: NSTextView, source: String) {
            guard let storage = editor.textStorage else { return }
            let fullRange = NSRange(location: 0, length: storage.length)
            var underlined: [String] = []
            storage.enumerateAttribute(.underlineStyle, in: fullRange, options: []) { value, range, _ in
                guard let raw = value as? NSNumber else { return }
                guard raw.intValue != 0 else { return }
                underlined.append("\(range.location):\(range.length)=\(raw.intValue)")
            }

            let marked = editor.markedRange()
            let selection = editor.selectedRange()
            let summary = underlined.isEmpty ? "none" : underlined.joined(separator: ",")
            composeTrace(
                "compose attrs source=\(source) marked_loc=\(marked.location) marked_len=\(marked.length) sel_loc=\(selection.location) sel_len=\(selection.length) underlines=\(summary)"
            )

            traceComposeEditorTemporaryAttributes(editor, source: source)
            traceComposeTerminalRow(source: source)
        }

        private func traceComposeEditorTemporaryAttributes(_ editor: NSTextView, source: String) {
            guard let layout = editor.layoutManager else { return }
            guard let container = editor.textContainer else { return }
            let glyphRange = layout.glyphRange(for: container)
            guard glyphRange.length > 0 else { return }

            var tmpUnderlined: [String] = []
            var index = glyphRange.location
            let limit = glyphRange.location + glyphRange.length
            while index < limit {
                var effective = NSRange(location: index, length: 0)
                let value = layout.temporaryAttribute(
                    .underlineStyle,
                    atCharacterIndex: index,
                    effectiveRange: &effective
                )
                if let raw = value as? NSNumber, raw.intValue != 0 {
                    tmpUnderlined.append("\(effective.location):\(effective.length)=\(raw.intValue)")
                }
                let next = effective.location + effective.length
                index = max(index + 1, next)
            }

            if !tmpUnderlined.isEmpty {
                composeTrace(
                    "compose temp attrs source=\(source) temp_underlines=\(tmpUnderlined.joined(separator: ","))"
                )
            }
        }

        private func traceComposeTerminalRow(source: String) {
            guard composeRowTraceBudget > 0 else { return }
            composeRowTraceBudget -= 1
            guard let snapshot = composeSnapshotForCursorRow() else {
                composeTrace("compose terminal row source=\(source) snapshot=nil")
                return
            }

            let cursor = composeCursorIndexFromTerminal(snapshot: snapshot)
            let utf16Len = snapshot.text.utf16.count
            let escaped = snapshot.text
                .replacingOccurrences(of: "\n", with: "\\n")
                .replacingOccurrences(of: "\r", with: "\\r")
                .replacingOccurrences(of: "\t", with: "\\t")
            let scalarHex = snapshot.text.unicodeScalars
                .prefix(32)
                .map { String(format: "%04X", $0.value) }
                .joined(separator: ",")
            composeTrace(
                "compose terminal row source=\(source) len=\(snapshot.text.count) utf16=\(utf16Len) cursor=\(cursor) text=\"\(escaped)\" scalars=\(scalarHex)"
            )
            traceComposeScreenRegion(source: source, snapshot: snapshot)
        }

        private func composeRowRange(
            for frame: NSRect,
            totalRows: Int
        ) -> ClosedRange<Int>? {
            guard totalRows > 0 else { return nil }
            let cellH = max(1, cellSize.height)
            let top = max(0, surfaceContentHeight - frame.maxY)
            let bottom = max(0, surfaceContentHeight - frame.minY)
            let start = min(max(0, Int(floor(top / cellH))), totalRows - 1)
            let end = min(max(0, Int(floor(max(0, bottom - 1) / cellH))), totalRows - 1)
            guard start <= end else { return nil }
            return start...end
        }

        private func composeScreenRowFlags(
            row: Int,
            promptRow: Int,
            cursorRow: Int?,
            editorRows: ClosedRange<Int>?,
            maskRows: ClosedRange<Int>?
        ) -> String {
            var flags: [String] = []
            if row == promptRow { flags.append("P") }
            if let cursorRow, row == cursorRow { flags.append("C") }
            if let editorRows, editorRows.contains(row) { flags.append("E") }
            if let maskRows, maskRows.contains(row) { flags.append("M") }
            return flags.isEmpty ? "-" : flags.joined()
        }

        private func traceComposeScreenRegion(
            source: String,
            snapshot: PromptInputSnapshot
        ) {
            guard let visible = visibleContentsSnapshot() else {
                composeTrace("compose screen source=\(source) visible=nil")
                return
            }

            let rows = visible
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init)
            guard !rows.isEmpty else {
                composeTrace("compose screen source=\(source) visible_rows=0")
                return
            }

            let promptRow = min(
                max(0, Int(floor(snapshot.yTop / max(1, cellSize.height)))),
                rows.count - 1
            )
            let cursorRow = readInputContext().map { min(max(0, Int($0.cursor_row)), rows.count - 1) }
            let editorRows: ClosedRange<Int>? = {
                guard let editor = composeEditor, !editor.isHidden else { return nil }
                return composeRowRange(for: editor.frame, totalRows: rows.count)
            }()
            let maskRows: ClosedRange<Int>? = {
                guard let mask = composeMaskView, !mask.isHidden else { return nil }
                return composeRowRange(for: mask.frame, totalRows: rows.count)
            }()

            var minRow = promptRow
            var maxRow = promptRow
            if let cursorRow {
                minRow = min(minRow, cursorRow)
                maxRow = max(maxRow, cursorRow)
            }
            if let editorRows {
                minRow = min(minRow, editorRows.lowerBound)
                maxRow = max(maxRow, editorRows.upperBound)
            }
            if let maskRows {
                minRow = min(minRow, maskRows.lowerBound)
                maxRow = max(maxRow, maskRows.upperBound)
            }
            minRow = max(0, minRow - 2)
            maxRow = min(rows.count - 1, maxRow + 3)

            let editorFrame: NSRect? = {
                guard let editor = composeEditor, !editor.isHidden else { return nil }
                return editor.frame
            }()
            let maskFrame: NSRect? = {
                guard let mask = composeMaskView, !mask.isHidden else { return nil }
                return mask.frame
            }()
            let editorString = composeEditor?.isHidden == false ? composeEditor?.string ?? "" : ""
            let editorSelection = composeEditor?.selectedRange()
            let editorSelectionLoc = editorSelection?.location ?? NSNotFound
            let editorSelectionLen = editorSelection?.length ?? 0
            composeTrace(
                "compose screen source=\(source) rows=\(rows.count) prompt_row=\(promptRow) cursor_row=\(cursorRow.map { String($0) } ?? "nil") editor_rows=\(editorRows.map { "\($0.lowerBound)...\($0.upperBound)" } ?? "nil") mask_rows=\(maskRows.map { "\($0.lowerBound)...\($0.upperBound)" } ?? "nil") editor_frame=\(editorFrame.map { "x=\($0.minX),y=\($0.minY),w=\($0.width),h=\($0.height)" } ?? "nil") mask_frame=\(maskFrame.map { "x=\($0.minX),y=\($0.minY),w=\($0.width),h=\($0.height)" } ?? "nil") draft_len=\(editorString.count) synced_len=\(composeSyncedText.count) term_len=\(composeTerminalText.count) structural_newlines=\(composeClaudeStructuralNewlineCount) local_dirty=\(composeLocalDraftDirty) pending_commit=\(composeCommitPending) selection_loc=\(editorSelectionLoc) selection_len=\(editorSelectionLen)"
            )

            for row in minRow...maxRow {
                let escaped = rows[row]
                    .replacingOccurrences(of: "\n", with: "\\n")
                    .replacingOccurrences(of: "\r", with: "\\r")
                    .replacingOccurrences(of: "\t", with: "\\t")
                let flags = composeScreenRowFlags(
                    row: row,
                    promptRow: promptRow,
                    cursorRow: cursorRow,
                    editorRows: editorRows,
                    maskRows: maskRows
                )
                composeTrace("compose screen row source=\(source) row=\(row) flags=\(flags) text=\"\(escaped)\"")
            }
        }

        private func composePromptRow(for snapshot: PromptInputSnapshot) -> Int {
            Int(floor(snapshot.yTop / max(1, cellSize.height)))
        }

        private func cacheClaudeSnapshot(_ snapshot: PromptInputSnapshot, source: String) {
            guard composeActivationContext == .claudeTui else { return }
            composeLastResolvedClaudeSnapshot = snapshot
            let promptRow = composePromptRow(for: snapshot)
            let cursorRow = readInputContext().map { Int($0.cursor_row) }
            composeTrace(
                "compose snapshot cached source=\(source) prompt_row=\(promptRow) cursor_row=\(cursorRow.map(String.init) ?? "nil") height=\(snapshot.height) width=\(snapshot.width) text_len=\(snapshot.text.count)"
            )
        }

        private func isLeftMouseButtonDown() -> Bool {
            (NSEvent.pressedMouseButtons & 1) != 0
        }

        private func composeInsertionIndex(
            for editor: NSTextView,
            clickPointInSurface point: NSPoint
        ) -> Int {
            let local = editor.convert(point, from: self)
            let maxIndex = editor.string.utf16.count

            guard let layout = editor.layoutManager,
                  let container = editor.textContainer
            else {
                let approx = Int(floor(max(0, local.x) / max(1, cellSize.width)))
                return min(max(0, approx), maxIndex)
            }

            layout.ensureLayout(for: container)
            let origin = editor.textContainerOrigin
            let pointInContainer = NSPoint(
                x: max(0, local.x - origin.x),
                y: max(0, local.y - origin.y)
            )
            let clampedY = min(max(0, pointInContainer.y), max(0, container.size.height - 1))
            var fraction: CGFloat = 0
            var index = layout.characterIndex(
                for: NSPoint(x: pointInContainer.x, y: clampedY),
                in: container,
                fractionOfDistanceBetweenInsertionPoints: &fraction
            )
            if fraction > 0.5 {
                index += 1
            }
            return min(max(0, index), maxIndex)
        }

        private func updateComposeSelectionForDrag(
            editor: NSTextView,
            anchor: Int,
            pointInSurface point: NSPoint
        ) -> Int {
            let idx = composeInsertionIndex(for: editor, clickPointInSurface: point)
            let lower = min(anchor, idx)
            let upper = max(anchor, idx)
            composeSuppressSync = true
            editor.setSelectedRange(NSRange(location: lower, length: upper - lower))
            composeSuppressSync = false
            updateComposeSelectionAppearance(editor)
            editor.needsDisplay = true
            editor.displayIfNeeded()
            return idx
        }

        private func handleComposeEditorMouseDown(_ event: NSEvent) -> Bool {
            guard composeOriginalText != nil else { return false }
            guard let editor = composeEditor, !editor.isHidden else { return false }
            let point = convert(event.locationInWindow, from: nil)
            guard isFinitePoint(point) else { return true }

            if composeTerminalSelectionMode {
                resumeSuspendedCompose(resetBlink: true)
            }

            if window?.firstResponder !== editor {
                _ = window?.makeFirstResponder(editor)
            }

            if event.clickCount == 1 {
                _ = applyComposeSingleClickInsertion(
                    editor: editor,
                    clickPointInSurface: point,
                    strictHit: true,
                    traceSource: "composeEditor mouseDown manual"
                )
                return true
            }

            composeTrace("composeEditor mouseDown passthrough clickCount=\(event.clickCount)")
            return false
        }

        private func handleComposeEditorMouseDragged(_ event: NSEvent) -> Bool {
            guard composeOriginalText != nil else { return false }
            guard let editor = composeEditor, !editor.isHidden else { return false }
            guard !composeTerminalSelectionMode else { return false }
            let point = convert(event.locationInWindow, from: nil)
            guard isFinitePoint(point) else { return true }

            if composeSelectionAnchor == nil {
                let current = min(max(0, editor.selectedRange().location), editor.string.utf16.count)
                composeSelectionAnchor = current
            }

            if let anchor = composeSelectionAnchor {
                let idx = updateComposeSelectionForDrag(
                    editor: editor,
                    anchor: anchor,
                    pointInSurface: point
                )
                composeTrace("composeEditor mouseDragged anchor=\(anchor) idx=\(idx)")
                refreshComposeCaret(resetBlink: false)
            }
            return true
        }

        private func handleComposeEditorMouseUp(_ event: NSEvent) -> Bool {
            guard composeOriginalText != nil else { return false }
            guard !composeTerminalSelectionMode else { return false }
            let point = convert(event.locationInWindow, from: nil)
            if isFinitePoint(point) {
                composeTrace("composeEditor mouseUp x=\(point.x) y=\(point.y)")
            } else {
                composeTrace("composeEditor mouseUp non-finite")
            }
            composeSelectionAnchor = nil
            return true
        }

        private func shouldInsertComposeTrailingSpace(
            editor: NSTextView,
            clickPointInSurface point: NSPoint,
            insertionIndex: Int,
            strictHit: Bool
        ) -> Bool {
            guard strictHit else { return false }
            let maxIndex = editor.string.utf16.count
            guard insertionIndex >= maxIndex else { return false }
            guard !editor.string.isEmpty else { return false }
            guard !editor.string.hasSuffix(" ") else { return false }

            let local = editor.convert(point, from: self)
            let origin = editor.textContainerOrigin
            let localX = max(0, local.x - origin.x)
            let cellW = max(1, cellSize.width)
            let clickedColumn = Int(floor(localX / cellW))

            // "Click + paste" behavior: only add a trailing space when the click is
            // at least one full cell beyond the current end of text.
            return clickedColumn > maxIndex
        }

        private func materializeComposeVirtualTrailingGapIfNeeded(
            editor: NSTextView,
            draft: String,
            cursor: Int
        ) -> (draft: String, cursor: Int) {
            guard composeVirtualTrailingGapPending else { return (draft, cursor) }

            let previous = composeSyncedText
            guard draft != previous else { return (draft, cursor) }

            defer {
                composeVirtualTrailingGapPending = false
            }

            guard draft.hasPrefix(previous) else {
                composeTrace(
                    "compose trailing gap skipped prefix_mismatch prev_len=\(previous.count) draft_len=\(draft.count)"
                )
                return (draft, cursor)
            }

            let suffix = String(draft.dropFirst(previous.count))
            guard !suffix.isEmpty else { return (draft, cursor) }
            guard !suffix.hasPrefix(" ") else {
                composeTrace(
                    "compose trailing gap materialized existing_space suffix_len=\(suffix.count)"
                )
                return (draft, cursor)
            }

            let newDraft = previous + " " + suffix
            let newCursor = min(max(0, cursor + 1), newDraft.utf16.count)

            composeSuppressSync = true
            editor.string = newDraft
            normalizeComposeEditorTextAttributes(editor)
            editor.setSelectedRange(NSRange(location: newCursor, length: 0))
            composeSuppressSync = false
            updateComposeSelectionAppearance(editor)
            editor.needsDisplay = true
            editor.displayIfNeeded()

            composeTrace(
                "compose trailing gap materialized prev_len=\(previous.count) suffix_len=\(suffix.count) new_len=\(newDraft.count) cursor=\(newCursor)"
            )
            return (newDraft, newCursor)
        }

        @discardableResult
        private func applyComposeSingleClickInsertion(
            editor: NSTextView,
            clickPointInSurface point: NSPoint,
            strictHit: Bool,
            traceSource: String
        ) -> Int {
            var insertion = composeInsertionIndex(
                for: editor,
                clickPointInSurface: point
            )

            if shouldInsertComposeTrailingSpace(
                editor: editor,
                clickPointInSurface: point,
                insertionIndex: insertion,
                strictHit: strictHit
            ) {
                composeVirtualTrailingGapPending = true
                composeTrace("compose trailing gap armed insertion=\(insertion)")
                composeSuppressSync = true
                editor.setSelectedRange(NSRange(location: insertion, length: 0))
                composeSuppressSync = false
                insertion = editor.string.utf16.count
            } else {
                composeVirtualTrailingGapPending = false
                composeSuppressSync = true
                editor.setSelectedRange(NSRange(location: insertion, length: 0))
                composeSuppressSync = false
            }

            composeSelectionAnchor = insertion
            updateComposeSelectionAppearance(editor)
            editor.needsDisplay = true
            editor.displayIfNeeded()
            composeTrace("\(traceSource) insertion=\(insertion)")
            refreshComposeCaret(resetBlink: true)
            return insertion
        }

        private func isComposeWordCodeUnit(_ unit: UInt16) -> Bool {
            guard let scalar = UnicodeScalar(unit) else { return false }
            return CharacterSet.alphanumerics.contains(scalar) || scalar == "_"
        }

        private func composeWordSelectionRange(text: String, around index: Int) -> NSRange {
            let units = Array(text.utf16)
            guard !units.isEmpty else { return NSRange(location: 0, length: 0) }

            var idx = min(max(0, index), units.count - 1)
            if !isComposeWordCodeUnit(units[idx]) {
                if idx > 0 && isComposeWordCodeUnit(units[idx - 1]) {
                    idx -= 1
                } else {
                    return NSRange(location: min(max(0, index), units.count), length: 0)
                }
            }

            var start = idx
            while start > 0 && isComposeWordCodeUnit(units[start - 1]) {
                start -= 1
            }

            var end = idx + 1
            while end < units.count && isComposeWordCodeUnit(units[end]) {
                end += 1
            }

            return NSRange(location: start, length: end - start)
        }

        private func syncTerminalCursor(from oldCursor: Int, to newCursor: Int) {
            guard composeSyncToTerminalEnabled else { return }
            let delta = newCursor - oldCursor
            if delta == 0 { return }
            if delta > 0 {
                for _ in 0..<delta {
                    surfaceModel?.sendKeyEvent(.init(key: .arrowRight))
                }
            } else {
                for _ in 0..<(-delta) {
                    surfaceModel?.sendKeyEvent(.init(key: .arrowLeft))
                }
            }
        }

        private func syncTerminalLine(
            from oldText: String,
            cursor oldCursor: Int,
            to newText: String,
            cursor newCursor: Int
        ) {
            guard composeSyncToTerminalEnabled else { return }
            let oldLen = oldText.utf16.count
            let newLen = newText.utf16.count
            let clampedOldCursor = min(max(0, oldCursor), oldLen)
            let clampedNewCursor = min(max(0, newCursor), newLen)

            // Move to end of old content first.
            if clampedOldCursor < oldLen {
                for _ in 0..<(oldLen - clampedOldCursor) {
                    surfaceModel?.sendKeyEvent(.init(key: .arrowRight))
                }
            } else if clampedOldCursor > oldLen {
                for _ in 0..<(clampedOldCursor - oldLen) {
                    surfaceModel?.sendKeyEvent(.init(key: .arrowLeft))
                }
            }

            // Clear previous editable content and write the new content.
            for _ in 0..<oldLen {
                surfaceModel?.sendKeyEvent(.init(key: .backspace))
            }
            if !newText.isEmpty {
                surfaceModel?.sendRawInput(newText)
            }

            // Reposition cursor within new content.
            if clampedNewCursor < newLen {
                for _ in 0..<(newLen - clampedNewCursor) {
                    surfaceModel?.sendKeyEvent(.init(key: .arrowLeft))
                }
            }
        }

        private func sendShiftEnterToTerminal() {
            surfaceModel?.sendKeyEvent(.init(key: .enter, action: .press, mods: .init(nsFlags: [.shift])))
            surfaceModel?.sendKeyEvent(.init(key: .enter, action: .release, mods: .init(nsFlags: [.shift])))
        }

        private func stringFromUTF16Slice(_ slice: ArraySlice<UInt16>) -> String {
            let units = Array(slice)
            if units.isEmpty { return "" }
            return units.withUnsafeBufferPointer { buffer in
                String(utf16CodeUnits: buffer.baseAddress!, count: buffer.count)
            }
        }

        private func sendClaudeMultilineInsertedText(_ text: String) {
            guard !text.isEmpty else { return }
            let parts = text.split(separator: "\n", omittingEmptySubsequences: false)
            for (idx, part) in parts.enumerated() {
                if !part.isEmpty {
                    surfaceModel?.sendText(String(part))
                }
                if idx < parts.count - 1 {
                    sendShiftEnterToTerminal()
                }
            }
        }

        private func composeNewlineCount(in text: String) -> Int {
            text.reduce(into: 0) { count, ch in
                if ch == "\n" {
                    count += 1
                }
            }
        }

        private func composeDesiredClaudeStructuralNewlineCount(
            editor: NSTextView,
            draft: String
        ) -> Int {
            let explicitNewlines = composeNewlineCount(in: draft)
            let visualLineCount = composeEditorLineMetrics(
                editor: editor,
                frameWidth: max(1, editor.frame.width),
                context: .claudeTui
            ).visualLineCount
            return max(explicitNewlines, max(0, visualLineCount - 1))
        }

        private func composeCommitTextForClaude(
            editor: NSTextView,
            draft: String
        ) -> String {
            let explicitNewlines = composeNewlineCount(in: draft)
            guard explicitNewlines == 0 else { return draft }

            let metrics = composeEditorLineMetrics(
                editor: editor,
                frameWidth: max(1, editor.frame.width),
                context: .claudeTui
            )
            guard metrics.visualLineCount > 1,
                  let layout = editor.layoutManager,
                  let container = editor.textContainer
            else { return draft }

            let text = draft as NSString
            let glyphRange = layout.glyphRange(for: container)
            guard glyphRange.length > 0 else { return draft }

            var fragments: [String] = []
            var glyphIndex = glyphRange.location
            let glyphLimit = glyphRange.location + glyphRange.length
            while glyphIndex < glyphLimit {
                var lineGlyphRange = NSRange(location: 0, length: 0)
                _ = layout.lineFragmentRect(
                    forGlyphAt: glyphIndex,
                    effectiveRange: &lineGlyphRange,
                    withoutAdditionalLayout: true
                )
                guard lineGlyphRange.length > 0 else { break }
                let charRange = layout.characterRange(forGlyphRange: lineGlyphRange, actualGlyphRange: nil)
                let fragment = text.substring(with: charRange)
                    .trimmingCharacters(in: CharacterSet.newlines)
                fragments.append(fragment)
                glyphIndex = lineGlyphRange.location + lineGlyphRange.length
            }

            guard fragments.count > 1 else { return draft }
            let commitText = fragments.joined(separator: "\n")
            composeTrace(
                "compose visual-wrap commit lines=\(fragments.count) draft_len=\(draft.count) commit_len=\(commitText.count)"
            )
            return commitText
        }

        private func syncClaudeStructuralNewlines(to desiredCount: Int) {
            guard composeActivationContext == .claudeTui else { return }
            guard composeSyncToTerminalEnabled else {
                composeClaudeStructuralNewlineCount = max(0, desiredCount)
                return
            }

            let clamped = max(0, desiredCount)
            let current = composeClaudeStructuralNewlineCount
            guard clamped != current else { return }

            if clamped > current {
                for _ in 0..<(clamped - current) {
                    sendShiftEnterToTerminal()
                }
            } else {
                for _ in 0..<(current - clamped) {
                    surfaceModel?.sendKeyEvent(.init(key: .backspace))
                }
            }
            composeClaudeStructuralNewlineCount = clamped
            composeTrace("compose structural-newlines synced current=\(current) desired=\(clamped)")
        }

        private func collapseClaudeMultilineScaffoldForCommit(
            targetLength: Int,
            completion: @escaping () -> Void
        ) {
            guard composeSyncToTerminalEnabled else {
                completion()
                return
            }

            let structuralCount = composeClaudeStructuralNewlineCount
            let cachedSnapshot = composeLastResolvedClaudeSnapshot
            let promptRow = cachedSnapshot.map(composePromptRow(for:))
            let liveContext = readInputContext()
            let liveCursorRow = liveContext.map { Int($0.cursor_row) }
            let liveCursorCol = liveContext.map { Int($0.cursor_col) }
            let bottomScaffoldRow = promptRow.map { $0 + structuralCount }
            let moveUpCount: Int = {
                guard structuralCount > 0 else { return 0 }
                if let bottomScaffoldRow, let liveCursorRow {
                    return max(0, liveCursorRow - bottomScaffoldRow)
                }
                return 0
            }()
            composeTrace(
                "compose multiline scaffold collapse target_len=\(targetLength) structural_newlines=\(structuralCount) prompt_row=\(promptRow.map(String.init) ?? "nil") bottom_row=\(bottomScaffoldRow.map(String.init) ?? "nil") live_cursor_row=\(liveCursorRow.map(String.init) ?? "nil") live_cursor_col=\(liveCursorCol.map(String.init) ?? "nil") move_up=\(moveUpCount) cached_snapshot=\(cachedSnapshot != nil)"
            )
            if let snapshot = composeSnapshotForCursorRow() ?? cachedSnapshot {
                traceComposeScreenRegion(source: "multiline-clear-before", snapshot: snapshot)
            }

            for _ in 0..<moveUpCount {
                surfaceModel?.sendKeyEvent(.init(key: .arrowUp))
            }

            if let liveCursorCol, liveCursorCol > 0 {
                for _ in 0..<liveCursorCol {
                    surfaceModel?.sendKeyEvent(.init(key: .arrowLeft))
                }
            }

            guard structuralCount > 0 else {
                if let snapshot = composeSnapshotForCursorRow() ?? cachedSnapshot {
                    traceComposeScreenRegion(source: "multiline-clear-after", snapshot: snapshot)
                }
                completion()
                return
            }

            collapseClaudeMultilineScaffoldStep(
                remaining: structuralCount,
                cachedSnapshot: cachedSnapshot,
                completion: completion
            )
        }

        private func collapseClaudeMultilineScaffoldStep(
            remaining: Int,
            cachedSnapshot: PromptInputSnapshot?,
            completion: @escaping () -> Void
        ) {
            guard remaining > 0 else {
                composeClaudeStructuralNewlineCount = 0
                if let snapshot = composeSnapshotForCursorRow() ?? cachedSnapshot {
                    traceComposeScreenRegion(source: "multiline-clear-after", snapshot: snapshot)
                }
                completion()
                return
            }

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) { [weak self] in
                guard let self else { return }

                let liveContext = self.readInputContext()
                let liveCursorRow = liveContext.map { Int($0.cursor_row) }
                let liveCursorCol = max(0, liveContext.map { Int($0.cursor_col) } ?? 0)
                self.composeTrace(
                    "compose multiline scaffold collapse step remaining=\(remaining) cursor_row=\(liveCursorRow.map(String.init) ?? "nil") cursor_col=\(liveCursorCol)"
                )

                if liveCursorCol > 0 {
                    for _ in 0..<liveCursorCol {
                        self.surfaceModel?.sendKeyEvent(.init(key: .arrowLeft))
                    }
                }

                self.surfaceModel?.sendKeyEvent(.init(key: .backspace))
                self.collapseClaudeMultilineScaffoldStep(
                    remaining: remaining - 1,
                    cachedSnapshot: cachedSnapshot,
                    completion: completion
                )
            }
        }

        private func prepareClaudeMultilineDraftForCommit(
            text: String,
            completion: @escaping () -> Void
        ) {
            guard composeSyncToTerminalEnabled else {
                completion()
                return
            }
            composeTrace(
                "compose multiline commit prepare draft_len=\(text.count) structural_newlines=\(composeClaudeStructuralNewlineCount)"
            )
            if let snapshot = composeSnapshotForCursorRow() ?? composeLastResolvedClaudeSnapshot {
                traceComposeScreenRegion(source: "multiline-commit-before", snapshot: snapshot)
            }

            collapseClaudeMultilineScaffoldForCommit(targetLength: text.utf16.count) { [weak self] in
                guard let self else { return }

                DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
                    // Claude already knows how to tokenize a multiline block pasted at commit time.
                    // Keep the local overlay alive until the follow-up Enter fires so that transient
                    // paste-token UI never leaks through to the user.
                    //
                    // Known limitation: because final multiline submit is a single block paste after
                    // scaffold collapse, Claude renders the first committed line after the prompt
                    // gutter but later lines flush-left within the pasted block. Native Claude keeps
                    // all committed lines aligned inside its live multiline scaffold.
                    if !text.isEmpty {
                        self.surfaceModel?.sendText(text)
                    }

                    self.composeTrace("compose multiline commit pasted-block draft_len=\(text.count)")
                    if let snapshot = self.composeSnapshotForCursorRow() ?? self.composeLastResolvedClaudeSnapshot {
                        self.traceComposeScreenRegion(source: "multiline-commit-after", snapshot: snapshot)
                    }
                    completion()
                }
            }
        }

        private func syncClaudeMultilineDraftIncrementally(
            from oldText: String,
            cursor oldCursor: Int,
            to newText: String,
            cursor newCursor: Int
        ) -> Bool {
            guard composeSyncToTerminalEnabled else { return false }

            let oldUnits = Array(oldText.utf16)
            let newUnits = Array(newText.utf16)
            var prefix = 0
            while prefix < oldUnits.count,
                  prefix < newUnits.count,
                  oldUnits[prefix] == newUnits[prefix]
            {
                prefix += 1
            }

            var oldSuffixStart = oldUnits.count
            var newSuffixStart = newUnits.count
            while oldSuffixStart > prefix,
                  newSuffixStart > prefix,
                  oldUnits[oldSuffixStart - 1] == newUnits[newSuffixStart - 1]
            {
                oldSuffixStart -= 1
                newSuffixStart -= 1
            }

            let removedCount = oldSuffixStart - prefix
            let insertedText = stringFromUTF16Slice(newUnits[prefix..<newSuffixStart])

            // Simple insertion at caret.
            if removedCount == 0, prefix == oldCursor {
                syncTerminalCursor(from: composeTerminalCursor, to: oldCursor)
                sendClaudeMultilineInsertedText(insertedText)
                composeTrace(
                    "compose multiline incremental kind=insert prefix=\(prefix) inserted_len=\(insertedText.count) old_cursor=\(oldCursor) new_cursor=\(newCursor)"
                )
                return true
            }

            // Simple backspace/delete immediately before caret.
            if insertedText.isEmpty,
               removedCount > 0,
               prefix == newCursor,
               oldCursor == newCursor + removedCount
            {
                syncTerminalCursor(from: composeTerminalCursor, to: oldCursor)
                for _ in 0..<removedCount {
                    surfaceModel?.sendKeyEvent(.init(key: .backspace))
                }
                composeTrace(
                    "compose multiline incremental kind=backspace prefix=\(prefix) removed=\(removedCount) old_cursor=\(oldCursor) new_cursor=\(newCursor)"
                )
                return true
            }

            composeTrace(
                "compose multiline incremental unsupported prefix=\(prefix) removed=\(removedCount) inserted_len=\(insertedText.count) old_cursor=\(oldCursor) new_cursor=\(newCursor)"
            )
            return false
        }

        private func replaceClaudeComposeDraft(text: String, cursor: Int) {
            guard composeSyncToTerminalEnabled else { return }
            collapseClaudeMultilineScaffoldForCommit(targetLength: text.utf16.count) { [weak self] in
                guard let self else { return }
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.02) {
                    if !text.isEmpty {
                        // Use JTerm's text/paste path so multiline drafts land as a single
                        // bracketed paste in Claude instead of piecemeal raw-input replay.
                        self.surfaceModel?.sendText(text)
                    }

                    let clamped = min(max(0, cursor), text.utf16.count)
                    let distanceFromEnd = max(0, text.utf16.count - clamped)
                    if distanceFromEnd > 0 {
                        for _ in 0..<distanceFromEnd {
                            self.surfaceModel?.sendKeyEvent(.init(key: .arrowLeft))
                        }
                    }
                    self.composeTrace(
                        "compose multiline replace paste draft_len=\(text.count) cursor=\(clamped) distance_from_end=\(distanceFromEnd)"
                    )
                }
            }
        }

        private func replaceTerminalLineForCompose(text: String, cursor: Int) {
            guard composeSyncToTerminalEnabled else { return }
            if composeActivationContext == .claudeTui, text.contains("\n") {
                replaceClaudeComposeDraft(text: text, cursor: cursor)
                return
            }
            // Ctrl+U clears the current Claude/shell input row reliably.
            surfaceModel?.sendRawInput("\u{15}")
            if !text.isEmpty {
                surfaceModel?.sendRawInput(text)
            }

            let clamped = min(max(0, cursor), text.utf16.count)
            if clamped < text.utf16.count {
                for _ in 0..<(text.utf16.count - clamped) {
                    surfaceModel?.sendKeyEvent(.init(key: .arrowLeft))
                }
            }
        }

        private func activateComposeMode(
            with snapshot: PromptInputSnapshot,
            clickPoint: NSPoint
        ) {
            let editor = ensureComposeEditor()
            configureComposeEditorAppearance(editor)

            let context = composeActivationContext
            composeClaudeStructuralNewlineCount = 0
            if context == .claudeTui {
                composeLastResolvedClaudeSnapshot = snapshot
            }
            let mask = ensureComposeMaskView()
            let caret = ensureComposeCaretView()
            mask.isHidden = !composeMaskEnabled
            caret.isHidden = !composeCaretEnabled
            addSubview(mask, positioned: .below, relativeTo: editor)
            addSubview(editor, positioned: .above, relativeTo: mask)
            addSubview(caret, positioned: .above, relativeTo: editor)
            let frame = composeEditorFrame(for: snapshot, context: context)
            composeTrace(
                "activate frame_x=\(frame.minX) frame_y=\(frame.minY) frame_w=\(frame.width) frame_h=\(frame.height) click_x=\(clickPoint.x) click_y=\(clickPoint.y) text_len=\(snapshot.text.count)"
            )
            composeSuppressSync = true
            editor.string = snapshot.text
            normalizeComposeEditorTextAttributes(editor)

            // Vertically center text in the terminal cell row.
            if let font = editor.font {
                let lineHeight = editor.layoutManager?.defaultLineHeight(for: font) ?? font.pointSize
                let insetY = composeTextInsetY(
                    context: context,
                    frameHeight: frame.height,
                    lineHeight: lineHeight
                )
                editor.textContainerInset = NSSize(
                    width: composeTextInsetX(context: context),
                    height: insetY
                )
            } else {
                editor.textContainerInset = NSSize(
                    width: composeTextInsetX(context: context),
                    height: 0
                )
            }
            applyComposeEditorLayout(
                editor: editor,
                snapshot: snapshot,
                resetCaret: false
            )

            editor.isHidden = false
            composeResponderHandoff = true
            if !(window?.makeFirstResponder(editor) ?? false) {
                composeResponderHandoff = false
                resetComposeState(reason: "activate-first-responder-failed")
                return
            }
            composeResponderHandoff = false

            // Important: arm compose state only after responder handoff succeeds.
            // Otherwise resigning SurfaceView during the handoff can immediately blur-cancel compose.
            composeOriginalText = snapshot.text
            composeSyncedText = snapshot.text
            composeSyncedCursor = snapshot.text.utf16.count
            composeTerminalText = snapshot.text
            composeTerminalCursor = snapshot.text.utf16.count
            composeLocalDraftDirty = false
            composePendingKeydownAt = nil
            composeLatencySamplesMs.removeAll(keepingCapacity: false)
            setTerminalCursorHidden(true)
            clearTerminalPreedit()
            composeStabilizeUntil = Date.timeIntervalSinceReferenceDate + 0.45
            composeInsertionTraceBudget = 40
            composeCaretTraceBudget = 40
            composeRowTraceBudget = 60
            pointerStyle = .horizontalText
            NSCursor.iBeam.set()
            composeTrace("compose debug mode=\(composeDebugMode.rawValue)")

            AppDelegate.logger.debug(
                "compose activate x=\(snapshot.x) y=\(snapshot.yTop) w=\(snapshot.width) h=\(snapshot.height) text_len=\(snapshot.text.count)"
            )

            let idx = applyComposeSingleClickInsertion(
                editor: editor,
                clickPointInSurface: clickPoint,
                strictHit: frame.contains(clickPoint),
                traceSource: "activate click"
            )
            traceComposeEditorUnderlineState(editor, source: "activate")

            // Keep shell cursor aligned with clicked insertion position when
            // live syncing is enabled.
            if idx != composeSyncedCursor {
                if composeShouldLiveSync() {
                    syncTerminalCursor(from: composeTerminalCursor, to: idx)
                    composeTerminalCursor = idx
                }
                composeSyncedCursor = idx
            }
            composeTrace("activate done cursor=\(idx)")
        }

        private func sendComposeCommitKey(
            context: ComposeActivationContext?,
            multilineDraft: Bool,
            completion: (() -> Void)? = nil
        ) {
            switch context {
            case .claudeTui:
                // Claude's multiline paste path tokenizes the pasted block before it can be
                // submitted. Give that state transition more time than the single-line case.
                let delay = multilineDraft ? 0.40 : 0.02
                composeTrace("commit key context=claude key=Enter scheduled multiline=\(multilineDraft) delay=\(delay)")
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                    guard let self else { return }
                    self.surfaceModel?.sendKeyEvent(.init(key: .enter, action: .press))
                    self.surfaceModel?.sendKeyEvent(.init(key: .enter, action: .release))
                    self.composeTrace("commit key context=claude key=Enter sent")
                    let cleanupDelay = multilineDraft ? 0.0 : 0.0
                    if cleanupDelay > 0 {
                        DispatchQueue.main.asyncAfter(deadline: .now() + cleanupDelay) {
                            completion?()
                        }
                    } else {
                        completion?()
                    }
                }
            case .shellPrompt, .none:
                surfaceModel?.sendKeyEvent(.init(key: .enter, action: .press))
                surfaceModel?.sendKeyEvent(.init(key: .enter, action: .release))
                composeTrace("commit key context=shell key=Enter")
                completion?()
            }
        }

        private func cleanupComposeSession(resetStabilize: Bool, pauseTracker: Bool = false) {
            composeEditor?.isHidden = true
            composeMaskView?.isHidden = true
            composeCaretView?.isHidden = true
            composeEditor?.isEditable = true
            stopComposeCaretBlink()
            composeOriginalText = nil
            composeSelectionAnchor = nil
            composeResponderHandoff = true
            window?.makeFirstResponder(self)
            composeResponderHandoff = false
            composeTerminalSelectionMode = false
            composeVirtualTrailingGapPending = false
            composeSyncedText = ""
            composeSyncedCursor = 0
            composeTerminalText = ""
            composeTerminalCursor = 0
            composeLocalDraftDirty = false
            composePendingKeydownAt = nil
            composeActivationContext = nil
            composeTrackerMisses = 0
            composeTrackerLastFrame = .null
            composeTrackerPausedUntilExplicitClick = pauseTracker
            composeCommitPending = false
            composeClaudeStructuralNewlineCount = 0
            composeLastResolvedClaudeSnapshot = nil
            pointerStyle = .horizontalText
            setTerminalCursorHidden(false)
            if resetStabilize {
                composeStabilizeUntil = 0
            }
        }

        private func finishCompose(_ reason: ComposeExitReason) {
            guard let original = composeOriginalText else { return }
            guard let editor = composeEditor else { return }
            guard !composeEnding else { return }
            composeEnding = true
            defer { composeEnding = false }

            let draft = editor.string
            let cursor = min(max(0, editor.selectedRange().location), draft.utf16.count)
            let activationContext = composeActivationContext

            switch reason {
            case .commit:
                AppDelegate.logger.debug("compose finish reason=commit draft_len=\(draft.count) original_len=\(original.count)")
                let claudeCommitText = draft
                let multilineDraft: Bool = {
                    guard activationContext == .claudeTui else {
                        return draft.contains("\n")
                    }
                    return composeDesiredClaudeStructuralNewlineCount(
                        editor: editor,
                        draft: draft
                    ) > 0
                }()
                if multilineDraft, activationContext == .claudeTui {
                    composeCommitPending = true
                    composeCaretView?.isHidden = true
                    stopComposeCaretBlink()
                    editor.isEditable = false
                    composeResponderHandoff = true
                    window?.makeFirstResponder(self)
                    composeResponderHandoff = false
                    composeStabilizeUntil = Date.timeIntervalSinceReferenceDate + 1.0
                    prepareClaudeMultilineDraftForCommit(text: claudeCommitText) { [weak self] in
                        guard let self else { return }
                        self.composeTerminalText = claudeCommitText
                        self.composeTerminalCursor = claudeCommitText.utf16.count
                        self.sendComposeCommitKey(
                            context: activationContext,
                            multilineDraft: true
                        ) { [weak self] in
                            guard let self else { return }
                            self.cleanupComposeSession(resetStabilize: false, pauseTracker: true)
                            self.composeTrace("finish reason=commit cleanup=deferred")
                        }
                    }
                    return
                }
                if composeShouldLiveSync() {
                    if draft != composeTerminalText || cursor != composeTerminalCursor {
                        syncTerminalLine(
                            from: composeTerminalText,
                            cursor: composeTerminalCursor,
                            to: draft,
                            cursor: cursor
                        )
                        composeTerminalText = draft
                        composeTerminalCursor = cursor
                    }
                } else {
                    replaceTerminalLineForCompose(text: draft, cursor: cursor)
                    composeTerminalText = draft
                    composeTerminalCursor = cursor
                }
                cleanupComposeSession(resetStabilize: false)
                sendComposeCommitKey(context: activationContext, multilineDraft: multilineDraft)
                composeStabilizeUntil = Date.timeIntervalSinceReferenceDate + (multilineDraft ? 0.70 : 0.08)
            case .cancel:
                AppDelegate.logger.debug("compose finish reason=cancel draft_len=\(draft.count) original_len=\(original.count)")
                if composeShouldLiveSync(), original != composeTerminalText {
                    syncTerminalLine(
                        from: composeTerminalText,
                        cursor: composeTerminalCursor,
                        to: original,
                        cursor: original.utf16.count
                    )
                    composeTerminalText = original
                    composeTerminalCursor = original.utf16.count
                }
                cleanupComposeSession(resetStabilize: true)
            case .blur:
                AppDelegate.logger.debug("compose finish reason=blur draft_len=\(draft.count) original_len=\(original.count)")
                if !composeShouldLiveSync(),
                   (draft != composeTerminalText || cursor != composeTerminalCursor) {
                    replaceTerminalLineForCompose(text: draft, cursor: cursor)
                    composeTerminalText = draft
                    composeTerminalCursor = cursor
                }
                cleanupComposeSession(resetStabilize: true)
            }
            composeTrace("finish reason=\(reason)")
        }

        private func suspendComposeForTerminalSelection() {
            guard composeOriginalText != nil else { return }
            composeTrackerPausedUntilExplicitClick = true
            composeTerminalSelectionMode = true
            composeSelectionAnchor = nil
            composeVirtualTrailingGapPending = false
            composeCaretView?.isHidden = true
            stopComposeCaretBlink()
            composeResponderHandoff = true
            _ = window?.makeFirstResponder(self)
            composeResponderHandoff = false
            composeTrace("compose suspended for terminal selection")
        }

        private func composeSnapshotForCursorRow() -> PromptInputSnapshot? {
            guard let cursorPoint = composeTrackerProbePointInView() ?? cursorClickPointInView() else { return nil }
            switch composeActivationContext {
            case .shellPrompt:
                return resolveShellPromptSnapshot(
                    clickPoint: cursorPoint,
                    source: "composeSnapshotForCursorRow-shell",
                    allowWhenCursorNotAtPrompt: true
                )
            case .claudeTui:
                return resolveClaudePromptSnapshot(source: "composeSnapshotForCursorRow")
            case .none:
                return resolveShellPromptSnapshot(
                    clickPoint: cursorPoint,
                    source: "composeSnapshotForCursorRow-none",
                    allowWhenCursorNotAtPrompt: true
                )
            }
        }

        private func composeCursorIndexFromTerminal(snapshot: PromptInputSnapshot) -> Int {
            guard let cursorPoint = cursorClickPointInView() else {
                return snapshot.text.utf16.count
            }

            let frame = promptInputFrame(snapshot)
            let cellW = max(1, cellSize.width)
            let relativeX = cursorPoint.x - frame.minX
            let idx = Int(round(relativeX / cellW))
            return min(max(0, idx), snapshot.text.utf16.count)
        }

        private func expandClaudeSnapshotToCursorRows(
            _ snapshot: PromptInputSnapshot?
        ) -> PromptInputSnapshot? {
            guard let snapshot else { return nil }
            guard composeActivationContext == .claudeTui else { return snapshot }
            guard composeUsesLocalMultilineDraft() ||
                composeTerminalText.contains("\n") ||
                composeSyncedText.contains("\n")
            else { return snapshot }
            // Keep Claude multiline geometry content-driven. VT traces show Claude
            // often leaves the terminal cursor parked on the native status/help
            // row below the compose box, so expanding to cursor_row covers valid
            // Claude UI and makes it disappear.
            if let inputContext = readInputContext() {
                let cellH = max(1, cellSize.height)
                let promptRow = Int(floor(snapshot.yTop / cellH))
                let cursorRow = max(0, Int(inputContext.cursor_row))
                composeTrace(
                    "claude snapshot cursor-row ignored prompt_row=\(promptRow) cursor_row=\(cursorRow) base_h=\(snapshot.height)"
                )
            }
            return snapshot
        }

        private func refreshComposeFromTerminalAfterTab(attempt: Int = 0) {
            guard composeOriginalText != nil else { return }
            guard let editor = composeEditor, !editor.isHidden else { return }

            if let snapshot = composeSnapshotForCursorRow() {
                composeSuppressSync = true
                if editor.string != snapshot.text {
                    editor.string = snapshot.text
                    normalizeComposeEditorTextAttributes(editor)
                }
                let cursor = composeCursorIndexFromTerminal(snapshot: snapshot)
                editor.setSelectedRange(NSRange(location: cursor, length: 0))
                composeSuppressSync = false
                composeSelectionAnchor = nil
                updateComposeSelectionAppearance(editor)
                applyComposeEditorLayout(
                    editor: editor,
                    snapshot: snapshot,
                    resetCaret: true
                )

                composeSyncedText = snapshot.text
                composeSyncedCursor = cursor
                composeTerminalText = snapshot.text
                composeTerminalCursor = cursor
                composeLocalDraftDirty = false
                composeVirtualTrailingGapPending = false
                composeTrace(
                    "tab refresh success attempt=\(attempt) text_len=\(snapshot.text.count) cursor=\(cursor)"
                )
                return
            }

            if attempt < 6 {
                let next = attempt + 1
                composeTrace("tab refresh retry attempt=\(next)")
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
                    self?.refreshComposeFromTerminalAfterTab(attempt: next)
                }
            } else {
                composeTrace("tab refresh gave up")
            }
        }

        private func handleComposeTab() {
            guard composeOriginalText != nil else { return }
            guard let editor = composeEditor, !editor.isHidden else { return }

            if !composeShouldLiveSync() {
                editor.insertText("\t", replacementRange: editor.selectedRange())
                return
            }

            var cursor = min(max(0, editor.selectedRange().location), editor.string.utf16.count)
            if editor.selectedRange().length > 0 {
                cursor = min(editor.selectedRange().location + editor.selectedRange().length, editor.string.utf16.count)
                composeSuppressSync = true
                editor.setSelectedRange(NSRange(location: cursor, length: 0))
                composeSuppressSync = false
            }

            let draft = editor.string
            if draft != composeTerminalText || cursor != composeTerminalCursor {
                syncTerminalLine(
                    from: composeTerminalText,
                    cursor: composeTerminalCursor,
                    to: draft,
                    cursor: cursor
                )
                composeTerminalText = draft
                composeTerminalCursor = cursor
            }
            composeSyncedText = draft
            composeSyncedCursor = cursor

            composeTrace("tab request draft_len=\(draft.count) cursor=\(cursor)")
            surfaceModel?.sendKeyEvent(.init(key: .tab, action: .press))
            surfaceModel?.sendKeyEvent(.init(key: .tab, action: .release))

            // Let shell completion update the prompt, then mirror terminal state back
            // into the compose editor.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.015) { [weak self] in
                self?.refreshComposeFromTerminalAfterTab(attempt: 0)
            }
        }

        private func composeRelevantModifierFlags(for event: NSEvent) -> NSEvent.ModifierFlags {
            event.modifierFlags.intersection([.shift, .control, .option, .command, .function])
        }

        private func syncComposeDraftToTerminalForPassthrough(editor: NSTextView) {
            let draft = editor.string
            let cursor = min(max(0, editor.selectedRange().location), draft.utf16.count)
            guard draft != composeTerminalText || cursor != composeTerminalCursor else { return }

            if composeShouldLiveSync() {
                syncTerminalLine(
                    from: composeTerminalText,
                    cursor: composeTerminalCursor,
                    to: draft,
                    cursor: cursor
                )
            } else {
                replaceTerminalLineForCompose(text: draft, cursor: cursor)
            }

            composeTerminalText = draft
            composeTerminalCursor = cursor
            composeSyncedText = draft
            composeSyncedCursor = cursor
            composeLocalDraftDirty = false
            composeVirtualTrailingGapPending = false
            composeTrace("compose passthrough synced draft_len=\(draft.count) cursor=\(cursor)")
        }

        @discardableResult
        private func sendComposePassthroughKeyToTerminal(
            _ event: NSEvent,
            reason: String,
            syncDraftFirst: Bool,
            refreshAfter: Bool
        ) -> Bool {
            guard composeOriginalText != nil else { return false }
            guard let editor = composeEditor, !editor.isHidden else { return false }

            if syncDraftFirst {
                syncComposeDraftToTerminalForPassthrough(editor: editor)
            }

            composePendingKeydownAt = nil
            let handled = keyAction(GHOSTTY_ACTION_PRESS, event: event)
            _ = keyAction(GHOSTTY_ACTION_RELEASE, event: event)
            composeTrace(
                "compose passthrough reason=\(reason) keyCode=\(event.keyCode) chars=\(event.charactersIgnoringModifiers ?? "") mods=\(composeRelevantModifierFlags(for: event).rawValue) handled=\(handled) syncDraftFirst=\(syncDraftFirst)"
            )

            if refreshAfter {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
                    self?.refreshComposeFromTerminalAfterTab(attempt: 0)
                }
            }

            return handled
        }

        private func shouldPassthroughComposeControlKey(_ event: NSEvent) -> Bool {
            let mods = composeRelevantModifierFlags(for: event)
            guard mods.contains(.control), !mods.contains(.command), !mods.contains(.option) else {
                return false
            }

            let chars = event.charactersIgnoringModifiers?.lowercased() ?? ""
            switch chars {
            case "c", "d", "l", "z", "\\":
                return true
            default:
                return false
            }
        }

        private func handleComposeStructuralNewline(
            editor: NSTextView,
            reason: String
        ) -> Bool {
            guard composeOriginalText != nil else { return false }
            guard composeActivationContext == .claudeTui else { return false }
            guard composeEditor?.isHidden == false else { return false }

            composePendingKeydownAt = ProcessInfo.processInfo.systemUptime
            composeTrace("compose local multiline insert reason=\(reason)")

            composeSuppressSync = true
            editor.insertText(
                "\n",
                replacementRange: editor.selectedRange()
            )
            composeSuppressSync = false

            normalizeComposeEditorTextAttributes(editor)
            editor.markedTextAttributes = [
                .foregroundColor: composeForegroundColor,
                .backgroundColor: NSColor.clear,
                .underlineStyle: 0,
            ]
            composeSelectionAnchor = nil
            composeVirtualTrailingGapPending = false
            updateComposeSelectionAppearance(editor)

            let draft = editor.string
            let cursor = min(max(0, editor.selectedRange().location), draft.utf16.count)

            // Let Claude grow its own multiline input chrome, but keep the
            // actual draft text local until final commit.
            syncClaudeStructuralNewlines(
                to: composeDesiredClaudeStructuralNewlineCount(
                    editor: editor,
                    draft: draft
                )
            )
            composeSyncedText = draft
            composeSyncedCursor = cursor
            composeLocalDraftDirty = true
            composeTrace("compose multiline structural-newline reason=\(reason) draft_len=\(draft.count) cursor=\(cursor)")

            let layoutSnapshot = composeSnapshotForCursorRow()
            applyComposeEditorLayout(
                editor: editor,
                snapshot: layoutSnapshot,
                resetCaret: true
            )
            maybeRecordComposeLatency()

            DispatchQueue.main.asyncAfter(deadline: .now() + 0.03) { [weak self] in
                self?.tickComposeTracker(reason: "shift-enter")
            }
            return true
        }

        private func handleComposeEditorKeyDown(_ event: NSEvent) -> Bool {
            guard composeOriginalText != nil else { return false }
            guard composeActivationContext == .claudeTui else { return false }
            guard composeEditor?.isHidden == false else { return false }

            let mods = composeRelevantModifierFlags(for: event)

            if (event.keyCode == 36 || event.keyCode == 76),
               mods == [.shift],
               let editor = composeEditor
            {
                return handleComposeStructuralNewline(
                    editor: editor,
                    reason: "shift-enter"
                )
            }

            if event.keyCode == 53,
               !mods.contains(.command),
               !mods.contains(.option)
            {
                return sendComposePassthroughKeyToTerminal(
                    event,
                    reason: "escape",
                    syncDraftFirst: false,
                    refreshAfter: true
                )
            }

            if shouldPassthroughComposeControlKey(event) {
                return sendComposePassthroughKeyToTerminal(
                    event,
                    reason: "terminal-control",
                    syncDraftFirst: false,
                    refreshAfter: true
                )
            }

            return false
        }

        private func handleComposeActivationClick(_ event: NSEvent) -> Bool {
            guard composeOriginalText == nil else { return false }
            guard searchState == nil else { return false }

            let point = convert(event.locationInWindow, from: nil)
            composeTrace("click point_x=\(point.x) point_y=\(point.y)")
            guard let activation = promptInputSnapshot(clickPoint: point) else { return false }

            AppDelegate.logger.debug("compose click hit click_x=\(point.x) click_y=\(point.y)")

            composeTrackerPausedUntilExplicitClick = false
            composeActivationContext = activation.context
            activateComposeMode(with: activation.snapshot, clickPoint: point)
            composeTrackerMisses = 0
            composeTrackerLastFrame = composeEditorFrame(
                for: activation.snapshot,
                context: activation.context
            )
            return true
        }

        private func resumeSuspendedCompose(resetBlink: Bool) {
            guard composeOriginalText != nil else { return }
            guard composeTerminalSelectionMode else { return }
            composeTerminalSelectionMode = false
            composeTrackerPausedUntilExplicitClick = false
            if let surface {
                _ = ghostty_surface_clear_selection(surface)
            }
            if let editor = composeEditor, !editor.isHidden {
                composeResponderHandoff = true
                _ = window?.makeFirstResponder(editor)
                composeResponderHandoff = false
                refreshComposeCaret(resetBlink: resetBlink)
            }
            composeTrace("compose resumed from terminal selection")
        }

        private func copySuspendedTerminalSelectionToPasteboard() -> Bool {
            let responderName = window?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
            let hasSelection = surface.map { ghostty_surface_has_selection($0) } ?? false
            let ok = writeSelection(to: .general, types: [.string])
            composeTrace(
                "clipboard action=copy terminal_selection_mode=true success=\(ok) has_selection=\(hasSelection) responder=\(responderName)"
            )
            return ok
        }

        // MARK: - Notifications

        @objc private func onUpdateRendererHealth(notification: SwiftUI.Notification) {
            guard let healthAny = notification.userInfo?["health"] else { return }
            guard let health = healthAny as? ghostty_action_renderer_health_e else { return }
            DispatchQueue.main.async { [weak self] in
                self?.healthy = health == GHOSTTY_RENDERER_HEALTH_OK
            }
        }

        @objc private func ghosttyDidContinueKeySequence(notification: SwiftUI.Notification) {
            guard let keyAny = notification.userInfo?[JTerm.Notification.KeySequenceKey] else { return }
            guard let key = keyAny as? KeyboardShortcut else { return }
            DispatchQueue.main.async { [weak self] in
                self?.keySequence.append(key)
            }
        }

        @objc private func ghosttyDidEndKeySequence(notification: SwiftUI.Notification) {
            DispatchQueue.main.async { [weak self] in
                self?.keySequence = []
            }
        }

        @objc private func ghosttyDidChangeKeyTable(notification: SwiftUI.Notification) {
            guard let action = notification.userInfo?[JTerm.Notification.KeyTableKey] as? JTerm.Action.KeyTable else { return }

            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                switch action {
                case .activate(let name):
                    self.keyTables.append(name)
                case .deactivate:
                    _ = self.keyTables.popLast()
                case .deactivateAll:
                    self.keyTables.removeAll()
                }
            }
        }

        @objc private func ghosttyConfigDidChange(_ notification: SwiftUI.Notification) {
            // Get our managed configuration object out
            guard let config = notification.userInfo?[
                SwiftUI.Notification.Name.JTermConfigChangeKey
            ] as? JTerm.Config else { return }

            // Update our derived config
            DispatchQueue.main.async { [weak self] in
                self?.derivedConfig = DerivedConfig(config)
            }
        }

        @objc private func ghosttyColorDidChange(_ notification: SwiftUI.Notification) {
            guard let change = notification.userInfo?[
                SwiftUI.Notification.Name.JTermColorChangeKey
            ] as? JTerm.Action.ColorChange else { return }

            switch (change.kind) {
            case .background:
                DispatchQueue.main.async { [weak self] in
                    self?.backgroundColor = change.color
                }

            default:
                // We don't do anything for the other colors yet.
                break
            }
        }

        @objc private func ghosttyBellDidRing(_ notification: SwiftUI.Notification) {
            // Bell state goes to true
            bell = true
        }

        @objc private func ghosttyDidChangeReadonly(_ notification: SwiftUI.Notification) {
            guard let value = notification.userInfo?[SwiftUI.Notification.Name.ReadonlyKey] as? Bool else { return }
            readonly = value
        }

        @objc private func windowDidChangeScreen(notification: SwiftUI.Notification) {
            guard let window = self.window else { return }
            guard let object = notification.object as? NSWindow, window == object else { return }
            guard let screen = window.screen else { return }
            guard let surface = self.surface else { return }

            // When the window changes screens, we need to update libghostty with the screen
            // ID. If vsync is enabled, this will be used with the CVDisplayLink to ensure
            // the proper refresh rate is going.
            ghostty_surface_set_display_id(surface, screen.displayID ?? 0)

            // We also just trigger a backing property change. Just in case the screen has
            // a different scaling factor, this ensures that we update our content scale.
            // Issue: https://github.com/ghostty-org/ghostty/issues/2731
            DispatchQueue.main.async { [weak self] in
                self?.viewDidChangeBackingProperties()
            }
        }

        @objc private func windowDidResignKey(notification: SwiftUI.Notification) {
            guard let window = self.window else { return }
            guard let object = notification.object as? NSWindow, window == object else { return }
            if composeOriginalText != nil {
                if composeShouldPersistAcrossBlur() {
                    composeTrace("windowDidResignKey preserve compose on blur")
                } else {
                    composeTrace("finish trigger source=windowDidResignKey")
                    finishCompose(.blur)
                }
            }
        }

        @objc private func appDidResignActive(_ notification: SwiftUI.Notification) {
            if composeOriginalText != nil {
                if composeShouldPersistAcrossBlur() {
                    composeTrace("appDidResignActive preserve compose on blur")
                } else {
                    composeTrace("finish trigger source=appDidResignActive")
                    finishCompose(.blur)
                }
            }
        }

        // MARK: - NSView

        override func becomeFirstResponder() -> Bool {
            let result = super.becomeFirstResponder()
            if (result) { focusDidChange(true) }
            composeTrace("becomeFirstResponder ok=\(result) compose_active=\(composeOriginalText != nil)")
            return result
        }

        override func resignFirstResponder() -> Bool {
            let result = super.resignFirstResponder()

            // We sometimes call this manually (see SplitView) as a way to force us to
            // yield our focus state.
            let suppressBlur = composeResponderHandoff || composeOriginalText != nil
            if result, !suppressBlur {
                focusDidChange(false)
            }

            composeTrace(
                "resignFirstResponder ok=\(result) compose_active=\(composeOriginalText != nil) suppress_blur=\(suppressBlur)"
            )
            return result
        }

        override func updateTrackingAreas() {
            // To update our tracking area we just recreate it all.
            trackingAreas.forEach { removeTrackingArea($0) }

            // This tracking area is across the entire frame to notify us of mouse movements.
            addTrackingArea(NSTrackingArea(
                rect: frame,
                options: [
                    .mouseEnteredAndExited,
                    .mouseMoved,

                    // Only send mouse events that happen in our visible (not obscured) rect
                    .inVisibleRect,

                    // We want active always because we want to still send mouse reports
                    // even if we're not focused or key.
                    .activeAlways,
                ],
                owner: self,
                userInfo: nil))
        }

        override func viewDidChangeBackingProperties() {
            super.viewDidChangeBackingProperties()

            // The Core Animation compositing engine uses the layer's contentsScale property
            // to determine whether to scale its contents during compositing. When the window
            // moves between a high DPI display and a low DPI display, or the user modifies
            // the DPI scaling for a display in the system settings, this can result in the
            // layer being scaled inappropriately. Since we handle the adjustment of scale
            // and resolution ourselves below, we update the layer's contentsScale property
            // to match the window's backingScaleFactor, so as to ensure it is not scaled by
            // the compositor.
            //
            // Ref: High Resolution Guidelines for OS X
            // https://developer.apple.com/library/archive/documentation/GraphicsAnimation/Conceptual/HighResolutionOSX/CapturingScreenContents/CapturingScreenContents.html#//apple_ref/doc/uid/TP40012302-CH10-SW27
            if let window = window {
                CATransaction.begin()
                // Disable the implicit transition animation that Core Animation applies to
                // property changes. Otherwise it will apply a scale animation to the layer
                // contents which looks pretty janky.
                CATransaction.setDisableActions(true)
                layer?.contentsScale = window.backingScaleFactor
                CATransaction.commit()
            }

            guard let surface = self.surface else { return }

            // Detect our X/Y scale factor so we can update our surface
            let fbFrame = self.convertToBacking(self.frame)
            let xScale = fbFrame.size.width / self.frame.size.width
            let yScale = fbFrame.size.height / self.frame.size.height
            ghostty_surface_set_content_scale(surface, xScale, yScale)

            // When our scale factor changes, so does our fb size so we send that too
            let scaledSize = self.convertToBacking(contentSize)
            setSurfaceSize(width: UInt32(scaledSize.width), height: UInt32(scaledSize.height))
        }

        override func mouseDown(with event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            guard isFinitePoint(point) else {
                composeTrace("mouseDown ignored non-finite point compose_active=\(composeOriginalText != nil)")
                return
            }
            let hadComposeActive = composeOriginalText != nil
            let responderName = window?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
            composeTrace(
                "mouseDown x=\(point.x) y=\(point.y) focused=\(focused) compose_active=\(composeOriginalText != nil) responder=\(responderName) clickCount=\(event.clickCount) buttons=\(NSEvent.pressedMouseButtons)"
            )

            if composeOriginalText != nil {
                if let editor = composeEditor, !editor.isHidden {
                    let strictHit = editor.frame.contains(point)
                    composeTrace(
                        "mouseDown compose hit strict=\(strictHit) frame_x=\(editor.frame.minX) frame_y=\(editor.frame.minY) frame_w=\(editor.frame.width) frame_h=\(editor.frame.height)"
                    )
                    guard strictHit else {
                        // In Claude mode, clicking elsewhere in the surface should not
                        // tear down/recreate compose; that causes cursor resets/flicker.
                        if point.y > editor.frame.maxY {
                            composeTrace("mouseDown outside compose allow-terminal-selection-above-row")
                            suspendComposeForTerminalSelection()
                            self.mouseMoved(with: event)
                            guard let surface = self.surface else { return }
                            let mods = JTerm.ghosttyMods(event.modifierFlags)
                            ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, mods)
                            return
                        }
                        if composeShouldPersistAcrossBlur() {
                            if window?.firstResponder !== editor {
                                _ = window?.makeFirstResponder(editor)
                            }
                            composeTrace("mouseDown outside compose swallowed preserve-on-blur")
                            refreshComposeCaret(resetBlink: true)
                            return
                        }
                        composeTrace("finish trigger source=mouseDown-outside-compose")
                        finishCompose(.blur)
                        // Continue normal terminal handling below after compose closes.
                        _ = window?.makeFirstResponder(self)
                        composeTrace("mouseDown after makeFirstResponder compose_active=\(composeOriginalText != nil)")
                        if handleComposeActivationClick(event) {
                            composeTrace("mouseDown compose activated")
                            return
                        }
                        // Do not forward the same click that just blurred compose.
                        // Forwarding this down event can start unintended terminal
                        // drag-selection when users are leaving the compose row.
                        composeTrace("mouseDown swallowed post-compose-blur")
                        return
                    }

                    if window?.firstResponder !== editor {
                        _ = window?.makeFirstResponder(editor)
                    }
                    resumeSuspendedCompose(resetBlink: true)

                    if event.clickCount == 1 {
                        _ = applyComposeSingleClickInsertion(
                            editor: editor,
                            clickPointInSurface: point,
                            strictHit: true,
                            traceSource: "mouseDown compose manual single-click"
                        )
                        return
                    }

                    editor.mouseDown(with: event)
                    return
                }

                if composeShouldPersistAcrossBlur() {
                    composeTrace("mouseDown outside compose ignored preserve-on-blur editor-missing")
                    return
                }
                composeTrace("finish trigger source=mouseDown-outside-compose")
                finishCompose(.blur)
            }

            _ = window?.makeFirstResponder(self)
            composeTrace("mouseDown after makeFirstResponder compose_active=\(composeOriginalText != nil)")
            if handleComposeActivationClick(event) {
                composeTrace("mouseDown compose activated")
                return
            }
            if hadComposeActive {
                // Compose was active at click start and is now closed; swallow this
                // first click to avoid leaking it into terminal selection logic.
                composeTrace("mouseDown swallowed post-compose-blur")
                return
            }
            composeTrace("mouseDown forwarding to terminal")

            guard let surface = self.surface else { return }
            self.mouseMoved(with: event)
            let mods = JTerm.ghosttyMods(event.modifierFlags)
            ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, mods)
        }

        override func mouseUp(with event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            composeTrace("mouseUp x=\(point.x) y=\(point.y) compose_active=\(composeOriginalText != nil) buttons=\(NSEvent.pressedMouseButtons)")
            if composeOriginalText != nil {
                if composeTerminalSelectionMode {
                    guard let surface = self.surface else { return }
                    let mods = JTerm.ghosttyMods(event.modifierFlags)
                    ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, mods)
                    ghostty_surface_mouse_pressure(surface, 0, 0)
                    return
                }
                composeSelectionAnchor = nil
                return
            }

            // Always reset our pressure when the mouse goes up
            prevPressureStage = 0

            // If we have an active surface, report the event
            guard let surface = self.surface else { return }
            let mods = JTerm.ghosttyMods(event.modifierFlags)
            ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, mods)

            // Release pressure
            ghostty_surface_mouse_pressure(surface, 0, 0)
        }

        override func otherMouseDown(with event: NSEvent) {
            guard let surface = self.surface else { return }
            let mods = JTerm.ghosttyMods(event.modifierFlags)
            let button = JTerm.Input.MouseButton(fromNSEventButtonNumber: event.buttonNumber)
            ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, button.cMouseButton, mods)
        }

        override func otherMouseUp(with event: NSEvent) {
            guard let surface = self.surface else { return }
            let mods = JTerm.ghosttyMods(event.modifierFlags)
            let button = JTerm.Input.MouseButton(fromNSEventButtonNumber: event.buttonNumber)
            ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, button.cMouseButton, mods)
        }


        override func rightMouseDown(with event: NSEvent) {
            if composeOriginalText != nil {
                composeTrace("finish trigger source=rightMouseDown")
                finishCompose(.blur)
            }

            guard let surface = self.surface else { return super.rightMouseDown(with: event) }

            let mods = JTerm.ghosttyMods(event.modifierFlags)
            if (ghostty_surface_mouse_button(
                surface,
                GHOSTTY_MOUSE_PRESS,
                GHOSTTY_MOUSE_RIGHT,
                mods
            )) {
                // Consumed
                return
            }

            // Mouse event not consumed
            super.rightMouseDown(with: event)
        }

        override func rightMouseUp(with event: NSEvent) {
            guard let surface = self.surface else { return super.rightMouseUp(with: event) }

            let mods = JTerm.ghosttyMods(event.modifierFlags)
            if (ghostty_surface_mouse_button(
                surface,
                GHOSTTY_MOUSE_RELEASE,
                GHOSTTY_MOUSE_RIGHT,
                mods
            )) {
                // Handled
                return
            }

            // Mouse event not consumed
            super.rightMouseUp(with: event)
        }

        override func mouseEntered(with event: NSEvent) {
            super.mouseEntered(with: event)

            guard let surfaceModel else { return }

            // On mouse enter we need to reset our cursor position. This is
            // super important because we set it to -1/-1 on mouseExit and
            // lots of mouse logic (i.e. whether to send mouse reports) depend
            // on the position being in the viewport if it is.
            let pos = self.convert(event.locationInWindow, from: nil)
            let mouseEvent = JTerm.Input.MousePosEvent(
                x: pos.x,
                y: frame.height - pos.y,
                mods: .init(nsFlags: event.modifierFlags)
            )
            surfaceModel.sendMousePos(mouseEvent)
        }

        override func mouseExited(with event: NSEvent) {
            guard let surfaceModel else { return }

            // If the mouse is being dragged then we don't have to emit
            // this because we get mouse drag events even if we've already
            // exited the viewport (i.e. mouseDragged)
            if NSEvent.pressedMouseButtons != 0 {
                return
            }

            // Negative values indicate cursor has left the viewport
            let mouseEvent = JTerm.Input.MousePosEvent(
                x: -1,
                y: -1,
                mods: .init(nsFlags: event.modifierFlags)
            )
            surfaceModel.sendMousePos(mouseEvent)
        }

        override func resetCursorRects() {
            super.resetCursorRects()
            if composeOriginalText != nil && !composeTerminalSelectionMode {
                addCursorRect(bounds, cursor: .iBeam)
            }
        }

        override func cursorUpdate(with event: NSEvent) {
            if composeOriginalText != nil && !composeTerminalSelectionMode {
                pointerStyle = .horizontalText
                NSCursor.iBeam.set()
                return
            }
            super.cursorUpdate(with: event)
        }

        override func mouseMoved(with event: NSEvent) {
            if composeOriginalText != nil && !composeTerminalSelectionMode {
                // While native compose is active, keep text-edit cursor feedback
                // and avoid feeding hover updates back into terminal cursor-shape state.
                pointerStyle = .horizontalText
                NSCursor.iBeam.set()
                return
            }

            guard let surfaceModel else { return }

            // Convert window position to view position. Note (0, 0) is bottom left.
            let pos = self.convert(event.locationInWindow, from: nil)
            let mouseEvent = JTerm.Input.MousePosEvent(
                x: pos.x,
                y: frame.height - pos.y,
                mods: .init(nsFlags: event.modifierFlags)
            )
            surfaceModel.sendMousePos(mouseEvent)

            // Handle focus-follows-mouse
            if let window,
               let controller = window.windowController as? BaseTerminalController,
               !controller.commandPaletteIsShowing,
               (window.isKeyWindow &&
                    !self.focused &&
                    controller.focusFollowsMouse)
            {
                JTerm.moveFocus(to: self)
            }
        }

        override func mouseDragged(with event: NSEvent) {
            if composeOriginalText != nil {
                if composeTerminalSelectionMode {
                    self.mouseMoved(with: event)
                    return
                }
                guard let editor = composeEditor, !editor.isHidden else { return }
                let point = convert(event.locationInWindow, from: nil)
                if !isFinitePoint(point) { return }

                if composeSelectionAnchor == nil {
                    let current = min(max(0, editor.selectedRange().location), editor.string.utf16.count)
                    composeSelectionAnchor = current
                }

                if let anchor = composeSelectionAnchor {
                    let idx = updateComposeSelectionForDrag(
                        editor: editor,
                        anchor: anchor,
                        pointInSurface: point
                    )
                    composeTrace("mouseDragged compose selection anchor=\(anchor) idx=\(idx)")
                    refreshComposeCaret(resetBlink: false)
                }
                return
            }
            self.mouseMoved(with: event)
        }

        override func rightMouseDragged(with event: NSEvent) {
            if composeOriginalText != nil { return }
            self.mouseMoved(with: event)
        }

        override func otherMouseDragged(with event: NSEvent) {
            if composeOriginalText != nil { return }
            self.mouseMoved(with: event)
        }

        override func scrollWheel(with event: NSEvent) {
            guard let surfaceModel else { return }

            var x = event.scrollingDeltaX
            var y = event.scrollingDeltaY
            let precision = event.hasPreciseScrollingDeltas

            if precision {
                // We do a 2x speed multiplier. This is subjective, it "feels" better to me.
                x *= 2;
                y *= 2;

                // TODO(mitchellh): do we have to scale the x/y here by window scale factor?
            }

            let scrollEvent = JTerm.Input.MouseScrollEvent(
                x: x,
                y: y,
                mods: .init(precision: precision, momentum: .init(event.momentumPhase))
            )
            surfaceModel.sendMouseScroll(scrollEvent)
            if composeOriginalText != nil, composeActivationContext == .claudeTui {
                composeTrackerLastFrame = .null
                DispatchQueue.main.async { [weak self] in
                    self?.tickComposeTracker(reason: "scroll")
                }
            }
        }

        override func pressureChange(with event: NSEvent) {
            guard let surface = self.surface else { return }

            // Notify JTerm first. We do this because this will let JTerm handle
            // state setup that we'll need for later pressure handling (such as
            // QuickLook)
            ghostty_surface_mouse_pressure(surface, UInt32(event.stage), Double(event.pressure))

            // Pressure stage 2 is force click. We only want to execute this on the
            // initial transition to stage 2, and not for any repeated events.
            guard self.prevPressureStage < 2 else { return }
            prevPressureStage = event.stage
            guard event.stage == 2 else { return }

            // If the user has force click enabled then we do a quick look. There
            // is no public API for this as far as I can tell.
            guard UserDefaults.standard.bool(forKey: "com.apple.trackpad.forceClick") else { return }
            quickLook(with: event)
        }

        override func keyDown(with event: NSEvent) {
            composeTrace(
                "keyDown keyCode=\(event.keyCode) chars=\(event.charactersIgnoringModifiers ?? "") compose_active=\(composeOriginalText != nil)"
            )
            if composeOriginalText != nil {
                if let editor = composeEditor, !editor.isHidden {
                    let disallowed: NSEvent.ModifierFlags = [.command, .control, .function]
                    if event.modifierFlags.intersection(disallowed).isEmpty {
                        composePendingKeydownAt = ProcessInfo.processInfo.systemUptime
                    }
                    window?.makeFirstResponder(editor)
                    editor.keyDown(with: event)
                    return
                }
                resetComposeState(reason: "keyDown compose-without-editor")
            }

            guard let surface = self.surface else {
                self.interpretKeyEvents([event])
                return
            }

            // On any keyDown event we unset our bell state
            bell = false

            // We need to translate the mods (maybe) to handle configs such as option-as-alt
            let translationModsGhostty = JTerm.eventModifierFlags(
                mods: ghostty_surface_key_translation_mods(
                    surface,
                    JTerm.ghosttyMods(event.modifierFlags)
                )
            )

            // There are hidden bits set in our event that matter for certain dead keys
            // so we can't use translationModsGhostty directly. Instead, we just check
            // for exact states and set them.
            var translationMods = event.modifierFlags
            for flag in [NSEvent.ModifierFlags.shift, .control, .option, .command] {
                if (translationModsGhostty.contains(flag)) {
                    translationMods.insert(flag)
                } else {
                    translationMods.remove(flag)
                }
            }

            // If the translation modifiers are not equal to our original modifiers
            // then we need to construct a new NSEvent. If they are equal we reuse the
            // old one. IMPORTANT: we MUST reuse the old event if they're equal because
            // this keeps things like Korean input working. There must be some object
            // equality happening in AppKit somewhere because this is required.
            let translationEvent: NSEvent
            if (translationMods == event.modifierFlags) {
                translationEvent = event
            } else {
                translationEvent = NSEvent.keyEvent(
                    with: event.type,
                    location: event.locationInWindow,
                    modifierFlags: translationMods,
                    timestamp: event.timestamp,
                    windowNumber: event.windowNumber,
                    context: nil,
                    characters: event.characters(byApplyingModifiers: translationMods) ?? "",
                    charactersIgnoringModifiers: event.charactersIgnoringModifiers ?? "",
                    isARepeat: event.isARepeat,
                    keyCode: event.keyCode
                ) ?? event
            }

            let action = event.isARepeat ? GHOSTTY_ACTION_REPEAT : GHOSTTY_ACTION_PRESS

            // By setting this to non-nil, we note that we're in a keyDown event. From here,
            // we call interpretKeyEvents so that we can handle complex input such as Korean
            // language.
            keyTextAccumulator = []
            defer { keyTextAccumulator = nil }

            // We need to know what the length of marked text was before this event to
            // know if these events cleared it.
            let markedTextBefore = markedText.length > 0

            // We need to know the keyboard layout before below because some keyboard
            // input events will change our keyboard layout and we don't want those
            // going to the terminal.
            let keyboardIdBefore: String? = if (!markedTextBefore) {
                KeyboardLayout.id
            } else {
                nil
            }

            // If we are in a keyDown then we don't need to redispatch a command-modded
            // key event (see docs for this field) so reset this to nil because
            // `interpretKeyEvents` may dispatch it.
            self.lastPerformKeyEvent = nil

            self.interpretKeyEvents([translationEvent])

            // If our keyboard changed from this we just assume an input method
            // grabbed it and do nothing.
            if (!markedTextBefore && keyboardIdBefore != KeyboardLayout.id) {
                return
            }

            // If we have marked text, we're in a preedit state. The order we
            // do this and the key event callbacks below doesn't matter since
            // we control the preedit state only through the preedit API.
            syncPreedit(clearIfNeeded: markedTextBefore)

            if let list = keyTextAccumulator, list.count > 0 {
                // If we have text, then we've composed a character, send that down.
                // These never have "composing" set to true because these are the
                // result of a composition.
                for text in list {
                    _ = keyAction(
                        action,
                        event: event,
                        translationEvent: translationEvent,
                        text: text
                    )
                }
            } else {
                // We have no accumulated text so this is a normal key event.
                _ = keyAction(
                    action,
                    event: event,
                    translationEvent: translationEvent,
                    text: translationEvent.ghosttyCharacters,

                    // We're composing if we have preedit (the obvious case). But we're also
                    // composing if we don't have preedit and we had marked text before,
                    // because this input probably just reset the preedit state. It shouldn't
                    // be encoded. Example: Japanese begin composing, the press backspace.
                    // This should only cancel the composing state but not actually delete
                    // the prior input characters (prior to the composing).
                    composing: markedText.length > 0 || markedTextBefore
                )
            }
        }

        override func keyUp(with event: NSEvent) {
            _ = keyAction(GHOSTTY_ACTION_RELEASE, event: event)
        }

        /// Records the timestamp of the last event to performKeyEquivalent that we need to save.
        /// We currently save all commands with command or control set.
        ///
        /// For command+key inputs, the AppKit input stack calls performKeyEquivalent to give us a chance
        /// to handle them first. If we return "false" then it goes through the standard AppKit responder chain.
        /// For an NSTextInputClient, that may redirect some commands _before_ our keyDown gets called.
        /// Concretely: Command+Period will do: performKeyEquivalent, doCommand ("cancel:"). In doCommand,
        /// we need to know that we actually want to handle that in keyDown, so we send it back through the
        /// event dispatch system and use this timestamp as an identity to know to actually send it to keyDown.
        ///
        /// Why not send it to keyDown always? Because if the user rebinds a command to something we
        /// actually handle then we do want the standard response chain to handle the key input. Unfortunately,
        /// we can't know what a command is bound to at a system level until we let it flow through the system.
        /// That's the crux of the problem.
        ///
        /// So, we have to send it back through if we didn't handle it.
        ///
        /// The next part of the problem is comparing NSEvent identity seems pretty nasty. I couldn't
        /// find a good way to do it. I originally stored a weak ref and did identity comparison but that
        /// doesn't work and for reasons I couldn't figure out the value gets mangled (fields don't match
        /// before/after the assignment). I suspect it has something to do with the fact an NSEvent is wrapping
        /// a lower level event pointer and its just not surviving the Swift runtime somehow. I don't know.
        ///
        /// The best thing I could find was to store the event timestamp which has decent granularity
        /// and compare that. To further complicate things, some events are synthetic and have a zero
        /// timestamp so we have to protect against that. Fun!
        var lastPerformKeyEvent: TimeInterval?

        /// Special case handling for some control keys
        override func performKeyEquivalent(with event: NSEvent) -> Bool {
            // We only care about key down events. It might not even be possible
            // to receive any other event type here.
            guard event.type == .keyDown else { return false }

            // If another control currently owns first responder outside this
            // surface tree, we should not intercept key equivalents here. This
            // preserves native text editing behavior for overlays/input fields
            // hosted above the terminal view.
            if let firstResponder = window?.firstResponder as? NSView,
               firstResponder !== self,
               !firstResponder.isDescendant(of: self) {
                return false
            }
            
            // Only process events if we're focused. Some key events like C-/ macOS
            // appears to send to the first view in the hierarchy rather than the
            // the first responder (I don't know why). This prevents us from handling it.
            // Besides C-/, its important we don't process key equivalents if unfocused
            // because there are other event listeners for that (i.e. AppDelegate's
            // local event handler).
            if (!focused) {
                return false
            }

            if composeTerminalSelectionMode,
               event.modifierFlags.contains(.command),
               let chars = event.charactersIgnoringModifiers?.lowercased()
            {
                switch chars {
                case "c":
                    return copySuspendedTerminalSelectionToPasteboard()
                default:
                    break
                }
            }

            // While native compose editing is active, let AppKit text editing
            // key equivalents take precedence (Cmd+C/X/V/A, etc.).
            if composeOriginalText != nil,
               !composeTerminalSelectionMode,
               let editor = composeEditor,
               !editor.isHidden
            {
                if window?.firstResponder !== editor {
                    _ = window?.makeFirstResponder(editor)
                }

                if editor.performKeyEquivalent(with: event) {
                    composeTrace(
                        "performKeyEquivalent compose handled chars=\(event.charactersIgnoringModifiers ?? "") mods=\(event.modifierFlags.rawValue)"
                    )
                    return true
                }

                // Some key equivalents may not be claimed by performKeyEquivalent
                // depending on responder-chain state; handle common edit keys directly.
                if event.modifierFlags.contains(.command),
                   let chars = event.charactersIgnoringModifiers?.lowercased()
                {
                    switch chars {
                    case "a":
                        composeTrace("clipboard action=select_all source=performKeyEquivalent")
                        editor.selectAll(nil)
                        return true
                    case "c":
                        composeTrace("clipboard action=copy source=performKeyEquivalent")
                        editor.copy(nil)
                        return true
                    case "x":
                        composeTrace("clipboard action=cut source=performKeyEquivalent")
                        editor.cut(nil)
                        return true
                    case "v":
                        composeTrace("clipboard action=paste source=performKeyEquivalent")
                        editor.paste(nil)
                        return true
                    default:
                        break
                    }
                }

                return false
            }
            
            // Get information about if this is a binding.
            let bindingFlags = surfaceModel.flatMap { surface in
                var ghosttyEvent = event.ghosttyKeyEvent(GHOSTTY_ACTION_PRESS)
                return (event.characters ?? "").withCString { ptr in
                    ghosttyEvent.text = ptr
                    return surface.keyIsBinding(ghosttyEvent)
                }
            }
            
            // If this is a binding then we want to perform it.
            if let bindingFlags {
                // Attempt to trigger a menu item for this key binding. We only do this if:
                //   - We're not in a key sequence or table (those are separate bindings)
                //   - The binding is NOT `all` (menu uses FirstResponder chain)
                //   - The binding is NOT `performable` (menu will always consume)
                //   - The binding is `consumed` (unconsumed bindings should pass through
                //     to the terminal, so we must not intercept them for the menu)
                if keySequence.isEmpty,
                   keyTables.isEmpty,
                   bindingFlags.isDisjoint(with: [.all, .performable]),
                   bindingFlags.contains(.consumed) {
                    if let menu = NSApp.mainMenu, menu.performKeyEquivalent(with: event) {
                        return true
                    }
                }
                
                self.keyDown(with: event)
                return true
            }

            let equivalent: String
            switch (event.charactersIgnoringModifiers) {
            case "\r":
                // Pass C-<return> through verbatim
                // (prevent the default context menu equivalent)
                if (!event.modifierFlags.contains(.control)) {
                    return false
                }

                equivalent = "\r"

            case "/":
                // Treat C-/ as C-_. We do this because C-/ makes macOS make a beep
                // sound and we don't like the beep sound.
                if (!event.modifierFlags.contains(.control) ||
                    !event.modifierFlags.isDisjoint(with: [.shift, .command, .option])) {
                    return false
                }

                equivalent = "_"

            default:
                // It looks like some part of AppKit sometimes generates synthetic NSEvents
                // with a zero timestamp. We never process these at this point. Concretely,
                // this happens for me when pressing Cmd+period with default bindings. This
                // binds to "cancel" which goes through AppKit to produce a synthetic "escape".
                //
                // Question: should we be ignoring all synthetic events? Should we be finding
                // synthetic escape and ignoring it? I feel like Cmd+period could map to a
                // escape binding by accident, but it hasn't happened yet...
                if event.timestamp == 0 {
                    return false
                }

                // All of this logic here re: lastCommandEvent is to workaround some
                // nasty behavior. See the docs for lastCommandEvent for more info.

                // Ignore all other non-command events. This lets the event continue
                // through the AppKit event systems.
                if (!event.modifierFlags.contains(.command) &&
                    !event.modifierFlags.contains(.control)) {
                    // Reset since we got a non-command event.
                    lastPerformKeyEvent = nil
                    return false
                }

                // If we have a prior command binding and the timestamp matches exactly
                // then we pass it through to keyDown for encoding.
                if let lastPerformKeyEvent {
                    self.lastPerformKeyEvent = nil
                    if lastPerformKeyEvent == event.timestamp {
                        equivalent = event.characters ?? ""
                        break
                    }
                }

                lastPerformKeyEvent = event.timestamp
                return false
            }

            let finalEvent = NSEvent.keyEvent(
                with: .keyDown,
                location: event.locationInWindow,
                modifierFlags: event.modifierFlags,
                timestamp: event.timestamp,
                windowNumber: event.windowNumber,
                context: nil,
                characters: equivalent,
                charactersIgnoringModifiers: equivalent,
                isARepeat: event.isARepeat,
                keyCode: event.keyCode
            )

            self.keyDown(with: finalEvent!)
            return true
        }

        override func flagsChanged(with event: NSEvent) {
            let mod: UInt32;
            switch (event.keyCode) {
            case 0x39: mod = GHOSTTY_MODS_CAPS.rawValue
            case 0x38, 0x3C: mod = GHOSTTY_MODS_SHIFT.rawValue
            case 0x3B, 0x3E: mod = GHOSTTY_MODS_CTRL.rawValue
            case 0x3A, 0x3D: mod = GHOSTTY_MODS_ALT.rawValue
            case 0x37, 0x36: mod = GHOSTTY_MODS_SUPER.rawValue
            default: return
            }

            // If we're in the middle of a preedit, don't do anything with mods.
            if hasMarkedText() { return }

            // The keyAction function will do this AGAIN below which sucks to repeat
            // but this is super cheap and flagsChanged isn't that common.
            let mods = JTerm.ghosttyMods(event.modifierFlags)

            // If the key that pressed this is active, its a press, else release.
            var action = GHOSTTY_ACTION_RELEASE
            if (mods.rawValue & mod != 0) {
                // If the key is pressed, its slightly more complicated, because we
                // want to check if the pressed modifier is the correct side. If the
                // correct side is pressed then its a press event otherwise its a release
                // event with the opposite modifier still held.
                let sidePressed: Bool
                switch (event.keyCode) {
                case 0x3C:
                    sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERSHIFTKEYMASK) != 0;
                case 0x3E:
                    sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERCTLKEYMASK) != 0;
                case 0x3D:
                    sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERALTKEYMASK) != 0;
                case 0x36:
                    sidePressed = event.modifierFlags.rawValue & UInt(NX_DEVICERCMDKEYMASK) != 0;
                default:
                    sidePressed = true
                }

                if (sidePressed) {
                    action = GHOSTTY_ACTION_PRESS
                }
            }

            _ = keyAction(action, event: event)
        }

        private func keyAction(
            _ action: ghostty_input_action_e,
            event: NSEvent,
            translationEvent: NSEvent? = nil,
            text: String? = nil,
            composing: Bool = false
        ) -> Bool {
            guard let surface = self.surface else { return false }

            var key_ev = event.ghosttyKeyEvent(action, translationMods: translationEvent?.modifierFlags)
            key_ev.composing = composing

            // For text, we only encode UTF8 if we don't have a single control
            // character. Control characters are encoded by JTerm itself.
            // Without this, `ctrl+enter` does the wrong thing.
            if let text, text.count > 0,
               let codepoint = text.utf8.first, codepoint >= 0x20 {
                return text.withCString { ptr in
                    key_ev.text = ptr
                    return ghostty_surface_key(surface, key_ev)
                }
            } else {
                return ghostty_surface_key(surface, key_ev)
            }
        }

        override func quickLook(with event: NSEvent) {
            guard let surface = self.surface else { return super.quickLook(with: event) }

            // Grab the text under the cursor
            var text = ghostty_text_s()
            guard ghostty_surface_quicklook_word(surface, &text) else { return super.quickLook(with: event) }
            defer { ghostty_surface_free_text(surface, &text) }
            guard text.text_len > 0  else { return super.quickLook(with: event) }

            // If we can get a font then we use the font. This should always work
            // since we always have a primary font. The only scenario this doesn't
            // work is if someone is using a non-CoreText build which would be
            // unofficial.
            var attributes: [ NSAttributedString.Key : Any ] = [:];
            if let fontRaw = ghostty_surface_quicklook_font(surface) {
                // Memory management here is wonky: ghostty_surface_quicklook_font
                // will create a copy of a CTFont, Swift will auto-retain the
                // unretained value passed into the dict, so we release the original.
                let font = Unmanaged<CTFont>.fromOpaque(fontRaw)
                attributes[.font] = font.takeUnretainedValue()
                font.release()
            }

            // JTerm coordinate system is top-left, convert to bottom-left for AppKit
            let pt = NSMakePoint(text.tl_px_x, frame.size.height - text.tl_px_y)
            let str = NSAttributedString.init(string: String(cString: text.text), attributes: attributes)
            self.showDefinition(for: str, at: pt);
        }

        override func menu(for event: NSEvent) -> NSMenu? {
            // We only support right-click menus
            switch event.type {
            case .rightMouseDown:
                // Good
                break

            case .leftMouseDown:
                if !event.modifierFlags.contains(.control) {
                    return nil
                }

                // In this case, AppKit calls menu BEFORE calling any mouse events.
                // If mouse capturing is enabled then we never show the context menu
                // so that we can handle ctrl+left-click in the terminal app.
                guard let surfaceModel else { return nil }
                if surfaceModel.mouseCaptured {
                    return nil
                }

                // If we return a non-nil menu then mouse events will never be
                // processed by the core, so we need to manually send a right
                // mouse down event.
                //
                // Note this never sounds a right mouse up event but that's the
                // same as normal right-click with capturing disabled from AppKit.
                surfaceModel.sendMouseButton(.init(
                    action: .press,
                    button: .right,
                    mods: .init(nsFlags: event.modifierFlags)))

            default:
                return nil
            }

            let menu = NSMenu()

            // We just use a floating var so we can easily setup metadata on each item
            // in a row without storing it all.
            var item: NSMenuItem

            // If we have a selection, add copy
            if let text = self.accessibilitySelectedText(), text.count > 0 {
                menu.addItem(withTitle: "Copy", action: #selector(copy(_:)), keyEquivalent: "")
            }
            menu.addItem(withTitle: "Paste", action: #selector(paste(_:)), keyEquivalent: "")

            menu.addItem(.separator())
            item = menu.addItem(withTitle: "Split Right", action: #selector(splitRight(_:)), keyEquivalent: "")
            item.setImageIfDesired(systemSymbolName: "rectangle.righthalf.inset.filled")
            item = menu.addItem(withTitle: "Split Left", action: #selector(splitLeft(_:)), keyEquivalent: "")
            item.setImageIfDesired(systemSymbolName: "rectangle.leadinghalf.inset.filled")
            item = menu.addItem(withTitle: "Split Down", action: #selector(splitDown(_:)), keyEquivalent: "")
            item.setImageIfDesired(systemSymbolName: "rectangle.bottomhalf.inset.filled")
            item = menu.addItem(withTitle: "Split Up", action: #selector(splitUp(_:)), keyEquivalent: "")
            item.setImageIfDesired(systemSymbolName: "rectangle.tophalf.inset.filled")

            menu.addItem(.separator())
            item = menu.addItem(withTitle: "Reset Terminal", action: #selector(resetTerminal(_:)), keyEquivalent: "")
            item.setImageIfDesired(systemSymbolName: "arrow.trianglehead.2.clockwise")
            item = menu.addItem(withTitle: "Toggle Terminal Inspector", action: #selector(toggleTerminalInspector(_:)), keyEquivalent: "")
            item.setImageIfDesired(systemSymbolName: "scope")
            item = menu.addItem(withTitle: "Terminal Read-only", action: #selector(toggleReadonly(_:)), keyEquivalent: "")
            item.setImageIfDesired(systemSymbolName: "eye.fill")
            item.state = readonly ? .on : .off
            menu.addItem(.separator())
            item = menu.addItem(withTitle: "Change Tab Title...", action: #selector(BaseTerminalController.changeTabTitle(_:)), keyEquivalent: "")
            item.setImageIfDesired(systemSymbolName: "pencil.line")
            item = menu.addItem(withTitle: "Change Terminal Title...", action: #selector(changeTitle(_:)), keyEquivalent: "")

            return menu
        }

        // MARK: Menu Handlers

        @IBAction func copy(_ sender: Any?) {
            if composeTerminalSelectionMode {
                if copySuspendedTerminalSelectionToPasteboard() {
                    return
                }
            }

            if composeOriginalText != nil,
               !composeTerminalSelectionMode,
               let editor = composeEditor,
               !editor.isHidden
            {
                let sel = editor.selectedRange()
                composeTrace(
                    "clipboard action=copy sel_loc=\(sel.location) sel_len=\(sel.length) draft_len=\(editor.string.count)"
                )
                if window?.firstResponder !== editor {
                    _ = window?.makeFirstResponder(editor)
                }
                editor.copy(sender)
                return
            }

            guard let surface = self.surface else { return }
            let action = "copy_to_clipboard"
            if (!ghostty_surface_binding_action(surface, action, UInt(action.lengthOfBytes(using: .utf8)))) {
                AppDelegate.logger.warning("action failed action=\(action)")
            }
        }

        @IBAction func cut(_ sender: Any?) {
            if composeOriginalText != nil,
               !composeTerminalSelectionMode,
               let editor = composeEditor,
               !editor.isHidden
            {
                let sel = editor.selectedRange()
                composeTrace(
                    "clipboard action=cut sel_loc=\(sel.location) sel_len=\(sel.length) draft_len=\(editor.string.count)"
                )
                if window?.firstResponder !== editor {
                    _ = window?.makeFirstResponder(editor)
                }
                editor.cut(sender)
                return
            }

            // No-op for terminal content outside compose mode.
        }

        @IBAction func paste(_ sender: Any?) {
            if composeOriginalText != nil,
               !composeTerminalSelectionMode,
               let editor = composeEditor,
               !editor.isHidden
            {
                let sel = editor.selectedRange()
                composeTrace(
                    "clipboard action=paste sel_loc=\(sel.location) sel_len=\(sel.length) draft_len=\(editor.string.count)"
                )
                if window?.firstResponder !== editor {
                    _ = window?.makeFirstResponder(editor)
                }
                editor.paste(sender)
                return
            }

            guard let surface = self.surface else { return }
            let action = "paste_from_clipboard"
            if (!ghostty_surface_binding_action(surface, action, UInt(action.lengthOfBytes(using: .utf8)))) {
                AppDelegate.logger.warning("action failed action=\(action)")
            }
        }


        @IBAction func pasteAsPlainText(_ sender: Any?) {
            guard let surface = self.surface else { return }
            let action = "paste_from_clipboard"
            if (!ghostty_surface_binding_action(surface, action, UInt(action.lengthOfBytes(using: .utf8)))) {
                AppDelegate.logger.warning("action failed action=\(action)")
            }
        }

        @IBAction func pasteSelection(_ sender: Any?) {
            guard let surface = self.surface else { return }
            let action = "paste_from_selection"
            if (!ghostty_surface_binding_action(surface, action, UInt(action.lengthOfBytes(using: .utf8)))) {
                AppDelegate.logger.warning("action failed action=\(action)")
            }
        }

        @IBAction override func selectAll(_ sender: Any?) {
            if composeOriginalText != nil,
               !composeTerminalSelectionMode,
               let editor = composeEditor,
               !editor.isHidden
            {
                composeTrace("clipboard action=select_all draft_len=\(editor.string.count)")
                if window?.firstResponder !== editor {
                    _ = window?.makeFirstResponder(editor)
                }
                editor.selectAll(sender)
                return
            }

            guard let surface = self.surface else { return }
            let action = "select_all"
            if (!ghostty_surface_binding_action(surface, action, UInt(action.lengthOfBytes(using: .utf8)))) {
                AppDelegate.logger.warning("action failed action=\(action)")
            }
        }

        @IBAction func find(_ sender: Any?) {
            guard let surface = self.surface else { return }
            let action = "start_search"
            if (!ghostty_surface_binding_action(surface, action, UInt(action.lengthOfBytes(using: .utf8)))) {
                AppDelegate.logger.warning("action failed action=\(action)")
            }
        }

        @IBAction func selectionForFind(_ sender: Any?) {
            guard let surface = self.surface else { return }
            let action = "search_selection"
            if (!ghostty_surface_binding_action(surface, action, UInt(action.lengthOfBytes(using: .utf8)))) {
                AppDelegate.logger.warning("action failed action=\(action)")
            }
        }

        @IBAction func scrollToSelection(_ sender: Any?) {
            guard let surface = self.surface else { return }
            let action = "scroll_to_selection"
            if (!ghostty_surface_binding_action(surface, action, UInt(action.lengthOfBytes(using: .utf8)))) {
                AppDelegate.logger.warning("action failed action=\(action)")
            }
        }

        @IBAction func findNext(_ sender: Any?) {
            guard let surface = self.surface else { return }
            let action = "search:next"
            if (!ghostty_surface_binding_action(surface, action, UInt(action.lengthOfBytes(using: .utf8)))) {
                AppDelegate.logger.warning("action failed action=\(action)")
            }
        }

        @IBAction func findPrevious(_ sender: Any?) {
            guard let surface = self.surface else { return }
            let action = "search:previous"
            if (!ghostty_surface_binding_action(surface, action, UInt(action.lengthOfBytes(using: .utf8)))) {
                AppDelegate.logger.warning("action failed action=\(action)")
            }
        }

        @IBAction func findHide(_ sender: Any?) {
            guard let surface = self.surface else { return }
            let action = "end_search"
            if (!ghostty_surface_binding_action(surface, action, UInt(action.lengthOfBytes(using: .utf8)))) {
                AppDelegate.logger.warning("action failed action=\(action)")
            }
        }

        @IBAction func toggleReadonly(_ sender: Any?) {
            guard let surface = self.surface else { return }
            let action = "toggle_readonly"
            if (!ghostty_surface_binding_action(surface, action, UInt(action.lengthOfBytes(using: .utf8)))) {
                AppDelegate.logger.warning("action failed action=\(action)")
            }
        }

        /// Triggers a brief highlight animation on this surface.
        func highlight() {
            highlighted = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
                self?.highlighted = false
            }
        }

        @IBAction func splitRight(_ sender: Any) {
            guard let surface = self.surface else { return }
            ghostty_surface_split(surface, GHOSTTY_SPLIT_DIRECTION_RIGHT)
        }

        @IBAction func splitLeft(_ sender: Any) {
            guard let surface = self.surface else { return }
            ghostty_surface_split(surface, GHOSTTY_SPLIT_DIRECTION_LEFT)
        }

        @IBAction func splitDown(_ sender: Any) {
            guard let surface = self.surface else { return }
            ghostty_surface_split(surface, GHOSTTY_SPLIT_DIRECTION_DOWN)
        }

        @IBAction func splitUp(_ sender: Any) {
            guard let surface = self.surface else { return }
            ghostty_surface_split(surface, GHOSTTY_SPLIT_DIRECTION_UP)
        }

        @objc func resetTerminal(_ sender: Any) {
            guard let surface = self.surface else { return }
            let action = "reset"
            if (!ghostty_surface_binding_action(surface, action, UInt(action.lengthOfBytes(using: .utf8)))) {
                AppDelegate.logger.warning("action failed action=\(action)")
            }
        }

        @objc func toggleTerminalInspector(_ sender: Any) {
            guard let surface = self.surface else { return }
            let action = "inspector:toggle"
            if (!ghostty_surface_binding_action(surface, action, UInt(action.lengthOfBytes(using: .utf8)))) {
                AppDelegate.logger.warning("action failed action=\(action)")
            }
        }

        @IBAction func changeTitle(_ sender: Any) {
            promptTitle()
        }

        /// Show a user notification and associate it with this surface
        func showUserNotification(title: String, body: String) {
            let content = UNMutableNotificationContent()
            content.title = title
            content.subtitle = self.title
            content.body = body
            content.sound = UNNotificationSound.default
            content.categoryIdentifier = JTerm.userNotificationCategory
            content.userInfo = ["surface": self.id.uuidString]

            let uuid = UUID().uuidString
            let request = UNNotificationRequest(
                identifier: uuid,
                content: content,
                trigger: nil
            )

            // Note the callback may be executed on a background thread as documented
            // so we need @MainActor since we're reading/writing view state.
            UNUserNotificationCenter.current().add(request) { @MainActor error in
                if let error = error {
                    AppDelegate.logger.error("Error scheduling user notification: \(error)")
                    return
                }

                // We need to keep track of this notification so we can remove it
                // under certain circumstances
                self.notificationIdentifiers.insert(uuid)

                // If we're focused then we schedule to remove the notification
                // after a few seconds. If we gain focus we automatically remove it
                // in focusDidChange.
                if (self.focused) {
                    Task { @MainActor [weak self] in
                        try await Task.sleep(for: .seconds(3))
                        self?.notificationIdentifiers.remove(uuid)
                        UNUserNotificationCenter.current()
                            .removeDeliveredNotifications(withIdentifiers: [uuid])
                    }
                }
            }
        }

        /// Handle a user notification click
        func handleUserNotification(notification: UNNotification, focus: Bool) {
            let id = notification.request.identifier
            guard self.notificationIdentifiers.remove(id) != nil else { return }
            if focus {
                self.window?.makeKeyAndOrderFront(self)
                JTerm.moveFocus(to: self)
            }
        }

        struct DerivedConfig {
            let backgroundColor: Color
            let backgroundOpacity: Double
            let backgroundBlur: JTerm.Config.BackgroundBlur
            let macosWindowShadow: Bool
            let windowTitleFontFamily: String?
            let windowAppearance: NSAppearance?
            let scrollbar: JTerm.Config.Scrollbar

            init() {
                self.backgroundColor = Color(NSColor.windowBackgroundColor)
                self.backgroundOpacity = 1
                self.backgroundBlur = .disabled
                self.macosWindowShadow = true
                self.windowTitleFontFamily = nil
                self.windowAppearance = nil
                self.scrollbar = .system
            }

            init(_ config: JTerm.Config) {
                self.backgroundColor = config.backgroundColor
                self.backgroundOpacity = config.backgroundOpacity
                self.backgroundBlur = config.backgroundBlur
                self.macosWindowShadow = config.macosWindowShadow
                self.windowTitleFontFamily = config.windowTitleFontFamily
                self.windowAppearance = .init(ghosttyConfig: config)
                self.scrollbar = config.scrollbar
            }
        }

        // MARK: - Codable

        enum CodingKeys: String, CodingKey {
            case pwd
            case uuid
            case title
            case isUserSetTitle
        }

        required convenience init(from decoder: Decoder) throws {
            // Decoding uses the global JTerm app
            guard let del = NSApplication.shared.delegate,
                  let appDel = del as? AppDelegate,
                  let app = appDel.ghostty.app else {
                throw TerminalRestoreError.delegateInvalid
            }

            let container = try decoder.container(keyedBy: CodingKeys.self)
            let uuid = UUID(uuidString: try container.decode(String.self, forKey: .uuid))
            var config = JTerm.SurfaceConfiguration()
            config.workingDirectory = try container.decode(String?.self, forKey: .pwd)
            let savedTitle = try container.decodeIfPresent(String.self, forKey: .title)
            let isUserSetTitle = try container.decodeIfPresent(Bool.self, forKey: .isUserSetTitle) ?? false

            self.init(app, baseConfig: config, uuid: uuid)

            // Restore the saved title after initialization
            if let title = savedTitle {
                self.title = title
                // If this was a user-set title, we need to prevent it from being overwritten
                if isUserSetTitle {
                    self.titleFromTerminal = title
                }
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(pwd, forKey: .pwd)
            try container.encode(id.uuidString, forKey: .uuid)
            try container.encode(title, forKey: .title)
            try container.encode(titleFromTerminal != nil, forKey: .isUserSetTitle)
        }
    }
}

// MARK: - NSTextInputClient

extension JTerm.SurfaceView: NSTextInputClient {
    func hasMarkedText() -> Bool {
        return markedText.length > 0
    }

    func markedRange() -> NSRange {
        guard markedText.length > 0 else { return NSRange() }
        return NSRange(0...(markedText.length-1))
    }

    func selectedRange() -> NSRange {
        guard let surface = self.surface else { return NSRange() }

        // Get our range from the JTerm API. There is a race condition between getting the
        // range and actually using it since our selection may change but there isn't a good
        // way I can think of to solve this for AppKit.
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return NSRange() }
        defer { ghostty_surface_free_text(surface, &text) }
        return NSRange(location: Int(text.offset_start), length: Int(text.offset_len))
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
        if composeOriginalText != nil {
            clearTerminalPreedit()
            return
        }

        switch string {
        case let v as NSAttributedString:
            self.markedText = NSMutableAttributedString(attributedString: v)

        case let v as String:
            self.markedText = NSMutableAttributedString(string: v)

        default:
            print("unknown marked text: \(string)")
        }

        // If we're not in a keyDown event, then we want to update our preedit
        // text immediately. This can happen due to external events, for example
        // changing keyboard layouts while composing: (1) set US intl (2) type '
        // to enter dead key state (3)
        if keyTextAccumulator == nil {
            syncPreedit()
        }
    }

    func unmarkText() {
        if composeOriginalText != nil {
            clearTerminalPreedit()
            return
        }

        if self.markedText.length > 0 {
            self.markedText.mutableString.setString("")
            syncPreedit()
        }
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        return []
    }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        // JTerm.logger.warning("pressure substring range=\(range) selectedRange=\(self.selectedRange())")
        guard let surface = self.surface else { return nil }

        // If the range is empty then we don't need to return anything
        guard range.length > 0 else { return nil }

        // I used to do a bunch of testing here that the range requested matches the
        // selection range or contains it but a lot of macOS system behaviors request
        // bogus ranges I truly don't understand so we just always return the
        // attributed string containing our selection which is... weird but works?

        // Get our selection text
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }

        // If we can get a font then we use the font. This should always work
        // since we always have a primary font. The only scenario this doesn't
        // work is if someone is using a non-CoreText build which would be
        // unofficial.
        var attributes: [ NSAttributedString.Key : Any ] = [:];
        if let fontRaw = ghostty_surface_quicklook_font(surface) {
            // Memory management here is wonky: ghostty_surface_quicklook_font
            // will create a copy of a CTFont, Swift will auto-retain the
            // unretained value passed into the dict, so we release the original.
            let font = Unmanaged<CTFont>.fromOpaque(fontRaw)
            attributes[.font] = font.takeUnretainedValue()
            font.release()
        }

        return .init(string: String(cString: text.text), attributes: attributes)
    }

    func characterIndex(for point: NSPoint) -> Int {
        return 0
    }

    func firstRect(forCharacterRange range: NSRange, actualRange: NSRangePointer?) -> NSRect {
        guard let surface = self.surface else {
            return NSMakeRect(frame.origin.x, frame.origin.y, 0, 0)
        }

        // JTerm will tell us where it thinks an IME keyboard should render.
        var x: Double = 0
        var y: Double = 0
        var width: Double = cellSize.width
        var height: Double = cellSize.height

        // QuickLook never gives us a matching range to our selection so if we detect
        // this then we return the top-left selection point rather than the cursor point.
        // This is hacky but I can't think of a better way to get the right IME vs. QuickLook
        // point right now. I'm sure I'm missing something fundamental...
        if range.length > 0 && range != self.selectedRange() {
            // QuickLook
            var text = ghostty_text_s()
            if ghostty_surface_read_selection(surface, &text) {
                // The -2/+2 here is subjective. QuickLook seems to offset the rectangle
                // a bit and I think these small adjustments make it look more natural.
                x = text.tl_px_x - 2;
                y = text.tl_px_y + 2;

                // Free our text
                ghostty_surface_free_text(surface, &text)
            } else {
                ghostty_surface_ime_point(surface, &x, &y, &width, &height)
            }
        } else {
            ghostty_surface_ime_point(surface, &x, &y, &width, &height)
        }
        if range.length == 0, width > 0 {
            // This fixes #8493 while speaking
            // My guess is that positive width doesn't make sense
            // for the dictation microphone indicator
            width = 0
            x += cellSize.width * Double(range.location + range.length)
        }
        // JTerm coordinates are in top-left (0, 0) so we have to convert to
        // bottom-left since that is what UIKit expects
        // when there's is no characters selected,
        // width should be 0 so that dictation indicator
        // can start in the right place
        let viewRect = NSMakeRect(
            x,
            frame.size.height - y,
            width,
            max(height, cellSize.height))

        // Convert the point to the window coordinates
        let winRect = self.convert(viewRect, to: nil)

        // Convert from view to screen coordinates
        guard let window = self.window else { return winRect }
        return window.convertToScreen(winRect)
    }

    func insertText(_ string: Any, replacementRange: NSRange) {
        // We must have an associated event
        guard NSApp.currentEvent != nil else { return }
        guard let surfaceModel else { return }

        // We want the string view of the any value
        var chars = ""
        switch (string) {
        case let v as NSAttributedString:
            chars = v.string
        case let v as String:
            chars = v
        default:
            return
        }

        // If insertText is called, our preedit must be over.
        unmarkText()

        // If we have an accumulator we're in another key event so we just
        // accumulate and return.
        if var acc = keyTextAccumulator {
            acc.append(chars)
            keyTextAccumulator = acc
            return
        }

        surfaceModel.sendText(chars)
    }

    /// This function needs to exist for two reasons:
    /// 1. Prevents an audible NSBeep for unimplemented actions.
    /// 2. Allows us to properly encode super+key input events that we don't handle
    override func doCommand(by selector: Selector) {
        // If we are being processed by performKeyEquivalent with a command binding,
        // we send it back through the event system so it can be encoded.
        if let lastPerformKeyEvent,
           let current = NSApp.currentEvent,
           lastPerformKeyEvent == current.timestamp
        {
            NSApp.sendEvent(current)
            return
        }

		guard let surfaceModel else { return }
        // Process MacOS native scroll events
        switch selector {
        case #selector(moveToBeginningOfDocument(_:)):
            _ = surfaceModel.perform(action: "scroll_to_top")
        case #selector(moveToEndOfDocument(_:)):
            _ = surfaceModel.perform(action: "scroll_to_bottom")
        default:
            break
        }

        print("SEL: \(selector)")
    }

    /// Sync the preedit state based on the markedText value to libghostty
    private func syncPreedit(clearIfNeeded: Bool = true) {
        guard let surface else { return }

        if markedText.length > 0 {
            let str = markedText.string
            let len = str.utf8CString.count
            if len > 0 {
                markedText.string.withCString { ptr in
                    // Subtract 1 for the null terminator
                    ghostty_surface_preedit(surface, ptr, UInt(len - 1))
                }
            }
        } else if clearIfNeeded {
            // If we had marked text before but don't now, we're no longer
            // in a preedit state so we can clear it.
            ghostty_surface_preedit(surface, nil, 0)
        }
    }
}

// MARK: Services

// https://developer.apple.com/library/archive/documentation/Cocoa/Conceptual/SysServices/Articles/using.html
extension JTerm.SurfaceView: NSServicesMenuRequestor {
    override func validRequestor(
        forSendType sendType: NSPasteboard.PasteboardType?,
        returnType: NSPasteboard.PasteboardType?
    ) -> Any? {
        // This function confused me a bit so I'm going to add my own commentary on
        // how this works. macOS sends this callback with the given send/return types and
        // we must return the responder capable of handling the COMBINATION of those send
        // and return types (or super up if we can't handle it).
        //
        // The "COMBINATION" bit is key: we might get sent a string (we can handle that)
        // but get requested an image (we can't handle that at the time of writing this),
        // so we must bubble up.

        // Types we can receive
        let receivable: [NSPasteboard.PasteboardType] = [.string, .init("public.utf8-plain-text")]

        // Types that we can send. Currently the same as receivable but I'm separating
        // this out so we can modify this in the future.
        let sendable: [NSPasteboard.PasteboardType] = receivable

        // The sendable types that require a selection (currently all)
        let sendableRequiresSelection = sendable

        // If we expect no data to be sent/received we can obviously handle it (that's
        // the nil check), otherwise it must conform to the types we support on both sides.
        if (returnType == nil || receivable.contains(returnType!)) &&
            (sendType == nil || sendable.contains(sendType!)) {
            // If we're expected to send back a type that requires selection, then
            // verify that we have a selection. We do this within this block because
            // validateRequestor is called a LOT and we want to prevent unnecessary
            // performance hits because `ghostty_surface_has_selection` isn't free.
            if let sendType, sendableRequiresSelection.contains(sendType) {
                if surface == nil || !ghostty_surface_has_selection(surface) {
                    return super.validRequestor(forSendType: sendType, returnType: returnType)
                }
            }

            return self
        }

        return super.validRequestor(forSendType: sendType, returnType: returnType)
    }

    func writeSelection(
        to pboard: NSPasteboard,
        types: [NSPasteboard.PasteboardType]
    ) -> Bool {
        guard let surface = self.surface else { return false }

        // Read the selection
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return false }
        defer { ghostty_surface_free_text(surface, &text) }

        pboard.declareTypes([.string], owner: nil)
        pboard.setString(String(cString: text.text), forType: .string)
        return true
    }

    func readSelection(from pboard: NSPasteboard) -> Bool {
        guard let str = pboard.getOpinionatedStringContents() else { return false }

        let len = str.utf8CString.count
        if (len == 0) { return true }
        str.withCString { ptr in
            // len includes the null terminator so we do len - 1
            ghostty_surface_text(surface, ptr, UInt(len - 1))
        }

        return true
    }
}

// MARK: NSMenuItemValidation

extension JTerm.SurfaceView: NSMenuItemValidation {
    func validateMenuItem(_ item: NSMenuItem) -> Bool {
        switch item.action {
        case #selector(pasteSelection):
            let pb = NSPasteboard.ghosttySelection
            guard let str = pb.getOpinionatedStringContents() else { return false }
            return !str.isEmpty

        case #selector(findHide):
            return searchState != nil

        case #selector(toggleReadonly):
            item.state = readonly ? .on : .off
            return true

        default:
            return true
        }
    }
}

// MARK: - Native Compose Editor

extension JTerm.SurfaceView: NSTextViewDelegate {
    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard textView === composeEditor else { return false }

        let currentEvent = NSApp.currentEvent
        let mods = currentEvent.map(composeRelevantModifierFlags(for:)) ?? []
        let keyCode = currentEvent.map { String($0.keyCode) } ?? "nil"
        composeTrace(
            "compose doCommand selector=\(NSStringFromSelector(commandSelector)) keyCode=\(keyCode) mods=\(mods.rawValue)"
        )

        switch commandSelector {
        case #selector(insertLineBreak(_:)),
             #selector(insertNewlineIgnoringFieldEditor(_:)):
            return handleComposeStructuralNewline(
                editor: textView,
                reason: NSStringFromSelector(commandSelector)
            )

        case #selector(insertNewline(_:)):
            if mods == [.shift] {
                return handleComposeStructuralNewline(
                    editor: textView,
                    reason: "insertNewline+shift"
                )
            }
            finishCompose(.commit)
            return true

        case #selector(cancelOperation(_:)):
            finishCompose(.cancel)
            return true

        default:
            return false
        }
    }

    func textDidChange(_ notification: Notification) {
        guard !composeEnding else { return }
        guard !composeSuppressSync else { return }
        guard let textView = notification.object as? NSTextView else { return }
        guard textView === composeEditor else { return }
        guard composeOriginalText != nil else { return }

        clearTerminalPreedit()
        var draft = textView.string
        var cursor = min(max(0, textView.selectedRange().location), draft.utf16.count)
        let materialized = materializeComposeVirtualTrailingGapIfNeeded(
            editor: textView,
            draft: draft,
            cursor: cursor
        )
        draft = materialized.draft
        cursor = materialized.cursor

        composeSuppressSync = true
        normalizeComposeEditorTextAttributes(textView)
        textView.markedTextAttributes = [
            .foregroundColor: composeForegroundColor,
            .backgroundColor: NSColor.clear,
            .underlineStyle: 0,
        ]
        composeSuppressSync = false

        let marked = textView.markedRange()
        let termSelection = surface.map { ghostty_surface_has_selection($0) } ?? false
        composeTrace(
            "textDidChange draft_len=\(draft.count) cursor=\(cursor) marked_loc=\(marked.location) marked_len=\(marked.length) term_sel=\(termSelection)"
        )
        traceComposeEditorUnderlineState(textView, source: "textDidChange")
        if composeShouldLiveSync() {
            syncTerminalLine(
                from: composeTerminalText,
                cursor: composeTerminalCursor,
                to: draft,
                cursor: cursor
            )
            composeTerminalText = draft
            composeTerminalCursor = cursor
        } else if composeActivationContext == .claudeTui {
            let desiredStructuralNewlines = composeDesiredClaudeStructuralNewlineCount(
                editor: textView,
                draft: draft
            )
            syncClaudeStructuralNewlines(to: desiredStructuralNewlines)
            composeLocalDraftDirty = true
            composeTrace(
                "compose multiline local-only draft_len=\(draft.count) cursor=\(cursor) structural_desired=\(desiredStructuralNewlines)"
            )
        } else {
            composeLocalDraftDirty = true
        }
        composeSyncedText = draft
        composeSyncedCursor = cursor

        // Ensure any stale insertion-point paint is cleared after text edits.
        let layoutSnapshot = composeSnapshotForCursorRow()
        applyComposeEditorLayout(
            editor: textView,
            snapshot: layoutSnapshot,
            resetCaret: true
        )
        maybeRecordComposeLatency()
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard !composeEnding else { return }
        guard !composeSuppressSync else { return }
        guard let textView = notification.object as? NSTextView else { return }
        guard textView === composeEditor else { return }
        guard composeOriginalText != nil else { return }

        let selection = textView.selectedRange()
        let end = textView.string.utf16.count
        if composeVirtualTrailingGapPending,
           (selection.length != 0 || selection.location < end)
        {
            composeVirtualTrailingGapPending = false
            composeTrace(
                "compose trailing gap cleared reason=selection location=\(selection.location) length=\(selection.length) end=\(end)"
            )
        }
        let cursor = min(max(0, selection.location), composeSyncedText.utf16.count)
        composeTrace("selection location=\(selection.location) length=\(selection.length) synced_cursor=\(composeSyncedCursor)")
        composeSuppressSync = true
        updateComposeSelectionAppearance(textView)
        composeSuppressSync = false
        if selection.length == 0,
           composeActivationContext == .claudeTui,
           composeTerminalText.contains("\n")
        {
            syncTerminalCursor(from: composeTerminalCursor, to: cursor)
            composeTerminalCursor = cursor
        }
        traceComposeEditorUnderlineState(textView, source: "selection")

        // Keep selection paint responsive while dragging.
        textView.needsDisplay = true
        textView.displayIfNeeded()
        refreshComposeCaret(resetBlink: true)
        if isLeftMouseButtonDown() { return }

        guard selection.length == 0 else { return }
        if cursor != composeSyncedCursor {
            if composeShouldLiveSync() {
                syncTerminalCursor(from: composeTerminalCursor, to: cursor)
                composeTerminalCursor = cursor
            }
            composeSyncedCursor = cursor
        }
        maybeRecordComposeLatency()
    }

    func textDidEndEditing(_ notification: Notification) {
        guard !composeEnding else { return }
        guard let textView = notification.object as? NSTextView else { return }
        guard textView === composeEditor else { return }
        guard composeOriginalText != nil else { return }

        let windowIsKey = window?.isKeyWindow ?? false
        let appIsActive = NSApp.isActive
        let inStabilize = Date.timeIntervalSinceReferenceDate < composeStabilizeUntil
        composeTrace(
            "textDidEndEditing compose_active=true window_key=\(windowIsKey) app_active=\(appIsActive) stabilize=\(inStabilize)"
        )

        // NSTextView editing-end notifications can fire during internal responder
        // transitions while compose should remain active.
        if appIsActive && windowIsKey {
            composeTrace("textDidEndEditing ignored active-window")
            return
        }

        if composeShouldPersistAcrossBlur() {
            composeTrace("textDidEndEditing ignored preserve-on-blur")
            return
        }

        composeTrace("finish trigger source=textDidEndEditing")
        finishCompose(.blur)
    }
}

// MARK: NSDraggingDestination

extension JTerm.SurfaceView {
    static let dropTypes: Set<NSPasteboard.PasteboardType> = [
        .string,
        .fileURL,
        .URL
    ]

    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation {
        guard let types = sender.draggingPasteboard.types else { return [] }

        // If the dragging object contains none of our types then we return none.
        // This shouldn't happen because AppKit should guarantee that we only
        // receive types we registered for but its good to check.
        if Set(types).isDisjoint(with: Self.dropTypes) {
            return []
        }

        // We use copy to get the proper icon
        return .copy
    }

    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let pb = sender.draggingPasteboard

        let content: String?
        if let url = pb.string(forType: .URL) {
            // URLs first, they get escaped as-is.
            content = JTerm.Shell.escape(url)
        } else if let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL],
           urls.count > 0 {
            // File URLs next. They get escaped individually and then joined by a
            // space if there are multiple.
            content = urls
                .map { JTerm.Shell.escape($0.path) }
                .joined(separator: " ")
        } else if let str = pb.string(forType: .string) {
            // Strings are not escaped because they may be copy/pasting a
            // command they want to execute.
            content = str
        } else {
            content = nil
        }

        if let content {
            DispatchQueue.main.async {
                self.insertText(
                    content,
                    replacementRange: NSMakeRange(0, 0)
                )
            }
            return true
        }

        return false
    }
}

// MARK: Accessibility

extension JTerm.SurfaceView {
    /// Indicates that this view should be exposed to accessibility tools like VoiceOver.
    /// By returning true, we make the terminal surface accessible to screen readers
    /// and other assistive technologies.
    override func isAccessibilityElement() -> Bool {
         return true
     }

    /// Defines the accessibility role for this view, which helps assistive technologies
    /// understand what kind of content this view contains and how users can interact with it.
    override func accessibilityRole() -> NSAccessibility.Role? {
        /// We use .textArea because the terminal surface is essentially an editable text area
        /// where users can input commands and view output.
        return .textArea
    }

    override func accessibilityHelp() -> String? {
        return "Terminal content area"
    }

    override func accessibilityValue() -> Any? {
        return cachedScreenContents.get()
    }

    /// Returns the range of text that is currently selected in the terminal.
    /// This allows VoiceOver and other assistive technologies to understand
    /// what text the user has selected.
    override func accessibilitySelectedTextRange() -> NSRange {
        return selectedRange()
    }

    /// Returns the currently selected text as a string.
    /// This allows assistive technologies to read the selected content.
    override func accessibilitySelectedText() -> String? {
        guard let surface = self.surface else { return nil }

        // Attempt to read the selection
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return nil }
        defer { ghostty_surface_free_text(surface, &text) }

        let str = String(cString: text.text)
        return str.isEmpty ? nil : str
    }

    /// Returns the number of characters in the terminal content.
    /// This helps assistive technologies understand the size of the content.
    override func accessibilityNumberOfCharacters() -> Int {
        let content = cachedScreenContents.get()
        return content.count
    }

    /// Returns the visible character range for the terminal.
    /// For terminals, we typically show all content as visible.
    override func accessibilityVisibleCharacterRange() -> NSRange {
        let content = cachedScreenContents.get()
        return NSRange(location: 0, length: content.count)
    }

    /// Returns the line number for a given character index.
    /// This helps assistive technologies navigate by line.
    override func accessibilityLine(for index: Int) -> Int {
        let content = cachedScreenContents.get()
        let substring = String(content.prefix(index))
        return substring.components(separatedBy: .newlines).count - 1
    }

    /// Returns a substring for the given range.
    /// This allows assistive technologies to read specific portions of the content.
    override func accessibilityString(for range: NSRange) -> String? {
        let content = cachedScreenContents.get()
        guard let swiftRange = Range(range, in: content) else { return nil }
        return String(content[swiftRange])
    }

    /// Returns an attributed string for the given range.
    ///
    /// Note: right now this only applies font information. One day it'd be nice to extend
    /// this to copy styling information as well but we need to augment JTerm core to
    /// expose that.
    ///
    /// This provides styling information to assistive technologies.
    override func accessibilityAttributedString(for range: NSRange) -> NSAttributedString? {
        guard let surface = self.surface else { return nil }
        guard let plainString = accessibilityString(for: range) else { return nil }

        var attributes: [NSAttributedString.Key: Any] = [:]

        // Try to get the font from the surface
        if let fontRaw = ghostty_surface_quicklook_font(surface) {
            let font = Unmanaged<CTFont>.fromOpaque(fontRaw)
            attributes[.font] = font.takeUnretainedValue()
            font.release()
        }

        return NSAttributedString(string: plainString, attributes: attributes)
    }

}

/// Caches a value for some period of time, evicting it automatically when that time expires.
/// We use this to cache our surface content. This probably should be extracted some day
/// to a more generic helper.
class CachedValue<T> {
    private var value: T?
    private let fetch: () -> T
    private let duration: Duration
    private var expiryTask: Task<Void, Never>?

    init(duration: Duration, fetch: @escaping () -> T) {
        self.duration = duration
        self.fetch = fetch
    }

    deinit {
        expiryTask?.cancel()
    }

    func get() -> T {
        if let value {
            return value
        }

        // We don't have a value (or it expired). Fetch and store.
        let result = fetch()
        let now = ContinuousClock.now
        let expires = now + duration
        self.value = result

        // Schedule a task to clear the value
        expiryTask = Task { [weak self] in
            do {
                try await Task.sleep(until: expires)
                self?.value = nil
                self?.expiryTask = nil
            } catch {
                // Task was cancelled, do nothing
            }
        }

        return result
    }
}
