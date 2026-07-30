import Foundation

/// Muninn 自己的商務／對外連結設定，全部集中在這一個檔案。
///
/// 上線前置作業（依序）：
/// 1. 到 https://polar.sh 註冊 organization（個人即可，KYC 走 Stripe Connect Express，
///    需要台灣銀行帳戶＋身分證件）。
/// 2. 建立產品「Muninn Pro」（one-time purchase），掛 License Key benefit，
///    設定 activation limit（裝置數上限）。
/// 3. 把下面三個 REPLACE_WITH_* 換成真實值：org ID 在 Polar Settings → General，
///    checkout 連結在產品頁的 Share，portal 固定是 polar.sh/{org-slug}/portal/request。
///
/// 客戶版必須用 `make release` 打包（不帶 LOCAL_BUILD 旗標，授權系統才會生效）。
enum StoreConfig {
    /// Polar organization ID（UUID），PolarService 驗證/啟用 license key 都以此為準。
    static let polarOrganizationId = "REPLACE_WITH_MUNINN_POLAR_ORG_ID"

    /// 購買頁：Polar 產品的 hosted checkout 連結，不需要自己架網站。
    static let purchaseURLString = "https://polar.sh/REPLACE_WITH_ORG_SLUG"

    /// 客戶自助入口：找回金鑰、管理已啟用裝置。
    static let licensePortalURLString = "https://polar.sh/REPLACE_WITH_ORG_SLUG/portal/request"

    static let supportEmail = "vi000246@gmail.com"

    /// GPL-3.0 義務：拿到 binary 的客戶必須能取得原始碼，此 repo 需保持可存取。
    static let sourceRepoURLString = "https://github.com/vi000246/VoiceInk"
    static let changelogURLString = "https://github.com/vi000246/VoiceInk/releases"
    static let issuesURLString = "https://github.com/vi000246/VoiceInk/issues"
    static let docsURLString = "https://github.com/vi000246/VoiceInk#readme"

    /// 公告 JSON（GitHub Pages）。404 時 AnnouncementsService 靜默跳過，
    /// 要用時在 repo 開 gh-pages 放 announcements.json 即可。
    static let announcementsURLString = "https://vi000246.github.io/VoiceInk/announcements.json"

    static var purchaseURL: URL? { URL(string: purchaseURLString) }
    static var licensePortalURL: URL? { URL(string: licensePortalURLString) }
}
