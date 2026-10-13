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
    /// Visual gap between wedges in points; hit testing still uses DonutGeometry's full segments.
    var gap: Double = 0

    func path(in rect: CGRect) -> Path {
        let radius = min(rect.width, rect.height) / 2
        let inner = radius * holeRatio
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let span = 2 * Double.pi / Double(max(count, 1))
        let start = Double(index) * span - span / 2 - .pi / 2
        let end = start + span
        // Inset each arc by the same linear distance so wedge edges stay parallel.
        let outerInset = count > 1 ? asin(min(gap / 2 / radius, 1)) : 0
        let innerInset = count > 1 ? asin(min(gap / 2 / max(inner, 1), 1)) : 0
        var path = Path()
        path.addArc(center: center, radius: radius, startAngle: .radians(start + outerInset), endAngle: .radians(end - outerInset), clockwise: false)
        path.addArc(center: center, radius: inner, startAngle: .radians(end - innerInset), endAngle: .radians(start + innerInset), clockwise: true)
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
    var animated = true
    var onHover: (Int?) -> Void = { _ in }
    var onInvoke: (Int) -> Void = { _ in }
    var onEdit: (Int) -> Void = { _ in }
    var onCenter: () -> Void = {}

    var body: some View {
        ZStack {
            ForEach(Array(items.enumerated()), id: \.element.id) { index, item in
                DonutSlice(item: item, index: index, count: items.count, radius: radius, holeRatio: holeRatio,
                           opacity: opacity, accent: accent, highlighted: activeIndex == index, animated: animated,
                           onInvoke: { onInvoke(index) }, onEdit: { onEdit(index) })
            }
            Button(action: onCenter) {
                VStack(spacing: 4) {
                    Text(title).font(.system(size: 13, weight: .semibold))
                    ZStack {
                        Text(subtitle).id(subtitle).transition(.blurSwap)
                    }.font(.system(size: 11)).foregroundStyle(.secondary).lineLimit(3)
                }
                .multilineTextAlignment(.center)
                .padding(10)
                .frame(width: radius * holeRatio * 2 - 6, height: radius * holeRatio * 2 - 6)
                .background(.regularMaterial, in: Circle())
                .overlay { Circle().strokeBorder(Color.primary.opacity(0.1), lineWidth: 1) }
                .animation(Motion.when(animated, Motion.quick), value: subtitle)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(title), \(subtitle)")
            .help(L("원형 툴바 닫기"))
        }
        .frame(width: radius * 2, height: radius * 2)
        .onContinuousHover { phase in
            switch phase {
            case .active(let point):
                onHover(DonutGeometry.segment(at: point, center: CGPoint(x: radius, y: radius),
                                              innerRadius: radius * holeRatio, outerRadius: radius, count: items.count))
            case .ended: onHover(nil)
            }
        }
        .shadow(color: .black.opacity(0.22), radius: 12, y: 4)
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
    let animated: Bool
    let onInvoke: () -> Void
    let onEdit: () -> Void
    private var shape: DonutWedge { DonutWedge(index: index, count: count, holeRatio: holeRatio, gap: 3) }
    private var angle: Double { Double(index) * 2 * .pi / Double(count) }
    private var foreground: Color { highlighted ? ThemeAccent.foreground(on: accent) : item.available ? .primary : .secondary }
    var body: some View {
        Button { if item.available { onInvoke() } } label: {
            shape.fill(highlighted ? accent : Color(nsColor: .controlBackgroundColor).opacity(opacity))
                .overlay { shape.stroke(highlighted ? Color.white.opacity(0.18) : Color.primary.opacity(0.1), lineWidth: 1) }
                .overlay {
                    VStack(spacing: 3) {
                        Text(item.title).font(.system(size: 12, weight: .semibold)).lineLimit(2)
                        if !item.caption.isEmpty && item.caption.caseInsensitiveCompare(item.title) != .orderedSame {
                            Text(item.caption).font(.system(size: 10)).lineLimit(1)
                        }
                    }.frame(width: radius * 0.65).foregroundStyle(foreground)
                        .offset(x: sin(angle) * radius * (1 + holeRatio) / 2, y: -cos(angle) * radius * (1 + holeRatio) / 2)
                }
                .opacity(item.available ? 1 : 0.55)
                // The highlighted wedge springs outward a few points (transitions.dev badge pop).
                .scaleEffect(highlighted ? 1.035 : 1)
                .animation(Motion.when(animated, highlighted ? Motion.pop : Motion.quick), value: highlighted)
        }.buttonStyle(.plain).contentShape(shape)
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
                    radialProgress(job).transition(.blurSwap)
                } else if model.isResolving || model.isStarting {
                    ProgressView(L("형식 확인 중…"))
                        .padding(20)
                        .background(.regularMaterial, in: Circle())
                        .transition(.opacity)
                } else {
                    DonutView(items: items, title: model.selectedFiles.count == 1 ? L("파일 1개") : L("파일 %@개", String(model.selectedFiles.count)), subtitle: subtitle,
                              radius: model.radialOuterRadius, holeRatio: model.radialHoleRatio, opacity: model.radialOpacity, accent: model.accentColor,
                              activeIndex: activeIndex, animated: !model.reduceMotion, onHover: { activeIndex = $0 }, onInvoke: invoke,
                              onEdit: { model.editPreset(items[$0].id) },
                              onCenter: model.closeRadial)
                    .transition(.scale(scale: 0.96).combined(with: .opacity))
                }
            }
            if !model.radialClickMode && model.radialJobID == nil {
                RadialDropTarget(model: model, activeIndex: $activeIndex)
            }
        }
        .padding(21)
        .frame(width: model.radialOuterRadius * 2 + 42, height: model.radialOuterRadius * 2 + 42)
        .animation(Motion.when(!model.reduceMotion, Motion.open), value: model.radialVisible)
        .animation(Motion.when(!model.reduceMotion, Motion.open), value: model.radialJobID)
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
                            .foregroundStyle(job.state == "completed" ? model.accentColor : job.state == "failed" ? Color.red : Color.secondary)
                            .transition(.scale(scale: 0.6).combined(with: .opacity))
                    } else {
                        Text("\(Int(job.progress * 100))%").font(.headline.monospacedDigit())
                            .contentTransition(.numericText(value: job.progress))
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
        .animation(Motion.when(!model.reduceMotion, .easeOut(duration: 0.28)), value: job.progress)
        .animation(Motion.when(!model.reduceMotion, Motion.pop), value: finished)
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
    static let fileePage = Color(nsColor: .windowBackgroundColor)
    static let fileeSurface = Color(nsColor: NSColor(name: nil) { $0.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? NSColor(white: 1, alpha: 0.045) : NSColor(white: 1, alpha: 0.75) })
}
