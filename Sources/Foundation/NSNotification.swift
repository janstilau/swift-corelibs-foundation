open class NSNotification: NSObject, NSCopying, NSCoding {
    public struct Name : RawRepresentable, Equatable, Hashable {
        // RawRepresentable
        // A type that can be converted to and from an associated raw value.
        // With a RawRepresentable type, you can switch back and forth between a custom type and an associated RawValue type without losing the value of the original RawRepresentable type.
        // 重构里面, 提倡用类型代替原始数据, RawRepresentable 可以认为是对于这个原则的体现.
        public private(set) var rawValue: String

        public init(_ rawValue: String) {
            self.rawValue = rawValue
        }

        public init(rawValue: String) {
            self.rawValue = rawValue
        }
    }

    private(set) open var name: Name
    
    private(set) open var object: Any? // 发出者. 可以没有.
    
    private(set) open var userInfo: [AnyHashable : Any]? // 通知的附带信息, 可以没有.
    
    public convenience override init() {
        /* do not invoke; not a valid initializer for this class */
        fatalError() // NSObject 的不让调用, 必须调用传参过来的初始化方法.
    }
    
    public init(name: Name, object: Any?, userInfo: [AnyHashable : Any]? = nil) {
        self.name = name
        self.object = object
        self.userInfo = userInfo
    }
    
    public convenience required init?(coder aDecoder: NSCoder) {
        guard aDecoder.allowsKeyedCoding else {
            preconditionFailure("Unkeyed coding is unsupported.")
        }
        // 必须要有名字.
        guard let name = aDecoder.decodeObject(of: NSString.self, forKey:"NS.name") else {
            return nil
        }
        let object = aDecoder.decodeObject(forKey: "NS.object")
        self.init(name: Name(rawValue: String._unconditionallyBridgeFromObjectiveC(name)), object: object as! NSObject, userInfo: nil)
    }
    
    open func encode(with aCoder: NSCoder) {
        guard aCoder.allowsKeyedCoding else {
            preconditionFailure("Unkeyed coding is unsupported.")
        }
        aCoder.encode(self.name.rawValue._bridgeToObjectiveC(), forKey:"NS.name")
        aCoder.encode(self.object, forKey:"NS.object")
        aCoder.encode(self.userInfo?._bridgeToObjectiveC(), forKey:"NS.userinfo")
    }
    
    open override func copy() -> Any {
        return copy(with: nil)
    }
    
    open func copy(with zone: NSZone? = nil) -> Any {
        return self
    }
    
    open override var description: String {
        var str = "\(type(of: self)) \(Unmanaged.passUnretained(self).toOpaque()) {"
        
        str += "name = \(self.name.rawValue)"
        if let object = self.object {
            str += "; object = \(object)"
        }
        if let userInfo = self.userInfo {
            str += "; userInfo = \(userInfo)"
        }
        str += "}"
        
        return str
    }
}

// 内部类, 都是 private 的.
private class NSNotificationReceiver : NSObject {
    fileprivate var name: Notification.Name?
    fileprivate var block: ((Notification) -> Void)?
    fileprivate var sender: AnyObject?
    fileprivate var queue: OperationQueue?
}

private let _defaultCenter: NotificationCenter = NotificationCenter()

// 这里的实现, 要简单一些, 就是一个 hash 算法.
// 这个类, 把 target action 的方式移除了.  所以, receiver, 就是一个 block 了.
open class NotificationCenter: NSObject {
    private lazy var _nilIdentifier: ObjectIdentifier = ObjectIdentifier(_observersLock)
    private lazy var _nilHashable: AnyHashable = AnyHashable(_nilIdentifier)
    
    // 第一层, name 作为 key. 对应一个字典
    // 第二层, sender 作为 key, 如果不关注 sender, 找了一个默认的假的 sender.
    // 第三层, receiver 自己作为 key, value 也是自己, 感觉这里使用数组不更好理解一点.
    // 按照这里的设计, NSNotification 里面, 其实是有着, 可以不关心名字, 但是关心 sender 这种设计的.
    private var _observers: [AnyHashable /* Notification.Name */ : [ObjectIdentifier /* object */ : [ObjectIdentifier /* notification receiver */ : NSNotificationReceiver]]]
    private let _observersLock = NSLock()
    
    public required override init() {
        // 所有的 key, 都没有使用具体的类型, 仅仅是建立在 hash, 指针 的基础上的.
        // 也让这个类, 很难理解.
        _observers = [AnyHashable: [ObjectIdentifier: [ObjectIdentifier: NSNotificationReceiver]]]()
    }
    
    // 这里, 也可以使用文件类的遍历, 然后 static 方法, 操作这个变量的方式
    open class var `default`: NotificationCenter {
        return _defaultCenter
    }
    
