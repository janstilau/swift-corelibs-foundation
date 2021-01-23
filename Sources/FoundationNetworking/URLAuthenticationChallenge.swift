#if os(macOS) || os(iOS) || os(watchOS) || os(tvOS)
import SwiftFoundation
#else
import Foundation
#endif

/*
 This protocol is only for use with the legacy NSURLConnection and NSURLDownload classes. It should not be used with URLSession-based code, for which you respond to authentication challenges by passing URLSession.
 AuthChallengeDisposition constants to the provided completion handler blocks.
 */

/*
 Protocol 不断的解析数据, Response 解析完成之后, 发现需要验证, 就组装一个 URLAuthenticationChallenge, 同时, 将自己作为这个 URLAuthenticationChallenge 的 sender, 交给自己的 client 进行处理.
 自己作为 URLAuthenticationChallenge 的 sender , 完成下面的这些方法, 在这些方法里面, 进行状态的改变.
 clietn 里面, 是交给 URLConnection, 或者 session 的 delegate 处理. 这些 delegate, 应该调用 sender 协议里面的方法, 标明对于这个 Challenge 的处理意见.
 代码继续向下执行, 根据 protocol 的状态, 判断 Challenge 的应对策略, 不过没能成功, 就 protocol stoploading.
 所以, 这种方式, 其实是将 组建 Challenge, 交付 Challenge, 响应 Challenge, 判断 Challenge 应对, 这四块代码, 分成了三个部分.
 组建, 判断 14 代码是在一起的, 但是中间的过程, 是两个协议. 现在 session 的 AuthChallengeDisposition, 将中间两个过程合在了一起, 让逻辑更加的清晰.
 */
public protocol URLAuthenticationChallengeSender : NSObjectProtocol {
    
    
    /*!
     @method useCredential:forAuthenticationChallenge:
     */
    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge)
    
    
    /*!
     @method continueWithoutCredentialForAuthenticationChallenge:
     */
    func continueWithoutCredential(for challenge: URLAuthenticationChallenge)
    
    
    /*!
     @method cancelAuthenticationChallenge:
     */
    func cancel(_ challenge: URLAuthenticationChallenge)
    
    
    /*!
     @method performDefaultHandlingForAuthenticationChallenge:
     */
    func performDefaultHandling(for challenge: URLAuthenticationChallenge)
    
    
    /*!
     @method rejectProtectionSpaceAndContinueWithChallenge:
     */
    func rejectProtectionSpaceAndContinue(with challenge: URLAuthenticationChallenge)
}

/*!
 @class URLAuthenticationChallenge
 @discussion This class represents an authentication challenge. It
 provides all the information about the challenge, and has a method
 to indicate when it's done.
 */
open class URLAuthenticationChallenge : NSObject {
    
    private let _protectionSpace: URLProtectionSpace // 哪块需要验证. 主要是 host + path
    private let _proposedCredential: URLCredential? // 应对验证的证书
    private let _previousFailureCount: Int // 失败次数
    private let _failureResponse: URLResponse? // 原始响应, 根据这个响应, 组建的这个 Challenge
    private let _error: Error?
    private let _sender: URLAuthenticationChallengeSender // 这个 Challenge 的应对办法.
    
