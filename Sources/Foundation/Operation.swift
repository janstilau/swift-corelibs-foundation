import Dispatch

// 这些, 主要是用在 keypath 里面的.
internal let _NSOperationIsFinished = "isFinished"
internal let _NSOperationIsFinishedAlternate = "finished"
internal let _NSOperationIsExecuting = "isExecuting"
internal let _NSOperationIsExecutingAlternate = "executing"
internal let _NSOperationIsReady = "isReady"
internal let _NSOperationIsReadyAlternate = "ready"
internal let _NSOperationIsCancelled = "isCancelled"
internal let _NSOperationIsCancelledAlternate = "cancelled"
internal let _NSOperationIsAsynchronous = "isAsynchronous"
internal let _NSOperationQueuePriority = "queuePriority"
internal let _NSOperationThreadPriority = "threadPriority"
internal let _NSOperationCompletionBlock = "completionBlock"
internal let _NSOperationName = "name"
internal let _NSOperationDependencies = "dependencies"
internal let _NSOperationQualityOfService = "qualityOfService"
internal let _NSOperationQueueOperationsKeyPath = "operations"
internal let _NSOperationQueueOperationCountKeyPath = "operationCount"
internal let _NSOperationQueueSuspendedKeyPath = "suspended"

// 这个类, 就是来指明任务优先级的. 不过, 用更好地方式, 进行了说明.
extension QualityOfService {
    internal var qosClass: DispatchQoS {
        switch self {
        case .userInteractive: return .userInteractive
        case .userInitiated: return .userInitiated
        case .utility: return .utility
        case .background: return .background
        case .default: return .default
        }
    }
}

/*
 An abstract class that represents the code and data associated with a single task.
 一个, 实现了命令模式的抽象数据类. 提供了 operation call 操作符的接口.
 并且, 里面有很多调度类所需要的参数. 所以这个类已经不是单纯的对于 Callable 的封装了, 它更多的体现了和 OperationQueue 之间的配合.
 
 The presence of this built-in logic allows you to focus on the actual implementation of your task,
 rather than on the glue code needed to ensure it works correctly with other system objects.
 
 An operation queue executes its operations either directly, by running them on secondary threads,
 or indirectly using the libdispatch library (also known as Grand Central Dispatch)
 在这里, 是使用了 GCD, 在 GNU 的版本里面, 是自己控制的线程.
 
 Operation Dependencies
 Dependency 这个概念, 完全是 Queue 所关心的. 它是 Queue 调度队列的一个依据.

 KVO-Compliant Properties
 kvo 可以简化代码的逻辑, 在 Gnu 的代码里面, 就是通过监听 各个属性, 进行任务队列的排序, 等待任务队列, Read 任务队列数据的切换的.
 
 Asynchronous Versus Synchronous Operations
 Operation 有一个 isAsynchronous 的属性, 不过 Queue 不 Care. 当自己调用 start 方法的时候, isAsynchronous 可以控制开辟线程完成自己的任务. 这个属性在 GNU 里面, 没有体现.
 */

// 只要是数据相关的部分, 都进行了加锁.
open class Operation : NSObject {
    
    // PointerHashedUnmanagedBox 这个类, 主要是对于 T 的 Hash 功能的体现.
    struct PointerHashedUnmanagedBox<T: AnyObject>: Hashable {
        var contents: Unmanaged<T>
        func hash(into hasher: inout Hasher) {
            hasher.combine(contents.toOpaque())
        }
        static func == (_ lhs: PointerHashedUnmanagedBox, _ rhs: PointerHashedUnmanagedBox) -> Bool {
            return lhs.contents.toOpaque() == rhs.contents.toOpaque()
        }
    }
    
    // 一个枚举类, 专门用来代表任务的状态.
    // 这个顺序是有序的, 后面 isFinished 里面, 使用到了这个顺序.
    enum __NSOperationState : UInt8 {
        case initialized = 0x00
        case enqueuing = 0x48
        case enqueued = 0x50
        case dispatching = 0x88
        case starting = 0xD8
        case executing = 0xE0
        case finishing = 0xF0
        case finished = 0xF4
    }
    
    // 数据部分. 所有的都是私有数据, 外界使用, 用更好的属性接口.
    // 这里是 Internal, 也就是说, 只有当前的包里可以使用,.
    // 这里能够很好地体现, Swift 如何进行访问控制的, Foundation 包内, 可能会有很多类是配合 Operation 使用的, 这些类直接可以拿到 Operation 里面的值进行修改.
    // 而包的使用者, 只能是使用 Operation 暴露出去的接口.
    internal var __previousOperation: Unmanaged<Operation>?
    internal var __nextOperation: Unmanaged<Operation>?
    internal var __nextPriorityOperation: Unmanaged<Operation>?
    internal var __queue: Unmanaged<OperationQueue>?
    
    internal var __dependencies = [Operation]() // 依赖项.
    internal var __downDependencies = Set<PointerHashedUnmanagedBox<Operation>>()
    internal var __unfinishedDependencyCount: Int = 0
    internal var __completion: (() -> Void)?
    internal var __name: String?
    internal var __schedule: DispatchWorkItem?
    internal var __state: __NSOperationState = .initialized
    internal var __priorityValue: Operation.QueuePriority.RawValue?
    internal var __cachedIsReady: Bool = true
    internal var __isCancelled: Bool = false
    internal var __propertyQoS: QualityOfService?
    
    var __waitCondition = NSCondition()
    var __lock = NSLock()
    var __atomicLoad = NSLock()
    
    internal var _state: __NSOperationState {
        get {
            __atomicLoad.lock()
            defer { __atomicLoad.unlock() }
            return __state
        }
        set(newValue) {
            __atomicLoad.lock()
            defer { __atomicLoad.unlock() }
            __state = newValue
        }
    }
    
    // 首先, 当前的状态得是 old, 如果是, 那么改变为 new
    internal func _compareAndSwapState(_ old: __NSOperationState, _ new: __NSOperationState) -> Bool {
        __atomicLoad.lock()
        defer { __atomicLoad.unlock() }
        if __state != old { return false }
        __state = new
        return true
    }
    
    // 将 __lock.lock 封装成为一个小的方法.
    internal func _lock() {
        __lock.lock()
    }
    
    internal func _unlock() {
        __lock.unlock()
    }
    
    internal var _queue: OperationQueue? {
        _lock()
        defer { _unlock() }
        return __queue?.takeUnretainedValue()
    }
    
