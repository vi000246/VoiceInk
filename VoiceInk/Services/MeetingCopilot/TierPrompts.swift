import Foundation

/// Tier 1 / Tier 2 的 system + user prompt 建構(純函式,FR-12)。
///
/// FR-27:Tier 2 system prompt **明確禁止捏造** benchmark 數字/論文/公司名,不確定寫進 uncertainties。
///
/// M8 AC-46:四個 system 都帶 `outputLanguage`。英文會議時 cue 原句與接地片段全是英文,
/// 模型會很自然地跟著用英文回答——但開口稿的用途是**直接照著唸**,語言錯了整個功能就報廢。
/// 語言跟著「翻譯目標語言」走(呼叫端傳 `MeetingTranslationPrompt.displayName(for:)`):
/// 我要看的字幕語言,就是我要開口說的語言,不該是兩個各自為政的設定。
enum TierPrompts {

    /// 預設輸出語言 = config 預設目標語言 `zh-TW` 的人話。
    /// 正式呼叫端(`AnswerCoordinator` / `MeetingCopilotRunConfig.capture`)一律**顯式傳入**;
    /// 這個預設只服務 prompt 契約測試那種「不在乎語言」的呼叫。
    static let defaultOutputLanguage = "繁體中文"

    /// 使用者可調的風格/範圍守則(`config.answerStyleGuidance`)注入 persona 之後、正文之前。
    /// 空字串 → 回空(不加行),讓不傳 guidance 的純函式契約測試與 legacy 輸出**逐字不變**。
    private static func guidanceLine(_ guidance: String) -> String {
        guidance.isEmpty ? "" : guidance + "\n"
    }

    // MARK: - Tier 1(開口稿)

    static func tier1System(persona: String, guidance: String = "",
                            outputLanguage: String = defaultOutputLanguage) -> String {
        """
        \(persona)
        \(guidanceLine(guidance))你正在協助我(聽者)在會議中即時回應對方的問題或質疑。
        目標:讓我能在 2 秒內開口。輸出**極簡**,只給:
        1. 一句「開口稿」——我可以直接照著說出口的第一句話,用來爭取思考時間,不要長。
        2. 恰好 3 個要點,每點一行、以「- 」開頭、每點不超過 20 字。
        嚴格格式(不要任何其他文字、不要 markdown):
        OPENER: <一句可直接說出口的話>
        - <要點一>
        - <要點二>
        - <要點三>
        一律以\(outputLanguage)回答——不論對方用什麼語言發問(開口稿與要點都是)。
        """
    }

    static func tier1User(cue: String, grounding: MeetingGrounding) -> String {
        var lines: [String] = []
        let g = grounding.userBlock()
        if !g.isEmpty { lines.append(g) }
        lines.append("對方問/說:\(cue)")
        return lines.joined(separator: "\n")
    }

    // MARK: - Tier 1(aboutMe 變體:個人記憶助手,M8 FR-48 / AC-33)

