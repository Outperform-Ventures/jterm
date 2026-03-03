import AppKit
import Combine
import SwiftUI
import CoreText
import UserNotifications
import GhosttyKit

extension Ghostty {
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

        /// The configuration derived from the Ghostty config so we don't need to rely on references.
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
        // detected with the set_password_input_cb on the Ghostty state.
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
        var inspector: Ghostty.Inspector? {
            guard let surface = self.surface else { return nil }
            guard let cInspector = ghostty_surface_inspector(surface) else { return nil }
            return Ghostty.Inspector(cInspector: cInspector)
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
        private(set) var surfaceModel: Ghostty.Surface?

        /// Returns the underlying C value for the surface. See "note" on surfaceModel.
        var surface: ghostty_surface_t? {
            surfaceModel?.unsafeCValue
        }
        /// Current scrollbar state, cached here for persistence across rebuilds
        /// of the SwiftUI view hierarchy, for example when changing splits
        var scrollbar: Ghostty.Action.Scrollbar?

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

        /// Text view used for native compose editing with a thin word-processor style caret.
        private final class ComposeTextView: NSTextView {
            var onCommit: (() -> Void)?
            var onCancel: (() -> Void)?
            var onTab: (() -> Void)?
            var caretColor: NSColor = .white
            var caretWidth: CGFloat = 1

            override func keyDown(with event: NSEvent) {
                switch event.keyCode {
                case 36, 76: // Return / Keypad Enter
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
                // Keep text/caret invisible via attributes, but allow AppKit to draw
                // selection highlight so selected ranges are visible to the user.
                super.draw(dirtyRect)
            }

            override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn flag: Bool) {
                guard flag else { return }
                var caret = rect
                caret.origin.x = floor(caret.origin.x) + 0.5
                caret.size.width = max(1, caretWidth)
                if caret.size.height <= 0 {
                    caret.size.height = max(1, bounds.height)
                }
                caretColor.setFill()
                caret.fill()
            }
        }

        /// Invisible native compose editor. This is shown only while editing input in-place.
        private var composeEditor: ComposeTextView?
        private var composeOriginalText: String? = nil
        private var composeEnding: Bool = false
        private var composeSyncedText: String = ""
        private var composeSyncedCursor: Int = 0
        private var composeSuppressSync: Bool = false
        private var composeSelectionAnchor: Int? = nil
        private var composeForegroundColor: NSColor = .labelColor
        private var composeBackgroundColor: NSColor = .black
        private var composeAutoActivateTimer: Timer? = nil
        private var composeAutoActivateAttempts: Int = 0
        private static let composeAutoActivateMaxAttempts: Int = 8
        private var composeResponderHandoff: Bool = false
        private var composeTerminalCursorHidden: Bool = false
        private var composeStabilizeUntil: TimeInterval = 0
        private static let composeLogPath = "/tmp/jterm-compose-events.log"

        private var surfaceContentHeight: CGFloat {
            max(1, contentSize.height)
        }

        private var surfaceContentWidth: CGFloat {
            max(1, contentSize.width)
        }

        private func composeTrace(_ message: String) {
            let line = "[compose][pid:\(ProcessInfo.processInfo.processIdentifier)] \(message)\n"
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

        private func resetComposeState(reason: String) {
            composeTrace("reset state reason=\(reason)")
            composeOriginalText = nil
            composeEnding = false
            composeSyncedText = ""
            composeSyncedCursor = 0
            composeSelectionAnchor = nil
            composeSuppressSync = false
            setTerminalCursorHidden(false)
            if let editor = composeEditor {
                editor.isHidden = true
            }
            if window?.firstResponder === composeEditor {
                _ = window?.makeFirstResponder(self)
            }
        }

        private func stopComposeAutoActivateTimer() {
            composeAutoActivateTimer?.invalidate()
            composeAutoActivateTimer = nil
        }

        private func startComposeAutoActivateTimer(reason: String) {
            _ = reason
            // Disabled for stability. Compose activates on explicit click.
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
            if let semantic = semanticPromptInputSnapshot() {
                snapshot = semantic
            } else if let cursorPoint = cursorClickPointInView() {
                snapshot = fallbackPromptInputSnapshot(
                    clickPoint: cursorPoint,
                    requirePromptMarker: true
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

        private func setTerminalCursorHidden(_ hidden: Bool) {
            guard composeTerminalCursorHidden != hidden else { return }
            composeTerminalCursorHidden = hidden
            guard let surface else { return }
            ghostty_surface_set_cursor_visible(surface, !hidden)
            composeTrace("terminal cursor hidden=\(hidden)")
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

            // Set a timer to show the default fallback title after 500ms if no title is set
            titleFallbackTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: false) { [weak self] _ in
                if let self = self, self.title.isEmpty {
                    self.title = "⚡"
                }
            }

            // Before we initialize the surface we want to register our notifications
            // so there is no window where we can't receive them.
            let center = NotificationCenter.default
            center.addObserver(
                self,
                selector: #selector(onUpdateRendererHealth),
                name: Ghostty.Notification.didUpdateRendererHealth,
                object: self)
            center.addObserver(
                self,
                selector: #selector(ghosttyDidContinueKeySequence),
                name: Ghostty.Notification.didContinueKeySequence,
                object: self)
            center.addObserver(
                self,
                selector: #selector(ghosttyDidEndKeySequence),
                name: Ghostty.Notification.didEndKeySequence,
                object: self)
            center.addObserver(
                self,
                selector: #selector(ghosttyDidChangeKeyTable),
                name: Ghostty.Notification.didChangeKeyTable,
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
                self.error = Ghostty.Error.apiFailed
                return
            }
            self.surfaceModel = Ghostty.Surface(cSurface: surface)

            // Setup our tracking area so we get mouse moved events
            updateTrackingAreas()

            // The UTTypes that can be dragged onto this view.
            registerForDraggedTypes(Array(Self.dropTypes))

            composeTrace("surface init id=\(id.uuidString)")
            DispatchQueue.main.async { [weak self] in
                self?.composeAutoActivateAttempts = 0
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
            setTerminalCursorHidden(false)

            composeEditor?.removeFromSuperview()
            composeEditor = nil
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
                    composeTrace("finish trigger source=focusDidChange")
                    finishCompose(.blur)
                }
            }

            self.focused = focused
            ghostty_surface_set_focus(surface, focused)
            if !focused {
                stopComposeAutoActivateTimer()
                setTerminalCursorHidden(false)
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
            }
        }

        func sizeDidChange(_ size: CGSize) {
            if composeOriginalText != nil,
               let editor = composeEditor,
               !editor.isHidden
            {
                if let snapshot = semanticPromptInputSnapshot() {
                    editor.frame = promptInputFrame(snapshot)
                } else if let cursorPoint = cursorClickPointInView(),
                          let snapshot = cursorOnlyPromptInputSnapshot(clickPoint: cursorPoint)
                {
                    editor.frame = promptInputFrame(snapshot)
                }
            }

            // Ghostty wants to know the actual framebuffer size... It is very important
            // here that we use "size" and NOT the view frame. If we're in the middle of
            // an animation (i.e. a fullscreen animation), the frame will not yet be updated.
            // The size represents our final size we're going for.
            let scaledSize = self.convertToBacking(size)
            setSurfaceSize(width: UInt32(scaledSize.width), height: UInt32(scaledSize.height))
            // Store this size so we can reuse it when backing properties change
            contentSize = size
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
                    let prevTitle = titleFromTerminal ?? "⚡"
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

        private func localEventHandler(_ event: NSEvent) -> NSEvent? {
            if event.type == .keyUp {
                composeTrace("local keyUp keyCode=\(event.keyCode) compose_active=\(composeOriginalText != nil)")
            }
            return switch event.type {
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

        private func localEventLeftMouseDown(_ event: NSEvent) -> NSEvent? {
            guard let window, event.windowNumber == window.windowNumber else { return event }
            let point = convert(event.locationInWindow, from: nil)
            composeTrace(
                "local down x=\(point.x) y=\(point.y) clickCount=\(event.clickCount) compose_active=\(composeOriginalText != nil)"
            )
            return event
        }

        private func localEventLeftMouseDragged(_ event: NSEvent) -> NSEvent? {
            guard composeOriginalText != nil else { return event }
            guard let window, event.windowNumber == window.windowNumber else { return event }
            let point = convert(event.locationInWindow, from: nil)
            let anchor = composeSelectionAnchor.map(String.init) ?? "nil"
            composeTrace("local drag x=\(point.x) y=\(point.y) anchor=\(anchor)")
            return event
        }

        private func localEventLeftMouseUp(_ event: NSEvent) -> NSEvent? {
            guard composeOriginalText != nil else { return event }
            guard let window, event.windowNumber == window.windowNumber else { return event }
            let point = convert(event.locationInWindow, from: nil)
            let anchor = composeSelectionAnchor.map(String.init) ?? "nil"
            composeTrace("local up x=\(point.x) y=\(point.y) anchor=\(anchor)")
            return event
        }

        private func localEventMouseMoved(_ event: NSEvent) -> NSEvent? {
            guard composeOriginalText != nil else { return event }
            guard let window, event.windowNumber == window.windowNumber else { return event }
            let point = convert(event.locationInWindow, from: nil)
            let dragging = isLeftMouseButtonDown()
            let anchor = composeSelectionAnchor.map(String.init) ?? "nil"
            composeTrace("local moved x=\(point.x) y=\(point.y) dragging=\(dragging) anchor=\(anchor)")
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

        private static let composePromptMarkers: [String] = [
            "❯ ",
            "› ",
            "> ",
            "$ ",
            "% ",
            "# ",
            "λ ",
            "➜ ",
            "→ ",
        ]
        private static let composePromptLineStartMarkers: [String] = [
            "❯",
            "›",
            ">",
            "$",
            "%",
            "#",
            "λ",
            "➜",
            "→",
        ]
        // Cursor-row detection can be off by one terminal row in some TUIs
        // (notably Claude Code) due to cursor geometry rounding. Keep this
        // tight (1 row) and rely on composeSnapshotMatchesClickY for final gating.
        private static let composeRowMatchTolerance: Int = 1
        private static let composeLooseRowTolerance: Int = 3

        private func composeSnapshotMatchesClickY(
            _ snapshot: PromptInputSnapshot,
            clickPoint: NSPoint,
            extraRowTolerance: Int = 0
        ) -> Bool {
            let frame = promptInputFrame(snapshot)
            let toleranceY = max(2, cellSize.height * 0.2)
            let rowToleranceY = CGFloat(max(0, extraRowTolerance)) * cellSize.height
            let yDistance = abs(clickPoint.y - frame.midY)
            return yDistance <= (frame.height * 0.5 + toleranceY + rowToleranceY)
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
                if ch == " " || ch == "\t" {
                    end = prev
                } else {
                    break
                }
            }

            return String(value[..<end])
        }

        private func heuristicInputStartColumn(line: String, cursorColumn: Int) -> (column: Int, markerFound: Bool) {
            guard !line.isEmpty else { return (0, false) }
            let cursorBound = min(max(0, cursorColumn), line.count)
            let prefix = String(line.prefix(cursorBound))

            var best = 0
            var found = false
            for marker in Self.composePromptMarkers {
                guard let range = prefix.range(of: marker, options: .backwards) else {
                    continue
                }
                let idx = prefix.distance(from: prefix.startIndex, to: range.upperBound)
                if idx > best {
                    best = idx
                }
                found = true
            }

            return (best, found)
        }

        private func lineStartPromptInputColumn(line: String) -> Int? {
            guard !line.isEmpty else { return nil }

            var idx = line.startIndex
            while idx < line.endIndex {
                let ch = line[idx]
                if ch == " " || ch == "\t" {
                    idx = line.index(after: idx)
                    continue
                }
                break
            }
            let prefixLen = line.distance(from: line.startIndex, to: idx)
            let tail = String(line[idx...])

            for marker in Self.composePromptLineStartMarkers {
                guard tail.hasPrefix(marker) else { continue }
                var start = prefixLen + marker.count
                if start < line.count {
                    let markerEnd = line.index(line.startIndex, offsetBy: start)
                    if markerEnd < line.endIndex && line[markerEnd] == " " {
                        start += 1
                    }
                }
                return start
            }

            return nil
        }

        private func genericLinePromptStartColumn(line: String) -> Int? {
            guard !line.isEmpty else { return nil }

            var idx = line.startIndex
            while idx < line.endIndex {
                let ch = line[idx]
                if ch == " " || ch == "\t" {
                    idx = line.index(after: idx)
                    continue
                }
                break
            }
            guard idx < line.endIndex else { return nil }
            let prefixLen = line.distance(from: line.startIndex, to: idx)

            // Generic TUI prompt detector:
            // If the first visible character is punctuation/symbol and is followed
            // by whitespace, treat it as a prompt marker and start after it.
            let first = line[idx]
            let nextIdx = line.index(after: idx)
            guard nextIdx < line.endIndex else { return nil }
            let next = line[nextIdx]
            guard next == " " || next == "\t" else { return nil }
            guard let scalar = first.unicodeScalars.first else { return nil }
            if CharacterSet.alphanumerics.contains(scalar) {
                return nil
            }

            var start = prefixLen + 1
            if next == " " {
                start += 1
            }
            return start
        }

        private func markerAnywherePromptInputColumn(line: String) -> Int? {
            guard !line.isEmpty else { return nil }
            let heuristic = heuristicInputStartColumn(line: line, cursorColumn: line.count)
            guard heuristic.markerFound else { return nil }
            return heuristic.column
        }

        private func looseLinePromptStartColumn(
            line: String,
            clickColumn: Int
        ) -> Int? {
            guard !line.isEmpty else { return nil }
            let boundedClick = min(max(0, clickColumn), line.count)

            var idx = line.startIndex
            while idx < line.endIndex {
                let ch = line[idx]
                if ch == " " || ch == "\t" {
                    idx = line.index(after: idx)
                    continue
                }
                break
            }

            // Entire row is whitespace: treat prompt as empty at click column.
            guard idx < line.endIndex else { return boundedClick }

            let firstNonWhitespace = line.distance(from: line.startIndex, to: idx)
            guard boundedClick >= firstNonWhitespace else { return nil }
            return firstNonWhitespace
        }

        private func composeLogLinePreview(_ line: String, limit: Int = 80) -> String {
            guard !line.isEmpty else { return "<empty>" }
            var out = ""
            out.reserveCapacity(min(line.count, limit))

            for scalar in line.unicodeScalars {
                if out.count >= limit {
                    out.append("…")
                    break
                }
                switch scalar.value {
                case 0x09:
                    out.append("\\t")
                case 0x0A:
                    out.append("\\n")
                case 0x0D:
                    out.append("\\r")
                case 0x00...0x1F, 0x7F:
                    out.append(String(format: "\\u{%02X}", scalar.value))
                default:
                    out.unicodeScalars.append(scalar)
                }
            }
            return out
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

            // Allow a few rows of slack in full-screen TUIs where click Y and cursor
            // Y can diverge by multiple cell rows due to viewport/overlay geometry.
            let rowDistance = abs(clickRow - cursorRow)
            if rowDistance > Self.composeLooseRowTolerance {
                composeTrace(
                    "fallback row miss click_row=\(clickRow) cursor_row=\(cursorRow) dist=\(rowDistance) tol=\(Self.composeLooseRowTolerance)"
                )
                return nil
            }

            guard let visible = visibleContentsSnapshot() else {
                return nil
            }
            let rows = visible
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init)

            guard cursorRow >= 0, cursorRow < rows.count else {
                return nil
            }

            let row = rows[cursorRow]
            let rawCursorColumn = max(0, Int(floor(CGFloat(cursorX) / cellW)))
            let cursorColumn = min(rawCursorColumn, row.count)
            let heuristic = heuristicInputStartColumn(
                line: row,
                cursorColumn: cursorColumn
            )
            if requirePromptMarker && !heuristic.markerFound {
                return nil
            }

            let boundedStart = min(heuristic.column, row.count)
            let startIndex = row.index(row.startIndex, offsetBy: boundedStart)
            let text = trimRightInlineWhitespace(String(row[startIndex...]))
            let cursorCellLeft = CGFloat(cursorX) - (cellW * 0.5)
            let dxCols = max(0, cursorColumn - boundedStart)
            let x = max(0, cursorCellLeft - (CGFloat(dxCols) * cellW))
            composeTrace(
                "fallback hit click_x=\(clickPoint.x) click_y=\(clickPoint.y) click_row=\(clickRow) cursor_row=\(cursorRow) dist=\(rowDistance) start_col=\(boundedStart) cursor_col=\(cursorColumn) text_len=\(text.count)"
            )

            return .init(
                x: x,
                yTop: cursorTop,
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
            if rowDistance > Self.composeLooseRowTolerance {
                composeTrace(
                    "cursor-only row miss click_row=\(clickRow) cursor_row=\(cursorRow) dist=\(rowDistance) tol=\(Self.composeLooseRowTolerance)"
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

        private func clickRowPromptInputSnapshot(clickPoint: NSPoint) -> PromptInputSnapshot? {
            let cellW = max(1, cellSize.width)
            let cellH = max(1, cellSize.height)

            guard let visible = visibleContentsSnapshot() else {
                return nil
            }
            let rows = visible
                .split(separator: "\n", omittingEmptySubsequences: false)
                .map(String.init)
            guard !rows.isEmpty else { return nil }

            let clickTop = max(0, surfaceContentHeight - clickPoint.y)
            var clickRow = Int(floor(clickTop / cellH))
            clickRow = min(max(0, clickRow), rows.count - 1)
            let rawClickColumn = max(0, Int(floor(clickPoint.x / cellW)))
            let cursorRowAndColumn: (row: Int, column: Int)? = {
                guard let cursorPoint = cursorClickPointInView() else { return nil }
                let cursorTop = max(0, surfaceContentHeight - cursorPoint.y)
                let row = Int(floor(cursorTop / cellH))
                let column = max(0, Int(floor(cursorPoint.x / cellW)))
                return (
                    row: min(max(0, row), rows.count - 1),
                    column: column
                )
            }()
            let cursorRow = cursorRowAndColumn?.row
            let cursorColumn = cursorRowAndColumn?.column

            var candidateRows: [Int] = [clickRow]
            let searchRadius = 4
            if searchRadius > 0 {
                for delta in 1...searchRadius {
                    let up = clickRow - delta
                    let down = clickRow + delta
                    if up >= 0 { candidateRows.append(up) }
                    if down < rows.count { candidateRows.append(down) }
                }
            }
            var rowDiagnostics: [String] = []
            rowDiagnostics.reserveCapacity(6)

            for rowIndex in candidateRows {
                let row = rows[rowIndex]
                let clickColumn = min(rawClickColumn, row.count)

                var startColumn = lineStartPromptInputColumn(line: row)
                var source = "line-start"
                if startColumn == nil {
                    let heuristic = heuristicInputStartColumn(
                        line: row,
                        cursorColumn: clickColumn
                    )
                    if heuristic.markerFound {
                        startColumn = heuristic.column
                        source = "heuristic-click"
                    }
                }
                if startColumn == nil {
                    startColumn = genericLinePromptStartColumn(line: row)
                    if startColumn != nil {
                        source = "generic-start"
                    }
                }
                if startColumn == nil {
                    startColumn = markerAnywherePromptInputColumn(line: row)
                    if startColumn != nil {
                        source = "heuristic-anywhere"
                    }
                }
                if startColumn == nil,
                   let cursorRow,
                   abs(rowIndex - cursorRow) <= Self.composeLooseRowTolerance
                {
                    startColumn = looseLinePromptStartColumn(
                        line: row,
                        clickColumn: clickColumn
                    )
                    if startColumn != nil {
                        source = "cursor-row-loose"
                    }
                }
                guard let markerColumn = startColumn else {
                    if rowDiagnostics.count < 6 {
                        rowDiagnostics.append(
                            "r\(rowIndex):c\(clickColumn):\"\(composeLogLinePreview(row))\""
                        )
                    }
                    continue
                }

                let boundedStart = min(markerColumn, row.count)
                let startIndex = row.index(row.startIndex, offsetBy: boundedStart)
                let text = trimRightInlineWhitespace(String(row[startIndex...]))
                let effectiveStart: Int = {
                    // Empty input lines are common at prompts and TUIs. In this case,
                    // marker-based parsing can be off by a few cells; anchor exactly
                    // to the terminal cursor column when we're on the cursor row.
                    if text.isEmpty,
                       let cursorRow,
                       let cursorColumn,
                       rowIndex == cursorRow
                    {
                        return min(max(0, cursorColumn), row.count)
                    }
                    return boundedStart
                }()
                let x = max(0, CGFloat(effectiveStart) * cellW)
                let yTop = CGFloat(rowIndex) * cellH
                composeTrace(
                    "click-row hit click_x=\(clickPoint.x) click_y=\(clickPoint.y) click_row=\(clickRow) resolved_row=\(rowIndex) cursor_row=\(cursorRow.map(String.init) ?? "nil") cursor_col=\(cursorColumn.map(String.init) ?? "nil") source=\(source) start_col=\(boundedStart) effective_start=\(effectiveStart) click_col=\(clickColumn) text_len=\(text.count)"
                )

                return .init(
                    x: x,
                    yTop: yTop,
                    width: max(cellW, surfaceContentWidth - x),
                    height: cellH,
                    text: text
                )
            }

            composeTrace(
                "click-row no marker click_x=\(clickPoint.x) click_y=\(clickPoint.y) click_row=\(clickRow) cursor_row=\(cursorRow.map(String.init) ?? "nil") click_col=\(rawClickColumn) rows=\(rowDiagnostics.joined(separator: " | "))"
            )
            return nil
        }

        private func cursorRowPromptInputSnapshot() -> PromptInputSnapshot? {
            guard let cursorPoint = cursorClickPointInView() else { return nil }
            return clickRowPromptInputSnapshot(clickPoint: cursorPoint)
        }

        private func promptInputSnapshot(clickPoint: NSPoint) -> PromptInputSnapshot? {
            if let snapshot = semanticPromptInputSnapshot() {
                let frame = promptInputFrame(snapshot)
                let toleranceY = max(2, cellSize.height * 0.25)
                let yDistance = abs(clickPoint.y - frame.midY)
                if yDistance <= (frame.height * 0.5 + toleranceY) {
                    AppDelegate.logger.debug(
                        "compose snapshot source=semantic x=\(snapshot.x) y=\(snapshot.yTop) w=\(snapshot.width) h=\(snapshot.height) len=\(snapshot.text.count)"
                    )
                    return snapshot
                }

                composeTrace(
                    "semantic miss click_x=\(clickPoint.x) click_y=\(clickPoint.y) frame_x=\(frame.minX) frame_y=\(frame.minY) frame_w=\(frame.width) frame_h=\(frame.height)"
                )
                AppDelegate.logger.debug(
                    "compose snapshot source=semantic-miss x=\(snapshot.x) y=\(snapshot.yTop) w=\(snapshot.width) h=\(snapshot.height) click_x=\(clickPoint.x) click_y=\(clickPoint.y)"
                )
            }

            if let snapshot = clickRowPromptInputSnapshot(clickPoint: clickPoint) {
                if !composeSnapshotMatchesClickY(snapshot, clickPoint: clickPoint) {
                    let frame = promptInputFrame(snapshot)
                    composeTrace(
                        "click-row y miss click_x=\(clickPoint.x) click_y=\(clickPoint.y) frame_x=\(frame.minX) frame_y=\(frame.minY) frame_w=\(frame.width) frame_h=\(frame.height)"
                    )
                    return nil
                }
                AppDelegate.logger.debug(
                    "compose snapshot source=click-row x=\(snapshot.x) y=\(snapshot.yTop) w=\(snapshot.width) h=\(snapshot.height) len=\(snapshot.text.count)"
                )
                return snapshot
            }

            if let snapshot = cursorRowPromptInputSnapshot() {
                let frame = promptInputFrame(snapshot)
                let toleranceY = max(cellSize.height * 4.0, frame.height * 0.5 + max(2, cellSize.height * 0.25))
                let yDistance = abs(clickPoint.y - frame.midY)
                if yDistance <= toleranceY {
                    AppDelegate.logger.debug(
                        "compose snapshot source=cursor-row x=\(snapshot.x) y=\(snapshot.yTop) w=\(snapshot.width) h=\(snapshot.height) len=\(snapshot.text.count)"
                    )
                    return snapshot
                }
                composeTrace(
                    "cursor-row y miss click_x=\(clickPoint.x) click_y=\(clickPoint.y) frame_x=\(frame.minX) frame_y=\(frame.minY) frame_w=\(frame.width) frame_h=\(frame.height) tol=\(toleranceY)"
                )
            }

            if let snapshot = fallbackPromptInputSnapshot(clickPoint: clickPoint) {
                if !composeSnapshotMatchesClickY(
                    snapshot,
                    clickPoint: clickPoint,
                    extraRowTolerance: Self.composeLooseRowTolerance
                ) {
                    let frame = promptInputFrame(snapshot)
                    composeTrace(
                        "fallback y miss click_x=\(clickPoint.x) click_y=\(clickPoint.y) frame_x=\(frame.minX) frame_y=\(frame.minY) frame_w=\(frame.width) frame_h=\(frame.height)"
                    )
                    return nil
                }
                AppDelegate.logger.debug(
                    "compose snapshot source=fallback x=\(snapshot.x) y=\(snapshot.yTop) w=\(snapshot.width) h=\(snapshot.height) len=\(snapshot.text.count)"
                )
                return snapshot
            }

            if let snapshot = cursorOnlyPromptInputSnapshot(clickPoint: clickPoint) {
                if !composeSnapshotMatchesClickY(
                    snapshot,
                    clickPoint: clickPoint,
                    extraRowTolerance: Self.composeLooseRowTolerance
                ) {
                    let frame = promptInputFrame(snapshot)
                    composeTrace(
                        "cursor-only y miss click_x=\(clickPoint.x) click_y=\(clickPoint.y) frame_x=\(frame.minX) frame_y=\(frame.minY) frame_w=\(frame.width) frame_h=\(frame.height)"
                    )
                    return nil
                }
                AppDelegate.logger.debug(
                    "compose snapshot source=cursor-only x=\(snapshot.x) y=\(snapshot.yTop) w=\(snapshot.width) h=\(snapshot.height)"
                )
                return snapshot
            }

            AppDelegate.logger.debug(
                "compose snapshot source=none click_x=\(clickPoint.x) click_y=\(clickPoint.y)"
            )
            composeTrace("snapshot none click_x=\(clickPoint.x) click_y=\(clickPoint.y)")
            return nil
        }

        private func promptInputFrame(_ snapshot: PromptInputSnapshot) -> NSRect {
            let width = max(snapshot.width, max(1, cellSize.width))
            let height = max(snapshot.height, max(1, cellSize.height))
            let y = surfaceContentHeight - snapshot.yTop - height
            return NSRect(x: snapshot.x, y: y, width: width, height: height)
        }

        private func composeHitFrame(for editor: NSTextView) -> NSRect {
            let base = editor.frame
            let slopX = max(cellSize.width * 1.5, 12)
            let slopY = max(cellSize.height * 0.6, 12)
            return base.insetBy(dx: -slopX, dy: -slopY)
        }

        private func ensureComposeEditor() -> ComposeTextView {
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
            editor.wantsLayer = true
            editor.layer?.zPosition = 10_000
            editor.drawsBackground = false
            editor.backgroundColor = .clear
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
            editor.textColor = .clear
            editor.insertionPointColor = .clear
            updateComposeSelectionAppearance(editor)
            editor.markedTextAttributes = [
                .foregroundColor: NSColor.clear,
                .backgroundColor: NSColor.clear,
                .underlineStyle: 0,
            ]
            editor.textContainerInset = .zero
            editor.textContainer?.lineFragmentPadding = 0
            editor.textContainer?.lineBreakMode = .byClipping
            editor.textContainer?.maximumNumberOfLines = 1
            editor.textContainer?.widthTracksTextView = true
            editor.textContainer?.heightTracksTextView = true
            editor.isHidden = true

            addSubview(editor)
            composeEditor = editor
            return editor
        }

        private func configureComposeEditorAppearance(_ editor: ComposeTextView) {
            if let surface, let fontRaw = ghostty_surface_quicklook_font(surface) {
                let font = Unmanaged<CTFont>.fromOpaque(fontRaw)
                editor.font = font.takeUnretainedValue()
                font.release()
            } else if cellSize.height > 0 {
                editor.font = .monospacedSystemFont(ofSize: max(12, cellSize.height * 0.8), weight: .regular)
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
            editor.textColor = .clear
            editor.insertionPointColor = .clear
            editor.caretColor = fg
            editor.caretWidth = 1
            editor.drawsBackground = false
            editor.backgroundColor = .clear
            if let layer = editor.layer {
                layer.zPosition = 10_000
                layer.backgroundColor = NSColor.clear.cgColor
            }

            var typing: [NSAttributedString.Key: Any] = [
                .foregroundColor: NSColor.clear,
                .backgroundColor: NSColor.clear,
                .underlineStyle: 0,
            ]
            if let font = editor.font {
                typing[.font] = font
            }
            editor.typingAttributes = typing
            updateComposeSelectionAppearance(editor)
            editor.markedTextAttributes = [
                .foregroundColor: NSColor.clear,
                .backgroundColor: NSColor.clear,
                .underlineStyle: 0,
            ]
        }

        private func updateComposeSelectionAppearance(_ editor: NSTextView) {
            let hasSelection = editor.selectedRange().length > 0
            editor.selectedTextAttributes = [
                .foregroundColor: NSColor.clear,
                .backgroundColor: hasSelection
                    ? NSColor.selectedTextBackgroundColor.withAlphaComponent(0.45)
                    : NSColor.clear,
            ]
        }

        private func normalizeComposeEditorTextAttributes(_ editor: NSTextView) {
            var attrs: [NSAttributedString.Key: Any] = [
                .foregroundColor: NSColor.clear,
                .backgroundColor: NSColor.clear,
                .underlineStyle: 0,
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

        private func insertComposeTrailingSpace(editor: NSTextView) {
            let oldText = composeSyncedText
            let oldCursor = composeSyncedCursor
            let newText = editor.string + " "
            let newCursor = newText.utf16.count

            composeSuppressSync = true
            editor.string = newText
            normalizeComposeEditorTextAttributes(editor)
            editor.setSelectedRange(NSRange(location: newCursor, length: 0))
            composeSuppressSync = false

            syncTerminalLine(
                from: oldText,
                cursor: oldCursor,
                to: newText,
                cursor: newCursor
            )
            composeSyncedText = newText
            composeSyncedCursor = newCursor
            composeTrace("compose inserted trailing space new_len=\(newText.count) cursor=\(newCursor)")
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
                // Keep compose mirroring consistent with regular text input paths.
                // `sendText` ensures visible rendering in TUIs that don't reflect
                // raw PTY injection in their local input widgets.
                surfaceModel?.sendText(newText)
            }

            // Reposition cursor within new content.
            if clampedNewCursor < newLen {
                for _ in 0..<(newLen - clampedNewCursor) {
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

            let frame = promptInputFrame(snapshot)
            editor.frame = frame
            composeTrace(
                "activate frame_x=\(frame.minX) frame_y=\(frame.minY) frame_w=\(frame.width) frame_h=\(frame.height) click_x=\(clickPoint.x) click_y=\(clickPoint.y) text_len=\(snapshot.text.count)"
            )
            composeSuppressSync = true
            editor.string = snapshot.text
            normalizeComposeEditorTextAttributes(editor)

            // Vertically center text in the terminal cell row.
            if let font = editor.font {
                let lineHeight = editor.layoutManager?.defaultLineHeight(for: font) ?? font.pointSize
                let insetY = max(0, floor((frame.height - lineHeight) * 0.5))
                editor.textContainerInset = NSSize(width: 0, height: insetY)
            } else {
                editor.textContainerInset = .zero
            }

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
            setTerminalCursorHidden(true)
            composeStabilizeUntil = Date.timeIntervalSinceReferenceDate + 0.45

            AppDelegate.logger.debug(
                "compose activate x=\(snapshot.x) y=\(snapshot.yTop) w=\(snapshot.width) h=\(snapshot.height) text_len=\(snapshot.text.count)"
            )

            let idx = composeInsertionIndex(for: editor, clickPointInSurface: clickPoint)
            editor.setSelectedRange(NSRange(location: idx, length: 0))
            composeSuppressSync = false

            // Keep shell cursor aligned with clicked insertion position.
            if idx != composeSyncedCursor {
                syncTerminalCursor(from: composeSyncedCursor, to: idx)
                composeSyncedCursor = idx
            }
            composeTrace("activate done cursor=\(idx)")
        }

        private func finishCompose(_ reason: ComposeExitReason) {
            guard let original = composeOriginalText else { return }
            guard let editor = composeEditor else { return }
            guard !composeEnding else { return }
            composeEnding = true
            defer { composeEnding = false }

            let draft = editor.string
            let cursor = min(max(0, editor.selectedRange().location), draft.utf16.count)
            editor.isHidden = true
            composeOriginalText = nil
            composeSelectionAnchor = nil
            composeResponderHandoff = true
            window?.makeFirstResponder(self)
            composeResponderHandoff = false

            switch reason {
            case .commit:
                AppDelegate.logger.debug("compose finish reason=commit draft_len=\(draft.count) original_len=\(original.count)")
                if draft != composeSyncedText || cursor != composeSyncedCursor {
                    syncTerminalLine(
                        from: composeSyncedText,
                        cursor: composeSyncedCursor,
                        to: draft,
                        cursor: cursor
                    )
                }
                surfaceModel?.sendKeyEvent(.init(key: .enter, action: .press))
                surfaceModel?.sendKeyEvent(.init(key: .enter, action: .release))
            case .cancel:
                AppDelegate.logger.debug("compose finish reason=cancel draft_len=\(draft.count) original_len=\(original.count)")
                if original != composeSyncedText {
                    syncTerminalLine(
                        from: composeSyncedText,
                        cursor: composeSyncedCursor,
                        to: original,
                        cursor: original.utf16.count
                    )
                }
            case .blur:
                AppDelegate.logger.debug("compose finish reason=blur draft_len=\(draft.count) original_len=\(original.count)")
            }

            composeSyncedText = ""
            composeSyncedCursor = 0
            setTerminalCursorHidden(false)
            composeStabilizeUntil = 0
            composeTrace("finish reason=\(reason)")
        }

        private func composeSnapshotForCursorRow() -> PromptInputSnapshot? {
            guard let cursorPoint = cursorClickPointInView() else { return nil }
            return semanticPromptInputSnapshot()
                ?? fallbackPromptInputSnapshot(clickPoint: cursorPoint)
                ?? cursorOnlyPromptInputSnapshot(clickPoint: cursorPoint)
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

        private func refreshComposeFromTerminalAfterTab(attempt: Int = 0) {
            guard composeOriginalText != nil else { return }
            guard let editor = composeEditor, !editor.isHidden else { return }

            if let snapshot = composeSnapshotForCursorRow() {
                composeSuppressSync = true
                editor.frame = promptInputFrame(snapshot)
                if editor.string != snapshot.text {
                    editor.string = snapshot.text
                    normalizeComposeEditorTextAttributes(editor)
                }
                let cursor = composeCursorIndexFromTerminal(snapshot: snapshot)
                editor.setSelectedRange(NSRange(location: cursor, length: 0))
                composeSuppressSync = false
                composeSelectionAnchor = nil
                updateComposeSelectionAppearance(editor)
                editor.needsDisplay = true
                editor.displayIfNeeded()

                composeSyncedText = snapshot.text
                composeSyncedCursor = cursor
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

            var cursor = min(max(0, editor.selectedRange().location), editor.string.utf16.count)
            if editor.selectedRange().length > 0 {
                cursor = min(editor.selectedRange().location + editor.selectedRange().length, editor.string.utf16.count)
                composeSuppressSync = true
                editor.setSelectedRange(NSRange(location: cursor, length: 0))
                composeSuppressSync = false
            }

            let draft = editor.string
            if draft != composeSyncedText || cursor != composeSyncedCursor {
                syncTerminalLine(
                    from: composeSyncedText,
                    cursor: composeSyncedCursor,
                    to: draft,
                    cursor: cursor
                )
                composeSyncedText = draft
                composeSyncedCursor = cursor
            }

            composeTrace("tab request draft_len=\(draft.count) cursor=\(cursor)")
            surfaceModel?.sendKeyEvent(.init(key: .tab, action: .press))
            surfaceModel?.sendKeyEvent(.init(key: .tab, action: .release))

            // Let shell completion update the prompt, then mirror terminal state back
            // into the compose editor.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.015) { [weak self] in
                self?.refreshComposeFromTerminalAfterTab(attempt: 0)
            }
        }

        private func handleComposeActivationClick(_ event: NSEvent) -> Bool {
            guard composeOriginalText == nil else { return false }
            guard searchState == nil else { return false }

            let point = convert(event.locationInWindow, from: nil)
            composeTrace("click point_x=\(point.x) point_y=\(point.y)")
            guard let snapshot = promptInputSnapshot(clickPoint: point) else { return false }

            AppDelegate.logger.debug("compose click hit click_x=\(point.x) click_y=\(point.y)")

            activateComposeMode(with: snapshot, clickPoint: point)
            return true
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
            guard let keyAny = notification.userInfo?[Ghostty.Notification.KeySequenceKey] else { return }
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
            guard let action = notification.userInfo?[Ghostty.Notification.KeyTableKey] as? Ghostty.Action.KeyTable else { return }

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
                SwiftUI.Notification.Name.GhosttyConfigChangeKey
            ] as? Ghostty.Config else { return }

            // Update our derived config
            DispatchQueue.main.async { [weak self] in
                self?.derivedConfig = DerivedConfig(config)
            }
        }

        @objc private func ghosttyColorDidChange(_ notification: SwiftUI.Notification) {
            guard let change = notification.userInfo?[
                SwiftUI.Notification.Name.GhosttyColorChangeKey
            ] as? Ghostty.Action.ColorChange else { return }

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
                composeTrace("finish trigger source=windowDidResignKey")
                finishCompose(.blur)
            }
        }

        @objc private func appDidResignActive(_ notification: SwiftUI.Notification) {
            if composeOriginalText != nil {
                composeTrace("finish trigger source=appDidResignActive")
                finishCompose(.blur)
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
            let responderName = window?.firstResponder.map { String(describing: type(of: $0)) } ?? "nil"
            composeTrace(
                "mouseDown x=\(point.x) y=\(point.y) focused=\(focused) compose_active=\(composeOriginalText != nil) responder=\(responderName) clickCount=\(event.clickCount) buttons=\(NSEvent.pressedMouseButtons)"
            )

            if composeOriginalText != nil {
                if let editor = composeEditor, !editor.isHidden {
                    let strictHit = editor.frame.contains(point)
                    let tolerantHit = composeHitFrame(for: editor).contains(point)
                    composeTrace(
                        "mouseDown compose hit strict=\(strictHit) tolerant=\(tolerantHit) frame_x=\(editor.frame.minX) frame_y=\(editor.frame.minY) frame_w=\(editor.frame.width) frame_h=\(editor.frame.height)"
                    )
                    guard strictHit || tolerantHit else {
                        composeTrace("finish trigger source=mouseDown-outside-compose")
                        finishCompose(.blur)
                        // Continue normal terminal handling below after compose closes.
                        _ = window?.makeFirstResponder(self)
                        composeTrace("mouseDown after makeFirstResponder compose_active=\(composeOriginalText != nil)")
                        if handleComposeActivationClick(event) {
                            composeTrace("mouseDown compose activated")
                            if let editor = composeEditor, !editor.isHidden {
                                if window?.firstResponder !== editor {
                                    _ = window?.makeFirstResponder(editor)
                                }
                                let idx = composeInsertionIndex(for: editor, clickPointInSurface: point)
                                composeSuppressSync = true
                                editor.setSelectedRange(NSRange(location: idx, length: 0))
                                composeSelectionAnchor = idx
                                composeSuppressSync = false
                                updateComposeSelectionAppearance(editor)
                                editor.needsDisplay = true
                                editor.displayIfNeeded()
                                composeTrace("mouseDown compose initial-anchor=\(idx)")
                            }
                            return
                        }
                        composeTrace("mouseDown forwarding to terminal")
                        guard let surface = self.surface else { return }
                        let mods = Ghostty.ghosttyMods(event.modifierFlags)
                        ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, mods)
                        return
                    }

                    if window?.firstResponder !== editor {
                        _ = window?.makeFirstResponder(editor)
                    }
                    var idx = composeInsertionIndex(for: editor, clickPointInSurface: point)
                    if event.clickCount >= 2 {
                        composeSuppressSync = true
                        let word = composeWordSelectionRange(text: editor.string, around: idx)
                        editor.setSelectedRange(word)
                        composeSelectionAnchor = nil
                        let caret = word.location + word.length
                        if caret != composeSyncedCursor {
                            syncTerminalCursor(from: composeSyncedCursor, to: caret)
                            composeSyncedCursor = caret
                        }
                        composeTrace(
                            "mouseDown compose word-select idx=\(idx) sel_loc=\(word.location) sel_len=\(word.length) clickCount=\(event.clickCount)"
                        )
                        composeSuppressSync = false
                    } else {
                        if shouldInsertComposeTrailingSpace(
                            editor: editor,
                            clickPointInSurface: point,
                            insertionIndex: idx,
                            strictHit: strictHit
                        ) {
                            insertComposeTrailingSpace(editor: editor)
                            idx = editor.string.utf16.count
                        }
                        composeSuppressSync = true
                        editor.setSelectedRange(NSRange(location: idx, length: 0))
                        composeSelectionAnchor = idx
                        composeSuppressSync = false
                    }
                    updateComposeSelectionAppearance(editor)
                    editor.needsDisplay = true
                    editor.displayIfNeeded()
                    composeTrace("mouseDown compose anchor=\(idx) clickCount=\(event.clickCount)")
                    return
                }
                composeTrace("finish trigger source=mouseDown-outside-compose")
                finishCompose(.blur)
            }

            _ = window?.makeFirstResponder(self)
            composeTrace("mouseDown after makeFirstResponder compose_active=\(composeOriginalText != nil)")
            if handleComposeActivationClick(event) {
                composeTrace("mouseDown compose activated")
                if let editor = composeEditor, !editor.isHidden {
                    if window?.firstResponder !== editor {
                        _ = window?.makeFirstResponder(editor)
                    }
                    var idx = composeInsertionIndex(for: editor, clickPointInSurface: point)
                    let strictHit = editor.frame.contains(point)
                    if event.clickCount >= 2 {
                        composeSuppressSync = true
                        let word = composeWordSelectionRange(text: editor.string, around: idx)
                        editor.setSelectedRange(word)
                        composeSelectionAnchor = nil
                        let caret = word.location + word.length
                        if caret != composeSyncedCursor {
                            syncTerminalCursor(from: composeSyncedCursor, to: caret)
                            composeSyncedCursor = caret
                        }
                        composeTrace(
                            "mouseDown compose initial word-select idx=\(idx) sel_loc=\(word.location) sel_len=\(word.length) clickCount=\(event.clickCount)"
                        )
                        composeSuppressSync = false
                    } else {
                        if shouldInsertComposeTrailingSpace(
                            editor: editor,
                            clickPointInSurface: point,
                            insertionIndex: idx,
                            strictHit: strictHit
                        ) {
                            insertComposeTrailingSpace(editor: editor)
                            idx = editor.string.utf16.count
                        }
                        composeSuppressSync = true
                        editor.setSelectedRange(NSRange(location: idx, length: 0))
                        composeSelectionAnchor = idx
                        composeSuppressSync = false
                    }
                    updateComposeSelectionAppearance(editor)
                    editor.needsDisplay = true
                    editor.displayIfNeeded()
                    composeTrace("mouseDown compose initial-anchor=\(idx)")
                }
                return
            }
            composeTrace("mouseDown forwarding to terminal")

            guard let surface = self.surface else { return }
            let mods = Ghostty.ghosttyMods(event.modifierFlags)
            ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, GHOSTTY_MOUSE_LEFT, mods)
        }

        override func mouseUp(with event: NSEvent) {
            let point = convert(event.locationInWindow, from: nil)
            composeTrace("mouseUp x=\(point.x) y=\(point.y) compose_active=\(composeOriginalText != nil) buttons=\(NSEvent.pressedMouseButtons)")
            if composeOriginalText != nil {
                if let editor = composeEditor, !editor.isHidden, let anchor = composeSelectionAnchor {
                    let idx = updateComposeSelectionForDrag(
                        editor: editor,
                        anchor: anchor,
                        pointInSurface: point
                    )
                    if idx != composeSyncedCursor {
                        syncTerminalCursor(from: composeSyncedCursor, to: idx)
                        composeSyncedCursor = idx
                    }
                    composeTrace("mouseUp compose idx=\(idx) anchor=\(anchor) sel_loc=\(editor.selectedRange().location) sel_len=\(editor.selectedRange().length)")
                }
                composeSelectionAnchor = nil
                return
            }

            // Always reset our pressure when the mouse goes up
            prevPressureStage = 0

            // If we have an active surface, report the event
            guard let surface = self.surface else { return }
            let mods = Ghostty.ghosttyMods(event.modifierFlags)
            ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, GHOSTTY_MOUSE_LEFT, mods)

            // Release pressure
            ghostty_surface_mouse_pressure(surface, 0, 0)
        }

        override func otherMouseDown(with event: NSEvent) {
            guard let surface = self.surface else { return }
            let mods = Ghostty.ghosttyMods(event.modifierFlags)
            let button = Ghostty.Input.MouseButton(fromNSEventButtonNumber: event.buttonNumber)
            ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_PRESS, button.cMouseButton, mods)
        }

        override func otherMouseUp(with event: NSEvent) {
            guard let surface = self.surface else { return }
            let mods = Ghostty.ghosttyMods(event.modifierFlags)
            let button = Ghostty.Input.MouseButton(fromNSEventButtonNumber: event.buttonNumber)
            ghostty_surface_mouse_button(surface, GHOSTTY_MOUSE_RELEASE, button.cMouseButton, mods)
        }


        override func rightMouseDown(with event: NSEvent) {
            if composeOriginalText != nil {
                composeTrace("finish trigger source=rightMouseDown")
                finishCompose(.blur)
            }

            guard let surface = self.surface else { return super.rightMouseDown(with: event) }

            let mods = Ghostty.ghosttyMods(event.modifierFlags)
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

            let mods = Ghostty.ghosttyMods(event.modifierFlags)
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
            let mouseEvent = Ghostty.Input.MousePosEvent(
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
            let mouseEvent = Ghostty.Input.MousePosEvent(
                x: -1,
                y: -1,
                mods: .init(nsFlags: event.modifierFlags)
            )
            surfaceModel.sendMousePos(mouseEvent)
        }

        override func mouseMoved(with event: NSEvent) {
            guard let surfaceModel else { return }

            // Convert window position to view position. Note (0, 0) is bottom left.
            let pos = self.convert(event.locationInWindow, from: nil)
            let mouseEvent = Ghostty.Input.MousePosEvent(
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
                Ghostty.moveFocus(to: self)
            }
        }

        override func hitTest(_ point: NSPoint) -> NSView? {
            if composeOriginalText != nil,
               let editor = composeEditor,
               !editor.isHidden,
               composeHitFrame(for: editor).contains(point)
            {
                // Keep compose click/drag handling deterministic in SurfaceView.
                return self
            }
            return super.hitTest(point)
        }

        override func mouseDragged(with event: NSEvent) {
            if composeOriginalText != nil {
                if let editor = composeEditor,
                   !editor.isHidden,
                   let anchor = composeSelectionAnchor
                {
                    let point = convert(event.locationInWindow, from: nil)
                    let idx = updateComposeSelectionForDrag(
                        editor: editor,
                        anchor: anchor,
                        pointInSurface: point
                    )
                    if idx != composeSyncedCursor {
                        syncTerminalCursor(from: composeSyncedCursor, to: idx)
                        composeSyncedCursor = idx
                    }
                    composeTrace(
                        "mouseDragged x=\(point.x) y=\(point.y) idx=\(idx) anchor=\(anchor) sel_loc=\(editor.selectedRange().location) sel_len=\(editor.selectedRange().length)"
                    )
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

            let scrollEvent = Ghostty.Input.MouseScrollEvent(
                x: x,
                y: y,
                mods: .init(precision: precision, momentum: .init(event.momentumPhase))
            )
            surfaceModel.sendMouseScroll(scrollEvent)
        }

        override func pressureChange(with event: NSEvent) {
            guard let surface = self.surface else { return }

            // Notify Ghostty first. We do this because this will let Ghostty handle
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
            let translationModsGhostty = Ghostty.eventModifierFlags(
                mods: ghostty_surface_key_translation_mods(
                    surface,
                    Ghostty.ghosttyMods(event.modifierFlags)
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

            // While native compose editing is active, let AppKit text editing
            // key equivalents take precedence (Cmd+C/X/V/A, etc.).
            if composeOriginalText != nil,
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
                        editor.selectAll(nil)
                        return true
                    case "c":
                        editor.copy(nil)
                        return true
                    case "x":
                        editor.cut(nil)
                        return true
                    case "v":
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
            let mods = Ghostty.ghosttyMods(event.modifierFlags)

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
            // character. Control characters are encoded by Ghostty itself.
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

            // Ghostty coordinate system is top-left, convert to bottom-left for AppKit
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
            if composeOriginalText != nil,
               let editor = composeEditor,
               !editor.isHidden
            {
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
               let editor = composeEditor,
               !editor.isHidden
            {
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
               let editor = composeEditor,
               !editor.isHidden
            {
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
               let editor = composeEditor,
               !editor.isHidden
            {
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
            if let window, let controller = window.windowController as? BaseTerminalController {
                controller.promptWindowTitle()
            } else {
                promptTitle()
            }
        }

        /// Show a user notification and associate it with this surface
        func showUserNotification(title: String, body: String) {
            let content = UNMutableNotificationContent()
            content.title = title
            content.subtitle = self.title
            content.body = body
            content.sound = UNNotificationSound.default
            content.categoryIdentifier = Ghostty.userNotificationCategory
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
                Ghostty.moveFocus(to: self)
            }
        }

        struct DerivedConfig {
            let backgroundColor: Color
            let backgroundOpacity: Double
            let backgroundBlur: Ghostty.Config.BackgroundBlur
            let macosWindowShadow: Bool
            let windowTitleFontFamily: String?
            let windowAppearance: NSAppearance?
            let scrollbar: Ghostty.Config.Scrollbar

            init() {
                self.backgroundColor = Color(NSColor.windowBackgroundColor)
                self.backgroundOpacity = 1
                self.backgroundBlur = .disabled
                self.macosWindowShadow = true
                self.windowTitleFontFamily = nil
                self.windowAppearance = nil
                self.scrollbar = .system
            }

            init(_ config: Ghostty.Config) {
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
            // Decoding uses the global Ghostty app
            guard let del = NSApplication.shared.delegate,
                  let appDel = del as? AppDelegate,
                  let app = appDel.ghostty.app else {
                throw TerminalRestoreError.delegateInvalid
            }

            let container = try decoder.container(keyedBy: CodingKeys.self)
            let uuid = UUID(uuidString: try container.decode(String.self, forKey: .uuid))
            var config = Ghostty.SurfaceConfiguration()
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

extension Ghostty.SurfaceView: NSTextInputClient {
    func hasMarkedText() -> Bool {
        return markedText.length > 0
    }

    func markedRange() -> NSRange {
        guard markedText.length > 0 else { return NSRange() }
        return NSRange(0...(markedText.length-1))
    }

    func selectedRange() -> NSRange {
        guard let surface = self.surface else { return NSRange() }

        // Get our range from the Ghostty API. There is a race condition between getting the
        // range and actually using it since our selection may change but there isn't a good
        // way I can think of to solve this for AppKit.
        var text = ghostty_text_s()
        guard ghostty_surface_read_selection(surface, &text) else { return NSRange() }
        defer { ghostty_surface_free_text(surface, &text) }
        return NSRange(location: Int(text.offset_start), length: Int(text.offset_len))
    }

    func setMarkedText(_ string: Any, selectedRange: NSRange, replacementRange: NSRange) {
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
        if self.markedText.length > 0 {
            self.markedText.mutableString.setString("")
            syncPreedit()
        }
    }

    func validAttributesForMarkedText() -> [NSAttributedString.Key] {
        return []
    }

    func attributedSubstring(forProposedRange range: NSRange, actualRange: NSRangePointer?) -> NSAttributedString? {
        // Ghostty.logger.warning("pressure substring range=\(range) selectedRange=\(self.selectedRange())")
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

        // Ghostty will tell us where it thinks an IME keyboard should render.
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
        // Ghostty coordinates are in top-left (0, 0) so we have to convert to
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
extension Ghostty.SurfaceView: NSServicesMenuRequestor {
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

extension Ghostty.SurfaceView: NSMenuItemValidation {
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

extension Ghostty.SurfaceView: NSTextViewDelegate {
    func textView(_ textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
        guard textView === composeEditor else { return false }

        switch commandSelector {
        case #selector(insertNewline(_:)):
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

        let draft = textView.string
        var selection = textView.selectedRange()
        var cursor = min(max(0, selection.location), draft.utf16.count)

        // Editing should leave a caret, not a persistent selection highlight.
        // If AppKit leaves a range selected after an edit, collapse to the insertion edge.
        if selection.length > 0 {
            let oldLength = selection.length
            let collapse = min(selection.location + oldLength, draft.utf16.count)
            composeSuppressSync = true
            textView.setSelectedRange(NSRange(location: collapse, length: 0))
            composeSuppressSync = false
            selection = textView.selectedRange()
            cursor = min(max(0, selection.location), draft.utf16.count)
            composeTrace("textDidChange collapsed selection old_len=\(oldLength) cursor=\(cursor)")
        }

        composeSuppressSync = true
        normalizeComposeEditorTextAttributes(textView)
        textView.markedTextAttributes = [
            .foregroundColor: NSColor.clear,
            .backgroundColor: NSColor.clear,
            .underlineStyle: 0,
        ]
        composeSuppressSync = false

        let marked = textView.markedRange()
        let termSelection = surface.map { ghostty_surface_has_selection($0) } ?? false
        composeTrace(
            "textDidChange draft_len=\(draft.count) cursor=\(cursor) marked_loc=\(marked.location) marked_len=\(marked.length) term_sel=\(termSelection)"
        )
        setTerminalCursorHidden(true)
        syncTerminalLine(
            from: composeSyncedText,
            cursor: composeSyncedCursor,
            to: draft,
            cursor: cursor
        )
        composeSyncedText = draft
        composeSyncedCursor = cursor
    }

    func textViewDidChangeSelection(_ notification: Notification) {
        guard !composeEnding else { return }
        guard !composeSuppressSync else { return }
        guard let textView = notification.object as? NSTextView else { return }
        guard textView === composeEditor else { return }
        guard composeOriginalText != nil else { return }

        let selection = textView.selectedRange()
        let cursor = min(max(0, selection.location), composeSyncedText.utf16.count)
        composeTrace("selection location=\(selection.location) length=\(selection.length) synced_cursor=\(composeSyncedCursor)")
        setTerminalCursorHidden(true)
        composeSuppressSync = true
        updateComposeSelectionAppearance(textView)
        composeSuppressSync = false

        // Keep selection paint responsive while dragging.
        textView.needsDisplay = true
        textView.displayIfNeeded()
        if isLeftMouseButtonDown() { return }

        guard selection.length == 0 else { return }
        if cursor != composeSyncedCursor {
            syncTerminalCursor(from: composeSyncedCursor, to: cursor)
            composeSyncedCursor = cursor
        }
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

        composeTrace("finish trigger source=textDidEndEditing")
        finishCompose(.blur)
    }
}

// MARK: NSDraggingDestination

extension Ghostty.SurfaceView {
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
            content = Ghostty.Shell.escape(url)
        } else if let urls = pb.readObjects(forClasses: [NSURL.self]) as? [URL],
           urls.count > 0 {
            // File URLs next. They get escaped individually and then joined by a
            // space if there are multiple.
            content = urls
                .map { Ghostty.Shell.escape($0.path) }
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

extension Ghostty.SurfaceView {
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
    /// this to copy styling information as well but we need to augment Ghostty core to
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
