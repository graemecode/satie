cask "acoustic-circuit" do
  version "1.1.0"
  sha256 "cb2bc434962b3882034506850c08d10ba59258ea2d15ad88ea0774515e725f5d"

  url "https://github.com/graemecode/acoustic-circuit/releases/download/v#{version}/AcousticCircuit-#{version}.dmg"
  name "Acoustic Circuit"
  desc "Native 120Hz Metal macOS menu bar audio visualizer and harmonic instrument"
  homepage "https://graemecode.github.io/acoustic-circuit/"

  depends_on macos: ">= :sequoia"

  app "AcousticCircuit.app"

  zap trash: [
    "~/Library/Preferences/com.strangechances.AcousticCircuit.plist",
  ]
end
