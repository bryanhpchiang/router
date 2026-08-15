import SwiftUI

struct AccountRow: View {
    let profile: Profile
    let isCurrent: Bool
    let usage: String?
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: isCurrent ? "checkmark.circle.fill" : "circle")
                    .foregroundStyle(isCurrent ? Color.accentColor : Color.secondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(profile.email ?? profile.name)
                    Text(usage ?? "no usage data yet")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 6)
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .background(
            hovering ? Color.primary.opacity(0.07) : Color.clear,
            in: RoundedRectangle(cornerRadius: 6))
        .onHover { hovering = $0 }
    }
}
