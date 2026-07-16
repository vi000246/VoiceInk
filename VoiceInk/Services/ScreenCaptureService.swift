import Foundation
import AppKit
import Vision
import ScreenCaptureKit
import ApplicationServices

@MainActor
class ScreenCaptureService: ObservableObject {
    @Published var isCapturing = false
    @Published var lastCapturedText: String?

    private struct FocusedWindowHint: Sendable {
        let processID: pid_t
        let title: String?
        let frame: CGRect?
    }

    private static let captureTimeout: TimeInterval = 3.0
    private static let maximumCaptureDimension: CGFloat = 2800
    private static let focusedWindowFrameTolerance: CGFloat = 96

    static func requestScreenCapturePermissionRegistration() async -> Bool {
        if CGPreflightScreenCaptureAccess() {
            return true
        }

        if CGRequestScreenCaptureAccess() {
            return true
        }

        do {
            _ = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
        } catch {
            return CGPreflightScreenCaptureAccess()
        }

        return CGPreflightScreenCaptureAccess()
    }

    func captureAndExtractText() async -> String? {
        guard !isCapturing else { return nil }

        isCapturing = true
        defer {
            isCapturing = false
        }

        let currentPID = ProcessInfo.processInfo.processIdentifier
        let focusedWindowHint = makeFocusedWindowHint(excluding: currentPID)

        guard let contextText = await Self.withTimeout(seconds: Self.captureTimeout, operation: {
            await Self.captureAndExtractWindowText(
                focusedWindowHint: focusedWindowHint,
                currentPID: currentPID
            )
        }) else {
            return nil
        }

        lastCapturedText = contextText
        return contextText
    }

    // MARK: - 截圖深答:擷取為圖片(JPEG,供多模態深答)

    /// 依 target 擷取畫面為 JPEG。失敗一律回 nil(靜默,同 OCR 紀律)。
    /// - `.region` 走系統原生 `screencapture -i`(使用者互動,不受 3s 逾時限制;Esc 取消 → nil)。
    /// - `.activeWindow` / `.fullScreen` 走 ScreenCaptureKit,3s 逾時,並排除 VoiceInk 自己的視窗。
    func captureImageData(target: CopilotScreenshotTarget) async -> Data? {
        guard !isCapturing else { return nil }
        isCapturing = true
        defer { isCapturing = false }

        if target == .region {
            return await Self.captureRegionJPEG()
        }

        let currentPID = ProcessInfo.processInfo.processIdentifier
        let hint = target == .activeWindow ? makeFocusedWindowHint(excluding: currentPID) : nil
        return await Self.withTimeout(seconds: Self.captureTimeout) {
            await Self.captureJPEG(target: target, focusedWindowHint: hint, currentPID: currentPID)
        }
    }

