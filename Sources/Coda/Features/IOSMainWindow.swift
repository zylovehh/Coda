import SwiftUI

#if os(iOS)
enum IPadChrome {
    case native
    case legacy
}

private struct IPadChromeKey: EnvironmentKey {
    static let defaultValue: IPadChrome = .legacy
}

private struct LegacyIPadSystemInsetsKey: EnvironmentKey {
    static let defaultValue = EdgeInsets()
}

private struct LegacyIPadKeyboardOverlapKey: EnvironmentKey {
    static let defaultValue: CGFloat = 0
}

private struct NowPlayingTransitionNamespaceKey: EnvironmentKey {
    static let defaultValue: Namespace.ID? = nil
}

extension EnvironmentValues {
    var legacyIPadKeyboardOverlap: CGFloat {
        get { self[LegacyIPadKeyboardOverlapKey.self] }
        set { self[LegacyIPadKeyboardOverlapKey.self] = newValue }
    }

    var legacyIPadSystemInsets: EdgeInsets {
        get { self[LegacyIPadSystemInsetsKey.self] }
        set { self[LegacyIPadSystemInsetsKey.self] = newValue }
    }

    var nowPlayingTransitionNamespace: Namespace.ID? {
        get { self[NowPlayingTransitionNamespaceKey.self] }
        set { self[NowPlayingTransitionNamespaceKey.self] = newValue }
    }

    var iPadChrome: IPadChrome {
        get { self[IPadChromeKey.self] }
        set { self[IPadChromeKey.self] = newValue }
    }
}

@available(iOS 26.0, *)
private struct NativeIPadRoot: View {
    @Binding var path: [Destination]

    var body: some View {
        MainWindow(path: $path)
            .environment(\.iPadChrome, .native)
    }
}

private struct LegacyIPadRoot: View {
    @Binding var path: [Destination]
    @Environment(\.scenePhase) private var scenePhase
    @State private var lastActiveSystemInsets: EdgeInsets?
    @State private var keyboardOcclusion: CGFloat = 0

    var body: some View {
        // Keep one full-window canvas. Keyboard avoidance is applied once,
        // explicitly, to destinations and chrome rather than to this root.
        GeometryReader { viewport in
            let isCompact = viewport.size.width < WindowLayout.compactWidth
            let insets = scenePhase == .active ? viewport.safeAreaInsets
                : (lastActiveSystemInsets ?? viewport.safeAreaInsets)
            MainWindow(path: $path)
                .environment(\.iPadChrome, .legacy)
                .environment(\.legacyIPadSystemInsets, insets)
                .environment(\.legacyIPadKeyboardOverlap,
                             max(0, keyboardOcclusion - insets.bottom))
                .ignoresSafeArea(.container, edges: isCompact ? [] : .vertical)
                .onAppear {
                    if scenePhase == .active { lastActiveSystemInsets = viewport.safeAreaInsets }
                }
                .onChange(of: viewport.safeAreaInsets) { next in
                    if scenePhase == .active { lastActiveSystemInsets = next }
                }
                .onChange(of: scenePhase) { phase in
                    if phase == .active { lastActiveSystemInsets = viewport.safeAreaInsets }
                }
        }
        .ignoresSafeArea(.keyboard, edges: .bottom)
        .background(LegacyIPadKeyboardObserver(occlusion: $keyboardOcclusion))
    }
}

@MainActor
private protocol LegacyKeyboardSafeAreaHosting {
    func configureLegacySafeArea(ownsContainerInsets: Bool, preservesContainerInsets: Bool)
}

extension UIHostingController: LegacyKeyboardSafeAreaHosting {
    fileprivate func configureLegacySafeArea(ownsContainerInsets: Bool, preservesContainerInsets: Bool) {
        if #available(iOS 16.4, *) {
            let excluded: SafeAreaRegions = ownsContainerInsets ? .all : .keyboard
            // The wide canvas owns its insets. Compact navigation restores
            // container regions so UIKit can reserve the real bar and indicators.
            let next = preservesContainerInsets
                ? safeAreaRegions.union(.container).subtracting(.keyboard)
                : safeAreaRegions.subtracting(excluded)
            if safeAreaRegions != next { safeAreaRegions = next }
        }
    }
}

@MainActor
private func configureLegacyHostingSafeAreas(_ controller: UIViewController,
                                            insideNavigation: Bool = false,
                                            preservesContainerInsets: Bool? = nil) {
    let preservesContainerInsets = preservesContainerInsets
        ?? ((controller.viewIfLoaded?.window?.bounds.width ?? .infinity) < WindowLayout.compactWidth)
    let ownsContainerInsets = insideNavigation || controller is UINavigationController
    (controller as? LegacyKeyboardSafeAreaHosting)?
        .configureLegacySafeArea(ownsContainerInsets: ownsContainerInsets,
                                  preservesContainerInsets: preservesContainerInsets)
    for child in controller.children {
        configureLegacyHostingSafeAreas(child, insideNavigation: ownsContainerInsets,
                                        preservesContainerInsets: preservesContainerInsets)
    }
}

/// A pushed destination can get a new hosting controller without resizing the
/// window. Configure that controller before it accepts text input as well.
struct LegacyIPadHostingSafeAreaProbe: UIViewRepresentable {
    func makeUIView(context: Context) -> Probe { Probe() }
    func updateUIView(_ view: Probe, context: Context) { view.scheduleConfiguration() }