    internal func _adopt(queue: OperationQueue, schedule: DispatchWorkItem) {
        _lock()
        defer { _unlock() }
        // 这里, retain 了 Operation 相关的 Queue.
        __queue = Unmanaged.passRetained(queue)
        __schedule = schedule
    }
    
    internal var _isCancelled: Bool {
        __atomicLoad.lock()
        defer { __atomicLoad.unlock() }
        return __isCancelled
    }
    
    internal var _unfinishedDependencyCount: Int {
        get {
            __atomicLoad.lock()
            defer { __atomicLoad.unlock() }
            return __unfinishedDependencyCount
        }
    }
    
    internal func _incrementUnfinishedDependencyCount(by amount: Int = 1) {
        __atomicLoad.lock()
        defer { __atomicLoad.unlock() }
        __unfinishedDependencyCount += amount
    }
    
    internal func _decrementUnfinishedDependencyCount(by amount: Int = 1) {
        __atomicLoad.lock()
        defer { __atomicLoad.unlock() }
        __unfinishedDependencyCount -= amount
    }
    
    internal func _addParent(_ parent: Operation) {
        __downDependencies.insert(PointerHashedUnmanagedBox(contents: .passUnretained(parent)))
    }
    
    internal func _removeParent(_ parent: Operation) {
        __downDependencies.remove(PointerHashedUnmanagedBox(contents: .passUnretained(parent)))
    }
    
    internal var _cachedIsReady: Bool {
        get {
            __atomicLoad.lock()
            defer { __atomicLoad.unlock() }
            return __cachedIsReady
        }
        set(newValue) {
            __atomicLoad.lock()
            defer { __atomicLoad.unlock() }
            __cachedIsReady = newValue
        }
    }
    
    internal func _fetchCachedIsReady(_ retest: inout Bool) -> Bool {
        let setting = _cachedIsReady
        if !setting {
            _lock()
            retest = __unfinishedDependencyCount == 0
            _unlock()
        }
        return setting
    }
    
    internal func _invalidateQueue() {
        _lock()
        __schedule = nil
        let queue = __queue
        __queue = nil
        _unlock()
        queue?.release()
    }
    
    internal func _removeAllDependencies() {
        _lock()
        let deps = __dependencies
        __dependencies.removeAll()
        _unlock()
        
        for dep in deps {
            dep._lock()
            _lock()
            let upIsFinished = dep._state == .finished
            if !upIsFinished && !_isCancelled {
                _decrementUnfinishedDependencyCount()
            }
            dep._removeParent(self)
            _unlock()
            dep._unlock()
        }
    }
    
    internal static func observeValue(forKeyPath keyPath: String, ofObject theOperation: Operation) {
        // 在方法内部定义枚举, 将作用域范围控制了起来.
        enum Transition {
            case toFinished
            case toExecuting
            case toReady
        }
        
        let kind: Transition?
        if keyPath == _NSOperationIsFinished || keyPath == _NSOperationIsFinishedAlternate {
            kind = .toFinished
        } else if keyPath == _NSOperationIsExecuting || keyPath == _NSOperationIsExecutingAlternate {
            kind = .toExecuting
        } else if keyPath == _NSOperationIsReady || keyPath == _NSOperationIsReadyAlternate {
            kind = .toReady
        } else {
            kind = nil
        }
        
        if let transition = kind {
            switch transition {
            case .toFinished: // we only care about NO -> YES
                if !theOperation.isFinished {
                    return
                }
                
                var ready_deps = [Operation]()
                theOperation._lock()
                let state = theOperation._state
                if theOperation.__queue != nil && state.rawValue < __NSOperationState.starting.rawValue {
                    print("*** \(type(of: theOperation)) \(Unmanaged.passUnretained(theOperation).toOpaque()) went isFinished=YES without being started by the queue it is in")
                }
                if state.rawValue < __NSOperationState.finishing.rawValue {
                    theOperation._state = .finishing
                } else if state == .finished {
                    theOperation._unlock()
                    return
                }
                
                // 这里, 是查找依赖自己的下游的 operation, 通知他们修改自己的 ready 状态. 然后重新调度.
                let down_deps = theOperation.__downDependencies
                theOperation.__downDependencies.removeAll()
                if 0 < down_deps.count {
                    for down in down_deps {
                        let idown = down.contents.takeUnretainedValue()
                        idown._lock()
                        if idown._unfinishedDependencyCount == 1 {
                            ready_deps.append(idown)
                        } else if idown._unfinishedDependencyCount > 1 {
                            idown._decrementUnfinishedDependencyCount()
                        } else {
                            assert(idown._unfinishedDependencyCount  == 0)
                            assert(idown._isCancelled == true)
                        }
                        idown._unlock()
                    }
                }
                
                theOperation._state = .finished
                let theQueue = theOperation.__queue
                theOperation.__queue = nil
                theOperation._unlock()
                
                if 0 < ready_deps.count {
                    for down in ready_deps {
                        down._lock()
                        if down._unfinishedDependencyCount >= 1 {
                            down._decrementUnfinishedDependencyCount()
                        }
                        down._unlock()
                        Operation.observeValue(forKeyPath: _NSOperationIsReady, ofObject: down)
                    }
                }
                
                // 当 op Finish 之后, 调用自己的 __waitCondition 的唤醒服务, 使得别的线程因为 wait 的代码重新执行.
                theOperation.__waitCondition.lock()
                theOperation.__waitCondition.broadcast()
                theOperation.__waitCondition.unlock()
                
                // 在 观察到 Finish 之后, 调用 Completion 方法.
                // Operation 在 queue 的
                if let complete = theOperation.__completion {
                    let held = Unmanaged.passRetained(theOperation)
                    DispatchQueue.global(qos: .default).async {
                        complete()
                        held.release()
                    }
                }
                // 注销自己的 queue 里面.
                if let queue = theQueue {
                    queue.takeUnretainedValue()._operationFinished(theOperation, state)
                    queue.release()
                }
            case .toExecuting:
                let isExecuting = theOperation.isExecuting
                theOperation._lock()
                if theOperation._state.rawValue < __NSOperationState.executing.rawValue && isExecuting {
                    theOperation._state = .executing
                }
                theOperation._unlock()
            case .toReady:
                // 当, operation 处于 ready 状态了. 就调动它的 queue 的调度算法.
                let r = theOperation.isReady
                theOperation._cachedIsReady = r
                let q = theOperation._queue
                if r {
                    q?._schedule()
                }
            }
        }
    }
    
    public override init() { }
    
