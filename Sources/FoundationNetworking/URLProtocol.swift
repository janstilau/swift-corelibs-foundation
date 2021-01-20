#if os(macOS) || os(iOS) || os(watchOS) || os(tvOS)
import SwiftFoundation
#else
import Foundation
#endif

/*!
    @header URLProtocol.h

    // 具体的, 网络请求怎么发送, 怎么解析, 是扩展系统的事情.
    This header file describes the constructs used to represent URL
    protocols, and describes the extensible system by which specific
    classes can be made to handle the loading of particular URL types or
    schemes.
    
    // 真正的网络交互, 是通过 protocol 来执行的. Connection, Session 是在上层的业务控制类.
    <p>URLProtocol is an abstract class which provides the
    basic structure for performing protocol-specific loading of URL
    data.
    
    // URLProtocolClient 就是 protocol 对外输出的信号, 在合适的实际, Protocol 调用代理方法, 将自己开始, 结束, 出错, 数据的信息, 暴露给业务系统.
    <p>The URLProtocolClient describes the integration points a
    protocol implementation can use to hook into the URL loading system.
    URLProtocolClient describes the methods a protocol implementation
    needs to drive the URL loading system from a URLProtocol subclass.
    
    // 如果想要扩展 protocol, 可以使用 setProperty:forKey:inRequest 在 Request 里面, 设置标志位. 通过这个标志位, 使用扩展的 protocol 处理网络请求.
    <p>To support customization of protocol-specific requests,
    protocol implementors are encouraged to provide categories on
    NSURLRequest and NSMutableURLRequest. Protocol implementors who
    need to extend the capabilities of NSURLRequest and
    NSMutableURLRequest in this way can store and retrieve
    protocol-specific request data by using the
    <tt>+propertyForKey:inRequest:</tt> and
    <tt>+setProperty:forKey:inRequest:</tt> class methods on
    URLProtocol. See the NSHTTPURLRequest on NSURLRequest and
    NSMutableHTTPURLRequest on NSMutableURLRequest for examples of
    such extensions.
    
    <p>An essential responsibility for a protocol implementor is
    creating a URLResponse for each request it processes successfully.
    A protocol implementor may wish to create a custom, mutable 
    URLResponse class to aid in this work.
*/

