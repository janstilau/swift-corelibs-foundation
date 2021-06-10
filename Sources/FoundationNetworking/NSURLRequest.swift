#if os(macOS) || os(iOS) || os(watchOS) || os(tvOS)
import SwiftFoundation
#else
import Foundation
#endif

// -----------------------------------------------------------------------------
///
/// This header file describes the constructs used to represent URL
/// load requests in a manner independent of protocol and URL scheme.
/// Immutable and mutable variants of this URL load request concept
/// are described, named `NSURLRequest` and `NSMutableURLRequest`,
/// respectively. A collection of constants is also declared to
/// exercise control over URL content caching policy.
///
/// `NSURLRequest` and `NSMutableURLRequest` are designed to be
/// customized to support protocol-specific requests. Protocol
/// implementors who need to extend the capabilities of `NSURLRequest`
/// and `NSMutableURLRequest` are encouraged to provide categories on
/// these classes as appropriate to support protocol-specific data. To
/// store and retrieve data, category methods can use the
/// `propertyForKey(_:,inRequest:)` and
/// `setProperty(_:,forKey:,inRequest:)` class methods on
/// `URLProtocol`. See the `NSHTTPURLRequest` on `NSURLRequest` and
/// `NSMutableHTTPURLRequest` on `NSMutableURLRequest` for examples of
/// such extensions.
///
/// The main advantage of this design is that a client of the URL
/// loading library can implement request policies in a standard way
/// without type checking of requests or protocol checks on URLs. Any
/// protocol-specific details that have been set on a URL request will
/// be used if they apply to the particular URL being loaded, and will
/// be ignored if they do not apply.
///
// -----------------------------------------------------------------------------

/// A cache policy
///
/// The `NSURLRequestCachePolicy` `enum` defines constants that
/// can be used to specify the type of interactions that take place with
/// the caching system when the URL loading system processes a request.
/// Specifically, these constants cover interactions that have to do
/// with whether already-existing cache data is returned to satisfy a
/// URL load request.
extension NSURLRequest {
    public enum CachePolicy : UInt {
        /// Specifies that the caching logic defined in the protocol
        /// implementation, if any, is used for a particular URL load request. This
        /// is the default policy for URL load requests.
        case useProtocolCachePolicy
        /// Specifies that the data for the URL load should be loaded from the
        /// origin source. No existing local cache data, regardless of its freshness
        /// or validity, should be used to satisfy a URL load request.
        case reloadIgnoringLocalCacheData
        /// Specifies that not only should the local cache data be ignored, but that
        /// proxies and other intermediates should be instructed to disregard their
        /// caches so far as the protocol allows.  Unimplemented.
        case reloadIgnoringLocalAndRemoteCacheData // Unimplemented
        /// Older name for `NSURLRequestReloadIgnoringLocalCacheData`.
        public static var reloadIgnoringCacheData: CachePolicy { return .reloadIgnoringLocalCacheData }
        /// Specifies that the existing cache data should be used to satisfy a URL
        /// load request, regardless of its age or expiration date. However, if
        /// there is no existing data in the cache corresponding to a URL load
        /// request, the URL is loaded from the origin source.
        case returnCacheDataElseLoad
        /// Specifies that the existing cache data should be used to satisfy a URL
        /// load request, regardless of its age or expiration date. However, if
        /// there is no existing data in the cache corresponding to a URL load
        /// request, no attempt is made to load the URL from the origin source, and
        /// the load is considered to have failed. This constant specifies a
        /// behavior that is similar to an "offline" mode.
        case returnCacheDataDontLoad
        /// Specifies that the existing cache data may be used provided the origin
        /// source confirms its validity, otherwise the URL is loaded from the
        /// origin source.
        /// - Note: Unimplemented.
        case reloadRevalidatingCacheData // Unimplemented
    }
    
    public enum NetworkServiceType : UInt {
        case `default` // Standard internet traffic
        case voip // Voice over IP control traffic
        case video // Video traffic
        case background // Background traffic
        case voice // Voice data
        case networkServiceTypeCallSignaling // Call Signaling
    }
}

/*
 /***************    Basic protocols        ***************/

 @protocol NSCopying

 - (id)copyWithZone:(nullable NSZone *)zone;

 @end

 @protocol NSMutableCopying

 - (id)mutableCopyWithZone:(nullable NSZone *)zone;

 @end
 */