    final class Probe: UIView {
        private var pending = false

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            accessibilityElementsHidden = true
        }
        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        override func didMoveToWindow() {
            super.didMoveToWindow()
            scheduleConfiguration()
        }
        func scheduleConfiguration() {
            guard window != nil, !pending else { return }
            pending = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.pending = false
                if let root = self.window?.rootViewController { configureLegacyHostingSafeAreas(root) }
            }
        }
    }
}

/// Observe the keyboard in this window's coordinates, independently of
/// SwiftUI's keyboard-safe-area propagation through NavigationStack on iOS 16.
private struct LegacyIPadKeyboardObserver: UIViewRepresentable {
    @Binding var occlusion: CGFloat

    func makeUIView(context: Context) -> Probe { Probe() }

    func updateUIView(_ view: Probe, context: Context) {
        view.onChange = { height, duration in
            guard occlusion != height else { return }
            withAnimation(.easeOut(duration: duration)) { occlusion = height }
        }
    }

    static func dismantleUIView(_ view: Probe, coordinator: Void) {
        view.onChange = nil
    }

    final class Probe: UIView {
        var onChange: ((CGFloat, TimeInterval) -> Void)?
        private var keyboardFrame: CGRect?
        private var updatePending = false

        override init(frame: CGRect) {
            super.init(frame: frame)
            isUserInteractionEnabled = false
            accessibilityElementsHidden = true
            for name in [UIResponder.keyboardWillChangeFrameNotification,
                         UIResponder.keyboardWillHideNotification] {
                NotificationCenter.default.addObserver(self, selector: #selector(keyboardChanged(_:)),
                                                       name: name, object: nil)
            }
        }

        required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
        deinit { NotificationCenter.default.removeObserver(self) }

        @objc private func keyboardChanged(_ notification: Notification) {
            if let root = window?.rootViewController { configureLegacyHostingSafeAreas(root) }
            if notification.name == UIResponder.keyboardWillHideNotification {
                keyboardFrame = nil
            } else {
                keyboardFrame = notification.userInfo?[UIResponder.keyboardFrameEndUserInfoKey] as? CGRect
            }
            publish(duration: notification.userInfo?[UIResponder.keyboardAnimationDurationUserInfoKey]
                    as? TimeInterval ?? 0.25)
        }

        override func layoutSubviews() {
            super.layoutSubviews()
            guard !updatePending else { return }
            updatePending = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.updatePending = false
                if let root = self.window?.rootViewController {
                    configureLegacyHostingSafeAreas(root)
                }
                self.publish(duration: 0)
            }
        }

        private func publish(duration: TimeInterval) {
            guard let window else { return }
            guard let keyboardFrame else { onChange?(0, duration); return }
            let frame = window.convert(keyboardFrame, from: window.screen.coordinateSpace)
            let covered = window.bounds.intersection(frame)
            // Floating/split keyboards must not collapse the whole page.
            let docked = !covered.isNull && covered.width >= window.bounds.width * 0.95
                && covered.maxY >= window.bounds.maxY - 1
            onChange?(docked ? covered.height : 0, duration)
        }
    }
}

struct IPadSplitStyle: ViewModifier {
    func body(content: Content) -> some View {
        content.navigationSplitViewStyle(.balanced)
    }
}

/// Before iOS 18 the player is presented by UIKit rather than `fullScreenCover`.
/// A full-screen cover takes the page underneath out of the window once it is
/// up, so dragging the player down showed a black window, and the page was put
/// back with a flash on dismissal. An over-full-screen presentation keeps the
/// page in place underneath for the whole time the player is shown.
///
/// UIKit only mounts the player here (no system animation). Opening, closing
/// and the handle drag all run through `CoverZoomMotion`, which grows the
/// player out of the mini player and shrinks it back, like the iOS 18 zoom.
private struct OverFullScreenCover<CoverContent: View>: UIViewControllerRepresentable {
    @Binding var isPresented: Bool
    var onDismiss: () -> Void
    @ViewBuilder var content: () -> CoverContent

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeUIViewController(context: Context) -> UIViewController {
        let anchor = UIViewController()
        anchor.view.backgroundColor = .clear
        anchor.view.isUserInteractionEnabled = false
        anchor.view.isAccessibilityElement = false
        return anchor
    }

    func updateUIViewController(_ anchor: UIViewController, context: Context) {
        let coordinator = context.coordinator
        coordinator.anchor = anchor
        coordinator.onDismiss = onDismiss
        coordinator.wantsPresented = { isPresented }
        let binding = $isPresented
        coordinator.requestDismiss = { binding.wrappedValue = false }
        coordinator.makeContent = { AnyView(content()) }
        if let hosting = coordinator.hosting { hosting.rootView = AnyView(content()) }
        coordinator.sync()
    }

    static func dismantleUIViewController(_ anchor: UIViewController, coordinator: Coordinator) {
        coordinator.wantsPresented = { false }
        coordinator.sync()
    }

    @MainActor
    final class Coordinator {
        weak var anchor: UIViewController?
        var hosting: UIHostingController<AnyView>?
        var onDismiss: () -> Void = {}
        var wantsPresented: () -> Bool = { false }
        var requestDismiss: () -> Void = {}
        var makeContent: () -> AnyView = { AnyView(EmptyView()) }
        private var motion: CoverZoomMotion?
        private var isTransitioning = false
        private var syncScheduled = false

        /// Brings UIKit in line with the binding. Runs after the current
        /// SwiftUI update and never starts a transition while one is running.
        func sync() {
            guard !syncScheduled else { return }
            syncScheduled = true
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.syncScheduled = false
                guard !self.isTransitioning else { return }
                if self.wantsPresented() { self.present() } else { self.dismiss() }
            }
        }