    open func start() {
        let state = _state
        if __NSOperationState.finished == state { return }
        
        if !_compareAndSwapState(__NSOperationState.initialized, __NSOperationState.starting) && !(__NSOperationState.starting == state && __queue != nil) {
            switch state {
            case .executing: fallthrough
            case .finishing:
                fatalError("\(self): receiver is already executing")
            default:
                fatalError("\(self): something is trying to start the receiver simultaneously from more than one thread")
            }
        }
        
        if state.rawValue < __NSOperationState.enqueued.rawValue && !isReady {
            _state = state
            fatalError("\(self): receiver is not yet ready to execute")
        }
        
        let isCanc = _isCancelled
        if !isCanc {
            _state = .executing
            Operation.observeValue(forKeyPath: _NSOperationIsExecuting, ofObject: self)
            // 如果有 queue, 就是在 queue 里面调用自己, 不然就直接调用 main.
            _queue?._execute(self) ?? main()
        }
        
        if __NSOperationState.executing == _state {
            _state = .finishing
            Operation.observeValue(forKeyPath: _NSOperationIsExecuting, ofObject: self)
            Operation.observeValue(forKeyPath: _NSOperationIsFinished, ofObject: self)
        } else {
            _state = .finishing
            Operation.observeValue(forKeyPath: _NSOperationIsFinished, ofObject: self)
        }
    }
    
    // 这个方法, 就是 templateMethod 需要自定义的一环, 在子类中重写.
    open func main() { }
    
    open var isCancelled: Bool {
        return _isCancelled
    }
    
    open func cancel() {
        if isFinished { return }
        
        __atomicLoad.lock()
        __isCancelled = true
        __atomicLoad.unlock()
        
        if __NSOperationState.executing.rawValue <= _state.rawValue {
            return
        }
        
        _lock()
        __unfinishedDependencyCount = 0
        _unlock()
        Operation.observeValue(forKeyPath: _NSOperationIsReady, ofObject: self)
    }
    
    // Operation state 记录了自己的状态, 但是这个状态, 不应该由外界知道, 需要使用 property 包装一层.
    open var isExecuting: Bool {
        return __NSOperationState.executing == _state
    }
    
    open var isFinished: Bool {
        return __NSOperationState.finishing.rawValue <= _state.rawValue
    }
    
    open var isAsynchronous: Bool {
        return false
    }
    
    // Operation ready 了, 就是没有依赖了.
    open var isReady: Bool {
        _lock()
        defer { _unlock() }
        return __unfinishedDependencyCount == 0
    }
    
    // 这样写, 就不用写捕获列表了????
    internal func _addDependency(_ beenDepended: Operation) {
        withExtendedLifetime(self) {
            withExtendedLifetime(beenDepended) {
                
                var addedDepend: Operation?
                
                _lock()
                // 如果, 之前依赖里面没有, 那么才把参数添加到 __dependencies 中去.
                if __dependencies.first(where: { $0 === beenDepended }) == nil {
                    __dependencies.append(beenDepended)
                    addedDepend = beenDepended
                }
                _unlock()
                
                if let addedOp = addedDepend {
                    // 锁的顺序要注意栈式顺序.
                    addedOp._lock()
                    _lock()
                    let upIsFinished = addedOp._state == __NSOperationState.finished
                    if !upIsFinished && !_isCancelled {
                        assert(_unfinishedDependencyCount >= 0)
                        _incrementUnfinishedDependencyCount()
                        addedOp._addParent(self)
                    }
                    _unlock()
                    addedOp._unlock()
                }
                Operation.observeValue(forKeyPath: _NSOperationIsReady, ofObject: self)
            }
        }
    }
    
    open func addDependency(_ op: Operation) {
        _addDependency(op)
    }
    
    open func removeDependency(_ op: Operation) {
        withExtendedLifetime(self) {
            withExtendedLifetime(op) {
                var up_canidate: Operation?
                _lock()
                let idxCanidate = __dependencies.firstIndex { $0 === op }
                if idxCanidate != nil {
                    up_canidate = op
                }
                _unlock()
                
                if let canidate = up_canidate {
                    canidate._lock()
                    _lock()
                    if let idx = __dependencies.firstIndex(where: { $0 === op }) {
                        if canidate._state == .finished && _isCancelled {
                            _decrementUnfinishedDependencyCount()
                        }
                        canidate._removeParent(self)
                        __dependencies.remove(at: idx)
                    }
                    
                    _unlock()
                    canidate._unlock()
                }
                Operation.observeValue(forKeyPath: _NSOperationIsReady, ofObject: self)
            }
        }
    }
    
    open var dependencies: [Operation] {
        get {
            _lock()
            defer { _unlock() }
            return __dependencies.filter { !($0 is _BarrierOperation) }
        }
    }
    
    internal func changePriority(_ newPri: Operation.QueuePriority.RawValue) {
        _lock()
        guard let oq = __queue?.takeUnretainedValue() else {
            __priorityValue = newPri
            _unlock()
            return
        }
        _unlock()
        oq._lock()
        var oldPri = __priorityValue
        if oldPri == nil {
            if let v = (0 == oq.__actualMaxNumOps) ? nil : __propertyQoS {
                switch v {
                case .default: oldPri = Operation.QueuePriority.normal.rawValue
                case .userInteractive: oldPri = Operation.QueuePriority.veryHigh.rawValue
                case .userInitiated: oldPri = Operation.QueuePriority.high.rawValue
                case .utility: oldPri = Operation.QueuePriority.low.rawValue
                case .background: oldPri = Operation.QueuePriority.veryLow.rawValue
                }
            } else {
                oldPri = Operation.QueuePriority.normal.rawValue
            }
        }
        if oldPri == newPri {
            oq._unlock()
            return
        }
        __priorityValue = newPri
        var op = oq._firstPriorityOperation(oldPri)
        var prev: Unmanaged<Operation>?
        while let operation = op?.takeUnretainedValue() {
            let nextOp = operation.__nextPriorityOperation
            if operation === self {
                // Remove from old list
                if let previous = prev?.takeUnretainedValue() {
                    previous.__nextPriorityOperation = nextOp
                } else {
                    oq._setFirstPriorityOperation(oldPri!, nextOp)
                }
                if nextOp == nil {
                    oq._setlastPriorityOperation(oldPri!, prev)
                }
                
                __nextPriorityOperation = nil
                
                // Append to new list
                if let oldLast = oq._lastPriorityOperation(newPri)?.takeUnretainedValue() {
                    oldLast.__nextPriorityOperation = Unmanaged.passUnretained(self)
                } else {
                    oq._setFirstPriorityOperation(newPri, Unmanaged.passUnretained(self))
                }
                oq._setlastPriorityOperation(newPri, Unmanaged.passUnretained(self))
                break
            }
            prev = op
            op = nextOp
        }
        oq._unlock()
    }
    
