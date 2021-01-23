#if os(macOS) || os(iOS) || os(watchOS) || os(tvOS)
import SwiftFoundation
#else
import Foundation
#endif

/*!
   @const NSURLProtectionSpaceHTTP
   @abstract The protocol for HTTP
*/
public let NSURLProtectionSpaceHTTP: String = "NSURLProtectionSpaceHTTP"

/*!
   @const NSURLProtectionSpaceHTTPS
   @abstract The protocol for HTTPS
*/
public let NSURLProtectionSpaceHTTPS: String = "NSURLProtectionSpaceHTTPS"

/*!
   @const NSURLProtectionSpaceFTP
   @abstract The protocol for FTP
*/
public let NSURLProtectionSpaceFTP: String = "NSURLProtectionSpaceFTP"

/*!
    @const NSURLProtectionSpaceHTTPProxy
    @abstract The proxy type for http proxies
*/
public let NSURLProtectionSpaceHTTPProxy: String = "NSURLProtectionSpaceHTTPProxy"

/*!
    @const NSURLProtectionSpaceHTTPSProxy
    @abstract The proxy type for https proxies
*/
public let NSURLProtectionSpaceHTTPSProxy: String = "NSURLProtectionSpaceHTTPSProxy"

/*!
    @const NSURLProtectionSpaceFTPProxy
    @abstract The proxy type for ftp proxies
*/
public let NSURLProtectionSpaceFTPProxy: String = "NSURLProtectionSpaceFTPProxy"

/*!
    @const NSURLProtectionSpaceSOCKSProxy
    @abstract The proxy type for SOCKS proxies
*/
public let NSURLProtectionSpaceSOCKSProxy: String = "NSURLProtectionSpaceSOCKSProxy"

/*!
    @const NSURLAuthenticationMethodDefault
    @abstract The default authentication method for a protocol
*/
public let NSURLAuthenticationMethodDefault: String = "NSURLAuthenticationMethodDefault"

/*!
    @const NSURLAuthenticationMethodHTTPBasic
    @abstract HTTP basic authentication. Equivalent to
    NSURLAuthenticationMethodDefault for http.
*/
public let NSURLAuthenticationMethodHTTPBasic: String = "NSURLAuthenticationMethodHTTPBasic"

/*!
    @const NSURLAuthenticationMethodHTTPDigest
    @abstract HTTP digest authentication.
*/
public let NSURLAuthenticationMethodHTTPDigest: String = "NSURLAuthenticationMethodHTTPDigest"

/*!
    @const NSURLAuthenticationMethodHTMLForm
    @abstract HTML form authentication. Applies to any protocol.
*/
public let NSURLAuthenticationMethodHTMLForm: String = "NSURLAuthenticationMethodHTMLForm"

/*!
   @const NSURLAuthenticationMethodNTLM
   @abstract NTLM authentication.
*/
public let NSURLAuthenticationMethodNTLM: String = "NSURLAuthenticationMethodNTLM"

/*!
   @const NSURLAuthenticationMethodNegotiate
   @abstract Negotiate authentication.
*/
public let NSURLAuthenticationMethodNegotiate: String = "NSURLAuthenticationMethodNegotiate"

/*!
    @const NSURLAuthenticationMethodClientCertificate
    @abstract SSL Client certificate.  Applies to any protocol.
 */
@available(*, deprecated, message: "swift-corelibs-foundation does not currently support certificate authentication.")
public let NSURLAuthenticationMethodClientCertificate: String = "NSURLAuthenticationMethodClientCertificate"

/*!
    @const NSURLAuthenticationMethodServerTrust
    @abstract SecTrustRef validation required.  Applies to any protocol.
 */
@available(*, deprecated, message: "swift-corelibs-foundation does not support methods of authentication that rely on the Darwin Security framework.")
public let NSURLAuthenticationMethodServerTrust: String = "NSURLAuthenticationMethodServerTrust"


// A server or an area on a server,ly referred to as a realm, that requires authentication.
/*
 https://developer.mozilla.org/zh-cn/docs/web/http/authentication
 RFC 7235 定义了一个 HTTP 身份验证框架，服务器可以用来针对客户端的请求发送 challenge （质询信息），客户端则可以用来提供身份验证凭证。质询与应答的工作流程如下：服务器端向客户端返回 401（Unauthorized，未被授权的） 状态码，并在  WWW-Authenticate 首部提供如何进行验证的信息，其中至少包含有一种质询方式。之后有意向证明自己身份的客户端可以在新的请求中添加 Authorization 首部字段进行验证，字段值为身份验证凭证信息。通常客户端会弹出一个密码框让用户填写，然后发送包含有恰当的 Authorization  首部的请求。
 */

