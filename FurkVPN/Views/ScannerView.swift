import AVFoundation
import Combine
import CoreImage
import PhotosUI
import SwiftUI
import UIKit

/**
 * Full-screen QR scanner: a key, or the code on the FurkVPN TV screen. The camera fills the screen,
 * dimmed around the frame; a photo from the gallery works too (also when there is no camera).
 */
struct ScannerView: View {
    var title: String
    var hint: String
    var onCode: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    @StateObject private var camera = QRCamera()
    @State private var picking = false
    @State private var message: String?

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if camera.state == .running {
                CameraPreview(session: camera.session).ignoresSafeArea()
                ScanFrameOverlay().ignoresSafeArea()
            }
            VStack(spacing: 16) {
                HStack {
                    Button { dismiss() } label: {
                        Image(systemName: "xmark").font(.headline).frame(width: 44, height: 44)
                    }
                    .foregroundColor(.white)
                    .glassSurface(Circle(), interactive: true, fallback: .black.opacity(0.4))
                    Spacer()
                }
                Text(title).font(.title3.weight(.semibold)).foregroundColor(.white)
                Spacer()
                status
                Text(hint)
                    .font(.subheadline)
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 24)
                Button { picking = true } label: {
                    Label("Выбрать из галереи", systemImage: "photo")
                        .padding(.horizontal, 8)
                        .padding(.vertical, 4)
                }
                .glassButtonStyle()
                .tint(.white)
            }
            .padding(20)
        }
        .toast($message)
        .onAppear { camera.start() }
        .onDisappear { camera.stop() }
        .onReceive(camera.$code.compactMap { $0 }) { code in
            UINotificationFeedbackGenerator().notificationOccurred(.success)
            dismiss()
            onCode(code)
        }
        .sheet(isPresented: $picking) {
            PhotoPicker { image in
                picking = false
                guard let image else { return }
                if let code = QRCamera.code(in: image) {
                    dismiss()
                    onCode(code)
                } else {
                    message = "На изображении не найден QR-код"
                }
            }
        }
    }

    @ViewBuilder
    private var status: some View {
        switch camera.state {
        case .denied:
            VStack(spacing: 12) {
                Text("Чтобы отсканировать QR-код, нужен доступ к камере")
                    .foregroundColor(.white)
                    .multilineTextAlignment(.center)
                Button("Открыть настройки") {
                    if let url = URL(string: UIApplication.openSettingsURLString) { UIApplication.shared.open(url) }
                }
                .glassButtonStyle(prominent: true)
            }
            .padding(.horizontal, 24)
        case .unavailable:
            Text("Камера недоступна. Выберите фото QR-кода из галереи.")
                .foregroundColor(.white)
                .multilineTextAlignment(.center)
                .padding(.horizontal, 24)
        case .starting, .running:
            EmptyView()
        }
    }
}

/** The camera and the QR codes it sees. */
final class QRCamera: NSObject, ObservableObject, AVCaptureMetadataOutputObjectsDelegate {
    enum State { case starting, running, denied, unavailable }

    @Published private(set) var state: State = .starting
    @Published private(set) var code: String?
    let session = AVCaptureSession()
    private let queue = DispatchQueue(label: "com.furkvpn.scanner")
    private var configured = false

