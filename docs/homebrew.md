# Homebrew Tap

Use a separate tap repo:

```text
philliplakis/homebrew-open-box
```

That gives users this install command:

```bash
brew install philliplakis/open-box/openbox
```

Homebrew tap docs recommend GitHub tap repos start with `homebrew-`, and
Homebrew formulae live under `Formula/`.

## Create the Tap

```bash
brew tap-new philliplakis/open-box
gh repo create philliplakis/homebrew-open-box \
  --public \
  --source "$(brew --repository philliplakis/open-box)" \
  --push
```

## Tag an OpenBox Release

Formulae should point at a stable tagged source archive, not `main`.

```bash
git tag v0.1.0
git push origin v0.1.0
```

Get the checksum:

```bash
curl -L https://github.com/philliplakis/open-box/archive/refs/tags/v0.1.0.tar.gz \
  | shasum -a 256
```

## Formula

Create this in the tap repo:

```text
Formula/openbox.rb
```

```ruby
class Openbox < Formula
  desc "Apple-container-backed local sandbox for agents and Swift apps"
  homepage "https://github.com/philliplakis/open-box"
  url "https://github.com/philliplakis/open-box/archive/refs/tags/v0.1.0.tar.gz"
  sha256 "PASTE_SHA256_HERE"
  license "MIT"

  depends_on macos: :tahoe
  depends_on arch: :arm64
  depends_on xcode: :build

  def install
    system "swift", "build", "-c", "release", "--disable-sandbox"
    bin.install ".build/release/openbox"
  end

  def caveats
    <<~EOS
      OpenBox requires Apple's `container` CLI on PATH.

      Verify the runtime with:
        container system start
        container run --rm docker.io/library/alpine:latest echo ok
    EOS
  end

  test do
    assert_match "openbox run", shell_output("#{bin}/openbox --help")
  end
end
```

Only use `license "MIT"` after adding an MIT `LICENSE` file to the main repo.
If you choose a different license, use that SPDX identifier instead.

## Test Locally

```bash
brew install --build-from-source philliplakis/open-box/openbox
brew test philliplakis/open-box/openbox
```

## User Install

```bash
brew install philliplakis/open-box/openbox
```

Or explicitly:

```bash
brew tap philliplakis/open-box
brew install openbox
```

## Private Repo Caveat

Homebrew works best when the tap repo and source tarball are public. If
`philliplakis/open-box` is private, the formula's `url` tarball will not
download for users unless they have GitHub credentials configured for Homebrew.
For broad distribution, make the source release public or publish bottles from
the tap.