    private nonisolated static func captureJPEG(
        target: CopilotScreenshotTarget,
        focusedWindowHint: FocusedWindowHint?,
        currentPID: pid_t
    ) async -> Data? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)
            let cgImage: CGImage
            switch target {
            case .activeWindow:
                guard let window = findActiveWindow(
                    in: content.windows, focusedWindowHint: focusedWindowHint, currentPID: currentPID
                ) else { return nil }
                let filter = SCContentFilter(desktopIndependentWindow: window)
                let configuration = SCStreamConfiguration()
                let scale = captureScale(for: window.frame.size)
                configuration.width = max(1, Int(window.frame.width * scale))
                configuration.height = max(1, Int(window.frame.height * scale))
                cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            case .fullScreen:
                guard let display = content.displays.first else { return nil }
                // 排除 VoiceInk 自己的所有視窗(overlay / pill / 讀稿面板不進截圖)——
                // 比 AI-overlay「先隱藏自己再截」更穩:根本不把自己納入擷取來源,沒有閃爍/race。
                let ownWindows = content.windows.filter { $0.owningApplication?.processID == currentPID }
                let filter = SCContentFilter(display: display, excludingWindows: ownWindows)
                let configuration = SCStreamConfiguration()
                let scale = captureScale(for: CGSize(width: display.width, height: display.height))
                configuration.width = max(1, Int(CGFloat(display.width) * scale))
                configuration.height = max(1, Int(CGFloat(display.height) * scale))
                cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)
            case .region:
                return nil   // region 在 captureImageData 已分流,不會走到這裡
            }
            return jpegData(from: cgImage)
        } catch {
            return nil
        }
    }

    /// 框選:呼叫系統 `screencapture -i`(十字準星、Esc 取消、`-x` 靜音)。使用者完成選取才寫檔;
    /// 取消時 status 仍為 0 但無檔案 → `fileExists` 守門回 nil。
    private nonisolated static func captureRegionJPEG() async -> Data? {
        let tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("voiceink-region-\(UUID().uuidString).png")
        let ok: Bool = await withCheckedContinuation { cont in
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            proc.arguments = ["-i", "-x", tmp.path]
            proc.terminationHandler = { p in cont.resume(returning: p.terminationStatus == 0) }
            do { try proc.run() } catch { cont.resume(returning: false) }
        }
        defer { try? FileManager.default.removeItem(at: tmp) }
        guard ok, FileManager.default.fileExists(atPath: tmp.path),
              let data = try? Data(contentsOf: tmp),
              let image = NSImage(data: data),
              let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil)
        else { return nil }
        return jpegData(from: cg)
    }

    /// CGImage → 縮到長邊 ≤ maxLongEdge 的 JPEG(控制多模態 token 量)。
    private nonisolated static func jpegData(
        from cgImage: CGImage, maxLongEdge: CGFloat = 1568, quality: CGFloat = 0.6
    ) -> Data? {
        let w = CGFloat(cgImage.width), h = CGFloat(cgImage.height)
        let longEdge = max(w, h)
        let scale = longEdge > maxLongEdge ? maxLongEdge / longEdge : 1
        let targetW = max(1, Int((w * scale).rounded()))
        let targetH = max(1, Int((h * scale).rounded()))
        guard let rep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: targetW, pixelsHigh: targetH,
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }
        rep.size = NSSize(width: targetW, height: targetH)
        guard let ctx = NSGraphicsContext(bitmapImageRep: rep) else { return nil }
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = ctx
        ctx.cgContext.draw(cgImage, in: CGRect(x: 0, y: 0, width: targetW, height: targetH))
        NSGraphicsContext.restoreGraphicsState()
        return rep.representation(using: .jpeg, properties: [.compressionFactor: quality])
    }

    private func makeFocusedWindowHint(excluding currentPID: pid_t) -> FocusedWindowHint? {
        guard let frontmostPID = NSWorkspace.shared.frontmostApplication?.processIdentifier,
              frontmostPID != currentPID else {
            return nil
        }

        var focusedTitle: String?
        var focusedFrame: CGRect?

        if AXIsProcessTrusted() {
            let appElement = AXUIElementCreateApplication(frontmostPID)
            if let focusedWindow = copyAXElementAttribute(kAXFocusedWindowAttribute, from: appElement) {
                focusedTitle = normalized(copyStringAttribute(kAXTitleAttribute, from: focusedWindow))

                if let position = copyCGPointAttribute(kAXPositionAttribute, from: focusedWindow),
                   let size = copyCGSizeAttribute(kAXSizeAttribute, from: focusedWindow) {
                    focusedFrame = CGRect(origin: position, size: size)
                }
            }
        }

        return FocusedWindowHint(
            processID: frontmostPID,
            title: focusedTitle,
            frame: focusedFrame
        )
    }

    private nonisolated static func captureAndExtractWindowText(
        focusedWindowHint: FocusedWindowHint?,
        currentPID: pid_t
    ) async -> String? {
        do {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: true)

            guard let window = findActiveWindow(
                in: content.windows,
                focusedWindowHint: focusedWindowHint,
                currentPID: currentPID
            ) else {
                return nil
            }

            let title = window.title ?? window.owningApplication?.applicationName ?? "Unknown"
            let appName = window.owningApplication?.applicationName ?? "Unknown"

            let filter = SCContentFilter(desktopIndependentWindow: window)

            let configuration = SCStreamConfiguration()
            let captureScale = captureScale(for: window.frame.size)
            configuration.width = max(1, Int(window.frame.width * captureScale))
            configuration.height = max(1, Int(window.frame.height * captureScale))

            let cgImage = try await SCScreenshotManager.captureImage(contentFilter: filter, configuration: configuration)

            var contextText = """
            Active Window: \(title)
            Application: \(appName)

            """

            let extractedText = extractText(from: cgImage)
            if let extractedText, !extractedText.isEmpty {
                contextText += "Window Content:\n\(extractedText)"
            } else {
                contextText += "Window Content:\nNo text detected via OCR"
            }

            return contextText

        } catch {
            return nil
        }
    }

    private nonisolated static func findActiveWindow(
        in windows: [SCWindow],
        focusedWindowHint: FocusedWindowHint?,
        currentPID: pid_t
    ) -> SCWindow? {
        let candidates = windows.filter { window in
            guard let processID = window.owningApplication?.processID else {
                return false
            }

            return processID != currentPID &&
                window.windowLayer == 0 &&
                window.isOnScreen &&
                window.frame.width > 0 &&
                window.frame.height > 0
        }

        guard let focusedWindowHint else {
            return candidates.first
        }

        let appWindows = candidates.filter {
            $0.owningApplication?.processID == focusedWindowHint.processID
        }

        guard !appWindows.isEmpty else {
            return candidates.first
        }

        if let focusedFrame = focusedWindowHint.frame,
           let closestWindow = closestFrameMatch(to: focusedFrame, in: appWindows),
           frameDistance(closestWindow.frame, focusedFrame) <= focusedWindowFrameTolerance {
            return closestWindow
        }

        if let focusedTitle = focusedWindowHint.title,
           let titledWindow = appWindows.first(where: { normalized($0.title) == focusedTitle }) {
            return titledWindow
        }

        return appWindows.first
    }

    private nonisolated static func closestFrameMatch(to frame: CGRect, in windows: [SCWindow]) -> SCWindow? {
        windows.min {
            frameDistance($0.frame, frame) < frameDistance($1.frame, frame)
        }
    }

    private nonisolated static func frameDistance(_ first: CGRect, _ second: CGRect) -> CGFloat {
        abs(first.origin.x - second.origin.x) +
            abs(first.origin.y - second.origin.y) +
            abs(first.size.width - second.size.width) +
            abs(first.size.height - second.size.height)
    }

    private nonisolated static func captureScale(for size: CGSize) -> CGFloat {
        let longestSide = max(size.width, size.height)
        guard longestSide > 0 else {
            return 1
        }

        return min(2, maximumCaptureDimension / longestSide)
    }

    private nonisolated static func extractText(from cgImage: CGImage) -> String? {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.usesLanguageCorrection = true
        request.automaticallyDetectsLanguage = true

        let requestHandler = VNImageRequestHandler(cgImage: cgImage, options: [:])

        do {
            try requestHandler.perform([request])
            guard let observations = request.results else {
                return nil
            }
            let text = observations
                .compactMap { $0.topCandidates(1).first?.string }
                .joined(separator: "\n")
            return text.isEmpty ? nil : text
        } catch {
            return nil
        }
    }

    private nonisolated static func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async -> T?
    ) async -> T? {
        await withTaskGroup(of: T?.self) { group in
            group.addTask {
                await operation()
            }

            group.addTask {
                try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
                return nil
            }

            let result = await group.next() ?? nil
            group.cancelAll()
            return result
        }
    }

    private func copyAXElementAttribute(_ attribute: String, from element: AXUIElement) -> AXUIElement? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXUIElementGetTypeID() else {
            return nil
        }

        return (value as! AXUIElement)
    }

    private func copyStringAttribute(_ attribute: String, from element: AXUIElement) -> String? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success else {
            return nil
        }

        return value as? String
    }

    private func copyCGPointAttribute(_ attribute: String, from element: AXUIElement) -> CGPoint? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID(),
              AXValueGetType(value as! AXValue) == .cgPoint else {
            return nil
        }

        let axValue = value as! AXValue
        var point = CGPoint.zero
        guard AXValueGetValue(axValue, .cgPoint, &point) else {
            return nil
        }

        return point
    }

    private func copyCGSizeAttribute(_ attribute: String, from element: AXUIElement) -> CGSize? {
        var value: CFTypeRef?
        guard AXUIElementCopyAttributeValue(element, attribute as CFString, &value) == .success,
              let value,
              CFGetTypeID(value) == AXValueGetTypeID(),
              AXValueGetType(value as! AXValue) == .cgSize else {
            return nil
        }

        let axValue = value as! AXValue
        var size = CGSize.zero
        guard AXValueGetValue(axValue, .cgSize, &size) else {
            return nil
        }

        return size
    }

    private nonisolated static func normalized(_ text: String?) -> String? {
        guard let text else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private func normalized(_ text: String?) -> String? {
        Self.normalized(text)
    }
}
