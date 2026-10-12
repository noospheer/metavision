// An HTTP request for the runtime's C side: mv_net_fetch, the one network
// facility Java surfaces answered from the host use (the Firestore REST client
// in runtime/jni/kl_jni_firestore.c, overlay step 145). URLSession does the
// work; the C callback runs once, on URLSession's delegate queue, with the
// status code and the body, or with status 0 and the error's description when
// no response arrived (offline, DNS, TLS, timeout).
//
// The runtime carries a weak default that fails every request as offline, so
// this definition is what turns the network on; tools/metavision-overlay
// copies this file into visionos/Sources and lists it in the Xcode project.
import Foundation

typealias MVNetDone = @convention(c) (UnsafeMutableRawPointer?, Int32, UnsafePointer<CChar>?, Int,
                                      UnsafePointer<CChar>?) -> Void

private let mvNetSession: URLSession = {
    let c = URLSessionConfiguration.ephemeral   // no cookies, no cache on disk
    c.requestCachePolicy = .reloadIgnoringLocalCacheData
    c.waitsForConnectivity = false              // offline fails now, as on a headset
    return URLSession(configuration: c)
}()

@_cdecl("mv_net_fetch")
func mvNetFetch(_ method: UnsafePointer<CChar>, _ url: UnsafePointer<CChar>,
                _ headers: UnsafePointer<CChar>?, _ body: UnsafePointer<CChar>?, _ bodyLen: Int,
                _ timeout: Double, _ done: MVNetDone, _ ctx: UnsafeMutableRawPointer?) {
    // Everything the C side passed is copied before this returns.
    let ctxBits = UInt(bitPattern: ctx)
    func finish(_ status: Int32, _ data: Data?, _ err: String?) {
        let c = UnsafeMutableRawPointer(bitPattern: ctxBits)
        if let err = err {
            err.withCString { done(c, 0, nil, 0, $0) }
            return
        }
        var d = data ?? Data()
        let len = d.count
        d.append(0)   // NUL-terminated for the C side
        d.withUnsafeBytes { raw in
            done(c, status, raw.bindMemory(to: CChar.self).baseAddress, len, nil)
        }
    }
    guard let u = URL(string: String(cString: url)) else {
        finish(0, nil, "not a URL")
        return
    }
    var req = URLRequest(url: u, cachePolicy: .reloadIgnoringLocalCacheData,
                         timeoutInterval: timeout > 0 ? timeout : 30)
    req.httpMethod = String(cString: method)
    if let headers = headers {
        for line in String(cString: headers).split(separator: "\n") {
            guard let colon = line.firstIndex(of: ":") else { continue }
            let name = line[..<colon].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
            if !name.isEmpty { req.setValue(value, forHTTPHeaderField: name) }
        }
    }
    if let body = body, bodyLen > 0 {
        req.httpBody = Data(bytes: body, count: bodyLen)
    }
    mvNetSession.dataTask(with: req) { data, response, error in
        if let http = response as? HTTPURLResponse {
            finish(Int32(http.statusCode), data, nil)
        } else {
            finish(0, nil, error?.localizedDescription ?? "no response")
        }
    }.resume()
}
