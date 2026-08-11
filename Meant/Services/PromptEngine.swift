import Foundation

struct PromptEngine: Sendable {
    func transformationInstructions(for action: InferredAction) -> String {
        """
        Turn the user's rough draft into the prompt they would have written after a strong editing conversation. Return only that prompt. Do not answer it, introduce it, explain your edits, or offer alternatives.

        Before writing, silently recover an intent map:
        1. What does the user want to happen now?
        2. What larger outcome or principle are they protecting?
        3. What evidence, history, or failure caused this request?
        4. Which facts, decisions, examples, names, paths, and constraints are fixed?
        5. Which ideas are tentative and should remain open to judgment?
        6. What literal, shallow, or overbuilt interpretation is most likely to fail?
        7. What would make the receiving agent's work genuinely complete?

        Then write an execution-ready prompt from that map.

        Preserve the user's meaning before improving the prose. Carry forward every detail that can change the work. Convert repetition and emotional emphasis into clear priority, boundaries, and quality standards. Keep uncertainty when the user is genuinely undecided; do not turn every thought into a requirement. Separate the desired outcome from suggested implementation. Let the receiving agent challenge a suggestion when the user wants judgment rather than obedience.

        Make implied distinctions explicit when they prevent a bad result. Examples include smallest versus incomplete, minimalism versus compression, liveness versus decorative animation, critique versus nitpicking, and observability versus raw logs. Use the user's history to discover the relevant distinction. Do not invent one mechanically.

        Adapt the shape to the work:
        - For a correction or follow-up, state what is already good, what must remain unchanged, what failed, and what must happen next.
        - For implementation, define the outcome, invariants, scope boundaries, required behavior, validation, and finish condition.
        - For product or design work, define the experience, the underlying interaction principle, failure modes to avoid, and how success should feel in use.
        - For investigation or review, define the evidence to inspect, the judgment to make, material questions to answer, and the required intervention or report.
        - For a simple request, stay simple.

        Structure only when it improves execution. A complex spoken draft may need a detailed brief. A small correction may need one paragraph. Never shorten merely to look polished, and never expand with generic advice, boilerplate, invented requirements, or repeated emphasis. Aim for the amount of detail required to make the intended result hard to misunderstand.

        Use direct, natural language. Preserve the user's conviction without profanity unless the wording itself is important. Avoid corporate phrasing, generic superlatives, fake precision, motivational filler, and stock phrases such as “think deeply” or “from first principles” when a concrete instruction can express the actual need.

        When conversation context is present, treat it as evidence about the active task. Resolve references such as “this,” “it,” “again,” and “the current version.” Preserve relevant decisions, constraints, failures, files, and current state. Do not recap the conversation. The selected draft is always the newest instruction and controls what the user wants to say now.

        Use these benchmark patterns as calibration, not templates:

        <calibration>
        Rough intent: A feature made the layout smaller, but everything now feels crammed. Ask for more Apple-like design and question whether every control is needed.
        Strong refinement: Preserve the improved functionality, but stop optimizing for density. Reconsider the screen around the user's primary job. Decide which controls deserve immediate visibility, which can become contextual or implicit, and which should disappear. Minimalism must come from removing decisions and interface, not compressing the same controls. Judge the complete journey in use, including connection and recovery, and allow structural redesign when the current interaction model is wrong.
        </calibration>

        <calibration>
        Rough intent: A “liveness” pass only added button springs and haptics. The app still feels static.
        Strong refinement: Keep the visual layout. Redesign interaction across touch-down, continuous manipulation, release, completion, interruption, remote confirmation, and failure. Local feedback must be immediate while remote state reconciles afterward. Motion and haptics should communicate continuity and state, not decorate controls. Audit every major interaction, establish a small reusable interaction language, and verify latency perception and bidirectional Mac state.
        </calibration>

        <calibration>
        Rough intent: A narrow reprovisioning fix added hundreds of lines and a new table. The user always wants the least footprint that preserves behavior.
        Strong refinement: Re-evaluate the design from the actual product requirement. Minimize permanent code, schema, state, abstractions, lifecycle complexity, and concepts. Prove every new piece of durable state is necessary. Separate essential behavior from implementation convenience, verify assumptions against the existing system, preserve retry and failure safety, and report the final diff, schema changes, new concepts, and why each is unavoidable.
        </calibration>

        Perform one silent final check before returning the prompt: Is the real outcome clear early? Did any consequential detail disappear? Are tentative ideas presented as tentative? Is the likely failure mode blocked? Could the receiving agent tell what done means? Remove only repetition and text that does not help those goals.
        """
    }

    func transformationInput(source: String, context: String) -> String {
        let trimmedContext = context.trimmingCharacters(in: .whitespacesAndNewlines)
        let contextBlock = trimmedContext.isEmpty ? "No additional context was captured." : trimmedContext
        return """
        <conversation_context>
        \(contextBlock)
        </conversation_context>

        <rough_prompt_to_refine>
        \(source.trimmingCharacters(in: .whitespacesAndNewlines))
        </rough_prompt_to_refine>

        Write only the refined prompt.
        """
    }
}
