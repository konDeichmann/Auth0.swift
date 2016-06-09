// OAuth2.swift
//
// Copyright (c) 2016 Auth0 (http://auth0.com)
//
// Permission is hereby granted, free of charge, to any person obtaining a copy
// of this software and associated documentation files (the "Software"), to deal
// in the Software without restriction, including without limitation the rights
// to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
// copies of the Software, and to permit persons to whom the Software is
// furnished to do so, subject to the following conditions:
//
// The above copyright notice and this permission notice shall be included in
// all copies or substantial portions of the Software.
//
// THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
// IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
// FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
// AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
// LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
// OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN
// THE SOFTWARE.

import UIKit
import SafariServices

/**
 Auth0 iOS component for authenticating with OAuth2
 
 ```
 Auth0.oauth2(clientId: clientId, domain: "samples.auth0.com")
 ```

 - parameter clientId: id of your Auth0 client
 - parameter domain:   name of your Auth0 domain

 - returns: Auth0 OAuth2 component
 */
public func oauth2(clientId clientId: String, domain: String) -> OAuth2 {
    return OAuth2(clientId: clientId, url: NSURL.a0_url(domain))
}

/// OAuth2 Authentication using Auth0
public class OAuth2 {

    private static let NoBundleIdentifier = "com.auth0.this-is-no-bundle"

    let clientId: String
    let url: NSURL
    let presenter: ControllerModalPresenter
    let storage: SessionStorage
    var state = generateDefaultState()
    var parameters: [String: String] = [:]
    var universalLink = false
    var usePKCE = true

    public convenience init(clientId: String, url: NSURL, presenter: ControllerModalPresenter = ControllerModalPresenter()) {
        self.init(clientId: clientId, url: url, presenter: presenter, storage: SessionStorage.sharedInstance)
    }

    init(clientId: String, url: NSURL, presenter: ControllerModalPresenter, storage: SessionStorage) {
        self.clientId = clientId
        self.url = url
        self.presenter = presenter
        self.storage = storage
    }
    /**
     For redirect url instead of a custom scheme it will use `https` and iOS 9 Universal Links.
     
     Before enabling this flag you'll need to configure Universal Links

     - returns: the same OAuth2 instance to allow method chaining
     */
    public func useUniversalLink() -> OAuth2 {
        self.universalLink = true
        return self
    }

    /**
     Specify a connection name to be used to authenticate.
     
     By default no connection is specified, so the hosted login page will be displayed

     - parameter connection: name of the connection to use

     - returns: the same OAuth2 instance to allow method chaining
     */
    public func connection(connection: String) -> OAuth2 {
        self.parameters["connection"] = connection
        return self
    }

    /**
     Scopes that will be requested during auth

     - parameter scope: a scope value like: `openid email`

     - returns: the same OAuth2 instance to allow method chaining
     */
    public func scope(scope: String) -> OAuth2 {
        self.parameters["scope"] = scope
        return self
    }

    /**
     State value that will be echoed after authentication 
     in order to check that the response is from your request and not other.
     
     By default a random value is used.

     - parameter state: a state value to send with the auth request

     - returns: the same OAuth2 instance to allow method chaining
     */
    public func state(state: String) -> OAuth2 {
        self.state = state
        return self
    }

    /**
     Send additional parameters for authentication.

     - parameter parameters: additional auth parameters

     - returns: the same OAuth2 instance to allow method chaining
     */
    public func parameters(parameters: [String: String]) -> OAuth2 {
        parameters.forEach { self.parameters[$0] = $1 }
        return self
    }

    /**
     Change the default grant used for auth from `code` (w/PKCE) to `token` (implicit grant)

     - returns: the same OAuth2 instance to allow method chaining
     */
    public func usingImplicitGrant() -> OAuth2 {
        self.usePKCE = false
        return self
    }

