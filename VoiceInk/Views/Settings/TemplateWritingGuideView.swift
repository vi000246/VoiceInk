import SwiftUI

/// Read-only tutorial explaining how VoiceInk assembles the AI request and which tags are
/// available when writing prompts / editing the system template. Content mirrors the actual
/// assembly in `AIEnhancementService.getSystemMessage` + `CustomPrompt.finalPromptText`.
struct TemplateWritingGuideView: View {
    var body: some View {
        VStack(spacing: 0) {
            AppScreenHeader(
                title: "Template Guide",
                infoMessage: "教你 VoiceInk 怎麼把你的範本組成送給 AI 的訊息、有哪些標籤可用、以及語音範本與錄音筆範本的差異。",
                infoURL: nil
            ) { EmptyView() }

            ScrollView {
                MarkdownContentView(Self.guide, fontSize: 14, foregroundColor: AppTheme.Text.primary)
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(AppCardBackground(cornerRadius: 10))
                    .padding(24)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // Tags are shown in `backticks` so Markdown renders them literally (angle brackets would
    // otherwise be swallowed as HTML).
    private static let guide = """
    # 怎麼寫範本

    ## 1. VoiceInk 怎麼組出給 AI 的訊息

    每次做 AI 分析／增強時，VoiceInk 會組出兩個部分：

    - **System message（系統訊息）**＝ `你的範本` ＋ `自訂詞彙區`（有設定時）＋ `上下文區`（有開啟時），用空行接起來。
    - **User message（使用者訊息）**＝ 你的逐字稿，會被自動包進 `<USER_MESSAGE>` … `</USER_MESSAGE>`。

    重點：**你「寫的」是範本（指令）；「要被處理的內容」（逐字稿）由 VoiceInk 自動放進 `<USER_MESSAGE>`**。你不需要、也無法自己填入逐字稿。

    ---

    ## 2. 兩種範本模式（最重要）

    每個範本都有一個「使用系統模板」開關，決定它怎麼被送出：

    ### 開啟「使用系統模板」（多數語音範本）
    你的提示詞會被塞進**系統模板**的 `<TASK_INSTRUCTIONS>` 位置，自動獲得 VoiceInk 內建的口述清理規則（修正錯字、標點、口語自我修正、版面提示…）與所有上下文標籤的說明。**適合語音聽寫的改寫／潤飾**。你只要寫「要做什麼」，清理規則交給系統模板。

    ### 關閉「使用系統模板」（錄音筆範本一律如此）
    你的提示詞**就是整個 system message**，完全由你掌控，不套任何內建規則。**適合分析、摘要、換格式、產報告**等任務。

    > 錄音筆範本永遠是「關閉」模式，而且**不會**注入選取文字／剪貼簿／螢幕擷取這三個上下文標籤。

    ---

    ## 3. 可用標籤總表

    這些標籤由 **VoiceInk 自動產生並填入內容**，你不用自己打。你可以在提示詞裡**引用它們的名字**，告訴模型「內容在哪個標籤」。

    | 標籤 | 內容 | 何時出現 |
    |---|---|---|
    | `<USER_MESSAGE>` | 要被處理的逐字稿 | **一律出現** |
    | `<TASK_INSTRUCTIONS>` | 你這個範本的提示詞 | 只有「**開啟**使用系統模板」時 |
    | `<CUSTOM_VOCABULARY>` | 你的自訂詞彙（字典）清單 | 有設定自訂詞彙時 |
    | `<CURRENTLY_SELECTED_TEXT>` | 目前選取的文字 | 語音範本且該範本開啟「選取文字上下文」時 |
    | `<CLIPBOARD_CONTEXT>` | 剪貼簿內容 | 語音範本且該範本開啟「剪貼簿上下文」時 |
    | `<CURRENT_WINDOW_CONTEXT>` | 目前視窗的螢幕擷取文字 | 語音範本且該範本開啟「螢幕擷取上下文」時 |
    | `%@` | 系統模板專用的插入點 | 只在「系統模板」本身，見第 5 節 |

    另外，若你使用 **Local CLI** 這個 provider，VoiceInk 內部會改用 `<SYSTEM_MESSAGE>` 與 `<USER_MESSAGE_PAYLOAD>` 包裝——這是自動的，一般不用理會。

    ### 選取文字／剪貼簿／螢幕這三個上下文在哪裡開？

    這三個**不是範本（提示詞）的設定，而是「語音模式（Voice Mode）」的設定**，所以你在範本編輯畫面看不到它們。開關位置：

    **側邊欄 → Voice Modes → 編輯某個 Mode → 「Voice Prompt」區塊 → 展開「Context Awareness」**，裡面有三個開關：`Selected Text`、`Clipboard`、`Screen`，分別對應上表的三個標籤。

    需要注意：

    - 它綁在 **Mode**，不是範本——同一個範本在不同 Mode 下，上下文行為可能不同。
    - 要那個 Mode **先開啟「Apply Voice Prompt (AI Enhancement)」並選好 AI 模型**，「Context Awareness」那排才會出現。
    - 該區**預設是收合的**，要手動點開才看得到三個開關。
    - **錄音筆範本完全用不到這三個**：錄音筆分析一律不注入選取／剪貼簿／螢幕上下文，所以錄音筆的訊息裡永遠不會有這三個標籤。

    ---

    ## 4. 標籤「不是變數」——別誤會

    - 你在提示詞裡打 `<USER_MESSAGE>` **不會**被替換成逐字稿，它只是**字面文字**。
    - VoiceInk 唯一真正做字串替換的地方是**系統模板裡的 `%@`**（見下節）。
    - 正確用法：在提示詞裡**引用標籤名稱**當作指路，例如：「把 `<USER_MESSAGE>` 裡的口述整理成會議記錄」。內容仍由 VoiceInk 自動放進各自的標籤，模型讀得到。

    ---

    ## 5. `%@`：只屬於「系統模板」

    到 **System Template（系統模板）** 頁編輯時，模板裡一定要保留**剛好一個** `%@`——它標記「各範本的提示詞要插進來的位置」。

    - 少了 `%@`：範本內容不會被插入（該頁會跳警告）。
    - 系統模板只影響「**開啟**使用系統模板」的語音範本；**錄音筆範本不受影響**。
    - 可用「重設為預設」還原內建模板。
    - 一般範本的提示詞欄位**不要**打 `%@`，那是系統模板專用的。

    ---

    ## 6. 各情境實際會出現哪些標籤

    | 情境 | 會出現的標籤 |
    |---|---|
    | 語音範本・開系統模板 | `<USER_MESSAGE>`、`<TASK_INSTRUCTIONS>`、（有詞彙）`<CUSTOM_VOCABULARY>`、（各自開）三個上下文標籤 |
    | 語音範本・關系統模板 | `<USER_MESSAGE>`、（有詞彙）`<CUSTOM_VOCABULARY>`、（各自開）三個上下文標籤；**無** `<TASK_INSTRUCTIONS>` 包裝 |
    | 錄音筆範本 | `<USER_MESSAGE>`、（有詞彙）`<CUSTOM_VOCABULARY>`；**無** `<TASK_INSTRUCTIONS>`、**無**三個上下文標籤 |

    ---

    ## 7. 範例

    ### A. 語音範本（開系統模板）——只寫任務
    因為清理規則已由系統模板提供，提示詞可以很短：

    ```
    把口述整理成正式的商務 email，語氣客氣、分段清楚，開頭加招呼、結尾加署名區塊。
    ```

    ### B. 錄音筆／原始範本（關系統模板）——自己寫完整指令
    這種模式下你要自己交代角色與輸出格式；逐字稿會在 `<USER_MESSAGE>` 裡：

    ```
    你是會議記錄助理。請把 <USER_MESSAGE> 的逐字稿整理成 Markdown：
    **摘要**（3–5 點）、**決議**、**待辦清單**（- [ ] 形式，去重）。
    只輸出整理後的內容，不要加入客套話或解釋。
    ```

    ---

    ## 8. 小抄

    - 逐字稿一律在 `<USER_MESSAGE>`，你不用自己貼。
    - 想套用內建口述清理 → 開「使用系統模板」；想完全自訂 → 關掉。
    - 標籤是自動填的，提示詞裡只能「引用名稱」，不會被替換。
    - `%@` 只在系統模板用，且要保留剛好一個。
    - 錄音筆範本 = 關系統模板、無選取／剪貼簿／螢幕上下文，適合分析類任務。
    - 輸出通常只要最終文字；自己寫 raw 範本時記得明確指定輸出格式。
    """
}
