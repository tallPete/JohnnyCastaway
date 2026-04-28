// PathFinderTests.swift
//
// Tests for the island walk-graph path-finding algorithm (calcpath.c).

import Testing
@testable import JohnnyEngine

@Suite("PathFinder")
struct PathFinderTests {

    private func rng(_ seed: UInt64 = 99) -> SeedableRNG { SeedableRNG(seed: seed) }

    @Test("Same source and destination returns empty path")
    func sameSpot() {
        var r = rng()
        let path = calcPath(from: Spot.A, to: Spot.A, rng: &r)
        #expect(path.isEmpty)
    }

    @Test("Path from A to C ends with C")
    func aToC() {
        var r = rng()
        let path = calcPath(from: Spot.A, to: Spot.C, rng: &r)
        #expect(!path.isEmpty)
        #expect(path.last == Spot.C)
    }

    @Test("Path from B to D ends with D")
    func bToD() {
        var r = rng()
        let path = calcPath(from: Spot.B, to: Spot.D, rng: &r)
        #expect(!path.isEmpty)
        #expect(path.last == Spot.D)
    }

    @Test("Path from A to F ends with F")
    func aToF() {
        var r = rng()
        let path = calcPath(from: Spot.A, to: Spot.F, rng: &r)
        #expect(!path.isEmpty)
        #expect(path.last == Spot.F)
    }

    @Test("Path from E to A ends with A")
    func eToA() {
        var r = rng()
        let path = calcPath(from: Spot.E, to: Spot.A, rng: &r)
        #expect(!path.isEmpty)
        #expect(path.last == Spot.A)
    }

    @Test("Path from C to B ends with B")
    func cToB() {
        var r = rng()
        let path = calcPath(from: Spot.C, to: Spot.B, rng: &r)
        #expect(!path.isEmpty)
        #expect(path.last == Spot.B)
    }

    @Test("Paths have no repeated nodes (simple path)")
    func noDuplicates() {
        let pairs = [(Spot.A,Spot.C),(Spot.B,Spot.D),(Spot.F,Spot.A),(Spot.E,Spot.B)]
        for (from, to) in pairs {
            var r = rng(UInt64(from * 10 + to))
            let path = calcPath(from: from, to: to, rng: &r)
            let nodes = [from] + path
            #expect(Set(nodes).count == nodes.count, "Path \(from)→\(to) has duplicates: \(path)")
        }
    }

    @Test("Different seeds produce different paths for A→C")
    func nonDeterministicWithDifferentSeeds() {
        // Not all seeds are different (LCG), but over 20 tries we should see variation
        var seen = Set<[Int]>()
        for seed: UInt64 in 0 ..< 20 {
            var r = SeedableRNG(seed: seed)
            seen.insert(calcPath(from: Spot.A, to: Spot.C, rng: &r))
        }
        // A→C has multiple valid paths; we should see > 1 distinct path
        #expect(seen.count > 1, "Expected path variation but got only: \(seen)")
    }
}
