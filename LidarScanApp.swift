// Scanner 3D : capture guidée LiDAR + reconstruction par photogrammétrie (SfM/MVS) 100 % sur l'iPhone.
// Prérequis : iOS 17+, iPhone avec LiDAR (12 Pro ou plus récent, modèles Pro), appareil réel (pas le simulateur).
import SwiftUI
import RealityKit
import QuickLook

@main
struct LidarScanApp: App {
    var body: some Scene { WindowGroup { RootView() } }
}

enum Phase {
    case idle
    case capturing
    case reconstructing(Double)
    case done(URL)
    case failed(String)
}

@MainActor
final class ScanModel: ObservableObject {
    @Published var phase: Phase = .idle
    @Published var session: ObjectCaptureSession?
    @Published var captureState: ObjectCaptureSession.CaptureState = .initializing
    @Published var passDone = false
    private var folder = URL.documentsDirectory

    func start() {
        guard ObjectCaptureSession.isSupported else {
            phase = .failed("Cet iPhone n'a pas de LiDAR (iPhone 12 Pro ou plus récent requis).")
            return
        }
        do {
            let base = URL.documentsDirectory.appending(path: "Scan-\(Int(Date().timeIntervalSince1970))")
            let images = base.appending(path: "Images")
            let snaps = base.appending(path: "Snapshots")
            for dir in [images, snaps] {
                try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            }
            folder = base
            passDone = false
            captureState = .initializing

            let s = ObjectCaptureSession()
            var cfg = ObjectCaptureSession.Configuration()
            cfg.checkpointDirectory = snaps
            s.start(imagesDirectory: images, configuration: cfg)
            session = s
            phase = .capturing

            Task { for await st in s.stateUpdates { onState(st) } }
            Task { for await done in s.userCompletedScanPassUpdates { passDone = done } }
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    private func onState(_ st: ObjectCaptureSession.CaptureState) {
        captureState = st
        switch st {
        case .completed:
            session = nil
            reconstruct()
        case .failed(let error):
            session = nil
            if case ObjectCaptureSession.Error.cancelled = error { phase = .idle }
            else { phase = .failed(error.localizedDescription) }
        default:
            break
        }
    }

    // Reconstruction locale (SfM + stéréo multi-vues d'Apple, avec la profondeur LiDAR des images).
    private func reconstruct() {
        phase = .reconstructing(0)
        let output = folder.appending(path: "model.usdz")
        Task {
            var lastError = "Reconstruction impossible."
            for detail in [PhotogrammetrySession.Request.Detail.reduced, .preview] {
                do {
                    var cfg = PhotogrammetrySession.Configuration()
                    cfg.checkpointDirectory = folder.appending(path: "Snapshots")
                    let s = try PhotogrammetrySession(input: folder.appending(path: "Images"), configuration: cfg)
                    try s.process(requests: [.modelFile(url: output, detail: detail)])
                    for try await o in s.outputs {
                        switch o {
                        case .requestProgress(_, let f): phase = .reconstructing(f)
                        case .requestComplete: phase = .done(output); return
                        case .requestError(_, let e): lastError = e.localizedDescription
                        default: break
                        }
                    }
                } catch {
                    lastError = error.localizedDescription
                }
            }
            phase = .failed(lastError)
        }
    }
}

struct RootView: View {
    @StateObject private var m = ScanModel()
    @State private var preview: URL?

    var body: some View {
        Group {
            switch m.phase {
            case .idle:
                VStack(spacing: 20) {
                    Image(systemName: "cube.transparent").font(.system(size: 64))
                    Text("Scanner 3D LiDAR").font(.title.bold())
                    Button("Nouveau scan") { m.start() }
                        .buttonStyle(.borderedProminent).controlSize(.large)
                }
            case .capturing:
                if let s = m.session {
                    ZStack(alignment: .bottom) {
                        ObjectCaptureView(session: s).ignoresSafeArea()
                        HStack(spacing: 16) {
                            Button("Annuler", role: .destructive) { s.cancel() }
                            switch m.captureState {
                            case .ready: Button("Continuer") { s.startDetecting() }
                            case .detecting: Button("Lancer la capture") { s.startCapturing() }
                            case .capturing where m.passDone: Button("Terminer") { s.finish() }
                            default: EmptyView()
                            }
                        }
                        .buttonStyle(.borderedProminent)
                        .padding(.bottom, 32)
                    }
                }
            case .reconstructing(let p):
                VStack(spacing: 16) {
                    ProgressView(value: p)
                    Text("Reconstruction 3D sur l'iPhone… \(Int(p * 100)) %")
                }
                .padding()
            case .done(let url):
                VStack(spacing: 16) {
                    Button("Voir / partager le modèle") { preview = url }
                        .buttonStyle(.borderedProminent)
                    Button("Nouveau scan") { m.start() }
                }
            case .failed(let msg):
                VStack(spacing: 16) {
                    Text(msg).multilineTextAlignment(.center)
                    Button("Recommencer") { m.start() }
                }
                .padding()
            }
        }
        .quickLookPreview($preview)
    }
}