// 这个类, 核心就是一个数据类.
// 也有一些和这个数据类建立相关的代码, 但是本质上, 还是数据类.
open class URLProtectionSpace : NSObject, NSCopying {

    private let _host: String
    private let _isProxy: Bool // 忽略
    private let _proxyType: String?
    private let _port: Int
    private let _protocol: String?
    // WWW-Authenticate: Basic realm="Access the img"
    // realm 里面, 存放的是服务器端指定的 realm 里面的内容, 而不是 url 的 path/
    private let _realm: String?
    private let _authenticationMethod: String // 就是上面的那些固定值.

    open override func copy() -> Any {
        return copy(with: nil)
    }
    
    // 不可变对象, 返回 self.
    // 这里, 返回 any 是 NSCopying 的限制. 因为, NSCopy 里面, 返回值是 id 类型的. 在 swift 里面就是 Any.
    open func copy(with zone: NSZone? = nil) -> Any {
        return self // These instances are immutable.
    }
    
    // 置顶初始化方法, 其他所有的信息, 仅仅是 get 而已, 所有的信息, 只能是在初始化方法里面指定.
    public init(host: String, port: Int, protocol: String?, realm: String?, authenticationMethod: String?) {
        _host = host
        _port = port
        _protocol = `protocol`
        _realm = realm
        _authenticationMethod = authenticationMethod ?? NSURLAuthenticationMethodDefault
        _proxyType = nil
        _isProxy = false
    }
    
    public init(proxyHost host: String, port: Int, type: String?, realm: String?, authenticationMethod: String?) {
        _host = host
        _port = port
        _proxyType = type
        _realm = realm
        _authenticationMethod = authenticationMethod ?? NSURLAuthenticationMethodDefault
        _isProxy = true
        _protocol = nil
    }

    // 一个 get 只读属性. 不是很明白, get privaite set 不也能够达到这个目的吗.
    open var realm: String? {
        return _realm
    }
    
    // 没太明白这个属性的意思, 不过这里有着 fallthrough 的使用.
    open var receivesCredentialSecurely: Bool {
        switch self.protocol {
        // The documentation is ambiguous whether a protection space needs to use the NSURLProtectionSpace… constants, or URL schemes.
        // Allow both.
        case NSURLProtectionSpaceHTTPS: fallthrough
        case "https": fallthrough
        case "ftps":
            return true
            
        default:
            switch authenticationMethod {
            case NSURLAuthenticationMethodDefault: fallthrough
            case NSURLAuthenticationMethodHTTPBasic: fallthrough
            case NSURLAuthenticationMethodHTTPDigest: fallthrough
            case NSURLAuthenticationMethodHTMLForm:
                return false
                
            case NSURLAuthenticationMethodNTLM: fallthrough
            case NSURLAuthenticationMethodNegotiate: fallthrough
            case NSURLAuthenticationMethodClientCertificate: fallthrough
            case NSURLAuthenticationMethodServerTrust:
                return true
                
            default:
                return false
            }
        }
    }
    
    /*!
        @method host
        @abstract Get the proxy host if this is a proxy authentication, or the host from the URL.
        @result The host for this protection space.
    */
    open var host: String {
        return _host
    }
    
    /*!
        @method port
        @abstract Get the proxy port if this is a proxy authentication, or the port from the URL.
        @result The port for this protection space, or 0 if not set.
    */
    open var port: Int {
        return _port
    }
    
    /*!
        @method proxyType
        @abstract Get the type of this protection space, if a proxy
        @result The type string, or nil if not a proxy.
     */
    open var proxyType: String? {
        return _proxyType
    }
    
    // Swift 里面, 有着大量对于保留字的使用, 都增加了 `` 的修饰.
    open var `protocol`: String? {
        return _protocol
    }
    
    /*!
        @method authenticationMethod
        @abstract Get the authentication method to be used for this protection space
        @result The authentication method
    */
    open var authenticationMethod: String {
        return _authenticationMethod
    }

