import Darwin
import Dispatch
import Synchronization

struct ScanOptions {
    /// Measure logical file length instead of allocated disk space.
    var apparentSize = false
    /// Descend into other volumes mounted inside the tree.
    var crossMounts = false
    /// Number of scanner threads.
    var threads = 8
    /// How many of the largest files to remember by name (the rest are only counted).
    var keepFiles = 64
    /// Files deeper than this are never shown, so don't bother remembering them.
    var keepFilesDepth = Int32.max
}

struct ScanResult {
    let root: DirNode
    var files = 0
    var allocatedBytes: UInt64 = 0
    var apparentBytes: UInt64 = 0
    var unreadable: [DirNode] = []
    var mountPoints: [DirNode] = []
    /// Cloud placeholders (iCloud Drive, Dropbox, ...) whose listing isn't stored locally.
    var dataless = 0
    var seconds = 0.0
}

struct ScanProgress {
    var files = 0
    var bytes: UInt64 = 0
    var seconds = 0.0
}

/// Walks a directory tree with a pool of threads.
///
/// Each thread lists directories with `getattrlistbulk(2)`, which returns names,
/// types and sizes for a whole batch of entries in one system call, instead of
/// one `stat` per file. Threads work depth-first on their own stack of pending
/// directories and hand half of it to the shared pool whenever another thread
/// runs dry, so they rarely touch shared state.
final class Scanner: @unchecked Sendable {
    let options: ScanOptions
    fileprivate let pool: WorkPool
    /// (device, inode) of every directory listed, so firmlinks and directory
    /// hard links are only counted once; nil when nothing can be seen twice.
    fileprivate let directories: InodeSet?
    /// (device, inode) of files with several hard links, counted only once.
    fileprivate let hardLinks = InodeSet()
    /// The device of the scanned volume, used when directories aren't checked.
    fileprivate let device: Int32
    private var workers: [Worker] = []

    private init(path: String, options: ScanOptions) {
        self.options = options
        pool = WorkPool(workers: max(1, options.threads))
        var info = stat()
        device = stat(path, &info) == 0 ? info.st_dev : 0
        // A directory can only turn up twice by crossing into another mount (the
        // Data volume behind the /Users firmlink, say) or through a directory
        // hard link, which APFS doesn't have. Skip the bookkeeping otherwise.
        var volume = statfs()
        let apfs = statfs(path, &volume) == 0
            && withUnsafeBytes(of: volume.f_fstypename) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) } == "apfs"
        directories = options.crossMounts || !apfs ? InodeSet() : nil
    }

    /// Scans the directory at `path` (absolute, symlinks resolved). `progress`
    /// is called on the calling thread about ten times a second until done.
    static func scan(path: String, name: String, options: ScanOptions,
                     progress: (ScanProgress) -> Void) -> ScanResult {
        Scanner(path: path, options: options).run(path: path, name: name, progress: progress)
    }

    private func run(path: String, name: String, progress: (ScanProgress) -> Void) -> ScanResult {
        let start = clock_gettime_nsec_np(CLOCK_UPTIME_RAW)
        let root = DirNode(name: name, parent: nil, depth: 0)
        pool.give(CollectionOfOne(DirTask(node: root, path: path)))
        workers = (0..<pool.workerCount).map { _ in Worker(scanner: self) }

        var attributes = pthread_attr_t()
        pthread_attr_init(&attributes)
        pthread_attr_set_qos_class_np(&attributes, QOS_CLASS_USER_INITIATED, 0)
        var threads: [pthread_t] = []
        for worker in workers {
            var thread: pthread_t?
            let context = Unmanaged.passRetained(worker).toOpaque()
            let status = pthread_create(&thread, &attributes, { context in
                Unmanaged<Worker>.fromOpaque(context).takeRetainedValue().run()
                return nil
            }, context)
            guard status == 0, let thread else { fatalError("could not start a scanner thread (\(status))") }
            threads.append(thread)
        }
        pthread_attr_destroy(&attributes)

        func seconds() -> Double { Double(clock_gettime_nsec_np(CLOCK_UPTIME_RAW) - start) / 1e9 }
        while pool.finished.wait(timeout: .now() + .milliseconds(100)) == .timedOut {
            var snapshot = ScanProgress(seconds: seconds())
            for worker in workers {
                snapshot.files += worker.liveFiles.load(ordering: .relaxed)
                snapshot.bytes &+= worker.liveBytes.load(ordering: .relaxed)
            }
            progress(snapshot)
        }
        for thread in threads { pthread_join(thread, nil) }

        var result = ScanResult(root: root)
        var largest: [FileNode] = []
        for worker in workers {
            result.files += worker.files
            result.allocatedBytes &+= worker.allocatedBytes
            result.apparentBytes &+= worker.apparentBytes
            result.unreadable += worker.unreadable
            result.mountPoints += worker.mountPoints
            result.dataless += worker.dataless
            largest += worker.largest.files
        }
        // Each thread kept its own top files; keep the overall top ones.
        if largest.count > options.keepFiles {
            largest.sort { $0.size > $1.size }
            largest.removeLast(largest.count - options.keepFiles)
        }
        for file in largest { file.parent.files.append(file) }
        DirNode.aggregate(root)
        result.seconds = seconds()
        return result
    }
}

