//
//  TransfersView.swift
//  JetBird
//
//  Pairing with PS MTP Explorer on the PS4 (QR code, or the "request six-digit code" flow).
//

import SwiftUI
import VisionKit

// MARK: - Link model

@MainActor
final class PS4LinkModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case working(String)
        case awaitingCode
        case failed(String)
    }

    private static let lastHostKey = "jetbird.ps4.lasthost.v1"

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var credentials: PS4Credentials?
    @Published private(set) var storage: ConsoleStorage?
    @Published var lastHost: String

    private var manual: PS4ManualPairing?

    init() {
        lastHost = UserDefaults.standard.string(forKey: Self.lastHostKey) ?? ""
        if let saved = PS4CredentialStore.load() {
            credentials = saved
            lastHost = saved.host
            DownloadManager.shared.ps4Client = PS4Client(credentials: saved)
        }
    }

    var isPaired: Bool { credentials != nil }

    // MARK: QR

    func pair(qr text: String) async {
        guard let found = PS4Credentials.fromQR(text) else {
            phase = .failed(L("This QR code is not a PS MTP Explorer code."))
            return
        }
        manual?.close()
        manual = nil
        phase = .working(L("Connecting to your PS4..."))
        do {
            try await PS4Client(credentials: found).probe()
            adopt(found)
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    // MARK: Six-digit code

    func requestCode(host rawHost: String) async {
        let host = rawHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isLocalIPv4(host) else {
            phase = .failed(L("Enter the PS4's local IPv4 address."))
            return
        }
        manual?.close()
        manual = nil
        lastHost = host
        UserDefaults.standard.set(host, forKey: Self.lastHostKey)

        phase = .working(L("Requesting a code from the PS4..."))
        do {
            manual = try await PS4ManualPairing.open(host: host)
            phase = .awaitingCode
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func submit(code: String) async {
        guard let pairing = manual else { return }
        phase = .working(L("Connecting to your PS4..."))
        do {
            let found = try await pairing.finish(code: code)
            manual = nil
            adopt(found)
        } catch {
            pairing.close()
            manual = nil
            phase = .failed(L("Pairing expired or the PS4 rejected it. Request a new code.") + "\n" + error.localizedDescription)
        }
    }

    func cancelCode() {
        manual?.close()
        manual = nil
        phase = .idle
    }

    // MARK: Paired console

    func checkConnection() async {
        guard let credentials = credentials else { return }
        phase = .working(L("Checking the connection..."))
        do {
            try await PS4Client(credentials: credentials).probe()
            phase = .idle
            await refreshStorage()
        } catch {
            phase = .failed(error.localizedDescription)
        }
    }

    func refreshStorage() async {
        guard let credentials = credentials else { return }
        storage = try? await PS4Client(credentials: credentials).storage()
    }

    func forget() {
        manual?.close()
        manual = nil
        PS4CredentialStore.delete()
        credentials = nil
        storage = nil
        DownloadManager.shared.ps4Client = nil
        phase = .idle
    }

    private func adopt(_ found: PS4Credentials) {
        PS4CredentialStore.save(found)
        credentials = found
        lastHost = found.host
        UserDefaults.standard.set(found.host, forKey: Self.lastHostKey)
        DownloadManager.shared.ps4Client = PS4Client(credentials: found)
        phase = .idle
        Task { await refreshStorage() }
    }
}

// MARK: - Transfers tab

struct TransfersView: View {
    @EnvironmentObject private var link: PS4LinkModel
    @State private var host = ""
    @State private var code = ""
    @State private var showScanner = false

    private var isBusy: Bool {
        if case .working = link.phase { return true }
        return false
    }

    private var awaitingCode: Bool {
        link.phase == .awaitingCode
    }

    var body: some View {
        NavigationStack {
            Form {
                statusSection

                Section {
                    TextField("192.168.1.100", text: $host)
                        .keyboardType(.numbersAndPunctuation)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    Button("Scan QR code") { showScanner = true }
                        .disabled(isBusy)

                    Button("Request six-digit code") {
                        code = ""
                        Task { await link.requestCode(host: host) }
                    }
                    .disabled(isBusy)
                } header: {
                    Text("Connect to PS4")
                } footer: {
                    Text("On the PS4 open PS MTP Explorer, turn on Direct Download and set Transfer Mode to Wireless. Then scan the QR code or request a six-digit code.")
                }

                if awaitingCode {
                    Section {
                        TextField("Six-digit code", text: $code)
                            .keyboardType(.numberPad)
                            .onChange(of: code) { newValue in
                                let digits = String(newValue.filter { $0.isASCII && $0.isNumber }.prefix(6))
                                if digits != newValue { code = digits }
                            }
                        Button("Connect") {
                            Task { await link.submit(code: code) }
                        }
                        .disabled(!PS4ManualPairing.isValid(code: code))
                        Button("Cancel", role: .cancel) { link.cancelCode() }
                    } header: {
                        Text("Pairing")
                    } footer: {
                        Text("Enter the six digits shown on your PS4.")
                    }
                }
            }
            .navigationTitle("Transfers")
            .onAppear { if host.isEmpty { host = link.lastHost } }
            .sheet(isPresented: $showScanner) {
                QRScannerSheet { text in
                    Task { await link.pair(qr: text) }
                }
            }
        }
    }

    @ViewBuilder
    private var statusSection: some View {
        Section("Status") {
            switch link.phase {
            case .working(let message):
                HStack { ProgressView(); Text(message) }
            case .failed(let message):
                Label(message, systemImage: "exclamationmark.triangle.fill")
                    .foregroundColor(.red)
            case .awaitingCode:
                Label("Enter the six digits shown on your PS4.", systemImage: "number")
            case .idle:
                EmptyView()
            }

            if let credentials = link.credentials {
                Label("Paired with \(credentials.host)", systemImage: "checkmark.circle.fill")
                    .foregroundColor(.green)
                if let storage = link.storage {
                    Text(L("Free space on PS4: %@ of %@",
                           ByteCountFormatter.string(fromByteCount: storage.available, countStyle: .file),
                           ByteCountFormatter.string(fromByteCount: storage.total, countStyle: .file)))
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                Button("Check connection") {
                    Task { await link.checkConnection() }
                }
                .disabled(isBusy)
                Button("Forget this PS4", role: .destructive) { link.forget() }
            } else if link.phase == .idle {
                Label("Not connected", systemImage: "wifi.slash")
            }
        }
    }
}

// MARK: - QR scanner

struct QRScannerSheet: View {
    var onCode: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            Group {
                if DataScannerViewController.isSupported && DataScannerViewController.isAvailable {
                    QRScannerView(onCode: { text in
                        dismiss()
                        onCode(text)
                    })
                    .ignoresSafeArea()
                } else {
                    Text("QR scanning is not available on this device. Enter the IP address and request a six-digit code instead.")
                        .multilineTextAlignment(.center)
                        .padding()
                }
            }
            .navigationTitle("Scan QR code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
    }
}

struct QRScannerView: UIViewControllerRepresentable {
    var onCode: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onCode: onCode) }

    func makeUIViewController(context: Context) -> DataScannerViewController {
        let controller = DataScannerViewController(
            recognizedDataTypes: [.barcode(symbologies: [.qr])],
            qualityLevel: .balanced,
            recognizesMultipleItems: false,
            isHighFrameRateTrackingEnabled: false,
            isPinchToZoomEnabled: true,
            isGuidanceEnabled: true,
            isHighlightingEnabled: true
        )
        controller.delegate = context.coordinator
        DispatchQueue.main.async { try? controller.startScanning() }
        return controller
    }

    func updateUIViewController(_ uiViewController: DataScannerViewController, context: Context) {}

    final class Coordinator: NSObject, DataScannerViewControllerDelegate {
        let onCode: (String) -> Void
        private var delivered = false

        init(onCode: @escaping (String) -> Void) {
            self.onCode = onCode
        }

        func dataScanner(_ dataScanner: DataScannerViewController,
                         didAdd addedItems: [RecognizedItem],
                         allItems: [RecognizedItem]) {
            guard !delivered else { return }
            for item in addedItems {
                if case .barcode(let barcode) = item, let text = barcode.payloadStringValue {
                    delivered = true
                    dataScanner.stopScanning()
                    onCode(text)
                    return
                }
            }
        }
    }
}
