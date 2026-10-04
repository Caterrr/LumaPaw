import AppKit
import simd

/// A small, noninteractive camera monitor. It displays one index marker OR one
/// palm marker; image-space coordinates never use the game's active-area mapping.
final class CameraPreviewView: NSView {
    private var enabled = false
    private var previewFrame: CameraPreviewFrame?
    private var cameraStatus = "Camera off"
    private var throwStatus:String?
    func setThrowStatus(_ value:String?){
        guard value != throwStatus else{return};throwStatus=value;needsDisplay=true
    }
    override var isOpaque: Bool { false }
    override var intrinsicContentSize: NSSize { NSSize(width: 252, height: 204) }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func setEnabled(_ value: Bool) {
        enabled = value
        if !value { previewFrame = nil; cameraStatus = "Camera off";throwStatus=nil }
        else if cameraStatus == "Camera off" { cameraStatus = "Starting camera" }
        needsDisplay = true
    }
    func update(frame: CameraPreviewFrame?) {
        guard enabled else { return }
        self.previewFrame = frame
        needsDisplay = true
    }
    func setStatus(_ text: String) {
        cameraStatus = text
        needsDisplay = true
    }

    static func aspectFitRect(imageSize: CGSize, in available: NSRect) -> NSRect {
        guard imageSize.width > 0, imageSize.height > 0, available.width > 0, available.height > 0 else { return .zero }
        let scale = min(available.width / imageSize.width, available.height / imageSize.height)
        let size = NSSize(width: imageSize.width * scale, height: imageSize.height * scale)
        return NSRect(x: available.midX - size.width / 2, y: available.midY - size.height / 2,
                      width: size.width, height: size.height)
    }
    static func markerPosition(_ point: SIMD2<Float>, in imageRect: NSRect) -> NSPoint {
        NSPoint(x: imageRect.minX + CGFloat(point.x) * imageRect.width,
                y: imageRect.minY + CGFloat(point.y) * imageRect.height)
    }