    /*!
     @method initWithProtectionSpace:proposedCredential:previousFailureCount:failureResponse:error:
     @abstract Initialize an authentication challenge
     @param space The URLProtectionSpace to use
     @param credential The proposed URLCredential for this challenge, or nil
     @param previousFailureCount A count of previous failures attempting access.
     @param response The URLResponse for the authentication failure, if applicable, else nil
     @param error The NSError for the authentication failure, if applicable, else nil
     @result An authentication challenge initialized with the specified parameters
     */
    public init(protectionSpace space: URLProtectionSpace, proposedCredential credential: URLCredential?, previousFailureCount: Int, failureResponse response: URLResponse?, error: Error?, sender: URLAuthenticationChallengeSender) {
        self._protectionSpace = space
        self._proposedCredential = credential
        self._previousFailureCount = previousFailureCount
        self._failureResponse = response
        self._error = error
        self._sender = sender
    }
    
    
    /*!
     @method initWithAuthenticationChallenge:
     @abstract Initialize an authentication challenge copying all parameters from another one.
     @param challenge
     @result A new challenge initialized with the parameters from the passed in challenge
     @discussion This initializer may be useful to subclassers that want to proxy
     one type of authentication challenge to look like another type.
     */
    public init(authenticationChallenge challenge: URLAuthenticationChallenge, sender: URLAuthenticationChallengeSender) {
        self._protectionSpace = challenge.protectionSpace
        self._proposedCredential = challenge.proposedCredential
        self._previousFailureCount = challenge.previousFailureCount
        self._failureResponse = challenge.failureResponse
        self._error = challenge.error
        self._sender = sender
    }
    
    
    /*!
     @method protectionSpace
     @abstract Get a description of the protection space that requires authentication
     @result The protection space that needs authentication
     */
    /*@NSCopying*/ open var protectionSpace: URLProtectionSpace {
        get {
            return _protectionSpace
        }
    }
    
    
    /*!
     @method proposedCredential
     @abstract Get the proposed credential for this challenge
     @result The proposed credential
     @discussion proposedCredential may be nil, if there is no default
     credential to use for this challenge (either stored or in the
     URL). If the credential is not nil and returns YES for
     hasPassword, this means the NSURLConnection thinks the credential
     is ready to use as-is. If it returns NO for hasPassword, then the
     credential is not ready to use as-is, but provides a default
     username the client could use when prompting.
     */
    /*@NSCopying*/ open var proposedCredential: URLCredential? {
        get {
            return _proposedCredential
        }
    }
    
    
    /*!
     @method previousFailureCount
     @abstract Get count of previous failed authentication attempts
     @result The count of previous failures
     */
    open var previousFailureCount: Int {
        get {
            return _previousFailureCount
        }
    }
    
    
    /*!
     @method failureResponse
     @abstract Get the response representing authentication failure.
     @result The failure response or nil
     @discussion If there was a previous authentication failure, and
     this protocol uses responses to indicate authentication failure,
     then this method will return the response. Otherwise it will
     return nil.
     */
    /*@NSCopying*/ open var failureResponse: URLResponse? {
        get {
            return _failureResponse
        }
    }
    
    
    /*!
     @method error
     @abstract Get the error representing authentication failure.
     @discussion If there was a previous authentication failure, and
     this protocol uses errors to indicate authentication failure,
     then this method will return the error. Otherwise it will
     return nil.
     */
    /*@NSCopying*/ open var error: Error? {
        get {
            return _error
        }
    }
    
    
    /*!
     @method sender
     @abstract Get the sender of this challenge
     @result The sender of the challenge
     @discussion The sender is the object you should reply to when done processing the challenge.
     */
    open var sender: URLAuthenticationChallengeSender? {
        get {
            return _sender
        }
    }
}

class URLSessionAuthenticationChallengeSender : NSObject, URLAuthenticationChallengeSender {
    func cancel(_ challenge: URLAuthenticationChallenge) {
        fatalError("swift-corelibs-foundation only supports URLSession; for challenges coming from URLSession, please implement the appropriate URLSessionTaskDelegate methods rather than using the sender argument.")
    }
    
    func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {
        fatalError("swift-corelibs-foundation only supports URLSession; for challenges coming from URLSession, please implement the appropriate URLSessionTaskDelegate methods rather than using the sender argument.")
    }
    
    func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {
        fatalError("swift-corelibs-foundation only supports URLSession; for challenges coming from URLSession, please implement the appropriate URLSessionTaskDelegate methods rather than using the sender argument.")
    }
    
    func performDefaultHandling(for challenge: URLAuthenticationChallenge) {
        fatalError("swift-corelibs-foundation only supports URLSession; for challenges coming from URLSession, please implement the appropriate URLSessionTaskDelegate methods rather than using the sender argument.")
    }
    
    func rejectProtectionSpaceAndContinue(with challenge: URLAuthenticationChallenge) {
        fatalError("swift-corelibs-foundation only supports URLSession; for challenges coming from URLSession, please implement the appropriate URLSessionTaskDelegate methods rather than using the sender argument.")
    }
}
