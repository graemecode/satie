cask "acoustic-circuit" do
  version "2.0.0"
  sha256 "2210a5540147ad12e181f361f0cff0500a3527ce6ba58950b57d31c645b6a7c8"

  url "https://github.com/graemecode/acoustic-circuit/releases/download/v#{version}/AcousticCircuit-#{version}.dmg"
  name "Acoustic Circuit"
  desc "Native macOS focus soundscape engine and 120Hz Metal audio visualizer"
  homepage "https://strangechances.com/acoustic-circuit/"

  depends_on macos: ">= :sequoia"

  app "AcousticCircuit.app"

  zap trash: [
    "~/Library/Preferences/com.strangechances.AcousticCircuit.plist",
  ]
end
