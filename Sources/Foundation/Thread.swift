
@_implementationOnly import CoreFoundation

internal typealias _swift_CFThreadRef = pthread_t

// 这个类, 主要就是向现场注册一些私有值的.
// 每个线程里面, 都有一个类似字典的东西, 传入 key 之后就会返回对应的 value/
// NSThreadSpecific 一般是类的静态变量, 将自己注册到线程的字典存储里面.
// 在这里, 是在 NSThread 的启动函数里面指定的 set. 因为如此, NSThread 才会和 pthread 所挂钩.
internal class NSThreadSpecific<T: NSObject> {
    
    private var key = _CFThreadSpecificKeyCreate()
    
    // 可以填充默认值的 get 方法.
    // 因为可能不是所有的线程, 都是 NSThread 创建的. 所以可能返回 nil.
    internal func get(_ generator: () -> T) -> T {
        if let specific = _CFThreadSpecificGet(key) {
            return specific as! T
        } else {
            let value = generator()
            _CFThreadSpecificSet(key, value)
            return value
        }
    }
    
    internal var current: T? {
        return _CFThreadSpecificGet(key) as? T
    }
    
    internal func set(_ value: T) {
        _CFThreadSpecificSet(key, value)
    }
    
    internal func clear() {
        _CFThreadSpecificSet(key, nil)
    }
}

internal enum _NSThreadStatus {
    case initialized
    case starting
    case executing
    case finished
}

// 同 Pthread 一样, 线程的入口函数.
// 这个函数里面, 会在调用 main 之前, 做一些 thread 的状态值的修改.
private func NSThreadStart(_ context: UnsafeMutableRawPointer?) -> UnsafeMutableRawPointer? {
    // unretainedReference 这个函数, 根据返回值的类型, 确定返回的类型.
    let thread: Thread = NSObject.unretainedReference(context!)
    Thread._currentThread.set(thread)
    if let name = thread.name {
        _CFThreadSetName(pthread_self(), name)
    }
    thread._status = .executing
    thread.main() // 最终还是调用 main
    thread._status = .finished
    // 这里, 是为了消耗 withRetainedReference 带来的 count + 1
    // 所以, 在线程的运行时间里面, 是不会 NSThread 消亡的.
    Thread.releaseReference(context!)
    return nil
}

open class Thread : NSObject {
    
    static internal var _currentThread = NSThreadSpecific<Thread>()
    
    open class var current: Thread {
        return Thread._currentThread.get() {
            if Thread.isMainThread {
                return mainThread
            } else {
                // 新建一个 NSThread, 和当前的线程 ID 挂钩.
                return Thread(thread: pthread_self())
            }
        }
    }
    
    open class var isMainThread: Bool {
        return _CFIsMainThread()
    }
    
    // !!! NSThread's mainThread property is incorrectly exported as "main", which conflicts with its "main" method.
    private static let _mainThread: Thread = {
        var thread = Thread(thread: _CFMainPThread)
        thread._status = .executing
        return thread
    }()
    
    open class var mainThread: Thread {
        return _mainThread
    }
    
    
    /// Alternative API for detached thread creation
    /// - Experiment: This is a draft API currently under consideration for official import into Foundation as a suitable alternative to creation via selector
    /// - Note: Since this API is under consideration it may be either removed or revised in the near future
    open class func detachNewThread(_ block: @escaping () -> Swift.Void) {
        let t = Thread(block: block)
        t.start()
    }
    
    open class func isMultiThreaded() -> Bool {
        return true
    }
    
    open class func sleep(until date: Date) {
        let start_ut = CFGetSystemUptime()
        let start_at = CFAbsoluteTimeGetCurrent()
        let end_at = date.timeIntervalSinceReferenceDate
        var ti = end_at - start_at
        let end_ut = start_ut + ti
        while (0.0 < ti) {
            var __ts__ = timespec(tv_sec: Int.max, tv_nsec: 0)
            if ti < Double(Int.max) {
                var integ = 0.0
                let frac: Double = withUnsafeMutablePointer(to: &integ) { integp in
                    return modf(ti, integp)
                }
                __ts__.tv_sec = Int(integ)
                __ts__.tv_nsec = Int(frac * 1000000000.0)
            }
            let _ = withUnsafePointer(to: &__ts__) { ts in
                nanosleep(ts, nil)
            }
            ti = end_ut - CFGetSystemUptime()
        }
    }
    
    open class func sleep(forTimeInterval interval: TimeInterval) {
        var ti = interval
        let start_ut = CFGetSystemUptime()
        let end_ut = start_ut + ti
        while 0.0 < ti {
            var __ts__ = timespec(tv_sec: Int.max, tv_nsec: 0)
            if ti < Double(Int.max) {
                var integ = 0.0
                let frac: Double = withUnsafeMutablePointer(to: &integ) { integp in
                    return modf(ti, integp)
                }
                __ts__.tv_sec = Int(integ)
                __ts__.tv_nsec = Int(frac * 1000000000.0)
            }
            let _ = withUnsafePointer(to: &__ts__) { ts in
                nanosleep(ts, nil)
            }
            ti = end_ut - CFGetSystemUptime()
        }
    }
    