private struct DirTask {
    let node: DirNode
    let path: String
}

/// Bits from <sys/attr.h>.
private enum Attr {
    static let name: attrgroup_t = 0x0000_0001          // ATTR_CMN_NAME
    static let objectType: attrgroup_t = 0x0000_0008    // ATTR_CMN_OBJTYPE
    static let fileID: attrgroup_t = 0x0200_0000        // ATTR_CMN_FILEID
    static let error: attrgroup_t = 0x2000_0000         // ATTR_CMN_ERROR
    static let returned: attrgroup_t = 0x8000_0000      // ATTR_CMN_RETURNED_ATTRS
    static let mountStatus: attrgroup_t = 0x0000_0004   // ATTR_DIR_MOUNTSTATUS
    static let linkCount: attrgroup_t = 0x0000_0001     // ATTR_FILE_LINKCOUNT
    static let totalSize: attrgroup_t = 0x0000_0002     // ATTR_FILE_TOTALSIZE
    static let allocSize: attrgroup_t = 0x0000_0004     // ATTR_FILE_ALLOCSIZE
    static let isMountPoint: UInt32 = 0x1               // DIR_MNTSTATUS_MNTPOINT
    static let isTrigger: UInt32 = 0x2                  // DIR_MNTSTATUS_TRIGGER

    static let request: attrlist = {
        var list = attrlist()
        list.bitmapcount = u_short(ATTR_BIT_MAP_COUNT)
        list.commonattr = returned | name | error | objectType | fileID
        list.dirattr = mountStatus
        list.fileattr = linkCount | totalSize | allocSize
        return list
    }()
}

private final class Worker {
    static let bufferSize = 64 * 1024

    private unowned let scanner: Scanner
    private let pool: WorkPool
    private let buffer = UnsafeMutableRawPointer.allocate(byteCount: Worker.bufferSize, alignment: 16)
    /// Directories waiting to be listed; the newest (deepest) is taken first.
    private var stack: [DirTask] = []

    // Results, read once the thread has finished.
    var largest: LargestFiles
    var files = 0
    var allocatedBytes: UInt64 = 0
    var apparentBytes: UInt64 = 0
    var unreadable: [DirNode] = []
    var mountPoints: [DirNode] = []
    var dataless = 0

    // Running totals for the progress display.
    let liveFiles = Atomic<Int>(0)
    let liveBytes = Atomic<UInt64>(0)

    init(scanner: Scanner) {
        self.scanner = scanner
        pool = scanner.pool
        largest = LargestFiles(capacity: scanner.options.keepFiles)
    }

    deinit { buffer.deallocate() }

    func run() {
        while let task = stack.popLast() ?? pool.take() {
            list(task)
            // Share the shallowest half of our backlog (the biggest subtrees,
            // most likely) when somebody is out of work.
            if stack.count > 1 && pool.idleWorkers.load(ordering: .relaxed) > 0 {
                let share = stack.count / 2
                pool.give(stack[..<share])
                stack.removeFirst(share)
            }
        }
    }