        private func present() {
            guard hosting == nil, let anchor, let window = anchor.view.window,
                  var top = window.rootViewController else { return }
            while let next = top.presentedViewController, !next.isBeingDismissed { top = next }
            let hosting = UIHostingController(rootView: makeContent())
            hosting.modalPresentationStyle = .overFullScreen
            hosting.modalPresentationCapturesStatusBarAppearance = true
            hosting.view.backgroundColor = .clear
            // Hidden until the motion takes over, so the first mounted frame
            // never shows the player at full size.
            hosting.view.alpha = 0
            self.hosting = hosting
            let motion = CoverZoomMotion(surface: hosting.view) { [weak self] in
                self?.requestDismiss()
            }
            self.motion = motion
            isTransitioning = true
            top.present(hosting, animated: false) { [weak self] in
                motion.open { [weak self] in
                    self?.isTransitioning = false
                    self?.sync()
                }
            }
        }

        private func dismiss() {
            guard let hosting else { return }
            guard let presenter = hosting.presentingViewController else {
                finishDismissal()
                return
            }
            isTransitioning = true
            let unmount = { [weak self] in
                presenter.dismiss(animated: false) { [weak self] in
                    self?.finishDismissal()
                }
            }
            if let motion { motion.close(completion: unmount) } else { unmount() }
        }

        private func finishDismissal() {
            motion?.invalidate()
            motion = nil
            hosting = nil
            isTransitioning = false
            onDismiss()
            sync()
        }
    }
}

/// Drives the pre-iOS 18 player surface: grows it out of the mini player,
/// follows a downward drag from the handle, and shrinks it back into the mini
/// player with the release velocity. The surface keeps its full-size layout
/// throughout; only its transform and a rounded mask change, so the lyrics
/// and the Metal background are never laid out at in-between sizes.
///
/// The drag is a UIKit recognizer measured in window coordinates: the surface
/// itself moves under the finger, so its own coordinates cannot be used.
@MainActor
private final class CoverZoomMotion: NSObject, UIGestureRecognizerDelegate {
    private weak var surface: UIView?
    private let requestDismiss: () -> Void
    private let mask = UIView()
    private var animator: UIViewPropertyAnimator?
    private var fadeAnimator: UIViewPropertyAnimator?
    private var pan: UIPanGestureRecognizer?
    /// Normalized release velocity for the next close, set by a dismissing drag.
    private var pendingCloseVelocity: CGFloat = 0
    private var dragStart: CGFloat = 0

    private static let dragCornerRadius: CGFloat = 36
    private static let dragMinimumScale: CGFloat = 0.86

    private var reduceMotion: Bool { UIAccessibility.isReduceMotionEnabled }