    func start() {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            run()
        case .notDetermined:
            AVCaptureDevice.requestAccess(for: .video) { granted in
                DispatchQueue.main.async {
                    if granted { self.run() } else { self.state = .denied }
                }
            }
        default:
            state = .denied
        }
    }

    func stop() {
        queue.async { if self.session.isRunning { self.session.stopRunning() } }
    }

    private func run() {
        queue.async {
            if !self.configured {
                guard let device = AVCaptureDevice.default(for: .video),
                      let input = try? AVCaptureDeviceInput(device: device), self.session.canAddInput(input) else {
                    DispatchQueue.main.async { self.state = .unavailable }
                    return
                }
                let output = AVCaptureMetadataOutput()
                guard self.session.canAddOutput(output) else {
                    DispatchQueue.main.async { self.state = .unavailable }
                    return
                }
                self.session.addInput(input)
                self.session.addOutput(output)
                output.setMetadataObjectsDelegate(self, queue: .main)
                output.metadataObjectTypes = [.qr]
                self.configured = true
            }
            self.session.startRunning()
            DispatchQueue.main.async { self.state = .running }
        }
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard code == nil,
              let value = metadataObjects.compactMap({ ($0 as? AVMetadataMachineReadableCodeObject)?.stringValue }).first,
              !value.isEmpty else { return }
        code = value
        stop()
    }

    /** The QR code on a photo, if there is one. */
    static func code(in image: UIImage) -> String? {
        guard let ciImage = CIImage(image: image),
              let detector = CIDetector(ofType: CIDetectorTypeQRCode, context: nil, options: [CIDetectorAccuracy: CIDetectorAccuracyHigh]) else { return nil }
        return detector.features(in: ciImage).compactMap { ($0 as? CIQRCodeFeature)?.messageString }.first
    }
}

private struct CameraPreview: UIViewRepresentable {
    let session: AVCaptureSession

    final class PreviewView: UIView {
        override class var layerClass: AnyClass { AVCaptureVideoPreviewLayer.self }
        var previewLayer: AVCaptureVideoPreviewLayer { layer as! AVCaptureVideoPreviewLayer }
    }

    func makeUIView(context: Context) -> PreviewView {
        let view = PreviewView()
        view.previewLayer.session = session
        view.previewLayer.videoGravity = .resizeAspectFill
        return view
    }

    func updateUIView(_ uiView: PreviewView, context: Context) {}
}

/** Dimmed everywhere but the square in the middle, with rounded corners marked. */
private struct ScanFrameOverlay: View {
    var body: some View {
        GeometryReader { geo in
            let side = min(geo.size.width, geo.size.height) * 0.68
            let frame = CGRect(x: (geo.size.width - side) / 2, y: (geo.size.height - side) / 2 - 40, width: side, height: side)
            ZStack {
                Path { path in
                    path.addRect(CGRect(origin: .zero, size: geo.size))
                    path.addRoundedRect(in: frame, cornerSize: CGSize(width: 28, height: 28))
                }
                .fill(Color.black.opacity(0.55), style: FillStyle(eoFill: true))
                RoundedRectangle(cornerRadius: 28, style: .continuous)
                    .stroke(Color.white.opacity(0.9), lineWidth: 3)
                    .frame(width: frame.width, height: frame.height)
                    .position(x: frame.midX, y: frame.midY)
            }
        }
    }
}

/** The system photo picker (no permission needed): one image. */
private struct PhotoPicker: UIViewControllerRepresentable {
    var onPick: (UIImage?) -> Void

    func makeUIViewController(context: Context) -> PHPickerViewController {
        var config = PHPickerConfiguration()
        config.filter = .images
        config.selectionLimit = 1
        let picker = PHPickerViewController(configuration: config)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ uiViewController: PHPickerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator { Coordinator(onPick: onPick) }

    final class Coordinator: NSObject, PHPickerViewControllerDelegate {
        let onPick: (UIImage?) -> Void

        init(onPick: @escaping (UIImage?) -> Void) { self.onPick = onPick }

        func picker(_ picker: PHPickerViewController, didFinishPicking results: [PHPickerResult]) {
            guard let provider = results.first?.itemProvider, provider.canLoadObject(ofClass: UIImage.self) else {
                onPick(nil)
                return
            }
            provider.loadObject(ofClass: UIImage.self) { image, _ in
                DispatchQueue.main.async { self.onPick(image as? UIImage) }
            }
        }
    }
}

enum CameraInfo {
    /** The TV's QR code is scanned with this phone's camera. */
    static var available: Bool { AVCaptureDevice.default(for: .video) != nil }
}
