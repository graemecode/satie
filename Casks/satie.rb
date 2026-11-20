cask "satie" do
  version "2.1.1"
  sha256 "0fb7b887e78169dae9b8f583ba2bb5fe92a162b1f3a7c54878cd5b358d51f9d5"

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
