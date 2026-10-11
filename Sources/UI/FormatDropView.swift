import AppKit
import SwiftUI

struct RadialItem: Identifiable {
    let id: String
    let title: String
    let caption: String
    let available: Bool
    let reason: String?
}

struct DonutWedge: Shape {
    let index: Int
    let count: Int
    let holeRatio: Double

    func path(in rect: CGRect) -> Path {
        let radius = min(rect.width, rect.height) / 2
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let span = 2 * Double.pi / Double(max(count, 1))
        let start = Double(index) * span - span / 2 - .pi / 2
        let end = start + span
        var path = Path()
        path.addArc(center: center, radius: radius, startAngle: .radians(start), endAngle: .radians(end), clockwise: false)
        path.addArc(center: center, radius: radius * holeRatio, startAngle: .radians(end), endAngle: .radians(start), clockwise: true)
        path.closeSubpath()
        return path
    }
}

struct DonutView: View {
    let items: [RadialItem]
    let title: String
    let subtitle: String
    var radius: Double = 150
    var holeRatio: Double = 0.42
    var opacity: Double = 0.96
    var accent: Color = .fileeAccent
    var activeIndex: Int?
    var onHover: (Int?) -> Void = { _ in }
    var onInvoke: (Int) -> Void = { _ in }
    var onEdit: (Int) -> Void = { _ in }
    var onCenter: () -> Void = {}

    var body: some View {
        ZStack {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                DonutSlice(item: item, index: index, count: items.count, radius: radius, holeRatio: holeRatio,
                           opacity: opacity, accent: accent, highlighted: activeIndex == index,
                           onHover: { onHover($0 ? index : nil) }, onInvoke: { onInvoke(index) }, onEdit: { onEdit(index) })
            }
            Button(action: onCenter) {
                VStack(spacing: 5) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    Text(subtitle).font(.system(size: 10)).foregroundStyle(.secondary).lineLimit(3)
                }
                .multilineTextAlignment(.center)
                .padding(8)
                .frame(width: radius * holeRatio * 2, height: radius * holeRatio * 2)
                .background(Color(nsColor: .controlBackgroundColor), in: Circle())
                .overlay { Circle().stroke(Color.primary.opacity(0.08), lineWidth: 1) }
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(title), \(subtitle)")
            .help(L("원형 툴바 닫기"))
        }
        .frame(width: radius * 2, height: radius * 2)
        .shadow(color: .black.opacity(0.16), radius: 8, y: 3)
    }
}

private struct DonutSlice: View {
    let item: RadialItem
    let index: Int
    let count: Int
    let radius: Double
    let holeRatio: Double
    let opacity: Double
    let accent: Color
    let highlighted: Bool
    let onHover: (Bool) -> Void
    let onInvoke: () -> Void
    let onEdit: () -> Void
    private var shape: DonutWedge { DonutWedge(index: index, count: count, holeRatio: holeRatio) }
    private var angle: Double { Double(index) * 2 * .pi / Double(count) }
    private var foreground: Color { highlighted ? ThemeAccent.foreground(on: accent) : item.available ? .primary : .secondary }
    var body: some View {
        Button { if item.available { onInvoke() } } label: {
            shape.fill(highlighted ? accent : Color(nsColor: .controlBackgroundColor).opacity(opacity))
                .overlay { shape.stroke(Color.primary.opacity(0.1), lineWidth: 1) }
                .overlay {
                    VStack(spacing: 3) {
                        Text(item.title).font(.system(size: 12, weight: .semibold)).lineLimit(2)
                        if !item.caption.isEmpty && item.caption.caseInsensitiveCompare(item.title) != .orderedSame {
                            Text(item.caption).font(.system(size: 10)).lineLimit(1)
                        }
                    }.frame(width: radius * 0.65).foregroundStyle(foreground)
                        .offset(x: sin(angle) * radius * (1 + holeRatio) / 2, y: -cos(angle) * radius * (1 + holeRatio) / 2)
                }
        }.buttonStyle(.plain).contentShape(shape).onHover(perform: onHover)
            .contextMenu { Button(L("프리셋 편집"), action: onEdit) }
            .help(item.reason ?? item.title).accessibilityLabel(item.title)
            .accessibilityValue(item.available ? item.caption : item.reason ?? L("변환할 수 없음"))
    }
}

struct FormatDropView: View {
    @Bindable var model: AppModel
    @State private var activeIndex: Int?