// Swift 版本的 NSURLRequest.
// Swift 版本的各个类, 和之前 OC 版本的没有任何联系, 都是要重新在 Swift 里面, 实现一次才可以.

open class NSURLRequest : NSObject, NSSecureCoding, NSCopying, NSMutableCopying {
    
    /*
     对于一个引用值来说, 它也可以有可变不可变之分, 这种区分, 就是看一下有没有可以改变属性的可变接口开放出来了.
     */
    open override func copy() -> Any {
        return copy(with: nil)
    }
    
    open func copy(with zone: NSZone? = nil) -> Any {
        if type(of: self) === NSURLRequest.self {
            // 不可变对象, 就是没有提供 set 方法的对象. 直接返回.
            return self
        }
        // 新生成一个不可变对象, 然后将所有的数据复制过去.
        // 这是一个固定的模式.
        let c = NSURLRequest(url: url!)
        c.setValues(from: self)
        return c
    }
    
    open override func mutableCopy() -> Any {
        return mutableCopy(with: nil)
    }
    
    open func mutableCopy(with zone: NSZone? = nil) -> Any {
        // 新生成一个可变对象, 然后将所有的数据复制过去.
        let c = NSMutableURLRequest(url: url!)
        c.setValues(from: self)
        return c
    }
    
    
    
    
    // designated init 方法.
    // 最主要的, 就是 url, cachePolicy, timeout 这三个值.
    public init(url: URL, cachePolicy: NSURLRequest.CachePolicy, timeoutInterval: TimeInterval) {
        self.url = url.absoluteURL
        self.cachePolicy = cachePolicy
        self.timeoutInterval = timeoutInterval
    }
    
    public convenience init(url: URL) {
        self.init(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 60.0)
    }
    
    // 一顿的 set 操作.
    private func setValues(from source: NSURLRequest) {
        self.url = source.url
        self.mainDocumentURL = source.mainDocumentURL
        self.cachePolicy = source.cachePolicy
        self.timeoutInterval = source.timeoutInterval
        self.httpMethod = source.httpMethod
        self.allHTTPHeaderFields = source.allHTTPHeaderFields
        self._body = source._body
        self.networkServiceType = source.networkServiceType
        self.allowsCellularAccess = source.allowsCellularAccess
        self.httpShouldHandleCookies = source.httpShouldHandleCookies
        self.httpShouldUsePipelining = source.httpShouldUsePipelining
    }
    
    // 反序列化协议的实现.
    public required init?(coder aDecoder: NSCoder) {
        guard aDecoder.allowsKeyedCoding else {
            preconditionFailure("Unkeyed coding is unsupported.")
        }
        super.init()
        
        // 所有的取值操作, 都增加了可选值绑定. 因为不确定是否序列化的时候, 存了该值.
        // 所有的值, 都是使用 Swift Struct 进行存储的. 所以, 会有 as 类型转化的操作.
        
        if let encodedURL = aDecoder.decodeObject(forKey: "NS.url") as? NSURL {
            self.url = encodedURL as URL
        }
        
        if let encodedHeaders = aDecoder.decodeObject(forKey: "NS._allHTTPHeaderFields") as? NSDictionary {
            self.allHTTPHeaderFields = encodedHeaders.reduce([String : String]()) { result, item in
                // 参数变为 var. 这种只会出现在, let -> var, optinal -> nonoptinal 的过程里面.
                // 在之后的作用域里面, 原来变量名指代的, 其实就是变化之后的复制值了.
                var result = result
                // NSDictionary 之后, 是 NSString 的值, 所以, 这里有大量的转化工作.
                if let key = item.key as? NSString,
                   let value = item.value as? NSString {
                    result[key as String] = value as String
                }
                return result
            }
        }
        
        if let encodedDocumentURL = aDecoder.decodeObject(forKey: "NS.mainDocumentURL") as? NSURL {
            self.mainDocumentURL = encodedDocumentURL as URL
        }
        
        if let encodedMethod = aDecoder.decodeObject(forKey: "NS.httpMethod") as? NSString {
            self.httpMethod = encodedMethod as String
        }
        
        let encodedCachePolicy = aDecoder.decodeObject(forKey: "NS._cachePolicy") as! NSNumber
        // 到底, 存的是原始值, 还是调用 Decoder 存储的值, 是类的设计者的责任.
        self.cachePolicy = CachePolicy(rawValue: encodedCachePolicy.uintValue)!
        
        let encodedTimeout = aDecoder.decodeObject(forKey: "NS._timeoutInterval") as! NSNumber
        self.timeoutInterval = encodedTimeout.doubleValue
        
        let encodedHttpBody: Data? = aDecoder.withDecodedUnsafeBufferPointer(forKey: "NS.httpBody") {
            guard let buffer = $0 else { return nil }
            return Data(buffer: buffer)
        }
        
        if let encodedHttpBody = encodedHttpBody {
            self._body = .data(encodedHttpBody)
        }
        
        let encodedNetworkServiceType = aDecoder.decodeObject(forKey: "NS._networkServiceType") as! NSNumber
        self.networkServiceType = NetworkServiceType(rawValue: encodedNetworkServiceType.uintValue)!
        
        let encodedCellularAccess = aDecoder.decodeObject(forKey: "NS._allowsCellularAccess") as! NSNumber
        self.allowsCellularAccess = encodedCellularAccess.boolValue
        
        let encodedHandleCookies = aDecoder.decodeObject(forKey: "NS._httpShouldHandleCookies") as! NSNumber
        self.httpShouldHandleCookies = encodedHandleCookies.boolValue
        
        let encodedUsePipelining = aDecoder.decodeObject(forKey: "NS._httpShouldUsePipelining") as! NSNumber
        self.httpShouldUsePipelining = encodedUsePipelining.boolValue
    }
    
