import SwiftUI

extension BottomDeckMetrics {
    /// Extra row above the capture bar, there only while a backing track is selected.
    static let musicChipHeight: CGFloat = 40
}

/// The backing track the next recording gets, right above the record button; tapping it opens the music sheet.
struct MusicChip: View {
    let title: String
    /// False while a capture is running: the chip still shows the track but does not open the sheet.
    let enabled: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: "music.note")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(BrandColors.gold)
                Text(title)
                    .font(.brandLabelLarge)
                    .foregroundStyle(BrandColors.text)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .frame(maxWidth: 200)
            }
            // As wide as its title, up to the limit above.
            .fixedSize(horizontal: true, vertical: false)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background(BrandColors.scrim, in: Capsule())
            .overlay(Capsule().stroke(BrandColors.gold.opacity(0.7), lineWidth: 1))
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
        .frame(maxWidth: .infinity)
        .frame(height: BottomDeckMetrics.musicChipHeight)
        .accessibilityLabel(Strings.musicSelected(title))
    }
}