    // 这里, 是调用了 pthread_exit,
    open class func exit() {
        Thread.current._status = .finished
        pthread_exit(nil)
    }
    
    // 同 NSThread 的 target action 不同, 这里主要的运行逻辑, 是在 main 这个闭包里面.
    internal var _main: () -> Void = {}
    private var _thread: _swift_CFThreadRef? = nil
    
    internal var _attr = pthread_attr_t()
    internal var _status = _NSThreadStatus.initialized
    internal var _cancelled = false
    
    /// - Note: This property is available on all platforms, but on some it may have no effect.
    open var qualityOfService: QualityOfService = .default
    
    open private(set) var threadDictionary: NSMutableDictionary = NSMutableDictionary()
    
    internal init(thread: _swift_CFThreadRef) {
        _thread = thread
    }
    
    public override init() {
        let _ = withUnsafeMutablePointer(to: &_attr) { attr in
            pthread_attr_init(attr)
            pthread_attr_setscope(attr, Int32(PTHREAD_SCOPE_SYSTEM))
            pthread_attr_setdetachstate(attr, Int32(PTHREAD_CREATE_DETACHED))
        }
    }
    
    public convenience init(block: @escaping () -> Swift.Void) {
        self.init()
        _main = block
    }
    
    open func start() {
        _status = .starting
        if _cancelled {
            _status = .finished
            return
        }
        _thread = self.withRetainedReference {
            // $0 是经过 withRetainedReference 返回的 rawPointer.
            // withRetainedReference 可以保证, 线程所管理的函数退出之前, NSThread 对象, 不会消亡.
            return _CFThreadCreate(self._attr, NSThreadStart, $0)
        }
    }
    
    open func main() {
        _main()
    }
    
    // 下面, 大部分都是对于线程相关的数据的包装.
    open var name: String? {
        get {
            return _name
        }
        set {
            if let thread = _thread {
                _CFThreadSetName(thread, newValue ?? "" )
            }
        }
    }
    
    internal var _name: String? {
        var buf: [Int8] = Array<Int8>(repeating: 0, count: 128)
        return String(cString: buf)
    }
    
    open var stackSize: Int {
        get {
            var size: Int = 0
            return withUnsafeMutablePointer(to: &_attr) { attr in
                withUnsafeMutablePointer(to: &size) { sz in
                    pthread_attr_getstacksize(attr, sz)
                    return sz.pointee
                }
            }
        }
        set {
            // just don't allow a stack size more than 1GB on any platform
            var s = newValue
            if (1 << 30) < s {
                s = 1 << 30
            }
            let _ = withUnsafeMutablePointer(to: &_attr) { attr in
                pthread_attr_setstacksize(attr, s)
            }
        }
    }
    
    open var isExecuting: Bool {
        return _status == .executing
    }
    
    open var isFinished: Bool {
        return _status == .finished
    }
    
    open var isCancelled: Bool {
        return _cancelled
    }
    
    open var isMainThread: Bool {
        return self === Thread.mainThread
    }
    
    open func cancel() {
        _cancelled = true
    }
    
    
    private class func backtraceAddresses<T>(_ body: (UnsafeMutablePointer<UnsafeMutableRawPointer?>, Int) -> [T]) -> [T] {
        // Same as swift/stdlib/public/runtime/Errors.cpp backtrace
        let maxSupportedStackDepth = 128;
        let addrs = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: maxSupportedStackDepth)
        defer { addrs.deallocate() }
        let count = backtrace(addrs, Int32(maxSupportedStackDepth))
        let addressCount = max(0, min(Int(count), maxSupportedStackDepth))
        return body(addrs, addressCount)
    }
    
    open class var callStackReturnAddresses: [NSNumber] {
        return backtraceAddresses({ (addrs, count) in
            UnsafeBufferPointer(start: addrs, count: count).map {
                NSNumber(value: UInt(bitPattern: $0))
            }
        })
    }
    
    open class var callStackSymbols: [String] {
        return backtraceAddresses({ (addrs, count) in
            var symbols: [String] = []
            if let bs = backtrace_symbols(addrs, Int32(count)) {
                symbols = UnsafeBufferPointer(start: bs, count: count).map {
                    guard let symbol = $0 else {
                        return "<null>"
                    }
                    return String(cString: symbol)
                }
                free(bs)
            }
            return symbols
        })
    }
}

extension NSNotification.Name {
    public static let NSWillBecomeMultiThreaded = NSNotification.Name(rawValue: "NSWillBecomeMultiThreadedNotification")
    public static let NSDidBecomeSingleThreaded = NSNotification.Name(rawValue: "NSDidBecomeSingleThreadedNotification")
    public static let NSThreadWillExit = NSNotification.Name(rawValue: "NSThreadWillExitNotification")
}
