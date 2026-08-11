import Foundation

struct CodexAccount: Sendable, Equatable {
    let type: String
    let email: String?
    let plan: String?

    var label: String {
        guard type == "chatgpt" else { return type == "apiKey" ? "API key" : type }
        return plan.map { "ChatGPT \($0.capitalized)" } ?? "ChatGPT"
    }
}

struct CodexModel: Sendable, Equatable {
    let id: String
    let displayName: String
    let isDefault: Bool
    let defaultEffort: String
    let supportedEfforts: [String]

    var preferredEffort: String {
        supportedEfforts.contains("medium") ? "medium" : defaultEffort
    }

    var fastEffort: String {
        supportedEfforts.contains("low") ? "low" : defaultEffort
    }
}

struct CodexConversationContext: Sendable, Equatable {
    let title: String?
    let workingDirectory: String?
    let transcript: String

    var promptContext: String {
        var parts = ["Recent Codex conversation:"]
        if let title, !title.isEmpty { parts.append("Thread: \(title)") }
        if let workingDirectory, !workingDirectory.isEmpty {
            parts.append("Working directory: \(workingDirectory)")
        }
        parts.append(transcript)
        return parts.joined(separator: "\n")
    }
}

enum CodexClientError: LocalizedError {
    case executableNotFound
    case serverStopped(String)
    case timedOut(String)
    case invalidResponse(String)
    case rpc(String)
    case signedOut
    case noSolModel

    var errorDescription: String? {
        switch self {
        case .executableNotFound:
            "Codex is not installed. Install Codex or the ChatGPT Mac app, then reconnect."
        case .serverStopped(let details):
            details.isEmpty ? "Codex stopped unexpectedly." : "Codex stopped: \(details)"
        case .timedOut(let method):
            "Codex did not answer \(method) in time."
        case .invalidResponse(let details):
            "Codex returned an incomplete response: \(details)."
        case .rpc(let message):
            message
        case .signedOut:
            "Sign in with ChatGPT to use your Codex subscription."
        case .noSolModel:
            "GPT-5.6 Sol is not available for this Codex account."
        }
    }
}

final class CodexAppServerClient: @unchecked Sendable {
    private typealias JSON = [String: Any]
    private typealias ResponseHandler = (Result<JSON, Error>) -> Void

    private struct PendingRequest {
        let method: String
        let completion: ResponseHandler
    }

    private struct ActiveTurn {
        let continuation: AsyncThrowingStream<String, Error>.Continuation
        var turnID: String?
        var streamedText = ""
        var cancellationRequested = false
    }

    private final class StreamCancellation: @unchecked Sendable {
        private let lock = NSLock()
        private var threadID: String?
        private var task: Task<Void, Never>?

        func attach(task: Task<Void, Never>) {
            lock.lock()
            self.task = task
            lock.unlock()
        }

        func set(threadID: String) {
            lock.lock()
            self.threadID = threadID
            lock.unlock()
        }

        func cancel() -> String? {
            lock.lock()
            let value = threadID
            let task = task
            lock.unlock()
            task?.cancel()
            return value
        }
    }

    private let queue = DispatchQueue(label: "dev.suny.meant.codex-app-server")
    private var process: Process?
    private var input: FileHandle?
    private var outputBuffer = Data()
    private var errorBuffer = Data()
    private var nextRequestID = 1
    private var pending: [Int: PendingRequest] = [:]
    private var turns: [String: ActiveTurn] = [:]
    private var cachedModels: [CodexModel]?
    private var isStarting = false
    private var startWaiters: [CheckedContinuation<Result<Void, Error>, Never>] = []

    deinit {
        process?.terminationHandler = nil
        process?.terminate()
    }

    func connect() async throws {
        if queue.sync(execute: { process?.isRunning == true }) { return }

        let result: Result<Void, Error> = await withCheckedContinuation { continuation in
            queue.async {
                if self.process?.isRunning == true {
                    continuation.resume(returning: .success(()))
                    return
                }
                self.startWaiters.append(continuation)
                guard !self.isStarting else { return }
                self.isStarting = true
                self.startProcess()
            }
        }
        try result.get()
    }

