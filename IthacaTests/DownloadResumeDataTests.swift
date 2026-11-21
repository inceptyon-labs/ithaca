import Foundation
import Testing
@testable import Ithaca

/// Resume data replays its original request; a resume must use the current
/// address, token and network constraints but keep URLSession's own Range.
@Suite("Download resume data")
struct DownloadResumeDataTests {
    private let rootKey = "NSKeyedArchiveRootObjectKey"
    private let requestKeys = ["NSURLSessionResumeCurrentRequest", "NSURLSessionResumeOriginalRequest"]

    private var storedRequest: URLRequest {
        var request = URLRequest(url: URL(string: "http://192.168.1.10:32400/library/parts/1/file.mkv?X-Plex-Token=OLD")!)
        request.setValue("OLD", forHTTPHeaderField: "X-Plex-Token")
        request.setValue("bytes=100-", forHTTPHeaderField: "Range")
        request.allowsExpensiveNetworkAccess = false
        return request
    }

    private var currentRequest: URLRequest {
        var request = URLRequest(url: URL(string: "https://plex.example.com/library/parts/1/file.mkv?X-Plex-Token=NEW")!)
        request.setValue("NEW", forHTTPHeaderField: "X-Plex-Token")
        request.allowsExpensiveNetworkAccess = true
        return request
    }

    private func archived(_ object: Any, secure: Bool) -> Data {
        let archiver = NSKeyedArchiver(requiringSecureCoding: secure)
        archiver.encode(object, forKey: rootKey)
        archiver.finishEncoding()
        return archiver.encodedData
    }

    private var resumeInfo: [String: Any] {
        let request = archived(storedRequest as NSURLRequest, secure: true)
        return [
            requestKeys[0]: request,
            requestKeys[1]: request,
            "NSURLSessionDownloadURL": storedRequest.url!.absoluteString,
            "NSURLSessionResumeBytesReceived": 100,
        ]
    }

    private func expectRetargeted(_ info: [String: Any]) throws {
        #expect(info["NSURLSessionDownloadURL"] as? String == currentRequest.url?.absoluteString)
        #expect(info["NSURLSessionResumeBytesReceived"] as? Int == 100)
        for key in requestKeys {
            let unarchiver = try NSKeyedUnarchiver(forReadingFrom: try #require(info[key] as? Data))
            let request = try #require(
                unarchiver.decodeObject(of: [NSURLRequest.self, NSMutableURLRequest.self], forKey: rootKey) as? URLRequest
            )
            #expect(request.url == currentRequest.url)
            #expect(request.value(forHTTPHeaderField: "X-Plex-Token") == "NEW")
            #expect(request.value(forHTTPHeaderField: "Range") == "bytes=100-")
            #expect(request.allowsExpensiveNetworkAccess)
        }
    }

    @Test func retargetsKeyedArchiveResumeData() throws {
        let data = archived(resumeInfo as NSDictionary, secure: false)
        let output = try #require(DownloadResumeData.retargeted(data, to: currentRequest))
        let unarchiver = try NSKeyedUnarchiver(forReadingFrom: output)
        unarchiver.requiresSecureCoding = false
        try expectRetargeted(try #require(unarchiver.decodeObject(forKey: rootKey) as? [String: Any]))
    }

    @Test func retargetsPropertyListResumeData() throws {
        let data = try PropertyListSerialization.data(fromPropertyList: resumeInfo, format: .binary, options: 0)
        let output = try #require(DownloadResumeData.retargeted(data, to: currentRequest))
        let info = try PropertyListSerialization.propertyList(from: output, format: nil)
        try expectRetargeted(try #require(info as? [String: Any]))
    }

    @Test func unrecognisedResumeDataIsLeftAlone() {
        #expect(DownloadResumeData.retargeted(Data("not resume data".utf8), to: currentRequest) == nil)
    }
}
