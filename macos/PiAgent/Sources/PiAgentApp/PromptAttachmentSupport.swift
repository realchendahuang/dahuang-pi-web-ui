import AppKit
import PiAgentCore
import SwiftUI
import SwiftTerm
import UniformTypeIdentifiers
import UserNotifications

let nativeInlineImageLimit = Int(4.5 * 1024 * 1024)
let nativePromptAttachmentLimit = 16
let nativePromptImageContentTypes: [UTType] = [.png, .jpeg, .gif]
    + (UTType(filenameExtension: "webp").map { [$0] } ?? [])

func nativeImageMimeType(for url: URL) -> String? {
    switch url.pathExtension.lowercased() {
    case "jpg", "jpeg": return "image/jpeg"
    case "png": return "image/png"
    case "gif": return "image/gif"
    case "webp": return "image/webp"
    default: return nil
    }
}