    init(surface: UIView, requestDismiss: @escaping () -> Void) {
        self.surface = surface
        self.requestDismiss = requestDismiss
        super.init()
        mask.backgroundColor = .black
        mask.layer.cornerCurve = .continuous
        let pan = UIPanGestureRecognizer(target: self, action: #selector(handlePan(_:)))
        pan.delegate = self
        pan.maximumNumberOfTouches = 1
        pan.isEnabled = false
        surface.addGestureRecognizer(pan)
        self.pan = pan
    }

    func invalidate() {
        animator?.stopAnimation(true)
        animator = nil
        fadeAnimator?.stopAnimation(true)
        fadeAnimator = nil
        if let pan { pan.view?.removeGestureRecognizer(pan) }
        pan = nil
    }

    // MARK: Open / close

    func open(completion: @escaping () -> Void) {
        guard let surface else { completion(); return }
        surface.layoutIfNeeded()
        // The player takes the handle drag and the close from its first frame:
        // both interrupt the open, so the transition ends for the presenter now
        // rather than when the spring finally settles.
        defer {
            pan?.isEnabled = true
            completion()
        }
        if reduceMotion {
            run(UIViewPropertyAnimator(duration: 0.2, curve: .easeInOut) { surface.alpha = 1 }) { position in
                if position == .end { self.settleOpen() }
            }
            return
        }
        apply(collapsedGeometry(of: surface), to: surface)
        surface.alpha = 0
        // The player covers the mini player within the first few frames, so
        // the grow reads as one surface rather than a fade over a scale.
        UIView.animate(withDuration: 0.2, delay: 0, options: [.curveEaseOut, .allowUserInteraction]) {
            surface.alpha = 1
        }
        // Response-based like the iOS 18 zoom: a soft start, no hard stop.
        let animator = UIViewPropertyAnimator(
            duration: 0,
            timingParameters: Self.spring(response: 0.5, dampingFraction: 0.94)
        )
        animator.addAnimations { self.apply(.expanded(surface.bounds), to: surface) }
        run(animator) { position in
            if position == .end { self.settleOpen() }
        }
    }

    func close(completion: @escaping () -> Void) {
        guard let surface else { completion(); return }
        pan?.isEnabled = false
        let velocity = pendingCloseVelocity
        pendingCloseVelocity = 0
        animator?.stopAnimation(true)
        animator = nil
        if reduceMotion {
            run(UIViewPropertyAnimator(duration: 0.2, curve: .easeInOut) { surface.alpha = 0 }) { _ in
                completion()
            }
            return
        }
        if surface.mask == nil { installMask(on: surface, geometry: .expanded(surface.bounds)) }
        let target = collapsedGeometry(of: surface)
        let animator = UIViewPropertyAnimator(
            duration: 0,
            timingParameters: Self.spring(response: 0.42, dampingFraction: 1, velocity: velocity)
        )
        animator.addAnimations { self.apply(target, to: surface) }
        guard target.fades else {
            run(animator) { _ in completion() }
            return
        }
        // Cross-fade into the mini player as the shrink lands. The fade, not
        // the spring's long settling tail, ends the transition.
        var finished = false
        let finish = { [weak self] in
            guard !finished else { return }
            finished = true
            self?.animator?.stopAnimation(true)
            self?.animator = nil
            self?.fadeAnimator = nil
            completion()
        }
        let fade = UIViewPropertyAnimator(duration: 0.2, controlPoint1: CGPoint(x: 0.42, y: 0),
                                          controlPoint2: CGPoint(x: 1, y: 1)) { surface.alpha = 0 }
        fade.addCompletion { _ in finish() }
        fadeAnimator = fade
        run(animator) { _ in finish() }
        fade.startAnimation(afterDelay: velocity > 1 ? 0.1 : 0.16)
    }

    /// A spring described like SwiftUI's `.spring(response:dampingFraction:)`.
    /// UIKit derives the duration from it, so the motion never stops abruptly.
    private static func spring(response: CGFloat, dampingFraction: CGFloat,
                               velocity: CGFloat = 0) -> UISpringTimingParameters {
        let stiffness = pow(2 * .pi / response, 2)
        let damping = 4 * .pi * dampingFraction / response
        return UISpringTimingParameters(mass: 1, stiffness: stiffness, damping: damping,
                                        initialVelocity: CGVector(dx: velocity, dy: velocity))
    }

    private func settleOpen() {
        guard let surface else { return }
        surface.transform = .identity
        surface.alpha = 1
        surface.mask = nil
        pan?.isEnabled = true
    }

    private func run(_ animator: UIViewPropertyAnimator,
                     completion: @escaping (UIViewAnimatingPosition) -> Void) {
        self.animator = animator
        animator.addCompletion { [weak self] position in
            if self?.animator === animator { self?.animator = nil }
            completion(position)
        }
        animator.startAnimation()
    }

    // MARK: Geometry

    private struct Geometry {
        var transform: CGAffineTransform
        /// Visible part of the surface, in its own (untransformed) bounds.
        var maskFrame: CGRect
        var cornerRadius: CGFloat
        var fades = false

        static func expanded(_ bounds: CGRect) -> Geometry {
            Geometry(transform: .identity, maskFrame: bounds, cornerRadius: 0)
        }
    }

    /// The surface scaled to the mini player's width, centered on it, and
    /// masked to a strip of the mini player's height. Without a visible mini
    /// player it slides off the bottom edge instead.
    private func collapsedGeometry(of surface: UIView) -> Geometry {
        let bounds = surface.bounds
        guard let window = surface.window,
              let zoomSource = NowPlayingZoomSource.source(within: window.bounds),
              bounds.width > 0 else {
            return Geometry(
                transform: CGAffineTransform(translationX: 0, y: bounds.height),
                maskFrame: bounds,
                cornerRadius: 0
            )
        }
        // The surface fills the window, so window and surface centers agree.
        let source = zoomSource.frame
        let center = CGPoint(x: window.bounds.midX, y: window.bounds.midY)
        let scale = max(0.05, source.width / bounds.width)
        let height = min(bounds.height, source.height / scale)
        let radius = zoomSource.cornerRadius / scale
        return Geometry(
            transform: CGAffineTransform(translationX: source.midX - center.x, y: source.midY - center.y)
                .scaledBy(x: scale, y: scale),
            maskFrame: CGRect(x: 0, y: bounds.midY - height / 2, width: bounds.width, height: height),
            cornerRadius: radius,
            fades: true
        )
    }

    private func dragGeometry(of surface: UIView, translation: CGFloat) -> Geometry {
        let bounds = surface.bounds
        let progress = min(1, max(0, translation) / max(1, bounds.height))
        let scale = 1 - (1 - Self.dragMinimumScale) * progress
        let radius = Self.dragCornerRadius * min(1, translation / 40)
        return Geometry(
            transform: CGAffineTransform(translationX: 0, y: max(0, translation))
                .scaledBy(x: scale, y: scale),
            maskFrame: bounds,
            cornerRadius: max(0, radius) / scale
        )
    }

    private func installMask(on surface: UIView, geometry: Geometry) {
        mask.frame = geometry.maskFrame
        mask.layer.cornerRadius = geometry.cornerRadius
        surface.mask = mask
    }

    private func apply(_ geometry: Geometry, to surface: UIView) {
        if surface.mask == nil { surface.mask = mask }
        surface.transform = geometry.transform
        mask.frame = geometry.maskFrame
        mask.layer.cornerRadius = geometry.cornerRadius
    }

    // MARK: Drag

    /// Only drags that start on the handle row and head downward close the
    /// player; elsewhere drags stay with lyrics and controls.
    func gestureRecognizerShouldBegin(_ recognizer: UIGestureRecognizer) -> Bool {
        guard let pan = recognizer as? UIPanGestureRecognizer, let surface else { return false }
        let velocity = pan.velocity(in: surface.window)
        guard velocity.y > abs(velocity.x) else { return false }
        let inset = surface.safeAreaInsets
        let height = surface.bounds.height - inset.top - inset.bottom
        let handleInset = UIDevice.current.userInterfaceIdiom == .pad
            ? NowPlayingSplitGeometry.verticalInset(height: height)
            : NowPlayingPresentationMetrics.indicatorTopSpacing
        return pan.location(in: surface).y <= inset.top + handleInset + 44
    }

    func gestureRecognizer(_ recognizer: UIGestureRecognizer,
                           shouldRecognizeSimultaneouslyWith other: UIGestureRecognizer) -> Bool {
        true
    }

    @objc private func handlePan(_ pan: UIPanGestureRecognizer) {
        guard let surface else { return }
        // Window coordinates do not move with the surface under the finger.
        let translation = pan.translation(in: surface.window).y
        switch pan.state {
        case .began:
            // May interrupt the open; the drag continues from full size.
            animator?.stopAnimation(true)
            animator = nil
            surface.alpha = 1
            dragStart = translation
            if !reduceMotion { installMask(on: surface, geometry: .expanded(surface.bounds)) }
        case .changed:
            let distance = max(0, translation - dragStart)
            if reduceMotion {
                surface.alpha = 1 - min(1, distance / max(1, surface.bounds.height))
            } else {
                apply(dragGeometry(of: surface, translation: distance), to: surface)
            }
        case .ended, .cancelled, .failed:
            let distance = max(0, translation - dragStart)
            let velocity = pan.state == .ended ? pan.velocity(in: surface.window).y : 0
            if pan.state == .ended, NowPlayingPresentationMetrics.shouldDismiss(
                translation: distance,
                predictedTranslation: distance + velocity * 0.25
            ) {
                pendingCloseVelocity = closeVelocity(of: surface, velocity: velocity)
                requestDismiss()
            } else {
                springBack(surface, velocity: velocity)
            }
        default:
            break
        }
    }

    /// UIKit springs take velocity relative to the distance left to travel.
    private func closeVelocity(of surface: UIView, velocity: CGFloat) -> CGFloat {
        guard velocity > 0 else { return 0 }
        let current = surface.transform.ty
        let target = collapsedGeometry(of: surface).transform.ty
        let remaining = target - current
        guard abs(remaining) > 1 else { return 0 }
        return min(8, max(0, velocity / remaining))
    }

    private func springBack(_ surface: UIView, velocity: CGFloat) {
        if reduceMotion {
            run(UIViewPropertyAnimator(duration: 0.2, curve: .easeOut) { surface.alpha = 1 }) { _ in
                self.settleOpen()
            }
            return
        }
        let remaining = surface.transform.ty
        let relative = remaining > 1 ? min(8, max(0, -velocity / remaining)) : 0
        let animator = UIViewPropertyAnimator(
            duration: 0,
            timingParameters: Self.spring(response: 0.38, dampingFraction: 0.86, velocity: relative)
        )
        animator.addAnimations { self.apply(.expanded(surface.bounds), to: surface) }
        run(animator) { position in
            if position == .end { self.settleOpen() }
        }
    }
}

/// Before iOS 18 SwiftUI inherits UIKit's rotation animation and interpolates
/// the whole player's layout from the old size to the new one, so lyrics and
/// controls are drawn at in-between sizes and clipped while the screen turns.
/// While this flag is set the cover drops that inherited animation: the player
/// takes its final layout at once and turns with the window, like UIKit views.
@MainActor
enum CoverRotation {
    static let didEnd = Notification.Name("CoverRotationDidEnd")
    /// Counted, so a turn that starts before the previous one finishes keeps
    /// the flag set until both have ended.
    private static var active = 0
    static var isActive: Bool { active > 0 }

