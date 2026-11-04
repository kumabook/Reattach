//
//  UpgradeView.swift
//  Reattach
//

import SwiftUI

struct UpgradeView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var purchaseManager = PurchaseManager.shared

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(spacing: 32) {
                    headerSection
                    featuresSection
                    purchaseSection
                }
                .padding()
            }
            .navigationTitle(String(localized: "Upgrade to Pro"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(String(localized: "Close")) {
                        dismiss()
                    }
                }
            }
            .alert(String(localized: "Error"), isPresented: .constant(purchaseManager.errorMessage != nil)) {
                Button(String(localized: "OK")) {
                    purchaseManager.errorMessage = nil
                }
            } message: {
                Text(purchaseManager.errorMessage ?? "")
            }
        }
    }

    private var headerSection: some View {
        VStack(spacing: 16) {
            Image(systemName: "star.fill")
                .font(.system(size: 60))
                .foregroundStyle(.yellow)

            Text(String(localized: "Reattach Pro"))
                .font(.largeTitle)
                .fontWeight(.bold)

            Text(String(localized: "Unlock all features"))
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 20)
    }

    private var featuresSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            FeatureRow(
                icon: "server.rack",
                title: String(localized: "Unlimited Servers"),
                description: String(localized: "Connect to all your machines")
            )

            FeatureRow(
                icon: "bookmark.fill",
                title: String(localized: "Unlimited Bookmarks"),
                description: String(localized: "Save as many commands as you need")
            )

            FeatureRow(
                icon: "clock.arrow.circlepath",
                title: String(localized: "Extended History"),
                description: String(localized: "Keep up to 100 commands in history")
            )
        }
        .padding()
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 16))
    }

    private var purchaseSection: some View {
        VStack(spacing: 16) {
            Button {
                guard !purchaseManager.isLoading else { return }
                Task {
                    let success = await purchaseManager.purchase()
                    if success {
                        dismiss()
                    }
                }
            } label: {
                HStack {
                    if purchaseManager.isLoading {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Text(String(localized: "Purchase"))
                        if let price = purchaseManager.productPrice {
                            Text(verbatim: "(\(price))")
                        }
                    }
                }
                .frame(maxWidth: .infinity)
                .padding()
            }
            .buttonStyle(.borderedProminent)

            Button {
                Task {
                    await purchaseManager.restore()
                }
            } label: {
                Text(String(localized: "Restore Purchase"))
                    .font(.footnote)
            }
            .disabled(purchaseManager.isLoading)
        }
    }
}

struct FeatureRow: View {
    let icon: String
    let title: String
    let description: String

    var body: some View {
        HStack(spacing: 16) {
            Image(systemName: icon)
                .font(.title2)
                .foregroundStyle(.blue)
                .frame(width: 32)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }
}

#Preview {
    UpgradeView()
}
