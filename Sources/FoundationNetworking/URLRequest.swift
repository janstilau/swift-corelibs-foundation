#if os(macOS) || os(iOS) || os(watchOS) || os(tvOS)
import SwiftFoundation
#else
import Foundation
#endif

// ReferenceConvertible
// A decoration applied to types that are backed by a Foundation reference type.
// AssociateType ReferenceType
/*
 这样的一个协议, 标明的是, 实际的成员变量, 是一个 Foundation 的 NSObject 对象.
 一般来说, 是 struct 来完成这个协议.
 这个协议, 没有任何的方法定义, 但是更好的表现出了 struct 的内在组成
 */

public struct URLRequest : ReferenceConvertible, Equatable, Hashable {
    
    public typealias ReferenceType = NSURLRequest
    public typealias CachePolicy = NSURLRequest.CachePolicy
    public typealias NetworkServiceType = NSURLRequest.NetworkServiceType
    
    // 这里没有初始化. 所以 init 方法里面, 要初始化.
    internal var _handle: _MutableHandle<NSMutableURLRequest>
    
    // 所有的 set 方法, 都会使用该函数.
    // 将真正的 set 操作, 包装一层.
    /* 这里, 其实是让 handle 和 里面的 pointer 保持一对一的关系.
        在复制 URLRequest 的时候, 其实是复制的 _handle 的值, 也就是 _handle 的引用.
        如果, _handle 不是 uniqueRef 的, 那么它里面的 request 也就是不是 uniqueRef 的.
        因为在初始化 _handle 的时候, 会对相应的 NSMutableRequest 做 Copy 动作, 保证, _handle 里面的 URLRequest 是一份独立的数据.
    */
    internal mutating func _applyMutation<ReturnType>(_ whatToDo : (NSMutableURLRequest) -> ReturnType) -> ReturnType {
        if !isKnownUniquelyReferenced(&_handle) {
            let ref = _handle._uncopiedReference()
            _handle = _MutableHandle(reference: ref)
        }
        return whatToDo(_handle._uncopiedReference())
    }
    
    // 新生成一个单独的 NSMutableURLRequest, 然后构造出 _handle 来.
    public init(url: URL, cachePolicy: CachePolicy = .useProtocolCachePolicy, timeoutInterval: TimeInterval = 60.0) {
        _handle = _MutableHandle(adoptingReference:
                                    NSMutableURLRequest(url: url, cachePolicy: cachePolicy, timeoutInterval: timeoutInterval))
    }
    
    // _bridged request 这种 init 函数, 应该就是系统桥接的时候, 调用的 init 函数.
    // 所以, 桥接, 实际上就是利用一种 Type 值, copy 出对应版本的另外一种 Type 值. 并不是免费的.
    fileprivate init(_bridged request: NSURLRequest) {
        _handle = _MutableHandle(reference: request.mutableCopy() as! NSMutableURLRequest)
    }
    
    /*
        所有的 get, 都是从 _handle 里面, 取到 NSMutableRequest 的相应值.
        Swfit 里面, 根据闭包值, 来确定函数的返回值, 让函数的作用性大大提高了. 用 OC, 或者 C++, 必须写大量的代理方法.
        所有的 set, 都包装在 _applyMutation 里面, 使得 _handle 和它管理的内部 _pointer, 是 uniqueRef 的.
     */
    
    public var url: URL? {
        get {
            return _handle.map { $0.url }
        }
        set {
            _applyMutation { $0.url = newValue }
        }
    }
    
    public var cachePolicy: CachePolicy {
        get {
            return _handle.map { $0.cachePolicy }
        }
        set {
            _applyMutation { $0.cachePolicy = newValue }
        }
    }

    internal var isTimeoutIntervalSet = false
    
    public var timeoutInterval: TimeInterval {
        get {
            return _handle.map { $0.timeoutInterval }
        }
        set {
            _applyMutation { $0.timeoutInterval = newValue }
            isTimeoutIntervalSet = true
        }
    }
    
    public var mainDocumentURL: URL? {
        get {
            return _handle.map { $0.mainDocumentURL }
        }
        set {
            _applyMutation { $0.mainDocumentURL = newValue }
        }
    }
    
    public var networkServiceType: NetworkServiceType {
        get {
            return _handle.map { $0.networkServiceType }
        }
        set {
            _applyMutation { $0.networkServiceType = newValue }
        }
    }
    
    public var allowsCellularAccess: Bool {
        get {
            return _handle.map { $0.allowsCellularAccess }
        }
        set {
            _applyMutation { $0.allowsCellularAccess = newValue }
        }
    }
    