    static func begin() { active += 1 }

    static func end() {
        guard active > 0 else { return }
        active -= 1
        if active == 0 { NotificationCenter.default.post(name: didEnd, object: nil) }
    }
}

/// Before iOS 18 the cover's window bounds turn through in-between sizes while
/// its content already has the final layout, and the transparent cover would
/// show the page underneath at the corners. This embedded controller receives
/// the system's rotation callbacks and, for the length of the rotation only,
/// puts a snapshot of the player's own background behind the cover, scaled to
/// fill a square on the screen's long side. UIKit keeps it centered, so it
/// covers both orientations without being resized or rendered a second time.
private struct CoverRotationBackdrop: UIViewControllerRepresentable {
    func makeUIViewController(context: Context) -> Controller { Controller() }
    func updateUIViewController(_ controller: Controller, context: Context) {}

    final class Controller: UIViewController {
        private var backdrop: UIView?
        private var coverSurface: UIView? {
            var root: UIViewController = self
            while let parent = root.parent { root = parent }
            return root.view
        }

        override func loadView() {
            view = UIView()
            view.backgroundColor = .clear
            view.isUserInteractionEnabled = false
            view.isAccessibilityElement = false
        }

        override func viewWillTransition(to size: CGSize,
                                         with coordinator: UIViewControllerTransitionCoordinator) {
            // Set before super: UIKit resizes the cover right after this call.
            CoverRotation.begin()
            showBackdrop()
            super.viewWillTransition(to: size, with: coordinator)
            coordinator.animate(alongsideTransition: { [weak self] _ in
                // The cover already has its final layout, but UIKit also gives
                // the cover and the native views inside it (such as the Metal
                // background) frame animations from the old size. Drop them:
                // the content keeps its final size and only the cover's center
                // follows the turning window, so everything stays centered.
                guard let surface = self?.coverSurface else { return }
                Self.settle(surface)
                DispatchQueue.main.async { Self.settle(surface) }
            }) { [weak self] _ in
                CoverRotation.end()
                self?.hideBackdrop()
            }
        }