    open var queuePriority: Operation.QueuePriority {
        get {
            guard let prioValue = __priorityValue else {
                return Operation.QueuePriority.normal
            }
            return Operation.QueuePriority(rawValue: prioValue) ?? .veryHigh
        }
        set(newValue) {
            let newPri: Operation.QueuePriority.RawValue
            if Operation.QueuePriority.veryHigh.rawValue <= newValue.rawValue {
                newPri = Operation.QueuePriority.veryHigh.rawValue
            } else if Operation.QueuePriority.high.rawValue <= newValue.rawValue {
                newPri = Operation.QueuePriority.high.rawValue
            } else if Operation.QueuePriority.normal.rawValue <= newValue.rawValue {
                newPri = Operation.QueuePriority.normal.rawValue
            } else if Operation.QueuePriority.low.rawValue < newValue.rawValue {
                newPri = Operation.QueuePriority.normal.rawValue
            } else if Operation.QueuePriority.veryLow.rawValue < newValue.rawValue {
                newPri = Operation.QueuePriority.low.rawValue
            } else {
                newPri = Operation.QueuePriority.veryLow.rawValue
            }
            if __priorityValue != newPri {
                changePriority(newPri)
            }
        }
    }
    
    open var completionBlock: (() -> Void)? {
        get {
            _lock()
            defer { _unlock() }
            return __completion
        }
        set(newValue) {
            _lock()
            defer { _unlock() }
            __completion = newValue
        }
    }
    
    // Operation wait, 是 Operation 的行为, 所以 __waitCondition 应该在 Operation 上, 在任务结束之后, 使用同样的 Condition 进行唤醒.
    open func waitUntilFinished() {
        __waitCondition.lock()
        while !isFinished {
            __waitCondition.wait()
        }
        __waitCondition.unlock()
    }
    
    open var qualityOfService: QualityOfService {
        get {
            __atomicLoad.lock()
            defer { __atomicLoad.unlock() }
            return __propertyQoS ?? QualityOfService.default
        }
        set(newValue) {
            __atomicLoad.lock()
            defer { __atomicLoad.unlock() }
            __propertyQoS = newValue
        }
    }
    
    open var name: String? {
        get {
            return __name
        }
        set(newValue) {
            __name = newValue
        }
    }
}

extension Operation {
    public func willChangeValue(forKey key: String) {
    }
    
    public func didChangeValue(forKey key: String) {
        Operation.observeValue(forKeyPath: key, ofObject: self)
    }
    
    public func willChangeValue<Value>(for keyPath: KeyPath<Operation, Value>) {
    }
    
    public func didChangeValue<Value>(for keyPath: KeyPath<Operation, Value>) {
        switch keyPath {
        // 这里, \ 这样就可以转换会字符串????
        case \Operation.isFinished: didChangeValue(forKey: _NSOperationIsFinished)
        case \Operation.isReady: didChangeValue(forKey: _NSOperationIsReady)
        case \Operation.isCancelled: didChangeValue(forKey: _NSOperationIsCancelled)
        case \Operation.isExecuting: didChangeValue(forKey: _NSOperationIsExecuting)
        default: break
        }
    }
}

extension Operation {
    
    public enum QueuePriority : Int {
        case veryLow = -8
        case low = -4
        case normal = 0
        case high = 4
        case veryHigh = 8
        
        internal static var barrier = 12
        
        internal static let priorities = [
            Operation.QueuePriority.barrier,
            Operation.QueuePriority.veryHigh.rawValue,
            Operation.QueuePriority.high.rawValue,
            Operation.QueuePriority.normal.rawValue,
            Operation.QueuePriority.low.rawValue,
            Operation.QueuePriority.veryLow.rawValue
        ]
    }
}

open class BlockOperation : Operation {
    var _block: (() -> Void)?
    var _executionBlocks: [() -> Void]?
    public override init() {
    }
    
    // 所有的, 都是 escaping 的, 因为实际上, BlockOperation 一定是异步调用的.
    // 就算是后面直接调用 start 方法, 也是先把 block 存起来后才去调用的.
    public convenience init(block: @escaping () -> Void) {
        self.init()
        _block = block
    }
    
    open func addExecutionBlock(_ block: @escaping () -> Void) {
        if isExecuting || isFinished {
            fatalError("blocks cannot be added after the operation has started executing or finished")
        }
        _lock()
        defer { _unlock() }
        if _block == nil {
            _block = block
        } else if _executionBlocks == nil {
            _executionBlocks = [block]
        } else {
            _executionBlocks?.append(block)
        }
    }
    
    // readonly 的属性, 没有 get, 只有 get.
    open var executionBlocks: [() -> Void] {
        get {
            // 这种写法, 会很常见, 当 lock 可以全部控制整个代码块的时候
            // 在下面, 为了效率不应全部锁住, 就在适当的地方调用 unlock 了.
            _lock()
            defer { _unlock() }
            
            var blocks = [() -> Void]()
            if let existing = _block {
                blocks.append(existing)
            }
            if let existing = _executionBlocks {
                blocks.append(contentsOf: existing)
            }
            return blocks
        }
    }
    
    open override func main() {
        var blocks = [() -> Void]() // 定义一个数组. 这里是直接使用了 Block 的类型.
        // 抽取数据的部分, 使用 lock, 真正执行的部分, 不用 lock.
        _lock()
        if let existing = _block {
            blocks.append(existing)
        }
        if let existing = _executionBlocks {
            blocks.append(contentsOf: existing)
        }
        _unlock()
        // 实际上, 真正的逻辑, 就是遍历调用里面的 block. 所以, 实际上所有的 block 都是运行在一个线程里面.
        for block in blocks {
            block()
        }
    }
}

internal final class _BarrierOperation : Operation {
    var _block: (() -> Void)?
    init(_ block: @escaping () -> Void) {
        _block = block
    }
    override func main() {
        _lock()
        let block = _block
        _block = nil
        _unlock()
        block?()
        _removeAllDependencies()
    }
}

internal final class _OperationQueueProgress : Progress {
    var queue: Unmanaged<OperationQueue>?
    let lock = NSLock()
    
    init(_ queue: OperationQueue) {
        self.queue = Unmanaged.passUnretained(queue)
        super.init(parent: nil, userInfo: nil)
    }
    
