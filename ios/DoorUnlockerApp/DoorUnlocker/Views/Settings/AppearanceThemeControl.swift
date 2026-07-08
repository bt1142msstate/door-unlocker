import SwiftUI

struct AppearanceThemeControl: View {
    let appTheme: DoorAppTheme
    @Binding var appThemeRawValue: String
    let accent: Color

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "paintpalette.fill")
                    .foregroundStyle(accent)
                Text("Color Scheme")
                    .font(.caption.weight(.bold))
                Spacer(minLength: 8)
                Text(appTheme.title)
                    .font(.caption2.weight(.bold))
                    .foregroundStyle(.secondary)
            }

            LazyVGrid(columns: [GridItem(.adaptive(minimum: 92), spacing: 8)], spacing: 8) {
                ForEach(DoorAppTheme.allCases) { theme in
                    ThemeSwatchButton(
                        theme: theme,
                        isSelected: theme == appTheme,
                        action: { appThemeRawValue = theme.rawValue }
                    )
                }
            }
        }
        .padding(12)
        .background(Color.black.opacity(0.24), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
