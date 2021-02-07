
// 想要完成 hashlink map, 对传入的 value 进行一次包装是不可避免的. 原因就在于, 需要有链表的 pre,next 指针.
// 也就是说, pre, next 指针, 构建了链表的结构. 然后在内部真实存储的时候,  dict 的 value 值, 就变为了 entry. 只有这样, 才能真正的做到, 通过 hash 表快速读取到数据之后, 通过链表的指针, 进行 sequence 的控制.
private class NSCacheEntry<KeyType : AnyObject, ObjectType : AnyObject> {
    var key: KeyType
    var value: ObjectType
    var cost: Int
    
    // HashLinkMap. 根据 hash 进行快速的读取, 根据 link map 进行 sequence 的控制.
    // 这里, 其实感觉不应该叫做 prevByCost, entry 作为数据类, 不应该表现出顺序的逻辑来, 这个过程, 应该交给 NSCache 来进行.
    // 如果, 真的有必要多个排序, 才应该在数据里面有 prevByCost, PrevByTime, PrevBySth.
    // 不过, prev 这种缩写, 在苹果源码里面也有, 以后可以放心使用了倒是.
    var prevByCost: NSCacheEntry?
    var nextByCost: NSCacheEntry?
    
    init(key: KeyType, value: ObjectType, cost: Int) {
        self.key = key
        self.value = value
        self.cost = cost
    }
}

fileprivate class NSCacheKey: NSObject {
    
    var value: AnyObject
    
    init(_ value: AnyObject) {
        self.value = value
        super.init()
    }
    
    // 原始的 OC 时代的 hash value 的获取.
    override var hash: Int {
        switch self.value {
        case let nsObject as NSObject:
            return nsObject.hashValue
        case let hashable as AnyHashable: // A type-erased hashable value.
            return hashable.hashValue
        default: return 0
        }
    }
    
    override func isEqual(_ object: Any?) -> Bool {
        guard let other = (object as? NSCacheKey) else { return false }
        if self.value === other.value {
            // 如果, 直接就是同一对象, 必然相等了
            return true
        } else {
            guard let left = self.value as? NSObject,
                  let right = other.value as? NSObject else { return false }
            // 使用 OC 的 isEqual 进行比较.
            return left.isEqual(right)
        }
    }
}

open class NSCache<KeyType : AnyObject, ObjectType : AnyObject> : NSObject {
    // 所有的变量, 都有着范围控制.
    // 对于不应该暴露出去的遍历, 使用了 _进行暗示. 至少源码是非常喜欢这样写. 也就遵从吧.
    private var _entries = Dictionary<NSCacheKey, NSCacheEntry<KeyType, ObjectType>>() // hash 表, 用于快速查找.
    private let _lock = NSLock() // 多线程的保护.
    private var _totalCost = 0 // 消耗量的统计
    private var _head: NSCacheEntry<KeyType, ObjectType>? // 链表, 用于实现 LRU
    
    open var name: String = ""
    open var totalCostLimit: Int = 0 // limits are imprecise/not strict
    open var countLimit: Int = 0 // limits are imprecise/not strict
    open var evictsObjectsWithDiscardedContent: Bool = false
    
    public override init() {}
    
    open weak var delegate: NSCacheDelegate?
    
    open func object(forKey key: KeyType) -> ObjectType? {
        var object: ObjectType?
        
        let key = NSCacheKey(key)
        
        // 尽量减少, 临界区的大小. 因为实际上, 会造成数据污染的, 就是临界区的位置. 其他的准备的代码, 是没有影响的.
        _lock.lock()
        if let entry = _entries[key] {
            object = entry.value
        }
        _lock.unlock()
        
        return object
    }
    
    open func setObject(_ obj: ObjectType, forKey key: KeyType) {
        setObject(obj, forKey: key, cost: 0)
    }
    
    // 简单的列表操作.
    private func removeFromList(_ entry: NSCacheEntry<KeyType, ObjectType>) {
        let oldPrev = entry.prevByCost
        let oldNext = entry.nextByCost
        
        oldPrev?.nextByCost = oldNext
        oldNext?.prevByCost = oldPrev
        
        if entry === _head {
            _head = oldNext
        }
    }
    
    private func insertIntoList(_ entry: NSCacheEntry<KeyType, ObjectType>) {
        // 如果, 当前的链表没有数据, 直接就把 entry 当做头结点存储起来.
        guard var currentElement = _head else {
            entry.prevByCost = nil
            entry.nextByCost = nil
            _head = entry
            return
        }
        
        // 新插入的 entry cost 大, 那么就把新插入的 entry 当做头结点.
        // 从这也可以看出来, 在这个实现里面, 是从大到小存储的 list 里面的数据.
        guard entry.cost > currentElement.cost else {
            entry.prevByCost = nil
            entry.nextByCost = currentElement
            currentElement.prevByCost = entry
            _head = entry
            return
        }
        
        // 将新的 entry, 插入到合适的位置.
        while let nextByCost = currentElement.nextByCost, nextByCost.cost < entry.cost {
            currentElement = nextByCost
        }
        
        let nextElement = currentElement.nextByCost
        
        currentElement.nextByCost = entry
        entry.prevByCost = currentElement
        
        entry.nextByCost = nextElement
        nextElement?.prevByCost = entry
    }
    
