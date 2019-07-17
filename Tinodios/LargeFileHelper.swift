//
//  LargeFileHelper.swift
//  Tinodios
//
//  Copyright © 2019 Tinode. All rights reserved.
//

import Foundation
import UIKit
import TinodeSDK

class Upload {
    var url: URL
    var topicId: String
    var msgId: Int64 = 0
    var isUploading = false
    var progress: Float = 0
    var responseData: Data = Data()
    var progressCb: (() -> Void)?
    var finalCb: ((ServerMessage?, Error?) -> Void)?

    var task: URLSessionUploadTask?

    init(url: URL) {
        self.url = url
        self.topicId = ""
    }
    deinit {
        if let cb = finalCb {
            cb(nil, TinodeError.invalidState("Topic \(topicId), msg id \(msgId): Could not finish upload. Cancelling."))
        }
    }
}

class LargeFileHelper: NSObject {
    static let kBoundary = "*****\(Int64(Date().timeIntervalSince1970 as Double * 1000))*****"
    static let kTwoHyphens = "--"
    static let kLineEnd = "\r\n"

    var urlSession: URLSession!
    var activeUploads: [String : Upload] = [:]
    init(config: URLSessionConfiguration) {
        super.init()
        self.urlSession = URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }
    convenience override init() {
        let config = URLSessionConfiguration.background(withIdentifier: Bundle.main.bundleIdentifier!)
        self.init(config: config)
    }
    private static func addCommonHeaders(to request: inout URLRequest, using tinode: Tinode) {
        request.addValue(tinode.apiKey, forHTTPHeaderField: "X-Tinode-APIKey")
        request.addValue("Token \(tinode.authToken!)", forHTTPHeaderField: "Authorization")
    }
    // TODO: make background uploads work.
    func startUpload(filename: String, mimetype: String, d: Data, topicId: String, msgId: Int64,
                     completionCallback: ((ServerMessage?, Error?) -> Void)?) {
        let tinode = Cache.getTinode()
        guard var url = tinode.baseURL(useWebsocketProtocol: false) else { return }
        url.appendPathComponent("file/u/")
        let upload = Upload(url: url)
        var request = URLRequest(url: url)

        request.httpMethod = "POST"
        request.addValue("Keep-Alive", forHTTPHeaderField: "Connection")
        request.addValue(tinode.userAgent, forHTTPHeaderField: "User-Agent")
        request.addValue("multipart/form-data; boundary=\(LargeFileHelper.kBoundary)", forHTTPHeaderField: "Content-Type")
        /*
        request.addValue(tinode.apiKey, forHTTPHeaderField: "X-Tinode-APIKey")
        request.addValue("Token \(tinode.authToken!)", forHTTPHeaderField: "Authorization")
        */
        LargeFileHelper.addCommonHeaders(to: &request, using: tinode)

        var newData = Data()
        let header = LargeFileHelper.kTwoHyphens + LargeFileHelper.kBoundary + LargeFileHelper.kLineEnd +
            "Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"" + LargeFileHelper.kLineEnd +
            "Content-Type: \(mimetype)" + LargeFileHelper.kLineEnd +
            "Content-Transfer-Encoding: binary" + LargeFileHelper.kLineEnd + LargeFileHelper.kLineEnd
        newData.append(contentsOf: header.utf8)
        newData.append(d)
        let footer = LargeFileHelper.kLineEnd + LargeFileHelper.kTwoHyphens + LargeFileHelper.kBoundary + LargeFileHelper.kTwoHyphens + LargeFileHelper.kLineEnd
        newData.append(contentsOf: footer.utf8)

        var tempDir: URL
        if #available(iOS 10.0, *) {
            tempDir = FileManager.default.temporaryDirectory
        } else {
            // Fallback on earlier versions
            tempDir = URL(string: NSTemporaryDirectory().appending("/dummy"))!
        }
        let localFileName = UUID().uuidString
        let localURL = tempDir.appendingPathComponent("throwaway-\(localFileName)")
        try? newData.write(to: localURL)

