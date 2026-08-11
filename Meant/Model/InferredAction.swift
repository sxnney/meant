import Foundation

enum ActionPresentation: String, Codable, Sendable {
    case replace
    case preview
}

struct InferredAction: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    let title: String
    let instruction: String
    let presentation: ActionPresentation

    init(
        id: UUID = UUID(),
        title: String,
        instruction: String,
        presentation: ActionPresentation
    ) {
        self.id = id
        self.title = title
        self.instruction = instruction
        self.presentation = presentation
    }

    private enum CodingKeys: String, CodingKey {
        case title
        case instruction
        case presentation
    }

    init(from decoder: Decoder) throws {
        let values = try decoder.container(keyedBy: CodingKeys.self)
        id = UUID()
        title = try values.decode(String.self, forKey: .title)
        instruction = try values.decode(String.self, forKey: .instruction)
        presentation = try values.decode(ActionPresentation.self, forKey: .presentation)
    }

    func encode(to encoder: Encoder) throws {
        var values = encoder.container(keyedBy: CodingKeys.self)
        try values.encode(title, forKey: .title)
        try values.encode(instruction, forKey: .instruction)
        try values.encode(presentation, forKey: .presentation)
    }
}
