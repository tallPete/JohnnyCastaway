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
// any later version. See the LICENSE file or <https://www.gnu.org/licenses/>.

// SnapshotTests.swift
//
// MD5 snapshot pin: every entry's parsed-and-decompressed payload
// hashes to a known value. Catches any subtle change to the parser
// that perturbs output bytes (compression bug, off-by-one,
// endian flip, etc.).
//
// Bootstrapping protocol:
//   * On first run, every entry not in `expectedMD5s` is reported
//     as a failure with its computed MD5 in a paste-ready format.
//   * Copy the output into the dictionary below.
//   * Re-run; all tests pass.
//   * Subsequent runs lock the parser output: any drift fails loud.
//
// MD5s are computed over the most-informative byte sequence per kind:
//   * .palette       -> 256 RGB triplets (768 bytes)
//   * .screen        -> the unpacked pixel buffer (width*height bytes)
//   * .bitmap        -> the unpacked pixel buffer (sum(w*h) bytes)
//   * .ttmScript     -> the decompressed bytecode
//   * .adsScript     -> the decompressed bytecode
//   * .unrecognised  -> the raw section bytes
//
// Hash count: 180 entries → 180 expected MD5s. Captured by running
// this test against canonical RESOURCE.MAP MD5
// 374e6d05c5e0acd88fb5af748948c899 and RESOURCE.001 MD5
// 8bb6c99e9129806b5089a39d24228a36.

import Testing
import Foundation
@testable import JohnnyResources

@Suite("MD5 snapshot pin (canonical archive)",
       .disabled(if: !TestResources.available, TestResources.skipMessage))
struct SnapshotTests {

    /// Computed once per test run.
    static let archive = ContainerTests.archiveResult

