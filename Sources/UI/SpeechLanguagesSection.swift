import Speech
import SwiftUI

/// The system's speech recognition languages for video and audio → TXT: the installed ones, and a menu to download
/// another. The engine never downloads one during a conversion (SpeechText).
@available(macOS 26.0, *)
struct SpeechLanguagesSection: View {
    @State private var installed: [Locale] = []
    @State private var available: [Locale] = []
    /// The languages this app asked macOS to keep; the others are kept by macOS or another app.
    @State private var reserved: Set<String> = []
    @State private var downloading: Locale?
    @State private var progress: Progress?
    @State private var error: String?

    var body: some View {
        Section {
            if installed.isEmpty {
                Label(L("speech.languages.none"), systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            ForEach(installed, id: \.identifier) { locale in
                LabeledContent {
                    if reserved.contains(locale.identifier) {
                        Button(L("speech.languages.release")) { Task { await release(locale) } }.disabled(downloading != nil)
                    } else {
                        Text(L("speech.languages.system")).font(.callout).foregroundStyle(.secondary)
                    }
                } label: {
                    Label(name(locale), systemImage: "checkmark.circle.fill")
                }
            }
            if let downloading {
                VStack(alignment: .leading, spacing: 6) {
                    Text(L("speech.languages.downloading", name(downloading))).font(.callout).foregroundStyle(.secondary)
                    if let progress { ProgressView(progress).labelsHidden() } else { ProgressView().controlSize(.small) }
                }
            } else if !available.isEmpty {
                Menu(L("speech.languages.add")) {
                    ForEach(available, id: \.identifier) { locale in
                        Button(name(locale)) { Task { await download(locale) } }
                    }
                }
            }
            if let error { Text(error).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
        } header: {
            Text(L("speech.languages.title"))
        } footer: {
            Text(L("speech.languages.help")).font(.callout).foregroundStyle(.secondary)
        }
        .task { await reload() }
    }

    private func name(_ locale: Locale) -> String {
        Locale.current.localizedString(forIdentifier: locale.identifier) ?? locale.identifier
    }

    private func reload() async {
        let ready = await SpeechTranscriber.installedLocales
        let ids = Set(ready.map(\.identifier))
        installed = ready.sorted { name($0) < name($1) }
        reserved = Set(await AssetInventory.reservedLocales.map(\.identifier))
        available = await SpeechTranscriber.supportedLocales.filter { !ids.contains($0.identifier) }.sorted { name($0) < name($1) }
    }

    /// Stops keeping the language for this app. macOS removes the model when nothing else uses it and it needs the space.
    private func release(_ locale: Locale) async {
        error = nil
        _ = await AssetInventory.release(reservedLocale: locale)
        await reload()
    }

    private func download(_ locale: Locale) async {
        (downloading, progress, error) = (locale, nil, nil)
        defer { (downloading, progress) = (nil, nil) }
        do {
            // The same options as SpeechText, so the model it needs is the one installed.
            let transcriber = SpeechTranscriber(locale: locale, transcriptionOptions: [], reportingOptions: [], attributeOptions: [.transcriptionConfidence])
            if let request = try await AssetInventory.assetInstallationRequest(supporting: [transcriber]) {
                progress = request.progress
                try await request.downloadAndInstall()
            }
        } catch {
            self.error = L("speech.languages.failed", name(locale), error.localizedDescription)
        }
        await reload()
    }
}