    /*!
        @method isProxy
        @abstract Determine if this authenticating protection space is a proxy server
        @result YES if a proxy, NO otherwise
    */
    open override func isProxy() -> Bool {
        return _isProxy
    }

    /*!
       A string that represents the contents of the URLProtectionSpace Object.
       This property is intended to produce readable output.
    */
    open override var description: String {
        let authMethods: Set<String> = [
            NSURLAuthenticationMethodDefault,
            NSURLAuthenticationMethodHTTPBasic,
            NSURLAuthenticationMethodHTTPDigest,
            NSURLAuthenticationMethodHTMLForm,
            NSURLAuthenticationMethodNTLM,
            NSURLAuthenticationMethodNegotiate,
            NSURLAuthenticationMethodClientCertificate,
            NSURLAuthenticationMethodServerTrust
        ]
        var result = "<\(type(of: self)) \(Unmanaged.passUnretained(self).toOpaque())>: "
        result += "Host:\(host), "

        if let prot = self.protocol {
            result += "Server:\(prot), "
        } else {
            result += "Server:(null), "
        }

        if authMethods.contains(self.authenticationMethod) {
            result += "Auth-Scheme:\(self.authenticationMethod), "
        } else {
            result += "Auth-Scheme:NSURLAuthenticationMethodDefault, "
        }

        if let realm = self.realm {
            result += "Realm:\(realm), "
        } else {
            result += "Realm:(null), "
        }

        result += "Port:\(self.port), "

        if _isProxy {
            result += "Proxy:YES, "
        } else {
            result += "Proxy:NO, "
        }

        if let proxyType = self.proxyType {
            result += "Proxy-Type:\(proxyType), "
        } else {
            result += "Proxy-Type:(null)"
        }
        return result
    }
}

// 上面, 是 URLProtectionSpace 的类的信息.
// 而 Http 的部分, 专门的到了一个 extension 里面.
extension URLProtectionSpace {
    //an internal helper to create a URLProtectionSpace from a HTTPURLResponse 
    static func create(with response: HTTPURLResponse) -> URLProtectionSpace? {
        // Using first challenge, as we don't support multiple challenges yet
        // 真正的创建部分, 被封装了起来.
        guard let challenge = _HTTPURLProtocol._HTTPMessage._Challenge.challenges(from: response).first else {
            return nil
        }
        guard let url = response.url, let host = url.host, let proto = url.scheme, proto == "http" || proto == "https" else {
            return nil
        }
        let port = url.port ?? (proto == "http" ? 80 : 443)
        return URLProtectionSpace(host: host,
                                  port: port,
                                  protocol: proto,
                                  realm: challenge.parameter(withName: "realm")?.value,
                                  authenticationMethod: challenge.authenticationMethod)
    }
}

extension _HTTPURLProtocol._HTTPMessage._Challenge {
    var authenticationMethod: String? {
        if authScheme.caseInsensitiveCompare(_HTTPURLProtocol._HTTPMessage._Challenge.AuthSchemeBasic) == .orderedSame {
            return NSURLAuthenticationMethodHTTPBasic
        } else if authScheme.caseInsensitiveCompare(_HTTPURLProtocol._HTTPMessage._Challenge.AuthSchemeDigest) == .orderedSame {
            return NSURLAuthenticationMethodHTTPDigest
        } else {
            return nil
        }
    }
}

extension URLProtectionSpace {
    
    /*!
        @method distinguishedNames
        @abstract Returns an array of acceptable certificate issuing authorities for client certification authentication. Issuers are identified by their distinguished name and returned as a DER encoded data.
        @result An array of NSData objects.  (Nil if the authenticationMethod is not NSURLAuthenticationMethodClientCertificate)
     */
    @available(*, deprecated, message: "swift-corelibs-foundation does not currently support certificate authentication.")
    public var distinguishedNames: [Data]? { return nil }
    
    /*!
        @method serverTrust
        @abstract Returns a SecTrustRef which represents the state of the servers SSL transaction state
        @result A SecTrustRef from Security.framework.  (Nil if the authenticationMethod is not NSURLAuthenticationMethodServerTrust)
     */
    @available(*, unavailable, message: "swift-corelibs-foundation does not support methods of authentication that rely on the Darwin Security framework.")
    public var serverTrust: Any? { NSUnsupported() }
}
