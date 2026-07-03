import Foundation

// Seams for the engine's mode-related collaborators, so the recording state machine can be
// unit-tested with fakes instead of reaching into app-global singletons.

protocol ModeSelecting: AnyObject {
    var currentEffectiveConfiguration: ModeConfig? { get }
    func getConfigurationForTriggerWord(_ text: String) -> (mode: ModeConfig, processedText: String)?
    func setActiveConfiguration(_ config: ModeConfig?)
}

extension ModeManager: ModeSelecting {}

protocol ModeApplying: AnyObject {
    @MainActor
    @discardableResult
    func beginApplyingConfiguration(modeId: UUID?, shouldApply: @escaping @MainActor () -> Bool) -> Task<Void, Never>
}

extension ActiveWindowService: ModeApplying {}