    func invalidateQueue() {
        lock.lock()
        queue = nil
        lock.unlock()
    }
    
    override var totalUnitCount: Int64 {
        get {
            return super.totalUnitCount
        }
        set(newValue) {
            super.totalUnitCount = newValue
            lock.lock()
            queue?.takeUnretainedValue().__progressReporting = true
            lock.unlock()
        }
    }
}

extension OperationQueue {
    public static let defaultMaxConcurrentOperationCount: Int = -1
}

@available(OSX 10.5, *)
open class OperationQueue : NSObject, ProgressReporting {
    let __queueLock = NSLock()
    let __atomicLoad = NSLock()
    var __firstOperation: Unmanaged<Operation>?
    var __lastOperation: Unmanaged<Operation>?
    // 这是一个元组, 存储着各个优先级的第一个任务.
    // 所以, 其实在 Queue 里面, 是按照优先级, 有着很多个队列在维护着.
    var __firstPriorityOperation: (barrier: Unmanaged<Operation>?,
                                   veryHigh: Unmanaged<Operation>?,
                                   high: Unmanaged<Operation>?,
                                   normal: Unmanaged<Operation>?,
                                   low: Unmanaged<Operation>?,
                                   veryLow: Unmanaged<Operation>?)
    var __lastPriorityOperation: (barrier: Unmanaged<Operation>?, veryHigh: Unmanaged<Operation>?, high: Unmanaged<Operation>?, normal: Unmanaged<Operation>?, low: Unmanaged<Operation>?, veryLow: Unmanaged<Operation>?)
    var _barriers = [_BarrierOperation]()
    var _progress: _OperationQueueProgress?
    var __operationCount: Int = 0
    var __maxNumOps: Int = OperationQueue.defaultMaxConcurrentOperationCount
    var __actualMaxNumOps: Int32 = .max
    var __numExecOps: Int32 = 0
    var __dispatch_queue: DispatchQueue?
    var __backingQueue: DispatchQueue?
    var __name: String?
    var __suspended: Bool = false
    var __overcommit: Bool = false
    var __propertyQoS: QualityOfService?
    var __mainQ: Bool = false
    var __progressReporting: Bool = false
    
    internal func _lock() {
        __queueLock.lock()
    }
    
    internal func _unlock() {
        __queueLock.unlock()
    }
    
    internal var _suspended: Bool {
        __atomicLoad.lock()
        defer { __atomicLoad.unlock() }
        return __suspended
    }
    
    internal func _incrementExecutingOperations() {
        __atomicLoad.lock()
        defer { __atomicLoad.unlock() }
        __numExecOps += 1
    }
    
    internal func _decrementExecutingOperations() {
        __atomicLoad.lock()
        defer { __atomicLoad.unlock() }
        if __numExecOps > 0 {
            __numExecOps -= 1
        }
    }
    
    internal func _incrementOperationCount(by amount: Int = 1) {
        __atomicLoad.lock()
        defer { __atomicLoad.unlock() }
        __operationCount += amount
    }
    
    internal func _decrementOperationCount(by amount: Int = 1) {
        __atomicLoad.lock()
        defer { __atomicLoad.unlock() }
        __operationCount -= amount
    }
    
    internal func _firstPriorityOperation(_ prio: Operation.QueuePriority.RawValue?) -> Unmanaged<Operation>? {
        guard let priority = prio else { return nil }
        switch priority {
        case Operation.QueuePriority.barrier: return __firstPriorityOperation.barrier
        case Operation.QueuePriority.veryHigh.rawValue: return __firstPriorityOperation.veryHigh
        case Operation.QueuePriority.high.rawValue: return __firstPriorityOperation.high
        case Operation.QueuePriority.normal.rawValue: return __firstPriorityOperation.normal
        case Operation.QueuePriority.low.rawValue: return __firstPriorityOperation.low
        case Operation.QueuePriority.veryLow.rawValue: return __firstPriorityOperation.veryLow
        default: fatalError("unsupported priority")
        }
    }
    
    internal func _setFirstPriorityOperation(_ prio: Operation.QueuePriority.RawValue, _ operation: Unmanaged<Operation>?) {
        switch prio {
        case Operation.QueuePriority.barrier: __firstPriorityOperation.barrier = operation
        case Operation.QueuePriority.veryHigh.rawValue: __firstPriorityOperation.veryHigh = operation
        case Operation.QueuePriority.high.rawValue: __firstPriorityOperation.high = operation
        case Operation.QueuePriority.normal.rawValue: __firstPriorityOperation.normal = operation
        case Operation.QueuePriority.low.rawValue: __firstPriorityOperation.low = operation
        case Operation.QueuePriority.veryLow.rawValue: __firstPriorityOperation.veryLow = operation
        default: fatalError("unsupported priority")
        }
    }
    
    internal func _lastPriorityOperation(_ prio: Operation.QueuePriority.RawValue?) -> Unmanaged<Operation>? {
        guard let priority = prio else { return nil }
        switch priority {
        case Operation.QueuePriority.barrier: return __lastPriorityOperation.barrier
        case Operation.QueuePriority.veryHigh.rawValue: return __lastPriorityOperation.veryHigh
        case Operation.QueuePriority.high.rawValue: return __lastPriorityOperation.high
        case Operation.QueuePriority.normal.rawValue: return __lastPriorityOperation.normal
        case Operation.QueuePriority.low.rawValue: return __lastPriorityOperation.low
        case Operation.QueuePriority.veryLow.rawValue: return __lastPriorityOperation.veryLow
        default: fatalError("unsupported priority")
        }
    }
    
    internal func _setlastPriorityOperation(_ prio: Operation.QueuePriority.RawValue, _ operation: Unmanaged<Operation>?) {
        if let op = operation?.takeUnretainedValue() {
            assert(op.queuePriority.rawValue == prio)
        }
        switch prio {
        case Operation.QueuePriority.barrier: __lastPriorityOperation.barrier = operation
        case Operation.QueuePriority.veryHigh.rawValue: __lastPriorityOperation.veryHigh = operation
        case Operation.QueuePriority.high.rawValue: __lastPriorityOperation.high = operation
        case Operation.QueuePriority.normal.rawValue: __lastPriorityOperation.normal = operation
        case Operation.QueuePriority.low.rawValue: __lastPriorityOperation.low = operation
        case Operation.QueuePriority.veryLow.rawValue: __lastPriorityOperation.veryLow = operation
        default: fatalError("unsupported priority")
        }
    }
    
