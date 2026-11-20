cask "acoustic-circuit" do
  version "1.0.2"
  sha256 "b5fe311af01ab2a83a71d7bb87d3745d8b56f57212581bc6d6421f5563165185"

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
