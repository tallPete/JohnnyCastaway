// MD5.swift
//
// Tiny MD5 helper backed by CryptoKit. Used by tests to snapshot-pin
// the byte signatures of decompressed payloads, so a future change
// that subtly perturbs the parser output is caught immediately.

import Foundation
import CryptoKit

enum MD5Hash {

    /// Lower-case hex string of MD5(data).
    static func hex(_ data: Data) -> String {
        let digest = Insecure.MD5.hash(data: data)
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
