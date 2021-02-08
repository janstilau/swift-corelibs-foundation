// RawRepresentable 表明了, 他就是字符串的封装而已.
public struct HTTPCookiePropertyKey : RawRepresentable, Equatable, Hashable {
    public private(set) var rawValue: String
    public init(_ rawValue: String) {
        self.rawValue = rawValue
    }
    public init(rawValue: String) {
        self.rawValue = rawValue
    }
}

// 在 OC 时代, 这些东西都是 String, 但是在 Swift 时代, 都包装在自己的类型里面, 是这个特殊类型的一个 static 的特殊变量.
/*
 NSString * const NSHTTPCookieComment = @"Comment";
 NSString * const NSHTTPCookieCommentURL = @"CommentURL";
 NSString * const NSHTTPCookieDiscard = @"Discard";
 NSString * const NSHTTPCookieDomain = @"Domain";
 NSString * const NSHTTPCookieExpires = @"Expires";
 NSString * const NSHTTPCookieMaximumAge = @"MaximumAge";
 NSString * const NSHTTPCookieName = @"Name";
 NSString * const NSHTTPCookieOriginURL = @"OriginURL";
 NSString * const NSHTTPCookiePath = @"Path";
 NSString * const NSHTTPCookiePort = @"Port";
 NSString * const NSHTTPCookieSecure = @"Secure";
 NSString * const NSHTTPCookieValue = @"Value";
 NSString * const NSHTTPCookieVersion = @"Version";
 static NSString * const HTTPCookieHTTPOnly = @"HTTPOnly";
 */
// 更好的组织方式, 所有的类相关的值, 通过类型下的 static 表明了, 这是类相关的数据. 比手动增加前缀要好太多了.
// 更好的组织方式, 特殊量放到一个 extension 里面. Extension 代码段, 没有其他的无关的逻辑.
extension HTTPCookiePropertyKey {
    public static let name = HTTPCookiePropertyKey(rawValue: "Name")
    public static let value = HTTPCookiePropertyKey(rawValue: "Value")
    public static let originURL = HTTPCookiePropertyKey(rawValue: "OriginURL")
    public static let version = HTTPCookiePropertyKey(rawValue: "Version")
    public static let domain = HTTPCookiePropertyKey(rawValue: "Domain")
    public static let path = HTTPCookiePropertyKey(rawValue: "Path")
    public static let secure = HTTPCookiePropertyKey(rawValue: "Secure")
    public static let expires = HTTPCookiePropertyKey(rawValue: "Expires")
    public static let comment = HTTPCookiePropertyKey(rawValue: "Comment")
    public static let commentURL = HTTPCookiePropertyKey(rawValue: "CommentURL")
    public static let discard = HTTPCookiePropertyKey(rawValue: "Discard")
    public static let maximumAge = HTTPCookiePropertyKey(rawValue: "Max-Age")
    public static let port = HTTPCookiePropertyKey(rawValue: "Port")
    internal static let created = HTTPCookiePropertyKey(rawValue: "Created")
    static let httpOnly = HTTPCookiePropertyKey(rawValue: "HttpOnly")
}

internal extension HTTPCookiePropertyKey {
    // 如果是成员变量, 应该增加 lazy
    // 但是 static 的值, 默认就是 lazy 的.
    static private let _setCookieAttributes: [String: HTTPCookiePropertyKey] = {
        let validProperties: [HTTPCookiePropertyKey] = [
            .expires, .maximumAge, .domain, .path, .secure, .comment,
            .commentURL, .discard, .port, .version, .httpOnly
        ]
        let canonicalNames = validProperties.map { $0.rawValue.lowercased() }
        // RawRepresentable 提供了一种通用的进行对象和数据之间的转化工作.
        return Dictionary(uniqueKeysWithValues: zip(canonicalNames, validProperties))
    }()
    
  
    // 如果我来写, 可能就是 contains 判断了.
    // 这里使用 switch, 更加的 Swift 风格
    init?(attributeName: String) {
        let canonical = attributeName.lowercased()
        switch HTTPCookiePropertyKey._setCookieAttributes[canonical] {
        case let property?: self = property
        case nil: return nil
        }
    }
}

open class HTTPCookie : NSObject {
    
