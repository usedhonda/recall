import SwiftUI
import UIKit
import AVFoundation

struct QRScannerView: View {
    @Environment(\.dismiss) private var dismiss
    let onScanned: (String) -> Void

    @State private var isScanning = true
    @State private var errorMessage: String?
    @State private var showError = false

    var body: some View {
        NavigationStack {
            ZStack {
                QRCameraPreview(onScanned: handleScanned)
                    .ignoresSafeArea()

                VStack {
                    Spacer()

                    RoundedRectangle(cornerRadius: 16)
                        .stroke(RecallTheme.Colors.neonCyan, lineWidth: 3)
                        .frame(width: 250, height: 250)
                        .background(Color.clear)

                    Spacer()

                    Text("Scan ClawGate QR Code")
                        .font(RecallTheme.Fonts.hudBody)
                        .foregroundStyle(RecallTheme.Colors.textPrimary)
                        .padding()
                        .background(RecallTheme.Colors.surface.opacity(0.9))
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                        .padding(.bottom, 50)
                }
            }
            .background(Color.black)
            .navigationTitle("QR Scanner")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                    .foregroundStyle(RecallTheme.Colors.neonCyan)
                }
            }
            .alert("Invalid QR Code", isPresented: $showError) {
                Button("OK") {
                    showError = false
                }
            } message: {
                Text(errorMessage ?? "Unknown error")
            }
        }
    }

    private func handleScanned(_ code: String) {
        guard isScanning else { return }
        isScanning = false

        if code.hasPrefix("openclaw://connect") {
            onScanned(code)
            dismiss()
        } else {
            errorMessage = "Expected openclaw://connect?... format.\nPlease scan a ClawGate QR code."
            showError = true
            isScanning = true
        }
    }
}

// MARK: - Camera Preview

private struct QRCameraPreview: UIViewRepresentable {
    let onScanned: (String) -> Void

    func makeUIView(context: Context) -> QRCameraPreviewView {
        let view = QRCameraPreviewView()
        view.onScanned = onScanned
        return view
    }

    func updateUIView(_ uiView: QRCameraPreviewView, context: Context) {}
}

private class QRCameraPreviewView: UIView {
    var onScanned: ((String) -> Void)?

    private var captureSession: AVCaptureSession?
    private var previewLayer: AVCaptureVideoPreviewLayer?

    override init(frame: CGRect) {
        super.init(frame: frame)
        setupCamera()
    }

    required init?(coder: NSCoder) {
        super.init(coder: coder)
        setupCamera()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        previewLayer?.frame = bounds
    }

    private func setupCamera() {
        let session = AVCaptureSession()
        captureSession = session

        guard let videoCaptureDevice = AVCaptureDevice.default(for: .video) else {
            showNoCameraMessage()
            return
        }

        let videoInput: AVCaptureDeviceInput
        do {
            videoInput = try AVCaptureDeviceInput(device: videoCaptureDevice)
        } catch {
            showNoCameraMessage()
            return
        }

        if session.canAddInput(videoInput) {
            session.addInput(videoInput)
        } else {
            showNoCameraMessage()
            return
        }

        let metadataOutput = AVCaptureMetadataOutput()

        if session.canAddOutput(metadataOutput) {
            session.addOutput(metadataOutput)
            metadataOutput.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
            metadataOutput.metadataObjectTypes = [.qr]
        } else {
            showNoCameraMessage()
            return
        }

        let previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.frame = bounds
        previewLayer.videoGravity = .resizeAspectFill
        layer.addSublayer(previewLayer)
        self.previewLayer = previewLayer

        DispatchQueue.global(qos: .userInitiated).async {
            session.startRunning()
        }
    }

    private func showNoCameraMessage() {
        let label = UILabel()
        label.text = "Camera not available"
        label.textColor = .white
        label.textAlignment = .center
        label.frame = bounds
        label.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(label)
        backgroundColor = .black
    }

    deinit {
        captureSession?.stopRunning()
    }
}

extension QRCameraPreviewView: AVCaptureMetadataOutputObjectsDelegate {
    func metadataOutput(_ output: AVCaptureMetadataOutput,
                        didOutput metadataObjects: [AVMetadataObject],
                        from connection: AVCaptureConnection) {
        guard let metadataObject = metadataObjects.first,
              let readableObject = metadataObject as? AVMetadataMachineReadableCodeObject,
              let stringValue = readableObject.stringValue else {
            return
        }

        AudioServicesPlaySystemSound(SystemSoundID(kSystemSoundID_Vibrate))
        onScanned?(stringValue)
    }
}
