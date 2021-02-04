
// A static, ordered collection of unique objects.

open class NSOrderedSet: NSObject, NSCopying, NSMutableCopying, NSSecureCoding, ExpressibleByArrayLiteral {

    fileprivate var _storage: NSSet // unique, 通过 _storage 进行保证
    fileprivate var _orderedStorage: NSArray // ordered, 通过 NSArray 进行保证.
    // 在类里面的各个方法里面, 都需要保持上面两个数据的同步, 用来保证这个类所表现出来的 API 的正确性.
    
    public convenience override init() {
        self.init(objects: [], count: 0)
    }

    public init(objects: UnsafePointer<AnyObject>?, count cnt: Int) {
        let storage = NSSet(objects: objects, count: cnt)
        _storage = storage
        
        let orderedStorage = NSMutableArray()
        let buffer = UnsafeBufferPointer(start: objects, count: cnt)
        for obj in buffer where storage.contains(obj) {
            orderedStorage.add(obj)
        }
        
        _orderedStorage = orderedStorage.copy() as! NSArray

        super.init()
    }
    
    required public convenience init(arrayLiteral elements: Any...) {
      self.init(array: elements)
    }

    public convenience init(objects elements: Any...) {
      self.init(array: elements)
    }
    
    internal init(storage: NSSet, orderedStorage: NSArray) {
        _storage = storage
        _orderedStorage = orderedStorage
    }
    
    open override func copy() -> Any {
        return copy(with: nil)
    }
    
    open func copy(with zone: NSZone? = nil) -> Any {
        if type(of: self) === NSOrderedSet.self {
            return self
        } else {
            return NSOrderedSet(storage: self.set as NSSet, orderedStorage: self.array as NSArray)
        }
    }

    open override func mutableCopy() -> Any {
        return mutableCopy(with: nil)
    }

    // 如果, 是 NSOrderedSet 或者, NSMutableOrderedSet, 那么直接的进行数据的赋值就可以了.
    // 如果, 是子类的类型, 那么根据外层表现出的序列的协议, 进行数据的收集.
    // 对于 Apple 的这种, 可变类型, 不可变类型的区分, 在设计类的时候, 要做好相互类型之间的转化.
    open func mutableCopy(with zone: NSZone? = nil) -> Any {
        if type(of: self) === NSOrderedSet.self || type(of: self) === NSMutableOrderedSet.self {
            let mutableOrderedSet = NSMutableOrderedSet()
            mutableOrderedSet._mutableStorage._storage = self._storage._storage
            mutableOrderedSet._storage = mutableOrderedSet._mutableStorage
            mutableOrderedSet._mutableOrderedStorage._storage = self._orderedStorage._storage
            mutableOrderedSet._orderedStorage = mutableOrderedSet._mutableOrderedStorage
            return mutableOrderedSet
        } else {
            let count = self.count
            let mutableSet = NSMutableSet(capacity: count)
            let mutableArray = NSMutableArray(capacity: count)

            for obj in self {
                mutableSet.add(obj)
                mutableArray.add(obj)
            }
            return NSMutableOrderedSet(mutableStorage: mutableSet, mutableOrderedStorage: mutableArray)
        }
    }
    
    public static var supportsSecureCoding: Bool {
        return true
    }
    
    open override func isEqual(_ object: Any?) -> Bool {
        guard let orderedSet = object as? NSOrderedSet else { return false }
        return isEqual(to: orderedSet)
    }
    
    open func encode(with aCoder: NSCoder) {
        guard aCoder.allowsKeyedCoding else {
            preconditionFailure("Unkeyed coding is unsupported.")
        }
        for idx in _indices {
            aCoder.encode(__SwiftValue.store(self.object(at: idx)), forKey:"NS.object.\(idx)")
        }
    }
    
    public required convenience init?(coder aDecoder: NSCoder) {
        // This uses the same storage setup as NSSet, but without allowing the use of the "NS.objects" key:
        self.init(array: NSSet._objects(from: aDecoder, allowDecodingNonindexedArrayKey: false))
    }
    
    open var count: Int {
        return _storage.count
    }

    // 返回值是 Any, 符合 OC 的 id.
    // 这个类, 并不是一个泛型类. 所以
    open func object(at idx: Int) -> Any {
        _validateSubscript(idx)
        return _orderedStorage.object(at: idx)
    }

    // 直接使用了 NSArray 的 api.
    open func index(of object: Any) -> Int {
        return _orderedStorage.index(of: object)
    }