        override func viewWillDisappear(_ animated: Bool) {
            super.viewWillDisappear(animated)
            backdrop?.removeFromSuperview()
            backdrop = nil
        }

        private func showBackdrop() {
            guard let surface = coverSurface, let container = surface.superview,
                  let background = Self.firstView(of: FluidBackgroundNativeView.self, in: surface),
                  background.bounds.width > 0, background.bounds.height > 0,
                  let snapshot = background.snapshotView(afterScreenUpdates: false) else { return }
            backdrop?.removeFromSuperview()
            let screen = container.window?.screen.bounds.size ?? UIScreen.main.bounds.size
            let side = max(screen.width, screen.height)
            let square = UIView(frame: CGRect(x: 0, y: 0, width: side, height: side))
            square.center = CGPoint(x: container.bounds.midX, y: container.bounds.midY)
            square.autoresizingMask = [.flexibleLeftMargin, .flexibleRightMargin,
                                       .flexibleTopMargin, .flexibleBottomMargin]
            square.backgroundColor = .black
            square.isUserInteractionEnabled = false
            square.accessibilityElementsHidden = true
            // Aspect-fill the square with the current background.
            let scale = side / min(background.bounds.width, background.bounds.height)
            snapshot.center = CGPoint(x: side / 2, y: side / 2)
            snapshot.transform = CGAffineTransform(scaleX: scale, y: scale)
            square.addSubview(snapshot)
            container.insertSubview(square, belowSubview: surface)
            backdrop = square
        }

        private func hideBackdrop() {
            guard let square = backdrop else { return }
            backdrop = nil
            UIView.animate(withDuration: 0.15, animations: { square.alpha = 0 }) { _ in
                square.removeFromSuperview()
            }
        }

        private static func settle(_ surface: UIView) {
            surface.layer.removeAnimation(forKey: "bounds.size")
            surface.layer.removeAnimation(forKey: "bounds.origin")
            func settleDescendants(of layer: CALayer) {
                for child in layer.sublayers ?? [] {
                    for key in ["position", "bounds.size", "bounds.origin", "anchorPoint"] {
                        child.removeAnimation(forKey: key)
                    }
                    settleDescendants(of: child)
                }
            }
            settleDescendants(of: surface.layer)
        }

        private static func firstView<T: UIView>(of type: T.Type, in root: UIView) -> T? {
            if let match = root as? T { return match }
            for child in root.subviews {
                if let match = firstView(of: type, in: child) { return match }
            }
            return nil
        }
    }
}

public struct IOSMainWindow: View {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var player = PlayerService.shared
    @StateObject private var account = AccountStore.shared
    @StateObject private var settings = SettingsManager.shared
    @StateObject private var toasts = ToastCenter.shared
    @StateObject private var updater = IOSUpdater.shared
    @StateObject private var artworkStore = NowPlayingArtworkStore()
    @State private var pendingPlayerDestination: (() -> Void)?
    @Namespace private var nowPlayingTransition
    @Environment(\.colorScheme) private var systemColorScheme

    /// The app's intended scheme, read on this ancestor so the search-active
    /// tab environment can't invert it (#31).
    private var resolvedColorScheme: ColorScheme {
        settings.appearance.colorScheme ?? systemColorScheme
    }

    @State private var selectedTab: IOSTab = .home

    @State private var showLogin = false
    @State private var homePath: [Destination] = []
    @State private var searchPath: [Destination] = []
    @State private var libraryPath: [Destination] = []
    @State private var iPadPath: [Destination] = []

    public init() {}

    public var body: some View {
        presentationRoot
            .environment(\.nowPlayingTransitionNamespace, nowPlayingTransition)
            .modifier(OfflinePlaybackAlert(player: player, onDownloads: { openDestination(.downloaded) }, enabled: !player.showNowPlaying))
            .modifier(MeteredDownloadAlert(enabled: !player.showNowPlaying))
            .environmentObject(player)
            .environmentObject(account)
        .onChange(of: account.sessionRevision) { _ in
            homePath = []; searchPath = []; libraryPath = []; iPadPath = []
        }
            .environmentObject(settings)
            .environmentObject(toasts)
            .environmentObject(artworkStore)
            .tint(Theme.accent)
            .preferredColorScheme(settings.appearance.colorScheme)
            .environment(\.openLogin, { showLogin = true })
            .environment(\.openDestination, openDestination)
            .modifier(PlaybackLifecycle())
            .task {
                // Prepare independently of authentication/download setup and page transitions.
                _ = await ArtworkFlowRenderer.prepared()
            }
            .task {
                await DownloadManager.shared.start()
                await account.bootstrap()
                if settings.autoCheckUpdates {
                    IOSUpdater.shared.check(interactive: false)
                }
            }
            .task(id: needsSharedArtwork) {
                artworkStore.setArtworkNeeded(needsSharedArtwork)
            }
            .sheet(isPresented: $updater.showSheet) {
                IOSUpdaterSheet()
            }
            .sheet(isPresented: $showLogin) {
                LoginSheet()
                    .environmentObject(account)
                    .environmentObject(toasts)
            }
            .modifier(FirstLaunchOnboarding())
            .overlay(alignment: .top) {
                VStack(spacing: 8) {
                    if !player.showNowPlaying, let toast = toasts.current {
                        ToastView(toast: toast)
                            .transition(.move(edge: .top).combined(with: .opacity))
                    }
                    if !player.hasCurrentTrack {
                        PlaybackHandoffBanner()
                    }
                }
                .padding(.top, 8)
            }
            .animation(.spring(duration: 0.3), value: toasts.current)
            .animation(.spring(duration: 0.35), value: player.hasCurrentTrack)
    }

