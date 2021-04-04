#if os(macOS) || os(iOS) || os(watchOS) || os(tvOS)
import SwiftFoundation
#else
import Foundation
#endif

/// `URLResponse` encapsulates the metadata associated
/// with a URL load. Note that URLResponse objects do not contain
/// the actual bytes representing the content of a URL. See
/// `URLSession` for more information about receiving the content
/// data for a URL load.
// 这里非常重要, Response 和 data 是分开的.
// 没有 NSURLResponse 这样的一个东西, URLResponse 就是 NSObject 的一个子类.
open class URLResponse : NSObject, NSSecureCoding, NSCopying {
    
    public required init?(coder aDecoder: NSCoder) {
        guard aDecoder.allowsKeyedCoding else {
            preconditionFailure("Unkeyed coding is unsupported.")
        }
        
        guard let nsurl = aDecoder.decodeObject(of: NSURL.self, forKey: "NS.url") else { return nil }
        self.url = nsurl as URL
        
        
        if let mimetype = aDecoder.decodeObject(of: NSString.self, forKey: "NS.mimeType") {
            self.mimeType = mimetype as String
        }
        
        self.expectedContentLength = aDecoder.decodeInt64(forKey: "NS.expectedContentLength")
        
        if let encodedEncodingName = aDecoder.decodeObject(of: NSString.self, forKey: "NS.textEncodingName") {
            self.textEncodingName = encodedEncodingName as String
        }
        
        if let encodedFilename = aDecoder.decodeObject(of: NSString.self, forKey: "NS.suggestedFilename") {
            self.suggestedFilename = encodedFilename as String
        }
    }
    
    open func encode(with aCoder: NSCoder) {
        guard aCoder.allowsKeyedCoding else {
            preconditionFailure("Unkeyed coding is unsupported.")
        }
        aCoder.encode(self.url?._bridgeToObjectiveC(), forKey: "NS.url")
        aCoder.encode(self.mimeType?._bridgeToObjectiveC(), forKey: "NS.mimeType")
        aCoder.encode(self.expectedContentLength, forKey: "NS.expectedContentLength")
        aCoder.encode(self.textEncodingName?._bridgeToObjectiveC(), forKey: "NS.textEncodingName")
        aCoder.encode(self.suggestedFilename?._bridgeToObjectiveC(), forKey: "NS.suggestedFilename")
    }
    
    open override func copy() -> Any {
        return copy(with: nil)
    }
    
    // 不可变, 直接返回 This
    open func copy(with zone: NSZone? = nil) -> Any {
        return self
    }
    
    open class func localizedString(forStatusCode statusCode: Int) -> String {
        switch statusCode {
        case 100: return "Continue"
        case 101: return "Switching Protocols"
        case 102: return "Processing"
        case 500...599: return "Server Error"
        default: return "Server Error"
        }
    }
    
    // Designated init 方法.
    public init(url: URL, mimeType: String?, expectedContentLength length: Int, textEncodingName name: String?) {
        self.url = url
        self.mimeType = mimeType
        self.expectedContentLength = Int64(length)
        self.textEncodingName = name
        let c = url.lastPathComponent
        self.suggestedFilename = c.isEmpty ? "Unknown" : c
    }
    
    // 这个记录的是资源的路径.
    /*@NSCopying*/ open private(set) var url: URL?
    // 这个记录的是, data 的 type 值.
    open fileprivate(set) var mimeType: String?
    // 这个记录的是, data 的 length 值/
    open fileprivate(set) var expectedContentLength: Int64
    open fileprivate(set) var textEncodingName: String?
    
    // 这个值, 指的是 response data 如果保存的话, 应该使用使用什么名字.
    open fileprivate(set) var suggestedFilename: String?
    
    open override func isEqual(_ value: Any?) -> Bool {
        switch value {
        case let other as URLResponse:
            return self.isEqual(to: other)
        default:
            return false
        }
    }
    
    private func isEqual(to other: URLResponse) -> Bool {
        if self === other {
            return true
        }
        return self.url == other.url &&
            self.expectedContentLength == other.expectedContentLength &&
            self.mimeType == other.mimeType &&
            self.textEncodingName == other.textEncodingName
    }
    
    open override var hash: Int {
        var hasher = Hasher()
        hasher.combine(url)
        hasher.combine(expectedContentLength)
        hasher.combine(mimeType)
        hasher.combine(textEncodingName)
        return hasher.finalize()
    }
}

open class HTTPURLResponse : URLResponse {
    