/*!
@protocol URLProtocolClient
@discussion URLProtocolClient provides the interface to the URL
loading system that is intended for use by URLProtocol
implementors.
*/
// Protocol 的代理.
public protocol URLProtocolClient : NSObjectProtocol {
    
    
    /*!
     @method URLProtocol:wasRedirectedToRequest:
     @abstract Indicates to an URLProtocolClient that a redirect has
     occurred.
     @param URLProtocol the URLProtocol object sending the message.
     @param request the NSURLRequest to which the protocol implementation
     has redirected.
     */
    // http 请求里面, 会有重定向的响应. 这里, 给外界一个机会, 决定如何处理.
    // 默认是接受重定向. 如果外界接受了重定向, 那么 protocol 应该 stop 当前 loading, 开始重定向的 loading.
    func urlProtocol(_ protocol: URLProtocol, wasRedirectedTo request: URLRequest, redirectResponse: URLResponse)
    
    
    /*!
     @method URLProtocol:cachedResponseIsValid:
     @abstract Indicates to an URLProtocolClient that the protocol
     implementation has examined a cached response and has
     determined that it is valid.
     @param URLProtocol the URLProtocol object sending the message.
     @param cachedResponse the NSCachedURLResponse object that has
     examined and is valid.
     */
    // 这个在之前的协议里面, 没有出现过.
    func urlProtocol(_ protocol: URLProtocol, cachedResponseIsValid cachedResponse: CachedURLResponse)
    
    
    /*!
     @method URLProtocol:didReceiveResponse:
     @abstract Indicates to an URLProtocolClient that the protocol
     implementation has created an URLResponse for the current load.
     @param URLProtocol the URLProtocol object sending the message.
     @param response the URLResponse object the protocol implementation
     has created.
     @param cacheStoragePolicy The URLCache.StoragePolicy the protocol
     has determined should be used for the given response if the
     response is to be stored in a cache.
     */
    // protocol 解析出来了响应, 抛出去.
    // URLResponse : -> The metadata associated with the response to a URL load request, independent of protocol and URL scheme.
    func urlProtocol(_ protocol: URLProtocol, didReceive response: URLResponse, cacheStoragePolicy policy: URLCache.StoragePolicy)
    
    
    /*!
     @method URLProtocol:didLoadData:
     @abstract Indicates to an NSURLProtocolClient that the protocol
     implementation has loaded URL data.
     @discussion The data object must contain only new data loaded since
     the previous call to this method (if any), not cumulative data for
     the entire load.
     @param URLProtocol the NSURLProtocol object sending the message.
     @param data URL load data being made available.
     */
    // protoocl 解析出来了数据, 抛出去.
    // 需要注意的是, response 和 data 的过程是分开的.  response, 仅仅代表相应的头信息.
    func urlProtocol(_ protocol: URLProtocol, didLoad data: Data)
    
    
    /*!
     @method URLProtocolDidFinishLoading:
     @abstract Indicates to an NSURLProtocolClient that the protocol
     implementation has finished loading successfully.
     @param URLProtocol the NSURLProtocol object sending the message.
     */
    // protocol 结束 loading 了, 通知外界.
    func urlProtocolDidFinishLoading(_ protocol: URLProtocol)
    
    
    /*!
     @method URLProtocol:didFailWithError:
     @abstract Indicates to an NSURLProtocolClient that the protocol
     implementation has failed to load successfully.
     @param URLProtocol the NSURLProtocol object sending the message.
     @param error The error that caused the load to fail.
     */
    // 当发生了错误, 通知外界.
    func urlProtocol(_ protocol: URLProtocol, didFailWithError error: Error)
    
    
    /*!
     @method URLProtocol:didReceiveAuthenticationChallenge:
     @abstract Start authentication for the specified request
     @param protocol The protocol object requesting authentication.
     @param challenge The authentication challenge.
     @discussion The protocol client guarantees that it will answer the
     request on the same thread that called this method. It may add a
     default credential to the challenge it issues to the connection delegate,
     if the protocol did not provide one.
     */
    // 当服务器有了审核相关的要求的时候.
    func urlProtocol(_ protocol: URLProtocol, didReceive challenge: URLAuthenticationChallenge)
    
    
    /*!
     @method URLProtocol:didCancelAuthenticationChallenge:
     @abstract Cancel authentication for the specified request
     @param protocol The protocol object cancelling authentication.
     @param challenge The authentication challenge.
     */
    // 这个之前没有.
    func urlProtocol(_ protocol: URLProtocol, didCancel challenge: URLAuthenticationChallenge)
}

// 这里, 专门有一个类, 叫做 _ProtocolClient
internal class _ProtocolClient : NSObject {
    var cachePolicy: URLCache.StoragePolicy = .notAllowed
    var cacheableData: [Data]?
    var cacheableResponse: URLResponse?
}

/*!
    @class NSURLProtocol
 
    @abstract NSURLProtocol is an abstract class which provides the
    basic structure for performing protocol-specific loading of URL
    data. Concrete subclasses handle the specifics associated with one
    or more protocols or URL schemes.
*/
open class URLProtocol : NSObject {
    
    // 任何私有的变量, 都增加了 private, 并且, 是 _ 开头的.
    // 还是很长的名字, iOS 里面, 对于名字, 一直是不避讳长名字.
    private static var _registeredProtocolClasses = [AnyClass]()
    private static var _classesLock = NSLock()

