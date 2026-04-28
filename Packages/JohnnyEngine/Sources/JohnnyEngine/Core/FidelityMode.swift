// FidelityMode.swift
//
// Selects between the Go-port corrected engine behaviour (.fixed) and
// the jc_reborn-canonical behaviour (.raw). Controlled by the debug
// overlay; defaults to .fixed in all production paths.
//
// Differences (plan §1.13):
//   Day/night:     .fixed  hour < 6 || hour >= 18
//                  .raw    (hour % 8) ∈ {0, 7}  — visibly broken
//   IF_IS_RUNNING: .fixed  inSkipBlock = !isSceneRunning  — Go correction
//                  .raw    inSkipBlock =  isSceneRunning  — jc_reborn bug
//   Wave modulo:   .fixed  counter1 %= 2  — 2-frame cycle
//                  .raw    counter1 %= 3  — jc_reborn value

public enum FidelityMode: String, CaseIterable, Equatable, Sendable {
    case fixed  // Go-port corrections applied (recommended)
    case raw    // jc_reborn-canonical (for A/B verification)
}
