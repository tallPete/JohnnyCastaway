// ResourceCache.swift
//
// Name-keyed lookup for the parsed resource types the engine touches at
// runtime: Palette, Screen, and Bitmap. Wraps a JohnnyResources.ResourceArchive
// and provides the engine-level find-or-throw helpers that replace
// jc_reborn's findScrResource() / findBmpResource() / findTtmResource()
// in resource.c.
//
// The cache is read-only after construction; the archive is the source
// of truth.

import JohnnyResources

// MARK: - EngineError

public enum EngineError: Error, Sendable {
    case resourceNotFound(String)
    case unexpectedResourceKind(name: String, expected: String)
    case tooManyTTMThreads
    case ttmTagNotFound(tag: UInt16)
    case adsTagNotFound(tag: UInt16)
    case adsNoSlotsAvailable
}

// MARK: - ResourceCache

public struct ResourceCache: Sendable {

    private let archive: ResourceArchive

    public init(archive: ResourceArchive) {
        self.archive = archive
    }

    // MARK: Typed accessors

    public func palette(named name: String) throws -> Palette {
        guard let resource = archive[name] else {
            throw EngineError.resourceNotFound(name)
        }
        guard case .palette(let pal) = resource else {
            throw EngineError.unexpectedResourceKind(name: name, expected: "PAL")
        }
        return pal
    }

    public func screen(named name: String) throws -> Screen {
        guard let resource = archive[name] else {
            throw EngineError.resourceNotFound(name)
        }
        guard case .screen(let scr) = resource else {
            throw EngineError.unexpectedResourceKind(name: name, expected: "SCR")
        }
        return scr
    }

    public func bitmap(named name: String) throws -> Bitmap {
        guard let resource = archive[name] else {
            throw EngineError.resourceNotFound(name)
        }
        guard case .bitmap(let bmp) = resource else {
            throw EngineError.unexpectedResourceKind(name: name, expected: "BMP")
        }
        return bmp
    }

    public func ttmScript(named name: String) throws -> TTMScript {
        guard let resource = archive[name] else {
            throw EngineError.resourceNotFound(name)
        }
        guard case .ttmScript(let ttm) = resource else {
            throw EngineError.unexpectedResourceKind(name: name, expected: "TTM")
        }
        return ttm
    }

    public func adsScript(named name: String) throws -> ADSScript {
        guard let resource = archive[name] else {
            throw EngineError.resourceNotFound(name)
        }
        guard case .adsScript(let ads) = resource else {
            throw EngineError.unexpectedResourceKind(name: name, expected: "ADS")
        }
        return ads
    }

    /// The first palette found in the archive (canonical container has
    /// exactly one). Throws if none is present.
    public func firstPalette() throws -> Palette {
        guard let entry = archive.entries(of: .palette).first,
              case .palette(let pal) = entry.resource else {
            throw EngineError.resourceNotFound("*.PAL")
        }
        return pal
    }
}