    //TODO: The right way to do this is using URLProtocol.property(forKey:in) and URLProtocol.setProperty(_:forKey:in)
    var properties: [URLProtocol._PropertyKey: Any] = [:]
    /*! 
        @method initWithRequest:cachedResponse:client:
        @abstract Initializes an NSURLProtocol given request, 
        cached response, and client.
        @param request The request to load.
        @param cachedResponse A response that has been retrieved from the
        cache for the given request. The protocol implementation should
        apply protocol-specific validity checks if such tests are
        necessary.
        @param client The NSURLProtocolClient object that serves as the
        interface the protocol implementation can use to report results back
        to the URL loading system.
    */
    // cachedResponse 应该由谁来去获取呢
    // sessionTask 里面有相应的逻辑, Gnu 里面, 直接传递的 nil.
    public required init(request: URLRequest, cachedResponse: CachedURLResponse?, client: URLProtocolClient?) {
        self._request = request
        self._cachedResponse = cachedResponse
        self._client = client ?? _ProtocolClient()
    }

    // 属性不固定在上面了. 还是不习惯.
    private var _request : URLRequest
    private var _cachedResponse : CachedURLResponse?
    private var _client : URLProtocolClient?

    /*! 
        @method client
        @abstract Returns the NSURLProtocolClient of the receiver. 
        @result The NSURLProtocolClient of the receiver.
        不太明白, 这种封装有什么意义. 因为 client 里面, 就是操作 _client, 没有安插别的东西.
    */
    open var client: URLProtocolClient? {
        set { self._client = newValue }
        get { return self._client }
    }
    
    /*! 
        @method request
        @abstract Returns the NSURLRequest of the receiver. 
        @result The NSURLRequest of the receiver. 
    */
    // 这里, 封装有意义, 对外是没有 _ 的漂亮的 request, 里面使用的是 _request.
    // 不过, private set 不也能够实现这个目的吗.
    /*@NSCopying*/ open var request: URLRequest {
        return _request
     }
    
    /*! 
        @method cachedResponse
        @abstract Returns the NSCachedURLResponse of the receiver.  
        @result The NSCachedURLResponse of the receiver. 
    */
    /*@NSCopying*/ open var cachedResponse: CachedURLResponse? {
        return _cachedResponse
     }
    
    // 一种, 很漂亮的提示外界的方法.
    /*======================================================================
      Begin responsibilities for protocol implementors
    
      The methods between this set of begin-end markers must be
      implemented in order to create a working protocol.
      ======================================================================*/
    
    /*! 
        @method canInitWithRequest:
        @abstract This method determines whether this protocol can handle
        the given request.
        @discussion A concrete subclass should inspect the given request and
        determine whether or not the implementation can perform a load with
        that request. This is an abstract method. Sublasses must provide an
        implementation. The implementation in this class calls
        NSRequestConcreteImplementation.
        @param request A request to inspect.
        @result YES if the protocol can handle the given request, NO if not.
    */
    // 在 session 处理 request 的时候, 首先会通过该方法, 查询是否使用该 protocol 去处理.
    // 这里, 没有使用 hashMap, 而是使用 _registeredProtocolClasses 数组遍历的方式.
    open class func canInit(with request: URLRequest) -> Bool {
        NSRequiresConcreteImplementation()
    }
    
    /*! 
        @method canonicalRequestForRequest:
        @abstract This method returns a canonical version of the given
        request.
        @discussion It is up to each concrete protocol implementation to
        define what "canonical" means. However, a protocol should
        guarantee that the same input request always yields the same
        canonical form. Special consideration should be given when
        implementing this method since the canonical form of a request is
        used to look up objects in the URL cache, a process which performs
        equality checks between NSURLRequest objects.
        <p>
    */
    // canonical -> 最简洁的. 这里解释就很清楚了, request 里面可能包含了变化的东西. 比如, 时间戳, 但是存储的时候, 时间戳不应该存储. 一个业务参数的 request, 应该取得对应的 response, 而时间戳会参与到 hash 值的计算. 所以, 在存储的时候, 应该使用 canonicalRequest 这个方法, 进行那些不重要的变化值的去除工作.
    open class func canonicalRequest(for request: URLRequest) -> URLRequest {
        NSRequiresConcreteImplementation()
    }
    
