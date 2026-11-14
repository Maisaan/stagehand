import CoreGraphics

/// Where the focus outline's panels go, in screen coordinates with y growing downward.
///
/// PassKit stops Touch ID while any other process's window lies over its payment sheet,
/// however transparent (2026-11-14 logs: `Payment UI is occluded: true`). So the outline
/// is several thin panels along the window's edges, never one panel over its content.
public enum FocusOutlineGeometry {
    public static let strokeWidth: CGFloat = 2

    /// The top and bottom bands are as deep as the corner radius so they hold the corner
    /// arcs; the sides are one stroke wide. Nothing overlaps `cutout`, the window's
    /// attached sheet, so the outline stops at its edge.
    public static func panelFrames(window: CGRect, cornerRadius: CGFloat, cutout: CGRect? = nil) -> [CGRect] {
        guard window.width > 0, window.height > 0 else { return [] }
        let radius = min(max(0, cornerRadius), min(window.width, window.height) / 2)
        let band = min(max(strokeWidth, radius.rounded(.up)), window.height / 2)
        let stroke = min(strokeWidth, window.width / 2)
        var strips = [
            CGRect(x: window.minX, y: window.minY, width: window.width, height: band),
            CGRect(x: window.minX, y: window.maxY - band, width: window.width, height: band),
        ]
        let sideHeight = window.height - 2 * band
        if sideHeight > 0 {
            strips.append(CGRect(x: window.minX, y: window.minY + band, width: stroke, height: sideHeight))
            strips.append(CGRect(x: window.maxX - stroke, y: window.minY + band, width: stroke, height: sideHeight))
        }
        guard let cutout else { return strips }
        return strips.flatMap { subtract(cutout, from: $0) }
    }

    /// The parts of `rect` outside `hole`: at most a band above and below it, and a piece
    /// on either side between those bands.
    static func subtract(_ hole: CGRect, from rect: CGRect) -> [CGRect] {
        let overlap = rect.intersection(hole)
        guard !overlap.isNull, overlap.width > 0, overlap.height > 0 else { return [rect] }
        return [
            CGRect(x: rect.minX, y: rect.minY, width: rect.width, height: overlap.minY - rect.minY),
            CGRect(x: rect.minX, y: overlap.maxY, width: rect.width, height: rect.maxY - overlap.maxY),
            CGRect(x: rect.minX, y: overlap.minY, width: overlap.minX - rect.minX, height: overlap.height),
            CGRect(x: overlap.maxX, y: overlap.minY, width: rect.maxX - overlap.maxX, height: overlap.height),
        ].filter { $0.width > 0 && $0.height > 0 }
    }
}
