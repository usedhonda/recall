import AppIntents

struct ToggleRecordingIntent: SetValueIntent {
    static var title: LocalizedStringResource = "Toggle Recording"
    static var description: IntentDescription = "Start or stop recall voice recording."

    @Parameter(title: "Recording")
    var value: Bool

    func perform() async throws -> some IntentResult {
        RecordingStateManager.shared.isRecording = value
        return .result()
    }
}