        upload.task = urlSession.uploadTask(with: request, fromFile: localURL)
        upload.task!.taskDescription = localFileName
        upload.isUploading = true
        upload.topicId = topicId
        upload.msgId = msgId
        upload.finalCb = completionCallback
        activeUploads[localFileName] = upload
        upload.task!.resume()
    }
    func startDownload(from url: URL) {
        //guard var url = tinode.baseURL(useWebsocketProtocol: false) else { return }
        //url.appendPathComponent("file/u/")
        //let upload = Do(url: url)
        let tinode = Cache.getTinode()
        var request = URLRequest(url: url)
        LargeFileHelper.addCommonHeaders(to: &request, using: tinode)

        let task = urlSession.downloadTask(with: request)
        task.resume()
    }
}

extension LargeFileHelper: URLSessionDelegate {
    func urlSessionDidFinishEvents(forBackgroundURLSession session: URLSession) {
        DispatchQueue.main.async {
            if let appDelegate = UIApplication.shared.delegate as? AppDelegate,
                let completionHandler = appDelegate.backgroundSessionCompletionHandler {
                appDelegate.backgroundSessionCompletionHandler = nil
                completionHandler()
            }
        }
    }
}
extension LargeFileHelper: URLSessionDataDelegate {
    func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive: Data) {
        if let taskId = dataTask.taskDescription, let upload = activeUploads[taskId] {
            print("working with task \(taskId) - \(upload.topicId)")
            upload.responseData.append(didReceive)
        }
    }
}
extension LargeFileHelper: URLSessionTaskDelegate {
    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError: Error?) {
        guard let taskId = task.taskDescription, let upload = activeUploads[taskId] else {
            print("Unknown upload. Discarding.")
            return
        }
        activeUploads.removeValue(forKey: taskId)
        var serverMsg: ServerMessage? = nil
        var uploadError: Error? = didCompleteWithError
        defer {
            upload.finalCb?(serverMsg, uploadError)
            upload.finalCb = nil
        }
        guard uploadError == nil else {
            return
        }
        print("done with task \(taskId) - \(upload.topicId)")
        guard let response = task.response as? HTTPURLResponse else {
            uploadError = TinodeError.invalidState("Upload failed (\(upload.topicId)). No server response.")
            return
        }
        guard response.statusCode == 200 else {
            uploadError = TinodeError.invalidState("Upload failed (\(upload.topicId)): response code \(response.statusCode).")
            return
        }
        guard !upload.responseData.isEmpty else {
            uploadError = TinodeError.invalidState("Upload failed (\(upload.topicId)): empty response body.")
            return
        }
        do {
            serverMsg = try Tinode.jsonDecoder.decode(ServerMessage.self, from: upload.responseData)
        } catch {
            uploadError = error
            return
        }
    }
    func urlSession(_ session: URLSession, task: URLSessionTask, didSendBodyData: Int64, totalBytesSent: Int64, totalBytesExpectedToSend: Int64) {
        Thread.sleep(forTimeInterval: 0.1)
        if let t = task.taskDescription, let upload = activeUploads[t] {
            print("\(upload.topicId): sent = \(totalBytesSent), expected = \(totalBytesExpectedToSend)")
        }
    }
}
// Downloads.
extension LargeFileHelper: URLSessionDownloadDelegate {
    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        guard downloadTask.error == nil else {
            print("download failed: \(downloadTask.error!)")
            return
        }
        print("Finished downloading to \(location).")

        let documentsUrl: URL = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first!
        let destinationURL = documentsUrl.appendingPathComponent(
            downloadTask.originalRequest!.url!.lastPathComponent)

        let fileManager = FileManager.default
        do {
            try fileManager.removeItem(at: destinationURL)
        } catch {
            // Non-fatal: file probably doesn't exist
        }
        do {
            try fileManager.moveItem(at: location, to: destinationURL)
            // TODO: show file preview.
        } catch {
            print("Could not copy file to disk: \(error.localizedDescription)")
        }
    }
}