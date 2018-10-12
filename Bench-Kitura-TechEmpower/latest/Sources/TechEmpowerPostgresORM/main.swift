/*
 * Copyright IBM Corporation 2018
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
 */

import Foundation
import Kitura
import LoggerAPI
import HeliumLogger
import KituraStencil
import Stencil
import TechEmpowerCommon
import KueryPostgresORM

Log.logger = HeliumLogger(.info)

// Stencil stuff
let ext = Extension()

// Stencil does not yet support automatic HTML escaping:
// https://github.com/kylef/Stencil/pull/80
//
ext.registerFilter("htmlencode") { (value: Any?) in
    if let value = value as? String {
        return value
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
            .replacingOccurrences(of: "'", with: "&apos;")
            .replacingOccurrences(of: "\"", with: "&quot;")
    }
    return value
}

let router = Router()
router.add(templateEngine: StencilTemplateEngine(extension: ext))

setupORM()

//
// TechEmpower test 2: Single database query (full ORM)
//
router.get("/db") {
    request, response, next in
    response.headers["Server"] = "Kitura"
    getRandomRow { (row, err) in
        guard let row = row else {
            guard let err = err else {
                Log.error("Unknown Error")
                try? response.status(.badRequest).send("Unknown error").end()
                return
            }
            Log.error("\(err)")
            try? response.status(.badRequest).send("Error: \(err)").end()
            return
        }
        try? response.status(.OK).send(json: row.asDictionary()).end()
    }
}

//
// TechEmpower test 3: Multiple database queries (full ORM)
// Get param provides number of queries: /queries?queries=N
//
router.get("/queries") {
    request, response, next in
    response.headers["Server"] = "Kitura"
    let queriesParam = request.queryParameters["queries"] ?? "1"
    let numQueries = max(1, min(Int(queriesParam) ?? 1, 500))      // Snap to range of 1-500 as per test spec
    var results: [[String:Int]] = []
    // Used to track completion of concurrent queries
    let resultNotification = DispatchSemaphore(value: 0)
    // Used to protect result array from concurrent modification
    let updateLock = DispatchSemaphore(value: 1)
    // Execute each query. Each callback will append its result to `results`
    for _ in 1...numQueries {
        getRandomRow { (row, err) in
            guard let row = row else {
                guard let err = err else {
                    Log.error("Unknown Error")
                    resultNotification.signal()
                    try? response.status(.badRequest).send("Unknown error").end()
                    return
                }
                Log.error("\(err)")
                resultNotification.signal()
                try? response.status(.badRequest).send("Error: \(err)").end()
                return
            }
            updateLock.wait()
            results.append(row.asDictionary())
            updateLock.signal()
            resultNotification.signal()
        }
    }
    // Wait for all callbacks to complete
    for _ in 1...numQueries {
        resultNotification.wait()
    }
    // Return JSON representation of array of results
    try response.status(.OK).send(json: results).end()
}

//
// TechEmpower test 4: fortunes (full ORM)
//
router.get("/fortunes") {
    request, response, next in
    response.headers["Server"] = "Kitura"
    response.headers["Content-Type"] = "text/html; charset=UTF-8"
    Fortune.findAll { (fortunes, err) in
        if var fortunes = fortunes {
            fortunes.append(Fortune(id: 0, message: "Additional fortune added at request time."))
            do {
                try response.render("fortunes.stencil", context: ["fortunes": fortunes.sorted()]).end()
            } catch {
                try? response.status(.internalServerError).send("Error: \(error)").end()
            }
        } else {
            try? response.status(.internalServerError).send("Error: \(err ?? .internalServerError)").end()
        }
    }
}

//
// TechEmpower test 5: updates (full ORM)
//
router.get("/updates") {
    request, response, next in
    response.headers["Server"] = "Kitura"
    let queriesParam = request.queryParameters["queries"] ?? "1"
    let numQueries = max(1, min(Int(queriesParam) ?? 1, 500))      // Snap to range of 1-500 as per test spec
    var results: [[String:Int]] = []
    // Used to track completion of concurrent queries
    let resultNotification = DispatchSemaphore(value: 0)
    // Used to protect result array from concurrent modification
    let updateLock = DispatchSemaphore(value: 1)
    // Execute each query. Each callback will append its result to `results`
    for _ in 1...numQueries {
        getRandomRow { (row, err) in
            guard let row = row else {
                guard let err = err else {
                    Log.error("Unknown Error")
                    resultNotification.signal()
                    try? response.status(.badRequest).send("Unknown error").end()
                    return
                }
                Log.error("\(err)")
                resultNotification.signal()
                try? response.status(.badRequest).send("Error: \(err)").end()
                return
            }
            // Execute inner callback for updating the row
            updateRow(id: row.id) { (err) in
                if let err = err {
                    resultNotification.signal()
                    try? response.status(.badRequest).send("Error: \(err)").end()
                    return
                }
                updateLock.wait()
                results.append(row.asDictionary())
                updateLock.signal()
                resultNotification.signal()
            }
        }
    }
    for _ in 1...numQueries {
        resultNotification.wait()
    }
    // Return JSON representation of array of results
    try response.status(.OK).send(json: results).end()
}


Kitura.addHTTPServer(onPort: 8080, with: router)
Kitura.run()
