cask "oh-my-opensnap" do
  version "1.0.81"
  sha256 "6c8e0f60f1a3c2c8706d7d678e38e7c1608d6a46420706ccc4a49c6394775c6a"

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
