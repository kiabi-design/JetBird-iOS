//
//  TransfersView.swift
//  JetBird
//

import SwiftUI
import Network
import VisionKit

// MARK: - Link model

@MainActor
final class PS4LinkModel: ObservableObject {
    enum Phase: Equatable {
        case idle
        case connecting
        case pairing
        case paired(String)
        case failed(String)
    }

    struct SavedConsole: Codable, Hashable {
        let name: String
        let certificateHash: String
    }

    private static let storageKey = "jetbird.consoles.v1"

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var saved: [SavedConsole] = []
    private var connection: PSMTPConnection?

    init() {
        if let data = UserDefaults.standard.data(forKey: Self.storageKey),
           let list = try? JSONDecoder().decode([SavedConsole].self, from: data) {
            saved = list
        }
    }

    var isPaired: Bool {
        if case .paired = phase { return true }
        return false
    }

    func pair(name: String, endpoint: NWEndpoint, certificateHash: String?, code: UInt32, pin: Data) async {
        phase = .connecting
        let pinned = certificateHash ?? saved.first(where: { $0.name == name })?.certificateHash
        let newConnection = PSMTPConnection(endpoint: endpoint, certificateHash: pinned)
        do {
            try await newConnection.connect()
            phase = .pairing
            _ = try await newConnection.pair(code: code, pin: pin)

            connection?.close()
            connection = newConnection
            DownloadManager.shared.ps4Link = newConnection
            if let hash = newConnection.observedCertificateHash { remember(name: name, hash: hash) }
            phase = .paired(name)
        } catch {
            newConnection.close()
            phase = .failed(error.localizedDescription)
        }
    }

    func disconnect() {
        connection?.close()
        connection = nil
        DownloadManager.shared.ps4Link = nil
        phase = .idle
    }

    private func remember(name: String, hash: String) {
        saved.removeAll { $0.name == name }
        saved.append(SavedConsole(name: name, certificateHash: hash))
        if let data = try? JSONEncoder().encode(saved) {
            UserDefaults.standard.set(data, forKey: Self.storageKey)
        }
    }
}

// MARK: - Transfers tab

struct PairingTarget: Identifiable {
    let id = UUID()
    let name: String
    let endpoint: NWEndpoint?
    let certificateHash: String?
}

struct TransfersView: View {
    @EnvironmentObject private var discovery: PSMTPDiscovery
    @EnvironmentObject private var link: PS4LinkModel
    @State private var target: PairingTarget?

    var body: some View {
        NavigationStack {
            List {
                Section("Status") {
                    statusRow
                    if link.isPaired {
                        Button("Disconnect", role: .destructive) { link.disconnect() }
                    }
                }

                Section {
                    ForEach(discovery.consoles) { console in
                        Button {
                            target = PairingTarget(
                                name: console.name,
                                endpoint: console.endpoint,
                                certificateHash: console.certificateHash
                            )
                        } label: {
                            HStack {
                                Image(systemName: "gamecontroller")
                                Text(console.name)
                                Spacer()
                                Image(systemName: "chevron.right").foregroundColor(.secondary)
                            }
                        }
                    }
                    if discovery.consoles.isEmpty {
                        Text(discovery.isSearching ? "Searching your Wi-Fi network..." : "Not searching")
                            .foregroundColor(.secondary)
                    }
                } header: {
                    Text("Nearby consoles")
                } footer: {
                    Text("Start PS MTP Explorer on the PS4. The phone and the console must be on the same network.")
                }

                Section {
                    Button("Pair by IP address") {
                        target = PairingTarget(name: "PS4", endpoint: nil, certificateHash: nil)
                    }
                }
            }
            .navigationTitle("Transfers")
            .onAppear { discovery.start() }
            .onDisappear { discovery.stop() }
            .sheet(item: $target) { item in PairingView(target: item) }
        }
    }

    @ViewBuilder
    private var statusRow: some View {
        switch link.phase {
        case .idle:
            Label("Not connected", systemImage: "wifi.slash")
        case .connecting:
            HStack { ProgressView(); Text("Connecting...") }
        case .pairing:
            HStack { ProgressView(); Text("Pairing...") }
        case .paired(let name):
            Label("Paired with \(name)", systemImage: "checkmark.circle.fill")
                .foregroundColor(.green)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .foregroundColor(.red)
        }
    }
}

// MARK: - Pairing sheet

struct PairingView: View {
    let target: PairingTarget

    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var link: PS4LinkModel

    @State private var host = ""
    @State private var codeText = ""
    @State private var pinText = ""
    @State private var showScanner = false
    @State private var errorText: String?
    @State private var isBusy = false

    var body: some View {
        NavigationStack {
            Form {
                if target.endpoint == nil {
                    Section("Console address") {
                        TextField("IP address, e.g. 192.168.1.20", text: $host)
                            .keyboardType(.numbersAndPunctuation)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                    }
                }

                Section {
                    TextField("6-digit code", text: $codeText)
                        .keyboardType(.numberPad)
                    TextField("PIN (Base64)", text: $pinText)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    Button("Scan QR code") { showScanner = true }
                } header: {
                    Text("Pairing")
                } footer: {
                    Text("Scan the QR code shown by the PS4, or enter the code and the Base64 PIN manually.")
                }

                if let errorText = errorText {
                    Section { Text(errorText).foregroundColor(.red) }
                }

                Section {
                    Button {
                        Task { await connect() }
                    } label: {
                        if isBusy { ProgressView() } else { Text("Pair") }
                    }
                    .disabled(isBusy)
                }
            }
            .navigationTitle(target.name)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
            .sheet(isPresented: $showScanner) {
                QRScannerSheet { text in handleScan(text) }
            }
        }
    }

    private func handleScan(_ text: String) {
        if let (code, pin) = Spake2Manager.parseQRCode(text) {
            codeText = String(format: "%06u", code)
            pinText = pin.base64EncodedString()
            errorText = nil
            showScanner = false
        } else {
            errorText = "This QR code is not a JetBird pairing code."
            showScanner = false
        }
    }

    private func connect() async {
        errorText = nil
        guard let code = UInt32(codeText.trimmingCharacters(in: .whitespaces)), code < 1_000_000 else {
            errorText = "The code must be 6 digits."
            return
        }
        guard let pin = Data(base64Encoded: pinText.trimmingCharacters(in: .whitespacesAndNewlines)),
              pin.count == 16 else {
            errorText = "The PIN must be 16 bytes, Base64 encoded."
            return
        }

        let endpoint: NWEndpoint
        var name = target.name
        if let existing = target.endpoint {
            endpoint = existing
        } else {
            let trimmed = host.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty, let port = NWEndpoint.Port(rawValue: PSMTP.defaultPort) else {
                errorText = "Enter the console IP address."
                return
            }
            endpoint = NWEndpoint.hostPort(host: NWEndpoint.Host(trimmed), port: port)
            name = trimmed
        }

        isBusy = true
        await link.pair(name: name, endpoint: endpoint, certificateHash: target.certificateHash, code: code, pin: pin)
        isBusy = false

        if link.isPaired {
            dismiss()
        } else if case .failed(let message) = link.phase {
            errorText = message
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
                    QRScannerView(onCode: onCode)
                        .ignoresSafeArea()
                } else {
                    Text("QR scanning is not available on this device. Enter the code and PIN manually.")
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
