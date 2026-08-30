//
//  CodexRateLimitProbe.swift
//  BoringNotchXPCHelper
//
//  Uses the local Codex app-server's read-only account/rateLimits/read method.
//  The handshake and executable discovery are adapted from Codex Usage Bar
//  (MIT, Copyright (c) 2026 CMMUU).
//

import Darwin
import Foundation

extension BoringNotchXPCHelper {
    @objc func readCodexRateLimits(with reply: @escaping (String?, String?) -> Void) {
        DispatchQueue.global(qos: .utility).async {
            do {
                reply(try CodexRateLimitProbe().fetch(), nil)
            } catch {
                reply(nil, error.localizedDescription)
            }
        }
    }
}

private struct CodexRateLimitProbe {
    private let timeout: TimeInterval = 8

    func fetch() throws -> String {
        let executableURL = try locateExecutable()
        let argumentVariants = [
            ["app-server", "--stdio"],
            ["app-server", "--listen", "stdio://"],
        ]
        var lastError: Error?

        for arguments in argumentVariants {
            do {
                let responses = try run(
                    executableURL: executableURL,
                    arguments: arguments,
                    timeout: timeout
                )
                return try makePayload(from: responses)
            } catch {
                lastError = error
            }
        }

        throw lastError ?? ProbeError.timedOut
    }

    private func makePayload(from responses: [Int: Data]) throws -> String {
        guard let accountData = responses[1] else {
            throw ProbeError.missingAccount
        }
        guard let rateLimitsData = responses[2] else {
            throw ProbeError.missingRateLimits
        }

        let account = try JSONSerialization.jsonObject(with: accountData)
        let rateLimits = try JSONSerialization.jsonObject(with: rateLimitsData)
        let data = try JSONSerialization.data(withJSONObject: [
            "account": account,
            "rateLimits": rateLimits,
        ])
        guard let payload = String(data: data, encoding: .utf8) else {
            throw ProbeError.invalidProtocol
        }
        return payload
    }

    private func locateExecutable() throws -> URL {
        let environment = ProcessInfo.processInfo.environment
        let home = NSHomeDirectory()
        var candidates: [String] = []

        if let override = environment["CODEX_BINARY_PATH"], !override.isEmpty {
            candidates.append(override)
        }

        for bundleRoot in [
            "/Applications/ChatGPT.app",
            "/System/Applications/ChatGPT.app",
            "\(home)/Applications/ChatGPT.app",
        ] {
            candidates.append("\(bundleRoot)/Contents/Resources/codex")
            candidates.append("\(bundleRoot)/Contents/SharedSupport/codex")
        }

        candidates.append(contentsOf: [
            "/opt/homebrew/bin/codex",
            "/usr/local/bin/codex",
            "\(home)/.local/bin/codex",
            "\(home)/.npm-global/bin/codex",
            "\(home)/.npm/bin/codex",
            "\(home)/bin/codex",
        ])

        if let path = environment["PATH"] {
            candidates.append(contentsOf: path.split(separator: ":").map { "\($0)/codex" })
        }

        var visited = Set<String>()
        for candidate in candidates where visited.insert(candidate).inserted {
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return URL(fileURLWithPath: candidate)
            }
        }

