import SwiftUI
import AppKit

struct AboutView: View {
    @EnvironmentObject var updates: UpdateChecker

    private var version: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
    }

    var body: some View {
        VStack(spacing: 14) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 112, height: 112)
                .accessibilityHidden(true)
            VStack(spacing: 3) {
                Text("Finder Rescue").font(.title2).bold()
                Text("Version \(version)").foregroundStyle(.secondary)
            }
            Text("Keeps Finder responsive. It watches Finder quietly from the menu bar, relaunches it when it gets stuck, and keeps the fixes for the usual causes one click away.")
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 320)

            VStack(spacing: 6) {
                Link("runtian.uk", destination: URL(string: "https://runtian.uk")!)
                Link("More apps at software.runtian.uk", destination: URL(string: "https://software.runtian.uk")!)
                Link("Source code on GitHub", destination: UpdateChecker.repoURL)
                Link("Report a problem", destination: UpdateChecker.repoURL.appendingPathComponent("issues"))
            }

            if let update = updates.availableUpdate {
                Link("Version \(update.version) is available — download", destination: update.url)
                    .fontWeight(.semibold)
            } else {
                Button(updates.isChecking ? "Checking…" : "Check for Updates") {
                    Task { await updates.checkNow(userInitiated: true) }
                }
                .disabled(updates.isChecking)
            }

            VStack(spacing: 2) {
                Text("Made by Runtian Wu · github.com/Micropeptide")
                Text("© 2026 · MIT License")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(28)
        .frame(width: 400)
    }
}
