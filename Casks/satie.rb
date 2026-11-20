cask "satie" do
  version "2.2.0"
  sha256 "d494c336daaaf8c076a9083fade839f19da1ddd6e2354936a0b29e3b14b82cd8"

  url "https://github.com/graemecode/satie/releases/download/v#{version}/Satie-#{version}.dmg"
  name "Satie"
  desc "Native macOS generative focus soundscape engine and 120Hz Metal audio instrument"
  homepage "https://strangechances.com/satie/"

  depends_on macos: ">= :sequoia"

  app "Satie.app"

  zap trash: [
    "~/Library/Preferences/com.strangechances.Satie.plist",
  ]
end