    open func post(_ notification: Notification) {
        let notificationNameIdentifier: AnyHashable = AnyHashable(notification.name)
        let senderIdentifier: ObjectIdentifier? = notification.object.map({ ObjectIdentifier(__SwiftValue.store($0)) })
        

        // 这里是 Values, 不是 value.
        // 之所以, 选用 map, 是因为会有重合. 一个 receiver, 什么都不关心, 和只关心 name, sender. 都会被触发.
        let sendTo: [Dictionary<ObjectIdentifier, NSNotificationReceiver>.Values] = _observersLock.synchronized({
            var retVal = [Dictionary<ObjectIdentifier, NSNotificationReceiver>.Values]()
            
            // 所有, 不关心 name 的, 也不关心 sender 的, 填充到 retVal 里面去.
            // 这里, map 是对 optinal 而言的, 所以, $0 是 values, 而不是一个个 value.
            (_observers[_nilHashable]?[_nilIdentifier]?.values).map({ retVal.append($0) })
            
            // 如果, senderIdentifier 有值的话.
            // 所有不关心 name 的, 但是关心 sender 的, 填充到 retVal 里面, 这里还是应该用 forEach.
            // flatMap 本身, 返回的是 optinal, 所以, 这里的 map 也是 optinal 的
            // 这里, flatmap 的参数, 是一定是非空的, 但是, _observers[_nilHashable] 本身就可能是空的.
            // 所以, map 后面, 填入的 $0 还是 values 集合, 而不是 value.
            senderIdentifier.flatMap({ _observers[_nilHashable]?[$0]?.values }).map({ retVal.append($0) })
            // 所有, 关心名字的, 但是不关心 sender 的, 填充到 retVal 里面.
            // 这里不用看, optianl chains 的, map 必然是 optinal 的, 所以 retVal 填入的, 还是 values.
            (_observers[notificationNameIdentifier]?[_nilIdentifier]?.values).map({ retVal.append($0) })
            // 如果 sender 不为空
            // 所有, 关心名字的, 关心 sender 的, 填充到 retVal 里面.
            senderIdentifier.flatMap({ _observers[notificationNameIdentifier]?[$0]?.values}).map({ retVal.append($0) })
            
            return retVal
        })

        // sendto 是集合的集合.
        sendTo.forEach { observers in
            // 集合的遍历.
            observers.forEach { observer in
                guard let block = observer.block else {
                    return
                }
                // queue, 是最基础的业务的数据, 一点不影响整个控制逻辑. 所以, 只在最最后面, 真正需要做业务的时候, 才把他取出来进行调用.
                if let queue = observer.queue, queue != OperationQueue.current {
                    queue.addOperation { block(notification) }
                    queue.waitUntilAllOperationsAreFinished()
                } else {
                    block(notification)
                }
            }
        }
    }

    open func post(name aName: NSNotification.Name, object anObject: Any?, userInfo aUserInfo: [AnyHashable : Any]? = nil) {
        let notification = Notification(name: aName, object: anObject, userInfo: aUserInfo)
        post(notification)
    }

    open func removeObserver(_ observer: Any) {
        removeObserver(observer, name: nil, object: nil)
    }

    open func removeObserver(_ observer: Any, name aName: NSNotification.Name?, object: Any?) {
        guard let observer = observer as? NSNotificationReceiver,
            // These 2 parameters would only be useful for removing notifications added by `addObserver:selector:name:object:`
            aName == nil || observer.name == aName,
            object == nil || observer.sender === __SwiftValue.store(object)
        else {
            return
        }

        let notificationNameIdentifier: AnyHashable = observer.name.map { AnyHashable($0) } ?? _nilHashable
        let senderIdentifier: ObjectIdentifier = observer.sender.map { ObjectIdentifier($0) } ?? _nilIdentifier
        let receiverIdentifier: ObjectIdentifier = ObjectIdentifier(observer)
        
        _observersLock.synchronized({
            _observers[notificationNameIdentifier]?[senderIdentifier]?.removeValue(forKey: receiverIdentifier)
            if _observers[notificationNameIdentifier]?[senderIdentifier]?.count == 0 {
                _observers[notificationNameIdentifier]?.removeValue(forKey: senderIdentifier)
            }
        })
    }

    @available(*, unavailable, renamed: "addObserver(forName:object:queue:using:)")
    open func addObserver(forName name: NSNotification.Name?, object obj: Any?, queue: OperationQueue?, usingBlock block: @escaping (Notification) -> Void) -> NSObjectProtocol {
        return addObserver(forName: name, object: obj, queue: queue, using: block)
    }

    // name 可以是 nil 的??? 
    open func addObserver(forName name: NSNotification.Name?,
                          object obj: Any?,
                          queue: OperationQueue?,
                          using block: @escaping (Notification) -> Void) -> NSObjectProtocol {
        let newObserver = NSNotificationReceiver()
        newObserver.name = name
        newObserver.block = block
        newObserver.sender = __SwiftValue.store(obj)
        newObserver.queue = queue
        
        // 如果没名, 就存到一个默认的地方了.
        let notificationNameIdentifier: AnyHashable = name.map({ AnyHashable($0) }) ?? _nilHashable
        // 如果没有 sender, 也存到一个默认的地方了.
        let senderIdentifier: ObjectIdentifier = newObserver.sender.map({ ObjectIdentifier($0) }) ?? _nilIdentifier
        let receiverIdentifier: ObjectIdentifier = ObjectIdentifier(newObserver)

        // Accesses the value with the given key. If the dictionary doesn’t contain the given key, accesses the provided default value as if the key and default value existed in the dictionary.
        _observersLock.synchronized({
            // 这里有点不太明白, 为什么会自动填充呢, 值语义就自动填充了
            _observers[notificationNameIdentifier, default: [:]][senderIdentifier, default: [:]][receiverIdentifier] = newObserver
        })
        
        return newObserver
    }

}