    // 序列化的过程, 要和反序列化的过程, 完全匹配才可以.
    open func encode(with aCoder: NSCoder) {
        guard aCoder.allowsKeyedCoding else {
            preconditionFailure("Unkeyed coding is unsupported.")
        }
        
        aCoder.encode(self.url?._bridgeToObjectiveC(), forKey: "NS.url")
        aCoder.encode(self.allHTTPHeaderFields?._bridgeToObjectiveC(), forKey: "NS._allHTTPHeaderFields")
        aCoder.encode(self.mainDocumentURL?._bridgeToObjectiveC(), forKey: "NS.mainDocumentURL")
        aCoder.encode(self.httpMethod?._bridgeToObjectiveC(), forKey: "NS.httpMethod")
        aCoder.encode(self.cachePolicy.rawValue._bridgeToObjectiveC(), forKey: "NS._cachePolicy")
        aCoder.encode(self.timeoutInterval._bridgeToObjectiveC(), forKey: "NS._timeoutInterval")
        if let httpBody = self.httpBody?._bridgeToObjectiveC() {
            let bytePtr = httpBody.bytes.bindMemory(to: UInt8.self, capacity: httpBody.length)
            aCoder.encodeBytes(bytePtr, length: httpBody.length, forKey: "NS.httpBody")
        }
        aCoder.encode(self.networkServiceType.rawValue._bridgeToObjectiveC(), forKey: "NS._networkServiceType")
        aCoder.encode(self.allowsCellularAccess._bridgeToObjectiveC(), forKey: "NS._allowsCellularAccess")
        aCoder.encode(self.httpShouldHandleCookies._bridgeToObjectiveC(), forKey: "NS._httpShouldHandleCookies")
        aCoder.encode(self.httpShouldUsePipelining._bridgeToObjectiveC(), forKey: "NS._httpShouldUsePipelining")
    }
    