    /// MD5 hex string for the most-informative payload of each entry,
    /// keyed by uppercased resource name.
    static let expectedMD5s: [String: String] = [
        "ACTIVITY.ADS": "584addf284401825ee89000b903f6db6",
        "BACKGRND.BMP": "7832af16198c5946fe3886e02d00f1d2",
        "BOAT.BMP": "ffd9474f4d9d98f867e3138a718ec7e9",
        "BUILDING.ADS": "52dc345b913a329f65f6296e9af545c2",
        "CLOUDS.BMP": "d829f1d796fce78c5ad8a5dbc61b3f25",
        "COCOHEAD.BMP": "6c0011af884eccf4aa63b8b959d47424",
        "COCONUTS.BMP": "d0967e6b52177a3fdb80a91d59bf9ee2",
        "DRUNKJON.BMP": "6db6e28f717137baff02c5a90021a7cd",
        "ENDCRDTS.BMP": "b08460df30ffbe228902a9c52b7cb381",
        "FILES.VIN": "b4901c7e1e66552d14c30833adfec43e",
        "FIRE.BMP": "36d49c4f3304e965193634d5c2bb79d2",
        "FIRE.TTM": "f6cd8501b8fab06e34248b781d4126bf",
        "FIRE1.BMP": "fcd5d416ddfa14e9ef5b6703baaa09ea",
        "FIRE2.BMP": "b83c6d2535b8257f7d55d2a917fec47f",
        "FIRE3.BMP": "183c606203ef7ce9e58093c421943ad3",
        "FIRE4.BMP": "2a46a7fa651ee9e88f395f5b294ec303",
        "FIRE5.BMP": "9a91c39a5b53a07f415a5517f2ce7198",
        "FISHING.ADS": "a7be4dc9116a143f2ed2bf32284d70c9",
        "FISHMAN.BMP": "6805eee97d021f4f1f7c63040ce5922e",
        "FISHWALK.TTM": "037c81929ed2b8ebfecbe4b674db9a6c",
        "GFFFOOD.TTM": "86fd0866434b99dae0e05552603db787",
        "GJANGRY.BMP": "67489567a40d6a634c972ac09ce76ce3",
        "GJBIPLAN.BMP": "35cacf9c5642cfb3e20c29b18169ebae",
        "GJCASTLE.BMP": "c1a785a5c5b5daf945ed72553675e977",
        "GJCATCH1.BMP": "f139ed0585f9bbda75d6f87693b0a809",
        "GJCATCH2.BMP": "d55c3daf3a0ae0ddb074d7e2d178d91f",
        "GJCATCH2.TTM": "dba6903c7a381b958597503b41e4cd8d",
        "GJCATCH3.BMP": "fb75ef57c0b329abe00d2314d29cea03",
        "GJDIVE.BMP": "b43e92eb196d2d62434caddb1d921897",
        "GJDIVE.TTM": "a02421ac4ed87689c7a3f1590fa58d08",
        "GJFFFOOD.BMP": "05c4663b4219ad405adaaf665d14aaa3",
        "GJGULIVR.TTM": "2c6c80bf365f99182c848c5290f0782b",
        "GJGULL1.BMP": "908a9f59f46cc0ce4e56c627a9b5dc89",
        "GJGULL1.TTM": "4073ebda9e61ad4514afe6f9e91b0b26",
        "GJGULL1A.BMP": "67489567a40d6a634c972ac09ce76ce3",
        "GJGULL2.BMP": "ce48c4c4efeed6ce2c7b0b1bc7008b69",
        "GJGULL2A.BMP": "be31721f6efda9b5fd6b73574aa11150",
        "GJGULL3.BMP": "1d3806fd02315332b090c2b87e0435cf",
        "GJGULL3A.BMP": "dbbbe4fec1c36ff2cb31f9ed12f316b7",
        "GJHOT.BMP": "d76ab9d5d444144af802708fb8a50cb4",
        "GJHOT.TTM": "2c9c2f04331ad5fc2cb18c902eb3ea1a",
        "GJKINGKO.BMP": "8bb335303a5db8191cdc4b1461c18bbf",
        "GJLILIPU.TTM": "11cbdde8e848fe1ba5001ba83dc9b202",
        "GJNAT1.BMP": "35e9826dde9a83df6b6df999e1b93085",
        "GJNAT1.TTM": "9204b19135d1798f3233a1d33df3ef5d",
        "GJNAT1LI.BMP": "fff7f105a5015e8eb4e1e0392e416928",
        "GJNAT3.BMP": "4e3732030ae62762a3154551f2d89a25",
        "GJNAT3.TTM": "66a1cc0fbdb94d0fe75a2ef55a8f3055",
        "GJPROW.BMP": "b2d7e5d480ba65d681c47d7d7c95af45",
        "GJRUNAWA.BMP": "9d6a976cf5e77369c37e46f3f60581e0",
        "GJVIS3.BMP": "53f2d1e6f4c61f965ec488bbfde04790",
        "GJVIS3.TTM": "bf02b870d232585c4e95f255952fdc98",
        "GJVIS5.BMP": "c94ab78476f0f6a6565547928e8b1f7e",
        "GJVIS5.TTM": "3b4db5ba3670e20b7f996438dbbad6db",
        "GJVIS52.BMP": "4eecbe5d2b0c477b41c9a5e9eceebdfc",
        "GJVIS5W.TTM": "1d4a4d71d30cd570432589bf37d969b9",
        "GJVIS6.BMP": "c58ccfc19c62a20af6e06e3c676f8f38",
        "GJVIS6.TTM": "6cc14b75095d5b63eeb58c9806e359d6",
        "HOLIDAY.BMP": "20c3322074da6d1aba2c2d984d33b4fa",
        "INTRO.SCR": "a3d0e967e41f38e2d6c0a90eafdc2a4d",
        "ISLAND2.SCR": "503eb5b7f6636569f9c25cecb0aafd94",
        "ISLETEMP.SCR": "f20e5fb3749f79dc1aa608c2f394e9be",
        "JATA.BMP": "61e01c523e3386943fbff5a730ff93bf",
        "JCHANGE.BMP": "58da699b8485f33903baded8d0c51bb5",
        "JOFFICE.SCR": "4f094922de267dc3983bc2ca6026b7a7",
        "JOHNCAST.PAL": "6f24de842e0afae1fec19de040c8dd6d",
        "JOHNNY.ADS": "f31c243bbcc61eaf596a81dcd84b46b2",
        "JOHNWALK.BMP": "1fae86d065232181ea58961c8457c5e7",
        "JOHNWOUL.BMP": "523c7ee46af9823bb92c9e7edada5ab5",
        "LILFISH.BMP": "c4a0f3124821f8d70f5b1a8f48dfe8b2",
        "LILIPUTS.BMP": "a644292244213623a1a6b27b984b7f56",
        "LITEBULB.BMP": "028f89ead93fa564eef9dfe92439ee98",
        "MARY.ADS": "e16714b8e6152d907fc4b87311934f15",
        "MEANWHIL.BMP": "47eb1d645cfb1cf4fb41167b5277e12a",
        "MEANWHIL.TTM": "c2d62634c42cac86509674d15ec7799c",
        "MEXCWALK.BMP": "58361142dd5ea8ac99ece5f2ab66fa22",
        "MISCGAG.ADS": "6dbe1635381f77e5c1b66ce1fe5be070",
        "MJAMBWLK.TTM": "2904a919536ecdfc9428765bfeaf10ae",
        "MJBATH.BMP": "605847e1e374d7ab2d02f962ef265b33",
        "MJBATH.TTM": "f5077b26a9b9a897dc5c3b1749ca3b88",
        "MJBOTTLE.BMP": "4ef11dd288d31c0ab8f633e22d33bd3b",
        "MJBTL2.BMP": "25a2ff7b5fa0c6f9eaa42ab15380f951",
        "MJCOCO.BMP": "6678eccb506c9a8203e41ad9acf90bfd",
        "MJCOCO.TTM": "b14fce77c4292075fdb9e4319eca5f29",
        "MJCOCO1.TTM": "682122d314d4eba5820ce60277333170",
        "MJDIVE.BMP": "f01fdeaa5050b67ef4c190a619a333ae",
        "MJDIVE.TTM": "8c249e8bdc5b41f972e11bee3bbbc635",
        "MJFIRE.TTM": "fe7c6a2c031ac31529214b0c43f0e3ab",
        "MJFISH.TTM": "cf90126194ce50cce80f8c2485e83d62",
        "MJFISH1.BMP": "c21a194d0c2827312d9f6f6fb829ca65",
        "MJFISH2.BMP": "01ab4bcd6255a8174e5afc113d9e5544",
        "MJFISH3.BMP": "d3bc73eeeda3f9811573892e5b79c661",
        "MJFISHC.TTM": "b983403043ddcc18a79e74df9d686540",
        "MJJOG.TTM": "01944b402dcb3e55fda85b34897c5804",
        "MJJOG1.BMP": "ca122db46a79311c86fb7185452d5a02",
        "MJJOG2.BMP": "186b85c6f86f86b49550817e0a98278b",
        "MJRAFT.TTM": "1383de4b4f0441059c4a345b5a68ffb8",
        "MJRAFT2.BMP": "285fc1ea3c39c8c7fc08d92df2d754df",
        "MJREAD.BMP": "594d766848627bfc1da516d596fc320e",
        "MJREAD.TTM": "043c1319a5ff55494fd58dffd8e294da",
        "MJSAND.TTM": "581fef4467934ba438238482ed531502",
        "MJSANDC.BMP": "c768dcc5072deb6df4134e95210b094f",
        "MJTELE.BMP": "e42ffce8868175ef4303ec36b0103385",
        "MJTELE.TTM": "23463cd8edd9f82625151d6b8d478940",
        "MJTELE2.BMP": "7ba834f0fd4e54a659c5784988cc4f54",
        "MJ_AMB.BMP": "783ddecb7c68eaeb445da293b25614bc",
        "MRAFT.BMP": "78df20b896275d2e7c6c34d2c1d4ec92",
        "NIGHT.SCR": "d05087443c8826c7462fc69d5ca8a2f2",
        "OCEAN00.SCR": "d3b1066317009c132235c0560a6e21b1",
        "OCEAN01.SCR": "0b22f3970eb5dfa078c89c892eba98d3",
        "OCEAN02.SCR": "ed4f280a2beb5edf0b14c2fccea047d5",
        "SANDCAST.BMP": "3da1c9522a6061e28f816bfc9f542511",
        "SASKDATE.TTM": "49093b293e552bbf485ead576db7102c",
        "SA_DEMO.BMP": "76e46e18b166acb70625dc4ce49155aa",
        "SBREAKUP.BMP": "07122d1d873bae4972d989c589d05faa",
        "SBREAKUP.TTM": "34f560c9a20f727cbc55915db47c402a",
        "SHARK.BMP": "b305c2e7a5bfbb27126889ab604a29f9",
        "SHARK1.TTM": "68995aff6bfefa5427e049b79ff2d223",
        "SHARKWLK.BMP": "3fb2333a084a11749a847cf13dd208f7",
        "SHIPS.BMP": "3a3a8157f57175c53b7ab7c2d0a61e4a",
        "SHKNFIST.BMP": "770762606e361adb782dba53489a5d62",
        "SJBRAKUP.BMP": "76c7a523e5ea0ae5fe0cba6385850069",
        "SJGFTASK.BMP": "e975a599ec8359b6e329c18969242a0b",
        "SJGFTJMP.BMP": "2c20a6e0b6baf408ecfc429485bee46f",
        "SJGFTSHY.BMP": "be43f4bfaa8f38a61234a8d367b44bb6",
        "SJGFTXCH.BMP": "c626247b62c03172b5f93ff2e30c4f4b",
        "SJGLIMPS.TTM": "a0b123f2319dc82961d42d4fc890e8f2",
        "SJLEAVES.TTM": "5c3404c321f7a86388bef59ed8c6fd5e",
        "SJMSSGE.TTM": "a7e0613e2876948680b2eea72ebfec0d",
        "SJMSUZY.TTM": "fd9e489bba17cc074d61522b8a45beca",
        "SJMSUZY1.BMP": "8d5b377d11be405002fc17d64c57b39f",
        "SJMSUZY2.BMP": "4e2b73ecdf7159a6d87a00292458ed1b",
        "SJMSUZY3.BMP": "5a195a71ee085778c4b5022ba44b7b6a",
        "SJRAFT1.BMP": "3bdd06632c0fa808f1c0c7242b541f37",
        "SJWORK.BMP": "68c6fbda900d33f667f7fe9751c41d3c",
        "SJWORK.TTM": "c439fa7f534e9c1fe730e9a97629fe1f",
        "SLEEP.BMP": "1352f955ccdbad8dd2a793a88c23f8c1",
        "SLEVEJC1.BMP": "38bfa277a6ccde622e411d2ffe548c93",
        "SLEVEJC2.BMP": "c5436acb501bf7b07c75b89a7f9568f0",
        "SLEVEJC3.BMP": "0a995cc95d31f4ca649d9e8ae0949025",
        "SLEVEJM1.BMP": "040ba34e7b6e96a7cd2445614fe64378",
        "SLEVEJM2.BMP": "1b34244bc291d8f9f444956687ac6e4e",
        "SLEVEJM3.BMP": "2a2cdc6833b607842a883ec6823d911b",
        "SMDATE.TTM": "0a08b6ec75eee8b7dec8b41ab0f1c2ee",
        "SMDATE1.BMP": "2eb9e886562e4aade374120dfdf2421c",
        "SMDATE10.BMP": "ddd8490200837f09ce7dfd49317415fa",
        "SMDATE11.BMP": "96561523c3aa99472d560b085b283f07",
        "SMDATE12.BMP": "30b597f49916fb9f617cad8dde930292",
        "SMDATE2.BMP": "958b7e87aa3044d473c6629acaf2f723",
        "SMDATE3.BMP": "2460510fbf7b5de9ab91a7cb746b6dde",
        "SMDATE4.BMP": "0fb030e5b05db3be3884cc9c6108f3e5",
        "SMDATE5.BMP": "a8d6976bfd7b074a8fa0e32320bc95d8",
        "SMDATE6.BMP": "dac5d4873668c7d42f8d7d78fc638b48",
        "SMDATE7.BMP": "0ce2a8f9f8f03ccfbb098d847b04057f",
        "SMDATE8.BMP": "bf05826821f44ea7fd2efe72b5df70ff",
        "SMDATE9.BMP": "6bd11ab9be19115ee9c42f1756c48460",
        "SMGFTWAV.BMP": "4f8dd87d041c828fcf9e46491614c681",
        "SMGIFT.BMP": "baa25f66f118fda2c862b0104af96312",
        "SMGLIMSE.BMP": "8bb2693e5280e5c4cb12a4e36689c6a2",
        "SPLASH.BMP": "be774e3ffe2317e3b5648a71c0721ec1",
        "SRAFT.BMP": "9ac5d5ffc488561ce5bf44cb7f92f41d",
        "SSUZY1.BMP": "d62e829fb557835a711765ed2d59f700",
        "SSUZY2.BMP": "04840dc8d733dd68344cfa374ac2bb6f",
        "SSUZY3.BMP": "475be9065f41815daf0cdd4e2697f678",
        "STAND.ADS": "22a9834a8faa510e8d904f5a61bf1bd4",
        "STNDLAY.BMP": "0533fd4c24ca5d75ace867b047b0c5b3",
        "SUZBEACH.SCR": "8d41a89acd35e3e78b95dae0ff435814",
        "SUZY.ADS": "95bd32e7a19a7271627854b03b44e914",
        "SUZYCITY.TTM": "e22d75b680eae301689893d65aefe3ed",
        "TANKER.BMP": "0563137568ac6ca29c74ce20aef26b5c",
        "THEEND.SCR": "d557acf9caf93b7a22a084b608e608c8",
        "THEEND.TTM": "3bf00dc2cad48197466dded0d70de7ed",
        "THEEND1.BMP": "4dbde97ec218f5f0bd892f38db9dba51",
        "THNKBUBL.BMP": "dedaa348d68594b2d210320bdd002d40",
        "TRUNK.BMP": "31d0ec7613a246980c744b83988d29c9",
        "VISITOR.ADS": "2e70d7398cbfe6c7fa49aa1e9ded67f7",
        "WALKSTUF.ADS": "d5f2b4bf18b4fdea72f899f8cd2ae5b1",
        "WOULDBE.BMP": "abd50b221c2a6191418598208c2616a4",
        "WOULDBE.TTM": "0bf6a8c424500e681cc99caade5338a9",
        "ZZZZS.BMP": "8b10146ed4aaebc3274eec5cb0df2bc4",
    ]

