//
//  QRScannerView.swift
//  Reattach
//

import SwiftUI
import AVFoundation
import WebKit

struct QRScannerView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var isScanning = true
    @State private var scannedURL: String?
    @State private var isRegistering = false
    @State private var errorMessage: String?
    @State private var showError = false
    @State private var showCloudflareAuth = false
    @State private var pendingServerURL: String?
    @State private var pendingSetupToken: String?

    var body: some View {
        NavigationStack {
            ZStack {
                QRCodeScannerRepresentable(
                    isScanning: $isScanning,
                    onCodeScanned: handleScannedCode
                )
                .ignoresSafeArea()

                VStack {
                    Spacer()

                    if isRegistering {
                        VStack(spacing: 12) {
                            ProgressView()
                                .scaleEffect(1.5)
                            Text("Registering device...")
                                .font(.headline)
                        }
                        .padding(32)
                        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
                    }

                    Spacer()

                    Text("Scan QR code from reattachd setup")
                        .font(.subheadline)
                        .foregroundStyle(.white)
                        .padding()
                        .background(.black.opacity(0.6), in: RoundedRectangle(cornerRadius: 8))
                        .padding(.bottom, 50)
                }
            }
            .navigationTitle("Scan QR Code")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        dismiss()
                    }
                }
            }
            .alert("Error", isPresented: $showError) {
                Button("OK") {
                    isScanning = true
                }
            } message: {
                Text(errorMessage ?? "Unknown error")
            }
            .fullScreenCover(isPresented: $showCloudflareAuth) {
                if let serverURL = pendingServerURL {
                    CloudflareAuthView(
                        serverURL: serverURL,
                        onAuthenticated: {
                            showCloudflareAuth = false
                            if let url = pendingServerURL, let token = pendingSetupToken {
                                registerDevice(serverURL: url, setupToken: token)
                            }
                        },
                        onCancel: {
                            showCloudflareAuth = false
                            isScanning = true
                        }
                    )
                }
            }
        }
    }

    private func handleScannedCode(_ code: String) {
        guard isScanning else { return }
        isScanning = false

        guard let url = URL(string: code),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let setupToken = components.queryItems?.first(where: { $0.name == "setup_token" })?.value
        else {
            errorMessage = "Invalid QR code format"
            showError = true
            return
        }

        var baseComponents = components
        baseComponents.queryItems = nil
        guard let baseURL = baseComponents.url?.absoluteString else {
            errorMessage = "Invalid server URL"
            showError = true
            return
        }

        pendingServerURL = baseURL
        pendingSetupToken = setupToken
        registerDevice(serverURL: baseURL, setupToken: setupToken)
    }

    private func registerDevice(serverURL: String, setupToken: String) {
        isRegistering = true

        Task {
            do {
                let deviceName = UIDevice.current.name
                let registerURL = URL(string: "\(serverURL)/register")!

                let config = URLSessionConfiguration.default
                config.httpCookieAcceptPolicy = .always
                config.httpShouldSetCookies = true
                config.httpCookieStorage = .shared
                let session = URLSession(configuration: config)

                var request = URLRequest(url: registerURL)
                request.httpMethod = "POST"
                request.setValue("application/json", forHTTPHeaderField: "Content-Type")
                request.httpShouldHandleCookies = true

                let body = ["setup_token": setupToken, "device_name": deviceName]
                request.httpBody = try JSONEncoder().encode(body)

                let (data, response) = try await session.data(for: request)

                guard let httpResponse = response as? HTTPURLResponse else {
                    throw NSError(domain: "Reattach", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid response"])
                }

                if let contentType = httpResponse.value(forHTTPHeaderField: "Content-Type"),
                   contentType.contains("text/html") {
                    await MainActor.run {
                        isRegistering = false
                        showCloudflareAuth = true
                    }
                    return
                }

                if httpResponse.statusCode == 302 || httpResponse.statusCode == 303 {
                    await MainActor.run {
                        isRegistering = false
                        showCloudflareAuth = true
                    }
                    return
                }

                guard httpResponse.statusCode == 200 else {
                    struct RegisterError: Decodable {
                        let error: String
                        let code: String
                    }
                    if let errorResponse = try? JSONDecoder().decode(RegisterError.self, from: data) {
                        throw NSError(domain: "Reattach", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: errorResponse.error])
                    }
                    throw NSError(domain: "Reattach", code: httpResponse.statusCode, userInfo: [NSLocalizedDescriptionKey: "Registration failed: \(httpResponse.statusCode)"])
                }

                struct RegisterResponse: Decodable {
                    let device_id: String
                    let device_token: String
                }

                let registerResponse = try JSONDecoder().decode(RegisterResponse.self, from: data)
                let serverName = URL(string: serverURL)?.host ?? serverURL

                let serverConfig = ServerConfig(
                    serverURL: serverURL,
                    deviceToken: registerResponse.device_token,
                    deviceId: registerResponse.device_id,
                    deviceName: deviceName,
                    serverName: serverName,
                    registeredAt: Date()
                )

                await MainActor.run {
                    ServerConfigManager.shared.addServer(serverConfig)
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    isRegistering = false
                    errorMessage = error.localizedDescription
                    showError = true
                }
            }
        }
    }
}

