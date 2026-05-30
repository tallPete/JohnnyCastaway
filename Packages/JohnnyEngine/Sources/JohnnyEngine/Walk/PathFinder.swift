// SPDX-License-Identifier: GPL-3.0-or-later
//
// Copyright (C) 2026 Peter Smith
//
// This file is part of the Johnny Castaway macOS screensaver, a derivative
// work of 'Johnny Reborn' (jc_reborn) by Jeremie Guillaume.
//
// This program is free software: you can redistribute it and/or modify it
// under the terms of the GNU General Public License as published by the Free
// Software Foundation, either version 3 of the License, or (at your option)
// any later version. See the COPYING file or <https://www.gnu.org/licenses/>.

// PathFinder.swift
//
// Path-finding algorithm for the island walk graph.
// Translated from jc_reborn's calcpath.c + calcpath_data.h.
//
// The graph has 6 nodes (spots A–F). Edges are directional and context-
// sensitive: the legal next nodes depend on *both* the current node AND the
// previous node (i.e. the direction we came from). This prevents U-turns
// that would look weird in animation.
//
// calcPath(from:to:rng:) enumerates *all* simple paths via DFS and returns
// one chosen uniformly at random, matching the C original.
//
// Reference: jc_reborn calcpath.c:50–129, calcpath_data.h

// MARK: - Walk matrix (calcpath_data.h)

/// `walkMatrix[prev][cur][next]` = 1 if we may step from `cur` to `next`
/// when we just arrived at `cur` from `prev`.
/// prev == 6 (UNDEF_NODE) is the "from any direction" (start-of-walk) rule.
private let walkMatrix: [[[UInt8]]] = [
    // from A (prev=0)
    [
        [0, 0, 0, 0, 0, 0],  // at A
        [0, 0, 1, 0, 0, 0],  // at B → can go to C
        [0, 0, 0, 1, 0, 0],  // at C → can go to D
        [0, 0, 0, 0, 0, 0],  // at D
        [0, 0, 0, 1, 0, 1],  // at E → can go to D or F
        [0, 0, 0, 0, 0, 0],  // at F
    ],
    // from B (prev=1)
    [
        [0, 0, 0, 0, 1, 0],  // at A → can go to E
        [0, 0, 0, 0, 0, 0],  // at B
        [0, 0, 0, 1, 0, 0],  // at C → can go to D
        [0, 0, 0, 0, 0, 0],  // at D
        [0, 0, 0, 0, 0, 0],  // at E
        [0, 0, 0, 0, 0, 0],  // at F
    ],
    // from C (prev=2)
    [
        [0, 0, 0, 0, 1, 0],  // at A → can go to E
        [1, 0, 0, 0, 0, 0],  // at B → can go to A
        [0, 0, 0, 0, 0, 0],  // at C
        [0, 0, 0, 0, 1, 0],  // at D → can go to E
        [0, 0, 0, 0, 0, 0],  // at E
        [0, 0, 0, 0, 0, 0],  // at F
    ],
    // from D (prev=3)
    [
        [0, 0, 0, 0, 0, 0],  // at A
        [0, 0, 0, 0, 0, 0],  // at B
        [1, 1, 0, 0, 0, 1],  // at C → can go to A, B, or F
        [0, 0, 0, 0, 0, 0],  // at D
        [1, 0, 0, 0, 0, 0],  // at E → can go to A
        [0, 0, 0, 0, 1, 0],  // at F → can go to E
    ],
    // from E (prev=4)
    [
        [0, 1, 1, 0, 0, 0],  // at A → can go to B or C
        [0, 0, 0, 0, 0, 0],  // at B
        [0, 0, 0, 0, 0, 0],  // at C
        [0, 0, 1, 0, 0, 0],  // at D → can go to C
        [0, 0, 0, 0, 0, 0],  // at E
        [0, 0, 0, 1, 0, 0],  // at F → can go to D
    ],
    // from F (prev=5)
    [
        [0, 0, 0, 0, 0, 0],  // at A
        [0, 0, 0, 0, 0, 0],  // at B
        [0, 0, 0, 1, 0, 0],  // at C → can go to D
        [0, 0, 0, 0, 0, 0],  // at D
        [1, 0, 0, 0, 0, 0],  // at E → can go to A
        [0, 0, 0, 0, 0, 0],  // at F
    ],
    // from UNDEF (prev=6, start of walk — any direction)
    [
        [0, 1, 1, 0, 1, 1],  // at A → B, C, E, F
        [1, 0, 1, 0, 0, 0],  // at B → A, C
        [1, 1, 0, 1, 1, 1],  // at C → A, B, D, E, F
        [0, 0, 1, 0, 1, 1],  // at D → C, E, F
        [1, 0, 1, 1, 0, 1],  // at E → A, C, D, F
        [1, 0, 1, 1, 1, 0],  // at F → A, C, D, E
    ],
]

private let UNDEF_NODE = 6
private let NUM_NODES  = 6

// MARK: - PathFinder

/// Computes all shortest simple paths between two spots and returns one
/// chosen at random (matching jc_reborn calcpath.c).
///
/// - Parameters:
///   - from: Source spot (0–5 = A–F).
///   - to:   Destination spot (0–5 = A–F).
///   - rng:  Randomness source (inout for deterministic testing).
/// - Returns: Array of intermediate+destination spots ending with the
///            destination (not including `from`). Same spot → empty array.
public func calcPath(
    from: Int,
    to:   Int,
    rng:  inout some RandomNumberGenerator
) -> [Int] {
    if from == to { return [] }

    // DFS state
    var isMarked  = [Bool](repeating: false, count: NUM_NODES)
    var fromNode  = [Int](repeating: 0,     count: NUM_NODES)
    var allPaths: [[Int]] = []

    // Maximum path length guard (6 nodes → max path length 6)
    let maxPathLen = 7

    func dfs(prev: Int, cur: Int, depth: Int) {
        if cur == to {
            // Reconstruct path: [first_node_after_from, ..., to]
            // depth == 1 for the starting node (from), so depth-1 nodes follow.
            // C equivalent: paths[n][0..pathLen-1] = [from, ..., to]; we skip [0].
            let len = depth - 1   // elements AFTER from
            var path = [Int](repeating: 0, count: len)
            var node = cur
            for i in stride(from: len - 1, through: 0, by: -1) {
                path[i] = node
                node = fromNode[node]
            }
            allPaths.append(path)
            return
        }
        guard depth < maxPathLen else { return }

        for next in 0 ..< NUM_NODES {
            if walkMatrix[prev][cur][next] == 1 && !isMarked[next] {
                isMarked[next] = true
                fromNode[next] = cur
                dfs(prev: cur, cur: next, depth: depth + 1)
                isMarked[next] = false
            }
        }
    }

    isMarked[from] = true
    fromNode[from] = UNDEF_NODE
    dfs(prev: UNDEF_NODE, cur: from, depth: 1)

    guard !allPaths.isEmpty else { return [to] } // fallback: direct
    return allPaths.randomElement(using: &rng)!
}