    func readAccount() async throws -> CodexAccount? {
        try await connect()
        let result = try await request(method: "account/read", params: ["refreshToken": false])
        guard let account = result["account"] as? JSON else { return nil }
        guard let type = account["type"] as? String else {
            throw CodexClientError.invalidResponse("the account type is missing")
        }
        return CodexAccount(
            type: type,
            email: account["email"] as? String,
            plan: account["planType"] as? String
        )
    }

    func startChatGPTLogin() async throws -> URL {
        try await connect()
        let result = try await request(
            method: "account/login/start",
            params: [
                "type": "chatgpt",
                "useHostedLoginSuccessPage": true,
                "appBrand": "chatgpt"
            ]
        )
        guard let string = result["authUrl"] as? String, let url = URL(string: string) else {
            throw CodexClientError.invalidResponse("the sign-in URL is missing")
        }
        return url
    }

    func availableModels() async throws -> [CodexModel] {
        try await connect()
        if let models = queue.sync(execute: { cachedModels }) { return models }

        let result = try await request(
            method: "model/list",
            params: ["limit": 100, "includeHidden": false]
        )
        let models = (result["data"] as? [JSON] ?? []).compactMap { value -> CodexModel? in
            guard let id = value["id"] as? String else { return nil }
            let effortValues = (value["supportedReasoningEfforts"] as? [JSON] ?? []).compactMap {
                $0["reasoningEffort"] as? String
            }
            return CodexModel(
                id: id,
                displayName: value["displayName"] as? String ?? id,
                isDefault: value["isDefault"] as? Bool ?? false,
                defaultEffort: value["defaultReasoningEffort"] as? String ?? "low",
                supportedEfforts: effortValues
            )
        }
        queue.sync { cachedModels = models }
        return models
    }

    func solModel() async throws -> CodexModel {
        guard let model = try await availableModels().first(where: { $0.id == "gpt-5.6-sol" }) else {
            throw CodexClientError.noSolModel
        }
        return model
    }

    func transform(source: String, context: String, action: InferredAction) -> AsyncThrowingStream<String, Error> {
        let prompt = PromptEngine()
        return stream(
            instructions: prompt.transformationInstructions(for: action),
            input: prompt.transformationInput(source: source, context: context),
            model: .sol
        )
    }

    func recentConversationContext(windowTitle: String?) async throws -> CodexConversationContext? {
        try await connect()
        let result = try await request(
            method: "thread/list",
            params: [
                "limit": 12,
                "sortKey": "recency_at",
                "sortDirection": "desc",
                "archived": false
            ]
        )
        let threads = result["data"] as? [JSON] ?? []
        guard let thread = bestContextThread(from: threads, windowTitle: windowTitle),
              let threadID = thread["id"] as? String else { return nil }

        let readResult = try await request(
            method: "thread/read",
            params: ["threadId": threadID, "includeTurns": true]
        )
        guard let fullThread = readResult["thread"] as? JSON else { return nil }
        let transcript = recentTranscript(from: fullThread)
        guard !transcript.isEmpty else { return nil }
        return CodexConversationContext(
            title: fullThread["name"] as? String,
            workingDirectory: fullThread["cwd"] as? String,
            transcript: transcript
        )
    }

    private func bestContextThread(from threads: [JSON], windowTitle: String?) -> JSON? {
        let meaningfulTitle = windowTitle?.trimmingCharacters(in: .whitespacesAndNewlines)
        if let meaningfulTitle,
           !meaningfulTitle.isEmpty,
           !["Codex", "ChatGPT"].contains(meaningfulTitle),
           let match = threads.first(where: {
               guard let name = $0["name"] as? String else { return false }
               return meaningfulTitle.localizedCaseInsensitiveContains(name)
                   || name.localizedCaseInsensitiveContains(meaningfulTitle)
           }) {
            return match
        }
        return threads.first
    }