    /**
     Starts the OAuth2 flow by modally presenting a ViewController in the top-most controller.
     
     ```
     let session = Auth0
        .oauth2(clientId: clientId, domain: "samples.auth0.com")
        .start { result in
            print(result)
        }
     ```
     
     The returned session must be kept alive until the OAuth2 flow is completed and used from `AppDelegate` 
     when the following method is called
     
     ```
     func application(app: UIApplication, openURL url: NSURL, options: [String : AnyObject]) -> Bool {
        let session = //retrieve current OAuth2 session
        return session.resume(url, options: options)
     }
     ```

     - parameter callback: callback called with the result of the OAuth2 flow

     - returns: an object representing the current OAuth2 session.
     */
    public func start(callback: Result<Credentials, Authentication.Error> -> ()) {
        guard
            let redirectURL = self.redirectURL
            where !redirectURL.absoluteString.hasPrefix(OAuth2.NoBundleIdentifier)
            else {
                return callback(Result.Failure(error: .RequestFailed(cause: failureCause("Cannot find iOS Application Bundle Identifier"))))
            }
        let handler = self.handler(redirectURL)
        let authorizeURL = self.buildAuthorizeURL(withRedirectURL: redirectURL, defaults: handler.defaults)
        let (controller, finish) = newSafari(authorizeURL, callback: callback)
        let session = OAuth2Session(controller: controller, redirectURL: redirectURL, state: self.state, handler: handler, finish: finish)
        controller.delegate = session
        self.presenter.present(controller)
        self.storage.store(session)
    }

    func newSafari(authorizeURL: NSURL, callback: Result<Credentials, Authentication.Error> -> ()) -> (SFSafariViewController, Result<Credentials, Authentication.Error> -> ()) {
        let controller = SFSafariViewController(URL: authorizeURL)
        let finish: Result<Credentials, Authentication.Error> -> () = { [weak controller] (result: Result<Credentials, Authentication.Error>) -> () in
            guard let presenting = controller?.presentingViewController else {
                return callback(Result.Failure(error: .RequestFailed(cause: failureCause("Cannot find controller that triggered web flow"))))
            }

            if case .Failure(let cause) = result, .Cancelled = cause {
                dispatch_async(dispatch_get_main_queue()) {
                    callback(result)
                }
            } else {
                dispatch_async(dispatch_get_main_queue()) {
                    presenting.dismissViewControllerAnimated(true) {
                        callback(result)
                    }
                }
            }
        }
        return (controller, finish)
    }

    func buildAuthorizeURL(withRedirectURL redirectURL: NSURL, defaults: [String: String]) -> NSURL {
        let authorize = NSURL(string: "/authorize", relativeToURL: self.url)!
        let components = NSURLComponents(URL: authorize, resolvingAgainstBaseURL: true)!
        var items = [
            NSURLQueryItem(name: "client_id", value: self.clientId),
            NSURLQueryItem(name: "redirect_uri", value: redirectURL.absoluteString),
            NSURLQueryItem(name: "state", value: state),
            ]

        let addAll: (String, String) -> () = { items.append(NSURLQueryItem(name: $0, value: $1)) }
        defaults.forEach(addAll)
        self.parameters.forEach(addAll)
        components.queryItems = items
        return components.URL!
    }

    func handler(redirectURL: NSURL) -> OAuth2Grant {
        return self.usePKCE ? PKCE(clientId: clientId, url: url, redirectURL: redirectURL) : ImplicitGrant()
    }

    var redirectURL: NSURL? {
        let bundleIdentifier = NSBundle.mainBundle().bundleIdentifier ?? OAuth2.NoBundleIdentifier
        let components = NSURLComponents(URL: self.url, resolvingAgainstBaseURL: true)
        components?.scheme = self.universalLink ? "https" : bundleIdentifier
        return components?.URL?
            .URLByAppendingPathComponent("ios")
            .URLByAppendingPathComponent(bundleIdentifier)
            .URLByAppendingPathComponent("callback")
    }
}


private func failureCause(message: String) -> NSError {
    return NSError(domain: "com.auth0.oauth2", code: 0, userInfo: [NSLocalizedDescriptionKey: message])
}

private func generateDefaultState() -> String? {
    guard let data = NSMutableData(length: 32) else { return nil }
    if SecRandomCopyBytes(kSecRandomDefault, data.length, UnsafeMutablePointer<UInt8>(data.mutableBytes)) != 0 {
        return nil
    }
    return data.a0_encodeBase64URLSafe()
}

public extension NSData {
    public func a0_encodeBase64URLSafe() -> String? {
        return self
            .base64EncodedStringWithOptions([])
            .stringByReplacingOccurrencesOfString("+", withString: "-")
            .stringByReplacingOccurrencesOfString("/", withString: "_")
            .stringByTrimmingCharactersInSet(NSCharacterSet(charactersInString: "="))
    }
}
