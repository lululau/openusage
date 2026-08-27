import AppKit
import CoreImage
import CoreImage.CIFilterBuiltins
import SwiftUI

/// Sizes tuned to match macOS Battery widget medium layout.
enum BatteryWidgetMetrics {
    /// Ring outer diameter (medium / 4-up).
    static let ringSize: CGFloat = 56
    static let ringSizeSmall: CGFloat = 50
    static let ringSizeLarge: CGFloat = 58
    /// Stroke width of a single-ring card.
    static let lineWidth: CGFloat = 4.5
    /// Slightly thinner strokes when drawing concentric multi-rings.
    static let multiLineWidth: CGFloat = 3.2
    /// Icon inside the ring (relative to ring diameter).
    static let iconRatio: CGFloat = 0.40

    /// Diameter shrink between concentric rings (index → index+1).
    /// SwiftUI strokes are centered on the path, so clear gap between ring
    /// edges = (centerline spacing) − strokeWidth. We want clear gap == stroke
    /// width ⇒ centerline spacing = 2×stroke ⇒ diameter step = 4×stroke.
    static func multiRingDiameterStep(strokeWidth: CGFloat) -> CGFloat {
        4 * strokeWidth
    }
    /// Primary value under ring ("94%" / "499") — Battery uses ~13pt.
    static let valueFontSize: CGFloat = 13
    /// Plugin name under value.
    static let nameFontSize: CGFloat = 11
    static let rowSpacing: CGFloat = 12
    static let hPadding: CGFloat = 14
    static let vPadding: CGFloat = 14
}

struct ProviderRingView: View {
    let item: UsageRingItem
    var size: CGFloat = BatteryWidgetMetrics.ringSize
    var lineWidth: CGFloat = BatteryWidgetMetrics.lineWidth
    var showName: Bool = true
    var period: AntigravityWidgetPeriod = .fiveHour

    private var layers: [UsageRingLayer] {
        item.resolvedRings(period: period)
    }

    private var isMulti: Bool {
        layers.count >= 2
    }

    private var strokeWidth: CGFloat {
        isMulti ? BatteryWidgetMetrics.multiLineWidth : lineWidth
    }

    private var valueText: String {
        item.displayPercentText(period: period)
    }

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                ForEach(Array(layers.enumerated()), id: \.offset) { index, layer in
                    let diameter = ringDiameter(index: index, count: layers.count)
                    let progress = clamped(layer.fraction)
                    let color = strokeColor(for: layer, progress: progress, index: index)

                    Circle()
                        .stroke(Color.primary.opacity(0.18), lineWidth: strokeWidth)
                        .frame(width: diameter, height: diameter)

                    Circle()
                        .trim(from: 0, to: progress)
                        .stroke(
                            color,
                            style: StrokeStyle(lineWidth: strokeWidth, lineCap: .round)
                        )
                        .rotationEffect(.degrees(-90))
                        .frame(width: diameter, height: diameter)
                }

                PluginIconView(item: item, side: size * BatteryWidgetMetrics.iconRatio)
            }
            .frame(width: size, height: size)

            // Single value line (Battery style) + optional name
            VStack(spacing: 2) {
                Text(valueText)
                    .font(.system(size: BatteryWidgetMetrics.valueFontSize, weight: .regular, design: .default))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)

                if showName {
                    Text(item.name)
                        .font(.system(size: BatteryWidgetMetrics.nameFontSize, weight: .regular))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .minimumScaleFactor(0.7)
                        .frame(maxWidth: size + 18)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel(accessibilityLabel)
    }

    private func ringDiameter(index: Int, count: Int) -> CGFloat {
        guard count > 1 else { return size }
        let step = BatteryWidgetMetrics.multiRingDiameterStep(strokeWidth: strokeWidth)
        let shrink = CGFloat(index) * step
        // Keep innermost ring large enough for the center icon.
        let minDiameter = max(size * 0.42, size * BatteryWidgetMetrics.iconRatio + strokeWidth * 2)
        return max(size - shrink, minDiameter)
    }

    private func clamped(_ value: Double) -> CGFloat {
        guard value.isFinite else { return 0 }
        return CGFloat(min(1, max(0, value)))
    }

    private func strokeColor(for layer: UsageRingLayer, progress: CGFloat, index: Int) -> Color {
        if let hex = layer.ringColor, let c = Color(hex: hex) {
            return c
        }
        if let hex = item.ringColor, index == 0, let c = Color(hex: hex) {
            return c
        }
        // Distinct fallbacks for multi-ring cards (outer → inner).
        let palette: [Color] = [
            Color(red: 0.30, green: 0.85, blue: 0.40),
            Color(red: 0.35, green: 0.78, blue: 0.98),
            Color(red: 1.00, green: 0.62, blue: 0.04),
        ]
        if isMulti, index < palette.count {
            return palette[index]
        }
        if progress >= 0.2 {
            return palette[0]
        }
        return Color.orange
    }

    private var accessibilityLabel: String {
        var parts = [item.name]
        if item.id == "antigravity" {
            parts.append(period == .weekly ? "weekly" : "5 hour")
        }
        if layers.count > 1 {
            for layer in layers {
                parts.append("\(layer.label) \(layer.percentText)")
            }
        } else {
            if let label = item.displayLabel(period: period) {
                parts.append(label)
            }
            parts.append(valueText)
        }
        return parts.joined(separator: ", ")
    }
}