    // 在类里面, 所有的都是使用了 Swift 的对象当做成员值, 所以这里使用 == 判断相等.
    open override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? NSURLRequest else { return false }
        return other === self
            || (other.url == self.url
                    && other.mainDocumentURL == self.mainDocumentURL
                    && other.httpMethod == self.httpMethod
                    && other.cachePolicy == self.cachePolicy
                    && other.httpBodyStream == self.httpBodyStream
                    && other.allowsCellularAccess == self.allowsCellularAccess
                    && other.httpShouldHandleCookies == self.httpShouldHandleCookies)
    }
    
    open class  var supportsSecureCoding: Bool { return true }
    
    
    // 数据部分, 所有的都应该考虑访问权限的问题.
    
    /*@NSCopying */open fileprivate(set) var url: URL?
    
    /// The main document URL associated with this load.
    ///
    /// This URL is used for the cookie "same domain as main
    /// document" policy. There may also be other future uses.
    /*@NSCopying*/ open fileprivate(set) var mainDocumentURL: URL?
    
    open internal(set) var cachePolicy: CachePolicy = .useProtocolCachePolicy
    
    open internal(set) var timeoutInterval: TimeInterval = 60.0
    
    /*
     在有访问控制操作符的限制下.
     1. 纯数据, 就是成员变量使用
     2. 有数据, 但是要经过加工. 计算属性来操作这个数据, _前缀, 用来区分真实的成员变量和计算属性名
     3. 纯计算属性, 值是其他不相干的成员变量计算出来的.
     */
    internal var _httpMethod: String? = "GET"
    
    open fileprivate(set) var httpMethod: String? {
        get { return _httpMethod }
        set { _httpMethod = NSURLRequest._normalized(newValue) }
    }
    
    private class func _normalized(_ raw: String?) -> String {
        // 如果, 没有设置, 就是 Get 方法.
        guard let raw = raw else {
            return "GET"
        }
        
        // 简单的进行一次筛选工作. 为什么不用 Set???
        let nsMethod = NSString(string: raw)
        for method in ["GET", "HEAD", "POST", "PUT", "DELETE", "CONNECT"] {
            if nsMethod.caseInsensitiveCompare(method) == .orderedSame {
                return method
            }
        }
        return raw
    }
    
    open internal(set) var allHTTPHeaderFields: [String : String]? = nil
    
    open func value(forHTTPHeaderField field: String) -> String? {
        guard let f = allHTTPHeaderFields else { return nil }
        return existingHeaderField(field, inHeaderFields: f)?.1
    }
    
    internal enum Body {
        case data(Data)
        case stream(InputStream)
    }
    internal var _body: Body?
    
    // 这两个方法应该有 set 方法, set 方法, 会修改 _body 的 enum 类型, 填充关联值.
    open var httpBody: Data? {
        if let body = _body {
            switch body {
            case .data(let data):
                return data
            case .stream:
                return nil
            }
        }
        return nil
    }
    
    open var httpBodyStream: InputStream? {
        if let body = _body {
            switch body {
            case .data:
                return nil
            case .stream(let stream):
                return stream
            }
        }
        return nil
    }
    
    // 对于, 这些纯数据的, 直接就是成员属性就可以了.
    open internal(set) var networkServiceType: NetworkServiceType = .default
    open internal(set) var allowsCellularAccess: Bool = true
    open internal(set) var httpShouldHandleCookies: Bool = true
    open internal(set) var httpShouldUsePipelining: Bool = true
    open override var description: String {
        let url = self.url?.description ?? "(null)"
        return super.description + " { URL: \(url) }"
    }
}

open class NSMutableURLRequest : NSURLRequest {
    