    private func recentTranscript(from thread: JSON) -> String {
        let turns = thread["turns"] as? [JSON] ?? []
        var messages: [String] = []
        for turn in turns {
            for item in turn["items"] as? [JSON] ?? [] {
                switch item["type"] as? String {
                case "userMessage":
                    let text = (item["content"] as? [JSON] ?? [])
                        .filter { $0["type"] as? String == "text" }
                        .compactMap { $0["text"] as? String }
                        .joined(separator: "\n")
                    if !text.isEmpty { messages.append("User: \(text)") }
                case "agentMessage":
                    if let text = item["text"] as? String, !text.isEmpty {
                        messages.append("Assistant: \(text)")
                    }
                default:
                    break
                }
            }
        }

        var selected: [String] = []
        var characterCount = 0
        for message in messages.reversed() {
            let remaining = 18_000 - characterCount
            guard remaining > 0 else { break }
            let value = message.count > remaining ? String(message.suffix(remaining)) : message
            selected.append(value)
            characterCount += value.count
        }
        return selected.reversed().joined(separator: "\n\n")
    }

    private enum ModelPreference {
        case sol
    }

    private func stream(
        instructions: String,
        input: String,
        model preference: ModelPreference
    ) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let cancellation = StreamCancellation()
            let setup = Task {
                do {
                    try await self.connect()
                    guard try await self.readAccount() != nil else { throw CodexClientError.signedOut }
                    let model: CodexModel
                    switch preference {
                    case .sol: model = try await self.solModel()
                    }
                    let workspace = try self.workspaceURL()
                    let reasoningEffort = model.fastEffort

                    let threadResult = try await self.request(
                        method: "thread/start",
                        params: [
                            "model": model.id,
                            "cwd": workspace.path,
                            "approvalPolicy": "never",
                            "sandbox": "read-only",
                            "ephemeral": true,
                            "serviceName": "meant_macos",
                            "baseInstructions": instructions
                        ]
                    )
                    guard let thread = threadResult["thread"] as? JSON,
                          let threadID = thread["id"] as? String else {
                        throw CodexClientError.invalidResponse("the thread ID is missing")
                    }

                    cancellation.set(threadID: threadID)
                    try Task.checkCancellation()
                    self.queue.sync {
                        self.turns[threadID] = ActiveTurn(continuation: continuation)
                    }

                    do {
                        let response = try await self.request(
                            method: "turn/start",
                            params: [
                                "threadId": threadID,
                                "input": [["type": "text", "text": input]],
                                "model": model.id,
                                "effort": reasoningEffort,
                                "summary": "none",
                                "sandboxPolicy": ["type": "readOnly", "networkAccess": false]
                            ]
                        )
                        guard let turn = response["turn"] as? JSON,
                              let turnID = turn["id"] as? String else {
                            throw CodexClientError.invalidResponse("the turn ID is missing")
                        }
                        self.queue.async {
                            guard var active = self.turns[threadID] else { return }
                            active.turnID = turnID
                            self.turns[threadID] = active
                            if active.cancellationRequested {
                                self.sendInterrupt(threadID: threadID, turnID: turnID)
                            }
                        }
                    } catch {
                        self.finishTurn(threadID: threadID, error: error)
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            cancellation.attach(task: setup)
            continuation.onTermination = { [weak self] _ in
                if let threadID = cancellation.cancel() {
                    self?.requestCancellation(threadID: threadID)
                }
            }
        }
    }

    func cancelAllTurns() {
        queue.async {
            for (threadID, var active) in self.turns {
                active.cancellationRequested = true
                self.turns[threadID] = active
                if let turnID = active.turnID {
                    self.sendInterrupt(threadID: threadID, turnID: turnID)
                }
            }
        }
    }

    private func startProcess() {
        do {
            let process = Process()
            let inputPipe = Pipe()
            let outputPipe = Pipe()
            let errorPipe = Pipe()
            process.executableURL = try codexExecutableURL()
            process.arguments = ["app-server", "--stdio"]
            process.standardInput = inputPipe
            process.standardOutput = outputPipe
            process.standardError = errorPipe

            outputPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                self?.queue.async { self?.consume(data) }
            }
            errorPipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
                let data = handle.availableData
                guard !data.isEmpty else { return }
                self?.queue.async {
                    self?.errorBuffer.append(data)
                    if let count = self?.errorBuffer.count, count > 32_768 {
                        self?.errorBuffer.removeFirst(count - 32_768)
                    }
                }
            }
            process.terminationHandler = { [weak self] _ in
                self?.queue.async { self?.handleTermination() }
            }

            try process.run()
            self.process = process
            input = inputPipe.fileHandleForWriting

            sendRequest(
                method: "initialize",
                params: [
                    "clientInfo": [
                        "name": "meant_macos",
                        "title": "Meant",
                        "version": "1.2.0"
                    ]
                ]
            ) { [weak self] result in
                guard let self else { return }
                switch result {
                case .success:
                    do {
                        try self.write(["method": "initialized", "params": [:]])
                        self.completeStart(.success(()))
                    } catch {
                        self.completeStart(.failure(error))
                    }
                case .failure(let error):
                    self.completeStart(.failure(error))
                }
            }
        } catch {
            completeStart(.failure(error))
        }
    }

    private func request(method: String, params: JSON) async throws -> JSON {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                self.sendRequest(method: method, params: params) { result in
                    continuation.resume(with: result)
                }
            }
        }
    }

    private func sendRequest(method: String, params: JSON, completion: @escaping ResponseHandler) {
        let id = nextRequestID
        nextRequestID += 1
        pending[id] = PendingRequest(method: method, completion: completion)
        do {
            try write(["method": method, "id": id, "params": params])
            queue.asyncAfter(deadline: .now() + 30) { [weak self] in
                guard let request = self?.pending.removeValue(forKey: id) else { return }
                request.completion(.failure(CodexClientError.timedOut(request.method)))
            }
        } catch {
            pending.removeValue(forKey: id)
            completion(.failure(error))
        }
    }

    private func write(_ message: JSON) throws {
        guard let input else { throw CodexClientError.serverStopped("") }
        var data = try JSONSerialization.data(withJSONObject: message)
        data.append(0x0A)
        try input.write(contentsOf: data)
    }

    private func consume(_ data: Data) {
        outputBuffer.append(data)
        while let newline = outputBuffer.firstIndex(of: 0x0A) {
            let line = Data(outputBuffer[..<newline])
            outputBuffer.removeSubrange(...newline)
            guard !line.isEmpty,
                  let value = try? JSONSerialization.jsonObject(with: line),
                  let message = value as? JSON else { continue }
            handle(message)
        }
    }

    private func handle(_ message: JSON) {
        if message["method"] != nil, message["id"] != nil {
            rejectServerRequest(message)
            return
        }

        if let id = (message["id"] as? NSNumber)?.intValue {
            guard let request = pending.removeValue(forKey: id) else { return }
            if let error = message["error"] as? JSON {
                request.completion(.failure(CodexClientError.rpc(error["message"] as? String ?? "Codex request failed.")))
            } else {
                request.completion(.success(message["result"] as? JSON ?? [:]))
            }
            return
        }

        guard let method = message["method"] as? String,
              let params = message["params"] as? JSON else { return }

        switch method {
        case "item/agentMessage/delta":
            guard let threadID = params["threadId"] as? String,
                  let delta = params["delta"] as? String,
                  var active = turns[threadID] else { return }
            active.streamedText += delta
            turns[threadID] = active
            active.continuation.yield(delta)

        case "item/completed":
            guard let threadID = params["threadId"] as? String,
                  let item = params["item"] as? JSON,
                  item["type"] as? String == "agentMessage",
                  let finalText = item["text"] as? String else { return }
            reconcileFinalText(finalText, threadID: threadID)

        case "turn/completed":
            guard let threadID = params["threadId"] as? String else { return }
            let turn = params["turn"] as? JSON
            if let items = turn?["items"] as? [JSON],
               let finalText = items.last(where: { $0["type"] as? String == "agentMessage" })?["text"] as? String {
                reconcileFinalText(finalText, threadID: threadID)
            }
            switch turn?["status"] as? String {
            case "failed":
                let error = turn?["error"] as? JSON
                finishTurn(threadID: threadID, error: CodexClientError.rpc(error?["message"] as? String ?? "Codex could not complete the prompt."))
            case "interrupted":
                finishTurn(threadID: threadID, error: CancellationError())
            default:
                finishTurn(threadID: threadID, error: nil)
            }

        default:
            break
        }
    }

    private func reconcileFinalText(_ finalText: String, threadID: String) {
        guard var active = turns[threadID] else { return }
        if finalText.hasPrefix(active.streamedText) {
            let remainder = String(finalText.dropFirst(active.streamedText.count))
            if !remainder.isEmpty {
                active.streamedText += remainder
                turns[threadID] = active
                active.continuation.yield(remainder)
            }
        } else if active.streamedText.isEmpty {
            active.streamedText = finalText
            turns[threadID] = active
            active.continuation.yield(finalText)
        }
    }

    private func requestCancellation(threadID: String) {
        queue.async {
            guard var active = self.turns[threadID] else { return }
            active.cancellationRequested = true
            self.turns[threadID] = active
            if let turnID = active.turnID {
                self.sendInterrupt(threadID: threadID, turnID: turnID)
            }
        }
    }

    private func sendInterrupt(threadID: String, turnID: String) {
        sendRequest(
            method: "turn/interrupt",
            params: ["threadId": threadID, "turnId": turnID]
        ) { _ in }
    }

    private func finishTurn(threadID: String, error: Error?) {
        queue.async {
            guard let active = self.turns.removeValue(forKey: threadID) else { return }
            if let error {
                active.continuation.finish(throwing: error)
            } else {
                active.continuation.finish()
            }
        }
    }

    private func rejectServerRequest(_ message: JSON) {
        guard let id = message["id"] else { return }
        try? write([
            "id": id,
            "error": [
                "code": -32601,
                "message": "Meant does not permit interactive tools."
            ]
        ])
    }

    private func completeStart(_ result: Result<Void, Error>) {
        isStarting = false
        let waiters = startWaiters
        startWaiters.removeAll()
        waiters.forEach { $0.resume(returning: result) }
    }

    private func handleTermination() {
        let details = String(data: errorBuffer, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let error = CodexClientError.serverStopped(details)
        process = nil
        input = nil
        cachedModels = nil
        pending.values.forEach { $0.completion(.failure(error)) }
        pending.removeAll()
        turns.values.forEach { $0.continuation.finish(throwing: error) }
        turns.removeAll()
        if isStarting { completeStart(.failure(error)) }
    }

    private func codexExecutableURL() throws -> URL {
        let home = FileManager.default.homeDirectoryForCurrentUser
        let candidates = [
            Bundle.main.url(forResource: "codex", withExtension: nil),
            home.appendingPathComponent(".local/bin/codex"),
            home.appendingPathComponent(".codex/packages/standalone/current/bin/codex"),
            URL(fileURLWithPath: "/Applications/ChatGPT.app/Contents/Resources/codex"),
            URL(fileURLWithPath: "/opt/homebrew/bin/codex"),
            URL(fileURLWithPath: "/usr/local/bin/codex")
        ].compactMap { $0 }
        guard let value = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0.path) }) else {
            throw CodexClientError.executableNotFound
        }
        return value
    }

    private func workspaceURL() throws -> URL {
        let base = try FileManager.default.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let value = base.appendingPathComponent("Meant/Session", isDirectory: true)
        try FileManager.default.createDirectory(at: value, withIntermediateDirectories: true)
        return value
    }
}
