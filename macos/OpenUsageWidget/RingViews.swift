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
    /// Stroke width of the progress arc.
    static let lineWidth: CGFloat = 4.5
    /// Icon inside the ring (relative to ring diameter).
    static let iconRatio: CGFloat = 0.40
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

    private var progress: CGFloat {
        guard let fraction = item.fraction, fraction.isFinite else { return 0 }
        return CGFloat(min(1, max(0, fraction)))
    }

    private var strokeColor: Color {
        if let hex = item.ringColor, let c = Color(hex: hex) {
            return c
        }
        // System battery green when healthy.
        if progress >= 0.2 {
            return Color(red: 0.30, green: 0.85, blue: 0.40)
        }
        return Color.orange
    }

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                // Track (Battery-like muted gray)
                Circle()
                    .stroke(Color.primary.opacity(0.18), lineWidth: lineWidth)

                Circle()
                    .trim(from: 0, to: progress)
                    .stroke(
                        strokeColor,
                        style: StrokeStyle(lineWidth: lineWidth, lineCap: .round)
                    )
                    .rotationEffect(.degrees(-90))

                PluginIconView(item: item, side: size * BatteryWidgetMetrics.iconRatio)
            }
            .frame(width: size, height: size)

            // Single value line (Battery style) + optional name
            VStack(spacing: 2) {
                Text(item.percentText)
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

    private var accessibilityLabel: String {
        var parts = [item.name, item.percentText]
        if let label = item.label {
            parts.insert(label, at: 1)
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
                        ProviderRingView(item: item, size: ringSize, showName: true)
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