    @Test("Snapshot dictionary covers all 180 entries")
    func snapshotCountMatchesArchive() throws {
        let archive = try Self.archive.get()
        #expect(Self.expectedMD5s.count == archive.entries.count,
                "expectedMD5s has \(Self.expectedMD5s.count) entries; archive has \(archive.entries.count)")
    }

    @Test("Every entry's payload MD5 matches its pinned snapshot")
    func payloadMD5Snapshots() throws {
        let archive = try Self.archive.get()

        var missing: [(name: String, md5: String)] = []
        var mismatched: [(name: String, expected: String, actual: String)] = []

        for entry in archive.entries {
            let payload = payloadBytes(for: entry.resource)
            let actual = MD5Hash.hex(payload)
            let key = entry.name.uppercased()
            if let expected = Self.expectedMD5s[key] {
                if expected != actual {
                    mismatched.append((key, expected, actual))
                }
            } else {
                missing.append((key, actual))
            }
        }

        if !missing.isEmpty {
            print("=== Missing snapshots (paste into expectedMD5s) ===")
            for (name, md5) in missing.sorted(by: { $0.name < $1.name }) {
                print("        \"\(name)\": \"\(md5)\",")
            }
            print("===")
        }

        for m in mismatched {
            Issue.record("\(m.name): expected \(m.expected) got \(m.actual)")
        }

        #expect(missing.isEmpty, "\(missing.count) entries missing from expectedMD5s")
        #expect(mismatched.isEmpty, "\(mismatched.count) entries drifted")
    }

    /// Choose the most informative byte sequence per resource kind.
    private func payloadBytes(for resource: Resource) -> Data {
        switch resource {
        case .palette(let p):
            // 256 RGB triplets concatenated.
            var d = Data(capacity: 768)
            for c in p.colors { d.append(c.r); d.append(c.g); d.append(c.b) }
            return d
        case .screen(let s):
            return s.pixels
        case .bitmap(let b):
            return b.pixels
        case .ttmScript(let t):
            return t.bytecode
        case .adsScript(let a):
            return a.bytecode
        case .unrecognised(_, let raw):
            return raw
        }
    }
}
