// Copyright 2026 Matthias Zenger
// SPDX-License-Identifier: Apache-2.0

import CoreGraphics
import Foundation
import GeminiAPI
import ImageIO
import UniformTypeIdentifiers

#if canImport(CoreImage)
import CoreImage
#endif

/// Content blocks for images and data attachments.
@available(iOS 27.0, macOS 27.0, visionOS 27.0, watchOS 27.0, *)
enum GeminiMedia {
  /// Longest edge, in pixels, an image is scaled to fit. The API tiles large
  /// images, so bigger images only cost tokens.
  static let maxLongEdge = 3072

  enum Error: LocalizedError, Sendable {
    case encodingFailed
    case unsupportedType(String)

    var errorDescription: String? {
      switch self {
      case .encodingFailed:
        "The image could not be encoded for upload."
      case .unsupportedType(let type):
        "Attachments of type \(type) are not supported by Gemini."
      }
    }
  }

  /// The block kind for data of `type`, or `nil` when the API takes no such
  /// content.
  static func blockType(for type: UTType) -> String? {
    if type.conforms(to: .pdf) { return "document" }
    if type.conforms(to: .image) { return "image" }
    if type.conforms(to: .audio) { return "audio" }
    if type.conforms(to: .movie) || type.conforms(to: .video) { return "video" }
    return nil
  }

  /// An image content block: PNG when the image has alpha, otherwise JPEG,
  /// upright and scaled to fit ``maxLongEdge``.
  static func imageBlock(
    _ image: CGImage,
    orientation: CGImagePropertyOrientation = .up
  ) throws -> JSONValue {
    let upright = baked(image, orientation: orientation)
    let fitted = try downscale(upright, toLongEdge: maxLongEdge)
    let hasAlpha: Bool
    switch fitted.alphaInfo {
    case .none, .noneSkipFirst, .noneSkipLast: hasAlpha = false
    default: hasAlpha = true
    }
    let type: UTType = hasAlpha ? .png : .jpeg
    let data = try encode(fitted, as: type)
    return [
      "type": "image",
      "data": .string(data.base64EncodedString()),
      "mime_type": .string(type.preferredMIMEType ?? "image/png"),
    ]
  }

  /// A content block for data of `type`.
  static func dataBlock(_ data: Data, type: UTType) throws -> JSONValue {
    guard let kind = blockType(for: type), let mime = type.preferredMIMEType else {
      throw Error.unsupportedType(type.identifier)
    }
    return ["type": .string(kind), "data": .string(data.base64EncodedString()), "mime_type": .string(mime)]
  }

  // MARK: - Private

  private static func encode(_ image: CGImage, as type: UTType) throws -> Data {
    let data = NSMutableData()
    guard
      let destination = CGImageDestinationCreateWithData(
        data as CFMutableData,
        type.identifier as CFString,
        1,
        nil
      )
    else { throw Error.encodingFailed }
    let options: [CFString: Any] = type == .jpeg ? [kCGImageDestinationLossyCompressionQuality: 0.9] : [:]
    CGImageDestinationAddImage(destination, image, options as CFDictionary)
    guard CGImageDestinationFinalize(destination) else { throw Error.encodingFailed }
    return data as Data
  }

  private static func downscale(_ image: CGImage, toLongEdge limit: Int) throws -> CGImage {
    let longEdge = max(image.width, image.height)
    guard longEdge > limit else { return image }
    let scale = Double(limit) / Double(longEdge)
    let width = max(1, Int((Double(image.width) * scale).rounded()))
    let height = max(1, Int((Double(image.height) * scale).rounded()))
    guard
      let context = CGContext(
        data: nil,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
      )
    else { throw Error.encodingFailed }
    context.interpolationQuality = .high
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    guard let scaled = context.makeImage() else { throw Error.encodingFailed }
    return scaled
  }

  /// `image` with `orientation` applied to its pixels.
  private static func baked(_ image: CGImage, orientation: CGImagePropertyOrientation) -> CGImage {
    #if canImport(CoreImage)
    guard orientation != .up else { return image }
    let oriented = CIImage(cgImage: image).oriented(orientation)
    return CIContext().createCGImage(oriented, from: oriented.extent) ?? image
    #else
    return image
    #endif
  }
}
