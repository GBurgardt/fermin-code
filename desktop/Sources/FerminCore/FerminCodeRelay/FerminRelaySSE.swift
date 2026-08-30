import Foundation

public struct FerminRelaySSEEvent: Equatable, Sendable {
    public let id: UInt64?
    public let name: String
    public let data: Data

    public init(id: UInt64?, name: String, data: Data) {
        self.id = id
        self.name = name
        self.data = data
    }

    public var dataString: String? {
        String(data: data, encoding: .utf8)
    }
}

public enum FerminRelaySSEParserError: Error, Equatable, Sendable {
    case frameTooLarge(maximumBytes: Int)
    case invalidUTF8
    case invalidEventID(String)
    case cursorRegression(current: UInt64, candidate: UInt64)
}

public enum FerminRelaySSECursorAction: Equatable, Sendable {
    case none
    case commit(UInt64)
    case reset(UInt64?)
}

public struct FerminRelaySSECursor: Equatable, Sendable {
    public private(set) var lastEventID: UInt64?

    public init(lastEventID: UInt64? = nil) {
        self.lastEventID = lastEventID
    }

    public mutating func commit(eventID: UInt64?) throws {
        guard let eventID else { return }
        if let current = lastEventID {
            guard eventID >= current else {
                throw FerminRelaySSEParserError.cursorRegression(
                    current: current,
                    candidate: eventID
                )
            }
            guard eventID > current else { return }
        }
        lastEventID = eventID
    }

    public mutating func reset(to eventID: UInt64?) {
        lastEventID = eventID
    }

    public mutating func apply(_ action: FerminRelaySSECursorAction) throws {
        switch action {
        case .none:
            return
        case .commit(let eventID):
            try commit(eventID: eventID)
        case .reset(let eventID):
            reset(to: eventID)
        }
    }

    public func applyLastEventID(to request: inout URLRequest) {
        guard let lastEventID else {
            request.setValue(nil, forHTTPHeaderField: "Last-Event-ID")
            return
        }
        request.setValue(String(lastEventID), forHTTPHeaderField: "Last-Event-ID")
    }
}

public struct FerminRelaySSEParser: Sendable {
    public let maximumFrameBytes: Int
    private var lineBuffer = Data()
    private var frameByteCount = 0
    private var eventName = "message"
    private var eventID: UInt64?
    private var dataLines: [Data] = []
    private var lastEmittedEventID: UInt64?

    public init(
        maximumFrameBytes: Int = 5 * 1_048_576,
        replayAfterEventID: UInt64? = nil
    ) {
        self.maximumFrameBytes = max(1, maximumFrameBytes)
        self.lastEmittedEventID = replayAfterEventID
    }

    public mutating func feed(_ chunk: Data) throws -> [FerminRelaySSEEvent] {
        var events: [FerminRelaySSEEvent] = []
        events.reserveCapacity(2)
        for byte in chunk {
            frameByteCount += 1
            guard frameByteCount <= maximumFrameBytes else {
                throw FerminRelaySSEParserError.frameTooLarge(
                    maximumBytes: maximumFrameBytes
                )
            }
            if byte == 0x0A {
                var line = lineBuffer
                lineBuffer.removeAll(keepingCapacity: true)
                if line.last == 0x0D { line.removeLast() }
                if line.isEmpty {
                    if let event = try dispatch() { events.append(event) }
                    frameByteCount = 0
                } else {
                    try process(line: line)
                }
            } else {
                lineBuffer.append(byte)
            }
        }
        return events
    }

    public mutating func finish() throws -> [FerminRelaySSEEvent] {
        if !lineBuffer.isEmpty {
            var line = lineBuffer
            lineBuffer.removeAll(keepingCapacity: false)
            if line.last == 0x0D { line.removeLast() }
            if !line.isEmpty { try process(line: line) }
        }
        let event = try dispatch()
        frameByteCount = 0
        return event.map { [$0] } ?? []
    }

    private mutating func process(line: Data) throws {
        guard let text = String(data: line, encoding: .utf8) else {
            throw FerminRelaySSEParserError.invalidUTF8
        }
        guard !text.hasPrefix(":") else { return }

        let field: Substring
        var value: Substring
        if let separator = text.firstIndex(of: ":") {
            field = text[..<separator]
            value = text[text.index(after: separator)...]
            if value.first == " " { value = value.dropFirst() }
        } else {
            field = Substring(text)
            value = ""
        }

        switch field {
        case "event":
            eventName = value.isEmpty ? "message" : String(value)
        case "id":
            let rawValue = String(value)
            guard !rawValue.isEmpty,
                  rawValue.allSatisfy(\.isNumber),
                  let parsed = UInt64(rawValue) else {
                throw FerminRelaySSEParserError.invalidEventID(rawValue)
            }
            eventID = parsed
        case "data":
            dataLines.append(Data(value.utf8))
        default:
            break
        }
    }

    private mutating func dispatch() throws -> FerminRelaySSEEvent? {
        defer {
            eventName = "message"
            eventID = nil
            dataLines.removeAll(keepingCapacity: true)
        }
        guard !dataLines.isEmpty else { return nil }
        let payload = dataLines.enumerated().reduce(into: Data()) { result, item in
            if item.offset > 0 { result.append(0x0A) }
            result.append(item.element)
        }
        if eventName == "snapshot",
           let snapshotCursor = Self.snapshotCursor(from: payload),
           let lastEmittedEventID,
           snapshotCursor < lastEmittedEventID {
            self.lastEmittedEventID = snapshotCursor
        }
        if let eventID {
            if let lastEmittedEventID, eventID <= lastEmittedEventID {
                return nil
            }
            lastEmittedEventID = eventID
        }
        return FerminRelaySSEEvent(id: eventID, name: eventName, data: payload)
    }

    private static func snapshotCursor(from payload: Data) -> UInt64? {
        guard let object = try? JSONSerialization.jsonObject(with: payload) as? [String: Any],
              let value = object["cursor"] else {
            return nil
        }
        if let number = value as? NSNumber, number.int64Value >= 0 {
            return number.uint64Value
        }
        if let string = value as? String { return UInt64(string) }
        return nil
    }
}

public struct FerminRelayStreamDelivery: Equatable, Sendable {
    public let eventID: UInt64?
    public let event: FerminRelayDecodedStreamEvent
    public let rawEvent: FerminRelaySSEEvent
    public let cursorAction: FerminRelaySSECursorAction

    public init(
        eventID: UInt64?,
        event: FerminRelayDecodedStreamEvent,
        rawEvent: FerminRelaySSEEvent,
        cursorAction: FerminRelaySSECursorAction? = nil
    ) {
        self.eventID = eventID
        self.event = event
        self.rawEvent = rawEvent
        self.cursorAction = cursorAction
            ?? eventID.map(FerminRelaySSECursorAction.commit)
            ?? .none
    }
}
