class Openbox < Formula
  desc "Apple-container-backed local sandbox for agents and Swift apps"
  homepage "https://github.com/philliplakis/open-box"
  url "https://github.com/philliplakis/open-box/archive/refs/tags/v0.1.0.tar.gz"
  sha256 "60fd897fc5e885d8e376fe3d8d74f81a2a3b70fb5ebfca3f33a0d5ebf350a4b6"
  license "MIT"

  depends_on xcode: :build
  depends_on arch: :arm64
  depends_on macos: :tahoe

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
