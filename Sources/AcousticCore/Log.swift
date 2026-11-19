import Foundation
import os

public enum Log {
    public static let subsystem = "com.strangechances.AcousticCircuit"
    public static let audio = Logger(subsystem: subsystem, category: "audio")
    public static let dsp = Logger(subsystem: subsystem, category: "dsp")
    public static let renderer = Logger(subsystem: subsystem, category: "renderer")
    public static let media = Logger(subsystem: subsystem, category: "media")
    public static let app = Logger(subsystem: subsystem, category: "app")
}