    internal func _operationFinished(_ finishedOperation: Operation, _ previousState: Operation.__NSOperationState) {
        // There are only three cases where an operation might have a nil queue
        // A) The operation was never added to a queue and we got here by a normal KVO change
        // B) The operation was somehow already finished
        // C) the operation was attempted to be added to a queue but an exception occured and was ignored...
        // Option C is NOT supported!
        let isBarrier = finishedOperation is _BarrierOperation
        
        _lock()
        let nextOp = finishedOperation.__nextOperation
        if Operation.__NSOperationState.finished == finishedOperation._state {
            let prevOp = finishedOperation.__previousOperation
            if let prev = prevOp {
                prev.takeUnretainedValue().__nextOperation = nextOp
            } else {
                __firstOperation = nextOp
            }
            if let next = nextOp {
                next.takeUnretainedValue().__previousOperation = prevOp
            } else {
                __lastOperation = prevOp
            }
            // only decrement execution count on operations that were executing! (the execution was initially set to __NSOperationStateDispatching so we must compare from that or later)
            // else the number of executing operations might underflow
            if previousState.rawValue >= Operation.__NSOperationState.dispatching.rawValue {
                _decrementExecutingOperations()
            }
            finishedOperation.__previousOperation = nil
            finishedOperation.__nextOperation = nil
            finishedOperation._invalidateQueue()
        }
        if !isBarrier {
            _decrementOperationCount()
        }
        _unlock()
        
        _schedule()
        
        if previousState.rawValue >= Operation.__NSOperationState.enqueuing.rawValue {
            // 在这里, 对 Operation 进行了 release 的操作.
            Unmanaged.passUnretained(finishedOperation).release()
        }
    }
    
    internal var _propertyQoS: QualityOfService? {
        get {
            __atomicLoad.lock()
            defer { __atomicLoad.unlock() }
            return __propertyQoS
        }
        set(newValue) {
            __atomicLoad.lock()
            defer { __atomicLoad.unlock() }
            __propertyQoS = newValue
        }
    }
    
    // 类似懒加载的技术, 将 queue 背后的 dispatch quueue 生成.
    // 都是 concurrent 的.
    internal func _synthesizeBackingQueue() -> DispatchQueue {
        guard let queue = __backingQueue else {
            let queue: DispatchQueue
            if let qos = _propertyQoS {
                if let name = __name {
                    queue = DispatchQueue(label: name, qos: qos.qosClass, attributes: .concurrent)
                } else {
                    queue = DispatchQueue(label: "NSOperationQueue \(Unmanaged.passUnretained(self).toOpaque())", qos: qos.qosClass, attributes: .concurrent)
                }
            } else {
                if let name = __name {
                    queue = DispatchQueue(label: name, attributes: .concurrent)
                } else {
                    queue = DispatchQueue(label: "NSOperationQueue \(Unmanaged.passUnretained(self).toOpaque())", attributes: .concurrent)
                }
            }
            __backingQueue = queue
            return queue
        }
        return queue
    }
    
    static internal var _currentQueue = NSThreadSpecific<OperationQueue>()
    
    // 这里单个任务的 GCD 里面的包装体
    internal func _schedule(_ op: Operation) {
        op._state = .starting
        // set current tsd
        OperationQueue._currentQueue.set(self)
        op.start() //
        OperationQueue._currentQueue.clear()
        // We've just cleared _currentQueue storage.
        // NSThreadSpecific doesn't release stored value on clear.
        // This means `self` will leak if we don't release manually.
        Unmanaged.passUnretained(self).release()
        
        // unset current tsd
        if op.isFinished && op._state.rawValue < Operation.__NSOperationState.finishing.rawValue {
            Operation.observeValue(forKeyPath: _NSOperationIsFinished, ofObject: op)
        }
    }
    
    // 相比较于, NSFoundation 的简单地 ready, stash 两个队列, 这里有各个优先级的队列的控制.
    // 并且, 自己主动维护了一个链表, 使得这个类异常复杂.
    internal func _schedule() {
        var retestOps = [Operation]()
        _lock()
        var slotsAvail = __actualMaxNumOps - __numExecOps
        // 各个优先级的队列, 都来一次.
        for prio in Operation.QueuePriority.priorities {
            if 0 >= slotsAvail || _suspended {
                break
            }
            var currentOpertion = _firstPriorityOperation(prio)
            var prev: Unmanaged<Operation>?
            
            // 每次提交一个任务, 都会更新 slotsAvail 的值, 所以, 还是先提交高优先级的任务, 只有高优先级的任务完成了, 才执行低优先级的任务.
            while let operation = currentOpertion?.takeUnretainedValue() {
                if 0 >= slotsAvail || _suspended {
                    break
                }
                let next = operation.__nextPriorityOperation
                var retest = false
                // if the cached state is possibly not valid then the isReady value needs to be re-updated
                if Operation.__NSOperationState.enqueued == operation._state && operation._fetchCachedIsReady(&retest) {
                    if let previous = prev?.takeUnretainedValue() {
                        previous.__nextPriorityOperation = next
                    } else {
                        _setFirstPriorityOperation(prio, next)
                    }
                    if next == nil {
                        _setlastPriorityOperation(prio, prev)
                    }
                    
                    operation.__nextPriorityOperation = nil
                    operation._state = .dispatching
                    _incrementExecutingOperations()
                    slotsAvail -= 1
                    
                    let queue: DispatchQueue
                    if __mainQ {
                        queue = DispatchQueue.main
                    } else {
                        queue = __dispatch_queue ?? _synthesizeBackingQueue()
                    }
                    
                    // 最终, 还是用到了 gcd 的方法.
                    if let schedule = operation.__schedule {
                        if operation is _BarrierOperation {
                            queue.async(flags: .barrier, execute: {
                                schedule.perform()
                            })
                        } else {
                            queue.async(execute: schedule)
                        }
                    }
                    
                    currentOpertion = next
                } else {
                    if retest {
                        retestOps.append(operation)
                    }
                    prev = currentOpertion
                    currentOpertion = next
                }
            }
        }
        _unlock()
        
        for op in retestOps {
            if op.isReady {
                op._cachedIsReady = true
            }
        }
    }
    
    internal var _isReportingProgress: Bool {
        return __progressReporting
    }
    
