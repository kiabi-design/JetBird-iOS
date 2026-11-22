//
//  PairingView.swift
//  JetBirdUI
//
//  SPAKE2 pairing with PS4 via QR code or 6-digit code
//

import SwiftUI
import VisionKit
import JetBirdCore

struct PairingView: View {
    @EnvironmentObject var spake2Manager: Spake2Manager
    @Environment(\.dismiss) var dismiss

    @State private var pairingStep: PairingStep = .enterCode
    @State private var code = ""
    @State private var pin = ""
    @State private var qrCodeImage: UIImage?
    @State private var isScanning = false
    @State private var isPairing = false
    @State private var error: String?
    @State private var pairingSuccess = false
    @State private var showManualEntry = false

    enum PairingStep: CaseIterable {
        case enterCode
        case scanQR
        case pairing
        case success
        case failure

        var title: String {
            switch self {
            case .enterCode: return "Enter Pairing Code"
            case .scanQR: return "Scan QR Code"
            case .pairing: return "Pairing..."
            case .success: return "Paired Successfully"
            case .failure: return "Pairing Failed"
            }
        }
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 32) {
                // Step indicator
                HStack {
                    ForEach(PairingStep.allCases.indices, id: \.self) { index in
                        let step = PairingStep.allCases[index]
                        Circle()
                            .fill(stepIndex(step) <= stepIndex(pairingStep) ? Color.accentColor : Color.secondary.opacity(0.3))
                            .frame(width: 12, height: 12)

                        if index < PairingStep.allCases.count - 1 {
                            Rectangle()
                                .fill(stepIndex(PairingStep.allCases[index + 1]) <= stepIndex(pairingStep) ? Color.accentColor : Color.secondary.opacity(0.3))
                                .frame(height: 2)
                        }
                    }
                }
                .padding(.horizontal, 40)

                Spacer()

                // Content based on step
                Group {
                    switch pairingStep {
                    case .enterCode:
                        EnterCodeView(
                            code: $code,
                            pin: $pin,
                            onSubmit: { startPairing() },
                            onScanQR: { pairingStep = .scanQR }
                        )

                    case .scanQR:
                        QRScannerView(onResult: { result in
                            handleQRResult(result)
                        })

                    case .pairing:
                        PairingProgressView()

                    case .success:
                        SuccessView(
                            qrCodeImage: qrCodeImage,
                            onDone: { dismiss() }
                        )

                    case .failure:
                        FailureView(
                            error: error ?? "Unknown error",
                            onRetry: { pairingStep = .enterCode },
                            onCancel: { dismiss() }
                        )
                    }
                }

                Spacer()

                // Manual entry toggle
                if pairingStep == .scanQR {
                    Button("Enter Code Manually") {
                        pairingStep = .enterCode
                    }
                    .font(.subheadline)
                }
            }
            .padding()
            .navigationTitle("Pair with PS4")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    if pairingStep != .success && pairingStep != .failure {
                        Button("Cancel") { dismiss() }
                    }
                }
            }
            .alert("Error", isPresented: .constant(error != nil)) {
                Button("OK") { error = nil }
            } message: {
                Text(error ?? "")
            }
        }
    }

    private func stepIndex(_ step: PairingStep) -> Int {
        PairingStep.allCases.firstIndex(of: step) ?? 0
    }

    private func startPairing() {
        guard code.count == 6, let codeInt = UInt32(code) else {
            error = "Enter a valid 6-digit code"
            return
        }

        guard pin.count == 16 || pin.isEmpty else {
            error = "PIN must be 16 characters"
            return
        }

        let pinData = pin.isEmpty ? Data(repeating: 0, count: 16) : Data(pin.utf8)
        if pinData.count != 16 {
            // Pad or truncate
            var padded = Data(repeating: 0, count: 16)
            let copyCount = min(pinData.count, 16)
            padded.replaceSubrange(0..<copyCount, with: pinData.prefix(copyCount))
        }

        pairingStep = .pairing

        Task {
            do {
                // Start SPAKE2 pairing as phone
                let ourPoint = try await spake2Manager.startPairingAsPhone(
                    code: codeInt,
                    pin: pinData
                )

                // Generate QR code for PS4 to scan
                if let qrString = await spake2Manager.generateQRCodeData() {
                    qrCodeImage = generateQRCode(from: qrString)
                }

                // In real implementation:
                // 1. Send ourPoint to PS4 via local network (Bonjour/mDNS)
                // 2. Receive theirPoint and proofs from PS4
                // 3. Complete pairing

                // For demo, simulate success after delay
                try await Task.sleep(nanoseconds: 2_000_000_000)

                await MainActor.run {
                    pairingStep = .success
                }

            } catch {
                await MainActor.run {
                    self.error = error.localizedDescription
                    pairingStep = .failure
                }
            }
        }
    }

    private func handleQRResult(_ result: String) {
        if let (code, pin) = Spake2Manager.parseQRCode(result) {
            self.code = String(format: "%06d", code)
            self.pin = pin.map { String(format: "%02x", $0) }.joined()
            pairingStep = .enterCode
        } else {
            error = "Invalid QR code format"
        }
    }

    private func generateQRCode(from string: String) -> UIImage? {
        let data = string.data(using: .utf8)!
        let filter = CIFilter.qrCodeGenerator()
        filter.setValue(data, forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")

        guard let output = filter.outputImage else { return nil }

        let context = CIContext()
        guard let cgImage = context.createCGImage(output, from: output.extent) else { return nil }

        return UIImage(cgImage: cgImage)
    }
}

