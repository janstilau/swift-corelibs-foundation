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

open class NSURLRequest : NSObject, NSSecureCoding, NSCopying, NSMutableCopying {
    
    open override func copy() -> Any {
        return copy(with: nil)
    }
    
    // NSCopying 里面, 限制的方法, 还是 withZone 的.
    // 所以, 这里提供了一个简便 copy, 去除了 zone 的传入.
    open func copy(with zone: NSZone? = nil) -> Any {
        // 如果, 就是 NSURLRequest, 那么不可变对象, 可以直接返回.
        if type(of: self) === NSURLRequest.self {
            // Already immutable
            return self
        }
        let c = NSURLRequest(url: url!) //生成一个新的对象, 然后通过私有方法进行初始化工作.
        c.setValues(from: self)
        return c
    }
    
    // mutableCopy, 就是生成可变版本的类.
    open override func mutableCopy() -> Any {
        return mutableCopy(with: nil)
    }
    
    open func mutableCopy(with zone: NSZone? = nil) -> Any {
        let c = NSMutableURLRequest(url: url!)
        c.setValues(from: self)
        return c
    }
    
    // 默认, 使用 useProtocolCachePolicy, 60 秒超时.
    // copy 协议, 感觉应该放到 extension 中去, 难道是因为里面使用了 setValues
    // 感觉还是 init 方法, 应该放到最上面.
    public convenience init(url: URL) {
        self.init(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 60.0)
    }
    
    // 最原始的, 就是 url, policy, cachePolicy 这些值.
    public init(url: URL, cachePolicy: NSURLRequest.CachePolicy, timeoutInterval: TimeInterval) {
        self.url = url.absoluteURL
        self.cachePolicy = cachePolicy
        self.timeoutInterval = timeoutInterval
    }
    
    // Copy 的话, 就是那所有的值, 都要进行一次 copy
    // 可以看到, 在源码里面, 也有大量的 self 的使用. 不是应该进行少用吗????
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
    
