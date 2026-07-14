class Openbox < Formula
  desc "Apple-container-backed local sandbox for agents and Swift apps"
  homepage "https://github.com/philliplakis/open-box"
  url "https://github.com/philliplakis/open-box/archive/refs/tags/v0.1.0.tar.gz"
  sha256 "REPLACE_WITH_RELEASE_SHA256"
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
