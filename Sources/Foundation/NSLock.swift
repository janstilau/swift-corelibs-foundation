@_implementationOnly import CoreFoundation

public protocol NSLocking {
    func lock()
    func unlock()
}

// _RecursiveMutexPointer 和 _MutexPointer 的区别, 主要在于, mutext 初始化的时候, 属性的设置.
// typealias, 也可以增加 private 控制.
private typealias _MutexPointer = UnsafeMutablePointer<pthread_mutex_t>
private typealias _RecursiveMutexPointer = UnsafeMutablePointer<pthread_mutex_t>
private typealias _ConditionVariablePointer = UnsafeMutablePointer<pthread_cond_t>

open class NSLock: NSObject, NSLocking {
    internal var mutex = _MutexPointer.allocate(capacity: 1)
    private var timeoutCond = _ConditionVariablePointer.allocate(capacity: 1)
    private var timeoutMutex = _MutexPointer.allocate(capacity: 1)

    public override init() {
        pthread_mutex_init(mutex, nil)
        pthread_cond_init(timeoutCond, nil)
        pthread_mutex_init(timeoutMutex, nil)
    }
    
    deinit {
        pthread_mutex_destroy(mutex)
        mutex.deinitialize(count: 1) // deinitialize 调用对应位置的析构函数.
        mutex.deallocate() // deallocate 是释放指针的内存.
        deallocateTimedLockData(cond: timeoutCond, mutex: timeoutMutex)
    }
    
    open func lock() {
        pthread_mutex_lock(mutex)
    }

    open func unlock() {
        pthread_mutex_unlock(mutex)
        pthread_mutex_lock(timeoutMutex)
        pthread_cond_broadcast(timeoutCond)
        pthread_mutex_unlock(timeoutMutex)
    }

    // try 在当前不能获取到所的情况下, 直接返回 false, 目前没有用到这种场景.
    open func `try`() -> Bool {
        return pthread_mutex_trylock(mutex) == 0
    }
    
    open func lock(before limit: Date) -> Bool {
        if pthread_mutex_trylock(mutex) == 0 {
            return true
        }

#if os(macOS) || os(iOS) || os(Windows)
        return timedLock(mutex: mutex, endTime: limit, using: timeoutCond, with: timeoutMutex)
#else
        guard var endTime = timeSpecFrom(date: limit) else {
            return false
        }
        return pthread_mutex_timedlock(mutex, &endTime) == 0
#endif
    }

    open var name: String?
}

// 所谓的, Lock 的 synchronized, 就是加锁解锁的封装.
// 这个封装很好, 将固定的部分进行了封装. 更大的意义在于, Lock 是一个比较危险的资源, 这种封装可以减少用户使用错误的机会.
extension NSLock {
    internal func synchronized<T>(_ closure: () -> T) -> T {
        self.lock()
        defer { self.unlock() }
        return closure()
    }
}

open class NSConditionLock : NSObject, NSLocking {
    internal var _cond = NSCondition()
    internal var _value: Int
    internal var _thread: _swift_CFThreadRef?
    
    public convenience override init() {
        self.init(condition: 0)
    }
    
    public init(condition: Int) {
        _value = condition
    }

    open func lock() {
        let _ = lock(before: Date.distantFuture)
    }

    open func unlock() {
        _cond.lock()
        _thread = nil
        _cond.broadcast()
        _cond.unlock()
    }
    
    open var condition: Int {
        return _value
    }

    open func lock(whenCondition condition: Int) {
        let _ = lock(whenCondition: condition, before: Date.distantFuture)
    }

    open func `try`() -> Bool {
        return lock(before: Date.distantPast)
    }
    
    open func tryLock(whenCondition condition: Int) -> Bool {
        return lock(whenCondition: condition, before: Date.distantPast)
    }

    open func unlock(withCondition condition: Int) {
        _cond.lock()
#if os(Windows)
        _thread = INVALID_HANDLE_VALUE
#else
        _thread = nil
#endif
        _value = condition
        _cond.broadcast()
        _cond.unlock()
    }

    open func lock(before limit: Date) -> Bool {
        _cond.lock()
        while _thread != nil {
            if !_cond.wait(until: limit) {
                _cond.unlock()
                return false
            }
        }
#if os(Windows)
        _thread = GetCurrentThread()
#else
        _thread = pthread_self()
#endif
        _cond.unlock()
        return true
    }
    
