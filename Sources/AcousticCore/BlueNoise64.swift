import Foundation

/// Genuine 64x64 isotropic toroidal Blue Noise rank tile generated via
/// Ulichney's (1993) Void-and-Cluster algorithm (sigma = 1.9).
/// Exact uniform histogram (16 texels per 8-bit level) with +37.87 dB high-pass
/// 2D FFT spectral suppression for zero-banding OLED / Apple EDR dithering.
public enum BlueNoise64 {
    public static let dimension: Int = 64

    private static let encodedTile: String = """
        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
        """

    public static let bytes: [UInt8] = Array(Data(base64Encoded: encodedTile, options: .ignoreUnknownCharacters)!)
}
