@_implementationOnly import CoreFoundation

#if canImport(ObjectiveC)
import ObjectiveC
#endif

// OC 类型实现, 可以将自己转化成为 Swift 的类型.
public protocol _StructBridgeable {
    func _bridgeToAny() -> Any
}

fileprivate protocol Unwrappable {
    func unwrap() -> Any?
}

extension Optional: Unwrappable {
    func unwrap() -> Any? {
        return self
    }
}

/// - Note: This does not exist currently on Darwin but it is the inverse correlation to the bridge types such that a 
/// reference type can be converted via a callout to a conversion method.
public protocol _StructTypeBridgeable : _StructBridgeable {
    associatedtype _StructType
    
    func _bridgeToSwift() -> _StructType
}

// Default adoption of the type specific variants to the Any variant
extension _ObjectiveCBridgeable {
    public func _bridgeToAnyObject() -> AnyObject {
        return _bridgeToObjectiveC()
    }
}

extension _StructTypeBridgeable {
    public func _bridgeToAny() -> Any {
        return _bridgeToSwift()
    }
}

// slated for removal, these are the swift-corelibs-only variant of the _ObjectiveCBridgeable

internal protocol _SwiftBridgeable {
    associatedtype SwiftType
    var _swiftObject: SwiftType { get }
}

internal protocol _NSBridgeable {
    associatedtype NSType
    var _nsObject: NSType { get }
}


#if !canImport(ObjectiveC)
// The _NSSwiftValue protocol is in the stdlib, and only available on platforms without ObjC.
extension __SwiftValue: _NSSwiftValue {}
#endif


// 这个类, 专门用于 OC 到 Swfit, 或者相反的桥接转换工作.
internal final class __SwiftValue : NSObject, NSCopying {
    public private(set) var value: Any
    
    static func fetch(_ object: AnyObject?) -> Any? {
        if let obj = object {
            let value = fetch(nonOptional: obj)
            if let wrapper = value as? Unwrappable, wrapper.unwrap() == nil {
                return nil
            } else {
                return value
            }
        }
        return nil
    }
    
    #if canImport(ObjectiveC)
    private static var _objCNSNullClassStorage: Any.Type?
    private static var objCNSNullClass: Any.Type? {
        if let type = _objCNSNullClassStorage {
            return type
        }
        
        let name = "NSNull"
        let maybeType = name.withCString { cString in
            return objc_getClass(cString)
        }
        
        if let type = maybeType as? Any.Type {
            _objCNSNullClassStorage = type
            return type
        } else {
            return nil
        }
    }
    
    private static var _swiftStdlibSwiftValueClassStorage: Any.Type?
    private static var swiftStdlibSwiftValueClass: Any.Type? {
        if let type = _swiftStdlibSwiftValueClassStorage {
            return type
        }
        
        let name = "__SwiftValue"
        let maybeType = name.withCString { cString in
            return objc_getClass(cString)
        }
        
        if let type = maybeType as? Any.Type {
            _swiftStdlibSwiftValueClassStorage = type
            return type
        } else {
            return nil
        }
    }
    
    #endif
    
    // 在这个函数里面, 会根据引用对象的特征, 返回相应的 swift 数据.
    static func fetch(nonOptional object: AnyObject) -> Any {
        #if canImport(ObjectiveC)
        // You can pass the result of a `as AnyObject` expression to this method. This can have one of three results on Darwin:
        // - It's a SwiftFoundation type. Bridging will take care of it below.
        // - It's nil. The compiler is hardcoded to return [NSNull null] for nils.
        // - It's some other Swift type. The compiler will box it in a native __SwiftValue.
        // Case 1 is handled below.
        // Case 2 is handled here:
        if type(of: object as Any) == objCNSNullClass {
            return Optional<Any>.none as Any
        }
        // Case 3 is handled here:
        if type(of: object as Any) == swiftStdlibSwiftValueClass {
            return object
            // Since this returns Any, the object is casted almost immediately — e.g.:
            //   __SwiftValue.fetch(x) as SomeStruct
            // which will immediately unbox the native box. For callers, it will be exactly
            // as if we returned the unboxed value directly.
        }
        
        // On Linux, case 2 is handled by the stdlib bridging machinery, and case 3 can't happen —
        // the compiler will produce SwiftFoundation.__SwiftValue boxes rather than ObjC ones.
        #endif
        
        // 直接, 指针判断
        if object === kCFBooleanTrue {
            return true
            // 直接指针判断.
        } else if object === kCFBooleanFalse {
            return false
            // 如果, obj 是包装类, 那么直接取出他包装的数据.
        } else if let container = object as? __SwiftValue {
            return container.value
            // 如果, 这个对象实现了 _StructBridgeable 协议, 那么调用它的 _bridgeToAny 算法.
        } else if let val = object as? _StructBridgeable {
            return val._bridgeToAny()
        } else {
            return object
        }
    }
    
    static func store(optional value: Any?) -> NSObject? {
        if let val = value {
            return store(val)
        }
        return nil
    }
    
    static func store(_ value: Any?) -> NSObject? {
        if let val = value {
            return store(val)
        }
        return nil
    }
    
    static func store(_ value: Any) -> NSObject {
        if let val = value as? NSObject {
            // 如果, 本身就是 NSObject 的子类, 那么直接返回
            return val
        } else if let opt = value as? Unwrappable, opt.unwrap() == nil {
            // 这里没有看明白. 反正, 能够叫 nil 传递过去.
            return NSNull()
        } else {
            let boxed = (value as AnyObject)
            if boxed is NSObject {
                return boxed as! NSObject
            } else {
                // 简单的理解一下, 就是找一个盒子, 这个盒子本身是 NSObject 的子类, 然后盒子里面的数据, 是原来的 value.
                return __SwiftValue(value) // Do not emit native boxes — wrap them in Swift Foundation boxes
        }
    }
    
    init(_ value: Any) {
        self.value = value
    }
    
    override var hash: Int {
        if let hashable = value as? AnyHashable {
            return hashable.hashValue
        }
        return ObjectIdentifier(self).hashValue
    }
    
    override func isEqual(_ value: Any?) -> Bool {
        switch value {
        case let other as __SwiftValue:
            guard let left = other.value as? AnyHashable,
                let right = self.value as? AnyHashable else { return self === other }
            
            return left == right
        case let other as AnyHashable:
            guard let hashable = self.value as? AnyHashable else { return false }
            return other == hashable
        default:
            return false
        }
    }
    
    public func copy(with zone: NSZone?) -> Any {
        return __SwiftValue(value)
    }
    
    public static let null: AnyObject = NSNull()

    override var description: String { String(describing: value) }
}