    /// The player loads its own artwork; the shared copy serves the ambient background.
    private var needsSharedArtwork: Bool {
        settings.showMainWindowAmbientBackground
    }

    @ViewBuilder
    private var presentationRoot: some View {
        if #available(iOS 18.0, *) {
            zoomNowPlayingRoot
        } else {
            coverNowPlayingRoot
        }
    }

    @available(iOS 18.0, *)
    private var zoomNowPlayingRoot: some View {
        appContent
            .fullScreenCover(isPresented: $player.showNowPlaying, onDismiss: finishPlayerDismissal) {
                systemNowPlayingPresentation
                    .navigationTransition(
                        .zoom(
                            sourceID: NowPlayingTransitionID.surface,
                            in: nowPlayingTransition
                        )
                    )
            }
    }

    @ViewBuilder
    private var systemNowPlayingPresentation: some View {
        if #available(iOS 16.4, *) {
            nowPlayingPresentation()
                .presentationBackground(.clear)
        } else {
            nowPlayingPresentation()
        }
    }

    /// iOS 16–17 present the player over the full screen through UIKit, so the
    /// system owns sizing, safe areas and rotation while the page stays in
    /// place underneath. The system zoom transition is iOS 18+, so the cover
    /// zooms out of the mini player and closes by handle drag on its own.
    private var coverNowPlayingRoot: some View {
        appContent
            .background(
                OverFullScreenCover(isPresented: $player.showNowPlaying, onDismiss: finishPlayerDismissal) {
                    systemNowPlayingPresentation
                        .transaction { transaction in
                            guard CoverRotation.isActive else { return }
                            transaction.animation = nil
                            transaction.disablesAnimations = true
                        }
                        .background(CoverRotationBackdrop())
                        // A UIKit presentation does not inherit this tree's environment.
                        .environment(\.nowPlayingTransitionNamespace, nowPlayingTransition)
                        .environmentObject(player)
                        .environmentObject(account)
                        .environmentObject(settings)
                        .environmentObject(toasts)
                        .environmentObject(artworkStore)
                        .tint(Theme.accent)
                        .preferredColorScheme(settings.appearance.colorScheme)
                        .environment(\.openLogin, { showLogin = true })
                        .environment(\.openDestination, openDestination)
                        // iPadOS 16 does not keep scenePhase current inside a
                        // UIKit-presented host; pass the window's own phase.
                        .environment(\.scenePhase, scenePhase)
                }
            )
    }

    private func openPlayerDestination(_ destination: Destination) {
        guard player.showNowPlaying else {
            openDestination(destination)
            return
        }
        pendingPlayerDestination = { openDestination(destination) }
        player.showNowPlaying = false
    }

    private func finishPlayerDismissal() {
        let destination = pendingPlayerDestination
        pendingPlayerDestination = nil
        destination?()
    }

    @ViewBuilder
    private var appContent: some View {
        if UIDevice.current.userInterfaceIdiom == .pad {
            if #available(iOS 26.0, *) {
                NativeIPadRoot(path: $iPadPath)
            } else {
                LegacyIPadRoot(path: $iPadPath)
            }
        } else {
            // iPhone 三个标签页（推荐 / 探索 / 我的）以前没有主题背景：主题背景只画在
            // MainWindow 里，而 MainWindow 只在 iPad 上用，iPhone 走这里的 tabInterface，
            // 所以三个页面一直透出系统窗口底色（深色下纯黑），换什么主题都没用。
            // 在这里垫一层主题背景，换主题立刻跟着变；歌单详情页自带封面背景盖在上面，不受影响。
            tabInterface
                .background(CodaThemeBackgroundView())
                .overlay {
                    if settings.showMainWindowAmbientBackground {
                        MainWindowAmbientBackground(
                            colors: artworkStore.colors,
                            intensity: settings.mainWindowAmbientBackgroundIntensity
                        )
                        .ignoresSafeArea()
                    }
                }
        }
    }

    private func nowPlayingPresentation(
        showsDismissIndicator: Bool = true
    ) -> some View {
        IOSNowPlayingPresentation(
            isPresented: $player.showNowPlaying,
            showsDismissIndicator: showsDismissIndicator,
            deferDismissCompletion: { pendingPlayerDestination = $0 }
        ) {
            NowPlayingView(onOpenDestination: openPlayerDestination, backgroundColorScheme: resolvedColorScheme)
                .environmentObject(player)
                .environmentObject(account)
                .environmentObject(settings)
        }
        .modifier(NowPlayingLoginPresenter())
        // The cover sits above the root overlay, so it shows toasts itself.
        .modifier(ToastOverlay())
    }

    @ViewBuilder
    private var tabInterface: some View {
        #if compiler(>=6.2)
        if #available(iOS 26.0, *) {
            iOS26TabInterface
        } else {
            customTabInterface
        }
        #else
        customTabInterface
        #endif
    }

    #if compiler(>=6.2)
    @available(iOS 26.0, *)
    private var iOS26TabInterface: some View {
        iOS26TabView
            .tabBarMinimizeBehavior(.never)
            .modifier(MiniPlayerAccessoryModifier(
                transitionNamespace: nowPlayingTransition,
                colorScheme: resolvedColorScheme
            ))
    }

    @available(iOS 26.0, *)
    private var iOS26TabView: some View {
        TabView(selection: $selectedTab) {
            Tab("推荐", systemImage: "house", value: .home) {
                tabStack(.home) { HomeView() }
            }
            // A regular tab: the search field lives in the page, not the bar,
            // and the 精选 playlist shelves sit under it.
            Tab("探索", systemImage: "magnifyingglass", value: .search) {
                tabStack(.search) { SearchView(query: "").id(account.sessionRevision) }
            }
            Tab("我的", systemImage: "person.crop.circle", value: .library) {
                tabStack(.library) { LibraryView(showLogin: $showLogin) }
            }
        }
    }
    #endif

    private var customTabInterface: some View {
        ZStack(alignment: .bottom) {
            ZStack {
                page(.home) { tabStack(.home) { HomeView() } }
                page(.search) { tabStack(.search) { SearchView(query: "").id(account.sessionRevision) } }
                page(.library) { tabStack(.library) { LibraryView(showLogin: $showLogin) } }
            }

            legacyBottomBar
                .padding(.bottom, 6)
        }
    }

    /// The mini player sits above a tab bar that always stays expanded.
    private var legacyBottomBar: some View {
        VStack(spacing: Theme.Layout.FloatingChrome.barSpacing) {
            IOSMiniPlayerBar(presentation: .legacyOverlay)
                .frame(height: Theme.Layout.FloatingChrome.miniPlayerHeight)
                .nowPlayingTransitionSource(in: nowPlayingTransition)

            GlassTabBar(items: IOSTab.barItems, selection: $selectedTab, onReselect: popToRoot)
                .frame(height: Theme.Layout.FloatingChrome.tabBarHeight)
        }
        .padding(.horizontal, Theme.Layout.FloatingChrome.horizontalMargin)
    }

    private func popToRoot(_ tab: IOSTab) {
        switch tab {
        case .home: homePath = []
        case .search: searchPath = []
        case .library: libraryPath = []
        }
    }

    private func openDestination(_ destination: Destination) {
        player.showNowPlaying = false
        if UIDevice.current.userInterfaceIdiom == .pad {
            iPadPath.appendIfNotCurrent(destination)
            return
        }

        let path = binding(for: selectedTab)
        var destinations = path.wrappedValue
        destinations.appendIfNotCurrent(destination)
        path.wrappedValue = destinations
    }

    @ViewBuilder
    private func tabStack<Content: View>(
        _ tab: IOSTab,
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        NavigationStack(path: binding(for: tab)) {
            content().appDestinations()
        }
    }

    @ViewBuilder
    private func page<Content: View>(
        _ tab: IOSTab,
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        content()
            .opacity(selectedTab == tab ? 1 : 0)
            .allowsHitTesting(selectedTab == tab)
            .zIndex(selectedTab == tab ? 1 : 0)
    }

    private func binding(for tab: IOSTab) -> Binding<[Destination]> {
        switch tab {
        case .home: return $homePath
        case .search: return $searchPath
        case .library: return $libraryPath
        }
    }
}

