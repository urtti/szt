/// A directory in the scanned tree.
///
/// A node is created by the thread that lists its parent and then filled in by
/// the thread that lists the directory itself. Nothing reads it until every
/// scanner thread has been joined, so no locking is needed.
final class DirNode {
    enum Skip: UInt8 {
        case none
        /// Another volume is mounted here and we were told not to cross mounts.
        case mountPoint
        /// Reached a second time (firmlink, directory hard link): counted elsewhere.
        case alreadyCounted
    }

    let name: String
    unowned(unsafe) let parent: DirNode?
    let depth: Int32

    var subdirs: [DirNode] = []
    /// The largest files directly inside this directory. Only files that could
    /// possibly make it into the report are remembered; the rest are just counted.
    var files: [FileNode] = []
    /// Number and total size of the non-directory entries directly inside.
    var fileCount: Int32 = 0
    var fileBytes: UInt64 = 0

    /// errno from opening or listing the directory, 0 if it was read fine.
    var error: Int32 = 0
    var skip = Skip.none

    /// Totals for the whole subtree, filled in by `aggregate()`.
    var size: UInt64 = 0
    var totalFiles = 0
    var totalDirs = 0

    init(name: String, parent: DirNode?, depth: Int32) {
        self.name = name
        self.parent = parent
        self.depth = depth
    }

    /// Sums sizes and counts bottom-up so every directory knows how much lives
    /// under it. Iterative, because trees can be far deeper than the stack.
    static func aggregate(_ root: DirNode) {
        var order = [root]
        var index = 0
        while index < order.count {
            order.append(contentsOf: order[index].subdirs)
            index += 1
        }
        // Breadth-first order lists every parent before its children, so walking
        // it backwards finishes each subtree before its parent is visited.
        for node in order.reversed() {
            node.size &+= node.fileBytes
            node.totalFiles += Int(node.fileCount)
            node.totalDirs += node.subdirs.count
            if let parent = node.parent {
                parent.size &+= node.size
                parent.totalFiles += node.totalFiles
                parent.totalDirs += node.totalDirs
            }
        }
    }

    /// Path from the scan root, starting with the root's display name.
    var path: String {
        var names: [String] = []
        var node: DirNode? = self
        while let current = node {
            names.append(current.name)
            node = current.parent
        }
        var result = ""
        for name in names.reversed() {
            if !result.isEmpty && !result.hasSuffix("/") { result += "/" }
            result += name
        }
        return result
    }
}

/// A file large enough that it may be shown on its own line.
final class FileNode {
    let name: String
    let size: UInt64
    unowned(unsafe) let parent: DirNode

    init(name: String, size: UInt64, parent: DirNode) {
        self.name = name
        self.size = size
        self.parent = parent
    }
}

/// A binary heap. `top` is an element that `precedes` every other one.
struct Heap<Element> {
    private(set) var elements: [Element] = []
    private let precedes: (Element, Element) -> Bool

    init(by precedes: @escaping (Element, Element) -> Bool) {
        self.precedes = precedes
    }

    var count: Int { elements.count }
    var top: Element? { elements.first }

    mutating func push(_ element: Element) {
        elements.append(element)
        var child = elements.count - 1
        while child > 0 {
            let parent = (child - 1) / 2
            guard precedes(elements[child], elements[parent]) else { break }
            elements.swapAt(child, parent)
            child = parent
        }
    }

    mutating func pop() -> Element? {
        guard !elements.isEmpty else { return nil }
        elements.swapAt(0, elements.count - 1)
        let top = elements.removeLast()
        siftDown()
        return top
    }

    mutating func replaceTop(with element: Element) {
        elements[0] = element
        siftDown()
    }

    private mutating func siftDown() {
        var parent = 0
        let count = elements.count
        while true {
            let left = 2 * parent + 1
            let right = left + 1
            var best = parent
            if left < count && precedes(elements[left], elements[best]) { best = left }
            if right < count && precedes(elements[right], elements[best]) { best = right }
            if best == parent { return }
            elements.swapAt(parent, best)
            parent = best
        }
    }
}
