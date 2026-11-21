import SwiftUI

struct PlayerSelectionSheet<Item: Identifiable>: View {
    let title: String
    var allowsDeselection = false
    var deselectionTitle = "Off"
    let items: [Item]
    let selectedID: Item.ID?
    let itemTitle: KeyPath<Item, String>
    let itemSubtitle: KeyPath<Item, String?>
    let onSelect: (Item?) -> Void
    let onDismiss: () -> Void

    var body: some View {
        NavigationStack {
            List {
                if allowsDeselection {
                    Button {
                        onSelect(nil)
                    } label: {
                        pickerRow(
                            title: deselectionTitle,
                            subtitle: nil,
                            isSelected: selectedID == nil
                        )
                    }
                    .listRowBackground(Color.ithacaSurface)
                    .ithacaSuppressTVOSButtonChrome()
                }

                ForEach(items) { item in
                    Button {
                        onSelect(item)
                    } label: {
                        pickerRow(
                            title: item[keyPath: itemTitle],
                            subtitle: item[keyPath: itemSubtitle],
                            isSelected: selectedID == item.id
                        )
                    }
                    .listRowBackground(Color.ithacaSurface)
                    .ithacaSuppressTVOSButtonChrome()
                }
            }
            .ithacaScrollContentBackgroundHidden()
            .background(Color.ithacaBackground)
            .ithacaNavigationTitle(title)
            .ithacaNavigationBarTitleDisplayModeInline()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done", action: onDismiss)
                        .ithacaSuppressTVOSButtonChrome()
                }
            }
        }
        .presentationDetents([.medium])
        .presentationBackground(Color.ithacaBackground)
    }

    private func pickerRow(title: String, subtitle: String?, isSelected: Bool) -> some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .ithacaFont(tvOnly: IthacaFont.TV.rowTitle)
                    .foregroundStyle(Color.ithacaTextPrimary)

                if let subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(IthacaFont.caption(ios: .caption))
                        .foregroundStyle(Color.ithacaTextSecondary)
                }
            }

            Spacer()

            if isSelected {
                Image(systemName: "checkmark")
                    .font(IthacaFont.glyphSmall(ios: .caption.weight(.bold)))
                    .foregroundStyle(Color.ithacaTextPrimary)
            }
        }
    }
}
