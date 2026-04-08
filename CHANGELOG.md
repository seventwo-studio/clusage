# Changelog

## [0.1.5](https://github.com/lucasilverentand/clusage/compare/v0.1.4...v0.1.5) (2026-04-08)


### Features

* add per-session tracking with context compounding insights ([2d5f2de](https://github.com/lucasilverentand/clusage/commit/2d5f2de3cf6eddae4f740e1320cb38b785302ee2))
* add token-level insights, API cost equivalent, and activity grid ([4a940f7](https://github.com/lucasilverentand/clusage/commit/4a940f7a040340575c4158b140a5c723b9f921b2))
* make activity grid responsive with GeometryReader ([5c971ec](https://github.com/lucasilverentand/clusage/commit/5c971ec049cd8d7e629d6a661970371cf06f0de6))
* show per-credential import errors inline in accounts page ([1456f04](https://github.com/lucasilverentand/clusage/commit/1456f042981c1c63b8368d7a0200c641b3a6f535))


### Bug Fixes

* add backward-compatible Codable decoding for Account ([d220380](https://github.com/lucasilverentand/clusage/commit/d2203801d5b7e3c309d5569010025cd4e8b7cccf))
* add short delay after system wake before first poll ([64683ec](https://github.com/lucasilverentand/clusage/commit/64683ec1309d26a8a3da114dcf8f28537d1e7aaf))
* add timeout to security dump-keychain to prevent indefinite hang ([38d061d](https://github.com/lucasilverentand/clusage/commit/38d061d9ef786ba1429be6f52aa6a7d1a00f8a00))
* call pruneOldOverrides to prevent unbounded schedule override growth ([e5e3999](https://github.com/lucasilverentand/clusage/commit/e5e39992c11ba3af15b3e00109d709236c57fe22))
* clamp API utilization values at the system boundary ([f8c1e24](https://github.com/lucasilverentand/clusage/commit/f8c1e245a551891bca01555b84acd63a7c10db75))
* clamp elapsedFraction to 0...1 to prevent negative pace targets ([e663310](https://github.com/lucasilverentand/clusage/commit/e663310eb30a3ebab6cbb7366b94768902f65208))
* clamp polling intervals on load to match Settings UI ranges ([bbbf679](https://github.com/lucasilverentand/clusage/commit/bbbf679a1e105862cc400fe96927506aed619ff1))
* correct onboarding text, DaySlot edge case, and minor cleanups ([df25a8b](https://github.com/lucasilverentand/clusage/commit/df25a8b91646b124839a149ccc26b2f32a12102e))
* create ViewModels once and fix app lifecycle handlers ([228a291](https://github.com/lucasilverentand/clusage/commit/228a2918a223633dca23f644b223b13a257ada0f))
* handle missing keychain entries gracefully instead of blocking polls ([0cf1bbf](https://github.com/lucasilverentand/clusage/commit/0cf1bbfca953e9b595bab100e969614deece723e))
* invalidate existing timers before creating new ones in poller ([ff79b9f](https://github.com/lucasilverentand/clusage/commit/ff79b9f871261edcbe85942ab80794cdd0e9a70b))
* make daily target cycle-aware using window start position ([5b970d4](https://github.com/lucasilverentand/clusage/commit/5b970d4a343d395b283d9a3681fc351bbbe11e4b))
* make DateFormatting @MainActor for thread-safe formatter access ([5e69eb7](https://github.com/lucasilverentand/clusage/commit/5e69eb7ee83685933c9f7a1d7056903fc12883fa)), closes [#11](https://github.com/lucasilverentand/clusage/issues/11)
* make DateFormatting thread-safe per-method and fix test signing ([0455f85](https://github.com/lucasilverentand/clusage/commit/0455f85d094187c3fe760e612a94dd761d8cc982))
* make session scanning incremental and batch account removal ([989fff8](https://github.com/lucasilverentand/clusage/commit/989fff862de5e538d8eecaa51ea1a3c835f7689e))
* mark DateFormatter statics as nonisolated(unsafe) for concurrency safety ([36906ce](https://github.com/lucasilverentand/clusage/commit/36906ce231d97d86e520d63689f41e5bc6c9a264))
* percent-encode OAuth refresh token in form body ([7470e8d](https://github.com/lucasilverentand/clusage/commit/7470e8d42462d924d9ec81d55535e169c575197a))
* prune stale monitoring gaps on load ([0a0aa7a](https://github.com/lucasilverentand/clusage/commit/0a0aa7a4234064fb123d68c1a696f28004d4ff0e))
* prune stale snapshots on load to prevent unbounded growth ([eb0451f](https://github.com/lucasilverentand/clusage/commit/eb0451f53e88d57df61695a0554338b9688a5e77))
* re-read account from store in pollWithToken to preserve token expiry ([3602f37](https://github.com/lucasilverentand/clusage/commit/3602f37497df4a231090aa1cedb10a441361a016))
* re-read account in error handlers to avoid reverting store state ([8725bf9](https://github.com/lucasilverentand/clusage/commit/8725bf9ea64db191ee8b29acda37ff18ccdd4f12))
* re-read account in selfRefreshToken to complete stale-copy cleanup ([8897383](https://github.com/lucasilverentand/clusage/commit/88973835156d286e1eb819523d606bc2ed300b9e))
* re-read account in validateTokenOwnership to avoid reverting usage data ([f6a02c3](https://github.com/lucasilverentand/clusage/commit/f6a02c36f61f0ba88f63b42c72943476bc266f12))
* recover individual accounts when array decode fails ([b2e6708](https://github.com/lucasilverentand/clusage/commit/b2e67080721e2dfe2fd8ae135b08511b5bd3e9a4))
* remove existing observers before re-registering in poller start ([c776989](https://github.com/lucasilverentand/clusage/commit/c776989738c39bb8bab6f8ce268224b1aece1716))
* remove force unwrap on app group container URL ([d11fb5a](https://github.com/lucasilverentand/clusage/commit/d11fb5ab87bb8965a801613279f8d61b3aa12d18))
* remove force unwraps in TokenPricing and MenuBarIcon ([6dfe777](https://github.com/lucasilverentand/clusage/commit/6dfe777ff57c0b54a19e465d3c4f2c15c3ba14af))
* remove unused retroactive Int: Identifiable conformance ([eef887d](https://github.com/lucasilverentand/clusage/commit/eef887d2d37812b49b0306f736b02ad069b481f6))
* replace force unwraps with guard let in burst detection ([57aab85](https://github.com/lucasilverentand/clusage/commit/57aab8587c46ba468f4ab39ebbb82841661b4c78))
* replace fragile force unwraps with safe optional access in UsagePoller ([a483314](https://github.com/lucasilverentand/clusage/commit/a4833143453a3b291d670e219fe9419c1ee40afa))
* replace Thread.sleep polling with semaphore in KeychainManager ([71526ba](https://github.com/lucasilverentand/clusage/commit/71526ba3267113c454fe77326cbff8070aa018cf)), closes [#7](https://github.com/lucasilverentand/clusage/issues/7)
* route key events to recordKey during hotkey recording ([501535a](https://github.com/lucasilverentand/clusage/commit/501535ac4b4730f0bf039de1e66ccddf5c2dbfc5))
* save streak data on app termination ([726d548](https://github.com/lucasilverentand/clusage/commit/726d5489f66cab75d50a198733b51ad230410da8))
* strip pre-release suffix before comparing version numbers ([bce0294](https://github.com/lucasilverentand/clusage/commit/bce0294cdd8a7d9760c356e6e1633513895b63ef))
* treat empty token same as missing to avoid doomed API call ([58ec712](https://github.com/lucasilverentand/clusage/commit/58ec7127d43c22106f4640127f2e2ca3fb51ef47))
* use max timestamp instead of last element for staleness decay ([4ff2b08](https://github.com/lucasilverentand/clusage/commit/4ff2b0827b5c86d87127e7d3d07cee2e899aabfd))

## [0.1.4](https://github.com/lucasilverentand/clusage/compare/v0.1.3...v0.1.4) (2026-03-26)


### Features

* improve dashboard cards, chart navigation, and account display ([129dda2](https://github.com/lucasilverentand/clusage/commit/129dda2d8c53622b281ccef009a8426d7eeafd73))
* polish, parity, and credentials file support ([#4](https://github.com/lucasilverentand/clusage/issues/4)) ([f0c1567](https://github.com/lucasilverentand/clusage/commit/f0c1567745018ad467cba6e4d3663e2e51ba2ea5))

## [0.1.3](https://github.com/seventwo-studio/clusage/compare/v0.1.2...v0.1.3) (2026-03-16)


### Features

* proper DMG with Applications symlink and updated actions ([5570bb0](https://github.com/seventwo-studio/clusage/commit/5570bb017fcbab0a03d2daf107e48db12ca21249))


### Bug Fixes

* use ExtensionKit extension type for macOS widget ([8b775ba](https://github.com/seventwo-studio/clusage/commit/8b775ba3b3412bb33808ad863a224b3143fe6bc5))

## [0.1.2](https://github.com/seventwo-studio/clusage/compare/v0.1.1...v0.1.2) (2026-03-16)


### Bug Fixes

* build unsigned then codesign manually for CI ([37845a3](https://github.com/seventwo-studio/clusage/commit/37845a3f555f5952f4d13414f2cc5e8a39382745))

## [0.1.1](https://github.com/seventwo-studio/clusage/compare/v0.1.0...v0.1.1) (2026-03-16)


### Features

* initial commit ([e864e8d](https://github.com/seventwo-studio/clusage/commit/e864e8da0530a5197483b1feed48c5871742165c))


### Bug Fixes

* harden CI workflow against secret exfiltration ([5c5a50a](https://github.com/seventwo-studio/clusage/commit/5c5a50a21e769b5226f77380b1b5c0c74eab31b0))
* use correct action SHAs and install Tuist via Homebrew ([5e913ee](https://github.com/seventwo-studio/clusage/commit/5e913ee76d0a19ec2acdf52fe2445c07748f5d21))
