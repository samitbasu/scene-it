import CoreFoundation
import Darwin
import MachO
import SceneItCore

/// Stops the app once an Objective-C exception has unwound a Swift job on the main thread
/// (ADR 0026), at the next run-loop activity it observes, normally before the next isolation
/// check.
///
/// HIToolbox catches an exception that escapes the run loop, logs it and carries on, whatever
/// `NSApplicationCrashOnExceptions` says. When the exception came from a job, the job runner
/// never restored the thread's record of the current task and executor, which is left pointing
/// into a dead stack frame, and the next isolation check crashes somewhere unrelated (#72, #120,
/// #142).
///
/// Nonisolated, so the check itself makes no isolation check: one would read the dead frame.
nonisolated enum UnwoundJobTrap {
    /// Whether the thread's records say a job is running: a task's, or an isolated deinit's,
    /// which has an executor but no task.
    enum JobRecord {
        case set, clear
    }

    /// What the main thread is running, as far as Swift concurrency is concerned.
    enum JobContext: Equatable {
        case none
        /// A job, which may be running a run loop of its own, as a modal alert does.
        case job
        /// The thread says a job is running, but none is: something left the job without
        /// returning through the runner, as an exception does.
        case unwound

        /// `runner` is the code of the image that runs jobs; a job has one of its frames on the
        /// stack, below everything the job calls.
        init(record: JobRecord, returnAddresses: some Sequence<UInt>, runner: Range<UInt>) {
            switch record {
            case .clear: self = .none
            case .set: self = returnAddresses.contains(where: runner.contains) ? .job : .unwound
            }
        }
    }

    /// Whether the executor record can tell a job from no job: it must be clear outside any job.
    /// A runtime that names the main executor there, as `_swift_getActiveExecutor` does, would
    /// make every run-loop entry look like an unwound job.
    enum Calibration: Equatable {
        case usable, unusable

        init(identityOutsideAnyJob identity: UInt) {
            self = identity == 0 ? .usable : .unusable
        }
    }

    @MainActor private(set) static var observer: CFRunLoopObserver?

    /// The executor record's reader, once calibration has found it usable. Only the main thread
    /// touches it, from run-loop callbacks that must make no isolation check.
    nonisolated(unsafe) private(set) static var executorIdentity: ExecutorIdentity?

    @MainActor static func install() {
        guard observer == nil else { return }
        if runner == nil {
            Log.diagnostics.fault("the job runner's code wasn't found; unwound jobs won't be trapped")
        }
        if executorRecordReader == nil {
            Log.diagnostics.fault("the executor record can't be read; unwound deinit jobs won't be trapped")
        } else {
            CFRunLoopPerformBlock(CFRunLoopGetMain(), CFRunLoopMode.commonModes.rawValue, calibrate)
            CFRunLoopWakeUp(CFRunLoopGetMain())
        }
        let activities: CFRunLoopActivity = [.entry, .afterWaiting]
        let observer = CFRunLoopObserverCreateWithHandler(nil, activities.rawValue, true, CFIndex.min, check)
        CFRunLoopAddObserver(CFRunLoopGetMain(), observer, .commonModes)
        Self.observer = observer
    }

    private static func check(_ observer: CFRunLoopObserver?, _ activity: CFRunLoopActivity) {
        if context == .unwound {
            fatalError("An Objective-C exception unwound a Swift job (ADR 0026)")
        }
    }

    /// Runs from the main run loop, outside any job.
    private static func calibrate() {
        guard let reader = executorRecordReader else { return }
        switch Calibration(identityOutsideAnyJob: reader()) {
        case .usable:
            executorIdentity = reader
        case .unusable:
            Log.diagnostics.fault(
                "the executor record isn't clear outside a job; unwound deinit jobs won't be trapped")
        }
    }

    /// Reads the executor record first: it's a plain read, safe even from a dead frame, which
    /// is still mapped. `withUnsafeCurrentTask` retains and releases the task it finds. After an
    /// unwind that's still safe: the task never completes, so it's leaked, never freed.
    static var record: JobRecord {
        if let executorIdentity, executorIdentity() != 0 { return .set }
        return withUnsafeCurrentTask { $0 == nil ? .clear : .set }
    }

    static var context: JobContext {
        let record = record
        guard case .set = record else { return .none }
        guard let runner else { return .job }
        var frames = InlineArray<512, UnsafeMutableRawPointer?>(repeating: nil)
        var span = frames.mutableSpan
        return span.withUnsafeMutableBufferPointer { buffer in
            let count = Int(backtrace(buffer.baseAddress, Int32(buffer.count)))
            // A full buffer may have cut the runner's frame off; a job is the safe guess.
            guard count < buffer.count else { return .job }
            let addresses = buffer.prefix(count).lazy.map { UInt(bitPattern: $0) }
            return JobContext(record: record, returnAddresses: addresses, runner: runner)
        }
    }

    /// `dlfcn.h`'s `RTLD_DEFAULT`, a cast macro that Swift doesn't import.
    private static var rtldDefault: UnsafeMutableRawPointer? { UnsafeMutableRawPointer(bitPattern: -2) }

    /// The `__TEXT` of `libswift_Concurrency`, where `swift_job_run` lives.
    static let runner: Range<UInt>? = {
        var info = Dl_info()
        guard let symbol = dlsym(rtldDefault, "swift_job_run"), dladdr(symbol, &info) != 0,
            let base = info.dli_fbase
        else { return nil }
        var size: UInt = 0
        guard let text = getsegmentdata(base.assumingMemoryBound(to: mach_header_64.self), "__TEXT", &size),
            size > 0
        else { return nil }
        let start = UInt(bitPattern: text)
        return start..<(start + size)
    }()

    /// The identity of the executor the thread's record names, null outside any job.
    typealias ExecutorIdentity = @convention(c) () -> UInt

    /// The runtime's `swift_task_getCurrentExecutor`, the only reader of the record that doesn't
    /// act on it, and acting on a dead frame's record is what crashes. No Swift API exposes it.
    /// It returns a `SerialExecutorRef`, the identity and then a witness table, in the Swift
    /// calling convention. Both conventions return the first word in the same register, so a C
    /// function type that returns only that word reads the identity.
    static let executorRecordReader: ExecutorIdentity? = {
        guard let symbol = dlsym(rtldDefault, "swift_task_getCurrentExecutor") else { return nil }
        return unsafeBitCast(symbol, to: ExecutorIdentity.self)
    }()
}