    /// aboutMe cue 的 Tier 1 system。輸出結構與 `tier1System` **相同**(OPENER + 「- 」bullets),
    /// 所以 `TierParsers.parseTier1` 不必改動(它本來就多截少補);換掉的只有「這是什麼題目、
    /// 可以用什麼素材」,以及 bullets 的條數要求。
    ///
    /// # 為什麼錨點是 1~3 條而不是「恰好 3 條」(M9 FR-66)
    /// 技術題硬湊第三個要點,頂多是廢話;**aboutMe 硬湊第三條錨點,湊出來的是假記憶**。
    /// 錨點的唯一來源是筆記片段——片段只撐得起 1 條時,「恰好 3 條」這道命令唯一的滿足方式
    /// 就是編兩條,而我現場會照著錨點講,講的是我沒做過的事。所以條數跟著素材走:
    /// 撐得起幾條列幾條,不足不硬湊——空著比編造安全。
    ///
    /// # 為什麼 bullets 要求「記憶錨點」而不是論述句
    /// 被問到自己的經歷時,我缺的不是論述——那些事是我做的,只要想起來就講得出來——我缺的是
    /// **當下一瞬間想不起是哪個專案、哪個數字**。所以 bullets 要給的是**觸發回憶的錨點**
    /// (專案名/我的角色/具體貢獻/量化成果):看到「訂單分庫 · 主導 · P99 800→120ms」,記憶
    /// 自己會把細節接上,我用自己的話講,聽起來就是真的。反過來給一段漂亮的論述句,現場還要
    /// 先讀完、再翻譯成自己的話——來不及,而且照唸的語氣一聽就是在讀稿。
    ///
    /// # 為什麼禁令比 `tier2System` 的通用鐵律更硬
    /// 技術題掰錯只是丟臉;**編造自己的經歷會當場被拆穿**(問的人可能就是當事人,或下一句就追問細節)。
    /// 所以這裡不是「不確定就列進 uncertainties」,而是「筆記沒記載就直接說『筆記沒有記載』」
    /// ——寧可空手,絕不捏造。筆記與自介是唯一事實來源:**沒提到的內容一個字都不能出現**。
    static func tier1SystemAboutMe(persona: String, guidance: String = "",
                                   outputLanguage: String = defaultOutputLanguage) -> String {
        """
        \(persona)
        \(guidanceLine(guidance))你是我的個人記憶助手。對方問到**我本人的經歷／專案／貢獻**。
        下方「我的筆記」與「我的自介」是**唯一事實來源**——只能使用它們:筆記片段與自介
        **沒提到的內容,一個字都不能出現在回答裡**;片段不足以回答時直說「筆記沒有記載」,
        絕不編造(編造我的經歷會被當場拆穿,寧可空手)。
        目標:讓我能在 2 秒內開口。輸出**極簡**,只給:
        1. 一句「開口稿」——我可以直接照著說出口的第一句話,用來爭取思考時間,不要長。
        2. 條列 **1~3 條**記憶錨點(專案名／我的角色／具體貢獻／量化成果),每點一行、
           以「- 」開頭、每點不超過 20 字——**筆記片段撐得起幾條就列幾條,不足不硬湊**;
           硬湊出來的錨點是假記憶,比沒有更糟。
           看到錨點我自己會想起細節,所以不要寫成論述句或替我把話講完。
        嚴格格式(不要任何其他文字、不要 markdown):
        OPENER: <一句可直接說出口的話>
        - <記憶錨點一>
        - <記憶錨點二>
        - <記憶錨點三>
        一律以\(outputLanguage)回答——不論對方用什麼語言發問(開口稿與記憶錨點都是)。
        """
    }

    /// aboutMe 的 Tier 1 user。= 既有 `userBlock()`(brief + 筆記檢索片段)+ 自介行 + cue 行。
    /// `aboutMeBrief` 空(預設)→ **整行略過**,不留一行空的「我的自介:」誤導模型「我沒有自介」。
    static func tier1UserAboutMe(cue: String, grounding: MeetingGrounding, aboutMeBrief: String) -> String {
        var lines: [String] = []
        // `.personalNotes`:片段全來自個人筆記,標題必須與 system 的「唯一事實來源」同一口徑。
        let g = grounding.userBlock(excerptLabel: .personalNotes)
        if !g.isEmpty { lines.append(g) }
        if !aboutMeBrief.isEmpty { lines.append("我的自介:\(aboutMeBrief)") }
        lines.append("對方問/說:\(cue)")
        return lines.joined(separator: "\n")
    }

    // MARK: - Tier 2(深度分析 + follow-up 預判)

