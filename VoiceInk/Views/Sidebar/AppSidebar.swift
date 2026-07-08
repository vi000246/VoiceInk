import SwiftUI

struct AppSidebar: View {
    @Binding var selectedView: ViewType
    @Environment(\.modelContext) private var modelContext
    @ObservedObject private var sidebarModel = LibrarySidebarModel.shared
    @State private var recorderCategoriesExpanded = false

    var body: some View {
        ZStack(alignment: .trailing) {
            sidebarBackground
            sidebarDivider
            sidebarContent
        }
        .frame(width: 220)
        .frame(maxHeight: .infinity)
        .onAppear {
            ViewType.assertSidebarItemsCoverAllCases()
            sidebarModel.refresh(modelContext)
        }
        // 每次切到管理頁時刷新分類計數（新增/分類/刪除錄音後保持同步）。
        .onChange(of: selectedView) { _, newValue in
            if newValue == .recorderLog || newValue == .history {
                sidebarModel.refresh(modelContext)
            }
        }
    }

    private var sidebarContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(ViewType.sidebarSections.enumerated()), id: \.offset) { _, section in
                    if let header = section.title {
                        sectionHeader(header)
                    }
                    sidebarSection(section.items)
                }
            }
            .padding(.top, 10)
            .padding(.bottom, 14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollIndicators(.never)
    }

    private func sectionHeader(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 18)
            .padding(.top, 16)
            .padding(.bottom, 5)
    }

    private var sidebarBackground: some View {
        VisualEffectView(material: .sidebar, blendingMode: .behindWindow)
            .ignoresSafeArea(.container, edges: .top)
    }

    private var sidebarDivider: some View {
        Rectangle()
            .fill(AppTheme.Border.control.opacity(0.55))
            .frame(width: 1)
            .ignoresSafeArea(.container, edges: .top)
    }

    private func sidebarSection(_ items: [ViewType]) -> some View {
        VStack(spacing: 3) {
            ForEach(items) { viewType in
                if viewType == .recorderLog {
                    expandableRecorderLog
                } else {
                    SidebarItemButton(
                        viewType: viewType,
                        isSelected: selectedView == viewType
                    ) {
                        selectedView = viewType
                    }
                }
            }
        }
        .padding(.horizontal, 10)
    }

    /// 錄音管理列：本體導覽 + 可展開的分類子項（數量多者在上，旁標檔案數）。
    private var expandableRecorderLog: some View {
        VStack(spacing: 3) {
            SidebarItemButton(
                viewType: .recorderLog,
                isSelected: selectedView == .recorderLog && sidebarModel.recorderCategoryFilter == nil,
                disclosure: sidebarModel.recorderCategories.isEmpty
                    ? nil
                    : (recorderCategoriesExpanded ? "chevron.down" : "chevron.right"),
                onDisclosure: { withAnimation(.easeInOut(duration: 0.15)) { recorderCategoriesExpanded.toggle() } }
            ) {
                sidebarModel.recorderCategoryFilter = nil
                selectedView = .recorderLog
            }

            if recorderCategoriesExpanded {
                ForEach(sidebarModel.recorderCategories) { cat in
                    SidebarCategoryChild(
                        name: cat.name,
                        count: cat.count,
                        isSelected: selectedView == .recorderLog && sidebarModel.recorderCategoryFilter == cat.name
                    ) {
                        sidebarModel.recorderCategoryFilter = cat.name
                        selectedView = .recorderLog
                    }
                }
            }
        }
    }
}

private extension ViewType {
    var title: LocalizedStringKey {
        switch self {
        case .modes: return "Voice Modes"
        case .prompts: return "共用範本"
        case .history: return "語音管理"
        case .recorders: return "錄音裝置"
        case .recorderMode: return "錄音設定"
        case .categories: return "錄音模式"
        case .recorderLog: return "Recording Management"
        case .askAI: return "Ask AI"
        case .templateGuide: return "Template Guide"
        case .models: return "Transcription & AI Models"
        case .transcribeAudio: return "Manual Transcribe"
        case .audio: return "Audio Devices"
        default: return LocalizedStringKey(rawValue)
        }
    }

    /// Sidebar grouped by the two pipelines (voice input vs recorder→Obsidian) + shared/system.
    static let sidebarSections: [(title: LocalizedStringKey?, items: [ViewType])] = [
        (nil, [.dashboard]),
        ("語音輸入", [.modes, .history]),
        ("錄音輸入", [.recorders, .recorderMode, .categories, .recorderLog]),
        ("Ask AI", [.askAI]),
        ("共用與系統", [.prompts, .models, .systemTemplate, .templateGuide, .dictionary, .transcribeAudio, .audio, .settings, .license]),
    ]

    static func assertSidebarItemsCoverAllCases() {
        #if DEBUG
        let sidebarItems = sidebarSections.flatMap { $0.items }
        assert(Set(sidebarItems) == Set(allCases) && sidebarItems.count == allCases.count)
        #endif
    }

    var icon: String {
        switch self {
        case .dashboard: return "gauge.medium"
        case .transcribeAudio: return "waveform.path"
        case .history: return "doc.text.fill"
        case .models: return "cpu"
        case .modes: return "sparkles.square.fill.on.square"
        case .prompts: return "text.alignleft"
        case .audio: return "mic.fill"
        case .dictionary: return "text.book.closed.fill"
        case .recorders: return "recordingtape"
        case .recorderMode: return "slider.horizontal.3"
        case .categories: return "folder.fill.badge.gearshape"
        case .recorderLog: return "list.bullet.rectangle.fill"
        case .askAI: return "bubble.left.and.text.bubble.right.fill"
        case .systemTemplate: return "doc.badge.gearshape"
        case .templateGuide: return "graduationcap.fill"
        case .settings: return "gearshape.fill"
        case .license: return "checkmark.seal.fill"
        }
    }

