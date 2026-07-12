import Foundation

/// fast / deep model 解析。純函式,鏡射 `AskAIAnswerModel.resolve`(AskAIConfig.swift:25-39),
/// 但**額外要求**:`available` 傳入 `aiService.connectedProviders` 的 rawValue——
/// 若使用者移除了某 provider 的 API key,該 provider 不再 connected,resolve 回退預設,
/// 不得用失效 provider 發請求(M3 SRS Architecture Notes)。fast 與 deep 各解析一次。
enum MeetingCopilotModels {
    /// - Parameters:
    ///   - storedProvider: 使用者設定的 provider rawValue(nil/空 = 跟隨預設)
    ///   - storedModel: 使用者設定的 model(nil = 用該 provider 的預設 model)
    ///   - defaultProvider: 回退用的預設 provider(通常 `aiService.selectedProvider.rawValue`)
    ///   - available: 目前 connected 的 provider rawValue 集合
    static func resolve(storedProvider: String?, storedModel: String?,
                        defaultProvider: String, available: [String]) -> (provider: String, model: String?) {
        if let sp = storedProvider, !sp.isEmpty, available.contains(sp) {
            let m = (storedModel?.isEmpty == false) ? storedModel : nil
            return (sp, m)
        }
        return (defaultProvider, nil)
    }
}