    open subscript (idx: Int) -> Any {
        return object(at: idx)
    }
    
    internal var allObjects: [Any] {
        return _orderedStorage.allObjects
    }
    
    // 因为, 这个类表现出的是有序的集合, 所以 _indices 是用的 Range<Int>
    internal var _indices: Range<Int> {
        return 0..<count
    }
    
    // 所有的, 需要通过 index 操作的函数, 首先都要经过数据安全性的校验
    internal func _validateSubscript(_ index: Int, file: StaticString = #file, line: UInt = #line) {
        precondition(_indices.contains(index), "\(self): Index out of bounds", file: file, line: line)
    }

    // A collection of unique integer values that represent the indexes of elements in another collection.
    // IndexSet 就是 Int 组成的集合, 所以, 这里可以直接用到 Array 里面.
    // 这里, 直接使用了 map, 这就体现出了面向协议的好处在哪里.
    // 手动实现的逻辑, 就是 Map 里面的逻辑. Map 将这层进行封装, 然后将变化转移到了传入的 Block 里面
    // 在 OC 版本库里面, 各个容器类, 也都有自己的 map 的实现, 但是需要在自己的类中添加分类, 而在这里, 直接使用通用的, sequence 这层抽象上的 map 的定义就可以了.
    open func objects(at indexes: IndexSet) -> [Any] {
        return indexes.map { object(at: $0) }
    }

    public var firstObject: Any? {
        return _orderedStorage.firstObject
    }

    public var lastObject: Any? {
        return _orderedStorage.lastObject
    }

    open func isEqual(to other: NSOrderedSet) -> Bool {
        //  isEqual, 首先应该比较的是, 最明显的外层值.
        if count != other.count {
            return false
        }
        
        // 然后才应该是各个数据的比较.
        // 这里, 是用的 AnyHashable 的 == 进行的比较, 具体的实现细节, 要到 AnyHashable 的定义去理解.
        // 不太明白, as 这个语法可以随便用吗, 在类的设计的时候应该做什么样的适配才可以.
        for idx in _indices {
            if let value1 = object(at: idx) as? AnyHashable,
               let value2 = other.object(at: idx) as? AnyHashable {
                if value1 != value2 {
                    return false
                }
            }
        }
        
        return true
    }
    
    open func contains(_ object: Any) -> Bool {
        return _storage.contains(object)
    }

    // 这里, 很难理解, contains 应该是一个 sequence 的方法, 但是和上面的 open func contains(_ object: Any) -> Bool 粘合在了一起, 导致根本无法理解这里到底是什么样的一个调用的流程.
    open func intersects(_ other: NSOrderedSet) -> Bool {
        if count < other.count {
            return contains { obj in other.contains(obj) }
        } else {
            return other.contains { obj in contains(obj) }
        }
    }

    open func intersectsSet(_ set: Set<AnyHashable>) -> Bool {
        if count < set.count {
            return contains { obj in set.contains(obj) }
        } else {
            return set.contains { obj in contains(obj) }
        }
    }
    
    open func isSubset(of other: NSOrderedSet) -> Bool {
        // If self is larger then self cannot be a subset of other
        if count > other.count {
            return false
        }

        for item in self {
            if !other.contains(item) {
                return false
            }
        }
        return true
    }

    open func isSubset(of set: Set<AnyHashable>) -> Bool {
        // If self is larger then self cannot be a subset of set
        if count > set.count {
            return false
        }

        for item in self {
            if !set.contains(item as! AnyHashable) {
                return false
            }
        }
        return true
    }
    
    public func objectEnumerator() -> NSEnumerator {
        return _orderedStorage.objectEnumerator()
    }

    public func reverseObjectEnumerator() -> NSEnumerator {
        return _orderedStorage.reverseObjectEnumerator()
    }
    
    /*@NSCopying*/ 
    public var reversed: NSOrderedSet {
        return NSOrderedSet(array: _orderedStorage.reversed())
    }
    
    // These two methods return a facade object for the receiving ordered set,
    // which acts like an immutable array or set (respectively).  Note that
    // while you cannot mutate the ordered set through these facades, mutations
    // to the original ordered set will "show through" the facade and it will
    // appear to change spontaneously, since a copy of the ordered set is not
    // being made.
    public var array: [Any] {
        if type(of: self) === NSOrderedSet.self || type(of: self) === NSMutableOrderedSet.self {
            return _orderedStorage._swiftObject
        } else {
            var result: [Any] = []
            result.reserveCapacity(self.count)
            for obj in self {
                result.append(obj)
            }
            return result
        }
    }