    // 还是纯 OC 的协议的方式. 因为这个协议, 其实是 OC 的协议.
    public required init?(coder aDecoder: NSCoder) {
        guard aDecoder.allowsKeyedCoding else {
            preconditionFailure("Unkeyed coding is unsupported.")
        }

        super.init()
        
        // 所有的, 都增加可选值绑定.
        if let encodedURL = aDecoder.decodeObject(forKey: "NS.url") as? NSURL {
            self.url = encodedURL as URL
        }
        
        if let encodedHeaders = aDecoder.decodeObject(forKey: "NS._allHTTPHeaderFields") as? NSDictionary {
            self.allHTTPHeaderFields = encodedHeaders.reduce([String : String]()) { result, item in
                // 首先, 显式地, 把参数变为可变的.
                // 因为 swift 里面, 参数是不可变的, 但是, 通过这种方式, 也能让参数可变.
                // 参数不可变, 有的时候, 专门在去定义一个变量, 其实算是污染了代码.
                var result = result
                // 这里, 不太明白, 为什么这么多转化???
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
        // 这里, 拿到了 number 值, 然是为了得到的是 CachePolicy 值, 专门调用了 CachePolicy 的初始化方法.
        // 这其实是, 用类型代替原始值的一次使用.
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
    
    // 为什么, 上面都是 as NS 的类, 就是因为 encode 的时候, 都调用了 _bridgeToObjectiveC 的代码
    // 我猜测是, 这是为了兼容之前 OC 的数据, 因为 OC 就是 NS 的类的存储.
    // 所以 decode 的时候, 就还是 NS 的类. 既然 decode 的时候, 还是原来的数据, 那么这个类, encode 的时候, 就得是用 OC 的版本.
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
        //On macOS input stream is not encoded.
        aCoder.encode(self.networkServiceType.rawValue._bridgeToObjectiveC(), forKey: "NS._networkServiceType")
        aCoder.encode(self.allowsCellularAccess._bridgeToObjectiveC(), forKey: "NS._allowsCellularAccess")
        aCoder.encode(self.httpShouldHandleCookies._bridgeToObjectiveC(), forKey: "NS._httpShouldHandleCookies")
        aCoder.encode(self.httpShouldUsePipelining._bridgeToObjectiveC(), forKey: "NS._httpShouldUsePipelining")
    }
    
    // 这里, 都是用的 ==, 因为 OC 版本的类, 只是序列化的过程中, 到了内存里面, 还是 Swift 版本的对象.
    open override func isEqual(_ object: Any?) -> Bool {
        //On macOS this fields do not determine the result:
        //allHTTPHeaderFields
        //timeoutInterval
        //httBody
        //networkServiceType
        //httpShouldUsePipelining
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

    open override var hash: Int {
        var hasher = Hasher()
        hasher.combine(url)
        hasher.combine(mainDocumentURL)
        hasher.combine(httpMethod)
        hasher.combine(httpBodyStream)
        hasher.combine(allowsCellularAccess)
        hasher.combine(httpShouldHandleCookies)
        return hasher.finalize()
    }

    /// Indicates that NSURLRequest implements the NSSecureCoding protocol.
    open class  var supportsSecureCoding: Bool { return true }
    
    // 数据部分, 不明白, 为什么不写到最开始的位置.
    /// The URL of the receiver.
    /*@NSCopying */open fileprivate(set) var url: URL?
    
    /// The main document URL associated with this load.
    ///
    /// This URL is used for the cookie "same domain as main
    /// document" policy. There may also be other future uses.
    /*@NSCopying*/ open fileprivate(set) var mainDocumentURL: URL?
    
    open internal(set) var cachePolicy: CachePolicy = .useProtocolCachePolicy
    
    open internal(set) var timeoutInterval: TimeInterval = 60.0

    internal var _httpMethod: String? = "GET"

    /// Returns the HTTP request method of the receiver.
    /// 这里, 之所以要变为计算属性, 是因为 get 的时候一定要有值. 所以 set 的时候, 要做处理.
    open fileprivate(set) var httpMethod: String? {
        get { return _httpMethod }
        set { _httpMethod = NSURLRequest._normalized(newValue) }
    }

    private class func _normalized(_ raw: String?) -> String {
        guard let raw = raw else {
            return "GET"
        }

        let nsMethod = NSString(string: raw)

        for method in ["GET", "HEAD", "POST", "PUT", "DELETE", "CONNECT"] {
            if nsMethod.caseInsensitiveCompare(method) == .orderedSame {
                return method
            }
        }
        return raw
    }
    
    /// A dictionary containing all the HTTP header fields
    /// of the receiver.
    /// 因为, Http 是一个纯文办的协议, 所以这里就是 [String: String] 了
    open internal(set) var allHTTPHeaderFields: [String : String]? = nil
    
    /// Returns the value which corresponds to the given header field.
    ///
    /// Note that, in keeping with the HTTP RFC, HTTP header field
    /// names are case-insensitive.
    /// - Parameter field: the header field name to use for the lookup
    ///     (case-insensitive).
    /// - Returns: the value associated with the given header field, or `nil` if
    /// there is no value associated with the given header field.
    open func value(forHTTPHeaderField field: String) -> String? {
        guard let f = allHTTPHeaderFields else { return nil }
        return existingHeaderField(field, inHeaderFields: f)?.1
    }
    
    // 这里, 就带来了 Enum 的好处, 就是将数据的可变性降低了. 不会同时出现, Data, inputStream 都存在的情况. Enum 的关联值的特性, 将数据划分为不同的区域, 不会交叉.
    internal enum Body {
        case data(Data)
        case stream(InputStream)
    }
    // 私有的, 还是应该加 _body, 公开的, 就应该不加.
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

/// An `NSMutableURLRequest` object represents a mutable URL load
/// request in a manner independent of protocol and URL scheme.
///
/// This specialization of `NSURLRequest` is provided to aid
/// developers who may find it more convenient to mutate a single request
/// object for a series of URL loads instead of creating an immutable
/// `NSURLRequest` for each load. This programming model is supported by
/// the following contract stipulation between `NSMutableURLRequest` and the
/// `URLSession` API: `URLSession` makes a deep copy of each
/// `NSMutableURLRequest` object passed to it.
///
/// `NSMutableURLRequest` is designed to be extended to support
/// protocol-specific data by adding categories to access a property
/// object provided in an interface targeted at protocol implementors.
///
/// Protocol implementors should direct their attention to the
/// `NSMutableURLRequestExtensibility` category on
/// `NSMutableURLRequest` for more information on how to provide
/// extensions on `NSMutableURLRequest` to support protocol-specific
/// request information.
///
/// Clients of this API who wish to create `NSMutableURLRequest`
/// objects to load URL content should consult the protocol-specific
/// `NSMutableURLRequest` categories that are available. The
/// `NSMutableHTTPURLRequest` category on `NSMutableURLRequest` is an
/// example.
open class NSMutableURLRequest : NSURLRequest {
    // 数据部分, 其实还是使用的 NSURLRequest 的. 仅仅是, 这里提供了 可变的接口.
    public required init?(coder aDecoder: NSCoder) {
        super.init(coder: aDecoder)
    }
    
    public convenience init(url: URL) {
        self.init(url: url, cachePolicy: .useProtocolCachePolicy, timeoutInterval: 60.0)
    }
    
    public override init(url: URL, cachePolicy: NSURLRequest.CachePolicy, timeoutInterval: TimeInterval) {
        super.init(url: url, cachePolicy: cachePolicy, timeoutInterval: timeoutInterval)
    }
    
    // 这里, 使用了 MutableCopy.
    // 一个可变对象 copy, 还是可变对象.
    open override func copy(with zone: NSZone? = nil) -> Any {
        return mutableCopy(with: zone)
    }
    
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

// 这里, 不太明白为什么这么写, 直接 hash 查找不应该更快一点吗.
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
