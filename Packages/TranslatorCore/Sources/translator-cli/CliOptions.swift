import Darwin
import Foundation
import TranslatorCore

struct Options {
    var manifest: URL
    var baseURL = URL(string: "https://api.inworld.ai")!
    var speed = 1.0
    var loops = 1
    var only: Set<String>?
    var dropEvery: Double?
    var model: String?
    var speak = false
    var speakingRate = 1.0
    var report: URL?
    var sttPricePerHour = 0.15
    var inputPricePerMillion = 0.10
    var outputPricePerMillion = 0.40
    var ttsPricePerMillion = 15.0

    static func parse(_ arguments: [String]) -> Options {
        var manifest: URL?
        var options = Options(manifest: URL(fileURLWithPath: "/"))
        var iterator = arguments.dropFirst().makeIterator()
        func value(_ flag: String) -> String {
            guard let value = iterator.next() else { fail("\(flag) needs a value") }
            return value
        }
        func number(_ flag: String) -> Double {
            guard let number = Double(value(flag)) else { fail("\(flag) needs a number") }
            return number
        }
        while let argument = iterator.next() {
            switch argument {
            case "--base-url": options.baseURL = URL(string: value(argument)) ?? { fail("bad --base-url") }()
            case "--speed": options.speed = number(argument)
            case "--loops": options.loops = Int(number(argument))
            case "--only": options.only = Set(value(argument).split(separator: ",").map(String.init))
            case "--drop-every": options.dropEvery = number(argument)
            case "--model": options.model = value(argument)
            case "--speak": options.speak = true
            case "--speaking-rate": options.speakingRate = number(argument)
            case "--report": options.report = URL(fileURLWithPath: value(argument))
            case "--stt-price": options.sttPricePerHour = number(argument)
            case "--input-price": options.inputPricePerMillion = number(argument)
            case "--output-price": options.outputPricePerMillion = number(argument)
            case "--tts-price": options.ttsPricePerMillion = number(argument)
            case "-h", "--help":
                print("usage: translator-cli MANIFEST [--base-url URL] [--speed X] [--loops N] [--only ids] [--drop-every S] [--model ID] [--speak] [--speaking-rate X] [--report PATH]")
                exit(0)
            default:
                if argument.hasPrefix("-") { fail("unknown option \(argument)") }
                manifest = URL(fileURLWithPath: argument)
            }
        }
        guard let manifest else { fail("give the path to a samples manifest") }
        let range = InworldClient.Configuration.speakingRateRange
        guard range.contains(options.speakingRate) else {
            fail("--speaking-rate must be between \(range.lowerBound) and \(range.upperBound)")
        }
        options.manifest = manifest
        return options
    }
}

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data("error: \(message)\n".utf8))
    exit(2)
}

struct Manifest: Decodable {
    struct Sample: Decodable {
        let id: String
        let language: String
        let text: String
        let english: String
    }

    let samples: [Sample]
}