    // headerFields 就是响应头里面的各种信息.
    public init?(url: URL, statusCode: Int, httpVersion: String?, headerFields: [String : String]?) {
        self.statusCode = statusCode
        self._allHeaderFields = {
            // Canonicalize the header fields by capitalizing the field names, but not X- Headers
            // This matches the behaviour of Darwin.
            guard let headerFields = headerFields else { return [:] }
            var canonicalizedFields: [String: String] = [:]
            
            // 具体的抽取的过程. 主要是 key 的名称的修改.
            for (key, value) in headerFields  {
                if key.isEmpty { continue }
                if key.hasPrefix("x-") || key.hasPrefix("X-") {
                    canonicalizedFields[key] = value
                } else if key.caseInsensitiveCompare("WWW-Authenticate") == .orderedSame {
                    canonicalizedFields["WWW-Authenticate"] = value
                } else {
                    canonicalizedFields[key.capitalized] = value
                }
            }
            return canonicalizedFields
        }()
        
        super.init(url: url, mimeType: nil, expectedContentLength: 0, textEncodingName: nil)
        
        expectedContentLength = getExpectedContentLength(fromHeaderFields: headerFields) ?? -1
        suggestedFilename = getSuggestedFilename(fromHeaderFields: headerFields) ?? "Unknown"
        // 解析的过程, 被包装到了 ContentTypeComponents 的构造方法内了, 然后直接读取构造出来的对象的数据.
        if let type = ContentTypeComponents(headerFields: headerFields) {
            mimeType = type.mimeType.lowercased()
            textEncodingName = type.textEncoding?.lowercased()
        }
    }
    
    public required init?(coder aDecoder: NSCoder) {
        guard aDecoder.allowsKeyedCoding else {
            preconditionFailure("Unkeyed coding is unsupported.")
        }
        
        // coder 的这种方式, 也是先解析自己引入的数据, 然后调用父类的方法
        self.statusCode = aDecoder.decodeInteger(forKey: "NS.statusCode")
        
        if aDecoder.containsValue(forKey: "NS.allHeaderFields") {
            self._allHeaderFields = aDecoder.decodeObject(of: NSDictionary.self, forKey: "NS.allHeaderFields") as! [String: String]
        } else {
            self._allHeaderFields = [:]
        }
        
        super.init(coder: aDecoder)
    }
    
    open override func encode(with aCoder: NSCoder) {
        super.encode(with: aCoder) //Will fail if .allowsKeyedCoding == false
        
        // 先 encode 父类的, 然后自己的.
        aCoder.encode(self.statusCode, forKey: "NS.statusCode")
        aCoder.encode(self.allHeaderFields as NSDictionary, forKey: "NS.allHeaderFields")
        
    }
    
    /// The HTTP status code of the receiver.
    public let statusCode: Int
    
    /// Returns a dictionary containing all the HTTP header fields
    /// of the receiver.
    ///
    /// By examining this header dictionary, clients can see
    /// the "raw" header information which was reported to the protocol
    /// implementation by the HTTP server. This may be of use to
    /// sophisticated or special-purpose HTTP clients.
    ///
    /// - Returns: A dictionary containing all the HTTP header fields of the
    /// receiver.
    ///
    /// - Important: This is an *experimental* change from the
    /// `[NSObject: AnyObject]` type that Darwin Foundation uses.
    private let _allHeaderFields: [String: String]
    public var allHeaderFields: [AnyHashable : Any] {
        _allHeaderFields as [AnyHashable : Any]
    }
    
    public func value(forHTTPHeaderField field: String) -> String? {
        return valueForCaseInsensitiveKey(field, fields: _allHeaderFields)
    }
}

// 使用 content-length, 获取到响应头里面的特定 key 值, 然后转化成为 Int 值.
private func getExpectedContentLength(fromHeaderFields headerFields: [String : String]?) -> Int64? {
    guard
        let f = headerFields,
        let contentLengthS = valueForCaseInsensitiveKey("content-length", fields: f),
        let contentLength = Int64(contentLengthS)
    else { return nil }
    return contentLength
}

/*
 在常规的 HTTP 应答中，Content-Disposition 响应头指示回复的内容该以何种形式展示，是以内联的形式（即网页或者页面的一部分），还是以附件的形式下载并保存到本地。
 在 multipart/form-data 类型的应答消息体中，Content-Disposition 消息头可以被用在 multipart 消息体的子部分中，用来给出其对应字段的相关信息。各个子部分由在Content-Type 中定义的分隔符分隔。用在消息体自身则无实际意义。
 */
private func getSuggestedFilename(fromHeaderFields headerFields: [String : String]?) -> String? {
    guard
        let f = headerFields,
        let contentDisposition = valueForCaseInsensitiveKey("content-disposition", fields: f),
        let field = contentDisposition.httpHeaderParts
    else { return nil }
    
    // 遍历, field.parameters, 寻找 filename 为 key 的值, 然后返回.
    for part in field.parameters where part.attribute == "filename" {
        if let path = part.value {
            return (path as NSString).pathComponents.map{ $0 == "/" ? "" : $0}.joined(separator: "_")
        } else {
            return nil
        }
    }
    return nil
}

// 一个特殊的类型, 它的目的, 主要是想把解析 Content-Type 的过程, 封装到自己的内部.
private struct ContentTypeComponents {
    let mimeType: String // JSON, XML
    let textEncoding: String? // data 的编码方式.
}