        throw ProbeError.executableNotFound
    }

    private func run(
        executableURL: URL,
        arguments: [String],
        timeout: TimeInterval
    ) throws -> [Int: Data] {
        let process = Process()
        let standardInput = Pipe()
        let standardOutput = Pipe()

        process.executableURL = executableURL
        process.arguments = arguments
        process.environment = ProcessInfo.processInfo.environment
        process.standardInput = standardInput
        process.standardOutput = standardOutput
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            throw ProbeError.launchFailed(error.localizedDescription)
        }

        let inputHandle = standardInput.fileHandleForWriting
        let outputHandle = standardOutput.fileHandleForReading
        defer {
            try? inputHandle.close()
            try? outputHandle.close()
            stop(process)
        }

        write(
            "{\"method\":\"initialize\",\"id\":0,\"params\":{\"clientInfo\":{\"name\":\"boring-notch\",\"title\":\"Boring Notch\",\"version\":\"1.0\"}}}\n",
            to: inputHandle
        )

        let outputDescriptor = outputHandle.fileDescriptor
        let currentFlags = fcntl(outputDescriptor, F_GETFL)
        guard currentFlags >= 0,
              fcntl(outputDescriptor, F_SETFL, currentFlags | O_NONBLOCK) >= 0
        else {
            throw ProbeError.invalidProtocol
        }

        var descriptor = pollfd(
            fd: outputDescriptor,
            events: Int16(POLLIN | POLLHUP | POLLERR),
            revents: 0
        )
        var buffer = Data()
        var responses: [Int: Data] = [:]
        var sentInitialized = false
        var sentRateLimitsRequest = false
        let deadline = Date().addingTimeInterval(timeout)

        while Date() < deadline {
            descriptor.revents = 0
            let remainingMilliseconds = max(
                1,
                min(250, Int(deadline.timeIntervalSinceNow * 1_000))
            )
            let pollResult = Darwin.poll(&descriptor, 1, Int32(remainingMilliseconds))
            if pollResult < 0 {
                if errno == EINTR { continue }
                throw ProbeError.invalidProtocol
            }

            if pollResult > 0,
               descriptor.revents & Int16(POLLIN | POLLHUP) != 0
            {
                var bytes = [UInt8](repeating: 0, count: 16_384)
                let byteCount = bytes.withUnsafeMutableBytes {
                    Darwin.read(outputDescriptor, $0.baseAddress, $0.count)
                }
                if byteCount > 0 {
                    buffer.append(contentsOf: bytes.prefix(byteCount))
                    consumeLines(from: &buffer, into: &responses)
                } else if byteCount < 0,
                          errno != EAGAIN,
                          errno != EWOULDBLOCK,
                          errno != EINTR
                {
                    throw ProbeError.invalidProtocol
                }
            }

            if responses[0] != nil, !sentInitialized {
                write(
                    "{\"method\":\"initialized\",\"params\":{}}\n"
                        + "{\"method\":\"account/read\",\"id\":1,\"params\":{\"refreshToken\":false}}\n",
                    to: inputHandle
                )
                sentInitialized = true
            }

            if responses[1] != nil, !sentRateLimitsRequest {
                write(
                    "{\"method\":\"account/rateLimits/read\",\"id\":2}\n",
                    to: inputHandle
                )
                sentRateLimitsRequest = true
            }

            if responses[2] != nil {
                return responses
            }

            if !process.isRunning {
                throw ProbeError.terminated(process.terminationStatus)
            }
        }

        throw ProbeError.timedOut
    }

    private func write(_ payload: String, to handle: FileHandle) {
        try? handle.write(contentsOf: Data(payload.utf8))
    }

    private func consumeLines(from buffer: inout Data, into responses: inout [Int: Data]) {
        while let newlineIndex = buffer.firstIndex(of: 0x0A) {
            let line = Data(buffer[..<newlineIndex])
            buffer.removeSubrange(...newlineIndex)
            guard !line.isEmpty,
                  let object = try? JSONSerialization.jsonObject(with: line) as? [String: Any],
                  let id = object["id"] as? Int,
                  (0...2).contains(id)
            else {
                continue
            }
            responses[id] = line
        }
    }

    private func stop(_ process: Process) {
        guard process.isRunning else { return }
        process.terminate()
        let deadline = Date().addingTimeInterval(1)
        while process.isRunning, Date() < deadline {
            usleep(10_000)
        }
        if process.isRunning {
            kill(process.processIdentifier, SIGKILL)
        }
        process.waitUntilExit()
    }
}

private enum ProbeError: LocalizedError {
    case executableNotFound
    case launchFailed(String)
    case terminated(Int32)
    case missingAccount
    case missingRateLimits
    case timedOut
    case invalidProtocol

    var errorDescription: String? {
        switch self {
        case .executableNotFound:
            return "未找到 Codex 可执行文件"
        case .launchFailed(let message):
            return "Codex 服务启动失败：\(message)"
        case .terminated(let status):
            return "Codex 服务已退出，状态码：\(status)"
        case .missingAccount:
            return "Codex 未返回账户信息"
        case .missingRateLimits:
            return "Codex 未返回额度信息"
        case .timedOut:
            return "读取 Codex 额度超时"
        case .invalidProtocol:
            return "Codex 返回的数据格式无效"
        }
    }
}
