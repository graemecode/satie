cask "satie" do
  version "2.3.0"
  sha256 "6bca15c8c2b3423dddfabd6e8f9eb62a9893ae7f62bc7eb67f26642d4e891bb0"

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