    open func lock(whenCondition condition: Int, before limit: Date) -> Bool {
        _cond.lock()
        while _thread != nil || _value != condition {
            if !_cond.wait(until: limit) {
                _cond.unlock()
                return false
            }
        }
#if os(Windows)
        _thread = GetCurrentThread()
#else
        _thread = pthread_self()
#endif
        _cond.unlock()
        return true
    }
    
    open var name: String?
}

open class NSRecursiveLock: NSObject, NSLocking {
    internal var mutex = _RecursiveMutexPointer.allocate(capacity: 1)
#if os(macOS) || os(iOS) || os(Windows)
    private var timeoutCond = _ConditionVariablePointer.allocate(capacity: 1)
    private var timeoutMutex = _MutexPointer.allocate(capacity: 1)
#endif

    public override init() {
        super.init()
#if os(Windows)
        InitializeCriticalSection(mutex)
        InitializeConditionVariable(timeoutCond)
        InitializeSRWLock(timeoutMutex)
#else
#if CYGWIN
        var attrib : pthread_mutexattr_t? = nil
#else
        var attrib = pthread_mutexattr_t()
#endif
        withUnsafeMutablePointer(to: &attrib) { attrs in
            pthread_mutexattr_init(attrs)
            pthread_mutexattr_settype(attrs, Int32(PTHREAD_MUTEX_RECURSIVE))
            pthread_mutex_init(mutex, attrs)
        }
#if os(macOS) || os(iOS)
        pthread_cond_init(timeoutCond, nil)
        pthread_mutex_init(timeoutMutex, nil)
#endif
#endif
    }
    
    deinit {
#if os(Windows)
        DeleteCriticalSection(mutex)
#else
        pthread_mutex_destroy(mutex)
#endif
        mutex.deinitialize(count: 1)
        mutex.deallocate()
#if os(macOS) || os(iOS) || os(Windows)
        deallocateTimedLockData(cond: timeoutCond, mutex: timeoutMutex)
#endif
    }
    
    open func lock() {
#if os(Windows)
        EnterCriticalSection(mutex)
#else
        pthread_mutex_lock(mutex)
#endif
    }
    
    open func unlock() {
#if os(Windows)
        LeaveCriticalSection(mutex)
        AcquireSRWLockExclusive(timeoutMutex)
        WakeAllConditionVariable(timeoutCond)
        ReleaseSRWLockExclusive(timeoutMutex)
#else
        pthread_mutex_unlock(mutex)
#if os(macOS) || os(iOS)
        // Wakeup any threads waiting in lock(before:)
        pthread_mutex_lock(timeoutMutex)
        pthread_cond_broadcast(timeoutCond)
        pthread_mutex_unlock(timeoutMutex)
#endif
#endif
    }
    
    open func `try`() -> Bool {
#if os(Windows)
        return TryEnterCriticalSection(mutex)
#else
        return pthread_mutex_trylock(mutex) == 0
#endif
    }
    
    open func lock(before limit: Date) -> Bool {
#if os(Windows)
        if TryEnterCriticalSection(mutex) {
            return true
        }
#else
        if pthread_mutex_trylock(mutex) == 0 {
            return true
        }
#endif

#if os(macOS) || os(iOS) || os(Windows)
        return timedLock(mutex: mutex, endTime: limit, using: timeoutCond, with: timeoutMutex)
#else
        guard var endTime = timeSpecFrom(date: limit) else {
            return false
        }
        return pthread_mutex_timedlock(mutex, &endTime) == 0
#endif
    }

    open var name: String?
}

// NSCondition 里面会有一个 mutex, 一个 Conditon.
// 最最原始的使用, 是一个 pthread_cond_t, 一个 pthread_mutex_t 之间配合.
// iOS 里面, NSCondition 将这两个封到了一起.
// 这样, NSCondition 本身也就是一把锁了.
open class NSCondition: NSObject, NSLocking {
    internal var mutex = _MutexPointer.allocate(capacity: 1)
    internal var cond = _ConditionVariablePointer.allocate(capacity: 1)

    public override init() {
        pthread_mutex_init(mutex, nil)
        pthread_cond_init(cond, nil)
    }
    