// MARK: - Enter Code View

struct EnterCodeView: View {
    @Binding var code: String
    @Binding var pin: String
    let onSubmit: () -> Void
    let onScanQR: () -> Void

    @FocusState private var focusedField: Field?

    enum Field: Hashable {
        case code, pin
    }

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "playstation.logo")
                .font(.system(size: 64))
                .foregroundStyle(.blue)

            Text("On your PS4, open PS MTP Explorer and go to Settings → Direct Download → Wireless Transfer")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)

            VStack(spacing: 16) {
                // Code field
                VStack(alignment: .leading, spacing: 8) {
                    Text("6-Digit Code")
                        .font(.headline)

                    TextField("123456", text: $code)
                        .textContentType(.oneTimeCode)
                        .keyboardType(.numberPad)
                        .focused($focusedField, equals: .code)
                        .font(.system(size: 32, weight: .medium, design: .monospaced))
                        .multilineTextAlignment(.center)
                        .onChange(of: code) { _, newValue in
                            code = String(newValue.filter { $0.isNumber }.prefix(6))
                            if code.count == 6 {
                                focusedField = .pin
                            }
                        }
                        .padding()
                        .background(.regularMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }

                // PIN field (optional)
                VStack(alignment: .leading, spacing: 8) {
                    Text("PIN (optional, from QR)")
                        .font(.headline)

                    SecureField("16 characters", text: $pin)
                        .focused($focusedField, equals: .pin)
                        .font(.system(size: 16, design: .monospaced))
                        .padding()
                        .background(.regularMaterial)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                }
            }
            .padding(.horizontal)

            Button(action: onSubmit) {
                Text("Start Pairing")
                    .font(.headline)
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(code.count == 6 ? Color.accentColor : Color.gray)
                    .foregroundStyle(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }
            .disabled(code.count != 6)
            .padding(.horizontal)

            Button(action: onScanQR) {
                Label("Scan QR Code Instead", systemImage: "qrcode.viewfinder")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

// MARK: - QR Scanner View

struct QRScannerView: View {
    let onResult: (String) -> Void
    @Environment(\.dismiss) var dismiss
    @State private var showScanner = true

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "qrcode.viewfinder")
                .font(.system(size: 64))
                .foregroundStyle(.blue)

            Text("Point camera at PS4 QR code")
                .font(.headline)
                .multilineTextAlignment(.center)

            Text("The QR code contains the pairing code and PIN")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            if showScanner {
                QRCodeScannerView(onResult: { result in
                    onResult(result)
                    showScanner = false
                })
                .frame(height: 300)
                .clipShape(RoundedRectangle(cornerRadius: 16))
                .padding(.horizontal)
            }

            Button("Cancel") {
                dismiss()
            }
            .foregroundStyle(.secondary)
        }
    }
}

