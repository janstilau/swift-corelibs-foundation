@_implementationOnly import CoreFoundation

extension CFKeyedArchiverUID : _NSBridgeable {
    typealias NSType = _NSKeyedArchiverUID
    
    internal var _nsObject: NSType { return unsafeBitCast(self, to: NSType.self) }
}

internal class _NSKeyedArchiverUID : NSObject {
    typealias CFType = CFKeyedArchiverUID
    internal var _base = _CFInfo(typeID: _CFKeyedArchiverUIDGetTypeID())
    internal var value : UInt32 = 0
    
    internal var _cfObject : CFType {
        return unsafeBitCast(self, to: CFType.self)
    }
    
    override open var _cfTypeID: CFTypeID {
        return _CFKeyedArchiverUIDGetTypeID()
    }
    
    open override var hash: Int {
        return Int(bitPattern: CFHash(_cfObject as CFTypeRef?))
    }
    
    open override func isEqual(_ object: Any?) -> Bool {
        // no need to compare these?
        return false
    }
    
    init(value : UInt32) {
        self.value = value
    }
    
    deinit {
        _CFDeinit(self)
    }
}
