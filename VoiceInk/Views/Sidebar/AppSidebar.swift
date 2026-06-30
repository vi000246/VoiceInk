import SwiftUI

struct AppSidebar: View {
    @Binding var selectedView: ViewType

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
                SidebarItemButton(
                    viewType: viewType,
                    isSelected: selectedView == viewType
                ) {
                    selectedView = viewType
                }
            }
        }
        .padding(.horizontal, 10)
    }
}

private extension ViewType {
    var title: LocalizedStringKey {
        switch self {
        case .modes: return "Voice Modes"
        case .prompts: return "Voice Prompts"
        case .history: return "Input History"
        case .recorders: return "Recorder Devices"
        case .models: return "Transcription & AI Models"
        case .transcribeAudio: return "Manual Transcribe"
        case .audio: return "Audio Devices"
        default: return LocalizedStringKey(rawValue)
        }
    }

    /// Sidebar grouped by the two pipelines (voice input vs recorder→Obsidian) + shared/system.
    static let sidebarSections: [(title: LocalizedStringKey?, items: [ViewType])] = [
        (nil, [.dashboard]),
        ("Voice Input", [.modes, .prompts, .history]),
        ("Recorder → Obsidian", [.recorders, .categories, .recorderLog]),
        ("Shared & System", [.models, .dictionary, .transcribeAudio, .audio, .settings, .license]),
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
        case .categories: return "folder.fill.badge.gearshape"
        case .recorderLog: return "list.bullet.rectangle.fill"
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
        case .categories:
            return .init(background: AppTheme.Sidebar.fallback)
        case .recorderLog:
            return .init(background: AppTheme.Sidebar.audio)
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
            }
            .foregroundStyle(isSelected ? selectedForegroundColor : Color.primary)
            .padding(.leading, 8)
            .padding(.trailing, 10)
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