    public var set: Set<AnyHashable> {
        if type(of: self) === NSOrderedSet.self || type(of: self) === NSMutableOrderedSet.self {
            return _storage._swiftObject
        } else {
            var result: Set<AnyHashable> = []
            result.reserveCapacity(self.count)
            for obj in self {
                result.insert(obj as! AnyHashable)
            }
            return result
        }
    }
    
    open func enumerateObjects(_ block: (Any, Int, UnsafeMutablePointer<ObjCBool>) -> Swift.Void) {
        _orderedStorage.enumerateObjects(block)
    }
    
    open func enumerateObjects(options opts: NSEnumerationOptions = [], using block: (Any, Int, UnsafeMutablePointer<ObjCBool>) -> Swift.Void) {
        enumerateObjects(at: IndexSet(0..<count), options: opts, using: block)
    }
    
    open func enumerateObjects(at s: IndexSet, options opts: NSEnumerationOptions = [], using block: (Any, Int, UnsafeMutablePointer<ObjCBool>) -> Swift.Void) {
        _orderedStorage.enumerateObjects(options: opts, using: block)
    }
    
    open func index(ofObjectPassingTest predicate: (Any, Int, UnsafeMutablePointer<ObjCBool>) -> Bool) -> Int {
        return index([], ofObjectPassingTest: predicate)
    }
    
    open func index(_ opts: NSEnumerationOptions = [], ofObjectPassingTest predicate: (Any, Int, UnsafeMutablePointer<ObjCBool>) -> Bool) -> Int {
        return index(ofObjectAt: IndexSet(0..<count), options: [], passingTest: predicate)
    }
    
    open func index(ofObjectAt s: IndexSet, options opts: NSEnumerationOptions = [], passingTest predicate: (Any, Int, UnsafeMutablePointer<ObjCBool>) -> Bool) -> Int {
        return _orderedStorage.indexOfObject(at: s, options: opts, passingTest: predicate)
    }
    
    open func indexes(ofObjectsPassingTest predicate: (Any, Int, UnsafeMutablePointer<ObjCBool>) -> Bool) -> IndexSet {
        return indexes(ofObjectsAt: IndexSet(0..<count), options: [], passingTest: predicate)
    }
    
    open func indexes(options opts: NSEnumerationOptions = [], ofObjectsPassingTest predicate: (Any, Int, UnsafeMutablePointer<ObjCBool>) -> Bool) -> IndexSet {
        return indexes(ofObjectsAt: IndexSet(0..<count), options: opts, passingTest: predicate)
    }
    
    open func indexes(ofObjectsAt s: IndexSet, options opts: NSEnumerationOptions = [], passingTest predicate: (Any, Int, UnsafeMutablePointer<ObjCBool>) -> Bool) -> IndexSet {
        return _orderedStorage.indexesOfObjects(at: s, options: opts, passingTest: predicate)
    }

     // binary search
    open func index(of object: Any, inSortedRange range: NSRange, options opts: NSBinarySearchingOptions = [], usingComparator cmp: (Any, Any) -> ComparisonResult) -> Int {
        return _orderedStorage.index(of:object, inSortedRange: range, options: opts, usingComparator: cmp)
    }
    
    open func sortedArray(comparator cmptr: (Any, Any) -> ComparisonResult) -> [Any] {
        return sortedArray(options: [], usingComparator: cmptr)
    }
    
    open func sortedArray(options opts: NSSortOptions = [], usingComparator cmptr: (Any, Any) -> ComparisonResult) -> [Any] {
        return _orderedStorage.sortedArray(options: opts, usingComparator: cmptr)
    }

    override open var description: String {
        return description(withLocale: nil)
    }

    public func description(withLocale locale: Locale?) -> String {
        return description(withLocale: locale, indent: 0)
    }

    public func description(withLocale locale: Locale?, indent level: Int) -> String {
        return _orderedStorage.description(withLocale: locale, indent: level)
    }
    
    public convenience init(object: Any) {
        self.init(array: [object])
    }
    
    public convenience init(orderedSet set: NSOrderedSet) {
        self.init(orderedSet: set, copyItems: false)
    }

