cask "satie" do
  version "2.3.1"
  sha256 "a9d4df9b3d97bd2d8616124df9c28f2c9434bd02bc713884a71998edc72edbdd"

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
