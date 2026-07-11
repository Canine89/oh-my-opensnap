cask "oh-my-opensnap" do
  version "1.0.64"
  sha256 "f853fab346c74133c8e148b1e3fbc63d85bf88014c21227994f1d578a6f7fa8d"

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