    public convenience init(orderedSet set: NSOrderedSet, copyItems flag: Bool) {
        self.init(orderedSet: set, range: NSRange(location: 0, length: set.count), copyItems: flag)
    }

    public convenience init(orderedSet set: NSOrderedSet, range: NSRange, copyItems flag: Bool) {
        // TODO: Use the array method here when available.
        self.init(array: Array(set), range: range, copyItems: flag)
    }

    public convenience init(array: [Any]) {
        let buffer = UnsafeMutablePointer<AnyObject>.allocate(capacity: array.count)
        for (idx, element) in array.enumerated() {
            buffer.advanced(by: idx).initialize(to: __SwiftValue.store(element))
        }
        self.init(objects: buffer, count: array.count)
        buffer.deinitialize(count: array.count)
        buffer.deallocate()
    }

    public convenience init(array set: [Any], copyItems flag: Bool) {
        self.init(array: set, range: NSRange(location: 0, length: set.count), copyItems: flag)
    }
    
    public convenience init(array set: [Any], range: NSRange, copyItems flag: Bool) {
        var objects = set

        if let range = Range(range), range.count != set.count || flag {
            objects = [Any]()
            for index in range.indices {
                let object = set[index]
                objects.append(flag ? (object as! NSObject).copy() : object)
            }
        }

        self.init(array: objects)
    }

    public convenience init(set: Set<AnyHashable>) {
        self.init(set: set, copyItems: false)
    }

    public convenience init(set: Set<AnyHashable>, copyItems flag: Bool) {
        self.init(array: Array(set), copyItems: flag)
    }
    
    open func sortedArray(using sortDescriptors: [NSSortDescriptor]) -> [Any] {
        return self.array._nsObject.sortedArray(using: sortDescriptors)
    }
}


open class NSMutableOrderedSet: NSOrderedSet {
    
    fileprivate var _mutableStorage: NSMutableSet
    fileprivate var _mutableOrderedStorage: NSMutableArray
    
    // C 风格的函数.
    public override init(objects: UnsafePointer<AnyObject>?, count cnt: Int) {
        let storage = NSMutableSet(objects: objects, count: cnt)
        _mutableStorage = storage
        
        let orderedStorage = NSMutableArray()
        let buffer = UnsafeBufferPointer(start: objects, count: cnt)
        for obj in buffer where storage.contains(obj) {
            orderedStorage.add(obj)
        }
        
        _mutableOrderedStorage = orderedStorage
        
        super.init(storage: storage, orderedStorage: orderedStorage)
    }
    
    fileprivate init(mutableStorage: NSMutableSet, mutableOrderedStorage: NSMutableArray) {
        _mutableStorage = mutableStorage
        _mutableOrderedStorage = mutableOrderedStorage
        super.init(objects: [], count: 0)
        _storage = _mutableStorage
        _orderedStorage = _mutableOrderedStorage
    }
    
    public init(capacity numItems: Int) {
        _mutableStorage = NSMutableSet(capacity: numItems)
        _mutableOrderedStorage = NSMutableArray(capacity: numItems)
        
        super.init(objects: [], count: 0)
        
        // 关键所在, 让父类里面的元素, 指向 mutable 的部分.
        // 对于 不可变类型来说, 所有的操作, 只会使用 不可变 set, array 里面的 api. 而 可变类型是不可变类型的子类, 可以进行替换.
        _storage = _mutableStorage
        _orderedStorage = _mutableOrderedStorage
    }

    required public convenience init(arrayLiteral elements: Any...) {
        self.init(capacity: 0)

        addObjects(from: elements)
    }


    public required convenience init?(coder aDecoder: NSCoder) {
        // See NSOrderedSet.init?(coder:)
        self.init(array: NSSet._objects(from: aDecoder, allowDecodingNonindexedArrayKey: false))
    }
    
    open func insert(_ object: Any, at idx: Int) {
        precondition(idx <= count && idx >= 0, "\(self): Index out of bounds")

        if contains(object) {
            return
        }
        
        _mutableStorage.add(object)
        _mutableOrderedStorage.insert(object, at: idx)
    }

    open func removeObject(at idx: Int) {
        _validateSubscript(idx)
        _mutableStorage.remove(_orderedStorage[idx])
        _mutableOrderedStorage.removeObject(at: idx)
    }

    open func replaceObject(at idx: Int, with obj: Any) {
        let objectToReplace = object(at: idx)
        _mutableStorage.remove(objectToReplace)
        _mutableStorage.add(obj)
        _mutableOrderedStorage.replaceObject(at: idx, with: obj)
    }