struct CloudflareAuthView: View {
    let serverURL: String
    let onAuthenticated: () -> Void
    let onCancel: () -> Void
    @State private var isLoading = true

    var body: some View {
        NavigationStack {
            ZStack {
                CloudflareWebView(
                    url: URL(string: serverURL)!,
                    isLoading: $isLoading,
                    onAuthenticated: onAuthenticated
                )

                if isLoading {
                    ProgressView()
                }
            }
            .navigationTitle("Sign In")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") {
                        onCancel()
                    }
                }
            }
        }
    }
}

struct CloudflareWebView: UIViewRepresentable {
    let url: URL
    @Binding var isLoading: Bool
    let onAuthenticated: () -> Void

    func makeUIView(context: Context) -> WKWebView {
        let config = WKWebViewConfiguration()
        config.websiteDataStore = .default()

        let webView = WKWebView(frame: .zero, configuration: config)
        webView.navigationDelegate = context.coordinator
        webView.load(URLRequest(url: url))
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }

    class Coordinator: NSObject, WKNavigationDelegate {
        let parent: CloudflareWebView
        private var hasCheckedAuth = false

        init(_ parent: CloudflareWebView) {
            self.parent = parent
        }

        func webView(_ webView: WKWebView, didStartProvisionalNavigation navigation: WKNavigation!) {
            parent.isLoading = true
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            parent.isLoading = false

            if let currentURL = webView.url,
               currentURL.host == parent.url.host {
                webView.configuration.websiteDataStore.httpCookieStore.getAllCookies { cookies in
                    for cookie in cookies {
                        HTTPCookieStorage.shared.setCookie(cookie)
                    }

                    let hasCFAuth = cookies.contains { $0.name == "CF_Authorization" }
                    if hasCFAuth && !self.hasCheckedAuth {
                        self.hasCheckedAuth = true
                        DispatchQueue.main.async {
                            self.parent.onAuthenticated()
                        }
                    }
                }
            }
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            parent.isLoading = false
        }

        func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
            parent.isLoading = false
        }
    }
}

struct QRCodeScannerRepresentable: UIViewControllerRepresentable {
    @Binding var isScanning: Bool
    let onCodeScanned: (String) -> Void

    func makeUIViewController(context: Context) -> QRScannerViewController {
        let controller = QRScannerViewController()
        controller.delegate = context.coordinator
        return controller
    }

    func updateUIViewController(_ uiViewController: QRScannerViewController, context: Context) {
        if isScanning {
            uiViewController.startScanning()
        } else {
            uiViewController.stopScanning()
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(onCodeScanned: onCodeScanned)
    }

    class Coordinator: NSObject, QRScannerViewControllerDelegate {
        let onCodeScanned: (String) -> Void

        init(onCodeScanned: @escaping (String) -> Void) {
            self.onCodeScanned = onCodeScanned
        }

        func didScanCode(_ code: String) {
            onCodeScanned(code)
        }
    }
}

protocol QRScannerViewControllerDelegate: AnyObject {
    func didScanCode(_ code: String)
}

class QRScannerViewController: UIViewController, AVCaptureMetadataOutputObjectsDelegate {
    weak var delegate: QRScannerViewControllerDelegate?

    private var captureSession: AVCaptureSession?
    private var previewLayer: AVCaptureVideoPreviewLayer?

    override func viewDidLoad() {
        super.viewDidLoad()
        setupCamera()
    }

    override func viewDidLayoutSubviews() {
        super.viewDidLayoutSubviews()
        previewLayer?.frame = view.bounds
    }

    private func setupCamera() {
        let session = AVCaptureSession()

        guard let videoCaptureDevice = AVCaptureDevice.default(for: .video),
              let videoInput = try? AVCaptureDeviceInput(device: videoCaptureDevice),
              session.canAddInput(videoInput)
        else {
            return
        }

        session.addInput(videoInput)

        let metadataOutput = AVCaptureMetadataOutput()
        if session.canAddOutput(metadataOutput) {
            session.addOutput(metadataOutput)
            metadataOutput.setMetadataObjectsDelegate(self, queue: DispatchQueue.main)
            metadataOutput.metadataObjectTypes = [.qr]
        }

        let previewLayer = AVCaptureVideoPreviewLayer(session: session)
        previewLayer.frame = view.bounds
        previewLayer.videoGravity = .resizeAspectFill
        view.layer.addSublayer(previewLayer)

        self.captureSession = session
        self.previewLayer = previewLayer

        startScanning()
    }

    func startScanning() {
        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            self?.captureSession?.startRunning()
        }
    }

    func stopScanning() {
        captureSession?.stopRunning()
    }

    func metadataOutput(_ output: AVCaptureMetadataOutput, didOutput metadataObjects: [AVMetadataObject], from connection: AVCaptureConnection) {
        guard let metadataObject = metadataObjects.first as? AVMetadataMachineReadableCodeObject,
              let code = metadataObject.stringValue
        else {
            return
        }

        AudioServicesPlaySystemSound(SystemSoundID(kSystemSoundID_Vibrate))
        delegate?.didScanCode(code)
    }
}

#Preview {
    QRScannerView()
}