    /*!
        @method requestIsCacheEquivalent:toRequest:
        @abstract Compares two requests for equivalence with regard to caching.
        @discussion Requests are considered equivalent for cache purposes
        if and only if they would be handled by the same protocol AND that
        protocol declares them equivalent after performing 
        implementation-specific checks.
        @result YES if the two requests are cache-equivalent, NO otherwise.
    */
    // 判断两个 Request 是否相等. 本身, NSURLRequest 是提供了 isEqual 的实现的.
    // 但是, 实际业务上, 是否要求那么严格呢, 是否 URL 相等就可以呢. 这里, 提供了业务上扩展的方法.
    open class func requestIsCacheEquivalent(_ a: URLRequest, to b: URLRequest) -> Bool {
        NSRequiresConcreteImplementation()
    }
    
    /*! 
        @method startLoading
        @abstract Starts protocol-specific loading of a request. 
        @discussion When this method is called, the protocol implementation
        should start loading a request.
    */
    // 开始 loading, 具体的实现, GNU Foundation 那里有
    open func startLoading() {
        NSRequiresConcreteImplementation()
    }
    
    /*! 
        @method stopLoading
        @abstract Stops protocol-specific loading of a request. 
        @discussion When this method is called, the protocol implementation
        should end the work of loading a request. This could be in response
        to a cancel operation, so protocol implementations must be able to
        handle this call while a load is in progress.
    */
    // 结束 loading, 具体的实现, GNU Foundation 那里有
    open func stopLoading() {
        NSRequiresConcreteImplementation()
    }
    
    /*======================================================================
      End responsibilities for protocol implementors
      ======================================================================*/
    
    /*! 
        @method propertyForKey:inRequest:
        @abstract Returns the property in the given request previously
        stored with the given key.
        @discussion The purpose of this method is to provide an interface
        for protocol implementors to access protocol-specific information
        associated with NSURLRequest objects.
        @param key The string to use for the property lookup.
        @param request The request to use for the property lookup.
        @result The property stored with the given key, or nil if no property
        had previously been stored with the given key in the given request.
    */
    // 专门, 设置 protocolProperties, 就是为了 protocol 扩展用的. 所以, 这个 map 不应该用到其他的存值的目的.
    // 可见, 还是数据类要提供实现. 或者 protocol 也可以提供, 但是很有可能一个 request, 会被另外一个 protocl 处理, 所以, 使用数据类存储最保险.
    open class func property(forKey key: String, in request: URLRequest) -> Any? {
        return request.protocolProperties[key]
    }
    
    /*! 
        @method setProperty:forKey:inRequest:
        @abstract Stores the given property in the given request using the
        given key.
        @discussion The purpose of this method is to provide an interface
        for protocol implementors to customize protocol-specific
        information associated with NSMutableURLRequest objects.
        @param value The property to store. 
        @param key The string to use for the property storage. 
        @param request The request in which to store the property. 
    */
    open class func setProperty(_ value: Any, forKey key: String, in request: NSMutableURLRequest) {
        request.protocolProperties[key] = value
    }
    
    /*!
        @method removePropertyForKey:inRequest:
        @abstract Remove any property stored under the given key
        @discussion Like setProperty:forKey:inRequest: above, the purpose of this
            method is to give protocol implementors the ability to store 
            protocol-specific information in an NSURLRequest
        @param key The key whose value should be removed
        @param request The request to be modified
    */
    open class func removeProperty(forKey key: String, in request: NSMutableURLRequest) {
        request.protocolProperties.removeValue(forKey: key)
    }
    
