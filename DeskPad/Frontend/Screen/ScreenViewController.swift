//
//  ScreenViewController.swift
//  DeskPad
//
//  @agents-index Window's screen-content view controller. CR-0001 Phase 4
//  reduces this file to its UI-shell responsibilities: it installs the
//  `MetalLayerHostView` produced by `CaptureRenderCoordinator`, observes
//  the ReSwift `ScreenViewData` fragment, and forwards
//  resolution / scale-factor updates to the coordinator. Capture API
//  knowledge, virtual-display construction, and frame delivery now live in
//  the Capture and Render subsystems.
//

import Cocoa
import ReSwift

enum ScreenViewAction: Action {
    case setDisplayID(CGDirectDisplayID)
}

class ScreenViewController: SubscriberViewController<ScreenViewData>, NSWindowDelegate {
    override func loadView() {
        view = NSView()
        view.wantsLayer = true
        view.addGestureRecognizer(NSClickGestureRecognizer(target: self, action: #selector(didClickOnScreen)))
    }

    private var display: CGVirtualDisplay!
    private var coordinator: CaptureRenderCoordinator!
    private var isWindowHighlighted = false
    private var previousResolution: CGSize?
    private var previousScaleFactor: CGFloat?

    override func viewDidLoad() {
        super.viewDidLoad()

        // Build the virtual display via the extracted factory; the controller
        // no longer carries the display-construction knowledge.
        let (display, displayID) = VirtualDisplayFactory.makeDisplay()
        self.display = display
        store.dispatch(ScreenViewAction.setDisplayID(displayID))

        // Construct the capture/render coordinator and install its host view
        // as the controller's content view's child so the CAMetalLayer is the
        // surface the compositor sees.
        let coordinator = CaptureRenderCoordinator()
        coordinator.bindDisplay(displayID)
        // CR-0002 FR-6: install the active backend's host view, not the
        // fixed Metal host view. A `--launch arg` or persisted preference
        // that selects AVSBDL has already run `switchBackend(.avsbdl)`
        // inside `coordinator.init`, so `currentBackend.hostView` is the
        // AVSBDL-backed view by this point. The Metal pacer is still
        // attached to its layer because the Metal ensemble owns the
        // CR-0001 pull model; for AVSBDL the pacer is harmless.
        let host = coordinator.currentBackend.hostView
        host.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host)
        NSLayoutConstraint.activate([
            host.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.topAnchor.constraint(equalTo: view.topAnchor),
            host.bottomAnchor.constraint(equalTo: view.bottomAnchor),
        ])
        coordinator.pacer.attach(toMetalLayer: coordinator.hostView.metalLayer)
        ScreenConfigurationEvents.shared.subscribe { [weak coordinator] event in
            guard let coordinator else { return }
            Task { @MainActor in
                await coordinator.applyConfiguration(
                    resolution: event.resolution,
                    scaleFactor: event.scaleFactor
                )
            }
        }
        // Up-front permission check so the user sees the TCC prompt on first
        // launch rather than only after a stream error.
        _ = coordinator.evaluatePermission()
        self.coordinator = coordinator
    }

    override func update(with viewData: ScreenViewData) {
        if viewData.isWindowHighlighted != isWindowHighlighted {
            isWindowHighlighted = viewData.isWindowHighlighted
            view.window?.backgroundColor = isWindowHighlighted
                ? NSColor(named: "TitleBarActive")
                : NSColor(named: "TitleBarInactive")
            if isWindowHighlighted {
                view.window?.orderFrontRegardless()
            }
        }

        if
            viewData.resolution != .zero,
            viewData.resolution != previousResolution
            || viewData.scaleFactor != previousScaleFactor
        {
            previousResolution = viewData.resolution
            previousScaleFactor = viewData.scaleFactor
            view.window?.setContentSize(viewData.resolution)
            view.window?.contentAspectRatio = viewData.resolution
            view.window?.center()
            // Route the new resolution/scale-factor pair through the
            // coordinator so the capture stream is reconfigured in place
            // (FR-6, AC-9) and the host view's drawable is resized.
            let resolution = viewData.resolution
            let scaleFactor = viewData.scaleFactor
            if let coordinator {
                Task { @MainActor in
                    await coordinator.applyConfiguration(
                        resolution: resolution,
                        scaleFactor: scaleFactor
                    )
                }
            }
        }
    }

    func windowWillResize(_ window: NSWindow, to frameSize: NSSize) -> NSSize {
        let snappingOffset: CGFloat = 30
        let contentSize = window.contentRect(forFrameRect: NSRect(origin: .zero, size: frameSize)).size
        guard
            let screenResolution = previousResolution,
            abs(contentSize.width - screenResolution.width) < snappingOffset
        else {
            return frameSize
        }
        return window.frameRect(forContentRect: NSRect(origin: .zero, size: screenResolution)).size
    }

    @objc private func didClickOnScreen(_ gestureRecognizer: NSGestureRecognizer) {
        guard let screenResolution = previousResolution else {
            return
        }
        let clickedPoint = gestureRecognizer.location(in: view)
        let onScreenPoint = NSPoint(
            x: clickedPoint.x / view.frame.width * screenResolution.width,
            y: (view.frame.height - clickedPoint.y) / view.frame.height * screenResolution.height
        )
        store.dispatch(MouseLocationAction.requestMove(toPoint: onScreenPoint))
    }
}