    // setObject 中, 是主要的控制逻辑, 里面有着对于当前类的主要逻辑的维护.
    open func setObject(_ obj: ObjectType, forKey key: KeyType, cost g: Int) {
        let objCost = max(g, 0)
        let keyRef = NSCacheKey(key)
        
        // 这里其实应该使用 defer 的. lock, unlock 中间代码太长了. 而且, 如果以后修改, 添加了提前退出的代码, 很危险.
        
        _lock.lock()
        
        let costDiff: Int
        
        if let entry = _entries[keyRef] {
            // 首先判断一下, 之前有没有对应的 key 已经占据了位置.
            // key 已经有值了, 更新值, 更新 cost, 如果 cost 不同, 更新链表的位置. 更新链表的位置, 就是简单地 remove, insert. insert 会保证, 新插入的数据, 在合适的位置上.
            costDiff = objCost - entry.cost
            entry.cost = objCost
            entry.value = obj
            
            if costDiff != 0 {
                removeFromList(entry)
                insertIntoList(entry)
            }
        } else {
            // 新的数据, hash 表维护, 链表维护
            let entry = NSCacheEntry(key: key, value: obj, cost: objCost)
            _entries[keyRef] = entry
            insertIntoList(entry)
            costDiff = objCost
        }
        
        _totalCost += costDiff
        
        // 当, cost 如果超了, 就进行 purge 的操作, 这个过程, 在 YYmodel 里面也见过, 所以这是一个很通用的做法.
        // 因为, 链表本身就已经是 cost 大到小排序了, 所以可以直接按照链表的顺序进行 purge.
        // 这也是类的作用, 在内部维护数据结构, 在算法中使用.
        var purgeAmount = (totalCostLimit > 0) ? (_totalCost - totalCostLimit) : 0
        while purgeAmount > 0 {
            if let entry = _head {
                delegate?.cache(unsafeDowncast(self, to:NSCache<AnyObject, AnyObject>.self), willEvictObject: entry.value)
                    
                // 删除, 并且更新数据
                _totalCost -= entry.cost
                purgeAmount -= entry.cost
                removeFromList(entry)
                _entries[NSCacheKey(entry.key)] = nil
            } else {
                break
            }
        }
        
        // 当 count 超了, 进行 purge 的操作, 也是按照链表的顺序来的.
        var purgeCount = (countLimit > 0) ? (_entries.count - countLimit) : 0
        while purgeCount > 0 {
            if let entry = _head {
                delegate?.cache(unsafeDowncast(self, to:NSCache<AnyObject, AnyObject>.self), willEvictObject: entry.value)
                
                // 这里不需要更新 count 的值, 因为这是一个计算属性
                // 计算属性的优势就在于, 不需要专门维护, 因为它是需要维护的数据所产生的值.
                _totalCost -= entry.cost
                purgeCount -= 1
                removeFromList(entry) // _head will be changed to next entry in remove(_:)
                _entries[NSCacheKey(entry.key)] = nil
            } else {
                break
            }
        }
        
        _lock.unlock()
    }
    
    // Remove 的操作就很简单了, 加锁, hahs 表操作, 链表操作, 维护类的数据.
    open func removeObject(forKey key: KeyType) {
        let keyRef = NSCacheKey(key)
        
        _lock.lock()
        if let entry = _entries.removeValue(forKey: keyRef) {
            _totalCost -= entry.cost
            removeFromList(entry)
        }
        _lock.unlock()
    }
    
    open func removeAllObjects() {
        _lock.lock()
        _entries.removeAll()
        
        // 这里, 直接 _head = nil 不就可以了吗.
        // 感觉没有必要每个都进行 prev, next 的删除操作. 本身, entry 数据就是只会在内部使用的数据, 不会暴露出去.
        // 引用计数, 解决了内存问题了.
        while let currentElement = _head {
            let nextElement = currentElement.nextByCost
            
            currentElement.prevByCost = nil
            currentElement.nextByCost = nil
            
            _head = nextElement
        }
        
        _totalCost = 0
        _lock.unlock()
    }    
}

public protocol NSCacheDelegate : NSObjectProtocol {
    func cache(_ cache: NSCache<AnyObject, AnyObject>, willEvictObject obj: Any)
}

extension NSCacheDelegate {
    func cache(_ cache: NSCache<AnyObject, AnyObject>, willEvictObject obj: Any) {
    }
}
