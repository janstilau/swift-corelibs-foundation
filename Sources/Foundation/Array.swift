// 这里并没有 Array 的实现, 仅仅是 Array 和 NSArray 的桥接的实现.
extension Array : _ObjectiveCBridgeable {
    
    public typealias _ObjectType = NSArray
    
    // 把, 自己的数据, 先装到一个盒子里面封一层, 然后在装到 NSArray 里面.
    public func _bridgeToObjectiveC() -> _ObjectType {
        let ocArray = map { (element: Element) -> AnyObject in
            return __SwiftValue.store(element)
        }
        return NSArray(array: ocArray)
    }
    
    // 把 NSArray 里面的数据, 添加到 result 里面.
    static public func _forceBridgeFromObjectiveC(_ source: _ObjectType, result: inout Array?) {
        result = _unconditionallyBridgeFromObjectiveC(source)
    }
    
    @discardableResult
    static public func _conditionallyBridgeFromObjectiveC(_ source: _ObjectType, result: inout Array?) -> Bool {
        var array = [Element]()
        // NSArray 的 allObjects 本身就是返回 [Any] 的数据了. 在 allObject 里面, 已经有了从 OC 类对象, 到 Any 的转化了.
        // 所以, 这里的关键其实就是 as? 能不能够实现.
        for value in source.allObjects {
            if let v = value as? Element {
                array.append(v)
            } else {
                return false
            }
        }
        result = array
        return true
    }
    
    static public func _unconditionallyBridgeFromObjectiveC(_ source: _ObjectType?) -> Array {
        if let object = source {
            var value: Array<Element>?
            // Swift 里面, 经常使用这种, 使用传出参数版本的函数.
            _conditionallyBridgeFromObjectiveC(object, result: &value)
            return value!
        } else {
            return Array<Element>()
        }
    }
}

