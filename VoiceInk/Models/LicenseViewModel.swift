import Foundation
import AppKit
import os

private let trialPeriodDays = 7

@MainActor
class LicenseViewModel: ObservableObject {
    enum LicenseState: Equatable {
        case unlicensed
        case trial(daysRemaining: Int)
        case trialExpired
        case licensed

        nonisolated var allowsAppUsage: Bool {
            switch self {
            case .licensed, .trial:
                return true
            case .unlicensed, .trialExpired:
                return false
            }
        }
    }

    /// 目前授權狀態的單一真相來源：Keychain 裡的 key/activation/試用起始日。
    /// 供 VM 本身、錄音入口 gating（VoiceInkEngine）與交付層共用，
    /// 避免各處自己 new 一個 VM 造成狀態分歧。
    nonisolated static func evaluateState(now: Date = Date()) -> LicenseState {
        #if LOCAL_BUILD
        return .licensed
        #else
        let manager = LicenseManager.shared
        if manager.licenseKey != nil,
           manager.activationId != nil || !UserDefaults.standard.bool(forKey: "VoiceInkLicenseRequiresActivation") {
            return .licensed
        }

        guard let trialStartDate = manager.trialStartDate else {
            return .unlicensed
        }

        let daysSinceTrialStart = Calendar.current.dateComponents([.day], from: trialStartDate, to: now).day ?? 0
        if daysSinceTrialStart >= trialPeriodDays {
            return .trialExpired
        }
        return .trial(daysRemaining: trialPeriodDays - daysSinceTrialStart)
        #endif
    }

    nonisolated static func usageRestrictionMessage(for state: LicenseState) -> String? {
        switch state {
        case .unlicensed, .trialExpired:
            return String(
                format: String(localized: "Your trial has ended. Upgrade to Muninn Pro at %@"),
                StoreConfig.purchaseURLString
            )
        case .trial, .licensed:
            return nil
        }
    }

    @Published private(set) var licenseState: LicenseState = .unlicensed
    @Published var licenseKey: String = ""
    @Published var isValidating = false
    @Published var validationMessage: String?
    @Published var validationSuccess: Bool = false
    @Published private(set) var activationsLimit: Int = 0

    private let polarService = PolarService()
    private let logger = Logger(subsystem: "com.prakashjoshipax.voiceink", category: "LicenseViewModel")
    private let userDefaults = UserDefaults.standard
    private let licenseManager = LicenseManager.shared

    init() {
        loadLicenseState()
    }

    func startTrial() {
        let didStartTrial = licenseManager.startTrialIfNeeded()
        licenseState = Self.evaluateState()
        NotificationCenter.default.post(name: .licenseStatusChanged, object: nil)

        if didStartTrial {
            requestLicenseCelebration()
        }
    }

    private func loadLicenseState() {
        // Trust the stored key at startup; server validation only happens on explicit activate.
        if let storedLicenseKey = licenseManager.licenseKey {
            self.licenseKey = storedLicenseKey
        }

        licenseState = Self.evaluateState()

        if case .licensed = licenseState {
            activationsLimit = userDefaults.activationsLimit
        }
    }

    var isLicensed: Bool {
        if case .licensed = licenseState {
            return true
        }

        return false
    }

    var canUseApp: Bool {
        licenseState.allowsAppUsage
    }

    var usageRestrictionMessage: String? {
        Self.usageRestrictionMessage(for: licenseState)
    }

    func openPurchaseLink() {
        if let url = StoreConfig.purchaseURL {
            NSWorkspace.shared.open(url)
        }
    }
    
