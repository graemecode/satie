cask "satie" do
  version "3.0.0"
  sha256 "acea09a13a14d76924d1b0e6c439cdb3d3a84330df79d7a09af6712380510ab7"

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
