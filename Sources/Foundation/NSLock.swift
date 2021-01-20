@_implementationOnly import CoreFoundation

#if canImport(Glibc)
import Glibc
#endif

#if os(Windows)
import WinSDK
#endif

public protocol NSLocking {
    func lock()
    func unlock()
}

// _RecursiveMutexPointer 和 _MutexPointer 的区别, 主要在于, mutext 初始化的时候, 属性的设置.
private typealias _MutexPointer = UnsafeMutablePointer<pthread_mutex_t>
private typealias _RecursiveMutexPointer = UnsafeMutablePointer<pthread_mutex_t>
private typealias _ConditionVariablePointer = UnsafeMutablePointer<pthread_cond_t>

open class NSLock: NSObject, NSLocking {
    internal var mutex = _MutexPointer.allocate(capacity: 1)
    private var timeoutCond = _ConditionVariablePointer.allocate(capacity: 1)
    private var timeoutMutex = _MutexPointer.allocate(capacity: 1)

    public override init() {
        // NSLock 控制的资源, 在 init 方法里面, 调用 C 方法, 进行初始化.
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
// 而且, 根据传入的闭包, 返回对应的类型的值.
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
#if os(Windows)
        _thread = INVALID_HANDLE_VALUE
#else
        _thread = nil
#endif
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

open class NSCondition: NSObject, NSLocking {
    internal var mutex = _MutexPointer.allocate(capacity: 1)
    internal var cond = _ConditionVariablePointer.allocate(capacity: 1)

    public override init() {
#if os(Windows)
        InitializeSRWLock(mutex)
        InitializeConditionVariable(cond)
#else
        pthread_mutex_init(mutex, nil)
        pthread_cond_init(cond, nil)
#endif
    }
    
    deinit {
#if os(Windows)
        // SRWLock do not need to be explicitly destroyed
#else
        pthread_mutex_destroy(mutex)
        pthread_cond_destroy(cond)
#endif
        mutex.deinitialize(count: 1)
        cond.deinitialize(count: 1)
        mutex.deallocate()
        cond.deallocate()
    }
    
    open func lock() {
#if os(Windows)
        AcquireSRWLockExclusive(mutex)
#else
        pthread_mutex_lock(mutex)
#endif
    }
    
    open func unlock() {
#if os(Windows)
        ReleaseSRWLockExclusive(mutex)
#else
        pthread_mutex_unlock(mutex)
#endif
    }
    
    open func wait() {
#if os(Windows)
        SleepConditionVariableSRW(cond, mutex, WinSDK.INFINITE, 0)
#else
        pthread_cond_wait(cond, mutex)
#endif
    }

    open func wait(until limit: Date) -> Bool {
#if os(Windows)
        return SleepConditionVariableSRW(cond, mutex, timeoutFrom(date: limit), 0)
#else
        guard var timeout = timeSpecFrom(date: limit) else {
            return false
        }
        return pthread_cond_timedwait(cond, mutex, &timeout) == 0
#endif
    }
    
    open func signal() {
#if os(Windows)
        WakeConditionVariable(cond)
#else
        pthread_cond_signal(cond)
#endif
    }
    
    open func broadcast() {
#if os(Windows)
        WakeAllConditionVariable(cond)
#else
        pthread_cond_broadcast(cond)
#endif
    }
    
    open var name: String?
}

#if os(Windows)
private func timeoutFrom(date: Date) -> DWORD {
  guard date.timeIntervalSinceNow > 0 else { return 0 }
  return DWORD(date.timeIntervalSinceNow * 1000)
}
#else
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
#endif

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
