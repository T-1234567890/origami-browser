import Foundation

enum AnswerBlockV1: Codable, Equatable {
    case heading(AnswerHeading)
    case paragraph(AnswerText)
    case bullets(AnswerList)
    case numbered_list(AnswerList)
    case steps(AnswerList)
    case comparison(AnswerComparison)
    case table(AnswerTable)
    case timeline(AnswerTimeline)
    case code(AnswerCode)
    case quote(AnswerQuote)
    case callout(AnswerText)
    case generated_visual(AnswerVisual)
    private enum Key: String, CodingKey { case type }
    init(from decoder: Decoder) throws {
        let key = try decoder.container(keyedBy: Key.self).decode(String.self, forKey: .type)
        switch key {
        case "heading": self = .heading(try AnswerHeading(from: decoder))
        case "paragraph": self = .paragraph(try AnswerText(from: decoder))
        case "bullets": self = .bullets(try AnswerList(from: decoder))
        case "numbered_list": self = .numbered_list(try AnswerList(from: decoder))
        case "steps": self = .steps(try AnswerList(from: decoder))
        case "comparison": self = .comparison(try AnswerComparison(from: decoder))
        case "table": self = .table(try AnswerTable(from: decoder))
        case "timeline": self = .timeline(try AnswerTimeline(from: decoder))
        case "code": self = .code(try AnswerCode(from: decoder))
        case "quote": self = .quote(try AnswerQuote(from: decoder))
        case "callout": self = .callout(try AnswerText(from: decoder))
        case "generated_visual": self = .generated_visual(try AnswerVisual(from: decoder))
        default: throw AIError.response
        }
    }
    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: Key.self)
        switch self {
        case .heading(let value): try container.encode("heading", forKey: .type); try value.encode(to: encoder)
        case .paragraph(let value): try container.encode("paragraph", forKey: .type); try value.encode(to: encoder)
        case .bullets(let value): try container.encode("bullets", forKey: .type); try value.encode(to: encoder)
        case .numbered_list(let value): try container.encode("numbered_list", forKey: .type); try value.encode(to: encoder)
        case .steps(let value): try container.encode("steps", forKey: .type); try value.encode(to: encoder)
        case .comparison(let value): try container.encode("comparison", forKey: .type); try value.encode(to: encoder)
        case .table(let value): try container.encode("table", forKey: .type); try value.encode(to: encoder)
        case .timeline(let value): try container.encode("timeline", forKey: .type); try value.encode(to: encoder)
        case .code(let value): try container.encode("code", forKey: .type); try value.encode(to: encoder)
        case .quote(let value): try container.encode("quote", forKey: .type); try value.encode(to: encoder)
        case .callout(let value): try container.encode("callout", forKey: .type); try value.encode(to: encoder)
        case .generated_visual(let value): try container.encode("generated_visual", forKey: .type); try value.encode(to: encoder)
        }
    }
}