struct QRCodeScannerView: UIViewControllerRepresentable {
    let onResult: (String) -> Void

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let scanner = DataScannerViewController(
            recognizedDataTypes: [.barcode()],
            qualityLevel: .accurate,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isPinchToZoomEnabled: true,
            isGuidanceEnabled: true,
            isHighlightingEnabled: true
        )

        scanner.delegate = context.coordinator
        try? scanner.startScanning()

        return scanner
    }

    func updateUIViewController(_ uiViewController: DataScannerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onResult: onResult)
    }

    class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onResult: (String) -> Void

        init(onResult: @escaping (String) -> Void) {
            self.onResult = onResult
        }

        func dataScanner(_ dataScanner: DataScannerViewController, didTapOn item: RecognizedItem) {
            if case .barcode(let barcode) = item {
                if let payload = barcode.payloadStringValue {
                    onResult(payload)
                }
            }
        }
    }
}

// MARK: - Pairing Progress View

struct PairingProgressView: View {
    @State private var progress = 0.0
    @State private var message = "Connecting to PS4..."

    let steps = [
        "Connecting to PS4...",
        "Exchanging keys...",
        "Verifying identity...",
        "Establishing secure channel...",
        "Complete!"
    ]

    var body: some View {
        VStack(spacing: 24) {
            ProgressView()
                .scaleEffect(1.5)

            Text(message)
                .font(.headline)
                .multilineTextAlignment(.center)

            ProgressView(value: progress, total: 1.0)
                .progressViewStyle(.linear)
                .frame(width: 200)

            // Simulate progress
            .onAppear {
                animateProgress()
            }
        }
    }

    private func animateProgress() {
        for (index, step) in steps.enumerated() {
            DispatchQueue.main.asyncAfter(deadline: .now() + Double(index) * 0.8) {
                withAnimation(.easeInOut(duration: 0.5)) {
                    message = step
                    progress = Double(index + 1) / Double(steps.count)
                }
            }
        }
    }
}

// MARK: - Success View

struct SuccessView: View {
    let qrCodeImage: UIImage?
    let onDone: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 80))
                .foregroundStyle(.green)

            Text("Successfully Paired!")
                .font(.title)
                .fontWeight(.bold)

            Text("Your iPhone is now paired with PS4 for wireless transfers.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)

            if let qrCode = qrCodeImage {
                VStack(spacing: 8) {
                    Text("Pairing QR Code (for reference)")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Image(uiImage: qrCode)
                        .interpolation(.none)
                        .resizable()
                        .frame(width: 150, height: 150)
                        .background(.white)
                        .clipShape(RoundedRectangle(cornerRadius: 8))
                }
            }

            Button("Done", action: onDone)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
    }
}

// MARK: - Failure View

struct FailureView: View {
    let error: String
    let onRetry: () -> Void
    let onCancel: () -> Void

    var body: some View {
        VStack(spacing: 24) {
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 80))
                .foregroundStyle(.red)

            Text("Pairing Failed")
                .font(.title)
                .fontWeight(.bold)

            Text(error)
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
                .padding(.horizontal)

            HStack(spacing: 16) {
                Button("Try Again", action: onRetry)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)

                Button("Cancel", action: onCancel)
                    .buttonStyle(.bordered)
                    .controlSize(.large)
            }
        }
    }
}