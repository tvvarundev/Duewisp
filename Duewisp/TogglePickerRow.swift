import SwiftUI

struct TogglePickerRow: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    let title: LocalizedStringKey
    let systemImage: String
    @Binding var isOn: Bool
    let value: String
    let isExpanded: Bool
    var onPress: () -> Void = {}
    let togglePicker: () -> Void

    var body: some View {
        let isEnabled = isOn
        HStack {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                    if isEnabled {
                        Text(value)
                            .font(.subheadline)
                            .foregroundStyle(Color.accentColor)
                    }
                }
            } icon: {
                Image(systemName: systemImage).foregroundStyle(.secondary)
            }
            .allowsHitTesting(false)
            .accessibilityHidden(true)

            Spacer(minLength: 8)

            Toggle(title, isOn: $isOn.animation(reduceMotion ? nil : .smooth))
                .labelsHidden()
        }
        .frame(minHeight: 44)
        .padding(.horizontal, 20)
        .padding(.vertical, 8)
        .background {
            Button {
                onPress()
                withAnimation(reduceMotion ? nil : .smooth(duration: PickerRowPressStyle.releaseDuration)) {
                    if isEnabled {
                        togglePicker()
                    } else {
                        isOn = true
                    }
                }
            } label: {
                Color.clear.contentShape(Rectangle())
            }
            .buttonStyle(PickerRowPressStyle(reduceMotion: reduceMotion))
            .accessibilityLabel(Text(title))
            .accessibilityValue(Text(isEnabled ? value : ""))
            .accessibilityHint(isExpanded ? "Collapses picker" : "Expands picker")
            .accessibilitySortPriority(1)
        }
        .listRowInsets(EdgeInsets())
    }
}

struct PickerRowPressStyle: ButtonStyle {
    static let releaseDuration = 0.4
    private static let releaseDelay = 0.1
    let reduceMotion: Bool

    func makeBody(configuration: Configuration) -> some View {
        configuration.label.background {
            Color(uiColor: .systemFill)
                .opacity(configuration.isPressed ? 1 : 0)
                .animation(
                    configuration.isPressed || reduceMotion ? nil :
                        .easeInOut(duration: Self.releaseDuration - Self.releaseDelay).delay(Self.releaseDelay),
                    value: configuration.isPressed
                )
        }
    }
}