    func validateLicense() async {
        let normalizedLicenseKey = licenseKey.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !normalizedLicenseKey.isEmpty else {
            validationSuccess = false
            validationMessage = String(localized: "Please enter a license key")
            return
        }
        
        licenseKey = normalizedLicenseKey
        isValidating = true
        validationSuccess = false
        validationMessage = nil
        
        do {
            // First, check if the license is valid and if it requires activation
            let licenseCheck = try await polarService.checkLicenseRequiresActivation(normalizedLicenseKey)
            
            if !licenseCheck.isValid {
                validationSuccess = false
                validationMessage = String(localized: "This license has been revoked or disabled. Please contact support.")
                isValidating = false
                return
            }
            
            // Handle based on whether activation is required
            if licenseCheck.requiresActivation {
                // If we already have an activation ID, try to validate with it first
                if let existingActivationId = licenseManager.activationId {
                    let isValid = (try? await polarService.validateLicenseKeyWithActivation(normalizedLicenseKey, activationId: existingActivationId)) ?? false
                    if isValid {
                        let limit = licenseCheck.activationsLimit ?? userDefaults.activationsLimit
                        licenseManager.licenseKey = normalizedLicenseKey
                        userDefaults.set(true, forKey: "VoiceInkLicenseRequiresActivation")
                        activationsLimit = limit
                        userDefaults.activationsLimit = limit
                        completeSuccessfulValidation(message: String(localized: "License activated successfully!"))
                        isValidating = false
                        return
                    }
                    // Activation is stale (deleted from portal) — clear it and create a new one
                    licenseManager.activationId = nil
                }

                // Need to create a new activation
                let (newActivationId, limit) = try await polarService.activateLicenseKey(normalizedLicenseKey)

                // Store activation details
                licenseManager.licenseKey = normalizedLicenseKey
                licenseManager.activationId = newActivationId
                userDefaults.set(true, forKey: "VoiceInkLicenseRequiresActivation")
                self.activationsLimit = limit
                userDefaults.activationsLimit = limit

            } else {
                // This license doesn't require activation (unlimited devices)
                licenseManager.licenseKey = normalizedLicenseKey
                licenseManager.activationId = nil
                userDefaults.set(false, forKey: "VoiceInkLicenseRequiresActivation")
                self.activationsLimit = licenseCheck.activationsLimit ?? 0
                userDefaults.activationsLimit = licenseCheck.activationsLimit ?? 0

                // Update the license state for unlimited license
                completeSuccessfulValidation(message: String(localized: "License validated successfully!"))
                isValidating = false
                return
            }
            
            // Update the license state for activated license
            completeSuccessfulValidation(message: String(localized: "License activated successfully!"))

        } catch LicenseError.keyNotFound {
            validationSuccess = false
            validationMessage = String(localized: "License key not found. Please double-check your key and try again.")
        } catch LicenseError.activationLimitReached {
            validationSuccess = false
            validationMessage = String(localized: "This license has reached its device limit. Visit the License Management Portal to deactivate other devices.")
        } catch LicenseError.serverError(let code) {
            validationSuccess = false
            validationMessage = String(
                format: String(localized: "Server error (%d). Please try again later or contact support."),
                code
            )
        } catch let urlError as URLError {
            validationSuccess = false
            logger.error("🔑 License network error: \(urlError, privacy: .public)")
            validationMessage = String(localized: "Could not reach the server. Please check your internet connection and try again.")
        } catch {
            validationSuccess = false
            logger.error("🔑 Unexpected license error: \(error, privacy: .public)")
            validationMessage = String(
                format: String(localized: "An unexpected error occurred. Please try again or contact support at %@"),
                StoreConfig.supportEmail
            )
        }
        
        isValidating = false
    }

    private func completeSuccessfulValidation(message: String) {
        licenseState = .licensed
        validationSuccess = true
        validationMessage = message
        NotificationCenter.default.post(name: .licenseStatusChanged, object: nil)
        requestLicenseCelebration()
    }

    private func requestLicenseCelebration() {
        NotificationCenter.default.post(name: .licenseCelebrationRequested, object: nil)
    }
    
    func removeLicense() {
        // Remove only the license credentials. Trial history stays intact.
        licenseManager.removeStoredLicense()

        // Reset UserDefaults flags
        userDefaults.set(false, forKey: "VoiceInkLicenseRequiresActivation")
        userDefaults.activationsLimit = 0

        licenseKey = ""
        validationMessage = nil
        validationSuccess = false
        activationsLimit = 0
        loadLicenseState()
        NotificationCenter.default.post(name: .licenseStatusChanged, object: nil)
    }
}


// UserDefaults extension for non-sensitive license settings
extension UserDefaults {
    var activationsLimit: Int {
        get { integer(forKey: "VoiceInkActivationsLimit") }
        set { set(newValue, forKey: "VoiceInkActivationsLimit") }
    }
}
