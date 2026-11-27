import MapKit

final class RidePlaceAnnotation: MKPointAnnotation {}

extension MKMapView {
    /// MapKit also sends region changes for playback. Only actual pan input detaches the camera.
    @MainActor var rideHasPanInput: Bool {
        #if os(macOS)
        guard let event = NSApp.currentEvent, event.window === window else { return false }
        return event.type == .leftMouseDragged ||
            (event.type == .scrollWheel && event.hasPreciseScrollingDeltas && !event.modifierFlags.contains(.control))
        #else
        func panning(_ view: UIView) -> Bool {
            if (view.gestureRecognizers ?? []).contains(where: {
                guard let pan = $0 as? UIPanGestureRecognizer else { return false }
                return (pan.state == .began || pan.state == .changed) && pan.numberOfTouches == 1
            }) { return true }
            return view.subviews.contains(where: panning)
        }
        return panning(self)
        #endif
    }
}
