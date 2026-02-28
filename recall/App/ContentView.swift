import SwiftUI

struct ContentView: View {
    init() {
        let tabBarAppearance = UITabBarAppearance()
        tabBarAppearance.configureWithOpaqueBackground()
        tabBarAppearance.backgroundColor = UIColor(RecallTheme.Colors.surface)

        tabBarAppearance.stackedLayoutAppearance.normal.iconColor = UIColor(RecallTheme.Colors.textMuted)
        tabBarAppearance.stackedLayoutAppearance.normal.titleTextAttributes = [
            .foregroundColor: UIColor(RecallTheme.Colors.textMuted),
            .font: UIFont.monospacedSystemFont(ofSize: 9, weight: .medium)
        ]
        tabBarAppearance.stackedLayoutAppearance.selected.iconColor = UIColor(RecallTheme.Colors.neonCyan)
        tabBarAppearance.stackedLayoutAppearance.selected.titleTextAttributes = [
            .foregroundColor: UIColor(RecallTheme.Colors.neonCyan),
            .font: UIFont.monospacedSystemFont(ofSize: 9, weight: .medium)
        ]

        UITabBar.appearance().standardAppearance = tabBarAppearance
        UITabBar.appearance().scrollEdgeAppearance = tabBarAppearance
    }

    var body: some View {
        TabView {
            RecordingView()
                .tabItem {
                    Label("REC", systemImage: "waveform")
                }

            UploadView()
                .tabItem {
                    Label("UPLOAD", systemImage: "arrow.up")
                }

            SettingsView()
                .tabItem {
                    Label("CONFIG", systemImage: "slider.horizontal.3")
                }
        }
        .tint(RecallTheme.Colors.neonCyan)
        .preferredColorScheme(.dark)
    }
}
