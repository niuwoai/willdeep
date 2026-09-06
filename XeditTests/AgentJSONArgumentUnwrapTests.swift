import Foundation
import Testing
@testable import WillDeep

/// Regression cover for the crash in 1.301.0-rc4 (build 542, x86_64):
/// `EXC_BAD_ACCESS` writing into thread 0's stack guard page, with ~500
/// identical `AgentSubagentTaskPacket.parse(_:)` frames on the main thread —
/// an unbounded self-recursion that ate the 8 MB stack.
///
/// The loop: `parse` re-entered itself with `AgentJSONValue.decode(from:)`
/// applied to the string, and `decode(from:)` hands text straight back as
/// `.string` when it is not JSON. So a `spawn_agent` whose `task` was a plain
/// sentence — the most natural thing for a model to write — decoded to the
/// same `.string` forever.
///
/// Every case here would have hung then crashed the test process before the
/// fix; that is exactly why they are worth having.
@Suite
struct AgentJSONArgumentUnwrapTests {

    // MARK: The unwrap primitive

    @Test("JSON zero and one remain numbers, distinct from booleans")
    func numericBoundaryValuesPreserveType() throws {
        let decoded = try AgentJSONValue.decode(from: Data("[0,1,1.0,-1,2,true,false,null]".utf8))
        #expect(decoded == .array([.number(0), .number(1), .number(1), .number(-1),
                                  .number(2), .bool(true), .bool(false), .null]))
        let roundTrip = try JSONSerialization.data(withJSONObject: decoded.rawAny)
        #expect(try AgentJSONValue.decode(from: roundTrip) == decoded)
    }

    @Test("native and boxed numeric arguments do not become booleans")
    func boxedValuesPreserveType() {
        #expect(AgentJSONValue.wrap(0) == .number(0))
        #expect(AgentJSONValue.wrap(1) == .number(1))
        #expect(AgentJSONValue.wrap(NSNumber(value: Int8(1))) == .number(1))
        #expect(AgentJSONValue.wrap(NSNumber(value: 0.0)) == .number(0))
        #expect(AgentJSONValue.wrap(true) == .bool(true))
        #expect(AgentJSONValue.wrap(NSNumber(value: false)) == .bool(false))
    }

    @Test("integer arguments reject overflow, nonfinite values and fractions without trapping")
    func integerConversionIsBounded() {
        for number in [Double.infinity, -Double.infinity, Double.nan, Double.greatestFiniteMagnitude, 1.5] {
            #expect(AgentJSONValue.number(number).intValue() == nil)
        }
        #expect(AgentJSONValue.number(0).intValue() == 0)
        #expect(AgentJSONValue.number(1).intValue() == 1)
        #expect(AgentJSONValue.number(-1).intValue() == -1)
    }

    @Test("nested tool pagination and attempt limits retain exact integer values")
    func paginationAndAttemptLimitsPreserveOne() throws {
        let fields = try #require(AgentJSONValue.objectFields(unwrapping:
            AgentJSONValue.decode(from: #"{"offset":1,"limit":1,"options":{"retries":0,"enabled":true}}"#)))
        #expect(fields["offset"]?.intValue() == 1)
        #expect(fields["limit"]?.intValue() == 1)
        #expect(fields["options"] == .object(["retries": .number(0), "enabled": .bool(true)]))
        let task = try #require(AgentSubagentTaskPacket.parse(.string(#"{"goal":"Inspect records","max_attempts":1}"#)))
        #expect(task.maxAttempts == 1)
    }

    @Test("plain prose is not an object, and does not loop")
    func plainProseTerminates() {
        #expect(AgentJSONValue.objectFields(unwrapping: .string("修复登录 bug")) == nil)
        #expect(AgentJSONValue.objectFields(unwrapping: .string("fix the login bug")) == nil)
    }

    /// `.fragmentsAllowed` means a quoted string is *valid* JSON that decodes
    /// to a string — the second way into the same loop.
    @Test("a JSON string fragment decodes to itself and stops")
    func stringFragmentTerminates() {
        #expect(AgentJSONValue.objectFields(unwrapping: .string("\"hello\"")) == nil)
    }

    @Test("a real object passes straight through")
    func objectPassesThrough() throws {
        let fields = try #require(
            AgentJSONValue.objectFields(unwrapping: .object(["goal": .string("修表格")]))
        )

        #expect(fields["goal"]?.stringValue() == "修表格")
    }

    @Test("a string holding an object is unwrapped once")
    func stringHoldingObjectIsUnwrapped() throws {
        let fields = try #require(
            AgentJSONValue.objectFields(unwrapping: .string(#"{"goal":"修表格"}"#))
        )

        #expect(fields["goal"]?.stringValue() == "修表格")
    }

    /// Double-encoding happens when a model JSON-encodes an argument that the
    /// transport then encodes again. Bounded unwrapping still gets there.
    @Test("a doubly encoded object is still reached")
    func doubleEncodedObjectIsUnwrapped() throws {
        let inner = #"{"goal":"修表格"}"#
        let encoded = try JSONSerialization.data(
            withJSONObject: inner,
            options: [.fragmentsAllowed]
        )
        let outer = try #require(String(data: encoded, encoding: .utf8))
        let fields = try #require(AgentJSONValue.objectFields(unwrapping: .string(outer)))

        #expect(fields["goal"]?.stringValue() == "修表格")
    }

    @Test("non-object JSON is refused rather than half-read")
    func nonObjectJSONIsRefused() {
        #expect(AgentJSONValue.objectFields(unwrapping: .string("[1,2,3]")) == nil)
        #expect(AgentJSONValue.objectFields(unwrapping: .string("42")) == nil)
        #expect(AgentJSONValue.objectFields(unwrapping: .string("   ")) == nil)
        #expect(AgentJSONValue.objectFields(unwrapping: nil) == nil)
        #expect(AgentJSONValue.objectFields(unwrapping: .number(7)) == nil)
    }

    // MARK: The two call sites that shipped the loop

    @Test("a plain-text task argument returns nil instead of crashing")
    func plainTextTaskDoesNotCrash() {
        #expect(AgentSubagentTaskPacket.parse(.string("修复登录 bug")) == nil)
        #expect(AgentSubagentTaskPacket.parse(.string("\"just a quoted sentence\"")) == nil)
    }

    @Test("a plain-text escalation argument returns nil instead of crashing")
    func plainTextEscalationDoesNotCrash() {
        #expect(AgentDeepAdmissionTicket.parse(.string("这个任务很复杂")) == nil)
        #expect(AgentDeepAdmissionTicket.parse(.string("\"too hard\"")) == nil)
    }

    /// The formats that were always meant to work still do — the fix removed
    /// a loop, not the tolerance the loop was written for.
    @Test("both call sites still accept an object and a string holding one")
    func supportedShapesStillParse() throws {
        let fromObject = try #require(
            AgentSubagentTaskPacket.parse(.object(["goal": .string("修表格")]))
        )
        let fromString = try #require(
            AgentSubagentTaskPacket.parse(.string(#"{"goal":"修表格","max_attempts":2}"#))
        )

        #expect(fromObject.goal == "修表格")
        #expect(fromString.goal == "修表格")
        #expect(fromString.maxAttempts == 2)

        let ticket = try #require(
            AgentDeepAdmissionTicket.parse(.string(#"{"reason":"跨模块重构"}"#))
        )
        #expect(ticket.reason == "跨模块重构")
    }
}
