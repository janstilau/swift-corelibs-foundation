// 这些, 都是类的设计者的设定而已, 没有什么道理.
extension URLCredential {
    public enum Persistence : UInt {
        case none // 不存
        case forSession // 内存里面 session 可读取
        case permanent // 存到硬盘上
        
        @available(*, deprecated, message: "Synchronizable credential storage is not available in swift-corelibs-foundation. If you rely on synchronization for your functionality, please audit your code.")
        case synchronizable // 存到硬盘上, 并且会和服务器端交互.
    }
}


// The URL Loading System supports password-based user credentials, certificate-based user credentials, and certificate-based server credentials.
// 这个类, 仅仅完成了 User Password 的相关概念的建设, 没有服务器证书的解析. 
open class URLCredential : NSObject, NSSecureCoding, NSCopying {
    
    private var _user : String
    private var _password : String
    private var _persistence : Persistence
    
    public init(user: String, password: String, persistence: Persistence) {
        _user = user
        _password = password
        _persistence = persistence
        super.init()
    }
    
    
    // 在这个框架里面, 一切都是用的 NS 进行的存储, 然后转为了 Swift 的数据类.
    public required init?(coder aDecoder: NSCoder) {
        guard aDecoder.allowsKeyedCoding else {
            preconditionFailure("Unkeyed coding is unsupported.")
        }
        
        func bridgeString(_ value: NSString) -> String? {
            return String._unconditionallyBridgeFromObjectiveC(value)
        }
        
        let encodedUser = aDecoder.decodeObject(forKey: "NS._user") as! NSString
        self._user = bridgeString(encodedUser)!
        
        let encodedPassword = aDecoder.decodeObject(forKey: "NS._password") as! NSString
        self._password = bridgeString(encodedPassword)!
        
        let encodedPersistence = aDecoder.decodeObject(forKey: "NS._persistence") as! NSNumber
        self._persistence = Persistence(rawValue: encodedPersistence.uintValue)!
    }
    
    open func encode(with aCoder: NSCoder) {
        guard aCoder.allowsKeyedCoding else {
            preconditionFailure("Unkeyed coding is unsupported.")
        }
        
        aCoder.encode(self._user._bridgeToObjectiveC(), forKey: "NS._user")
        aCoder.encode(self._password._bridgeToObjectiveC(), forKey: "NS._password")
        aCoder.encode(self._persistence.rawValue._bridgeToObjectiveC(), forKey: "NS._persistence")
    }
    
    static public var supportsSecureCoding: Bool {
        return true
    }
    
    open override func copy() -> Any {
        return copy(with: nil)
    }
    
    open func copy(with zone: NSZone? = nil) -> Any {
        return self 
    }
    
    open override func isEqual(_ object: Any?) -> Bool {
        guard let other = object as? URLCredential else { return false }
        return other === self
            || (other._user == self._user
                && other._password == self._password
                && other._persistence == self._persistence)
    }
    
    /*!
        @method persistence
        @abstract Determine whether this credential is or should be stored persistently
        @result A value indicating whether this credential is stored permanently, per session or not at all.
     */
    open var persistence: Persistence { return _persistence }
    
    /*!
        @method user
        @abstract Get the username
        @result The user string
     */
    open var user: String? { return _user }
    
    /*!
        @method password
        @abstract Get the password
        @result The password string
        @discussion This method might actually attempt to retrieve the
        password from an external store, possible resulting in prompting,
        so do not call it unless needed.
     */
    open var password: String? { return _password }

    /*!
        @method hasPassword
        @abstract Find out if this credential has a password, without trying to get it
        @result YES if this credential has a password, otherwise NO
        @discussion If this credential's password is actually kept in an
        external store, the password method may return nil even if this
        method returns YES, since getting the password may fail, or the
        user may refuse access.
     */
    open var hasPassword: Bool {
        // Currently no support for SecTrust/SecIdentity, always return true
        return true
    }
}
