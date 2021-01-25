// 它是 NSObject 的子类.
open class NSNull : NSObject, NSCopying, NSSecureCoding {
    
    open override func copy() -> Any {
        return copy(with: nil)
    }
    
    open func copy(with zone: NSZone? = nil) -> Any {
        return self
    }
    
    public override init() {
        // Nothing to do here
    }
    
    public required init?(coder aDecoder: NSCoder) {
        // Nothing to do here
    }
    
    open func encode(with aCoder: NSCoder) {
        // Nothing to do here
    }
    
    public static var supportsSecureCoding: Bool {
        return true
    }
    
    open override var description: String {
        return "<null>"
    }
    
    open override func isEqual(_ object: Any?) -> Bool {
        return object is NSNull
    }
}

public func ===(lhs: NSNull?, rhs: NSNull?) -> Bool {
    guard let _ = lhs, let _ = rhs else { return false }
    return true
}