    private func list(_ task: DirTask) {
        let dir = task.node
        let fd = Self.openDirectory(task.path)
        guard fd >= 0 else { return failed(dir, errno) }
        defer { close(fd) }

        var device = scanner.device
        if let directories = scanner.directories {
            var info = stat()
            guard fstat(fd, &info) == 0 else { return failed(dir, errno) }
            guard directories.insert(device: info.st_dev, inode: info.st_ino) else {
                dir.skip = .alreadyCounted
                return
            }
            device = info.st_dev
        }

        let options = scanner.options
        let childDepth = dir.depth + 1
        let keepNames = childDepth <= options.keepFilesDepth
        let base = task.path.utf8.last == UInt8(ascii: "/") ? task.path : task.path + "/"
        var fileCount: Int32 = 0
        var fileBytes: UInt64 = 0
        var allocated: UInt64 = 0
        var apparent: UInt64 = 0
        var request = Attr.request

        while true {
            let count = getattrlistbulk(fd, &request, buffer, Self.bufferSize, 0)
            if count == 0 { break }
            if count < 0 {
                if errno == EINTR { continue }
                failed(dir, errno)
                break
            }
            // Each entry: length, returned-attribute bitmap, then the attributes
            // that were returned, in bit order: common, directory, file.
            var entry = UnsafeRawPointer(buffer)
            for _ in 0..<count {
                let length = Int(entry.loadUnaligned(as: UInt32.self))
                defer { entry += length }
                let returned = entry.loadUnaligned(fromByteOffset: 4, as: attribute_set_t.self)
                var field = entry + 4 + MemoryLayout<attribute_set_t>.size

                if returned.commonattr & Attr.error != 0 {
                    if field.loadUnaligned(as: UInt32.self) != 0 { continue }
                    field += 4
                }
                guard returned.commonattr & Attr.name != 0 else { continue }
                let nameStart = field + Int(field.loadUnaligned(as: Int32.self))
                let nameLength = Int(field.loadUnaligned(fromByteOffset: 4, as: UInt32.self)) - 1
                field += 8
                var type: UInt32 = 0
                if returned.commonattr & Attr.objectType != 0 {
                    type = field.loadUnaligned(as: UInt32.self)
                    field += 4
                }
                var fileID: UInt64 = 0
                if returned.commonattr & Attr.fileID != 0 {
                    fileID = field.loadUnaligned(as: UInt64.self)
                    field += 8
                }

                if type == VDIR.rawValue {
                    var mount: UInt32 = 0
                    if returned.dirattr & Attr.mountStatus != 0 {
                        mount = field.loadUnaligned(as: UInt32.self)
                    }
                    let name = Self.string(nameStart, nameLength)
                    let child = DirNode(name: name, parent: dir, depth: childDepth)
                    dir.subdirs.append(child)
                    // Never wake an automounter; other volumes only when asked.
                    if mount & Attr.isTrigger != 0 || (mount & Attr.isMountPoint != 0 && !options.crossMounts) {
                        child.skip = .mountPoint
                        mountPoints.append(child)
                    } else {
                        stack.append(DirTask(node: child, path: base + name))
                    }
                    continue
                }

                var links: UInt32 = 1
                var logical: UInt64 = 0
                var onDisk: UInt64 = 0
                if returned.fileattr & Attr.linkCount != 0 {
                    links = field.loadUnaligned(as: UInt32.self)
                    field += 4
                }
                if returned.fileattr & Attr.totalSize != 0 {
                    logical = UInt64(clamping: field.loadUnaligned(as: Int64.self))
                    field += 8
                }
                if returned.fileattr & Attr.allocSize != 0 {
                    onDisk = UInt64(clamping: field.loadUnaligned(as: Int64.self))
                }
                if links > 1 && !scanner.hardLinks.insert(device: device, inode: fileID) {
                    continue  // another link to a file we've already counted
                }
                let size = options.apparentSize ? logical : onDisk
                fileCount += 1
                fileBytes &+= size
                allocated &+= onDisk
                apparent &+= logical
                if keepNames && size > largest.threshold {
                    largest.insert(FileNode(name: Self.string(nameStart, nameLength), size: size, parent: dir))
                }
            }
        }

        dir.fileCount = fileCount
        dir.fileBytes = fileBytes
        files += Int(fileCount)
        allocatedBytes &+= allocated
        apparentBytes &+= apparent
        liveFiles.wrappingAdd(Int(fileCount), ordering: .relaxed)
        liveBytes.wrappingAdd(fileBytes, ordering: .relaxed)
    }

