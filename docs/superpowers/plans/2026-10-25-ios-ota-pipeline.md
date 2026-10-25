# FSNotes iOS OTA Pipeline Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use subagent-driven-development (recommended) or executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Running `./deploy` builds an ad hoc signed FSNotes iOS `.ipa`, publishes it to files.chiq.me under fixed URLs, commits and tags the version bump, and pushes it to the fork. The app gets an "Install Latest" Home Screen quick action and an opt-in DevLog diagnostics channel.

**Architecture:** A Ruby `./deploy` at the repo root replaces `./deploy-ios`. It drives small helper modules in `scripts/deploy/`, each covered by minitest tests in `scripts/deploy/test/`. The upstream identifiers are still rewritten in a throwaway copy of the tree (the existing REBRAND approach), so the checkout keeps upstream's identifiers and merges from upstream stay clean. Team ID and bundle prefix now come from a gitignored `Config/Local.xcconfig` that overrides committed defaults in `Config/FSNotes.xcconfig`. The app reads two build-setting-driven Info.plist keys (`FSNotesOTAManifestURL`, `FSNotesDevLogURL`). Their pure logic is tested by a standalone `swiftc` test runner, because the project has no unit test target.

**Tech Stack:** Ruby 3.2 (stdlib + minitest 6), Xcode 26.3 `xcodebuild`, Swift 5 (UIKit), Python 3 stdlib (DevLog server), the file_server service at `~/c/file_server/files/` (https://files.chiq.me).

**Source of truth:** `~/c/agents-configs/docs/ios-ota-rollout/pipeline-prompt.md`. Read it fully before starting. The reference implementation is `~/c/vvterm`: `deploy`, `scripts/deploy/ipa_builder.rb`, `scripts/deploy/uploader.rb`, `scripts/devlog/server.py`, `VVTerm/Core/Logging/DevLog.swift`, `VVTerm/App/iOS/Composition/AppQuickAction*.swift`, `VVTermTests/App/Lifecycle/AppQuickActionTests.swift`. This plan ports those files and adapts them. Where the plan and vvterm differ, follow the plan.

---

## Context the executor needs (read first)

- **Repo:** `~/c/third-parties/fsnotes` on the macmini. It is a fork of upstream FSNotes (`glushchenko/fsnotes`). The only remote is `github` = `git@github.com:grillermo/fsnotes.git`, the user's fork. **Never push anywhere else.** The default branch is `master`, and releases are cut from `master`. Earlier fork commits went straight to `master`, so do this work on `master` too (or in a worktree merged back to `master` before Task 16).
- **What exists today (HEAD `821b20dd`):**
  - `./deploy-ios` (single Ruby file) and `deploy-ios.md`. They publish to `../file_to_s3/files`, which no longer exists, so publishing is broken. The correct directory is `~/c/file_server/files/`. It already holds the files published earlier: `e58c7006-f8fc-4111-8334-bda7fc96b41f-Install_FSNotes.html`, `fsnotes-manifest.plist`, `fsnotes-icon.png`, `FSNotes-7.3.3-20260924.0748.ipa`, `FSNotes-7.3.3-20260927.1906.ipa`.
  - Commit `821b20dd` added an "Install Latest" quick action: `FSNotes iOS/Helpers/ShortcutIdentifier.swift` (case `installLatest` plus a **hard-coded** manifest URL), `FSNotes iOS/AppDelegate.swift` (always registers the item), and `FSNotes iOS/SceneDelegate.swift` (handles cold launch via `pendingInstallURL` and `windowScene(_:performActionFor:)`). It has no `OTAManifestURL` key, no `exit(0)` and no tests.
- **Targets and versions in `FSNotes.xcodeproj/project.pbxproj`:** there are 10 `XCBuildConfiguration` blocks, and 6 of them carry versions:
  - iOS app (`INFOPLIST_FILE = "FSNotes iOS/Info.plist"`): Debug and Release, `MARKETING_VERSION = 7.3.3`, `CURRENT_PROJECT_VERSION = 339`
  - iOS share extension (`INFOPLIST_FILE = "FSNotes iOS Share/Info.plist"`): Debug and Release, `7.3.3`, `338`
  - macOS (`INFOPLIST_FILE = FSNotes/Info.plist`): `7.3.4`, `718`. **Never touch these.**
  - **Starting version:** iOS is at 7.3.3. The first `./deploy` (patch) releases **7.3.4, build 340**, and app and share extension get the same build number. vvterm's bump regex rewrites every block; this repo must scope the bump to the four iOS blocks.
- **No unit test target, no xcconfig files, no `.env`.** `.gitignore` is upstream's. `build/` is ignored only through `.git/info/exclude`.
- **Schemes:** `FSNotes iOS` (app plus share extension) and `FSNotes` (macOS).
- **Swift:** every target uses `SWIFT_VERSION = 5.0`, with no strict concurrency and no default actor isolation. Drop vvterm's Swift 6 `nonisolated` annotations when porting.
- **Signing:** team `Q3WS4MWCW3` (the user's paid team; PatataTube uses it too). Bundle prefix `com.grillermo.fsnotes`. One "Apple Development" identity is in the keychain. The iPhone 16e UDID is `00008140-001509200E02801C` and is already registered on the portal.
- **DevLog ports are per app, so the servers can run side by side on the macmini.** vvterm already listens on 19480. FSNotes uses **19488**, overridable with `FSNOTES_DEVLOG_PORT`. `scripts/devlog/server.py` and the URL that `./deploy --devlog` bakes in both read that variable, so the two always agree.
- **Icon:** `FSNotes iOS/Assets.xcassets/Icons/AppIconModern.imageset/classic-iOS-Default-1024x1024@1x.png` (1024 px).
- **ntfy:** `sh ~/.claude/skills/ntfy/scripts/ntfy-send.sh` (see `~/.claude/skills/ntfy/SKILL.md`).

### Decisions (already made; do not relitigate)

1. **`./deploy-ios` becomes `./deploy`** and its helpers move to `scripts/deploy/`. `deploy-ios.md` is deleted and its useful content moves into a README section.
2. **REBRAND stays, and `Config/Local.xcconfig` holds its inputs.** The upstream identifiers live in entitlements, Info.plists and Swift sources (`UserDefaultsManagement.swift`, `SandboxBookmark.swift`), and an xcconfig cannot reach those. Turning them into build settings would rewrite upstream files and break clean merges. So `./deploy` reads `DEVELOPMENT_TEAM` and `FSNOTES_BUNDLE_PREFIX` from `Config/Local.xcconfig`, falling back to the committed defaults in `Config/FSNotes.xcconfig`. It rewrites identifiers in a tmp copy, as before. The xcconfig files are **not** attached to the Xcode project, because target-level settings would override them anyway; their header comment says so. A fresh clone still builds in Xcode with upstream's settings. `FSNOTES_TEAM_ID` and `FSNOTES_BUNDLE_PREFIX` env vars still override for a one-off.
3. **Semver plus tags:** `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` are bumped in the four iOS blocks only. Tags are `fsnotes-ota-vX.Y.Z`. The timestamp build numbers go away.
4. **Fixed names:** `fsnotes-manifest.plist`, `fsnotes-icon.png`, `fsnotes-install.html`, and the versioned `FSNotes-X.Y.Z.ipa`. The old UUID page stops being updated by `./deploy`. After the first real deploy it is overwritten **once** with a redirect to `fsnotes-install.html` (Task 16), so the user's existing Home Screen bookmark keeps working.
5. **`--install` (cable/devicectl) is kept.** It is about 15 lines, runs after everything is published and pushed, and is non-fatal. **`--build-only` is kept** too. It builds without bumping, publishing or committing, which is how the unsigned build and `FSNOTES_UNSIGNED=1` get verified without publishing.
6. **`FSNOTES_UNSIGNED=1` works only with `--build-only`.** An unsigned `.ipa` cannot be installed from Safari, and publishing one would break the live install link for the phone.
7. **No `NSAllowsLocalNetworking`.** `FSNotes iOS/Info.plist` already sets `NSAppTransportSecurity → NSAllowsArbitraryLoads = true`, which allows plain HTTP to the LAN. On iOS 10+, adding `NSAllowsLocalNetworking` next to it makes iOS **ignore** `NSAllowsArbitraryLoads`, which would break upstream's arbitrary HTTP loads. This is a deliberate deviation from the spec. The README states it and the Info.plist does not change ATS. `NSLocalNetworkUsageDescription` is added for the iOS 14+ local network prompt that a DevLog build triggers.
8. **The URL mapping lives in the existing `ShortcutIdentifier.swift`** (already compiled into the iOS target only), as a pure static function. It is tested by `scripts/test/swift/main.swift`, compiled with `xcrun swiftc` together with the source files. This avoids adding a test target to upstream's pbxproj.
9. **DevLog** goes into a new `FSNotes iOS/Helpers/DevLog.swift`, registered in the iOS target only, with 4 hand-written pbxproj lines (IDs `1A7E0C032F5000010000A001` for the file ref and `1A7E0C042F5000010000A001` for the build file; both verified unused). The macOS target is untouched.
10. **ntfy is sent by the agent after each deploy, not by the script**, matching vvterm. It is saved as a project memory (Task 15).

## File structure

| Path | Status | Responsibility |
|---|---|---|
| `deploy` | create (`git mv deploy-ios deploy`, then rewrite) | CLI: flags, preflight, prompt, bump with restore guard, build, publish, commit/tag/push, `--install` |
| `scripts/deploy/ui.rb` | create | `UI.bold/green/red/step/die/run` |
| `scripts/deploy/release.rb` | create | dotenv, version math, iOS-scoped pbxproj bump, release notes, option parsing, `RestoreGuard` |
| `scripts/deploy/rebrand.rb` | create | Upstream→own identifier table, tmp-copy + rewrite + leftover check |
| `scripts/deploy/ipa_builder.rb` | create | xcconfig lookup, team/prefix, `DEVELOPER_DIR`, codesign probe, ExportOptions.plist, archive/export, unsigned packaging, profile UDID check |
| `scripts/deploy/uploader.rb` | create | Base URL, publish dir, atomic copy publish, pruning old `.ipa`s |
| `scripts/deploy/install_page.rb` | create | Renders the escaped dark install page |
| `scripts/deploy/test/*_test.rb` | create | minitest for each helper |
| `scripts/test/run` | create | Runs every Ruby test plus the Swift test runner |
| `scripts/test/swift/main.swift` | create | Assertion-based Swift tests for the quick action mapping and DevLog gating |
| `scripts/devlog/server.py` | create | Stdlib DevLog receiver on :19488 (`FSNOTES_DEVLOG_PORT`) |
| `Config/FSNotes.xcconfig` | create | Committed defaults (`com.example.fsnotes`, empty team) |
| `Config/Local.xcconfig` | create, **untracked** | Personal values (gitignored) |
| `.env` | create, **untracked** | `FSNOTES_UPLOAD_BASE=https://files.chiq.me` (gitignored) |
| `.gitignore` | modify | `.env`, `Config/Local.xcconfig`, `/log/`, `/build/` |
| `FSNotes iOS/Helpers/ShortcutIdentifier.swift` | modify | Info.plist-driven `installLatestURL(infoDictionary:)` |
| `FSNotes iOS/AppDelegate.swift` | modify | Register Install Latest only when the key is set; `DevLog.event("app.launch")` |
| `FSNotes iOS/SceneDelegate.swift` | modify | Use the mapping and `exit(0)` 1.5 s after the URL opens |
| `FSNotes iOS/Helpers/DevLog.swift` | create | DevLog sink |
| `FSNotes iOS/Info.plist` | modify | `FSNotesOTAManifestURL`, `FSNotesDevLogURL`, `NSLocalNetworkUsageDescription` |
| `FSNotes.xcodeproj/project.pbxproj` | modify | Register DevLog.swift (iOS target). The deploy itself bumps versions here at release time |
| `README.md` | modify | "Personal OTA builds (this fork)" section |
| `deploy-ios.md` | delete | Content moved to README |

Commit after every task. Each commit message ends with the line `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`. **Do not push** until Task 16, where the deploy pushes.

---

### Task 0: Baseline builds

Record that the untouched tree builds, so a later failure can be attributed to this work.

- [ ] **Step 1: Confirm state**

```bash
cd ~/c/third-parties/fsnotes && git status --short && git rev-parse --abbrev-ref HEAD && git remote -v
```
Expected: empty status, `master`, and only `github  git@github.com:grillermo/fsnotes.git`.

- [ ] **Step 2: iOS simulator build (fast compile check, no signing)**

```bash
cd ~/c/third-parties/fsnotes && xcodebuild -project FSNotes.xcodeproj -scheme "FSNotes iOS" -configuration Debug -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build 2>&1 | grep -E '(: error:|\*\* BUILD)' | tail -5
```
Expected: `** BUILD SUCCEEDED **`.

- [ ] **Step 3: macOS build**

```bash
cd ~/c/third-parties/fsnotes && xcodebuild -project FSNotes.xcodeproj -scheme FSNotes -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build 2>&1 | grep -E '(: error:|\*\* BUILD)' | tail -5
```
Expected: `** BUILD SUCCEEDED **`. If either baseline fails, stop and tell the user. Do not "fix" upstream code.

---

### Task 1: Ignore rules, xcconfig defaults, local secrets

**Files:**
- Modify: `.gitignore`
- Create: `Config/FSNotes.xcconfig`
- Create (untracked): `Config/Local.xcconfig`, `.env`

- [ ] **Step 1: Append to `.gitignore`**

Append these lines to the end of the existing file:

```gitignore

# Personal OTA deploy (./deploy) — local values, never committed
.env
Config/Local.xcconfig
/build/

# DevLog server output (scripts/devlog/server.py)
/log/
```

- [ ] **Step 2: Create `Config/FSNotes.xcconfig`**

```xcconfig
// Defaults for ./deploy (the personal OTA release script). Put your own values
// in Config/Local.xcconfig, which is gitignored and overrides these. See README.md.
//
// These files are read by scripts/deploy/ipa_builder.rb, NOT attached to
// FSNotes.xcodeproj: upstream's identifiers also live in entitlements, Info.plist
// and Swift sources that an xcconfig cannot reach, so ./deploy rewrites them in a
// throwaway copy of the tree (scripts/deploy/rebrand.rb) using the values below.
// A fresh clone therefore still builds in Xcode exactly like upstream.

// Prefix every rebranded identifier hangs off: <prefix> (app),
// <prefix>.FSNotes-iOS-Share, iCloud.<prefix>, group.<prefix>.
FSNOTES_BUNDLE_PREFIX = com.example.fsnotes

// Apple Developer team that signs the ad hoc build. Empty = ./deploy refuses to
// sign (FSNOTES_UNSIGNED=1 ./deploy --build-only still works).
DEVELOPMENT_TEAM =

// The app's Info.plist reads FSNOTES_OTA_MANIFEST_URL and FSNOTES_DEVLOG_URL.
// ./deploy passes them on the xcodebuild command line, because an xcconfig would
// read the // in a URL as a comment. Builds made any other way leave them empty.
```

- [ ] **Step 3: Create the untracked local files**

```bash
cd ~/c/third-parties/fsnotes && printf '%s\n' '// Personal signing values; gitignored. Overrides Config/FSNotes.xcconfig.' 'FSNOTES_BUNDLE_PREFIX = com.grillermo.fsnotes' 'DEVELOPMENT_TEAM = Q3WS4MWCW3' > Config/Local.xcconfig
```

```bash
cd ~/c/third-parties/fsnotes && test -e .env || printf '%s\n' '# ./deploy settings; gitignored. Exported shell variables win over these.' 'FSNOTES_UPLOAD_BASE=https://files.chiq.me' > .env
```

(A hook may block commands that print `.env`. Do not `cat` it.)

- [ ] **Step 4: Verify the ignores**

```bash
cd ~/c/third-parties/fsnotes && git check-ignore -q .env && git check-ignore -q Config/Local.xcconfig && git check-ignore -q log/x && git check-ignore -q build && echo ignored-ok; git status --short
```
Expected: `ignored-ok`, and status shows only `.gitignore` and `Config/FSNotes.xcconfig`.

- [ ] **Step 5: Commit**

```bash
cd ~/c/third-parties/fsnotes && git add .gitignore Config/FSNotes.xcconfig && git commit -m "Add deploy config defaults and ignore local deploy files

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 2: `scripts/deploy/ui.rb` + `scripts/deploy/release.rb` (TDD)

**Files:**
- Create: `scripts/deploy/ui.rb`, `scripts/deploy/release.rb`, `scripts/deploy/test/release_test.rb`, `scripts/test/run`

- [ ] **Step 1: Create `scripts/deploy/ui.rb`**

```ruby
# frozen_string_literal: true

# ui.rb — terminal output and command helpers shared by ../../deploy and the
# other scripts/deploy modules.
module UI
  module_function

  def bold(str) = "\e[1m#{str}\e[0m"
  def green(str) = "\e[32m#{str}\e[0m"
  def red(str) = "\e[31m#{str}\e[0m"
  def step(msg) = puts("\n#{bold("==> #{msg}")}")

  def die(msg)
    warn red("error: #{msg}")
    exit 1
  end

  def run(cmd, chdir:)
    puts "    $ #{cmd}"
    system(cmd, chdir: chdir) or die("command failed: #{cmd}")
  end
end
```

- [ ] **Step 2: Write the failing test `scripts/deploy/test/release_test.rb`**

```ruby
# frozen_string_literal: true

require "minitest/autorun"
require "rbconfig"
require "tmpdir"
require_relative "../release"

class ReleaseTest < Minitest::Test
  PBX = File.read(File.expand_path("../../../FSNotes.xcodeproj/project.pbxproj", __dir__))

  def test_next_version
    assert_equal "7.3.4", Release.next_version("7.3.3", nil)
    assert_equal "7.3.4", Release.next_version("7.3.3", "patch")
    assert_equal "7.4.0", Release.next_version("7.3.3", "minor")
    assert_equal "8.0.0", Release.next_version("7.3.3", "major")
    assert_equal "7.10.0", Release.next_version("7.3.3", "7.10.0")
    assert_raises(ArgumentError) { Release.next_version("7.3.3", "banana") }
    assert_raises(ArgumentError) { Release.next_version("7.3.3", "7.4") }
  end

  def test_tag_for
    assert_equal "fsnotes-ota-v7.3.4", Release.tag_for("7.3.4")
  end

  def test_ios_versions_reads_only_ios_targets
    # iOS app is 7.3.3/339, share extension 7.3.3/338, macOS 7.3.4/718.
    version, build = Release.ios_versions(PBX)
    assert_equal "7.3.3", version
    assert_operator build, :>=, 339
    refute_equal 718, build
  end

  def test_bump_touches_only_the_four_ios_configurations
    bumped = Release.bump_ios_versions(PBX, version: "9.9.9", build: 4242)
    assert_equal 4, bumped.scan("MARKETING_VERSION = 9.9.9;").size
    assert_equal 4, bumped.scan("CURRENT_PROJECT_VERSION = 4242;").size
    # macOS keeps upstream's numbers
    assert_equal PBX.scan(/MARKETING_VERSION = 7\.3\.4;/).size, bumped.scan(/MARKETING_VERSION = 7\.3\.4;/).size
    assert_equal PBX.scan("CURRENT_PROJECT_VERSION = 718;").size, bumped.scan("CURRENT_PROJECT_VERSION = 718;").size
    assert_equal ["9.9.9", 4242], Release.ios_versions(bumped)
    # nothing else changed
    assert_equal PBX.lines.size, bumped.lines.size
  end

  def test_dotenv_never_overrides_existing_values
    Dir.mktmpdir do |dir|
      path = File.join(dir, ".env")
      File.write(path, "# comment\nFSNOTES_UPLOAD_BASE=\"https://files.example.com\"\nexport FSNOTES_X='y'\nFSNOTES_KEEP=from-file\n\nbroken-line\n")
      env = { "FSNOTES_KEEP" => "from-shell" }
      Release.load_dotenv(path, env)
      assert_equal "https://files.example.com", env["FSNOTES_UPLOAD_BASE"]
      assert_equal "y", env["FSNOTES_X"]
      assert_equal "from-shell", env["FSNOTES_KEEP"]
      Release.load_dotenv(File.join(dir, "missing"), env) # no error
    end
  end

  def test_filter_subjects_drops_noise_and_caps_at_eight
    subjects = [
      "Release FSNotes OTA fsnotes-ota-v7.3.4", "Merge branch 'x'", "Bump deps", "wip stuff",
      "Commit pending changes", "", "feat(ios): a", "feat(ios): a",
      *("b".."j").map { |c| "fix: #{c}" }
    ]
    notes = Release.filter_subjects(subjects)
    assert_equal "feat(ios): a", notes.first
    assert_equal 8, notes.size
    refute notes.any? { |n| n =~ /Release FSNotes OTA|Merge|Bump|wip|pending/ }
  end

  def test_normalize_notes_and_release_notes
    bullets = Release.normalize_notes(["- one\n* two", "  ", "• three"])
    assert_equal %w[one two three], bullets
    assert_equal "Fast.\n\n• one", Release.release_notes("7.3.4", summary: "Fast.", bullets: ["one"])
    assert_equal "What's new in 7.3.4:\n\n• one", Release.release_notes("7.3.4", summary: nil, bullets: ["one"])
    assert_equal "Release 7.3.4.", Release.release_notes("7.3.4", summary: nil, bullets: [])
  end

  def test_take_option
    argv = ["minor", "--note", "a", "--note=b", "-s", "S", "--yes"]
    assert_equal %w[a b], Release.take_option(argv, "--note", "-n")
    assert_equal ["S"], Release.take_option(argv, "--summary", "-s")
    assert_equal ["minor", "--yes"], argv
    assert_raises(ArgumentError) { Release.take_option(["--note"], "--note") }
    assert_raises(ArgumentError) { Release.take_option(["--note", "--yes"], "--note") }
  end

  def run_guard(path, body)
    lib = File.expand_path("..", __dir__)
    code = "require #{File.join(lib, 'release').inspect}; g = Release::RestoreGuard.new([#{path.inspect}]); #{body}"
    system(RbConfig.ruby, "-e", code, err: File::NULL)
  end

  def test_restore_guard_restores_on_failure_and_keeps_after_commit
    Dir.mktmpdir do |dir|
      path = File.join(dir, "project.pbxproj")
      File.write(path, "original")
      run_guard(path, "File.write(#{path.inspect}, 'bumped'); exit 1")
      assert_equal "original", File.read(path)

      run_guard(path, "File.write(#{path.inspect}, 'bumped'); raise 'boom'")
      assert_equal "original", File.read(path)

      run_guard(path, "File.write(#{path.inspect}, 'bumped'); Process.kill('INT', Process.pid); sleep 1")
      assert_equal "original", File.read(path)

      run_guard(path, "File.write(#{path.inspect}, 'bumped'); g.commit!; exit 0")
      assert_equal "bumped", File.read(path)
    end
  end
end
```

- [ ] **Step 3: Run it and watch it fail**

```bash
cd ~/c/third-parties/fsnotes && ruby scripts/deploy/test/release_test.rb
```
Expected: a LoadError for `../release`.

- [ ] **Step 4: Implement `scripts/deploy/release.rb`**

```ruby
# frozen_string_literal: true

# release.rb
#
# The pure parts of ../../deploy: reading .env, choosing the next version,
# writing it into the iOS targets of project.pbxproj, the release notes, and
# putting the tree back if a run dies halfway. Kept apart from the script so
# scripts/deploy/test/release_test.rb can check them without building anything.

require "fileutils"
require "shellwords"

module Release
  TAG_PREFIX = "fsnotes-ota-v"

  # The iOS app and its share extension. An extension's CFBundleVersion must
  # match its app's, so both get the same bump. The macOS targets
  # (FSNotes/Info.plist) carry upstream's own version and are never touched.
  IOS_INFO_PLISTS = ["FSNotes iOS/Info.plist", "FSNotes iOS Share/Info.plist"].freeze

  # One XCBuildConfiguration object. Its buildSettings dict closes with three
  # tabs, the object itself with two, so the lazy match stops at the object.
  BUILD_CONFIG = /isa = XCBuildConfiguration;.*?\n\t\t\};/m

  # Commit subjects that tell someone installing the build nothing.
  NOTE_NOISE = /\A(Release FSNotes OTA |Release OTA v|Merge |Commit pending changes|Bump |wip\b)/i
  MAX_NOTES = 8

  module_function

  # Minimal dotenv: KEY=VALUE lines, # comments, optional quotes and `export`.
  # A variable already set (exported in the shell) wins, so a one-off override
  # never needs an edit to .env.
  def load_dotenv(path, env = ENV)
    return unless File.exist?(path)

    File.readlines(path).each do |line|
      line = line.strip
      next if line.empty? || line.start_with?("#")

      key, value = line.split("=", 2)
      next unless key && value

      key = key.strip.sub(/\Aexport\s+/, "")
      env[key] ||= value.strip.gsub(/\A["']|["']\z/, "")
    end
  end

  def next_version(current, arg)
    return arg if arg.to_s.match?(/\A\d+\.\d+\.\d+\z/)

    major, minor, patch = current.split(".").map(&:to_i)
    patch ||= 0
    case arg
    when nil, "patch" then "#{major}.#{minor}.#{patch + 1}"
    when "minor" then "#{major}.#{minor + 1}.0"
    when "major" then "#{major + 1}.0.0"
    else raise ArgumentError, "bad version argument '#{arg}' (use patch|minor|major or X.Y.Z)"
    end
  end

  def tag_for(version) = "#{TAG_PREFIX}#{version}"

  def ios_config?(block)
    IOS_INFO_PLISTS.any? { |plist| block.include?(%(INFOPLIST_FILE = "#{plist}";)) }
  end

  # [marketing version, highest build number] across the iOS configurations.
  def ios_versions(pbx)
    blocks = pbx.scan(BUILD_CONFIG).select { |b| ios_config?(b) }
    raise ArgumentError, "no iOS build configurations in project.pbxproj" if blocks.empty?

    versions = blocks.map { |b| b[/MARKETING_VERSION = ([\d.]+);/, 1] }.compact.uniq
    builds = blocks.map { |b| b[/CURRENT_PROJECT_VERSION = (\d+);/, 1] }.compact.map(&:to_i)
    raise ArgumentError, "iOS targets disagree on MARKETING_VERSION: #{versions.join(', ')}" unless versions.size == 1
    raise ArgumentError, "no CURRENT_PROJECT_VERSION in the iOS targets" if builds.empty?

    [versions.first, builds.max]
  end

  def bump_ios_versions(pbx, version:, build:)
    pbx.gsub(BUILD_CONFIG) do |block|
      next block unless ios_config?(block)

      block.sub(/(MARKETING_VERSION = )[\d.]+;/) { "#{Regexp.last_match(1)}#{version};" }
           .sub(/(CURRENT_PROJECT_VERSION = )\d+;/) { "#{Regexp.last_match(1)}#{build};" }
    end
  end

  def filter_subjects(subjects)
    subjects.map(&:strip).reject { |s| s.empty? || s.match?(NOTE_NOISE) }.uniq.first(MAX_NOTES)
  end

  # Commit subjects since the last release tag (the last 20 commits before the
  # first release), minus noise.
  def notes_from_git(repo)
    last = `git -C #{repo.shellescape} describe --tags --abbrev=0 --match '#{TAG_PREFIX}*' 2>/dev/null`.strip
    range = last.empty? ? "-n 20 HEAD" : "#{last.shellescape}..HEAD"
    filter_subjects(`git -C #{repo.shellescape} log --no-merges --pretty=%s #{range}`.lines)
  end

  def normalize_notes(notes)
    notes.flat_map { |n| n.split("\n") }.map { |n| n.strip.sub(/\A[-*•]\s*/, "") }.reject(&:empty?)
  end

  def release_notes(version, summary:, bullets:)
    headline = summary || (bullets.empty? ? "Release #{version}." : "What's new in #{version}:")
    lines = [headline]
    lines << "" unless bullets.empty?
    lines.concat(bullets.map { |b| "• #{b}" })
    lines.join("\n")
  end

  # Pulls repeatable "--flag value" / "--flag=value" options out of argv, so
  # the version argument stays positional wherever it sits.
  def take_option(argv, *names)
    values = []
    i = 0
    while i < argv.length
      arg = argv[i]
      if names.include?(arg)
        value = argv[i + 1]
        raise ArgumentError, "#{arg} needs a value" if value.nil? || value.start_with?("--")

        values << value
        argv.slice!(i, 2)
      elsif (eq = arg.match(/\A(--[a-z-]+)=(.*)\z/m)) && names.include?(eq[1])
        values << eq[2]
        argv.slice!(i, 1)
      else
        i += 1
      end
    end
    values
  end

  # Snapshots files and puts them back at exit unless #commit! was called.
  # A bump left behind by a failed run would fail the *next* run's clean-tree
  # check with an error pointing nowhere near the run that caused it. UI.die
  # (exit 1), exceptions and Ctrl-C all pass through at_exit, so it covers
  # every way out.
  class RestoreGuard
    def initialize(paths)
      @originals = paths.to_h { |p| [p, File.exist?(p) ? File.binread(p) : nil] }
      @committed = false
      at_exit { restore unless @committed }
    end

    def commit!
      @committed = true
    end

    def restore
      @originals.each do |path, content|
        content.nil? ? FileUtils.rm_f(path) : File.binwrite(path, content)
      end
    end
  end
end
```

- [ ] **Step 5: Run the test and watch it pass**

```bash
cd ~/c/third-parties/fsnotes && ruby scripts/deploy/test/release_test.rb
```
Expected: `0 failures, 0 errors`.

- [ ] **Step 6: Create `scripts/test/run`** (Task 9 extends it with Swift)

```bash
#!/bin/bash
# Runs every non-publishing test for the OTA pipeline: the scripts/deploy Ruby
# helpers and (from Task 9 on) the pure Swift app logic.
set -euo pipefail
cd "$(dirname "$0")/../.."

for test in scripts/deploy/test/*_test.rb; do
  echo "== $test"
  ruby "$test"
done
```

```bash
cd ~/c/third-parties/fsnotes && chmod +x scripts/test/run && scripts/test/run
```
Expected: the release tests pass.

- [ ] **Step 7: Commit**

```bash
cd ~/c/third-parties/fsnotes && git add scripts/deploy/ui.rb scripts/deploy/release.rb scripts/deploy/test/release_test.rb scripts/test/run && git commit -m "Add deploy release helpers with iOS-scoped version bump

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 3: `scripts/deploy/rebrand.rb` (TDD)

This ports the REBRAND table and the tmp copy from `deploy-ios` unchanged in behaviour.

**Files:**
- Create: `scripts/deploy/rebrand.rb`, `scripts/deploy/test/rebrand_test.rb`

- [ ] **Step 1: Write the failing test**

```ruby
# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../rebrand"

class RebrandTest < Minitest::Test
  ROOT = File.expand_path("../../..", __dir__)

  def test_rewrite_maps_every_upstream_identifier
    text = <<~TXT
      PRODUCT_BUNDLE_IDENTIFIER = "co.fluder.mobile.FSNotes-iOS";
      PRODUCT_BUNDLE_IDENTIFIER = "co.fluder.mobile.FSNotes-iOS.FSNotes-iOS-Share";
      <string>iCloud.co.fluder.fsnotes</string>
      <string>$(TeamIdentifierPrefix)co.fluder.fsnotes</string>
      "group.es.fsnot.user.defaults"
      key "co.fluder.fsnotes.pins.shared"
      DEVELOPMENT_TEAM = 866P6MTE92;
    TXT
    out = Rebrand.rewrite(text, prefix: "com.me.fsn", team: "ABCDE12345", pbxproj: true)
    assert_includes out, %("com.me.fsn";)
    assert_includes out, %("com.me.fsn.FSNotes-iOS-Share";)
    assert_includes out, "iCloud.com.me.fsn"
    assert_includes out, "$(TeamIdentifierPrefix)com.me.fsn"
    assert_includes out, "group.com.me.fsn"
    assert_includes out, "co.fluder.fsnotes.pins.shared" # data key, not an identifier
    assert_includes out, "DEVELOPMENT_TEAM = ABCDE12345;"
    assert_empty Rebrand.leftovers(out)
  end

  def test_team_untouched_outside_pbxproj_or_without_team
    assert_includes Rebrand.rewrite("DEVELOPMENT_TEAM = X;", prefix: "p", team: "T", pbxproj: false), "= X;"
    assert_includes Rebrand.rewrite("DEVELOPMENT_TEAM = X;", prefix: "p", team: nil, pbxproj: true), "= X;"
  end

  def test_leftovers_flags_upstream_ids
    refute_empty Rebrand.leftovers("a\niCloud.co.fluder.fsnotes\n")
  end

  def test_copy_and_rebrand_on_the_real_tree
    Dir.mktmpdir do |dir|
      src = Rebrand.copy_and_rebrand(ROOT, File.join(dir, "src"), prefix: "com.me.fsn", team: "ABCDE12345")
      refute Dir.exist?(File.join(src, ".git"))
      refute Dir.exist?(File.join(src, "build"))
      Rebrand::FILES.each { |rel| assert_empty Rebrand.leftovers(File.read(File.join(src, rel))), rel }
      assert_includes File.read(File.join(src, "FSNotes.xcodeproj/project.pbxproj")), %(PRODUCT_BUNDLE_IDENTIFIER = com.me.fsn;)
      # the checkout itself is never modified
      assert_includes File.read(File.join(ROOT, "FSNotes iOS/FSNotes iOS.entitlements")), "iCloud.co.fluder.fsnotes"
    end
  end
end
```

Note: in the pbxproj, `PRODUCT_BUNDLE_IDENTIFIER = "co.fluder.mobile.FSNotes-iOS";` is quoted. After the rewrite it reads `PRODUCT_BUNDLE_IDENTIFIER = "com.me.fsn";`. If the last assertion fails on quoting, check the actual line with `grep -n 'PRODUCT_BUNDLE_IDENTIFIER = "com.me.fsn' "$src/FSNotes.xcodeproj/project.pbxproj"` and change the assertion to `%(PRODUCT_BUNDLE_IDENTIFIER = "com.me.fsn";)`, which is the expected form.

- [ ] **Step 2: Run it and watch it fail**

```bash
cd ~/c/third-parties/fsnotes && ruby scripts/deploy/test/rebrand_test.rb
```
Expected: LoadError.

- [ ] **Step 3: Implement `scripts/deploy/rebrand.rb`**

```ruby
# frozen_string_literal: true

# rebrand.rb
#
# This checkout is upstream FSNotes (glushchenko/fsnotes). Its identifiers --
# bundle IDs co.fluder.mobile.FSNotes-iOS*, iCloud container
# iCloud.co.fluder.fsnotes, app group group.es.fsnot.user.defaults -- belong to
# the upstream author's team, and Apple will not let another team sign for
# them. They live in the pbxproj, entitlements, Info.plists *and Swift sources*,
# which no xcconfig can reach. So every build copies the tree to a tmp dir and
# rewrites them there, under FSNOTES_BUNDLE_PREFIX. The checkout is never
# modified, so merging upstream keeps working without conflicts.
#
# The app finds its iCloud container with url(forUbiquityContainerIdentifier: nil),
# i.e. whatever the entitlements declare, so the rename needs no code change.
# Consequence: this build's iCloud Drive folder is separate from the App Store
# FSNotes' folder.

require "fileutils"
require "shellwords"

module Rebrand
  # Only these files are rewritten. A blanket find/replace would also hit data
  # keys such as "co.fluder.fsnotes.pins.shared" that are not identifiers.
  FILES = [
    "FSNotes.xcodeproj/project.pbxproj",
    "FSNotes iOS/Info.plist",
    "FSNotes iOS/FSNotes iOS.entitlements",
    "FSNotes iOS Share/Info.plist",
    "FSNotes iOS Share/FSNotes iOS Share.entitlements",
    "FSNotes iOS/Extensions/UserDefaultsManagement+.swift",
    "FSNotes iOS/Helpers/SandboxBookmark.swift",
    "FSNotesCore/UserDefaultsManagement.swift",
  ].freeze

  LEFTOVER = /co\.fluder\.mobile|iCloud\.co\.fluder|group\.es\.fsnot/

  # Anchored to the copy's root: build products, logs and secrets stay behind.
  RSYNC_EXCLUDES = %w[/.git /.code-review-graph /build /log /.env /docs].freeze

  module_function

  # Upstream identifier -> ours. Order matters: the plain app ID rule also
  # turns ...FSNotes-iOS.FSNotes-iOS-Share into <prefix>.FSNotes-iOS-Share.
  def table(prefix)
    {
      "co.fluder.mobile.FSNotes-iOS" => prefix,
      "iCloud.co.fluder.fsnotes" => "iCloud.#{prefix}",
      "$(TeamIdentifierPrefix)co.fluder.fsnotes" => "$(TeamIdentifierPrefix)#{prefix}",
      "group.es.fsnot.user.defaults" => "group.#{prefix}",
    }
  end

  def rewrite(text, prefix:, team:, pbxproj:)
    out = table(prefix).reduce(text) { |acc, (from, to)| acc.gsub(from, to) }
    out = out.gsub(/DEVELOPMENT_TEAM = [A-Z0-9]*;/, "DEVELOPMENT_TEAM = #{team};") if pbxproj && team && !team.empty?
    out
  end

  def leftovers(text) = text.lines.grep(LEFTOVER).map(&:strip)

  # Copies repo_root (uncommitted changes included) to dest, rewrites FILES
  # there and returns dest. Raises if a file moved or an identifier survived:
  # upstream added one somewhere new, and FILES needs that path.
  def copy_and_rebrand(repo_root, dest, prefix:, team:)
    FileUtils.mkdir_p(dest)
    excludes = RSYNC_EXCLUDES.map { |e| "--exclude #{e.shellescape}" }.join(" ")
    system("rsync -a #{excludes} #{(repo_root + '/').shellescape} #{(dest + '/').shellescape}") or
      raise "rsync of #{repo_root} failed"

    FILES.each do |rel|
      path = File.join(dest, rel)
      raise "expected #{rel} -- did upstream move it? Update Rebrand::FILES." unless File.exist?(path)

      File.write(path, rewrite(File.read(path), prefix: prefix, team: team, pbxproj: rel.end_with?(".pbxproj")))
    end

    left = FILES.flat_map { |rel| leftovers(File.read(File.join(dest, rel))).map { |l| "#{rel}: #{l}" } }
    raise "upstream identifiers survived the rebrand:\n  #{left.join("\n  ")}" unless left.empty?

    dest
  end
end
```

- [ ] **Step 4: Run the test and watch it pass**

```bash
cd ~/c/third-parties/fsnotes && ruby scripts/deploy/test/rebrand_test.rb
```
Expected: `0 failures, 0 errors` (the copy takes a few seconds; `build/` is 865 MB and excluded).

- [ ] **Step 5: Commit**

```bash
cd ~/c/third-parties/fsnotes && git add scripts/deploy/rebrand.rb scripts/deploy/test/rebrand_test.rb && git commit -m "Move identifier rebrand into scripts/deploy/rebrand.rb

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 4: `scripts/deploy/uploader.rb` (TDD)

**Files:**
- Create: `scripts/deploy/uploader.rb`, `scripts/deploy/test/uploader_test.rb`

- [ ] **Step 1: Write the failing test**

```ruby
# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../uploader"

class UploaderTest < Minitest::Test
  def with_env(vars)
    old = vars.keys.to_h { |k| [k, ENV[k]] }
    vars.each { |k, v| ENV[k] = v }
    yield
  ensure
    old.each { |k, v| ENV[k] = v }
  end

  def test_base_url_strips_slashes_and_requires_a_value
    with_env("FSNOTES_UPLOAD_BASE" => "https://files.example.com//") do
      assert_equal "https://files.example.com", Uploader.base_url
    end
    with_env("FSNOTES_UPLOAD_BASE" => "") do
      assert_raises(SystemExit) { capture_io { Uploader.base_url } }
    end
  end

  def test_default_publish_dir_is_file_server
    with_env("FSNOTES_PUBLISH_DIR" => nil) do
      assert_equal File.join(Dir.home, "c", "file_server", "files"), Uploader.publish_dir
    end
  end

  def test_upload_is_atomic_and_returns_public_url
    Dir.mktmpdir do |dir|
      src = File.join(dir, "src.txt")
      File.write(src, "new")
      out = File.join(dir, "files")
      Dir.mkdir(out)
      File.write(File.join(out, "fsnotes-install.html"), "old")
      with_env("FSNOTES_UPLOAD_BASE" => "https://files.example.com", "FSNOTES_PUBLISH_DIR" => out) do
        url = Uploader.upload(src, name: "fsnotes-install.html")
        assert_equal "https://files.example.com/files/fsnotes-install.html", url
      end
      assert_equal "new", File.read(File.join(out, "fsnotes-install.html"))
      assert_empty Dir.glob(File.join(out, "*.publishing-*"))
    end
  end

  def test_upload_rejects_paths_in_names_and_missing_dir
    Dir.mktmpdir do |dir|
      src = File.join(dir, "a")
      File.write(src, "x")
      with_env("FSNOTES_UPLOAD_BASE" => "https://f.example", "FSNOTES_PUBLISH_DIR" => dir) do
        assert_raises(SystemExit) { capture_io { Uploader.upload(src, name: "../evil") } }
      end
      with_env("FSNOTES_UPLOAD_BASE" => "https://f.example", "FSNOTES_PUBLISH_DIR" => File.join(dir, "nope")) do
        assert_raises(SystemExit) { capture_io { Uploader.check_publish_dir! } }
      end
    end
  end

  def test_prune_keeps_the_newest_ipas
    Dir.mktmpdir do |dir|
      names = %w[FSNotes-7.3.3-20260924.0748.ipa FSNotes-7.3.3-20260927.1906.ipa FSNotes-7.3.4.ipa]
      names.each_with_index do |n, i|
        path = File.join(dir, n)
        File.write(path, n)
        File.utime(Time.now - (100 - i), Time.now - (100 - i), path)
      end
      File.write(File.join(dir, "fsnotes-manifest.plist"), "m")
      with_env("FSNOTES_UPLOAD_BASE" => "https://f.example", "FSNOTES_PUBLISH_DIR" => dir) do
        pruned = Uploader.prune_ipas(keep: 2)
        assert_equal ["FSNotes-7.3.3-20260924.0748.ipa"], pruned
      end
      assert File.exist?(File.join(dir, "FSNotes-7.3.4.ipa"))
      assert File.exist?(File.join(dir, "fsnotes-manifest.plist"))
    end
  end
end
```

- [ ] **Step 2: Run it and watch it fail**

```bash
cd ~/c/third-parties/fsnotes && ruby scripts/deploy/test/uploader_test.rb
```
Expected: LoadError.

- [ ] **Step 3: Implement `scripts/deploy/uploader.rb`**

```ruby
# frozen_string_literal: true

# uploader.rb
#
# Publishes release artifacts into the files/ directory that the file_server
# service behind FSNOTES_UPLOAD_BASE (https://files.chiq.me) serves.
#
# That service runs on this machine (the macmini), so publishing is a copy into
# ~/c/file_server/files, not an HTTP upload: request bodies over ~12 MB stall in
# the Cloudflare tunnel and come back as 524s before the origin sees them.
#
# Every publish lands at exactly the given name and overwrites what was there.
# That gives the install page and manifest URLs that never move, so one Home
# Screen bookmark keeps installing the newest release.

require "fileutils"
require_relative "ui"

module Uploader
  DEFAULT_PUBLISH_DIR = File.join(Dir.home, "c", "file_server", "files")
  IPA_GLOB = "FSNotes-*.ipa"

  module_function

  def base_url
    base = ENV["FSNOTES_UPLOAD_BASE"].to_s
    UI.die("set FSNOTES_UPLOAD_BASE (in .env) to the public URL of your file server, e.g. https://files.chiq.me") if base.empty?
    base.sub(%r{/+\z}, "")
  end

  def public_url(name) = "#{base_url}/files/#{name}"

  # FSNOTES_PUBLISH_DIR overrides it, so a moved service needs no code change.
  def publish_dir
    dir = ENV["FSNOTES_PUBLISH_DIR"].to_s
    dir.empty? ? DEFAULT_PUBLISH_DIR : File.expand_path(dir)
  end

  # ../../deploy calls this in preflight, so a missing service fails before a
  # build rather than after one.
  def check_publish_dir!
    dir = publish_dir
    return dir if File.directory?(dir)

    UI.die(
      "the file_server files/ directory was not found at #{dir}.\n" \
      "  Releases are published by copying into it, because the service serving\n" \
      "  #{base_url} runs on this machine. Set FSNOTES_PUBLISH_DIR if it moved."
    )
  end

  # Publishes `path` under exactly `name` and returns its public URL.
  def upload(path, name:)
    UI.die("file to publish not found: #{path}") unless File.file?(path)
    UI.die("unsafe publish name: #{name.inspect}") unless name == File.basename(name) && !name.start_with?(".")

    target = File.join(check_publish_dir!, name)
    # Copy beside the target, then rename over it: rename is atomic on one
    # filesystem, so a phone downloading a fixed URL never gets half a file.
    staged = "#{target}.publishing-#{Process.pid}"
    begin
      FileUtils.cp(path, staged)
      File.rename(staged, target)
    ensure
      FileUtils.rm_f(staged)
    end
    public_url(name)
  end

  # Old .ipas pile up otherwise. The manifest only ever points at the newest,
  # and the one before stays for a phone mid-download. Returns pruned names.
  def prune_ipas(keep: 2)
    old = Dir.glob(File.join(publish_dir, IPA_GLOB)).sort_by { |f| File.mtime(f) }[0...-keep] || []
    old.each { |f| FileUtils.rm_f(f) }
    old.map { |f| File.basename(f) }
  end
end
```

- [ ] **Step 4: Run the test and watch it pass**

```bash
cd ~/c/third-parties/fsnotes && ruby scripts/deploy/test/uploader_test.rb
```
Expected: `0 failures, 0 errors`.

- [ ] **Step 5: Commit**

```bash
cd ~/c/third-parties/fsnotes && git add scripts/deploy/uploader.rb scripts/deploy/test/uploader_test.rb && git commit -m "Publish OTA files by atomic copy into ~/c/file_server/files

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 5: `scripts/deploy/install_page.rb` (TDD)

**Files:**
- Create: `scripts/deploy/install_page.rb`, `scripts/deploy/test/install_page_test.rb`

- [ ] **Step 1: Write the failing test**

```ruby
# frozen_string_literal: true

require "minitest/autorun"
require_relative "../install_page"

class InstallPageTest < Minitest::Test
  def page(notes: "What's new in 7.3.4:\n\n• fix <b>bold</b> & \"quotes\"")
    InstallPage.render(
      version: "7.3.4", build: 340,
      icon_url: "https://files.example.com/files/fsnotes-icon.png",
      itms_url: "itms-services://?action=download-manifest&url=https://files.example.com/files/fsnotes-manifest.plist",
      notes: notes, bundle_id: "com.me.fsn"
    )
  end

  def test_contains_everything_the_phone_needs
    html = page
    assert_includes html, "<!doctype html>"
    assert_includes html, 'name="viewport"'
    assert_includes html, "color-scheme: dark"
    assert_includes html, 'src="https://files.example.com/files/fsnotes-icon.png"'
    assert_includes html, 'href="itms-services://?action=download-manifest&amp;url=https://files.example.com/files/fsnotes-manifest.plist"'
    assert_includes html, "Version 7.3.4 (build 340)"
    assert_includes html, "Safari"
    assert_includes html, "Add to Home Screen"
    assert_includes html, "registered"
    assert_includes html, "com.me.fsn"
  end

  def test_escapes_inserted_text
    html = page
    assert_includes html, "fix &lt;b&gt;bold&lt;/b&gt; &amp; &quot;quotes&quot;"
    refute_includes html, "<b>bold</b>"
  end
end
```

- [ ] **Step 2: Run it and watch it fail**

```bash
cd ~/c/third-parties/fsnotes && ruby scripts/deploy/test/install_page_test.rb
```
Expected: LoadError.

- [ ] **Step 3: Implement `scripts/deploy/install_page.rb`**

```ruby
# frozen_string_literal: true

# install_page.rb — the self-contained page published as fsnotes-install.html.
# Every value inserted into it goes through h().
module InstallPage
  module_function

  def h(str)
    str.to_s.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;").gsub('"', "&quot;")
  end

  def render(version:, build:, icon_url:, itms_url:, notes:, bundle_id:)
    <<~HTML
      <!doctype html>
      <html lang="en">
      <head>
      <meta charset="utf-8">
      <meta name="viewport" content="width=device-width, initial-scale=1, viewport-fit=cover">
      <title>Install FSNotes</title>
      <link rel="apple-touch-icon" href="#{h(icon_url)}">
      <style>
        :root { color-scheme: dark; }
        body { margin: 0; padding: 2.5rem 1.25rem 4rem; background: #111; color: #f2f2f2;
          font: 16px/1.55 -apple-system, BlinkMacSystemFont, system-ui, sans-serif;
          display: flex; flex-direction: column; align-items: center; }
        main { width: 100%; max-width: 26rem; }
        img.icon { width: 88px; height: 88px; border-radius: 20px; display: block; margin: 0 auto 1.25rem; }
        h1 { font-size: 1.6rem; margin: 0 0 .25rem; text-align: center; }
        .version { text-align: center; color: #9a9a9a; margin: 0 0 2rem; font-size: .95rem; }
        a.install { display: block; background: #0a84ff; color: #fff; text-decoration: none;
          font-weight: 600; font-size: 1.05rem; text-align: center; padding: 1rem;
          border-radius: 14px; margin-bottom: 1.5rem; }
        a.install:active { background: #0868cc; }
        section { border-top: 1px solid #2a2a2a; padding-top: 1.25rem; margin-top: 1.25rem; }
        h2 { font-size: .8rem; text-transform: uppercase; letter-spacing: .08em; color: #8a8a8a; margin: 0 0 .6rem; }
        pre.notes { white-space: pre-wrap; margin: 0; font: inherit; color: #d8d8d8; }
        p { color: #b0b0b0; font-size: .9rem; }
        code { background: #1c1c1c; padding: .15em .4em; border-radius: 5px; font-size: .85em; word-break: break-all; }
      </style>
      </head>
      <body>
      <main>
        <img class="icon" src="#{h(icon_url)}" alt="">
        <h1>FSNotes</h1>
        <p class="version">Version #{h(version)} (build #{h(build)})</p>
        <a class="install" href="#{h(itms_url)}">Install FSNotes</a>
        <p>Open this page in <strong>Safari</strong>; other browsers cannot start an
        install. Then confirm the prompt. Notes and settings are kept.</p>
        <section>
          <h2>What&rsquo;s new</h2>
          <pre class="notes">#{h(notes)}</pre>
        </section>
        <section>
          <h2>Updating later</h2>
          <p>Add this page to your Home Screen (Share &rarr; Add to Home Screen). The
          button always installs the newest release. The app&rsquo;s own
          <strong>Install Latest</strong> quick action (touch and hold its icon) does the same.</p>
        </section>
        <section>
          <h2>Requirements</h2>
          <p>This is an ad hoc build: your device must be registered on the developer
          account <em>before</em> the build is made. A device added later needs a fresh
          <code>./deploy</code>.</p>
          <p>It is signed as <code>#{h(bundle_id)}</code>, so it installs next to the App Store
          FSNotes, and its iCloud Drive folder is separate from the App Store app&rsquo;s.</p>
        </section>
      </main>
      </body>
      </html>
    HTML
  end
end
```

- [ ] **Step 4: Run the test and watch it pass**

```bash
cd ~/c/third-parties/fsnotes && ruby scripts/deploy/test/install_page_test.rb
```
Expected: `0 failures, 0 errors`.

- [ ] **Step 5: Commit**

```bash
cd ~/c/third-parties/fsnotes && git add scripts/deploy/install_page.rb scripts/deploy/test/install_page_test.rb && git commit -m "Add escaped OTA install page renderer

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 6: `scripts/deploy/ipa_builder.rb` (TDD for the pure parts)

**Files:**
- Create: `scripts/deploy/ipa_builder.rb`, `scripts/deploy/test/ipa_builder_test.rb`

- [ ] **Step 1: Write the failing test**

```ruby
# frozen_string_literal: true

require "minitest/autorun"
require "tmpdir"
require_relative "../ipa_builder"

class IpaBuilderTest < Minitest::Test
  def test_xcconfig_local_wins_and_empty_values_fall_through
    Dir.mktmpdir do |dir|
      local = File.join(dir, "Local.xcconfig")
      defaults = File.join(dir, "FSNotes.xcconfig")
      File.write(local, "// c\nDEVELOPMENT_TEAM = ABCDE12345\nFSNOTES_BUNDLE_PREFIX =\n")
      File.write(defaults, "FSNOTES_BUNDLE_PREFIX = com.example.fsnotes\nDEVELOPMENT_TEAM =\n")
      paths = [local, defaults]
      assert_equal "ABCDE12345", IpaBuilder.xcconfig_value("DEVELOPMENT_TEAM", paths: paths)
      assert_equal "com.example.fsnotes", IpaBuilder.xcconfig_value("FSNOTES_BUNDLE_PREFIX", paths: paths)
      assert_nil IpaBuilder.xcconfig_value("MISSING", paths: paths)
      assert_nil IpaBuilder.xcconfig_value("DEVELOPMENT_TEAM", paths: [defaults, File.join(dir, "nope")])
    end
  end

  def test_export_options_plist
    Dir.mktmpdir do |dir|
      path = IpaBuilder.export_options_plist(
        File.join(dir, "ExportOptions.plist"), team: "ABCDE12345",
        manifest: { app_url: "https://f.example/files/FSNotes-7.3.4.ipa?a=1&b=2", icon_url: "https://f.example/files/fsnotes-icon.png" }
      )
      xml = File.read(path)
      assert system("plutil", "-lint", "-s", path), "plist must be valid"
      assert_includes xml, "<string>release-testing</string>"
      assert_includes xml, "<key>signingStyle</key><string>automatic</string>"
      assert_includes xml, "<string>ABCDE12345</string>"
      assert_includes xml, "<string>&lt;none&gt;</string>"
      assert_includes xml, "<key>appURL</key><string>https://f.example/files/FSNotes-7.3.4.ipa?a=1&amp;b=2</string>"
      assert_includes xml, "<key>displayImageURL</key>"
      assert_includes xml, "<key>fullSizeImageURL</key>"
    end
  end

  def test_build_settings_quote_urls
    s = IpaBuilder.build_settings(team: "T", ota_manifest_url: "https://f.example/files/fsnotes-manifest.plist", devlog_url: nil, version_build: 340)
    assert_includes s, "DEVELOPMENT_TEAM=T"
    assert_includes s, "FSNOTES_OTA_MANIFEST_URL=https://f.example/files/fsnotes-manifest.plist"
    assert_includes s, "CURRENT_PROJECT_VERSION=340"
    refute_includes s, "FSNOTES_DEVLOG_URL"
    unsigned = IpaBuilder.build_settings(team: nil, ota_manifest_url: nil, devlog_url: "http://macmini.local:19488/api/devlog", version_build: nil)
    assert_includes unsigned, "CODE_SIGNING_ALLOWED=NO"
    assert_includes unsigned, "FSNOTES_DEVLOG_URL=http://macmini.local:19488/api/devlog"
  end

  def test_resolve_developer_dir_prefers_existing_env
    Dir.mktmpdir do |dir|
      old = ENV["DEVELOPER_DIR"]
      ENV["DEVELOPER_DIR"] = dir
      assert_equal dir, IpaBuilder.resolve_developer_dir
    ensure
      ENV["DEVELOPER_DIR"] = old
    end
  end
end
```

- [ ] **Step 2: Run it and watch it fail**

```bash
cd ~/c/third-parties/fsnotes && ruby scripts/deploy/test/ipa_builder_test.rb
```
Expected: LoadError.

- [ ] **Step 3: Implement `scripts/deploy/ipa_builder.rb`**

```ruby
# frozen_string_literal: true

# ipa_builder.rb
#
# Builds an ad hoc signed FSNotes .ipa from a rebranded copy of the tree
# (rebrand.rb), together with the OTA manifest.plist an itms-services:// link
# points at. Used by ../../deploy.
#
# Signed with the user's paid Apple Developer team (DEVELOPMENT_TEAM in
# Config/Local.xcconfig), which is what lets iOS install it straight from
# Safari, with a signature good for a year. The price: an Ad Hoc profile only
# covers devices registered on the portal *before* the build. A new device means
# registering it, then running ./deploy again.
#
# FSNOTES_UNSIGNED=1 (with --build-only) falls back to an unsigned Payload/ zip,
# so a broken signing setup never blocks getting a binary. That build cannot be
# installed from Safari.

require "fileutils"
require "shellwords"
require "tmpdir"
require_relative "ui"

module IpaBuilder
  APP_NAME  = "FSNotes"
  SCHEME    = "FSNotes iOS"
  PROJECT   = "FSNotes.xcodeproj"
  REPO_ROOT = File.expand_path("../..", __dir__)
  XCCONFIGS = [
    File.join(REPO_ROOT, "Config", "Local.xcconfig"),
    File.join(REPO_ROOT, "Config", "FSNotes.xcconfig"),
  ].freeze
  ICON_SOURCE = File.join(REPO_ROOT, "FSNotes iOS/Assets.xcassets/Icons/AppIconModern.imageset/classic-iOS-Default-1024x1024@1x.png")

  module_function

  def unsigned? = ENV["FSNOTES_UNSIGNED"] == "1"

  # A setting as Xcode would resolve it: Config/Local.xcconfig (gitignored,
  # personal) wins over the committed defaults; empty values fall through.
  def xcconfig_value(key, paths: XCCONFIGS)
    paths.each do |path|
      next unless File.exist?(path)

      value = File.read(path)[/^\s*#{Regexp.escape(key)}\s*=[ \t]*(\S*)/, 1]
      return value if value && !value.empty?
    end
    nil
  end

  def team_id
    id = ENV["FSNOTES_TEAM_ID"].to_s
    id = xcconfig_value("DEVELOPMENT_TEAM").to_s if id.empty?
    UI.die("no DEVELOPMENT_TEAM in Config/Local.xcconfig and no FSNOTES_TEAM_ID set (see README)") if id.empty?
    id
  end

  def bundle_prefix
    prefix = ENV["FSNOTES_BUNDLE_PREFIX"].to_s
    prefix = xcconfig_value("FSNOTES_BUNDLE_PREFIX").to_s if prefix.empty?
    UI.die("no FSNOTES_BUNDLE_PREFIX in Config/*.xcconfig") if prefix.empty?
    prefix
  end

  # xcodebuild needs a full Xcode, not the Command Line Tools. Honour an existing
  # DEVELOPER_DIR, otherwise use the newest /Applications/Xcode*.app.
  def resolve_developer_dir
    env = ENV["DEVELOPER_DIR"]
    return env if env && Dir.exist?(env)

    xcode = Dir.glob("/Applications/Xcode*.app").max
    UI.die("no Xcode.app in /Applications; install Xcode or set DEVELOPER_DIR") unless xcode
    File.join(xcode, "Contents", "Developer")
  end

  # Over SSH, or after the Mac slept, the login keychain is locked and codesign
  # cannot use the signing key: the archive then dies at its first CodeSign
  # step (errSecInternalComponent) after minutes of compiling. Sign a throwaway
  # copy of /usr/bin/true as a probe; if that fails, unlock and probe again.
  def ensure_codesign_can_sign!
    return if unsigned?

    probe = File.join(Dir.tmpdir, "#{APP_NAME}-codesign-probe-#{Process.pid}")
    FileUtils.cp("/usr/bin/true", probe)
    sign = "codesign -f -s 'Apple Development' #{probe.shellescape} >/dev/null 2>&1"
    return if system(sign)

    puts UI.red("    codesign cannot use your signing key -- the login keychain is probably locked.")
    keychain = File.expand_path("~/Library/Keychains/login.keychain-db")
    system("security unlock-keychain #{keychain.shellescape}") or UI.die("could not unlock the login keychain")
    system(sign) or UI.die("codesign still fails after unlocking; try: codesign -f -s 'Apple Development' /tmp/somefile")
  ensure
    FileUtils.rm_f(probe) if probe
  end

  def xml_escape(str) = str.to_s.gsub("&", "&amp;").gsub("<", "&lt;").gsub(">", "&gt;")

  # ExportOptions.plist for `xcodebuild -exportArchive`.
  #
  # `release-testing` is Xcode 15.3+'s name for ad hoc: it re-signs with the
  # team's distribution certificate against an Ad Hoc profile that lists the
  # registered devices. Automatic signing creates certificates and profiles,
  # but NOT App IDs: <prefix> and <prefix>.FSNotes-iOS-Share must exist on the
  # portal (they do since 2026-09-23).
  #
  # thinning <none> keeps one universal .ipa; thinned exports produce
  # per-device variants that a single download URL cannot serve.
  #
  # The `manifest` dict makes xcodebuild write the manifest.plist the
  # itms-services:// link needs, so the manifest can never drift from the
  # binary. appURL is the .ipa's final public URL, known before the build.
  def export_options_plist(path, team:, manifest:)
    entries = [
      "<key>method</key><string>release-testing</string>",
      "<key>teamID</key><string>#{xml_escape(team)}</string>",
      "<key>signingStyle</key><string>automatic</string>",
      "<key>stripSwiftSymbols</key><true/>",
      "<key>thinning</key><string>&lt;none&gt;</string>",
      "<key>destination</key><string>export</string>",
    ]
    if manifest
      entries << <<~PLIST.chomp
        <key>manifest</key>
        <dict>
          <key>appURL</key><string>#{xml_escape(manifest[:app_url])}</string>
          <key>displayImageURL</key><string>#{xml_escape(manifest[:icon_url])}</string>
          <key>fullSizeImageURL</key><string>#{xml_escape(manifest[:icon_url])}</string>
        </dict>
      PLIST
    end
    File.write(path, <<~PLIST)
      <?xml version="1.0" encoding="UTF-8"?>
      <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
      <plist version="1.0">
      <dict>
      #{entries.join("\n")}
      </dict>
      </plist>
    PLIST
    path
  end

  # Command-line build settings. The URLs go here, not in an xcconfig, because
  # an xcconfig reads the // in a URL as a comment. They apply to every target,
  # so the app and its share extension get the same CURRENT_PROJECT_VERSION.
  def build_settings(team:, ota_manifest_url:, devlog_url:, version_build:)
    settings = []
    settings << (team ? "DEVELOPMENT_TEAM=#{team.shellescape}" : "CODE_SIGNING_ALLOWED=NO")
    settings << "CURRENT_PROJECT_VERSION=#{version_build}" if version_build
    settings << "FSNOTES_OTA_MANIFEST_URL=#{ota_manifest_url.shellescape}" if ota_manifest_url
    settings << "FSNOTES_DEVLOG_URL=#{devlog_url.shellescape}" if devlog_url
    settings.join(" ")
  end

  # Archives and exports from `src` (the rebranded copy) inside `work`, which
  # the caller owns and deletes. Returns the .ipa path. With `manifest:`, the
  # export also writes manifest.plist next to the .ipa.
  def build(work:, src:, manifest:, ota_manifest_url:, devlog_url:, version_build:)
    ENV["DEVELOPER_DIR"] = resolve_developer_dir
    puts "    DEVELOPER_DIR=#{ENV['DEVELOPER_DIR']}"
    team = unsigned? ? nil : team_id
    archive = File.join(work, "#{APP_NAME}.xcarchive")
    log = File.join(work, "archive.log")

    UI.step "Archiving (xcodebuild, Release, generic iOS)#{unsigned? ? ' [UNSIGNED]' : ''}"
    # -allowProvisioningUpdates lets Xcode create/refresh profiles for the team
    # from the Apple ID signed in under Xcode -> Settings -> Accounts.
    cmd = "xcodebuild -project #{PROJECT.shellescape} -scheme #{SCHEME.shellescape} " \
          "-configuration Release -destination 'generic/platform=iOS' " \
          "-archivePath #{archive.shellescape} " \
          "#{build_settings(team: team, ota_manifest_url: ota_manifest_url, devlog_url: devlog_url, version_build: version_build)} " \
          "-allowProvisioningUpdates archive"
    puts "    $ #{cmd}"
    puts "    (full log: #{log})"
    # The full xcodebuild output is thousands of lines; show errors and the verdict.
    ok = system("set -o pipefail; #{cmd} 2>&1 | tee #{log.shellescape} | " \
                "{ grep -E '(: error:|^error:|: warning: .*(provision|sign)|\\*\\* )' || true; }", chdir: src)
    unless ok && Dir.exist?(archive)
      ENV["FSNOTES_KEEP_WORK"] = "1"
      UI.die("archive failed -- see #{log}.#{signing_hint(team)}")
    end
    puts UI.green("    archived: #{archive}")

    return package_unsigned(archive, work) if unsigned?

    UI.step "Exporting signed .ipa (ad hoc / release-testing)"
    options = export_options_plist(File.join(work, "ExportOptions.plist"), team: team, manifest: manifest)
    export = File.join(work, "export")
    UI.run("xcodebuild -exportArchive -archivePath #{archive.shellescape} " \
           "-exportPath #{export.shellescape} -exportOptionsPlist #{options.shellescape} " \
           "-allowProvisioningUpdates", chdir: src)
    ipa = Dir.glob(File.join(export, "*.ipa")).first
    UI.die("export produced no .ipa in #{export}.#{signing_hint(team)}") unless ipa
    ipa
  end

  def signing_hint(team)
    return "" unless team

    "\n  If this is a signing failure: check the Apple ID for team #{team} in Xcode -> Settings -> Accounts,\n" \
      "  that the device is registered on the portal (ad hoc only installs on devices registered\n" \
      "  before the build), and that the App IDs #{bundle_prefix} and #{bundle_prefix}.FSNotes-iOS-Share\n" \
      "  exist on the portal (automatic signing creates profiles, not App IDs)."
  end

  # FSNOTES_UNSIGNED=1: zip the .app into Payload/ by hand. ditto --keepParent
  # keeps Payload/ at the root and preserves symlinks inside frameworks.
  def package_unsigned(archive, work)
    app = File.join(archive, "Products", "Applications", "#{APP_NAME}.app")
    UI.die("no #{APP_NAME}.app inside #{archive}") unless Dir.exist?(app)

    UI.step "Packaging .ipa (unsigned)"
    payload = File.join(work, "Payload")
    FileUtils.mkdir_p(payload)
    FileUtils.cp_r(app, payload)
    ipa = File.join(work, "#{APP_NAME}-unsigned.ipa")
    UI.run("ditto -c -k --sequesterRsrc --keepParent #{payload.shellescape} #{ipa.shellescape}", chdir: work)
    ipa
  end

  # Is the device in the ad hoc profile? If not, iOS refuses with a vague
  # "Unable to Install", so say so now instead of after a trip to the phone.
  def profile_includes?(ipa, udid)
    xml = `unzip -p #{ipa.shellescape} 'Payload/*.app/embedded.mobileprovision' 2>/dev/null | security cms -D 2>/dev/null`
    xml.include?(udid)
  end
end
```

- [ ] **Step 4: Run the tests and watch them pass**

```bash
cd ~/c/third-parties/fsnotes && ruby scripts/deploy/test/ipa_builder_test.rb && scripts/test/run
```
Expected: all pass.

- [ ] **Step 5: Probe codesign (no build)**

```bash
cd ~/c/third-parties/fsnotes && ruby -e 'require_relative "scripts/deploy/ipa_builder"; IpaBuilder.ensure_codesign_can_sign!; puts "codesign ok"'
```
Expected: `codesign ok`. If it asks for the keychain password and you cannot type it, stop and ask the user to run this in their own terminal:
```bash
security unlock-keychain ~/Library/Keychains/login.keychain-db
```

- [ ] **Step 6: Commit**

```bash
cd ~/c/third-parties/fsnotes && git add scripts/deploy/ipa_builder.rb scripts/deploy/test/ipa_builder_test.rb && git commit -m "Add ad hoc IPA builder with codesign probe and unsigned fallback

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 7: `./deploy` (replaces `./deploy-ios`)

**Files:**
- Rename: `deploy-ios` → `deploy` (then rewrite the whole file)

- [ ] **Step 1: Rename**

```bash
cd ~/c/third-parties/fsnotes && git mv deploy-ios deploy
```

- [ ] **Step 2: Replace the contents of `deploy` with:**

```ruby
#!/usr/bin/env ruby
# frozen_string_literal: true

# deploy
#
# One-command over-the-air release of FSNotes iOS (this fork): no App Store, no
# TestFlight, no cable.
#
#   1. preflight: master branch, clean tree, new tag, publish dir, codesign
#   2. bump MARKETING_VERSION + CURRENT_PROJECT_VERSION in the iOS targets
#   3. copy the tree to a tmp dir and rewrite upstream identifiers (rebrand.rb)
#   4. archive + export an ad hoc .ipa and its OTA manifest   (ipa_builder.rb)
#   5. publish .ipa, icon, manifest, install page into ~/c/file_server/files
#   6. commit "Release FSNotes OTA fsnotes-ota-vX.Y.Z", tag, push to `github`
#
# Usage:
#   ./deploy                    # bump patch (7.3.3 -> 7.3.4)
#   ./deploy patch|minor|major
#   ./deploy 7.4.0              # explicit version
#   ./deploy --yes              # skip the confirmation prompt
#   ./deploy --summary "Faster search" --note "Fix X" --note "Fix Y"
#                               # release notes; without them, commit subjects
#                               # since the last fsnotes-ota-v* tag are used
#   ./deploy --devlog           # diagnostics build: DevLog -> scripts/devlog/server.py
#   ./deploy --install          # also push the .ipa to the paired iPhone (devicectl)
#   ./deploy --build-only       # build into build/ only: no bump, publish or git
#   FSNOTES_UNSIGNED=1 ./deploy --build-only   # unsigned Payload/ zip
#   ./deploy --help
#
# How it works:
#
# Settings: .env (gitignored) holds FSNOTES_UPLOAD_BASE (https://files.chiq.me)
# and optionally FSNOTES_PUBLISH_DIR (default ~/c/file_server/files),
# FSNOTES_DEVICE_UDID, FSNOTES_DEVLOG_PORT (19488), FSNOTES_DEVLOG_URL. Config/Local.xcconfig (gitignored)
# holds DEVELOPMENT_TEAM and FSNOTES_BUNDLE_PREFIX over the committed defaults in
# Config/FSNotes.xcconfig. FSNOTES_KEEP_WORK=1 keeps the tmp build dir.
#
# Why copy into file_server instead of uploading: the service runs on this Mac,
# and request bodies over ~12 MB stall in the Cloudflare tunnel (524s).
#
# Why fixed names: fsnotes-manifest.plist, fsnotes-icon.png and
# fsnotes-install.html are overwritten by every release, so one Home Screen
# bookmark of the install page (and the app's Install Latest quick action)
# always installs the newest build. Only the .ipa is versioned.
#
# Why the version is bumped and committed: it makes every release a distinct,
# tagged, reproducible commit, and the tag check makes a version impossible to
# release twice. Only the iOS targets are bumped; macOS keeps upstream's numbers.
#
# Instructions and troubleshooting: README.md, "Personal OTA builds".

require_relative "scripts/deploy/ui"
require_relative "scripts/deploy/release"
require_relative "scripts/deploy/rebrand"
require_relative "scripts/deploy/ipa_builder"
require_relative "scripts/deploy/uploader"
require_relative "scripts/deploy/install_page"
require "digest"
require "fileutils"
require "shellwords"
require "tmpdir"

REPO_ROOT      = IpaBuilder::REPO_ROOT
APP_NAME       = IpaBuilder::APP_NAME
PBXPROJ_REL    = "FSNotes.xcodeproj/project.pbxproj"
PBXPROJ        = File.join(REPO_ROOT, PBXPROJ_REL)
REMOTE         = "github" # the user's fork; never push upstream
RELEASE_BRANCH = "master"

Release.load_dotenv(File.join(REPO_ROOT, ".env"))

DEVICE_UDID = ENV.fetch("FSNOTES_DEVICE_UDID", "00008140-001509200E02801C") # iPhone 16e

# --- flags -------------------------------------------------------------------

if ARGV.include?("--help") || ARGV.include?("-h")
  puts File.read(__FILE__)[/^# Usage:\n.*?(?=^# How it works:)/m].gsub(/^# ?/, "")
  exit 0
end

assume_yes = !ARGV.delete("--yes").nil?
devlog     = !ARGV.delete("--devlog").nil?
install    = !ARGV.delete("--install").nil?
build_only = !ARGV.delete("--build-only").nil?
begin
  summary = Release.take_option(ARGV, "--summary", "-s").last
  notes   = Release.normalize_notes(Release.take_option(ARGV, "--note", "--notes", "-n"))
rescue ArgumentError => e
  UI.die(e.message)
end
UI.die("unknown flag(s): #{ARGV.grep(/\A-/).join(' ')} (see --help)") if ARGV.any? { |a| a.start_with?("-") }
UI.die("too many arguments: #{ARGV.join(' ')} (see --help)") if ARGV.size > 1
version_arg = ARGV[0]

if IpaBuilder.unsigned? && !build_only
  UI.die("FSNOTES_UNSIGNED=1 only works with --build-only: an unsigned .ipa cannot be " \
         "installed from Safari, and publishing it would break the live install link")
end

def git(args) = `git -C #{REPO_ROOT.shellescape} #{args}`.strip

# Each app has its own DevLog port so the servers run side by side (vvterm: 19480).
# scripts/devlog/server.py reads the same FSNOTES_DEVLOG_PORT, so the two agree.
devlog_port = ENV["FSNOTES_DEVLOG_PORT"].to_s.empty? ? "19488" : ENV["FSNOTES_DEVLOG_PORT"]
devlog_url = if devlog
  ENV["FSNOTES_DEVLOG_URL"].to_s.empty? ? "http://#{`scutil --get LocalHostName`.strip}.local:#{devlog_port}/api/devlog" : ENV["FSNOTES_DEVLOG_URL"]
end

current, current_build = begin
  Release.ios_versions(File.read(PBXPROJ))
rescue ArgumentError => e
  UI.die(e.message)
end

# The tmp dir holds the rebranded copy, the archive and the export. Removed at
# exit (success or failure) unless FSNOTES_KEEP_WORK=1, which a failed archive
# sets itself so archive.log survives.
work = Dir.mktmpdir("fsnotes-ios-")
at_exit do
  if ENV["FSNOTES_KEEP_WORK"] == "1"
    puts "    (kept #{work})"
  else
    FileUtils.rm_rf(work)
  end
end

def rebranded_copy(work)
  UI.step "Copying working tree + rebranding identifiers"
  team = IpaBuilder.unsigned? ? nil : IpaBuilder.team_id
  src = Rebrand.copy_and_rebrand(REPO_ROOT, File.join(work, "src"), prefix: IpaBuilder.bundle_prefix, team: team)
  puts UI.green("    #{IpaBuilder.bundle_prefix}, iCloud.#{IpaBuilder.bundle_prefix}, group.#{IpaBuilder.bundle_prefix}")
  src
rescue RuntimeError => e
  UI.die(e.message)
end

# --- --build-only --------------------------------------------------------------
# For checking a build without releasing it: no bump, no publish, no git. The
# OTA key is still baked in when FSNOTES_UPLOAD_BASE is set, so the binary
# matches a released one except for its version.

if build_only
  IpaBuilder.ensure_codesign_can_sign!
  base = ENV["FSNOTES_UPLOAD_BASE"].to_s
  ota = base.empty? ? nil : "#{base.sub(%r{/+\z}, '')}/files/fsnotes-manifest.plist"
  puts UI.bold("\n==> Building #{APP_NAME} iOS #{current} (build #{current_build}) -- build only")
  src = rebranded_copy(work)
  ipa = IpaBuilder.build(work: work, src: src, manifest: nil, ota_manifest_url: ota, devlog_url: devlog_url, version_build: nil)
  out = File.join(REPO_ROOT, "build", "#{APP_NAME}-#{current}#{IpaBuilder.unsigned? ? '-unsigned' : ''}#{devlog ? '-devlog' : ''}.ipa")
  FileUtils.mkdir_p(File.dirname(out))
  FileUtils.cp(ipa, out)
  unless IpaBuilder.unsigned?
    puts IpaBuilder.profile_includes?(out, DEVICE_UDID) ? UI.green("    #{DEVICE_UDID} is in the ad hoc profile") : UI.red("    #{DEVICE_UDID} is NOT in the ad hoc profile")
  end
  puts UI.green("\n✓ Built #{out} (not published: --build-only)")
  exit 0
end

# --- preflight ---------------------------------------------------------------
# Nothing here touches the tree or the publish dir.

Uploader.check_publish_dir!

remote_url = git("remote get-url #{REMOTE} 2>/dev/null")
UI.die("remote '#{REMOTE}' is missing") if remote_url.empty?
UI.die("remote '#{REMOTE}' is #{remote_url}, not the grillermo fork; refusing to push there") unless remote_url.include?("grillermo/")

branch = git("rev-parse --abbrev-ref HEAD")
UI.die("on branch '#{branch}', not '#{RELEASE_BRANCH}'; releases are cut from #{RELEASE_BRANCH}") unless branch == RELEASE_BRANCH

dirty = git("status --porcelain")
UI.die("working tree is dirty -- commit or stash before releasing:\n#{dirty}") unless dirty.empty?

version = begin
  Release.next_version(current, version_arg)
rescue ArgumentError => e
  UI.die(e.message)
end
build = current_build + 1
tag   = Release.tag_for(version)
# This check is what makes a version impossible to release twice.
UI.die("tag #{tag} already exists -- choose a new version") if git("tag -l #{tag.shellescape}") == tag

IpaBuilder.ensure_codesign_can_sign! # now, not after minutes of compiling

asset        = "#{APP_NAME}-#{version}.ipa"
ipa_url      = Uploader.public_url(asset)
manifest_url = Uploader.public_url("fsnotes-manifest.plist")
icon_url     = Uploader.public_url("fsnotes-icon.png")
install_url  = Uploader.public_url("fsnotes-install.html")
itms_url     = "itms-services://?action=download-manifest&url=#{manifest_url}"

bullets = notes.empty? ? Release.notes_from_git(REPO_ROOT) : notes
description = Release.release_notes(version, summary: summary, bullets: bullets)

puts UI.bold("\n==> Releasing #{APP_NAME} iOS (OTA) #{current} -> #{version} (build #{current_build} -> #{build})")
puts UI.bold("\n    What's New:")
puts description.lines.map { |l| "      #{l}" }.join
puts "\n    Install page: #{install_url}"
puts "    DevLog:       #{devlog_url} (start scripts/devlog/server.py first)" if devlog_url

unless assume_yes
  print "\n    Continue? [y/N] "
  UI.die("aborted") unless $stdin.gets.to_s.strip.downcase.start_with?("y")
end

# --- bump --------------------------------------------------------------------
# From here the tree is modified; the guard puts project.pbxproj back on any
# exit before the commit (failed build, failed publish, exception, Ctrl-C).

guard = Release::RestoreGuard.new([PBXPROJ])
File.write(PBXPROJ, Release.bump_ios_versions(File.read(PBXPROJ), version: version, build: build))

# --- build -------------------------------------------------------------------

src = rebranded_copy(work)
ipa = IpaBuilder.build(work: work, src: src, manifest: { app_url: ipa_url, icon_url: icon_url },
                       ota_manifest_url: manifest_url, devlog_url: devlog_url, version_build: build)
built_manifest = File.join(File.dirname(ipa), "manifest.plist")
UI.die("export produced no manifest.plist -- cannot publish the OTA route") unless File.exist?(built_manifest)

puts UI.green("    #{asset} -- #{(File.size(ipa) / 1_048_576.0).round(1)} MB  sha256:#{Digest::SHA256.file(ipa).hexdigest[0, 12]}…")
if IpaBuilder.profile_includes?(ipa, DEVICE_UDID)
  puts UI.green("    #{DEVICE_UDID} is in the ad hoc profile")
else
  puts UI.red("    ⚠  #{DEVICE_UDID} is NOT in the ad hoc profile -- register it on the portal and run ./deploy again")
end

# --- publish -----------------------------------------------------------------
# Order matters: each file references the one before it (manifest -> .ipa and
# icon, install page -> manifest), so each must exist before its referrer.

UI.step "Publishing to #{Uploader.publish_dir}"
puts "    #{Uploader.upload(ipa, name: asset)}"
puts "    #{Uploader.upload(IpaBuilder::ICON_SOURCE, name: 'fsnotes-icon.png')}"
puts "    #{Uploader.upload(built_manifest, name: 'fsnotes-manifest.plist')}"
page = File.join(work, "fsnotes-install.html")
File.write(page, InstallPage.render(version: version, build: build, icon_url: icon_url, itms_url: itms_url,
                                    notes: description, bundle_id: IpaBuilder.bundle_prefix))
puts "    #{Uploader.upload(page, name: 'fsnotes-install.html')}"
Uploader.prune_ipas(keep: 2).each { |name| puts "    pruned #{name}" }

# --- commit, tag, push -------------------------------------------------------

UI.step "Committing + pushing"
UI.run("git add #{PBXPROJ_REL.shellescape}", chdir: REPO_ROOT)
UI.run("git commit -q -m #{"Release #{APP_NAME} OTA #{tag}".shellescape}", chdir: REPO_ROOT)
guard.commit! # the bump lives in a commit now; the restore must not undo it
UI.run("git tag #{tag.shellescape}", chdir: REPO_ROOT)

push = "git push #{REMOTE} #{RELEASE_BRANCH} --tags"
puts "    $ #{push}"
unless system(push, chdir: REPO_ROOT)
  # A push can fail after the remote already took it (a flaky hook, a dropped
  # connection on the reply). If the remote has our HEAD, that is success.
  local  = git("rev-parse HEAD")
  remote = git("ls-remote #{REMOTE} refs/heads/#{RELEASE_BRANCH}").split.first.to_s
  UI.die("push failed (remote at #{remote.empty? ? 'nothing' : remote[0, 7]}, we are at #{local[0, 7]})") unless local == remote

  puts UI.green("    remote already at #{local[0, 7]} -- pushed; continuing")
end

# --- optional cable/Wi-Fi install -------------------------------------------

if install
  UI.step "Installing on the iPhone (devicectl)"
  # Non-fatal: the OTA route is already live; the usual failure is a locked phone.
  cmd = "xcrun devicectl device install app --device #{DEVICE_UDID.shellescape} #{ipa.shellescape}"
  puts "    $ #{cmd}"
  system(cmd) or puts UI.red("    ⚠  direct install failed (unlock the iPhone?). The Safari link below already works.")
end

puts UI.green("\n✓ Published #{APP_NAME} iOS OTA #{version} (build #{build}), tagged #{tag}")
puts UI.bold("\n    Install from Safari on the iPhone:")
puts UI.bold("    #{install_url}")
puts "    itms link: #{itms_url}"
```

Note: the `at_exit` for `work` is registered **before** `RestoreGuard`'s. Ruby runs at_exit handlers in reverse order, so the guard restores first and the tmp dir is removed after. Both always run.

- [ ] **Step 3: Syntax-check and help**

```bash
cd ~/c/third-parties/fsnotes && ruby -c deploy && ./deploy --help
```
Expected: `Syntax OK`, then the Usage block with no `#` prefixes.

- [ ] **Step 4: Commit**

```bash
cd ~/c/third-parties/fsnotes && git add deploy && git commit -m "Replace deploy-ios with ./deploy: semver, tags, fixed URLs, file_server publish

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 8: Verify every preflight failure (nothing is published)

Before this task, note the current manifest mtime. It must not change during the task:

```bash
stat -f '%m %N' ~/c/file_server/files/fsnotes-manifest.plist ~/c/file_server/files/e58c7006-f8fc-4111-8334-bda7fc96b41f-Install_FSNotes.html
```

Run each case below and check that the expected error appears and that `git status --short` is empty afterwards (Steps 6 and 7 deliberately make the tree dirty and clean it up).

- [ ] **Step 1: Unknown flag / bad version / too many args**

```bash
cd ~/c/third-parties/fsnotes && ./deploy --bogus; ./deploy banana --yes; ./deploy 1.2.3 4.5.6; ./deploy --note
```
Expected, in order: `unknown flag(s): --bogus`, then `bad version argument 'banana'`, then `too many arguments`, then `--note needs a value`. Each exits 1.

- [ ] **Step 2: Unsigned without --build-only**

```bash
cd ~/c/third-parties/fsnotes && FSNOTES_UNSIGNED=1 ./deploy --yes
```
Expected: `FSNOTES_UNSIGNED=1 only works with --build-only`.

- [ ] **Step 3: Missing publish dir**

```bash
cd ~/c/third-parties/fsnotes && FSNOTES_PUBLISH_DIR=/nonexistent/files ./deploy --yes
```
Expected: `the file_server files/ directory was not found at /nonexistent/files`.

- [ ] **Step 4: Missing upload base (an exported empty value wins over .env)**

```bash
cd ~/c/third-parties/fsnotes && FSNOTES_UPLOAD_BASE= ./deploy --yes
```
Expected: `set FSNOTES_UPLOAD_BASE (in .env)`.

- [ ] **Step 5: Wrong branch**

```bash
cd ~/c/third-parties/fsnotes && git switch -q -c ota-preflight-check && ./deploy --yes; git switch -q master && git branch -q -D ota-preflight-check
```
Expected: `on branch 'ota-preflight-check', not 'master'`.

- [ ] **Step 6: Dirty tree**

```bash
cd ~/c/third-parties/fsnotes && touch preflight-dirty && ./deploy --yes; rm -f preflight-dirty
```
Expected: `working tree is dirty`.

- [ ] **Step 7: Existing tag**

```bash
cd ~/c/third-parties/fsnotes && git tag fsnotes-ota-v7.3.4 && ./deploy --yes; git tag -d fsnotes-ota-v7.3.4
```
Expected: `tag fsnotes-ota-v7.3.4 already exists`.

- [ ] **Step 8: Abort at the prompt (runs the codesign probe)**

```bash
cd ~/c/third-parties/fsnotes && echo n | ./deploy --summary "Preflight check" --note "one"; git status --short
```
Expected: it prints `7.3.3 -> 7.3.4 (build 339 -> 340)`, the notes and the install page URL, then `aborted`. Status is empty. (If the codesign probe asks for the keychain password, see Task 6 Step 5.)

- [ ] **Step 9: Default notes come from git**

```bash
cd ~/c/third-parties/fsnotes && echo n | ./deploy | sed -n '/What/,/Install page/p'
```
Expected: up to 8 bullets from recent commit subjects, with no `Merge`, `Bump`, `wip` or release commits.

- [ ] **Step 10: Confirm nothing was published**

```bash
stat -f '%m %N' ~/c/file_server/files/fsnotes-manifest.plist ~/c/file_server/files/e58c7006-f8fc-4111-8334-bda7fc96b41f-Install_FSNotes.html; ls ~/c/file_server/files | grep -c publishing; cd ~/c/third-parties/fsnotes && git tag -l 'fsnotes-ota-v*'; git status --short
```
Expected: the same mtimes as before, `0` staging files, no tags, empty status. Nothing to commit in this task.

---

### Task 9: Install Latest URL mapping in `ShortcutIdentifier.swift` (TDD with the swiftc runner)

**Files:**
- Create: `scripts/test/swift/main.swift`
- Modify: `scripts/test/run`, `FSNotes iOS/Helpers/ShortcutIdentifier.swift`

- [ ] **Step 1: Write the failing Swift test `scripts/test/swift/main.swift`**

```swift
// Assertion-based tests for the pure Swift logic behind the OTA pipeline.
// FSNotes has no unit test target, and adding one means a large hand edit of
// upstream's project.pbxproj, so scripts/test/run compiles this file together
// with the Foundation-only sources it covers and runs it on macOS.

import Foundation

var failures = 0

func expect(_ condition: @autoclosure () -> Bool, _ message: String, line: Int = #line) {
    if condition() {
        print("ok   \(message)")
    } else {
        failures += 1
        print("FAIL \(message) (main.swift:\(line))")
    }
}

// MARK: - Install Latest quick action

let manifest = "https://files.example.com/files/fsnotes-manifest.plist"
let deployed: [String: Any] = [ShortcutIdentifier.otaManifestURLInfoKey: manifest]

expect(ShortcutIdentifier.otaManifestURLInfoKey == "FSNotesOTAManifestURL", "Info.plist key name")
expect(
    ShortcutIdentifier.installLatestURL(infoDictionary: deployed)
        == URL(string: "itms-services://?action=download-manifest&url=\(manifest)"),
    "a ./deploy build installs from its fixed manifest"
)
expect(ShortcutIdentifier.installLatestURL(infoDictionary: [ShortcutIdentifier.otaManifestURLInfoKey: ""]) == nil,
       "empty key (local build): no action")
expect(ShortcutIdentifier.installLatestURL(infoDictionary: [ShortcutIdentifier.otaManifestURLInfoKey: "  "]) == nil,
       "blank key: no action")
expect(ShortcutIdentifier.installLatestURL(infoDictionary: [:]) == nil, "missing key: no action")
expect(ShortcutIdentifier.installLatestURL(infoDictionary: nil) == nil, "no Info.plist: no action")
expect(ShortcutIdentifier(fullType: "com.grillermo.fsnotes.installLatest") == .installLatest, "shortcut type maps back")
expect(ShortcutIdentifier(fullType: "com.example.unknown") == nil, "unknown shortcut type is ignored")

// MARK: - Done

print(failures == 0 ? "\nall Swift tests passed" : "\n\(failures) Swift test(s) failed")
exit(failures == 0 ? 0 : 1)
```

- [ ] **Step 2: Extend `scripts/test/run`** (full new contents)

```bash
#!/bin/bash
# Runs every non-publishing test for the OTA pipeline: the scripts/deploy Ruby
# helpers and the pure Swift app logic (scripts/test/swift/main.swift).
set -euo pipefail
cd "$(dirname "$0")/../.."

for test in scripts/deploy/test/*_test.rb; do
  echo "== $test"
  ruby "$test"
done

echo "== Swift (swiftc)"
out=$(mktemp -d)
trap 'rm -rf "$out"' EXIT
SWIFT_SOURCES=(
  "FSNotes iOS/Helpers/ShortcutIdentifier.swift"
)
xcrun swiftc -swift-version 5 -o "$out/fsnotes-swift-tests" "${SWIFT_SOURCES[@]}" scripts/test/swift/main.swift
"$out/fsnotes-swift-tests"
```

- [ ] **Step 3: Run it and watch it fail**

```bash
cd ~/c/third-parties/fsnotes && scripts/test/run
```
Expected: swiftc errors such as `type 'ShortcutIdentifier' has no member 'otaManifestURLInfoKey'`.

- [ ] **Step 4: Implement it.** In `FSNotes iOS/Helpers/ShortcutIdentifier.swift`, replace the whole `var url: URL? { ... }` property (the one with the hard-coded `files.chiq.me` URL and the `// ./deploy-ios republishes…` comment above it) with:

```swift
    /// Info.plist key that ./deploy fills with its fixed OTA manifest URL
    /// (`FSNotesOTAManifestURL` = `$(FSNOTES_OTA_MANIFEST_URL)`).
    static let otaManifestURLInfoKey = "FSNotesOTAManifestURL"

    /// The itms-services link Install Latest opens: the same link as the install
    /// page's button. ./deploy republishes the manifest under the same name on
    /// every release, so it always installs the newest build. Builds made
    /// outside ./deploy carry no manifest URL and get nil: nothing to install.
    static func installLatestURL(infoDictionary: [String: Any]?) -> URL? {
        guard let value = infoDictionary?[otaManifestURLInfoKey] as? String,
              !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
              let manifest = URL(string: value) else {
            return nil
        }
        return URL(string: "itms-services://?action=download-manifest&url=\(manifest.absoluteString)")
    }
```

- [ ] **Step 5: Run it and watch it pass**

```bash
cd ~/c/third-parties/fsnotes && scripts/test/run
```
Expected: Ruby tests pass and `all Swift tests passed`. (The iOS app does not compile yet, because SceneDelegate still uses `.url`. Task 10 fixes that. Commit both together at the end of Task 10.)

---

### Task 10: Wire the quick action (AppDelegate, SceneDelegate, Info.plist)

**Files:**
- Modify: `FSNotes iOS/AppDelegate.swift`, `FSNotes iOS/SceneDelegate.swift`, `FSNotes iOS/Info.plist`

- [ ] **Step 1: AppDelegate.** Replace this block:

```swift
        let installLatest = NSLocalizedString("Install Latest", comment: "")
        let shortcutInstallLatest = UIMutableApplicationShortcutItem(
            type: ShortcutIdentifier.installLatest.type,
            localizedTitle: installLatest,
            localizedSubtitle: "",
            icon: UIApplicationShortcutIcon(systemImageName: "arrow.down.app"),
            userInfo: nil
        )

        application.shortcutItems = [shortcutNew, shortcutNewClipboard, shortcutSearch, shortcutInstallLatest]
```

with:

```swift
        var shortcutItems = [shortcutNew, shortcutNewClipboard, shortcutSearch]

        // Only ./deploy builds carry an OTA manifest URL; any other build has no
        // release to install, so it offers no Install Latest action.
        if ShortcutIdentifier.installLatestURL(infoDictionary: Bundle.main.infoDictionary) != nil {
            let installLatest = NSLocalizedString("Install Latest", comment: "")
            shortcutItems.append(UIMutableApplicationShortcutItem(
                type: ShortcutIdentifier.installLatest.type,
                localizedTitle: installLatest,
                localizedSubtitle: "",
                icon: UIApplicationShortcutIcon(systemImageName: "arrow.down.app"),
                userInfo: nil
            ))
        }

        application.shortcutItems = shortcutItems
```

- [ ] **Step 2: SceneDelegate, cold launch.** Replace:

```swift
            if ShortcutIdentifier(fullType: shortcutItem.type) == .installLatest {
                pendingInstallURL = ShortcutIdentifier.installLatest.url
            } else {
```

with:

```swift
            if ShortcutIdentifier(fullType: shortcutItem.type) == .installLatest {
                pendingInstallURL = ShortcutIdentifier.installLatestURL(infoDictionary: Bundle.main.infoDictionary)
            } else {
```

- [ ] **Step 3: SceneDelegate, activation.** Replace:

```swift
        if let url = pendingInstallURL {
            pendingInstallURL = nil
            UIApplication.shared.open(url)
        }
```

with:

```swift
        if let url = pendingInstallURL {
            pendingInstallURL = nil
            openForInstall(url)
        }
```

- [ ] **Step 4: SceneDelegate, performActionFor.** Replace:

```swift
        if ShortcutIdentifier(fullType: shortcutItem.type) == .installLatest,
           let url = ShortcutIdentifier.installLatest.url {
            if windowScene.activationState == .foregroundActive {
                UIApplication.shared.open(url)
            } else {
                pendingInstallURL = url
            }
            completionHandler(true)
            return
        }
```

with:

```swift
        if ShortcutIdentifier(fullType: shortcutItem.type) == .installLatest {
            guard let url = ShortcutIdentifier.installLatestURL(infoDictionary: Bundle.main.infoDictionary) else {
                completionHandler(false)
                return
            }
            if windowScene.activationState == .foregroundActive {
                openForInstall(url)
            } else {
                pendingInstallURL = url
            }
            completionHandler(true)
            return
        }
```

- [ ] **Step 5: SceneDelegate, add the helper** directly after the `windowScene(_:performActionFor:completionHandler:)` method:

```swift

    /// iOS replaces the app bundle under the running process, which crashes it,
    /// and only starts the install once the user leaves the app. Exiting shortly
    /// after the install prompt is up lets the install begin on its own.
    private func openForInstall(_ url: URL) {
        UIApplication.shared.open(url) { opened in
            guard opened else { return }
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                exit(0)
            }
        }
    }
```

- [ ] **Step 6: Info.plist.** In `FSNotes iOS/Info.plist`, directly after

```xml
	<key>CFBundleVersion</key>
	<string>$(CURRENT_PROJECT_VERSION)</string>
```

insert:

```xml
	<!-- Set by ./deploy on the xcodebuild command line; empty builds offer no Install Latest quick action -->
	<key>FSNotesOTAManifestURL</key>
	<string>$(FSNOTES_OTA_MANIFEST_URL)</string>
```

Then lint it:

```bash
cd ~/c/third-parties/fsnotes && plutil -lint "FSNotes iOS/Info.plist"
```
Expected: `OK`.

- [ ] **Step 7: Compile the iOS target and run the tests**

```bash
cd ~/c/third-parties/fsnotes && grep -rn "installLatest.url\|ShortcutIdentifier.installLatest.url" "FSNotes iOS" ; xcodebuild -project FSNotes.xcodeproj -scheme "FSNotes iOS" -configuration Debug -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build 2>&1 | grep -E '(: error:|\*\* BUILD)' | tail -5 && scripts/test/run
```
Expected: no grep hits, `** BUILD SUCCEEDED **`, all tests pass.

- [ ] **Step 8: Commit**

```bash
cd ~/c/third-parties/fsnotes && git add scripts/test "FSNotes iOS/Helpers/ShortcutIdentifier.swift" "FSNotes iOS/AppDelegate.swift" "FSNotes iOS/SceneDelegate.swift" "FSNotes iOS/Info.plist" && git commit -m "feat(ios): drive Install Latest from FSNotesOTAManifestURL and exit for install

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 11: DevLog (iOS only)

**Files:**
- Create: `FSNotes iOS/Helpers/DevLog.swift`
- Modify: `FSNotes.xcodeproj/project.pbxproj` (4 lines), `FSNotes iOS/Info.plist`, `FSNotes iOS/AppDelegate.swift`, `scripts/test/swift/main.swift`, `scripts/test/run`

- [ ] **Step 1: Add failing DevLog tests.** In `scripts/test/swift/main.swift`, insert before `// MARK: - Done`:

```swift
// MARK: - DevLog

expect(DevLog.urlInfoKey == "FSNotesDevLogURL", "DevLog Info.plist key name")
expect(DevLogSink(infoDictionary: nil) == nil, "no Info.plist: DevLog off")
expect(DevLogSink(infoDictionary: [DevLog.urlInfoKey: ""]) == nil, "empty URL (normal build): DevLog off")
expect(DevLogSink(infoDictionary: [DevLog.urlInfoKey: "ftp://macmini.local/x"]) == nil, "non-http URL: DevLog off")
expect(DevLogSink(infoDictionary: [DevLog.urlInfoKey: "http:///api/devlog"]) == nil, "URL without host: DevLog off")
expect(DevLogSink(infoDictionary: [DevLog.urlInfoKey: "http://macmini.local:19488/api/devlog"]) != nil,
       "--devlog build: DevLog on")
expect(!DevLog.isEnabled, "this test binary has no DevLog URL")
var built = false
DevLog.event("test", { built = true; return ["k": "v"] }())
expect(!built, "disabled DevLog never builds its fields (@autoclosure)")
```

And in `scripts/test/run`, change the `SWIFT_SOURCES` array to:

```bash
SWIFT_SOURCES=(
  "FSNotes iOS/Helpers/ShortcutIdentifier.swift"
  "FSNotes iOS/Helpers/DevLog.swift"
)
```

```bash
cd ~/c/third-parties/fsnotes && scripts/test/run
```
Expected: FAIL (`error: no such file … DevLog.swift`).

- [ ] **Step 2: Create `FSNotes iOS/Helpers/DevLog.swift`** (ported from vvterm; Swift 5, so no `nonisolated`)

```swift
//
//  DevLog.swift
//  FSNotes iOS
//
//  Ships diagnostic events to the developer's Mac (scripts/devlog/server.py)
//  so a device build can be debugged without Xcode. Only `./deploy --devlog`
//  bakes the server URL into Info.plist (FSNotesDevLogURL); every other build
//  has none, and `event` then does nothing, not even build its fields.
//
//  Emitting only appends to a bounded buffer under a lock. Sending happens on a
//  utility queue once a second, and failed batches are dropped, so the code
//  being observed never waits on the network.
//

import Foundation

enum DevLog {
    static let urlInfoKey = "FSNotesDevLogURL"

    private static let sink = DevLogSink(infoDictionary: Bundle.main.infoDictionary)

    static var isEnabled: Bool { sink != nil }

    static func event(_ kind: String, _ fields: @autoclosure () -> [String: String] = [:]) {
        sink?.append(kind: kind, fields: fields())
    }

    /// Sends a file (e.g. a screenshot) to the server, stored as log/screens/<name>.
    /// Uploads skip the record buffer, because one image would crowd out many
    /// records, and are dropped when too many are in flight.
    static func upload(_ name: String, _ data: Data) {
        sink?.upload(name: name, data: data)
    }
}

final class DevLogSink: @unchecked Sendable {
    private static let maxBufferedRecords = 2_000
    private static let flushInterval: DispatchTimeInterval = .seconds(1)
    private static let maxUploadsInFlight = 6

    private let endpoint: URL
    private let session = UUID().uuidString
    private let build: String
    private let lock = NSLock()
    private var buffer: [[String: Any]] = []
    private let queue = DispatchQueue(label: "fsnotes.devlog", qos: .utility)
    private var timer: DispatchSourceTimer?
    private var uploadsInFlight = 0

    init?(infoDictionary: [String: Any]?) {
        guard let value = infoDictionary?[DevLog.urlInfoKey] as? String,
              let url = URL(string: value.trimmingCharacters(in: .whitespacesAndNewlines)),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let host = url.host, !host.isEmpty else {
            return nil
        }
        endpoint = url
        let version = infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let number = infoDictionary?["CFBundleVersion"] as? String ?? "?"
        build = "\(version) (\(number))"
        startTimer()
    }

    func append(kind: String, fields: [String: String]) {
        let record: [String: Any] = [
            "t": DevLogSink.timestamp(Date()),
            "kind": kind,
            "meta": fields,
            "session": session,
            "build": build
        ]
        lock.lock()
        if buffer.count < Self.maxBufferedRecords {
            buffer.append(record)
        }
        lock.unlock()
    }

    func upload(name: String, data: Data) {
        guard var components = URLComponents(url: endpoint.appendingPathComponent("screen"), resolvingAgainstBaseURL: false) else {
            return
        }
        components.queryItems = [URLQueryItem(name: "name", value: name)]
        guard let url = components.url else { return }
        lock.lock()
        guard uploadsInFlight < Self.maxUploadsInFlight else {
            lock.unlock()
            return
        }
        uploadsInFlight += 1
        lock.unlock()
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.httpMethod = "POST"
        request.setValue("application/octet-stream", forHTTPHeaderField: "Content-Type")
        URLSession.shared.uploadTask(with: request, from: data) { [weak self] _, _, _ in
            guard let self = self else { return }
            self.lock.lock()
            self.uploadsInFlight -= 1
            self.lock.unlock()
        }.resume()
    }

    private func startTimer() {
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + Self.flushInterval, repeating: Self.flushInterval)
        timer.setEventHandler { [weak self] in self?.flush() }
        self.timer = timer
        timer.resume()
    }

    private func flush() {
        lock.lock()
        let records = buffer
        buffer.removeAll(keepingCapacity: true)
        lock.unlock()
        guard !records.isEmpty,
              let body = try? JSONSerialization.data(withJSONObject: ["records": records]) else {
            return
        }
        var request = URLRequest(url: endpoint, timeoutInterval: 5)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body
        URLSession.shared.dataTask(with: request).resume()
    }

    private static let formatterLock = NSLock()
    private static let formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static func timestamp(_ date: Date) -> String {
        formatterLock.lock()
        defer { formatterLock.unlock() }
        return formatter.string(from: date)
    }
}
```

- [ ] **Step 3: Run the Swift tests**

```bash
cd ~/c/third-parties/fsnotes && scripts/test/run
```
Expected: `all Swift tests passed`.

- [ ] **Step 4: Register DevLog.swift in the iOS target (4 pbxproj edits).** Use the Edit tool with these exact anchors in `FSNotes.xcodeproj/project.pbxproj`. Lines are tab-indented: the first two entries use 2 tabs, the last two use 4.

1. After the line
   `		D7CBAFFE214D5A1C002ECD5A /* ShortcutIdentifier.swift in Sources */ = {isa = PBXBuildFile; fileRef = D7CBAFFD214D5A1C002ECD5A /* ShortcutIdentifier.swift */; };`
   add
   `		1A7E0C042F5000010000A001 /* DevLog.swift in Sources */ = {isa = PBXBuildFile; fileRef = 1A7E0C032F5000010000A001 /* DevLog.swift */; };`
2. After the line
   `		D7CBAFFD214D5A1C002ECD5A /* ShortcutIdentifier.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = ShortcutIdentifier.swift; sourceTree = "<group>"; };`
   add
   `		1A7E0C032F5000010000A001 /* DevLog.swift */ = {isa = PBXFileReference; lastKnownFileType = sourcecode.swift; path = DevLog.swift; sourceTree = "<group>"; };`
3. In the `Helpers` group (`11598D9F2EDCB85F0036E387`), after
   `				D7CBAFFD214D5A1C002ECD5A /* ShortcutIdentifier.swift */,`
   add
   `				1A7E0C032F5000010000A001 /* DevLog.swift */,`
4. In the iOS app's Sources phase, after
   `				D7CBAFFE214D5A1C002ECD5A /* ShortcutIdentifier.swift in Sources */,`
   add
   `				1A7E0C042F5000010000A001 /* DevLog.swift in Sources */,`

Verify:

```bash
cd ~/c/third-parties/fsnotes && grep -c "1A7E0C0[34]2F5000010000A001" FSNotes.xcodeproj/project.pbxproj && plutil -lint FSNotes.xcodeproj/project.pbxproj && xcodebuild -list -project FSNotes.xcodeproj | head -5
```
Expected: `4` (lines), `OK`, and the targets list prints (the project parses).

- [ ] **Step 5: Info.plist keys.** In `FSNotes iOS/Info.plist`, directly after the `FSNotesOTAManifestURL` `<string>` line added in Task 10, insert:

```xml
	<!-- Set by ./deploy --devlog; empty builds send no DevLog records -->
	<key>FSNotesDevLogURL</key>
	<string>$(FSNOTES_DEVLOG_URL)</string>
```

Directly after
```xml
	<key>NSLocationWhenInUseUsageDescription</key>
	<string>Requested when photo attached</string>
```
insert:
```xml
	<key>NSLocalNetworkUsageDescription</key>
	<string>Diagnostic builds send logs to the developer's Mac on your network.</string>
```

Do **not** add `NSAllowsLocalNetworking`. See Decision 7: `NSAllowsArbitraryLoads = true` already allows LAN HTTP, and adding the key would make iOS ignore it.

```bash
cd ~/c/third-parties/fsnotes && plutil -lint "FSNotes iOS/Info.plist"
```

- [ ] **Step 6: Emit one event at launch** so a devlog build proves the path end to end. In `FSNotes iOS/AppDelegate.swift`, at the top of `application(_:didFinishLaunchingWithOptions:)`, directly before `// Setup dynamic shortcuts`, add:

```swift
        DevLog.event("app.launch", ["state": "\(application.applicationState.rawValue)"])

```

- [ ] **Step 7: Build iOS and macOS, run the tests**

```bash
cd ~/c/third-parties/fsnotes && xcodebuild -project FSNotes.xcodeproj -scheme "FSNotes iOS" -configuration Debug -destination 'generic/platform=iOS Simulator' CODE_SIGNING_ALLOWED=NO build 2>&1 | grep -E '(: error:|\*\* BUILD)' | tail -5; xcodebuild -project FSNotes.xcodeproj -scheme FSNotes -configuration Debug -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO build 2>&1 | grep -E '(: error:|\*\* BUILD)' | tail -5; scripts/test/run
```
Expected: two `** BUILD SUCCEEDED **` and all tests pass.

- [ ] **Step 8: Commit**

```bash
cd ~/c/third-parties/fsnotes && git add "FSNotes iOS/Helpers/DevLog.swift" FSNotes.xcodeproj/project.pbxproj "FSNotes iOS/Info.plist" "FSNotes iOS/AppDelegate.swift" scripts/test && git commit -m "feat(ios): add DevLog, enabled only by ./deploy --devlog builds

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 12: `scripts/devlog/server.py`

**Files:**
- Create: `scripts/devlog/server.py`

- [ ] **Step 1: Create the server** (vvterm's, minus the tmux capture)

```python
#!/usr/bin/env python3
"""Receives the DevLog records a `./deploy --devlog` build of FSNotes sends.

A phone cannot write to this machine's filesystem, so the instrumented app POSTs
batches of JSON records to /api/devlog and this server appends them, one per
line, to log/devlog.jsonl, echoing each to stdout so a run can be watched live.
Files sent with DevLog.upload land in log/screens/. Logs are emptied on start,
so they only hold the current run.

    scripts/devlog/server.py                      # 0.0.0.0:19488
    FSNOTES_DEVLOG_PORT=19500 scripts/devlog/server.py
    curl http://$(scutil --get LocalHostName).local:19488/api/devlog/health

Each app has its own DevLog port, so the servers run side by side on this Mac
(vvterm: 19480, FSNotes: 19488). `./deploy --devlog` reads the same
FSNOTES_DEVLOG_PORT for the URL it bakes in, so set it for both or neither.

Stdlib only. It listens on the LAN without auth, so it caps request and file
sizes instead of trusting the client.
"""

import json
import os
import re
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from threading import Lock
from urllib.parse import parse_qs, urlparse

PORT = int(os.getenv("FSNOTES_DEVLOG_PORT", "19488"))
LOG_PATH = Path(os.getenv("FSNOTES_DEVLOG_FILE", Path(__file__).resolve().parents[2] / "log" / "devlog.jsonl"))
SCREENS_DIR = LOG_PATH.parent / "screens"
MAX_REQUEST_BYTES = 1024 * 1024
MAX_RECORDS_PER_REQUEST = 2000
# At the cap the file becomes devlog.jsonl.1, so at most two generations exist.
MAX_LOG_BYTES = 32 * 1024 * 1024
MAX_SCREEN_BYTES = 8 * 1024 * 1024
MAX_SCREENS_BYTES = 512 * 1024 * 1024
SCREEN_NAME = re.compile(r"^[A-Za-z0-9._+-]{1,128}$")

write_lock = Lock()


def append(records):
    lines = []
    for record in records:
        try:
            lines.append(json.dumps(record, ensure_ascii=True, separators=(",", ":")))
        except (TypeError, ValueError):
            continue
    if not lines:
        return 0
    with write_lock:
        if LOG_PATH.exists() and LOG_PATH.stat().st_size >= MAX_LOG_BYTES:
            os.replace(LOG_PATH, LOG_PATH.with_suffix(LOG_PATH.suffix + ".1"))
        with LOG_PATH.open("a", encoding="utf-8") as handle:
            handle.write("\n".join(lines) + "\n")
    for line in lines:
        print(line, flush=True)
    return len(lines)


def screens_size():
    return sum(p.stat().st_size for p in SCREENS_DIR.iterdir() if p.is_file())


def save_screen(name, data):
    if not SCREEN_NAME.match(name) or name.startswith("."):
        return False
    with write_lock:
        if screens_size() + len(data) > MAX_SCREENS_BYTES:
            return False
        (SCREENS_DIR / name).write_bytes(data)
    return True


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        if self.path in ("/health", "/api/devlog/health"):
            self._reply(200, b"ok\n")
        else:
            self._reply(404, b"not found\n")

    def do_POST(self):
        url = urlparse(self.path)
        if url.path == "/api/devlog/screen":
            return self._screen(parse_qs(url.query).get("name", [""])[0])
        if url.path != "/api/devlog":
            return self._reply(404, b"not found\n")
        length = int(self.headers.get("Content-Length") or 0)
        if length <= 0 or length > MAX_REQUEST_BYTES:
            return self._reply(413, b"bad size\n")
        try:
            payload = json.loads(self.rfile.read(length))
            records = payload["records"]
            if not isinstance(records, list) or len(records) > MAX_RECORDS_PER_REQUEST:
                raise ValueError("records")
        except (ValueError, KeyError, TypeError):
            return self._reply(400, b"bad payload\n")
        append([r for r in records if isinstance(r, dict)])
        self._reply(204, b"")

    def _screen(self, name):
        length = int(self.headers.get("Content-Length") or 0)
        if length <= 0 or length > MAX_SCREEN_BYTES:
            return self._reply(413, b"bad size\n")
        data = self.rfile.read(length)
        if not save_screen(name, data):
            return self._reply(400, b"bad name or screens full\n")
        print(json.dumps({"kind": "screen.file", "name": name, "bytes": length}), flush=True)
        self._reply(204, b"")

    def _reply(self, status, body):
        self.send_response(status)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        if body:
            self.wfile.write(body)

    def log_message(self, *args):
        # Records already go to stdout; per-request access lines would bury them.
        pass


def main():
    LOG_PATH.parent.mkdir(parents=True, exist_ok=True)
    LOG_PATH.write_text("")
    LOG_PATH.with_suffix(LOG_PATH.suffix + ".1").unlink(missing_ok=True)
    SCREENS_DIR.mkdir(parents=True, exist_ok=True)
    for old in SCREENS_DIR.iterdir():
        if old.is_file():
            old.unlink()
    server = ThreadingHTTPServer(("0.0.0.0", PORT), Handler)
    print(f"devlog: listening on :{PORT}, writing {LOG_PATH}", file=sys.stderr, flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass


if __name__ == "__main__":
    main()
```

- [ ] **Step 2: Exercise it on its default port 19488** (vvterm's server keeps 19480, so both can run). First check that 19488 is free: `lsof -nP -iTCP:19488 -sTCP:LISTEN` should print nothing. Then start the server with the Bash tool's `run_in_background: true`:

```bash
cd ~/c/third-parties/fsnotes && chmod +x scripts/devlog/server.py && scripts/devlog/server.py
```

Then:

```bash
curl -s http://127.0.0.1:19488/api/devlog/health; curl -s http://127.0.0.1:19488/health; curl -s -o /dev/null -w '%{http_code}\n' -X POST -H 'Content-Type: application/json' --data '{"records":[{"t":"x","kind":"app.launch","meta":{},"session":"s","build":"7.3.3 (339)"}]}' http://127.0.0.1:19488/api/devlog; curl -s -o /dev/null -w '%{http_code}\n' -X POST --data 'nope' http://127.0.0.1:19488/api/devlog; curl -s -o /dev/null -w '%{http_code}\n' -X POST --data-binary 'PNGDATA' 'http://127.0.0.1:19488/api/devlog/screen?name=shot.png'; curl -s -o /dev/null -w '%{http_code}\n' -X POST --data-binary 'x' 'http://127.0.0.1:19488/api/devlog/screen?name=../evil'; head -c 1100000 /dev/zero | curl -s -o /dev/null -w '%{http_code}\n' -X POST --data-binary @- http://127.0.0.1:19488/api/devlog; cat ~/c/third-parties/fsnotes/log/devlog.jsonl; ls ~/c/third-parties/fsnotes/log/screens; cd ~/c/third-parties/fsnotes && git status --short
```
Expected: `ok`, `ok`, `204`, `400`, `204`, `400`, `413`, the one record line, `shot.png`, and git status showing only `?? scripts/devlog/` (`log/` is ignored). Then stop the background server (TaskStop, or `pkill -f 'scripts/devlog/server.py'` **only** if `ps` shows the FSNotes path; never kill vvterm's server).

- [ ] **Step 3: Commit**

```bash
cd ~/c/third-parties/fsnotes && git add scripts/devlog/server.py && git commit -m "Add stdlib DevLog server for ./deploy --devlog builds

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 13: Build verification without publishing

- [ ] **Step 1: Unsigned build-only**

```bash
cd ~/c/third-parties/fsnotes && FSNOTES_UNSIGNED=1 ./deploy --build-only 2>&1 | tail -15
```
Expected: `** ARCHIVE SUCCEEDED **`, `Packaging .ipa (unsigned)`, `✓ Built …/build/FSNotes-7.3.3-unsigned.ipa`.

```bash
cd ~/c/third-parties/fsnotes && unzip -l build/FSNotes-7.3.3-unsigned.ipa | grep -m1 'Payload/FSNotes.app/' && unzip -p build/FSNotes-7.3.3-unsigned.ipa Payload/FSNotes.app/Info.plist | plutil -p - | grep -E 'CFBundleIdentifier|FSNotesOTAManifestURL|FSNotesDevLogURL|CFBundleShortVersionString|CFBundleVersion'
```
Expected: `CFBundleIdentifier => "com.grillermo.fsnotes"`, `FSNotesOTAManifestURL => "https://files.chiq.me/files/fsnotes-manifest.plist"`, `FSNotesDevLogURL => ""`, version `7.3.3`, build `339`.

- [ ] **Step 2: Unsigned devlog build-only**

```bash
cd ~/c/third-parties/fsnotes && FSNOTES_UNSIGNED=1 ./deploy --build-only --devlog 2>&1 | tail -3 && unzip -p build/FSNotes-7.3.3-unsigned-devlog.ipa Payload/FSNotes.app/Info.plist | plutil -p - | grep FSNotesDevLogURL
```
Expected: `FSNotesDevLogURL => "http://macmini.local:19488/api/devlog"`.

- [ ] **Step 3: Signed build-only (exercises signing, publishes nothing)**

```bash
cd ~/c/third-parties/fsnotes && ./deploy --build-only 2>&1 | tail -12
```
Expected: `ARCHIVE SUCCEEDED`, the export succeeds, `00008140-001509200E02801C is in the ad hoc profile`, and `✓ Built …/build/FSNotes-7.3.3.ipa`. A signing failure prints the hint from `signing_hint`; report it to the user rather than working around it.

- [ ] **Step 4: Tree still clean, nothing published**

```bash
cd ~/c/third-parties/fsnotes && git status --short; stat -f '%m %N' ~/c/file_server/files/fsnotes-manifest.plist; ls /tmp | grep -c fsnotes-ios- || true
```
Expected: empty status, the same mtime as in Task 8, and no leftover `fsnotes-ios-*` tmp dirs (Dir.mktmpdir uses `$TMPDIR`; also check `ls "$TMPDIR" | grep fsnotes-ios-`).

---

### Task 14: README section; remove `deploy-ios.md`

**Files:**
- Modify: `README.md` (append a section)
- Delete: `deploy-ios.md`

- [ ] **Step 1: Append to `README.md`**

````markdown

## Personal OTA builds (this fork)

This fork (`grillermo/fsnotes`) adds `./deploy`, which builds FSNotes iOS signed
**ad hoc** with your own Apple Developer team and publishes it to
`files.chiq.me`, so an iPhone installs it from Safari. No App Store, TestFlight
or cable is involved.

**Install / update (open on the iPhone in Safari):**
<https://files.chiq.me/files/fsnotes-install.html>. Add it to the Home Screen
once. The URL never changes and always installs the newest release. The app's
**Install Latest** quick action (touch and hold the icon) does the same.

### Setup (once per machine)

- `.env` (gitignored): `FSNOTES_UPLOAD_BASE=https://files.chiq.me`. Optional:
  `FSNOTES_PUBLISH_DIR` (default `~/c/file_server/files`, the directory the
  file_server service behind files.chiq.me serves), `FSNOTES_DEVICE_UDID`,
  `FSNOTES_DEVLOG_PORT` (default 19488), `FSNOTES_DEVLOG_URL`. A variable exported in the shell wins over `.env`.
- `Config/Local.xcconfig` (gitignored) overrides `Config/FSNotes.xcconfig`:
  ```
  FSNOTES_BUNDLE_PREFIX = com.grillermo.fsnotes
  DEVELOPMENT_TEAM = Q3WS4MWCW3
  ```
- Xcode → Settings → Accounts is signed in to that team. The App IDs
  `<prefix>` and `<prefix>.FSNotes-iOS-Share` exist on the developer portal
  (automatic signing creates profiles, not App IDs), and every iPhone is
  registered there **before** the build. An ad hoc profile only contains
  devices registered before it was made.

### Usage

```bash
./deploy                       # bump patch, build, publish, commit, tag, push
./deploy minor                 # or major, or an explicit 7.4.0
./deploy --summary "Faster search" --note "Fix X" --note "Fix Y"
./deploy --yes                 # no confirmation prompt
./deploy --devlog              # diagnostics build (see below)
./deploy --install             # also push to the paired iPhone with devicectl
./deploy --build-only          # build into build/ only: no bump, publish or git
FSNOTES_UNSIGNED=1 ./deploy --build-only   # unsigned Payload/ zip
```

Without notes, the commit subjects since the last `fsnotes-ota-v*` tag are
used (merges, release commits, "Bump" and "wip" are skipped; 8 at most).

Before changing anything, `./deploy` checks that you are on `master` with a
clean tree, that the tag `fsnotes-ota-vX.Y.Z` does not exist yet, that the
publish directory exists, and that codesign can sign. Over SSH the login
keychain is locked; it then runs `security unlock-keychain`. It bumps
`MARKETING_VERSION`/`CURRENT_PROJECT_VERSION` in the **iOS targets only**
(macOS keeps upstream's numbers) and restores `project.pbxproj` if the run
dies before the release commit. It pushes only to the `github` remote (this
fork).

### How it works

- Upstream's identifiers (`co.fluder.mobile.FSNotes-iOS*`,
  `iCloud.co.fluder.fsnotes`, `group.es.fsnot.user.defaults`) belong to
  upstream's team. They are rewritten to `FSNOTES_BUNDLE_PREFIX` in a **tmp
  copy** of the tree (`scripts/deploy/rebrand.rb`), so this checkout keeps
  merging cleanly from upstream. Consequence: this build installs next to the
  App Store FSNotes, and its iCloud Drive folder is separate from the App Store
  app's. Copy notes over with the Files app.
- `xcodebuild archive` + `-exportArchive` with `method = release-testing` (ad
  hoc) and `thinning = <none>`. The export writes the `itms-services` manifest
  itself.
- Files are **copied** into the file_server directory (large uploads stall in
  the Cloudflare tunnel), each via a `.publishing-<pid>` temp name and a rename.
  The order is `.ipa`, `fsnotes-icon.png`, `fsnotes-manifest.plist`,
  `fsnotes-install.html`. Only the `.ipa` (`FSNotes-X.Y.Z.ipa`) is versioned,
  and the last two are kept.
- `FSNotesOTAManifestURL` and `FSNotesDevLogURL` are passed to xcodebuild as
  command-line build settings (an xcconfig would read the `//` in a URL as a
  comment). Builds made any other way leave them empty and get neither the
  Install Latest action nor DevLog.

### DevLog (`./deploy --devlog`)

The build sends `DevLog.event(...)` records to
`http://<LocalHostName>.local:19488/api/devlog` on this Mac (port override: `FSNOTES_DEVLOG_PORT`, read by both `./deploy --devlog` and the server). Start the receiver
first and check it:

```bash
scripts/devlog/server.py
```

```bash
curl http://$(scutil --get LocalHostName).local:19488/api/devlog/health
```

Records go to `log/devlog.jsonl` (gitignored) and uploads to `log/screens/`.
vvterm's server uses 19480, so both can run side by side. The Info.plist already
allows plain HTTP (`NSAllowsArbitraryLoads`). `NSAllowsLocalNetworking` is
deliberately **not** added, because on iOS 10+ it makes iOS ignore
`NSAllowsArbitraryLoads`.

### Tests (no publishing)

```bash
scripts/test/run
```

### Troubleshooting

| Symptom | Fix |
|---|---|
| Install does nothing | Use **Safari**, on the files.chiq.me page. |
| "Unable to Install FSNotes" | The device is not in the profile (`./deploy` warns). Register the UDID, then deploy again. |
| `codesign cannot use your signing key` | Enter the login password when prompted, or run `security unlock-keychain ~/Library/Keychains/login.keychain-db` first. |
| Archive fails with `No Account for Team` / `No profiles` | Sign in again under Xcode → Settings → Accounts. Rerun with `FSNOTES_KEEP_WORK=1` and read `archive.log`. |
| `upstream identifiers survived the rebrand` | Upstream added an identifier to a new file. Add it to `Rebrand::FILES`. |
| `working tree is dirty` after a failed run | Should not happen (the bump is restored). Check `git diff FSNotes.xcodeproj/project.pbxproj`. |
````

- [ ] **Step 2: Delete the old doc and check for stale references**

```bash
cd ~/c/third-parties/fsnotes && git rm -q deploy-ios.md && grep -rn "deploy-ios\|file_to_s3" --exclude-dir=.git --exclude-dir=build --exclude-dir=docs . || echo "no stale references"
```
Expected: `no stale references`.

- [ ] **Step 3: Commit**

```bash
cd ~/c/third-parties/fsnotes && git add README.md && git commit -m "Document ./deploy OTA builds in README; drop deploy-ios.md

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>"
```

---

### Task 15: Project memory: ntfy after every deploy

**Files (outside the repo, not committed):**
- Create: `~/.claude/projects/-Users-grillermo-c-third-parties-fsnotes/memory/deploy-ntfy-install-link.md`
- Create or append: `~/.claude/projects/-Users-grillermo-c-third-parties-fsnotes/memory/MEMORY.md`

- [ ] **Step 1: Write the memory**

```markdown
---
name: deploy-ntfy-install-link
description: "After every ./deploy of FSNotes iOS, send an ntfy notification whose tap starts the OTA install"
metadata:
  type: feedback
---

After every `./deploy` (OTA release) of FSNotes iOS in ~/c/third-parties/fsnotes, send an ntfy notification (ntfy skill) with the version in the message, so tapping it starts the install.

**Why:** the OTA pipeline spec (~/c/agents-configs/docs/ios-ota-rollout/pipeline-prompt.md, section 5) requires it on every deploy, as for vvterm.

**How to apply:** on success:
`sh ~/.claude/skills/ntfy/scripts/ntfy-send.sh -t "FSNotes" -T rocket -u 'itms-services://?action=download-manifest&url=https://files.chiq.me/files/fsnotes-manifest.plist' -l https://files.chiq.me/files/fsnotes-install.html -L "Install page" "FSNotes <version> (build <build>) is ready. Tap to install."`
`-u` (the tap target) is the itms-services link itself. `-l` only takes http(s), so the install page is the button. On failure, send the failure instead with `-p high -T x` and the failing step.
```

And add this line to `MEMORY.md` (create the file if it is missing):

```markdown
- [Deploy → ntfy install link](deploy-ntfy-install-link.md) — after every ./deploy, ntfy the itms-services install link
```

- [ ] **Step 2: Dry-run the notification** (sends nothing)

```bash
sh ~/.claude/skills/ntfy/scripts/ntfy-send.sh --dry-run -t "FSNotes" -T rocket -u 'itms-services://?action=download-manifest&url=https://files.chiq.me/files/fsnotes-manifest.plist' -l https://files.chiq.me/files/fsnotes-install.html -L "Install page" "FSNotes 7.3.4 (build 340) is ready. Tap to install."
```
Expected: the preview prints without errors. If the script rejects `-u` with a non-http URL, tell the user and use the install page as both `-u` and `-l`.

---

### Task 16: Ask the user before the one real `./deploy`

**Do not run `./deploy` (without `--build-only`) until the user explicitly approves in chat.**

- [ ] **Step 1: Final checks**

```bash
cd ~/c/third-parties/fsnotes && scripts/test/run && git status --short && git log --oneline -15 && git remote -v
```
Expected: tests pass, the tree is clean, the commits from Tasks 1–14 are present, and the remote is the fork.

- [ ] **Step 2: Ask the user.** Report what was verified (Tasks 8, 10, 11, 13) and ask for approval to run:

```bash
cd ~/c/third-parties/fsnotes && ./deploy --yes --summary "First release from the new ./deploy pipeline"
```
Tell them what it will do: release **7.3.3 → 7.3.4 (build 340)**, publish `FSNotes-7.3.4.ipa` plus the fixed-name files into `~/c/file_server/files`, prune the older `.ipa`s, commit `Release FSNotes OTA fsnotes-ota-v7.3.4`, tag it, and push `master` plus tags to `github` (grillermo/fsnotes). Mention the risks listed below (downgrade check, Home Screen bookmark).

- [ ] **Step 3 (only after approval): Deploy.** Run the command above with Bash and a 600000 ms timeout (or `run_in_background: true`). The archive takes about 3–5 minutes. Report what each step printed and the install URL.

- [ ] **Step 4 (only after a successful deploy): Turn the legacy UUID page into a redirect, once.** The user's existing Home Screen bookmark points at `e58c7006-f8fc-4111-8334-bda7fc96b41f-Install_FSNotes.html`, which `./deploy` no longer updates. Overwrite it once (atomic copy):

```bash
cd ~/c/third-parties/fsnotes && ruby -e '
require_relative "scripts/deploy/release"; require_relative "scripts/deploy/uploader"; require "tmpdir"
Release.load_dotenv(".env")
html = <<~HTML
  <!doctype html>
  <html lang="en"><head><meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta http-equiv="refresh" content="0; url=https://files.chiq.me/files/fsnotes-install.html">
  <title>Install FSNotes</title>
  <style>:root{color-scheme:dark}body{background:#111;color:#f2f2f2;font:16px/1.5 -apple-system,system-ui,sans-serif;padding:2.5rem 1.25rem;text-align:center}a{color:#0a84ff}</style>
  </head><body>
  <p>The FSNotes install page moved.</p>
  <p><a href="https://files.chiq.me/files/fsnotes-install.html">Open the new install page</a>, then add <em>that</em> page to your Home Screen. It always installs the newest release.</p>
  </body></html>
HTML
Dir.mktmpdir { |d| p = File.join(d, "legacy.html"); File.write(p, html); puts Uploader.upload(p, name: "e58c7006-f8fc-4111-8334-bda7fc96b41f-Install_FSNotes.html") }'
```

```bash
curl -s https://files.chiq.me/files/e58c7006-f8fc-4111-8334-bda7fc96b41f-Install_FSNotes.html | grep -c fsnotes-install.html; curl -sI https://files.chiq.me/files/fsnotes-install.html | head -1; curl -s https://files.chiq.me/files/fsnotes-manifest.plist | grep -o 'FSNotes-7.3.4.ipa'
```
Expected: a count ≥ 1, `HTTP/2 200`, `FSNotes-7.3.4.ipa`.

- [ ] **Step 5: ntfy** (per the Task 15 memory). On success:

```bash
sh ~/.claude/skills/ntfy/scripts/ntfy-send.sh -t "FSNotes" -T rocket -u 'itms-services://?action=download-manifest&url=https://files.chiq.me/files/fsnotes-manifest.plist' -l https://files.chiq.me/files/fsnotes-install.html -L "Install page" "FSNotes 7.3.4 (build 340) is ready. Tap to install."
```
On failure, send `-p high -T x` with the failing step instead.

- [ ] **Step 6: Update the rollout tracker.** Update the fsnotes row in the Status table of `~/c/agents-configs/docs/ios-ota-rollout/index.html`, commit it in that repo, and re-publish it to the same URL (`ios-ota-rollout.html` via file_server upload_file). This is per `~/.claude/projects/-Users-grillermo/memory/ios-ota-rollout.md`.

---

## Risks and open questions for the user

1. **Lower build number than the installed app.** The current phone build has `CFBundleVersion` `20260927.1906` (timestamp), and the first new build is `340`. Ad hoc installs over itms-services are not expected to block a lower build number, but this is unverified. If the phone refuses ("Unable to Install" while the profile check passed), delete and reinstall the app (notes in its iCloud folder survive; local settings do not), or ask the user before choosing a higher build number.
2. **Home Screen bookmark.** The old UUID install page stops being updated. Task 16 turns it into a redirect once, but the user should re-add `https://files.chiq.me/files/fsnotes-install.html` to the Home Screen.
3. **Upstream merges.** Each release commits iOS `MARKETING_VERSION`/`CURRENT_PROJECT_VERSION` changes to `project.pbxproj`. A later merge from upstream that bumps the iOS version will conflict on those lines (resolve by keeping the higher numbers). The README section, Info.plist keys, AppDelegate/SceneDelegate edits and the DevLog pbxproj lines are small, isolated hunks.
4. **DevLog port 19488** belongs to fsnotes (vvterm keeps 19480). If `FSNOTES_DEVLOG_PORT` is overridden, set it for both `./deploy --devlog` and `scripts/devlog/server.py`.
5. **Spec deviations:** no `NSAllowsLocalNetworking` (it would disable upstream's `NSAllowsArbitraryLoads`). The Swift tests run in a `swiftc` runner instead of an Xcode test target. `Config/*.xcconfig` is read by the script, not attached to the Xcode project, because REBRAND has to stay.