    private var items: [RadialItem] {
        (model.selection?.slices ?? []).map {
            RadialItem(id: $0.presetId, title: $0.displayName, caption: $0.targetFormat == "*" ? L("같은 형식") : $0.targetFormat.uppercased(), available: $0.available, reason: $0.reasonText)
        }
    }
    private var subtitle: String {
        if let index = activeIndex, items.indices.contains(index) {
            let item = items[index]
            return item.available ? L(model.radialClickMode ? "Convert to %@" : "Drop to %@", item.title) : item.reason ?? L("Unavailable")
        }
        return model.radialClickMode ? L("중앙을 누르면 닫기") : L("파일을 놓으세요")
    }

    var body: some View {
        ZStack {
            if model.radialVisible {
                if let job = model.radialJob {
                    radialProgress(job)
                } else if model.isResolving || model.isStarting {
                    ProgressView(L("형식 확인 중…"))
                        .padding(20)
                        .background(.regularMaterial, in: Circle())
                } else {
                    DonutView(items: items, title: L("파일 %@개", String(describing: (model.selectedFiles.count))), subtitle: subtitle,
                              radius: model.radialOuterRadius, holeRatio: model.radialHoleRatio, opacity: model.radialOpacity, accent: model.accentColor,
                              activeIndex: activeIndex, onHover: { activeIndex = $0 }, onInvoke: invoke,
                              onEdit: { model.editPreset(items[$0].id) },
                              onCenter: model.closeRadial)
                }
            }
            if !model.radialClickMode && model.radialJobID == nil {
                RadialDropTarget(model: model, activeIndex: $activeIndex)
            }
        }
        .padding(21)
        .frame(width: model.radialOuterRadius * 2 + 42, height: model.radialOuterRadius * 2 + 42)
        .preferredColorScheme(model.themeColorScheme)
        .environment(\.locale, Locale(identifier: model.language.rawValue))
        .onExitCommand { model.closeRadial() }
    }

    private func invoke(_ index: Int) {
        guard items.indices.contains(index), items[index].available else { return }
        Task { await model.start(presetID: items[index].id) }
    }

    private func radialProgress(_ job: HostJob) -> some View {
        let finished = AppModel.isFinished(job.state)
        return ZStack {
            Circle().stroke(Color.secondary.opacity(0.2), lineWidth: 6)
            Circle().trim(from: 0, to: min(max(job.progress, 0), 1))
                .stroke(job.state == "failed" ? Color.red : model.accentColor, style: StrokeStyle(lineWidth: 6, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Button {
                model.reveal(job.files.flatMap { $0.outputs.map(\.path) })
            } label: {
                VStack(spacing: 2) {
                    if finished {
                        Image(systemName: job.state == "completed" ? "checkmark" : job.state == "cancelled" ? "xmark" : "exclamationmark")
                            .font(.title2.weight(.bold))
                    } else {
                        Text("\(Int(job.progress * 100))%").font(.headline.monospacedDigit())
                    }
                    Text(model.cancellingJobIDs.contains(job.jobId) ? L("취소 중") : AppModel.stateTitle(job.state)).font(.system(size: 9))
                }
            }
            .buttonStyle(.plain)
            .help(L("완료된 결과를 Finder에서 보기"))
        }
        .frame(width: 76, height: 76)
        .padding(8)
        .background(.regularMaterial, in: Circle())
        .overlay(alignment: .topTrailing) {
            if !finished {
                Button { Task { await model.cancel(jobID: job.jobId) } } label: { Image(systemName: "xmark.circle.fill") }
                    .buttonStyle(.plain)
                    .disabled(model.cancellingJobIDs.contains(job.jobId))
                    .help(L("변환 취소"))
            }
        }
        .animation(model.reduceMotion ? nil : .easeOut(duration: 0.28), value: job.progress)
        .accessibilityElement(children: .contain)
    }
}

struct FileDropTarget: NSViewRepresentable {
    @Binding var isTargeted: Bool
    var isEnabled = true
    let onDrop: ([URL]) -> Void

    func makeNSView(context: Context) -> FileDropNSView {
        let view = FileDropNSView()
        view.registerForDraggedTypes([.fileURL])
        view.setAccessibilityElement(false)
        return view
    }
    func updateNSView(_ view: FileDropNSView, context: Context) {
        view.isEnabled = isEnabled
        view.onDrop = onDrop
        view.onTargetChanged = { isTargeted = $0 }
    }
}

final class FileDropNSView: NSView {
    var isEnabled = true
    var onDrop: (([URL]) -> Void)?
    var onTargetChanged: ((Bool) -> Void)?
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { updateTarget(sender) }
    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation { updateTarget(sender) }
    override func draggingExited(_ sender: (any NSDraggingInfo)?) { onTargetChanged?(false) }
    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool { !acceptedURLs(sender).isEmpty }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        let urls = acceptedURLs(sender)
        onTargetChanged?(false)
        guard !urls.isEmpty else { return false }
        onDrop?(urls)
        return true
    }
    override func concludeDragOperation(_ sender: (any NSDraggingInfo)?) { onTargetChanged?(false) }
    private func updateTarget(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let accepts = !acceptedURLs(sender).isEmpty
        onTargetChanged?(accepts)
        return accepts ? .copy : []
    }
    private func acceptedURLs(_ sender: any NSDraggingInfo) -> [URL] {
        guard isEnabled else { return [] }
        return Self.fileURLs(from: sender.draggingPasteboard, sourceOperationMask: sender.draggingSourceOperationMask)
    }
    static func fileURLs(from pasteboard: NSPasteboard, sourceOperationMask: NSDragOperation) -> [URL] {
        guard sourceOperationMask.contains(.copy) else { return [] }
        let objects = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) ?? []
        return objects.compactMap { $0 as? URL }.filter {
            $0.isFileURL && ($0.host == nil || $0.host == "" || $0.host == "localhost")
        }
    }
}