private enum NowPlayingTransitionID {
    static let surface = "now-playing-surface"
}

/// Login requested from the player must be presented by the player itself:
/// the main window is already presenting its full-screen cover on iOS 18+.
/// Keeping this state here also makes cancellation return to the same player.
private struct NowPlayingLoginPresenter: ViewModifier {
    @EnvironmentObject private var account: AccountStore
    @State private var showLogin = false

    func body(content: Content) -> some View {
        content
            .environment(\.openLogin, { showLogin = true })
            .sheet(isPresented: $showLogin) {
                LoginSheet()
                    .environmentObject(account)
            }
    }
}

// MARK: - Mini player bar for iOS

#if compiler(>=6.2)
@available(iOS 26.0, *)
private struct MiniPlayerAccessoryModifier: ViewModifier {
    let transitionNamespace: Namespace.ID
    let colorScheme: ColorScheme

    /// Always attached so the TabView keeps its identity: adding the
    /// accessory later would rebuild every tab on first playback.
    func body(content: Content) -> some View {
        content.tabViewBottomAccessory {
            IOSMiniPlayerAccessory(transitionNamespace: transitionNamespace)
                .environment(\.colorScheme, colorScheme)
        }
    }
}

@available(iOS 26.0, *)
private struct IOSMiniPlayerAccessory: View {
    @Environment(\.tabViewBottomAccessoryPlacement) private var placement
    let transitionNamespace: Namespace.ID

    var body: some View {
        IOSMiniPlayerBar(presentation: presentation)
            .nowPlayingTransitionSource(in: transitionNamespace)
    }

    private var presentation: IOSMiniPlayerBar.Presentation {
        let placementIsInline = placement.map { $0 == .inline }
        return NowPlayingPresentationMetrics.shouldUseInlineMiniPlayerLayout(
            placementIsInline: placementIsInline
        ) ? .inlineAccessory : .bottomAccessory
    }
}
#endif

extension View {
    @ViewBuilder
    func nowPlayingTransitionSource(in namespace: Namespace.ID?) -> some View {
        if #available(iOS 18.0, *), let namespace {
            matchedTransitionSource(
                id: NowPlayingTransitionID.surface,
                in: namespace
            )
        } else {
            // Pre-18 the cover zooms out of the mini player by hand (see
            // CoverZoomMotion), so it needs the mini player's frame.
            modifier(NowPlayingZoomSourceReporter(cornerRadius: Theme.Layout.iPadChromeCornerRadius))
        }
    }
}

#endif
