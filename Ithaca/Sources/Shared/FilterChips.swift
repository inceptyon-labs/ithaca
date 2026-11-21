import SwiftUI

/// Browse-control chips (the library grid, Pick Something).
enum FilterChipMetrics {
    static let cornerRadius: CGFloat = 18
}

/// The label of a filter `Menu`: icon, current value, chevron. An active
/// filter gets a stronger icon and outline, never a colour.
struct FilterMenuChipLabel: View {
    let value: String
    let systemImage: String
    let isActive: Bool
    let accessibilityLabel: String

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: FilterChipMetrics.cornerRadius, style: .continuous)
    }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(IthacaFont.glyphMedium(ios: .headline))
                .foregroundStyle(isActive ? Color.ithacaTextPrimary : Color.ithacaTextSecondary)

            Text(value)
                .font(IthacaFont.buttonLabel(ios: .subheadline.weight(.medium)))
                .foregroundStyle(Color.ithacaTextPrimary)
                .lineLimit(1)

            Image(systemName: "chevron.down")
                .font(IthacaFont.glyphSmall(ios: .caption.weight(.semibold)))
                .foregroundStyle(Color.ithacaTextSecondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(shape.fill(Color.ithacaSurface))
        .overlay {
            shape.stroke(
                isActive ? Color.ithacaTextPrimary.opacity(0.35) : Color.ithacaTextSecondary.opacity(0.18),
                lineWidth: 1
            )
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityLabel)
        .accessibilityValue(value)
        .ithacaTVOSFocusEffectShape(shape)
    }
}

/// A filter chip rather than a menu: one tap (one click on tvOS) flips it.
/// On, it inverts to a `TextPrimary` fill with a filled checkmark, the
/// STYLE.md selected treatment, so the active filter reads at a glance.
struct FilterToggleChip: View {
    let title: String
    let isOn: Bool
    let accessibilityLabel: String
    let action: () -> Void

    private var shape: RoundedRectangle {
        RoundedRectangle(cornerRadius: FilterChipMetrics.cornerRadius, style: .continuous)
    }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 10) {
                Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                    .font(IthacaFont.glyphMedium(ios: .headline))
                    .foregroundStyle(isOn ? Color.ithacaBackground : Color.ithacaTextSecondary)

                Text(title)
                    .font(IthacaFont.buttonLabel(ios: .subheadline.weight(.medium)))
                    .foregroundStyle(isOn ? Color.ithacaBackground : Color.ithacaTextPrimary)
                    .lineLimit(1)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .background(shape.fill(isOn ? Color.ithacaTextPrimary : Color.ithacaSurface))
            .overlay {
                shape.stroke(isOn ? Color.clear : Color.ithacaTextSecondary.opacity(0.18), lineWidth: 1)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(accessibilityLabel)
            .accessibilityAddTraits(isOn ? .isSelected : [])
            .ithacaTVOSFocusEffectShape(shape)
        }
        .ithacaSuppressTVOSButtonChrome()
        .animation(.snappy(duration: 0.2), value: isOn)
    }
}
