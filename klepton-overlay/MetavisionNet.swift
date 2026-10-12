// An HTTP request for the runtime's C side: mv_net_fetch, the one network
// facility Java surfaces answered from the host use (the Firestore REST client
// in runtime/jni/kl_jni_firestore.c, overlay step 145; the Realtime Database
// REST client in runtime/jni/kl_jni_database.c, step 160). URLSession does the
// work; the C callback runs once, on URLSession's delegate queue, with the
// status code and the body, or with status 0 and the error's description when
// no response arrived (offline, DNS, TLS, timeout). mv_net_fetch_headers
// (step 162) is the same request answering the response headers too, as
// "Name: value" lines — what a Realtime Database transaction's ETag needs.
//
// The runtime carries weak defaults (every request fails as offline; the
// headers form falls back to mv_net_fetch without headers), so these
// definitions are what turn the network on; tools/metavision-overlay copies
// this file into visionos/Sources and lists it in the Xcode project.
import Foundation

typealias MVNetDone = @convention(c) (UnsafeMutableRawPointer?, Int32, UnsafePointer<CChar>?, Int,
                                      UnsafePointer<CChar>?) -> Void
typealias MVNetHeadersDone = @convention(c) (UnsafeMutableRawPointer?, Int32, UnsafePointer<CChar>?, Int,
                                             UnsafePointer<CChar>?, UnsafePointer<CChar>?) -> Void

private let mvNetSession: URLSession = {
    let c = URLSessionConfiguration.ephemeral   // no cookies, no cache on disk
    c.requestCachePolicy = .reloadIgnoringLocalCacheData
    c.waitsForConnectivity = false              // offline fails now, as on a headset
    return URLSession(configuration: c)
}()

// Builds and starts the request from what the C side passed (all copied before
// this returns). `finish` runs once, on URLSession's queue: the status, the
// body and the response headers, or status 0 and the error.
private func mvNetStart(_ method: UnsafePointer<CChar>, _ url: UnsafePointer<CChar>,
                        _ headers: UnsafePointer<CChar>?, _ body: UnsafePointer<CChar>?, _ bodyLen: Int,
                        _ timeout: Double,
                        _ finish: @escaping @Sendable (Int32, Data?, String?, String?) -> Void) {
    guard let u = URL(string: String(cString: url)) else {
        finish(0, nil, "not a URL", nil)
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
            var lines = ""
            for (key, value) in http.allHeaderFields {
                let name = (key.base as? String) ?? "\(key)"
                lines += "\(name): \(value)\n"
            }
            finish(Int32(http.statusCode), data, nil, lines)
        } else {
            finish(0, nil, error?.localizedDescription ?? "no response", nil)
        }
    }.resume()
}

@_cdecl("mv_net_fetch")
func mvNetFetch(_ method: UnsafePointer<CChar>, _ url: UnsafePointer<CChar>,
                _ headers: UnsafePointer<CChar>?, _ body: UnsafePointer<CChar>?, _ bodyLen: Int,
                _ timeout: Double, _ done: MVNetDone, _ ctx: UnsafeMutableRawPointer?) {
    let ctxBits = UInt(bitPattern: ctx)
    mvNetStart(method, url, headers, body, bodyLen, timeout) { status, data, err, _ in
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
}

@_cdecl("mv_net_fetch_headers")
func mvNetFetchHeaders(_ method: UnsafePointer<CChar>, _ url: UnsafePointer<CChar>,
                       _ headers: UnsafePointer<CChar>?, _ body: UnsafePointer<CChar>?, _ bodyLen: Int,
                       _ timeout: Double, _ done: MVNetHeadersDone, _ ctx: UnsafeMutableRawPointer?) {
    let ctxBits = UInt(bitPattern: ctx)
    mvNetStart(method, url, headers, body, bodyLen, timeout) { status, data, err, respHeaders in
        let c = UnsafeMutableRawPointer(bitPattern: ctxBits)
        if let err = err {
            err.withCString { done(c, 0, nil, 0, $0, nil) }
            return
        }
        var d = data ?? Data()
        let len = d.count
        d.append(0)   // NUL-terminated for the C side
        (respHeaders ?? "").withCString { h in
            d.withUnsafeBytes { raw in
                done(c, status, raw.bindMemory(to: CChar.self).baseAddress, len, nil, h)
            }
        }
    }
}