    override func draw(_ dirtyRect: NSRect) {
        guard bounds.width > 2, bounds.height > 2 else { return }
        let card = NSBezierPath(roundedRect: bounds.insetBy(dx: 0.75, dy: 0.75), xRadius: 13, yRadius: 13)
        NSColor(calibratedWhite: 0.045, alpha: 0.96).setFill(); card.fill()
        NSColor(calibratedWhite: 0.23, alpha: 0.8).setStroke(); card.lineWidth = 0.75; card.stroke()
        let imageArea = NSRect(x: 7, y: 37, width: max(1, bounds.width - 14), height: max(1, bounds.height - 44))
        var accent = NSColor(calibratedWhite: 0.55, alpha: 1)
        var status: String
        if enabled, let frame = previewFrame {
            let imageRect = Self.aspectFitRect(imageSize: CGSize(width: frame.image.width, height: frame.image.height), in: imageArea)
            NSGraphicsContext.saveGraphicsState()
            NSBezierPath(roundedRect: imageArea, xRadius: 8, yRadius: 8).addClip()
            NSColor.black.setFill(); imageArea.fill()
            if let context = NSGraphicsContext.current?.cgContext {
                context.interpolationQuality = .medium
                // CGImage has already been mirrored in HandTracker. No UI flip.
                context.draw(frame.image, in: imageRect)
            }
            // A quiet guide shows the 84% area used by the control mapping.
            let activeArea = NSBezierPath(rect: imageRect.insetBy(dx: imageRect.width * 0.08, dy: imageRect.height * 0.08))
            activeArea.setLineDash([3, 4], count: 2, phase: 0)
            activeArea.lineWidth = 0.65
            NSColor(white: 0.9, alpha: 0.22).setStroke(); activeArea.stroke()
            switch frame.intent {
            case .pointing:
                status = "Point to lead"
                accent = NSColor(calibratedRed: 0.45, green: 0.90, blue: 1, alpha: 1)
                if let tip = frame.tip {
                    let p = Self.markerPosition(tip, in: imageRect)
                    drawMarker(at: p, radius: 10, palm: false, color: accent)
                }
            case .palm:
                status = "Palm to pet"
                accent = NSColor(calibratedRed: 1, green: 0.79, blue: 0.43, alpha: 1)
                if let palm = frame.palm {
                    let p = Self.markerPosition(palm, in: imageRect)
                    let radius = min(48, max(13, CGFloat(frame.palmRadius) * imageRect.height))
                    drawMarker(at: p, radius: radius, palm: true, color: accent)
                }
            case .uncertain:
                // Partial/ambiguous detections do not show an unmapped cursor.
                status = frame.fist != nil ? "Hold fist for 1 second" : (frame.confidence > 0 ? "Adjust your hand" : "No hand detected")
                if let fist = frame.fist {
                    accent = NSColor(calibratedRed: 0.76, green: 1, blue: 0.64, alpha: 1)
                    drawMarker(at: Self.markerPosition(fist, in: imageRect), radius: 9, palm: false, color: accent)
                }
            }
            NSGraphicsContext.restoreGraphicsState()
        } else {
            status = placeholderStatus()
            NSColor(calibratedWhite: 0.07, alpha: 1).setFill()
            NSBezierPath(roundedRect: imageArea, xRadius: 8, yRadius: 8).fill()
            if let image = NSImage(systemSymbolName: enabled ? "video" : "video.slash", accessibilityDescription: nil) {
                image.draw(in: NSRect(x: imageArea.midX - 14, y: imageArea.midY + 2, width: 28, height: 23),
                           from: .zero, operation: .sourceOver, fraction: 0.42)
            }
            let note = enabled ? "Bring one hand into view" : "Choose Hand to see the camera preview"
            drawText(note, at: NSPoint(x: imageArea.minX + 8, y: imageArea.midY - 24),
                     width: imageArea.width - 16, size: 10, color: NSColor(white: 0.50, alpha: 1), centered: true)
        }
        if enabled,let throwStatus{status=throwStatus}
        accent.setFill()
        NSBezierPath(ovalIn: NSRect(x: 13, y: 16, width: 5, height: 5)).fill()
        drawText(status, at: NSPoint(x: 25, y: 11), width: max(1, bounds.width - (throwStatus == nil ? 98:34)),
                 size: 11, color: NSColor(white: 0.88, alpha: 1))
        if throwStatus == nil {drawText("On device", at: NSPoint(x: bounds.width - 62, y: 11), width: 49,
                 size: 9, color: NSColor(white: 0.40, alpha: 1), centered: true)}
        toolTip = enabled ? cameraStatus : "The camera is off until you choose Hand."
        setAccessibilityLabel("Camera preview: " + status)
    }

    private func placeholderStatus() -> String {
        guard enabled else { return "Camera off" }
        let text=cameraStatus.lowercased()
        if text.contains("permission") || text.contains("allow") || text.contains("restricted") {return "Camera permission needed"}
        if text.contains("paused") {return "Camera paused"}
        if text.contains("unavailable") || text.contains("could not") || text.contains("no camera") || text.contains("interrupted") || text.contains("in use") {return "Camera unavailable"}
        if text.contains("starting") {return "Starting camera"}
        return "No hand detected"
    }
    private func drawMarker(at point: NSPoint, radius: CGFloat, palm: Bool, color: NSColor) {
        let rect = NSRect(x: point.x - radius, y: point.y - radius, width: radius * 2, height: radius * 2)
        color.withAlphaComponent(palm ? 0.12 : 0.20).setFill(); NSBezierPath(ovalIn: rect).fill()
        color.withAlphaComponent(0.95).setStroke()
        let ring = NSBezierPath(ovalIn: rect); ring.lineWidth = palm ? 2 : 1.6; ring.stroke()
        NSColor.black.withAlphaComponent(0.55).setFill()
        NSBezierPath(ovalIn: NSRect(x: point.x - 4, y: point.y - 4, width: 8, height: 8)).fill()
        color.setFill(); NSBezierPath(ovalIn: NSRect(x: point.x - 2.3, y: point.y - 2.3, width: 4.6, height: 4.6)).fill()
    }
    private func drawText(_ text: String, at origin: NSPoint, width: CGFloat, size: CGFloat,
                          color: NSColor, centered: Bool = false) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = centered ? .center : .left
        paragraph.lineBreakMode = .byTruncatingTail
        (text as NSString).draw(in: NSRect(x: origin.x, y: origin.y, width: width, height: size + 6),
                               withAttributes: [.font: LumaStyle.font(size),
                                                .foregroundColor: color, .paragraphStyle: paragraph])
    }
}