    public required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
    }
    
    public override init(url: URL, cachePolicy: NSURLRequest.CachePolicy, timeoutInterval: TimeInterval) {
        super.init(url: url, cachePolicy: cachePolicy, timeoutInterval: timeoutInterval)
    }
    
    public convenience init(url: URL) {
        self.init(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 60.0)
    }
    
    open override func copy(with zone: NSZone? = nil) -> Any {
        return mutableCopy(with: zone)
    }
    
    // 下面, 所有的对于属性的 override, 都是说增加了对于属性的 set 方法而已.
    // 父类将 set 方法的作用域进行了限制. 所以, 只能通过 Mutable 版本的类, 来调用 private 的 set 方法.
    
    /*@NSCopying */ open override var url: URL? {
        get { return super.url }
        //TODO: set { super.URL = newValue.map{ $0.copy() as! NSURL } }
        set { super.url = newValue }
    }
    
    /// The main document URL.
    ///
    /// The caller should pass the URL for an appropriate main
    /// document, if known. For example, when loading a web page, the URL
    /// of the main html document for the top-level frame should be
    /// passed.  This main document will be used to implement the cookie
    /// *only from same domain as main document* policy, and possibly
    /// other things in the future.
    /*@NSCopying*/ open override var mainDocumentURL: URL? {
        get { return super.mainDocumentURL }
        //TODO: set { super.mainDocumentURL = newValue.map{ $0.copy() as! NSURL } }
        set { super.mainDocumentURL = newValue }
    }
    
    
    /// The HTTP request method of the receiver.
    open override var httpMethod: String? {
        get { return super.httpMethod }
        set { super.httpMethod = newValue }
    }
    
    open override var cachePolicy: CachePolicy {
        get { return super.cachePolicy }
        set { super.cachePolicy = newValue }
    }
    
    open override var timeoutInterval: TimeInterval {
        get { return super.timeoutInterval }
        set { super.timeoutInterval = newValue }
    }
    
    open override var allHTTPHeaderFields: [String : String]? {
        get { return super.allHTTPHeaderFields }
        set { super.allHTTPHeaderFields = newValue }
    }
    
    /// Sets the value of the given HTTP header field.
    ///
    /// If a value was previously set for the given header
    /// field, that value is replaced with the given value. Note that, in
    /// keeping with the HTTP RFC, HTTP header field names are
    /// case-insensitive.
    /// - Parameter value: the header field value.
    /// - Parameter field: the header field name (case-insensitive).
    open func setValue(_ value: String?, forHTTPHeaderField field: String) {
        // Store the field name capitalized to match native Foundation
        let capitalizedFieldName = field.capitalized
        var f: [String : String] = allHTTPHeaderFields ?? [:]
        if let old = existingHeaderField(capitalizedFieldName, inHeaderFields: f) {
            f.removeValue(forKey: old.0)
        }
        f[capitalizedFieldName] = value
        allHTTPHeaderFields = f
    }
    
    /// Adds an HTTP header field in the current header dictionary.
    ///
    /// This method provides a way to add values to header
    /// fields incrementally. If a value was previously set for the given
    /// header field, the given value is appended to the previously-existing
    /// value. The appropriate field delimiter, a comma in the case of HTTP,
    /// is added by the implementation, and should not be added to the given
    /// value by the caller. Note that, in keeping with the HTTP RFC, HTTP
    /// header field names are case-insensitive.
    /// - Parameter value: the header field value.
    /// - Parameter field: the header field name (case-insensitive).
    open func addValue(_ value: String, forHTTPHeaderField field: String) {
        // Store the field name capitalized to match native Foundation
        let capitalizedFieldName = field.capitalized
        var f: [String : String] = allHTTPHeaderFields ?? [:]
        if let old = existingHeaderField(capitalizedFieldName, inHeaderFields: f) {
            f[old.0] = old.1 + "," + value
        } else {
            f[capitalizedFieldName] = value
        }
        allHTTPHeaderFields = f
    }
    
    open override var httpBody: Data? {
        get {
            if let body = _body {
                switch body {
                case .data(let data):
                    return data
                case .stream:
                    return nil
                }
            }
            return nil
        }
        // 不可变类, 不提供 set 方法.
        set {
            if let value = newValue {
                _body = Body.data(value)
            } else {
                _body = nil
            }
        }
    }
    
    open override var httpBodyStream: InputStream? {
        get {
            if let body = _body {
                switch body {
                case .data:
                    return nil
                case .stream(let stream):
                    return stream
                }
            }
            return nil
        }
        // 不可变类, 不提供 set 方法.
        set {
            if let value = newValue {
                _body = Body.stream(value)
            } else {
                _body = nil
            }
        }
    }
    
    open override var networkServiceType: NetworkServiceType {
        get { return super.networkServiceType }
        set { super.networkServiceType = newValue }
    }
    
    open override var allowsCellularAccess: Bool {
        get { return super.allowsCellularAccess }
        set { super.allowsCellularAccess = newValue }
    }
    
    open override var httpShouldHandleCookies: Bool {
        get { return super.httpShouldHandleCookies }
        set { super.httpShouldHandleCookies = newValue }
    }
    
    open override var httpShouldUsePipelining: Bool {
        get { return super.httpShouldUsePipelining }
        set { super.httpShouldUsePipelining = newValue }
    }
    
    // These properties are settable using URLProtocol's class methods.
    var protocolProperties: [String: Any] = [:]
}

//
private func existingHeaderField(_ key: String, inHeaderFields fields: [String : String]) -> (String, String)? {
    for (k, v) in fields {
        if k.lowercased() == key.lowercased() {
            return (k, v)
        }
    }
    return nil
}

extension NSURLRequest : _StructTypeBridgeable {
    public typealias _StructType = URLRequest
    
    public func _bridgeToSwift() -> URLRequest {
        return URLRequest._unconditionallyBridgeFromObjectiveC(self)
    }
}
