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
            .navigationTitle("Upgrade to Pro")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") {
                        dismiss()
                    }
                }
            }
            .alert("Error", isPresented: .constant(purchaseManager.errorMessage != nil)) {
                Button("OK") {
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

            Text("Reattach Pro")
                .font(.largeTitle)
                .fontWeight(.bold)

            Text("Unlock all features")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
        .padding(.top, 20)
    }

    private var featuresSection: some View {
        VStack(alignment: .leading, spacing: 16) {
            FeatureRow(
                icon: "server.rack",
                title: "Unlimited Servers",
                description: "Connect to all your machines"
            )

            FeatureRow(
                icon: "bookmark.fill",
                title: "Unlimited Bookmarks",
                description: "Save as many commands as you need"
            )

            FeatureRow(
                icon: "clock.arrow.circlepath",
                title: "Extended History",
                description: "Keep up to 100 commands in history"
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
                        Text("Purchase")
                        if let price = purchaseManager.productPrice {
                            Text("(\(price))")
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
                Text("Restore Purchase")
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
