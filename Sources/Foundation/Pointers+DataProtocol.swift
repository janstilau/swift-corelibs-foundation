
extension UnsafeRawBufferPointer : DataProtocol {
    public var regions: CollectionOfOne<UnsafeRawBufferPointer> {
        return CollectionOfOne(self)
    }
}

extension UnsafeBufferPointer : DataProtocol where Element == UInt8 {
    public var regions: CollectionOfOne<UnsafeBufferPointer<Element>> {
        return CollectionOfOne(self)
    }
}
