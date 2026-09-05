/// 새 편집은 다시 실행을 지우고, 이미지와 주석을 같은 스냅샷으로 이동시킨다.
struct EditHistory<State> {
    private var undoStates: [State] = []
    private var redoStates: [State] = []
    let limit: Int
    init(limit: Int = 50) { self.limit = max(1, limit) }
    var canUndo: Bool { !undoStates.isEmpty }
    var canRedo: Bool { !redoStates.isEmpty }

    mutating func record(_ state: State) {
        undoStates.append(state)
        if undoStates.count > limit { undoStates.removeFirst() }
        redoStates.removeAll()
    }

    mutating func undo(current: State) -> State? {
        guard let previous = undoStates.popLast() else { return nil }
        redoStates.append(current)
        return previous
    }

    mutating func redo(current: State) -> State? {
        guard let next = redoStates.popLast() else { return nil }
        undoStates.append(current)
        return next
    }

    mutating func reset() {
        undoStates.removeAll()
        redoStates.removeAll()
    }
}
