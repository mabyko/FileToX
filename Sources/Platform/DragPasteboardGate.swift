// Each native drag must publish its own file payload before the panel can intercept it.
struct DragPasteboardGate {
    private(set) var generation = 0
    private var initialChangeCount: Int?

    mutating func begin(changeCount: Int) {
        generation += 1
        initialChangeCount = changeCount
    }

    mutating func end() {
        generation += 1
        initialChangeCount = nil
    }

    func accepts(changeCount: Int, hasFileURLs: Bool, leftButtonPressed: Bool, shortcutPressed: Bool, generation: Int) -> Bool {
        generation == self.generation && initialChangeCount != nil &&
            changeCount != initialChangeCount && hasFileURLs && leftButtonPressed && shortcutPressed
    }
}
