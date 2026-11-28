import MapKit

final class RidePlaceAnnotation: MKPointAnnotation {}

extension MKMapView {
    @MainActor var hasLineFramingGesture: Bool {
        #if os(macOS)
        guard let event = NSApp.currentEvent, event.window === window else { return false }
        return [.leftMouseDragged, .scrollWheel, .magnify, .smartMagnify].contains(event.type)
        #else
        func manipulating(_ view: UIView) -> Bool {
            if (view.gestureRecognizers ?? []).contains(where: {
                ($0 is UIPanGestureRecognizer || $0 is UIPinchGestureRecognizer) &&
                    ($0.state == .began || $0.state == .changed)
            }) { return true }
            return view.subviews.contains(where: manipulating)
        }
        return manipulating(self)
        #endif
    }
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