    /*! 
        @method registerClass:
        @abstract This method registers a protocol class, making it visible
        to several other NSURLProtocol class methods.
        @discussion When the URL loading system begins to load a request,
        each protocol class that has been registered is consulted in turn to
        see if it can be initialized with a given request. The first
        protocol handler class to provide a YES answer to
        <tt>+canInitWithRequest:</tt> "wins" and that protocol
        implementation is used to perform the URL load.
        // 具体的 protocol 初始化, 使用的过程.
        There is no guarantee that all registered protocol classes will be consulted.
     
        Hence, it should be noted that registering a class places it first
        on the list of classes that will be consulted in calls to
        <tt>+canInitWithRequest:</tt>, moving it in front of all classes
        that had been registered previously.
        <p>A similar design governs the process to create the canonical form
        of a request with the <tt>+canonicalRequestForRequest:</tt> class
        method.
        @param protocolClass the class to register.
        @result YES if the protocol was registered successfully, NO if not.
        The only way that failure can occur is if the given class is not a
        subclass of NSURLProtocol.
    */
    open class func registerClass(_ protocolClass: AnyClass) -> Bool {
        // 这里, 没有使用提前退出的技术. Swift 里面好像对这个技术不是很感冒
        if protocolClass is URLProtocol.Type {
            _classesLock.lock()
            guard !_registeredProtocolClasses.contains(where: { $0 === protocolClass }) else {
                _classesLock.unlock()
                return true
            }
            _registeredProtocolClasses.append(protocolClass)
            _classesLock.unlock()
            return true
        }
        return false
    }

    internal class func getProtocolClass(protocols: [AnyClass], request: URLRequest) -> AnyClass? {
        // Registered protocols are consulted in reverse order.
        // reverse order, 这样保证注册的可以优先使用. 因为, 注册的是开发者的意愿, 所以先询问.
        // This behaviour makes the latest registered protocol to be consulted first
        _classesLock.lock()
        let protocolClasses = protocols
        for protocolClass in protocolClasses {
            let urlProtocolClass: AnyClass = protocolClass
            // 在 Swift 里面, 通过这种方法, 实现了类对象的转化.
            // 如果单纯的判断, is 就可以了, 但是这里是转化, 所以使用了 as? URLProtocol.Type 这种
            guard let urlProtocol = urlProtocolClass as? URLProtocol.Type else { fatalError() }
            // 这个逻辑, 在 OC 里面, Protocol 的初始化, 是使用了类簇模式, 包装到了 Protoco 的 init 方法内部.
            if urlProtocol.canInit(with: request) {
                _classesLock.unlock()
                return urlProtocol
            }
        }
        _classesLock.unlock()
        return nil
    }

    // 返回之前注册的 protocols
    // defer 的时候, 之前自己写的 MCDefer 也是这么实现的.
    internal class func getProtocols() -> [AnyClass]? {
        _classesLock.lock()
        defer { _classesLock.unlock() }
        return _registeredProtocolClasses
    }
    /*! 
        @method unregisterClass:
        @abstract This method unregisters a protocol. 
        @discussion After unregistration, a protocol class is no longer
        consulted in calls to NSURLProtocol class methods.
        @param protocolClass The class to unregister.
    */
    open class func unregisterClass(_ protocolClass: AnyClass) {
        _classesLock.lock()
        // 默认, 是使用 == 操作符, 这里使用了 === 操作符, 所以必须要提供闭包.
        if let idx = _registeredProtocolClasses.firstIndex(where: { $0 === protocolClass }) {
            _registeredProtocolClasses.remove(at: idx)
        }
        _classesLock.unlock()
    }

    // 以下, 是 Protocol 对于 Task 的包装. 这里, Protocol 里面, 直接存储了 TASK. 
    open class func canInit(with task: URLSessionTask) -> Bool {
        guard let request = task.currentRequest else { return false }
        return canInit(with: request)
    }
    
    public required convenience init(task: URLSessionTask, cachedResponse: CachedURLResponse?, client: URLProtocolClient?) {
        let urlRequest = task.originalRequest
        self.init(request: urlRequest!, cachedResponse: cachedResponse, client: client)
        self.task = task
    }
    
    /*@NSCopying*/ open var task: URLSessionTask? {
        set { self._task = newValue }
        get { return self._task }
    }

    // 在这里, Protocol 里面, 居然存了一个 task.
    private var _task : URLSessionTask? = nil
}
