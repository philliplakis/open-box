# Homebrew Tap

OpenBox ships via a custom Homebrew tap:

```text
philliplakis/homebrew-open-box
```

## Install

One-liner:

```bash
brew install philliplakis/open-box/openbox
```

Or tap once, then use the bare formula name:

```bash
brew tap philliplakis/open-box
brew install openbox
```

A bare `brew install openbox` without tapping first only works for
`homebrew-core` formulae. OpenBox is distributed from this tap because it
targets macOS 26 / Apple Silicon and depends on Apple's `container` CLI.

## Requirements

- macOS 26+ (Tahoe)
- Apple Silicon
- Xcode / Swift toolchain (build-from-source formula)
- Apple's `container` CLI on `PATH` at runtime

## Create the Tap (one-time)

```bash
brew tap-new philliplakis/open-box
gh repo create philliplakis/homebrew-open-box \
  --public \
  --source "$(brew --repository philliplakis/open-box)" \
  --push
```

Add a repository secret on `philliplakis/open-box` named
`HOMEBREW_TAP_TOKEN`. Use a GitHub PAT with `contents:write` on
`philliplakis/homebrew-open-box`. The bump workflow uses that token to push
`Formula/openbox.rb` into the tap after each release.

## Release Flow

1. Tag a release in this repo:

```bash
git tag v0.1.0
git push origin v0.1.0
```

2. `.github/workflows/release.yml` creates the GitHub Release for the tag.
3. `.github/workflows/bump-tap.yml` downloads the source archive, computes its
   `sha256`, renders [`Formula/openbox.rb`](../Formula/openbox.rb), and pushes
   it to `philliplakis/homebrew-open-box`.

The formula in this repo is the source of truth. The tap copy is updated by CI
and should not be edited by hand unless you are recovering from a failed bump.

## Formula

Canonical formula: [`Formula/openbox.rb`](../Formula/openbox.rb)

It builds the `openbox` executable from source:

```ruby
system "swift", "build", "-c", "release", "--disable-sandbox"
bin.install ".build/release/openbox"
```

Runtime caveats remind users to install Apple's `container` CLI. The formula
test only checks `openbox --help`, so it does not require a running container
runtime during `brew test`.

## Test Locally

```bash
brew install --build-from-source philliplakis/open-box/openbox
brew test philliplakis/open-box/openbox
```

## Manual Tap Bump

If CI cannot push to the tap, run the bump workflow manually from the Actions
tab (`Bump Homebrew Tap` → `workflow_dispatch`) and pass the release tag, or
update the tap formula yourself:

```bash
curl -L https://github.com/philliplakis/open-box/archive/refs/tags/v0.1.0.tar.gz \
  | shasum -a 256
```

Then set `url` and `sha256` in the tap's `Formula/openbox.rb`.
