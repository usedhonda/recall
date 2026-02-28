import WidgetKit
import SwiftUI

@main
struct RecordingControlWidget: ControlWidget {
    var body: some ControlWidgetConfiguration {
        StaticControlConfiguration(
            kind: "com.example.recall.RecordingControl",
            provider: RecordingValueProvider()
        ) { isRecording in
            ControlWidgetToggle(
                "recall",
                isOn: isRecording,
                action: ToggleRecordingIntent()
            ) { value in
                Label(
                    value ? "Recording" : "Stopped",
                    systemImage: value ? "mic.fill" : "mic.slash"
                )
            }
            .tint(isRecording ? .red : .cyan)
        }
        .displayName("recall Recording")
        .description("Toggle voice recording on/off.")
    }
}

struct RecordingValueProvider: ControlValueProvider {
    var previewValue: Bool { false }

    func currentValue() async throws -> Bool {
        RecordingStateManager.shared.isRecording
    }
}