// 类里面, 仅仅是数据的定义, 实现的部分, 在 extension 里面.

extension ContentTypeComponents {
    /// Parses the `Content-Type` header field
    ///
    /// `Content-Type: text/html; charset=ISO-8859-4` would result in `("text/html", "ISO-8859-4")`, while
    /// `Content-Type: text/html` would result in `("text/html", nil)`.
    init?(headerFields: [String : String]?) {
        // 连贯的过程, 在 Swift 里面, 用 , 代替了.
        guard
            let f = headerFields,
            let contentType = valueForCaseInsensitiveKey("content-type", fields: f),
            let field = contentType.httpHeaderParts
        else { return nil }
        for parameter in field.parameters where parameter.attribute == "charset" {
            self.mimeType = field.value
            self.textEncoding = parameter.value
            return
        }
        self.mimeType = field.value
        self.textEncoding = nil
    }
}

/// A type with parameters
///
/// RFC 2616 specifies a few types that can have parameters, e.g. `Content-Type`.
/// These are specified like so
/// ```
/// field          = value *( ";" parameter )
/// value          = token
/// ```
/// where parameters are attribute/value as specified by
/// ```
/// parameter               = attribute "=" value
/// attribute               = token
/// value                   = token | quoted-string
/// ```
// 一个特殊的类型, 只在这个文件里使用,
private struct ValueWithParameters {
    struct Parameter {
        let attribute: String
        let value: String?
    }
    let value: String
    let parameters: [Parameter]
}

// 给 String, 添加一个分类, 用来完成这个类业务范围内的某些功能.
// 在 类内添加一个方法, 也可以完成这件事.
private extension String {
    var httpHeaderParts: ValueWithParameters? {
        var type: String?
        var parameters: [ValueWithParameters.Parameter] = []
        let ws = CharacterSet.whitespaces
        
        // 函数内定义方法, 这是一个闭包, 直接修改了外界的值.
        func append(_ string: String) {
            if type == nil {
                type = string
            } else {
                if let r = string.range(of: "=") {
                    let name = String(string[string.startIndex..<r.lowerBound]).trimmingCharacters(in: ws)
                    let value = String(string[r.upperBound..<string.endIndex]).trimmingCharacters(in: ws)
                    parameters.append(ValueWithParameters.Parameter(attribute: name, value: value))
                } else {
                    let name = string.trimmingCharacters(in: ws)
                    parameters.append(ValueWithParameters.Parameter(attribute: name, value: nil))
                }
            }
        }
        
        
        //------前面是数据部分, 下面是解析部分------//
        // 这种代码管理的方式真的好吗 ???
        
        enum State {
            case nonQuoted(String)
            case nonQuotedEscaped(String)
            case quoted(String)
            case quotedEscaped(String)
        }
        
        // 特殊的变量, 先定义出来.
        let escape = UnicodeScalar(0x5c)!    //  \
        let quote = UnicodeScalar(0x22)!     //  "
        let separator = UnicodeScalar(0x3b)! //  ;
        
        var state = State.nonQuoted("")
        for next in unicodeScalars {
            // next 就是字符, state 是上次设置状态.
            // for 循环不断的取值, 然后根据状态和 next 的值, 进行后续的操作.
            // 状态里面的 s, 是目前已经拼接的值.
            // 通过 switch 这种方式, 让代码很简练.
            switch (state, next) {
            case (.nonQuoted(let s), separator):
                append(s)
                state = .nonQuoted("")
            case (.nonQuoted(let s), escape):
                state = .nonQuotedEscaped(s + String(next))
            case (.nonQuoted(let s), quote):
                state = .quoted(s)
            case (.nonQuoted(let s), _):
                state = .nonQuoted(s + String(next))
                
            case (.nonQuotedEscaped(let s), _):
                state = .nonQuoted(s + String(next))
                
            case (.quoted(let s), quote):
                state = .nonQuoted(s)
            case (.quoted(let s), escape):
                state = .quotedEscaped(s + String(next))
            case (.quoted(let s), _):
                state = .quoted(s + String(next))
                
            case (.quotedEscaped(let s), _):
                state = .quoted(s + String(next))
            }
        }
        switch state {
        case .nonQuoted(let s): append(s)
        case .nonQuotedEscaped(let s): append(s)
        case .quoted(let s): append(s)
        case .quotedEscaped(let s): append(s)
        }
        guard let t = type else { return nil }
        return ValueWithParameters(value: t, parameters: parameters)
    }
}

// valueForCaseInsensitiveKey 是一个通用的方法, 就是通过 key , 去后面的 fileds 里面进行取值.
// 各个 getSepecificKey 就是通过这个方法, 进行值的获取工作. 然后在获取到 String 之后, 转化为自己需要的数据类型的形式.
private func valueForCaseInsensitiveKey(_ key: String, fields: [String: String]) -> String? {
    let kk = key.lowercased()
    for (k, v) in fields {
        if k.lowercased() == kk {
            return v
        }
    }
    return nil
}
