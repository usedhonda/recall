import SwiftUI

struct ContentView: View {
    var body: some View {
        TabView {
            RecordingView()
                .tabItem {
                    Label("Record", systemImage: "mic.fill")
                }

            UploadView()
                .tabItem {
                    Label("Upload", systemImage: "arrow.up.circle")
                }

            SettingsView()
                .tabItem {
                    Label("Settings", systemImage: "gear")
                }
        }
    }
}