    public var httpMethod: String? {
        get {
            return _handle.map { $0.httpMethod }
        }
        set {
            _applyMutation {
                if let value = newValue {
                    $0.httpMethod = value
                } else {
                    $0.httpMethod = "GET"
                }
            }
        }
    }
    
    public var allHTTPHeaderFields: [String : String]? {
        get {
            return _handle.map { $0.allHTTPHeaderFields }
        }
        set {
            _applyMutation { $0.allHTTPHeaderFields = newValue }
        }
    }
    
    public func value(forHTTPHeaderField field: String) -> String? {
        return _handle.map { $0.value(forHTTPHeaderField: field) }
    }
    
    public mutating func setValue(_ value: String?, forHTTPHeaderField field: String) {
        _applyMutation {
            $0.setValue(value, forHTTPHeaderField: field)
        }
    }
    
    public mutating func addValue(_ value: String, forHTTPHeaderField field: String) {
        _applyMutation {
            $0.addValue(value, forHTTPHeaderField: field)
        }
    }
    
    public var httpBody: Data? {
        get {
            return _handle.map { $0.httpBody }
        }
        set {
            _applyMutation { $0.httpBody = newValue }
        }
    }
    
    public var httpBodyStream: InputStream? {
        get {
            return _handle.map { $0.httpBodyStream }
        }
        set {
            _applyMutation { $0.httpBodyStream = newValue }
        }
    }
    
    public var httpShouldHandleCookies: Bool {
        get {
            return _handle.map { $0.httpShouldHandleCookies }
        }
        set {
            _applyMutation { $0.httpShouldHandleCookies = newValue }
        }
    }
    
    public var httpShouldUsePipelining: Bool {
        get {
            return _handle.map { $0.httpShouldUsePipelining }
        }
        set {
            _applyMutation { $0.httpShouldUsePipelining = newValue }
        }
    }
    
    public func hash(into hasher: inout Hasher) {
        hasher.combine(_handle.map { $0 })
    }
    
    // struct 里面如果有引用值, 直接使用引用值进行判等.
    public static func ==(lhs: URLRequest, rhs: URLRequest) -> Bool {
        return lhs._handle._uncopiedReference().isEqual(rhs._handle._uncopiedReference())
    }
    
    var protocolProperties: [String: Any] {
        get {
            return _handle.map { $0.protocolProperties }
        }
        set {
            _applyMutation { $0.protocolProperties = newValue }
        }
    }
}

extension URLRequest : CustomStringConvertible, CustomDebugStringConvertible, CustomReflectable {
    public var description: String {
        if let u = url {
            return u.description
        } else {
            return "url: nil"
        }
    }

    public var debugDescription: String {
        return self.description
    }

    // mirror, 由各个类, 来决定如何暴露自己的内部数据.
    public var customMirror: Mirror {
        var c: [(label: String?, value: Any)] = []
        c.append((label: "url", value: url as Any))
        c.append((label: "cachePolicy", value: cachePolicy.rawValue))
        c.append((label: "timeoutInterval", value: timeoutInterval))
        c.append((label: "mainDocumentURL", value: mainDocumentURL as Any))
        c.append((label: "networkServiceType", value: networkServiceType))
        c.append((label: "allowsCellularAccess", value: allowsCellularAccess))
        c.append((label: "httpMethod", value: httpMethod as Any))
        c.append((label: "allHTTPHeaderFields", value: allHTTPHeaderFields as Any))
        c.append((label: "httpBody", value: httpBody as Any))
        c.append((label: "httpBodyStream", value: httpBodyStream as Any))
        c.append((label: "httpShouldHandleCookies", value: httpShouldHandleCookies))
        c.append((label: "httpShouldUsePipelining", value: httpShouldUsePipelining))
        return Mirror(self, children: c, displayStyle: .struct)
    }
}

extension URLRequest : _ObjectiveCBridgeable {
    // 返回对应 OC 的类型.
    public static func _getObjectiveCType() -> Any.Type {
        return NSURLRequest.self
    }

    // 这里返回的是 copy 之后的, 将原始数据和目标数据, 进行了切分.
    public func _bridgeToObjectiveC() -> NSURLRequest {
        return _handle._copiedReference()
    }

    public static func _forceBridgeFromObjectiveC(_ input: NSURLRequest, result: inout URLRequest?) {
        result = URLRequest(_bridged: input)
    }

    public static func _conditionallyBridgeFromObjectiveC(_ input: NSURLRequest, result: inout URLRequest?) -> Bool {
        result = URLRequest(_bridged: input)
        return true
    }

    public static func _unconditionallyBridgeFromObjectiveC(_ source: NSURLRequest?) -> URLRequest {
        var result: URLRequest? = nil
        _forceBridgeFromObjectiveC(source!, result: &result)
        return result!
    }
}
