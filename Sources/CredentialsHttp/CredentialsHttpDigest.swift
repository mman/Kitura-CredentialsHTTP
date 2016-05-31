/**
 * Copyright IBM Corporation 2016
 *
 * Licensed under the Apache License, Version 2.0 (the "License");
 * you may not use this file except in compliance with the License.
 * You may obtain a copy of the License at
 *
 * http://www.apache.org/licenses/LICENSE-2.0
 *
 * Unless required by applicable law or agreed to in writing, software
 * distributed under the License is distributed on an "AS IS" BASIS,
 * WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
 * See the License for the specific language governing permissions and
 * limitations under the License.
 **/

import Kitura
import KituraNet
import KituraSys
import Credentials
import Cryptor

import Foundation

public class CredentialsHttpDigest : CredentialsPluginProtocol {
    
    public var name : String {
        return "HttpDigest"
    }
    
    public var redirecting: Bool {
        return false
    }
    
    #if os(OSX)
    public var usersCache : NSCache<NSString, BaseCacheElement>?
    #else
    public var usersCache : NSCache?
    #endif
    
    private var userProfileLoader : UserProfileLoader
    
    public var realm : String
    
    public var opaque : String?
    
    private let qop = "auth"
    
    private let algorithm = "MD5"
    
    public init (userProfileLoader: UserProfileLoader, opaque: String?=nil, realm: String?=nil) {
        self.userProfileLoader = userProfileLoader
        self.opaque = opaque ?? nil
        self.realm = realm ?? "Users"
    }
    
    public func authenticate (request: RouterRequest, response: RouterResponse, options: [String:OptionValue], onSuccess: (UserProfile) -> Void, onFailure: (HTTPStatusCode?, [String:String]?) -> Void, onPass: (HTTPStatusCode?, [String:String]?) -> Void, inProgress: () -> Void)  {
        
        guard request.headers["Authorization"] != nil, let authorizationHeader = request.headers["Authorization"] where authorizationHeader.hasPrefix("Digest") else {
            onPass(.unauthorized, createHeaders())
            return
        }
        
        guard let credentials = CredentialsHttpDigest.parse(params: String(authorizationHeader.characters.dropFirst(7))) where credentials.count > 0,
            let userid = credentials["username"],
            let credentialsRealm = credentials["realm"] where credentialsRealm == realm,
            let credentialsURI = credentials["uri"] where credentialsURI == request.originalUrl,
            let credentialsNonce = credentials["nonce"],
            let credentialsCNonce = credentials["cnonce"],
            let credentialsNC = credentials["nc"],
            let credentialsQoP = credentials["qop"] where credentialsQoP == qop,
            let credentialsResponse = credentials["response"] else {
                onFailure(.badRequest, nil)
                return
        }
        
        if let opaque = opaque {
            guard let credentialsOpaque = credentials["opaque"] where credentialsOpaque == opaque else {
                onFailure(.badRequest, nil)
                return
            }
        }
        
        if let credentialsAlgorithm = credentials["algorithm"] {
            guard credentialsAlgorithm == algorithm else {
                onFailure(.badRequest, nil)
                return
            }
        }
        
        userProfileLoader(userId: userid) { userProfile, password in
            guard let userProfile = userProfile, let password = password else {
                onFailure(.unauthorized, self.createHeaders())
                return
            }
            
            let s1 = userid + ":" + credentialsRealm + ":" + password
            let ha1 = s1.digest(using: .md5)
            
            let s2 = request.method.rawValue + ":" + credentialsURI
            let ha2 = s2.digest(using: .md5)
            
            let s3 = ha1 + ":" + credentialsNonce + ":" + credentialsNC + ":" + credentialsCNonce + ":" + credentialsQoP + ":" + ha2
            let response = s3.digest(using: .md5)
            
            if response == credentialsResponse {
                onSuccess(userProfile)
            }
            else {
                onFailure(.unauthorized, self.createHeaders())
            }
        }
    }
    
    private func createHeaders () -> [String:String]? {
        var header = "Digest realm=\"" + realm + "\", nonce=\"" + CredentialsHttpDigest.generateNonce() + "\""
        if let opaque = opaque {
            header += ", opaque=\"" + opaque + "\""
        }
        header += ", algorithm=\"" + algorithm + "\", qop=\"" + qop + "\""
        return ["WWW-Authenticate":header]
    }
    
    private static func generateNonce() -> String {
        let nonce : [UInt8]
        do {
            nonce = try Random.generate(byteCount: 16)
            return CryptoUtils.hexString(from: nonce)
        }
        catch {
            return "0a0b0c0d0e0f1a1b1c1d1e1f01234567"
        }
    }
    
    private static func parse (params: String) -> [String:String]? {
        guard let tokens = split(originalString: params, pattern: ",(?=(?:[^\"]|\"[^\"]*\")*$)") else {
            return nil
        }

        var result = [String:String]()
        for token in tokens {
            let nsString = token as NSString
            do {
                let regex = try NSRegularExpression(pattern: "(\\w+)=[\"]?([^\"]+)[\"]?$", options: [])
                let matches = regex.matches(in: token, options: [], range: NSMakeRange(0, nsString.length))
                if matches.count == 1 && matches[0].range(at: 1).location != NSNotFound && matches[0].range(at: 2).location != NSNotFound {
                    result[nsString.substring(with: matches[0].range(at: 1))] = nsString.substring(with: matches[0].range(at: 2))
                }
            } catch  {
                return nil
            }
        }
        return result
    }
    
    
    private static func split(originalString: String, pattern: String) -> [String]? {
        var result = [String]()
        do {
            let regex = try NSRegularExpression(pattern: pattern, options: [])
            let nsString = originalString as NSString
            var start = 0
            while true {
                let results = regex.rangeOfFirstMatch(in: originalString, options: [], range: NSMakeRange(start, nsString.length - start))
                if results.location == NSNotFound {
                    result.append(nsString.substring(from: start))
                    break
                }
                else {
                    result.append(nsString.substring(with: NSMakeRange(start, results.location - start)))
                    start = results.length + results.location
                }
            }
        } catch {
            return nil
        }
        return result
    }
}