    // 在 OC 的版本里面, 所有的东西, 都存到了一个 NSDictionary 上, 不同的 value 的 get, 就是使用特殊的 key 去查询.
    // 在这里, 都显式地定义出来了, 并且变为了 get.
    let _comment: String?
    let _commentURL: URL?
    let _domain: String
    let _expiresDate: Date?
    let _HTTPOnly: Bool
    let _secure: Bool
    let _sessionOnly: Bool
    let _name: String
    let _path: String
    let _portList: [NSNumber]?
    let _value: String
    let _version: Int
    var _properties: [HTTPCookiePropertyKey : Any]
    
    // See: https://tools.ietf.org/html/rfc2616#section-3.3.1
    // Sun, 06 Nov 1994 08:49:37 GMT  ; RFC 822, updated by RFC 1123
    static let _formatter1: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd MMM yyyy HH:mm:ss O"
        formatter.timeZone = TimeZone(abbreviation: "GMT")
        return formatter
    }()
    // Sun Nov  6 08:49:37 1994       ; ANSI C's asctime() format
    static let _formatter2: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE MMM d HH:mm:ss yyyy"
        formatter.timeZone = TimeZone(abbreviation: "GMT")
        return formatter
    }()
    // Sun, 06-Nov-1994 08:49:37 GMT  ; Tomcat servers sometimes return cookies in this format
    static let _formatter3: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "EEE, dd-MMM-yyyy HH:mm:ss O"
        formatter.timeZone = TimeZone(abbreviation: "GMT")
        return formatter
    }()
    static let _allFormatters: [DateFormatter]
        = [_formatter1, _formatter2, _formatter3]
    
    // HttpCookie 的初始化方法. 其实就是根据一个字典, 不断进行自己的各个成员变量的初始化就可以了.
    public init?(properties: [HTTPCookiePropertyKey : Any]) {
        func stringValue(_ strVal: Any?) -> String? {
            if let subStr = strVal as? Substring {
                return String(subStr)
            }
            return strVal as? String
        }
        
        guard
            let path = stringValue(properties[.path]),
            let name = stringValue(properties[.name]),
            let value = stringValue(properties[.value])
        else {
            return nil
        }
        
        let canonicalDomain: String
        if let domain = properties[.domain] as? String {
            canonicalDomain = domain
        } else if let originURL = properties[.originURL] as? URL,
                  let host = originURL.host {
            canonicalDomain = host
        } else {
            return nil
        }
        
        _path = path
        _name = name
        _value = value
        _domain = canonicalDomain.lowercased()
        
        if let secureString = properties[.secure] as? String, !secureString.isEmpty {
            _secure = true
        } else {
            _secure = false
        }
        
        let version: Int
        if let versionString = properties[.version] as? String, versionString == "1" {
            version = 1
        } else {
            version = 0
        }
        _version = version
        
        if let portString = properties[.port] as? String {
            let portList = portString.split(separator: ",")
                .compactMap { Int(String($0)) }
                .map { NSNumber(value: $0) }
            if version == 1 {
                _portList = portList
            } else {
                _portList = portList.count > 0 ? [portList[0]] : nil
            }
        } else {
            _portList = nil
        }
        
        var expDate: Date? = nil
        // Maximum-Age is preferred over expires-Date but only version 1 cookies use Maximum-Age
        if let maximumAge = properties[.maximumAge] as? String,
           let secondsFromNow = Int(maximumAge) {
            if version == 1 {
                expDate = Date(timeIntervalSinceNow: Double(secondsFromNow))
            }
        } else {
            let expiresProperty = properties[.expires]
            if let date = expiresProperty as? Date {
                expDate = date
            } else if let dateString = expiresProperty as? String {
                let results = HTTPCookie._allFormatters.compactMap { $0.date(from: dateString) }
                expDate = results.first
            }
        }
        _expiresDate = expDate
        
        if let discardString = properties[.discard] as? String {
            _sessionOnly = discardString == "TRUE"
        } else {
            _sessionOnly = properties[.maximumAge] == nil && version >= 1
        }
        
        _comment = properties[.comment] as? String
        if let commentURL = properties[.commentURL] as? URL {
            _commentURL = commentURL
        } else if let commentURL = properties[.commentURL] as? String {
            _commentURL = URL(string: commentURL)
        } else {
            _commentURL = nil
        }
        
        if let httpOnlyString = properties[.httpOnly] as? String {
            _HTTPOnly = httpOnlyString == "TRUE"
        } else {
            _HTTPOnly = false
        }
        
        _properties = [
            .created : Date().timeIntervalSinceReferenceDate, // Cocoa Compatibility
            .discard : _sessionOnly,
            .domain : _domain,
            .name : _name,
            .path : _path,
            .secure : _secure,
            .value : _value,
            .version : _version
        ]
        if let comment = properties[.comment] {
            _properties[.comment] = comment
        }
        if let commentURL = properties[.commentURL] {
            _properties[.commentURL] = commentURL
        }
        if let expires = properties[.expires] {
            _properties[.expires] = expires
        }
        if let maximumAge = properties[.maximumAge] {
            _properties[.maximumAge] = maximumAge
        }
        if let originURL = properties[.originURL] {
            _properties[.originURL] = originURL
        }
        if let _portList = _portList {
            _properties[.port] = _portList
        }
    }
    
    // 把 Cookie 的值, 变为一个 String Dict.
    open class func requestHeaderFields(with cookies: [HTTPCookie]) -> [String : String] {
        var cookieString = cookies.reduce("") {
            (sum, next) -> String in
            return sum + "\(next._name)=\(next._value); "
        }
        if ( cookieString.length > 0 ) {
            cookieString.removeLast()
            cookieString.removeLast()
        }
        if cookieString == "" {
            return [:]
        } else {
            return ["Cookie": cookieString]
        }
    }
    
    // Cookie 的解析过程. 传过来一个 Response, 返回对应的 Cookie
    open class func cookies(withResponseHeaderFields headerFields: [String : String], for URL: URL) -> [HTTPCookie] {
        
        guard let cookies: String = headerFields["Set-Cookie"]  else { return [] }
        
        var httpCookies: [HTTPCookie] = []
        
        // Let's do old school parsing, which should allow us to handle the
        // embedded commas correctly.
        var idx: String.Index = cookies.startIndex
        let end: String.Index = cookies.endIndex
        while idx < end {
            // Skip leading spaces.
            while idx < end && cookies[idx].isSpace {
                idx = cookies.index(after: idx)
            }
            let cookieStartIdx: String.Index = idx
            var cookieEndIdx: String.Index = idx
            
            while idx < end {
                // Scan to the next comma, but check that the comma is not a
                // legal comma in a value, by looking ahead for the token,
                // which indicates the comma was separating cookies.
                let cookiesRest = cookies[idx..<end]
                if let commaIdx = cookiesRest.firstIndex(of: ",") {
                    // We are looking for WSP* TOKEN_CHAR+ WSP* '='
                    var lookaheadIdx = cookies.index(after: commaIdx)
                    // Skip whitespace
                    while lookaheadIdx < end && cookies[lookaheadIdx].isSpace {
                        lookaheadIdx = cookies.index(after: lookaheadIdx)
                    }
                    // Skip over the token characters
                    var tokenLength = 0
                    while lookaheadIdx < end && cookies[lookaheadIdx].isTokenCharacter {
                        lookaheadIdx = cookies.index(after: lookaheadIdx)
                        tokenLength += 1
                    }
                    // Skip whitespace
                    while lookaheadIdx < end && cookies[lookaheadIdx].isSpace {
                        lookaheadIdx = cookies.index(after: lookaheadIdx)
                    }
                    // Check there was a token, and there's an equals.
                    if lookaheadIdx < end && cookies[lookaheadIdx] == "=" && tokenLength > 0 {
                        // We found a token after the comma, this is a cookie
                        // separator, and not an embedded comma.
                        idx = cookies.index(after: commaIdx)
                        cookieEndIdx = commaIdx
                        break
                    }
                    // Otherwise, keep scanning from the comma.
                    idx = cookies.index(after: commaIdx)
                    cookieEndIdx = idx
                } else {
                    // No more commas, skip to the end.
                    idx = end
                    cookieEndIdx = end
                    break
                }
            }
            
            if cookieEndIdx <= cookieStartIdx {
                continue
            }
            
            if let aCookie = createHttpCookie(url: URL, cookie: String(cookies[cookieStartIdx..<cookieEndIdx])) {
                httpCookies.append(aCookie)
            }
        }
        
        return httpCookies
    }
    
    private class func createHttpCookie(url: URL, cookie: String) -> HTTPCookie? {
        var properties: [HTTPCookiePropertyKey : Any] = [:]
        let scanner = Scanner(string: cookie)
        
        guard let nameValuePair = scanner.scanUpToString(";") else {
            // if the scanner does not read anything, there's no cookie
            return nil
        }
        
        guard case (let name?, let value?) = splitNameValue(nameValuePair) else {
            return nil
        }
        
        properties[.name] = name
        properties[.value] = value
        properties[.originURL] = url
        
        while scanner.scanString(";") != nil {
            if let attribute = scanner.scanUpToString(";") {
                switch splitNameValue(attribute) {
                case (nil, _):
                    // ignore empty attribute names
                    break
                case (let name?, nil):
                    switch HTTPCookiePropertyKey(attributeName: name) {
                    case .secure?:
                        properties[.secure] = "TRUE"
                    case .discard?:
                        properties[.discard] = "TRUE"
                    case .httpOnly?:
                        properties[.httpOnly] = "TRUE"
                    default:
                        // ignore unknown attributes
                        break
                    }
                case (let name?, let value?):
                    switch HTTPCookiePropertyKey(attributeName: name) {
                    case .comment?:
                        properties[.comment] = value
                    case .commentURL?:
                        properties[.commentURL] = value
                    case .domain?:
                        properties[.domain] = value
                    case .maximumAge?:
                        properties[.maximumAge] = value
                    case .path?:
                        properties[.path] = value
                    case .port?:
                        properties[.port] = value
                    case .version?:
                        properties[.version] = value
                    case .expires?:
                        properties[.expires] = value
                    default:
                        // ignore unknown attributes
                        break
                    }
                }
            }
        }
        
        if let domain = properties[.domain] as? String {
            // The provided domain string has to be prepended with a dot,
            // because the domain field indicates that it can be sent
            // subdomains of the domain (but only if it is not an IP address).
            if (!domain.hasPrefix(".") && !isIPv4Address(domain)) {
                properties[.domain] = ".\(domain)"
            }
        } else {
            // If domain wasn't provided, extract it from the URL. No dots in
            // this case, only exact matching.
            properties[.domain] = url.host
        }
        // Always lowercase the domain.
        if let domain = properties[.domain] as? String {
            properties[.domain] = domain.lowercased()
        }
        
        // the default Path is "/"
        if let path = properties[.path] as? String, path.first == "/" {
            // do nothing
        } else {
            properties[.path] = "/"
        }
        
        return HTTPCookie(properties: properties)
    }
    
    private class func splitNameValue(_ pair: String) -> (name: String?, value: String?) {
        let scanner = Scanner(string: pair)
        
        guard let name = scanner.scanUpToString("=")?.trim(),
              !name.isEmpty else {
            // if the scanner does not read anything, or the trimmed name is
            // empty, there's no name=value
            return (nil, nil)
        }
        
        guard scanner.scanString("=") != nil else {
            // if the scanner does not find =, there's no value
            return (name, nil)
        }
        
        let location = scanner.scanLocation
        let value = String(pair[pair.index(pair.startIndex, offsetBy: location)..<pair.endIndex]).trim()
        
        return (name, value)
    }
    
    private class func isIPv4Address(_ string: String) -> Bool {
        var x = in_addr()
        return inet_pton(AF_INET, string, &x) == 1
    }
    open var properties: [HTTPCookiePropertyKey : Any]? {
        return _properties
    }
    open var version: Int {
        return _version
    }
    open var name: String {
        return _name
    }
    open var value: String {
        return _value
    }
    open var expiresDate: Date? {
        return _expiresDate
    }
    open var isSessionOnly: Bool {
        return _sessionOnly
    }
    open var domain: String {
        return _domain
    }
    open var path: String {
        return _path
    }
    open var isSecure: Bool {
        return _secure
    }
    open var isHTTPOnly: Bool {
        return _HTTPOnly
    }
    open var comment: String? {
        return _comment
    }
    open var commentURL: URL? {
        return _commentURL
    }
    open var portList: [NSNumber]? {
        return _portList
    }
}

fileprivate extension String {
    func trim() -> String {
        return self.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

fileprivate extension Character {
    var isSpace: Bool {
        return self == " " || self == "\t" || self == "\n" || self == "\r"
    }
    
    var isTokenCharacter: Bool {
        guard let asciiValue = self.asciiValue else {
            return false
        }
        
        // CTL, 0-31 and DEL (127)
        if asciiValue <= 31 || asciiValue >= 127 {
            return false
        }
        
        let nonTokenCharacters = "()<>@,;:\\\"/[]?={} \t"
        return !nonTokenCharacters.contains(self)
    }
}