private struct RadialDropTarget: NSViewRepresentable {
    let model: AppModel
    @Binding var activeIndex: Int?
    func makeNSView(context: Context) -> RadialDropNSView {
        let view = RadialDropNSView()
        view.registerForDraggedTypes([.fileURL])
        return view
    }
    func updateNSView(_ view: RadialDropNSView, context: Context) {
        view.model = model
        view.onHover = { activeIndex = $0 }
    }
}

private final class RadialDropNSView: NSView {
    var model: AppModel?
    var onHover: ((Int?) -> Void)?
    private var lastURLs: [URL] = []
    override var isFlipped: Bool { true }
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func draggingEntered(_ sender: any NSDraggingInfo) -> NSDragOperation { update(sender) }
    override func draggingUpdated(_ sender: any NSDraggingInfo) -> NSDragOperation { update(sender) }
    override func draggingExited(_ sender: (any NSDraggingInfo)?) { onHover?(nil) }
    override func prepareForDragOperation(_ sender: any NSDraggingInfo) -> Bool { acceptedIndex(sender) != nil }
    override func performDragOperation(_ sender: any NSDraggingInfo) -> Bool {
        guard let model, let index = acceptedIndex(sender), let slice = model.selection?.slices[index] else { return false }
        Task { await model.start(presetID: slice.presetId) }
        onHover?(nil)
        return true
    }
    private func update(_ sender: any NSDraggingInfo) -> NSDragOperation {
        let urls = FileDropNSView.fileURLs(from: sender.draggingPasteboard, sourceOperationMask: sender.draggingSourceOperationMask)
        if !urls.isEmpty && (urls != lastURLs || model?.selectedFiles != urls) {
            lastURLs = urls
            Task { await model?.resolve(urls, clickMode: false, showRadial: false) }
        }
        onHover?(hoveredIndex(sender))
        return acceptedIndex(sender) == nil ? [] : .copy
    }
    private func acceptedIndex(_ sender: any NSDraggingInfo) -> Int? {
        guard let index = hoveredIndex(sender), model?.selection?.slices[index].available == true else { return nil }
        return index
    }
    private func hoveredIndex(_ sender: any NSDraggingInfo) -> Int? {
        guard let model, !model.isResolving, !model.isStarting, let selection = model.selection else { return nil }
        let urls = FileDropNSView.fileURLs(from: sender.draggingPasteboard, sourceOperationMask: sender.draggingSourceOperationMask)
        guard !urls.isEmpty, urls == model.selectedFiles else { return nil }
        let point = convert(sender.draggingLocation, from: nil)
        guard let index = DonutGeometry.segment(at: point, center: CGPoint(x: bounds.midX, y: bounds.midY),
            innerRadius: model.radialOuterRadius * model.radialHoleRatio, outerRadius: model.radialOuterRadius, count: selection.slices.count) else { return nil }
        return index
    }
}

extension Color {
    static let fileeAccent = ThemeAccent.color(hex: nil)
    static let fileePage = Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(red: 0.106, green: 0.106, blue: 0.098, alpha: 1) : NSColor(red: 0.965, green: 0.961, blue: 0.945, alpha: 1) })
}
