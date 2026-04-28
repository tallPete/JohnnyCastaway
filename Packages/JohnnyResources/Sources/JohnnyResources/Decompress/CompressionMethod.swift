// CompressionMethod.swift

import Foundation

public enum CompressionMethod: UInt8, Sendable, CaseIterable {
    case rle = 1
    case lzw = 2
}
