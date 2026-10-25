import FileToXCore
import AppKit
import SwiftUI

struct WatchRulesEditor: View {
    let model: AppModel
    @Binding var settings: JSONValue
    @State private var statuses: [JSONValue] = []
    @State private var statusError: String?
    private var rules: [JSONValue] { settings["watchFolders"]?.array ?? [] }

    var body: some View {
        Section {
            Text(L("watch.help")).foregroundStyle(.secondary)
            Button(L("watch.add")) {
                var items = rules
                items.append(.object(["id": .string(String(UUID().uuidString.prefix(8))), "enabled": .bool(false),
                                      "folder": .string(""), "presetId": .string(model.library?.presets.first?.identity ?? ""),
                                      "includeSubfolders": .bool(false), "outputFolder": .string(""), "originals": .string("keep"),
                                      "include": .array([]), "fileNamePattern": .string(""), "renames": .array([])]))
                settings["watchFolders"] = .array(items)
            }
            if let statusError { Text(statusError).foregroundStyle(.red).textSelection(.enabled) }
        }
        .task {
            while !Task.isCancelled {
                if model.isConnected {
                    do { statuses = try await model.host.watchStatus(); statusError = nil }
                    catch { statusError = error.localizedDescription }
                } else { statuses = [] }
                do { try await Task.sleep(for: .seconds(2)) } catch { return }
            }
        }
        ForEach(rules, id: \.identity) { rule in
            WatchRuleEditor(model: model, rule: Binding(get: {
                rules.first { $0.identity == rule.identity } ?? rule
            }, set: { changed in
                settings["watchFolders"] = .array(rules.map { $0.identity == changed.identity ? changed : $0 })
            }), status: statuses.first { $0.identity == rule.identity }) {
                settings["watchFolders"] = .array(rules.filter { $0.identity != rule.identity })
            }
        }
    }
}

private struct WatchRuleEditor: View {
    let model: AppModel
    @Binding var rule: JSONValue
    let status: JSONValue?
    let remove: () -> Void

    var body: some View {
        Section {
            Toggle(L("watch.enabled"), isOn: Binding(get: { rule["enabled"]?.bool ?? false }, set: { rule["enabled"] = .bool($0) }))
            folder("watch.folder", key: "folder")
            Picker(L("프리셋"), selection: text("presetId")) {
                if !(model.library?.presets ?? []).contains(where: { $0.identity == rule["presetId"]?.string }) {
                    Text(L("watch.choosePreset")).tag(rule["presetId"]?.string ?? "")
                }
                ForEach(model.library?.presets ?? [], id: \.identity) { Text($0.libraryName).tag($0.identity) }
            }
            Toggle(L("watch.subfolders"), isOn: Binding(get: { rule["includeSubfolders"]?.bool ?? false }, set: { rule["includeSubfolders"] = .bool($0) }))
            folder("watch.output", key: "outputFolder")
            TextField(L("watch.include"), text: Binding(get: {
                rule["include"]?.array?.compactMap(\.string).joined(separator: "\n") ?? ""
            }, set: { rule["include"] = .array($0.split(separator: "\n").map { .string(String($0)) }) }), axis: .vertical)
            TextField(L("파일명 패턴"), text: text("fileNamePattern"))
            Picker(L("watch.originals"), selection: text("originals")) {
                Text(L("watch.keep")).tag("keep")
                Text(L("watch.move")).tag("moveToOriginals")
            }
            if let status {
                LabeledContent(L("watch.savedStatus"), value: L("watch.state.\(status["state"]?.string ?? "disabled")"))
                if let detail = status["detail"]?.string { Text(detail).font(.callout).foregroundStyle(.red).textSelection(.enabled) }
            }
            Button(L("삭제"), role: .destructive, action: remove)
        } footer: {
            Text(L("watch.ruleHelp")).font(.callout).foregroundStyle(.secondary)
        }
    }
    private func text(_ key: String) -> Binding<String> { Binding(get: { rule[key]?.string ?? "" }, set: { rule[key] = .string($0) }) }
    private func folder(_ title: String, key: String) -> some View {
        LabeledContent(L(title)) {
            HStack {
                TextField(L(title), text: text(key)).labelsHidden()
                Button(L("찾기…")) {
                    let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
                    if panel.runModal() == .OK, let url = panel.url { rule[key] = .string(url.path) }
                }
            }
        }
    }
}
