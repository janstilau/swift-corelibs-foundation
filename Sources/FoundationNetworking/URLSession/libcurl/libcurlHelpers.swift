@_implementationOnly import CoreFoundation
@_implementationOnly import CFURLSessionInterface

//TODO: Move things in this file?


internal func initializeLibcurl() {
    try! CFURLSessionInit().asError()
}


internal extension String {
    /// Create a string by a buffer of UTF 8 code points that is not zero
    /// terminated.
    init?(utf8Buffer: UnsafeBufferPointer<UInt8>) {
        var bufferIterator = utf8Buffer.makeIterator()
        var codec = UTF8()
        var result: String = ""
        iter: repeat {
            switch codec.decode(&bufferIterator) {
            case .scalarValue(let scalar):
                result.append(String(describing: scalar))
            case .error:
                return nil
            case .emptyInput:
                break iter
            }
        } while true
        self.init(stringLiteral: result)
    }
}