    open override func copy(with zone: NSZone? = nil) -> Any {
        if type(of: self) === NSMutableOrderedSet.self {
            let orderedSet = NSOrderedSet()
            orderedSet._storage._storage = self._storage._storage
            orderedSet._orderedStorage._storage = self._orderedStorage._storage
            return orderedSet
        } else {
            return NSMutableOrderedSet(mutableStorage: NSMutableSet(set: self.set), mutableOrderedStorage: NSMutableArray(array: self.array))
        }
    }

    fileprivate func _removeObject(_ object: Any) {
        guard contains(object) else {
            return
        }
        _mutableStorage.remove(object)
        _mutableOrderedStorage.remove(object)
    }
    
    fileprivate func _insertObject(_ object: Any) {
        if contains(object) {
            return
        }
        
        _mutableStorage.add(object)
        _mutableOrderedStorage.add(object)
    }

    open override subscript(idx: Int) -> Any {
        get {
            return object(at: idx)
        }
        set {
            replaceObject(at: idx, with: newValue)
        }
    }

    open func add(_ object: Any) {
        _insertObject(object)
    }

    open func add(_ objects: UnsafePointer<AnyObject>?, count: Int) {
        let buffer = UnsafeBufferPointer(start: objects, count: count)
        for obj in buffer {
            _insertObject(obj)
        }
    }

    open func addObjects(from array: [Any]) {
        for object in array {
            _insertObject(object)
        }
    }
    
    open func exchangeObject(at idx1: Int, withObjectAt idx2: Int) {
        _mutableOrderedStorage.exchangeObject(at: idx1, withObjectAt: idx2)
    }

    open func moveObjects(at indexes: IndexSet, to idx: Int) {
        var removedObjects = [Any]()
        for index in indexes.lazy.reversed() {
            let obj = object(at: index)
            removedObjects.append(obj)
            removeObject(at: index)
            
        }
        for removedObject in removedObjects {
            insert(removedObject, at: idx)
        }
    }
    
    open func insert(_ objects: [Any], at indexes: IndexSet) {
        for (indexLocation, index) in indexes.enumerated() {
            let object = objects[indexLocation]
            insert(object, at: index)
        }
    }
    
    /// Sets the object at the specified index of the mutable ordered set.
    ///
    /// - Parameters:
    ///   - obj: The object to be set.
    ///   - idx: The index. If the index is equal to `count`, then it appends
    ///   the object. Otherwise it replaces the object at the index with the
    ///   given object.
    open func setObject(_ obj: Any, at idx: Int) {
        if idx == count {
            insert(obj, at: idx)
        } else {
            replaceObject(at: idx, with: obj)
        }
    }
    
    open func replaceObjects(in range: NSRange, with objects: UnsafePointer<AnyObject>!, count: Int) {
        if let range = Range(range) {
            let buffer = UnsafeBufferPointer(start: objects, count: count)
            for (indexLocation, index) in range.indices.lazy.reversed().enumerated() {
                let object = buffer[indexLocation]
                replaceObject(at: index, with: object)
            }
        }
    }

    open func replaceObjects(at indexes: IndexSet, with objects: [Any]) {
        for (indexLocation, index) in indexes.enumerated() {
            let object = objects[indexLocation]
            replaceObject(at: index, with: object)
        }
    }
    
    open func removeObjects(in range: NSRange) {
        if let range = Range(range) {
            for index in range.indices.lazy.reversed() {
                removeObject(at: index)
            }
        }
    }

    open func removeObjects(at indexes: IndexSet) {
        for index in indexes.lazy.reversed() {
            removeObject(at: index)
        }
    }

    open func removeAllObjects() {
        _mutableStorage.removeAllObjects()
        _mutableOrderedStorage.removeAllObjects()
    }
    
    open func remove(_ val: Any) {
        _mutableStorage.remove(val)
        _mutableOrderedStorage.remove(val)
    }

    open func removeObjects(in array: [Any]) {
        array.forEach(remove)
    }
    
    open func intersect(_ other: NSOrderedSet) {
        var i = 0
        while i < _mutableOrderedStorage.count {
            let currentObject = _mutableOrderedStorage[i] as! AnyHashable
            if !other.contains(currentObject) {
                let nextIndex = i + 1
                if nextIndex < count {
                    _mutableOrderedStorage[i] = _mutableOrderedStorage[nextIndex]
                }
                _mutableStorage.remove(currentObject)
            } else {
                i += 1
            }
        }
        while _mutableOrderedStorage.count > count {
            _mutableOrderedStorage.removeLastObject()
        }
    }

