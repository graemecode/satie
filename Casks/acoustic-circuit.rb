cask "acoustic-circuit" do
  version "1.0.1"
  sha256 "e4029dd4f3fc8900fa0671267c6b8508787dcd9a02eb7f7a6b81d814a933888e"

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
