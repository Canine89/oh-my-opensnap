cask "oh-my-opensnap" do
  version "1.0.79"
  sha256 "5c6669ad539af201a466110c6a83f2eb94dae976bc9436201a8c3e14e5c58360"

  url "https://github.com/Canine89/oh-my-opensnap/releases/download/v#{version}/oh-my-opensnap-#{version}.dmg"
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