    private func failed(_ dir: DirNode, _ code: Int32) {
        dir.error = code
        switch code {
        case ENOENT, ENOTDIR: break           // deleted or replaced while we were scanning
        case EDEADLK: dataless += 1           // would have to be downloaded first
        default: unreadable.append(dir)
        }
    }

    @inline(__always)
    private static func string(_ start: UnsafeRawPointer, _ count: Int) -> String {
        String(decoding: UnsafeRawBufferPointer(start: start, count: max(0, count)), as: UTF8.self)
    }

    private static func openDirectory(_ path: String) -> Int32 {
        let flags = O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC
        var fd = open(path, flags)
        if fd >= 0 || errno != ENAMETOOLONG { return fd }
        // Longer than PATH_MAX: walk down one component at a time.
        fd = open("/", flags)
        for component in path.split(separator: "/") where fd >= 0 {
            let next = openat(fd, String(component), flags)
            let code = errno
            close(fd)
            fd = next
            errno = code
        }
        return fd
    }
}

/// Keeps the `capacity` largest files seen by one thread.
struct LargestFiles {
    private let capacity: Int
    private var heap = Heap<FileNode> { $0.size < $1.size }
    /// A file has to be larger than this to be worth remembering.
    private(set) var threshold: UInt64

    init(capacity: Int) {
        self.capacity = capacity
        threshold = capacity > 0 ? 0 : .max
    }

    var files: [FileNode] { heap.elements }

    mutating func insert(_ file: FileNode) {
        if heap.count < capacity {
            heap.push(file)
        } else {
            heap.replaceTop(with: file)
        }
        if heap.count >= capacity, let smallest = heap.top { threshold = smallest.size }
    }
}

/// The shared backlog of directories. Threads only come here when their own
/// stack is empty; the scan is over when every thread is waiting here at once.
private final class WorkPool: @unchecked Sendable {
    let workerCount: Int
    let idleWorkers = Atomic<Int>(0)
    let finished = DispatchSemaphore(value: 0)

    private let mutex = UnsafeMutablePointer<pthread_mutex_t>.allocate(capacity: 1)
    private let condition = UnsafeMutablePointer<pthread_cond_t>.allocate(capacity: 1)
    private var queue: [DirTask] = []
    private var waiting = 0
    private var done = false

    init(workers: Int) {
        workerCount = workers
        pthread_mutex_init(mutex, nil)
        pthread_cond_init(condition, nil)
    }

    deinit {
        pthread_cond_destroy(condition)
        pthread_mutex_destroy(mutex)
        condition.deallocate()
        mutex.deallocate()
    }

    func give<Tasks: Collection<DirTask>>(_ tasks: Tasks) {
        pthread_mutex_lock(mutex)
        queue.append(contentsOf: tasks)
        for _ in 0..<min(waiting, tasks.count) { pthread_cond_signal(condition) }
        pthread_mutex_unlock(mutex)
    }

    /// Blocks until there is work, or returns nil once all work is done.
    func take() -> DirTask? {
        pthread_mutex_lock(mutex)
        defer { pthread_mutex_unlock(mutex) }
        while true {
            if let task = queue.popLast() { return task }
            if done { return nil }
            waiting += 1
            if waiting == workerCount {
                // Nobody is working, so nobody can produce more work.
                done = true
                pthread_cond_broadcast(condition)
                finished.signal()
                return nil
            }
            idleWorkers.store(waiting, ordering: .relaxed)
            pthread_cond_wait(condition, mutex)
            waiting -= 1
            idleWorkers.store(waiting, ordering: .relaxed)
        }
    }
}

/// A thread-safe set of (device, inode) pairs, split into shards to keep
/// lock contention low. Inodes are kept per device, 8 bytes apiece.
private final class InodeSet: Sendable {
    private final class Shard: Sendable {
        let inodes = Mutex<[Int32: Set<UInt64>]>([:])
    }

    private let shards = (0..<64).map { _ in Shard() }

    /// Returns false if the pair was already present.
    func insert(device: Int32, inode: UInt64) -> Bool {
        let hash = (inode ^ UInt64(UInt32(bitPattern: device))) &* 0x9E37_79B9_7F4A_7C15
        return shards[Int(hash >> 58)].inodes.withLock { $0[device, default: []].insert(inode).inserted }
    }
}
