cask "oh-my-opensnap" do
  version "1.0.60"
  sha256 "2d623f6f55d6de2675a13df91cce29a37059f6d03c4d569cacd6467916e9ee65"

  url "https://github.com/Canine89/oh-my-opensnap/releases/download/v#{version}/oh-my-opensnap-#{version}-notarized.dmg"
  name "oh-my-opensnap"
  desc "Fast, precise screen capture tool"
  homepage "https://github.com/Canine89/oh-my-opensnap"

  livecheck do
    url :url
    strategy :github_latest
  end

  depends_on macos: :tahoe

  app "oh-my-opensnap.app"

  zap trash: "~/Library/Preferences/com.goldenrabbit.ohmyopensnap.plist"

  caveats <<~EOS
    oh-my-opensnap needs Screen Recording permission to capture the screen.

    Open System Settings > Privacy & Security > Screen & System Audio Recording,
    then enable oh-my-opensnap.
  EOS
end