    deinit {
        pthread_mutex_destroy(mutex)
        pthread_cond_destroy(cond)
    }
    
    open func lock() {
        pthread_mutex_lock(mutex)
    }
    
    open func unlock() {
        pthread_mutex_unlock(mutex)
    }
    
    open func wait() {
        pthread_cond_wait(cond, mutex)
    }

    open func wait(until limit: Date) -> Bool {
        guard var timeout = timeSpecFrom(date: limit) else {
            return false
        }
        return pthread_cond_timedwait(cond, mutex, &timeout) == 0
    }
    
    open func signal() {
        pthread_cond_signal(cond)
    }
    
    open func broadcast() {
        pthread_cond_broadcast(cond)
    }
    
    open var name: String?
}

private func timeSpecFrom(date: Date) -> timespec? {
    guard date.timeIntervalSinceNow > 0 else {
        return nil
    }
    let nsecPerSec: Int64 = 1_000_000_000
    let interval = date.timeIntervalSince1970
    let intervalNS = Int64(interval * Double(nsecPerSec))

    return timespec(tv_sec: time_t(intervalNS / nsecPerSec),
                    tv_nsec: Int(intervalNS % nsecPerSec))
}

#if os(macOS) || os(iOS) || os(Windows)

private func deallocateTimedLockData(cond: _ConditionVariablePointer, mutex: _MutexPointer) {
    pthread_cond_destroy(cond) // pthread_cond_destroy 会释放, cond 所管理的资源.
    cond.deinitialize(count: 1) // 不太明白这里, cond 会触发什么, 应该是没有析构的调用
    cond.deallocate()

    pthread_mutex_destroy(mutex)
    mutex.deinitialize(count: 1)
    mutex.deallocate()
}

// Emulate pthread_mutex_timedlock using pthread_cond_timedwait.
// lock(before:) passes a condition variable/mutex pair to use.
// unlock() will use pthread_cond_broadcast() to wake any waits in progress.
#if os(Windows)
private func timedLock(mutex: _MutexPointer, endTime: Date,
                       using timeoutCond: _ConditionVariablePointer,
                       with timeoutMutex: _MutexPointer) -> Bool {
    repeat {
      AcquireSRWLockExclusive(timeoutMutex)
      SleepConditionVariableSRW(timeoutCond, timeoutMutex,
                                timeoutFrom(date: endTime), 0)
      ReleaseSRWLockExclusive(timeoutMutex)
      if TryAcquireSRWLockExclusive(mutex) != 0 {
        return true
      }
    } while timeoutFrom(date: endTime) != 0
    return false
}

private func timedLock(mutex: _RecursiveMutexPointer, endTime: Date,
                       using timeoutCond: _ConditionVariablePointer,
                       with timeoutMutex: _MutexPointer) -> Bool {
    repeat {
      AcquireSRWLockExclusive(timeoutMutex)
      SleepConditionVariableSRW(timeoutCond, timeoutMutex,
                                timeoutFrom(date: endTime), 0)
      ReleaseSRWLockExclusive(timeoutMutex)
      if TryEnterCriticalSection(mutex) {
        return true
      }
    } while timeoutFrom(date: endTime) != 0
    return false
}
#else
private func timedLock(mutex: _MutexPointer, endTime: Date,
                       using timeoutCond: _ConditionVariablePointer,
                       with timeoutMutex: _MutexPointer) -> Bool {
    var timeSpec = timeSpecFrom(date: endTime)
    while var ts = timeSpec {
        let lockval = pthread_mutex_lock(timeoutMutex)
        precondition(lockval == 0)
        let waitval = pthread_cond_timedwait(timeoutCond, timeoutMutex, &ts)
        precondition(waitval == 0 || waitval == ETIMEDOUT)
        let unlockval = pthread_mutex_unlock(timeoutMutex)
        precondition(unlockval == 0)

        if waitval == ETIMEDOUT {
            return false
        }
        let tryval = pthread_mutex_trylock(mutex)
        precondition(tryval == 0 || tryval == EBUSY)
        if tryval == 0 { // The lock was obtained.
            return true
        }
        // pthread_cond_timedwait didn't timeout so wait some more.
        timeSpec = timeSpecFrom(date: endTime)
    }
    return false
}
#endif
#endif
