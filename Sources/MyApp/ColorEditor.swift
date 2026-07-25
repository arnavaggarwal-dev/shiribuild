import SwiftUI
import UIKit

/// RGB/HSV colour picker for the two themeable colours. Hand-rolled rather
/// than using SwiftUI's `ColorPicker` so it matches the rest of the app's
/// look and can show a live preview of what the theme will actually become.
struct ColorEditorView: View {
    var title: String
    var initial: UInt32
    var defaultHex: UInt32
    var onSave: (UInt32) -> Void

    @Environment(\.dismiss) private var dismiss

    private enum Mode: String, CaseIterable { case rgb = "RGB", hsv = "HSV" }
    @State private var mode: Mode = .rgb

    // RGB components, 0...255
    @State private var r: Double = 0
    @State private var g: Double = 0
    @State private var b: Double = 0

    // HSV components: hue 0...360, saturation/value 0...100
    @State private var h: Double = 0
    @State private var s: Double = 0
    @State private var v: Double = 0

    @State private var hexField = ""

    private var currentHex: UInt32 {
        (UInt32(r.rounded()) << 16) | (UInt32(g.rounded()) << 8) | UInt32(b.rounded())
    }

    private var currentColor: Color { Color(hex: currentHex) }

    var body: some View {
        NavigationStack {
            ZStack {
                AnimatedNebulaBackground()
                ScrollView {
                    VStack(spacing: 18) {
                        preview

                        Picker("Mode", selection: $mode) {
                            ForEach(Mode.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                        }
                        .pickerStyle(.segmented)

                        if mode == .rgb {
                            rgbSliders
                        } else {
                            hsvSliders
                        }

                        hexRow

                        GhostButton(title: "Reset to default", systemImage: "arrow.uturn.backward") {
                            apply(hex: defaultHex)
                        }

                        Spacer(minLength: 20)
                    }
                    .padding(20)
                }
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSave(currentHex)
                        Haptics.accepted()
                        dismiss()
                    }
                }
            }
        }
        .preferredColorScheme(.dark)
        .onAppear { apply(hex: initial) }
    }

    // MARK: pieces

    private var preview: some View {
        VStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(currentColor)
                .frame(height: 90)
                .overlay(
                    RoundedRectangle(cornerRadius: 16, style: .continuous)
                        .strokeBorder(Palette.border, lineWidth: 1)
                )
            Text(String(format: "#%06X", currentHex))
                .font(GameFont.mono(15))
                .foregroundStyle(Palette.dim)
        }
    }

    private var rgbSliders: some View {
        VStack(spacing: 16) {
            componentSlider(label: "Red", value: $r, range: 0...255, tint: .red) { syncHSVFromRGB() }
            componentSlider(label: "Green", value: $g, range: 0...255, tint: .green) { syncHSVFromRGB() }
            componentSlider(label: "Blue", value: $b, range: 0...255, tint: .blue) { syncHSVFromRGB() }
        }
        .padding(16)
        .glassCard()
    }

    private var hsvSliders: some View {
        VStack(spacing: 16) {
            componentSlider(label: "Hue", value: $h, range: 0...360, tint: Palette.accent) { syncRGBFromHSV() }
            componentSlider(label: "Saturation", value: $s, range: 0...100, tint: Palette.accent) { syncRGBFromHSV() }
            componentSlider(label: "Value", value: $v, range: 0...100, tint: Palette.accent) { syncRGBFromHSV() }
        }
        .padding(16)
        .glassCard()
    }

    private func componentSlider(label: String, value: Binding<Double>,
                                  range: ClosedRange<Double>, tint: Color,
                                  onChange: @escaping () -> Void) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(label)
                    .font(GameFont.caption(11))
                    .foregroundStyle(Palette.dim)
                Spacer()
                Text("\(Int(value.wrappedValue.rounded()))")
                    .font(GameFont.mono(13))
                    .foregroundStyle(Palette.text)
            }
            Slider(value: value, in: range)
                .tint(tint)
                .onChange(of: value.wrappedValue) { _, _ in
                    onChange()
                    hexField = String(format: "%06X", currentHex)
                }
        }
    }

    private var hexRow: some View {
        HStack(spacing: 10) {
            Text("#")
                .font(GameFont.mono(15))
                .foregroundStyle(Palette.dim)
            TextField("A855F7", text: $hexField)
                .font(GameFont.mono(15))
                .foregroundStyle(Palette.text)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.characters)
                .onSubmit {
                    if let parsed = UInt32(hexField.trimmingCharacters(in: .whitespaces), radix: 16),
                       hexField.trimmingCharacters(in: .whitespaces).count == 6 {
                        apply(hex: parsed)
                    } else {
                        hexField = String(format: "%06X", currentHex)
                    }
                }
        }
        .padding(14)
        .glassCard(border: Palette.border, fill: Palette.card2)
    }

    // MARK: conversion

    private func apply(hex: UInt32) {
        r = Double((hex >> 16) & 0xFF)
        g = Double((hex >> 8) & 0xFF)
        b = Double(hex & 0xFF)
        syncHSVFromRGB()
        hexField = String(format: "%06X", hex)
    }

    private func syncHSVFromRGB() {
        let ui = UIColor(red: r / 255, green: g / 255, blue: b / 255, alpha: 1)
        var hue: CGFloat = 0, sat: CGFloat = 0, bri: CGFloat = 0, alpha: CGFloat = 0
        guard ui.getHue(&hue, saturation: &sat, brightness: &bri, alpha: &alpha) else { return }
        h = Double(hue) * 360
        s = Double(sat) * 100
        v = Double(bri) * 100
    }

    private func syncRGBFromHSV() {
        let ui = UIColor(hue: h / 360, saturation: s / 100, brightness: v / 100, alpha: 1)
        var red: CGFloat = 0, green: CGFloat = 0, blue: CGFloat = 0, alpha: CGFloat = 0
        ui.getRed(&red, green: &green, blue: &blue, alpha: &alpha)
        r = Double(red) * 255
        g = Double(green) * 255
        b = Double(blue) * 255
    }
}