    internal func _execute(_ op: Operation) {
        var operationProgress: Progress? = nil
        if !(op is _BarrierOperation) && _isReportingProgress {
            let opProgress = Progress(parent: nil, userInfo: nil)
            opProgress.totalUnitCount = 1
            progress.addChild(opProgress, withPendingUnitCount: 1)
            operationProgress = opProgress
        }
        operationProgress?.becomeCurrent(withPendingUnitCount: 1)
        defer { operationProgress?.resignCurrent() }
        
        op.main() // 就是调用 op 的 main.
    }
    
    internal var _maxNumOps: Int {
        get {
            __atomicLoad.lock()
            defer { __atomicLoad.unlock() }
            return __maxNumOps
        }
        set(newValue) {
            __atomicLoad.lock()
            defer { __atomicLoad.unlock() }
            __maxNumOps = newValue
        }
    }
    
    internal var _isSuspended: Bool {
        get {
            __atomicLoad.lock()
            defer { __atomicLoad.unlock() }
            return __suspended
        }
        set(newValue) {
            __atomicLoad.lock()
            defer { __atomicLoad.unlock() }
            __suspended = newValue
        }
    }
    
    internal var _operationCount: Int {
        _lock()
        defer { _unlock() }
        var op = __firstOperation
        var cnt = 0
        while let operation = op?.takeUnretainedValue() {
            if !(operation is _BarrierOperation) {
                cnt += 1
            }
            op = operation.__nextOperation
        }
        return cnt
    }
    
    // 遍历链表, 把所有的 Operation 收集起来, 然后返回.
    internal func _operations(includingBarriers: Bool = false) -> [Operation] {
        _lock()
        defer { _unlock() }
        var operations = [Operation]()
        var op = __firstOperation
        while let operation = op?.takeUnretainedValue() {
            if includingBarriers || !(operation is _BarrierOperation) {
                operations.append(operation)
            }
            op = operation.__nextOperation
        }
        return operations
    }
    
    public override init() {
        super.init()
        __name = "NSOperationQueue \(Unmanaged<OperationQueue>.passUnretained(self).toOpaque())"
    }
    
    internal init(asMainQueue: ()) {
        super.init()
        __mainQ = true
        __maxNumOps = 1
        __actualMaxNumOps = 1
        __name = "NSOperationQueue Main Queue"
        __propertyQoS = QualityOfService(qos_class_main())
    }
    
    open var progress: Progress {
        get {
            _lock()
            defer { _unlock() }
            guard let progress = _progress else {
                let progress = _OperationQueueProgress(self)
                _progress = progress
                return progress
            }
            return progress
        }
    }
    
    // 向队列里面, 添加任务的核心逻辑.
    internal func _addOperations(_ ops: [Operation], barrier: Bool = false) {
        if ops.isEmpty { return }
        
        var failures = 0
        var successes = 0
        var listHead: Unmanaged<Operation>?
        var lastNewOp: Unmanaged<Operation>?
        
        for op in ops {
            // 因为 Operation 是不可以复用的, 所以必然应该是 init 的状态.
            if op._compareAndSwapState(.initialized, .enqueuing) {
                successes += 1
                if 0 == failures {
                    let retainedOperation = Unmanaged.passRetained(op)
                    // 在入队的时候, 先记录一下 Operation 的 read 状态.
                    op._cachedIsReady = op.isReady
                    
                    let schedule: DispatchWorkItem
                    // 如果, 设置了优先级, 那么就按照优先级执行任务. 否则就使用当前环境的.
                    if let qos = op.__propertyQoS?.qosClass {
                        schedule = DispatchWorkItem.init(qos: qos, flags: .enforceQoS, block: {
                            self._schedule(op)
                        })
                    } else {
                        schedule = DispatchWorkItem(flags: .assignCurrentContext, block: {
                            self._schedule(op)
                        })
                    }
                    // 在这里, 一个 Operation, 和 Queue, 以及实际会执行的 GCD 任务绑定了.
                    op._adopt(queue: self, schedule: schedule)
                    op.__previousOperation = lastNewOp
                    op.__nextOperation = nil
                    // 这里, 维护了 Operation 之间的一个链表.
                    if let lastNewOperation = lastNewOp?.takeUnretainedValue() {
                        lastNewOperation.__nextOperation = retainedOperation
                    } else {
                        listHead = retainedOperation
                    }
                    lastNewOp = retainedOperation
                } else {
                    _ = op._compareAndSwapState(.enqueuing, .initialized)
                }
            } else {
                failures += 1
            }
        }
        
        // 这里, 如果有失败的其实是就崩了, 先不管.
        if 0 < failures {
            while let currentOpertion = listHead?.takeUnretainedValue() {
                let nextNewOp = currentOpertion.__nextOperation
                currentOpertion._invalidateQueue()
                currentOpertion.__previousOperation = nil
                currentOpertion.__nextOperation = nil
                _ = currentOpertion._compareAndSwapState(.enqueuing, .initialized)
                listHead?.release()
                listHead = nextNewOp
            }
            fatalError("operations finished, executing or already in a queue cannot be enqueued")
        }
        
        // Attach any operations pending attachment to main list
        if !barrier {
            _lock()
            _incrementOperationCount()
        }
        
        // 这里是将插入的链表, 和 queue 的链表进行挂钩.
        var pending = listHead
        if let pendingOperation = pending?.takeUnretainedValue() {
            let old_last = __lastOperation
            pendingOperation.__previousOperation = old_last
            if let old = old_last?.takeUnretainedValue() {
                old.__nextOperation = pending
            } else {
                __firstOperation = pending
            }
            __lastOperation = lastNewOp
        }
        
        while let pendingOperation = pending?.takeUnretainedValue() {
            
            if !barrier {
                var barrierOp = _firstPriorityOperation(Operation.QueuePriority.barrier)
                // 这里, 为什么可以 barrier 就在于此了, 普通的任务, 要将当前的 barrier 任务, 添加为依赖, 这样只有当 barrier 的任务完成之后, 普通的任务才能执行.
                // 从队列的角度来说, 就是 barrier 的任务不完成, 普通的任务, 就没有机会进行调度.
                while let barrierOperation = barrierOp?.takeUnretainedValue() {
                    pendingOperation._addDependency(barrierOperation)
                    barrierOp = barrierOperation.__nextPriorityOperation
                }
            }
            
            _ = pendingOperation._compareAndSwapState(.enqueuing, .enqueued)
            
            var pri = pendingOperation.__priorityValue
            // 如果, 没有设置 __priorityValue , 那么 Queue 中会计算, 根据 QoS 的值进行转化, 或者直接用 normal
            if pri == nil {
                let v = __actualMaxNumOps == 1 ? nil : pendingOperation.__propertyQoS
                if let qos = v {
                    switch qos {
                    case .default: pri = Operation.QueuePriority.normal.rawValue
                    case .userInteractive: pri = Operation.QueuePriority.veryHigh.rawValue
                    case .userInitiated: pri = Operation.QueuePriority.high.rawValue
                    case .utility: pri = Operation.QueuePriority.low.rawValue
                    case .background: pri = Operation.QueuePriority.veryLow.rawValue
                    }
                } else {
                    pri = Operation.QueuePriority.normal.rawValue
                }
            }
            // 这里, 就是将对应的任务, 连接到 Queue 所维护的队列的末尾了.
            pendingOperation.__nextPriorityOperation = nil
            if let old_last = _lastPriorityOperation(pri)?.takeUnretainedValue() {
                old_last.__nextPriorityOperation = pending
            } else {
                _setFirstPriorityOperation(pri!, pending)
            }
            _setlastPriorityOperation(pri!, pending)
            pending = pendingOperation.__nextOperation
        }
        
        if !barrier {
            _unlock()
        }
        
        if !barrier {
            _schedule()
        }
    }
    