struct PluginIconView: View {
    let item: UsageRingItem
    var side: CGFloat

    var body: some View {
        Group {
            if let image = loadMonochromeIcon() {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(width: side, height: side)
            } else {
                Text(String(item.name.prefix(1)).uppercased())
                    .font(.system(size: side * 0.55, weight: .medium, design: .rounded))
                    .foregroundStyle(Color.primary.opacity(0.85))
            }
        }
        .frame(width: side, height: side)
    }

    /// Load icon, force monochrome, invert so logos read on dark widget chrome.
    private func loadMonochromeIcon() -> NSImage? {
        guard let rel = item.iconFile, !rel.isEmpty else { return nil }
        guard let url = AppGroup.resolveFile(relativePath: rel) else { return nil }
        let source: NSImage?
        if let image = NSImage(contentsOf: url), image.isValid {
            source = image
        } else if let data = try? Data(contentsOf: url),
                  let image = NSImage(data: data),
                  image.isValid {
            source = image
        } else {
            source = nil
        }
        guard let source else { return nil }
        return monochromeInverted(source) ?? source
    }

    /// Desaturate + invert → light glyph on dark battery-style cards.
    /// Plugin SVGs are typically dark on transparent; invert makes them light.
    private func monochromeInverted(_ image: NSImage) -> NSImage? {
        var rect = CGRect(origin: .zero, size: image.size)
        guard image.size.width > 0, image.size.height > 0,
              let cgImage = image.cgImage(forProposedRect: &rect, context: nil, hints: nil)
        else { return nil }

        let input = CIImage(cgImage: cgImage)
        let extent = input.extent
        guard extent.width > 1, extent.height > 1 else { return nil }

        let mono = input.applyingFilter("CIColorControls", parameters: [
            kCIInputSaturationKey: 0.0,
            kCIInputContrastKey: 1.1,
        ])
        let inverted = mono.applyingFilter("CIColorInvert", parameters: [:])

        // Restore original alpha so transparent backgrounds stay transparent after invert.
        let alphaOnly = input.applyingFilter("CIColorMatrix", parameters: [
            "inputRVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputGVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputBVector": CIVector(x: 0, y: 0, z: 0, w: 0),
            "inputAVector": CIVector(x: 0, y: 0, z: 0, w: 1),
            "inputBiasVector": CIVector(x: 0, y: 0, z: 0, w: 0),
        ])
        let composed = inverted.applyingFilter("CISourceInCompositing", parameters: [
            kCIInputBackgroundImageKey: alphaOnly,
        ])

        let context = CIContext(options: nil)
        let final = composed.extent.isEmpty ? inverted : composed
        guard let outCG = context.createCGImage(final, from: extent) else { return nil }
        return NSImage(cgImage: outCG, size: NSSize(width: extent.width, height: extent.height))
    }
}

/// Horizontal battery-style row: up to 4 enabled plugins (medium / banner).
struct RingsRowView: View {
    let items: [UsageRingItem]
    var ringSize: CGFloat = BatteryWidgetMetrics.ringSize
    var maxVisible: Int = 4
    var period: AntigravityWidgetPeriod = .fiveHour

    var body: some View {
        let visible = Array(items.prefix(maxVisible))
        Group {
            if visible.isEmpty {
                VStack(spacing: 6) {
                    Text("Open OpenUsage to refresh usage")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    if !UsageSnapshotStore.lastLoadNote.isEmpty {
                        Text(UsageSnapshotStore.lastLoadNote)
                            .font(.system(size: 8, design: .monospaced))
                            .foregroundStyle(.tertiary)
                            .multilineTextAlignment(.center)
                            .lineLimit(4)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding(12)
            } else {
                HStack(alignment: .top, spacing: BatteryWidgetMetrics.rowSpacing) {
                    ForEach(visible) { item in
                        ProviderRingView(
                            item: item,
                            size: ringSize,
                            showName: true,
                            period: period
                        )
                        .frame(maxWidth: .infinity)
                    }
                }
                .padding(.horizontal, BatteryWidgetMetrics.hPadding)
                .padding(.vertical, BatteryWidgetMetrics.vPadding)
            }
        }
    }
}

extension Color {
    /// Parse `#RGB`, `#RRGGBB`, or `#RRGGBBAA`.
    init?(hex: String) {
        var s = hex.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("#") { s.removeFirst() }
        guard s.count == 3 || s.count == 6 || s.count == 8 else { return nil }

        var value: UInt64 = 0
        guard Scanner(string: s).scanHexInt64(&value) else { return nil }

        let r, g, b, a: Double
        switch s.count {
        case 3:
            r = Double((value >> 8) & 0xF) / 15
            g = Double((value >> 4) & 0xF) / 15
            b = Double(value & 0xF) / 15
            a = 1
        case 6:
            r = Double((value >> 16) & 0xFF) / 255
            g = Double((value >> 8) & 0xFF) / 255
            b = Double(value & 0xFF) / 255
            a = 1
        default:
            r = Double((value >> 24) & 0xFF) / 255
            g = Double((value >> 16) & 0xFF) / 255
            b = Double((value >> 8) & 0xFF) / 255
            a = Double(value & 0xFF) / 255
        }
        self.init(.sRGB, red: r, green: g, blue: b, opacity: a)
    }
}