    /// M9 FR-73:深答的**輸出密度**由 `style` 決定(`MeetingDeepStyle`,預設 `.bullets`)。
    ///
    /// # 為什麼要有這個參數
    /// 段落式深答在會議**進行中**等於沒有:對方講完話到我該接話之間只有幾秒,眼睛掃得過三、四個
    /// 要點,掃不過三段散文。以前那份寫得很好的分析,實際上是寫給「會後的我」看的。
    ///
    /// # 為什麼 `style` 沒有預設值
    /// 三個呼叫點的正確答案彼此不同——coordinator 跟著 config 走、RunConfig 快照要記錄**當時真的
    /// 送出去的那一份**、prompt 契約測試要鎖 `.detailed`。給預設值的話,下一個新增的呼叫點會安靜地
    /// 拿到一個「看起來能動」但不是它要的風格,而 prompt 選錯風格不會 crash、不會報錯,只會讓輸出
    /// 悄悄變成另一種東西。所以這裡強迫每個呼叫點自己講清楚。
    ///
    /// # 什麼**不**跟著 style 變
    /// JSON 輸出契約(analysis / followUps / uncertainties 三鍵 + 格式範例)三種風格**共用同一段**,
    /// 不得分岔:風格只活在 analysis 字串**內部**,所以 `TierParsers.parseTier2` 與
    /// `AIEnhancementOutputFilter.filter` 零改動。同理,結尾的語言指示也是共用段。
    ///
    /// AC-58 回歸鎖:`.detailed` 的輸出與 M8 出貨版**逐字相同**
    /// (`TierPromptsTests.testTier2StyleDetailedIsByteIdenticalToLegacy`)。
    static func tier2System(persona: String, guidance: String = "",
                            outputLanguage: String = defaultOutputLanguage,
                            style: MeetingDeepStyle) -> String {
        // 只有「analysis 該怎麼寫」這一段會換;上面的鐵律、下面的 JSON 契約與語言指示都不動。
        let formatSection: String
        switch style {
        case .detailed:
            formatSection = "followUps 給 2-3 個最可能的追問。"
        case .bullets:
            formatSection = """
            analysis 以**條列**輸出:**至多 4 條**、每條一行,格式「**關鍵詞**:一句話」
            (例:「**風險**:舊資料遷移會鎖表」)。對話進行中我只有 3 秒掃視時間——
            關鍵詞是眼睛的錨點,所以每條都要從關鍵詞開頭,不要寫成一段沒有落腳點的長句。
            followUps 至多 2 條;uncertainties 至多 2 條。
            """
        case .concise:
            formatSection = """
            analysis 以 **2~3 句話**直接給出結論與建議立場,不條列、不鋪陳、不重述問題。
            followUps 至多 2 條。
            """
        }
        return """
        \(persona)
        \(guidanceLine(guidance))以下是我在會議中被問到的問題,以及我剛才的初步開口稿。請補強成足以應付追問的深度回答。
        **鐵律:不要捏造/編造任何 benchmark 數字、論文名稱、公司名、產品版本或不存在的事實。**
        任何你沒把握的點,不要硬掰——把它列進 uncertainties。
        只輸出 JSON(不要 markdown code fence、不要其他文字),格式:
        {
          "analysis": "<完整分析,可分段>",
          "followUps": [{"question":"<對方很可能接著追問的問題>","oneLineAnswer":"<一句話答案>"}],
          "uncertainties": ["<我不確定、需要實測或查證的點>"]
        }
        \(formatSection)
        一律以\(outputLanguage)回答——不論對方用什麼語言發問(JSON 內的文字也是;key 名維持英文)。
        """
    }

    static func tier2User(cue: String, draft: Tier1Draft, grounding: MeetingGrounding) -> String {
        var lines: [String] = []
        let g = grounding.userBlock()
        if !g.isEmpty { lines.append(g) }
        lines.append("對方問/說:\(cue)")
        lines.append("")
        lines.append("我的初步開口稿:")
        lines.append(draft.draftText)
        return lines.joined(separator: "\n")
    }

    // MARK: - Tier 2 的 aboutMe 變體:M9 FR-67 已移除
    //
    // aboutMe cue 一律不進 Tier 2(`AnswerCoordinator.runAutoDeep` / `requestDeep` 兩處守門),
    // 這兩個 prompt 變體因此成了死碼,隨 FR-67 一起刪除。
    // 理由:記憶錨點看一眼就夠——深度分析對「回憶自己的經歷」沒有增量,只是多一段對話中讀不完的
    // 文字 + 一次 deep token。要復活這條路,先撤掉那兩道守門,別只把 prompt 函式加回來。
}