    open func addOperation(_ op: Operation) {
        _addOperations([op], barrier: false)
    }
    
    // 添加 block, 就是将 Block 纳入到 Operation 的抽象里面, 然后添加到队列里面.
    open func addOperation(_ block: @escaping () -> Void) {
        let op = BlockOperation(block: block)
        if let qos = __propertyQoS {
            op.qualityOfService = qos
        }
        addOperation(op)
    }
    
    // wait 这个行为, 是 Operation 的行为, 所以 waitCondition 在 Operation 上, 相应的方法, 也在 Operation 上.
    open func addOperations(_ ops: [Operation], waitUntilFinished wait: Bool) {
        _addOperations(ops, barrier: false)
        if wait {
            for op in ops {
                op.waitUntilFinished()
            }
        }
    }
    
    open func addBarrierBlock(_ barrier: @escaping () -> Void) {
        var queue: DispatchQueue?
        _lock()
        if let op = __firstOperation {
            let barrierOperation = _BarrierOperation(barrier)
            barrierOperation.__priorityValue = Operation.QueuePriority.barrier
            var iterOp: Unmanaged<Operation>? = op
            while let operation = iterOp?.takeUnretainedValue() {
                barrierOperation.addDependency(operation)
                iterOp = operation.__nextOperation
            }
            _addOperations([barrierOperation], barrier: true)
        } else {
            queue = _synthesizeBackingQueue()
        }
        _unlock()
        
        // 因为, 这个 Queue 里面的所有任务, 其实都是放到了一个队列里面, 所以, 这个队列 barrier, 其实就是这个任务 barrier.
        // 队列的 barrier, 先用自己设计的算法去理解.
        if let q = queue {
            q.async(flags: .barrier, execute: barrier)
        } else {
            _schedule()
        }
    }
    
    // 在修改了, 可以影响到调度策略的数值后, 重新调用调度算法.
    open var maxConcurrentOperationCount: Int {
        get {
            return _maxNumOps
        }
        set(newValue) {
            if !__mainQ {
                _lock()
                _maxNumOps = newValue
                let acnt = OperationQueue.defaultMaxConcurrentOperationCount == newValue || Int32.max < newValue ? Int32.max : Int32(newValue)
                __actualMaxNumOps = acnt
                _unlock()
                _schedule()
            }
            
        }
    }
    
    // 在修改了, 可以影响到调度策略的数值后, 重新调用调度算法.
    open var isSuspended: Bool {
        get {
            return _isSuspended
        }
        set(newValue) {
            if !__mainQ {
                _isSuspended = newValue
                if !newValue {
                    _schedule()
                }
            }
        }
    }
    
    open var name: String? {
        get {
            _lock()
            defer { _unlock() }
            return __name ?? "NSOperationQueue \(Unmanaged.passUnretained(self).toOpaque())"
        }
        set(newValue) {
            if !__mainQ {
                _lock()
                __name = newValue ?? ""
                _unlock()
            }
        }
    }
    
    open var qualityOfService: QualityOfService {
        get {
            return _propertyQoS ?? .default
        }
        set(newValue) {
            if !__mainQ {
                _lock()
                _propertyQoS = newValue
                _unlock()
            }
        }
    }
    
    // 有这个量, 其实可以证明, OperationQueue 的底层, 就是 GCD 了.
    unowned(unsafe) open var underlyingQueue: DispatchQueue? {
        get {
            if __mainQ {
                return DispatchQueue.main
            } else {
                _lock()
                defer { _unlock() }
                return __dispatch_queue
            }
        }
        set(newValue) {
            if !__mainQ {
                if 0 < _operationCount {
                    fatalError("operation queue must be empty in order to change underlying dispatch queue")
                }
                __dispatch_queue = newValue
            }
        }
    }
    
    // cancle 是对于 Operation 的操作, 而不是队列的操作.
    // 所以这里不需要加锁, Queue 所控制的数据都没有发生改变.
    open func cancelAllOperations() {
        if !__mainQ {
            for op in _operations(includingBarriers: true) {
                op.cancel()
            }
        }
    }
    
    open func waitUntilAllOperationsAreFinished() {
        var ops = _operations(includingBarriers: true)
        while 0 < ops.count {
            for op in ops {
                // 当前线程进行了 wait, 但是在其他线程, 可以继续完成任务, 并对队列进行改变.
                // 所以在唤醒之后, 重新进行任务的获取.
                op.waitUntilFinished()
            }
            ops = _operations(includingBarriers: true)
        }
    }
    
    open class var current: OperationQueue? {
        get {
            if Thread.isMainThread {
                return main
            }
            return OperationQueue._currentQueue.current
        }
    }
    
    open class var main: OperationQueue {
        get {
            // 为什么要这面写???
            // SWIFT不支持静态变量而不将其附加到类/结构中。尝试使用静态变量声明私有结构。
            // 如果, 想要达成在函数内使用静态变量的目的, 应该在函数内定义一个类型, 然后将这个 static 挂钩到这个类型上.
            struct Once {
                static let mainQ = OperationQueue(asMainQueue: ())
            }
            return Once.mainQ
        }
    }
}

extension OperationQueue {
    // These two functions are inherently a race condition and should be avoided if possible
    
    open var operations: [Operation] {
        get {
            return _operations(includingBarriers: false)
        }
    }
    
    open var operationCount: Int {
        get {
            return _operationCount
        }
    }
}
