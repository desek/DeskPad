//
//  capture.virtual_display_factory.swift
//  DeskPad
//
//  @agents-index Factory that constructs the private `CGVirtualDisplay`
//  DeskPad mirrors. Extracted from `ScreenViewController.viewDidLoad` in
//  CR-0001 Phase 4 so the view controller no longer carries
//  display-construction knowledge: the coordinator builds the display, the
//  view controller only attaches the host view and observes ReSwift state.
//
//  Keeping this in `Backend/Capture/` reflects that the virtual display is
//  the capture source, not a UI concern. The supported modes list is the
//  same one that previously lived inline in the view controller; it is
//  reproduced verbatim so the visible behaviour is unchanged.
//

import Cocoa
import Foundation

/// Stateless factory that creates the `CGVirtualDisplay` DeskPad captures.
/// The factory owns the supported-modes catalogue and the descriptor
/// parameters (name, pixel cap, physical size, vendor/product IDs).
public enum VirtualDisplayFactory {
    /// Build the virtual display and return both the live instance and its
    /// `CGDirectDisplayID`. The caller is responsible for retaining the
    /// returned `CGVirtualDisplay`; releasing it tears the display down.
    ///
    /// - Returns: Tuple `(display, displayID)` where `displayID` is what
    ///   ScreenCaptureKit's `SCContentFilter` resolution path consumes.
    public static func makeDisplay() -> (CGVirtualDisplay, CGDirectDisplayID) {
        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.setDispatchQueue(DispatchQueue.main)
        descriptor.name = "DeskPad Display"
        descriptor.maxPixelsWide = 5120
        descriptor.maxPixelsHigh = 2160
        descriptor.sizeInMillimeters = CGSize(width: 1600, height: 1000)
        descriptor.productID = 0x1234
        descriptor.vendorID = 0x3456
        descriptor.serialNum = 0x0001

        let display = CGVirtualDisplay(descriptor: descriptor)

        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = 1
        settings.modes = supportedModes()
        display.apply(settings)

        return (display, display.displayID)
    }

    /// The supported display modes catalogue. Kept identical to the prior
    /// inline list in `ScreenViewController` so user-facing resolutions do
    /// not regress with the cutover.
    public static func supportedModes() -> [CGVirtualDisplayMode] {
        return [
            // 32:9
            CGVirtualDisplayMode(width: 5120, height: 1440, refreshRate: 60),
            // 21:9 (239:100, 12:5)
            CGVirtualDisplayMode(width: 5120, height: 2160, refreshRate: 60),
            CGVirtualDisplayMode(width: 3840, height: 1600, refreshRate: 60),
            CGVirtualDisplayMode(width: 3440, height: 1440, refreshRate: 60),
            // 16:9
            CGVirtualDisplayMode(width: 3840, height: 2160, refreshRate: 60),
            CGVirtualDisplayMode(width: 2560, height: 1440, refreshRate: 60),
            CGVirtualDisplayMode(width: 1920, height: 1080, refreshRate: 60),
            CGVirtualDisplayMode(width: 1600, height: 900, refreshRate: 60),
            CGVirtualDisplayMode(width: 1366, height: 768, refreshRate: 60),
            CGVirtualDisplayMode(width: 1280, height: 720, refreshRate: 60),
            // 16:10
            CGVirtualDisplayMode(width: 2560, height: 1600, refreshRate: 60),
            CGVirtualDisplayMode(width: 1920, height: 1200, refreshRate: 60),
            CGVirtualDisplayMode(width: 1680, height: 1050, refreshRate: 60),
            CGVirtualDisplayMode(width: 1440, height: 900, refreshRate: 60),
            CGVirtualDisplayMode(width: 1280, height: 800, refreshRate: 60),
        ]
    }
}
