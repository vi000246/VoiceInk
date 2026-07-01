import SwiftUI
import AVFoundation

/// Sequential player for a recording that was split into chunks for cloud transcription. Lists each
/// chunk as a clickable row; playing one auto-advances to the next when it finishes, so the whole
/// recording plays end-to-end while each segment stays individually seekable.
struct RecorderChunkPlayerView: View {
    let urls: [URL]
    @StateObject private var playerManager = AudioPlayerManager()
    @State private var currentIndex: Int = 0

    private var currentURL: URL? { urls.indices.contains(currentIndex) ? urls[currentIndex] : nil }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 6) {
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.system(size: 11)).foregroundStyle(AppTheme.Accent.primary)
                Text("分割錄音・共 \(urls.count) 段").font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    playerManager.cyclePlaybackRate()
                } label: {
                    Text(rateLabel).font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.primary)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Capsule().fill(playerManager.playbackRate == 1.0
                            ? AppTheme.Surface.subtle : AppTheme.Surface.controlActive))
                }
                .buttonStyle(.plain).help("播放速度")
            }

            WaveformView(
                samples: playerManager.waveformSamples,
                currentTime: playerManager.currentTime,
                duration: playerManager.duration,
                isLoading: playerManager.isLoadingWaveform,
                onSeek: { playerManager.seek(to: $0) }
            )
            .padding(.horizontal, 4)

            VStack(spacing: 3) {
                ForEach(Array(urls.enumerated()), id: \.offset) { index, url in
                    chunkRow(index: index, url: url)
                }
            }
        }
        .padding(10)
        .background(AppTheme.Surface.control, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(AppTheme.Border.control, lineWidth: 0.5))
        .onAppear { load(index: 0, autoplay: false) }
        .onChange(of: playerManager.isPlaying) { _, playing in
            // Auto-advance: AudioPlayerManager resets to 0 and pauses at end of a chunk.
            if !playing, playerManager.duration > 0,
               playerManager.currentTime == 0, currentIndex < urls.count - 1 {
                load(index: currentIndex + 1, autoplay: true)
            }
        }
        .onDisappear { playerManager.cleanup() }
    }

    private var rateLabel: String {
        playerManager.playbackRate == 1.0 ? "1×" : playerManager.playbackRate == 1.5 ? "1.5×" : "2×"
    }

    @ViewBuilder private func chunkRow(index: Int, url: URL) -> some View {
        let isCurrent = index == currentIndex
        Button {
            if isCurrent {
                playerManager.isPlaying ? playerManager.pause() : playerManager.play()
            } else {
                load(index: index, autoplay: true)
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: (isCurrent && playerManager.isPlaying) ? "pause.circle.fill" : "play.circle.fill")
                    .font(.system(size: 15))
                    .foregroundStyle(isCurrent ? AppTheme.Accent.primary : Color.secondary)
                Text("片段 \(index + 1)").font(.system(size: 12, weight: isCurrent ? .semibold : .regular))
                Spacer()
                if isCurrent {
                    Text(timecode).font(.system(size: 10)).monospacedDigit().foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
            .padding(.vertical, 4).padding(.horizontal, 8)
            .background((isCurrent ? AppTheme.Accent.primary.opacity(0.10) : Color.clear),
                        in: RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
    }

    private var timecode: String {
        func fmt(_ t: TimeInterval) -> String { String(format: "%d:%02d", Int(t) / 60, Int(t) % 60) }
        return "\(fmt(playerManager.currentTime)) / \(fmt(playerManager.duration))"
    }

    private func load(index: Int, autoplay: Bool) {
        guard urls.indices.contains(index) else { return }
        currentIndex = index
        playerManager.cleanup()
        playerManager.loadAudio(from: urls[index])
        if autoplay {
            // Give AVAudioPlayer a beat to prepare before starting.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                if currentIndex == index { playerManager.play() }
            }
        }
    }
}
