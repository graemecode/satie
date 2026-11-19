cask "acoustic-circuit" do
  version "1.0.0"
  sha256 "2fa14c0d5725e5b4f42a20efef41d23f23787301685922ff5393dfa2b2feb4a2"

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