    var sidebarIconStyle: SidebarIconStyle {
        switch self {
        case .dashboard:
            return .init(background: AppTheme.Sidebar.dashboard)
        case .modes:
            return .init(background: AppTheme.Sidebar.modes)
        case .prompts:
            return .init(background: AppTheme.Sidebar.modes)
        case .models:
            return .init(background: AppTheme.Sidebar.models)
        case .audio:
            return .init(background: AppTheme.Sidebar.fallback)
        case .dictionary:
            return .init(background: AppTheme.Sidebar.dictionary)
        case .history:
            return .init(background: AppTheme.Sidebar.audio)
        case .transcribeAudio:
            return .init(background: AppTheme.Sidebar.transcribeAudio)
        case .recorders:
            return .init(background: AppTheme.Sidebar.fallback)
        case .recorderMode:
            return .init(background: AppTheme.Sidebar.fallback)
        case .categories:
            return .init(background: AppTheme.Sidebar.fallback)
        case .recorderLog:
            return .init(background: AppTheme.Sidebar.audio)
        case .askAI:
            return .init(background: AppTheme.Sidebar.modes)
        case .systemTemplate:
            return .init(background: AppTheme.Sidebar.fallback)
        case .templateGuide:
            return .init(background: AppTheme.Sidebar.fallback)
        case .settings:
            return .init(background: AppTheme.Sidebar.fallback)
        case .license:
            return .init(background: AppTheme.Sidebar.license)
        }
    }
}

private struct SidebarIconStyle {
    let background: Color
    var foreground: Color = .white
}

private struct SidebarItemButton: View {
    let viewType: ViewType
    let isSelected: Bool
    /// SF Symbol name for a trailing disclosure chevron (own hit area), or nil for none.
    var disclosure: String? = nil
    var onDisclosure: (() -> Void)? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 9) {
                SidebarIconTile(
                    systemName: viewType.icon,
                    style: viewType.sidebarIconStyle
                )

                Text(viewType.title)
                    .font(.system(size: 13.5, weight: isSelected ? .semibold : .medium))
                    .lineLimit(1)

                Spacer(minLength: 0)

                if let disclosure {
                    Image(systemName: disclosure)
                        .font(.system(size: 11, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 22, height: 30)
                        .contentShape(Rectangle())
                        .onTapGesture { onDisclosure?() }
                }
            }
            .foregroundStyle(isSelected ? selectedForegroundColor : Color.primary)
            .padding(.leading, 8)
            .padding(.trailing, disclosure == nil ? 10 : 2)
            .frame(height: 38)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(rowBackground)
            .contentShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
        .help(viewType.title)
        .accessibilityLabel(viewType.title)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
        .animation(.easeInOut(duration: 0.12), value: isSelected)
    }

    private var rowBackground: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(rowBackgroundColor)
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(rowBorderColor, lineWidth: 1)
            }
    }

    private var rowBackgroundColor: Color {
        if isSelected {
            return Color(nsColor: .selectedContentBackgroundColor)
        }

        return .clear
    }

    private var rowBorderColor: Color {
        isSelected ? selectedForegroundColor.opacity(0.18) : .clear
    }

    private var selectedForegroundColor: Color {
        Color(nsColor: .alternateSelectedControlTextColor)
    }
}

/// 側欄分類子項：縮排的分類名 + 檔案數徽章。點擊即把該分類設為錄音管理頁的篩選。
private struct SidebarCategoryChild: View {
    let name: String
    let count: Int
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(isSelected ? selectedForegroundColor : .secondary)
                    .frame(width: 16)

                Text(name)
                    .font(.system(size: 12.5, weight: isSelected ? .semibold : .regular))
                    .lineLimit(1)

                Spacer(minLength: 4)

                Text("\(count)")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.secondary.opacity(0.14)))
            }
            .foregroundStyle(isSelected ? selectedForegroundColor : Color.primary)
            .padding(.leading, 34)   // 縮排對齊父列的圖示之後
            .padding(.trailing, 10)
            .frame(height: 30)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(isSelected ? Color(nsColor: .selectedContentBackgroundColor) : .clear)
            )
            .contentShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
        .help("\(name)（\(count)）")
    }

    private var selectedForegroundColor: Color {
        Color(nsColor: .alternateSelectedControlTextColor)
    }
}

private struct SidebarIconTile: View {
    let systemName: String
    let style: SidebarIconStyle

    var body: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(style.background)
                .overlay(alignment: .top) {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .fill(Color.white.opacity(0.18))
                        .frame(height: 11)
                        .blendMode(.screen)
                }
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .strokeBorder(Color.white.opacity(0.24), lineWidth: 0.5)
                }
                .shadow(color: Color.black.opacity(0.18), radius: 1.2, y: 1)

            Image(systemName: systemName)
                .font(.system(size: 14.5, weight: .semibold))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(style.foreground)
                .shadow(color: Color.black.opacity(0.16), radius: 0.5, y: 0.5)
        }
        .frame(width: 24, height: 24)
    }
}