    open func minus(_ other: NSOrderedSet) {
        for item in other where contains(item) {
            remove(item)
        }
    }

    open func union(_ other: NSOrderedSet) {
        other.forEach(add)
    }
    
    open func intersectSet(_ other: Set<AnyHashable>) {
        let objects = Array(self)
        for case let item as AnyHashable in objects where !other.contains(item) {
            remove(item)
        }
    }

    open func minusSet(_ other: Set<AnyHashable>) {
        for item in other where contains(item) {
            remove(item)
        }
    }

    open func unionSet(_ other: Set<AnyHashable>) {
        other.forEach(add)
    }
    
    open func sort(comparator cmptr: (Any, Any) -> ComparisonResult) {
        sortRange(NSRange(location: 0, length: count), options: [], usingComparator: cmptr)
    }

    open func sort(options opts: NSSortOptions = [], usingComparator cmptr: (Any, Any) -> ComparisonResult) {
        sortRange(NSRange(location: 0, length: count), options: opts, usingComparator: cmptr)
    }

    open func sortRange(_ range: NSRange, options opts: NSSortOptions = [], usingComparator cmptr: (Any, Any) -> ComparisonResult) {
        let sortedSubrange = _mutableOrderedStorage.sortedArray(from: range, options: opts, usingComparator: cmptr)
        _mutableOrderedStorage.replaceObjects(in: range, withObjectsFrom: sortedSubrange)
    }
    
    open func sort(using sortDescriptors: [NSSortDescriptor]) {
        _mutableOrderedStorage.sort(using: sortDescriptors)
    }
    
    // MARK: Convenience initializers that are automatically inherited in ObjC, but not in Swift:
    
    public convenience init() {
        self.init(objects: [], count: 0)
    }
    
    public convenience init(object: Any) {
        self.init(array: [object])
    }
    
    public convenience init(orderedSet set: NSOrderedSet) {
        self.init(orderedSet: set, copyItems: false)
    }
    
    public convenience init(orderedSet set: NSOrderedSet, copyItems flag: Bool) {
        self.init(orderedSet: set, range: NSRange(location: 0, length: set.count), copyItems: flag)
    }
    
    public convenience init(orderedSet set: NSOrderedSet, range: NSRange, copyItems flag: Bool) {
        // TODO: Use the array method here when available.
        self.init(array: Array(set), range: range, copyItems: flag)
    }
    
    public convenience init(array: [Any]) {
        let buffer = UnsafeMutablePointer<AnyObject>.allocate(capacity: array.count)
        for (idx, element) in array.enumerated() {
            buffer.advanced(by: idx).initialize(to: __SwiftValue.store(element))
        }
        self.init(objects: buffer, count: array.count)
        buffer.deinitialize(count: array.count)
        buffer.deallocate()
    }
    
    public convenience init(array set: [Any], copyItems flag: Bool) {
        self.init(array: set, range: NSRange(location: 0, length: set.count), copyItems: flag)
    }
    
    public convenience init(array set: [Any], range: NSRange, copyItems flag: Bool) {
        var objects = set
        
        if let range = Range(range), range.count != set.count || flag {
            objects = [Any]()
            for index in range.indices {
                let object = set[index]
                objects.append(flag ? (object as! NSObject).copy() : object)
            }
        }
        
        self.init(array: objects)
    }
    
    public convenience init(set: Set<AnyHashable>) {
        self.init(set: set, copyItems: false)
    }
    
    public convenience init(set: Set<AnyHashable>, copyItems flag: Bool) {
        self.init(array: Array(set), copyItems: flag)
    }
    
    public convenience init(objects elements: Any...) {
        self.init(array: elements)
    }
}


extension NSOrderedSet: Sequence {

    public typealias Iterator = NSEnumerator.Iterator

    /// Return a *generator* over the elements of this *sequence*.
    ///
    /// - Complexity: O(1).
    public func makeIterator() -> Iterator {
        return self.objectEnumerator().makeIterator()
    }
}


extension NSOrderedSet: CustomReflectable {
    public var customMirror: Mirror {
        return Mirror(reflecting: _orderedStorage as Array)
    }
}
