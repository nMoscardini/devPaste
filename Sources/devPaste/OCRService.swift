import Foundation
import Vision
import DevPasteCore

/// On-device text recognition for captured images (spec: OCR). One image at a time, in the
/// background, never blocking capture or paste. Very large images are downsampled first.
/// The result is derived data: the image is kept, and a failure never touches it.
final class OCRService {
    private let store: HistoryStore
    private let queue = DispatchQueue(label: "com.nino.devPaste.ocr", qos: .utility)
    private let lock = NSLock()
    private var running = false
    private var _enabled = true

    /// Called on the main thread when an item's OCR state changes.
    var onUpdate: (String) -> Void = { _ in }

    init(store: HistoryStore) {
        self.store = store
    }

    var enabled: Bool {
        get { lock.lock(); defer { lock.unlock() }; return _enabled }
        set { lock.lock(); _enabled = newValue; lock.unlock() }
    }

    /// Look for images without OCR and work through them.
    func kick() {
        lock.lock()
        let start = _enabled && !running
        if start { running = true }
        lock.unlock()
        guard start else { return }
        queue.async { [weak self] in self?.drain() }
    }

    private func drain() {
        defer {
            lock.lock()
            running = false
            lock.unlock()
        }
        while enabled {
            guard let ids = try? store.pendingOCR(limit: 5), !ids.isEmpty else { return }
            for id in ids {
                guard enabled else { return }
                recognise(id)
            }
        }
    }

    private func recognise(_ id: String) {
        let state: OCRState
        var text: String?
        if let data = try? store.firstPayload(id: id, utis: PBType.imageTypes),
           let image = ImageLoader.downsample(data, maxPixel: 4096) {
            let request = VNRecognizeTextRequest()
            request.recognitionLevel = .accurate
            request.usesLanguageCorrection = true
            request.recognitionLanguages = ["en-US"]
            do {
                try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
                let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
                text = lines.isEmpty ? nil : lines.joined(separator: "\n")
                state = lines.isEmpty ? .none : .ready
            } catch {
                state = .failed
                Log.store.error("ocr.failed error=\(String(describing: error), privacy: .public)")
            }
        } else {
            state = .failed
        }
        do { try store.setOCR(id: id, state: state, text: text) } catch {
            Log.store.error("ocr.saveFailed error=\(String(describing: error), privacy: .public)")
        }
        Log.store.info("ocr.done state=\(state.rawValue, privacy: .public)")
        DispatchQueue.main.async { self.onUpdate(id) }
    }
}
