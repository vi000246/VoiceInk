import Foundation

extension Notification.Name {
    static let AppSettingsDidChange = Notification.Name("appSettingsDidChange")
    static let languageDidChange = Notification.Name("languageDidChange")
    static let promptDidChange = Notification.Name("promptDidChange")
    static let didChangeModel = Notification.Name("didChangeModel")
    static let aiProviderKeyChanged = Notification.Name("aiProviderKeyChanged")
    static let licenseStatusChanged = Notification.Name("licenseStatusChanged")
    static let licenseCelebrationRequested = Notification.Name("licenseCelebrationRequested")
    static let modeConfigurationApplied = Notification.Name("modeConfigurationApplied")
    static let modeConfigurationsDidChange = Notification.Name("ModeConfigurationsDidChange")
    static let modeShortcutAvailabilityDidChange = Notification.Name("modeShortcutAvailabilityDidChange")
    static let transcriptionCreated = Notification.Name("transcriptionCreated")
    static let transcriptionCompleted = Notification.Name("transcriptionCompleted")
    static let transcriptionDeleted = Notification.Name("transcriptionDeleted")
    static let sessionMetricsDidChange = Notification.Name("sessionMetricsDidChange")
    static let openFileForTranscription = Notification.Name("openFileForTranscription")
    static let audioDeviceSwitchRequired = Notification.Name("audioDeviceSwitchRequired")
    static let recorderImportCompleted = Notification.Name("recorderImportCompleted")
    /// Posted when a volume mounts/unmounts so recorder device cards can refresh their connection dot live.
    static let recorderDeviceConnectivityChanged = Notification.Name("recorderDeviceConnectivityChanged")
}
