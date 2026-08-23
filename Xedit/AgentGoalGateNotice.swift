//
//  AgentGoalGateNotice.swift
//  WillDeep
//
//  What a Goal-gated tool call tells the model.
//
//  The gate itself is fine: Goal mode locks write-tier tools until evidence
//  planning produces a validated plan (`goalPlanningGateBlocks`). What was
//  not fine is what the model concluded from being blocked. The old payload
//  said "finish the host-owned planning flow", and models rendered that back
//  to the user as 「等待宿主放行后立即执行」 — waiting for a host to release
//  them. There is no host to wait for and no button to press, so the user
//  reads a sentence that describes a permission dialog that does not exist,
//  and the turn burns itself on explaining why it cannot proceed.
//
//  So the payload has one job beyond stating the block: leave the model with
//  something to *do*, and forbid the one sentence that sends users hunting
//  for a nonexistent control.
//

import Foundation

nonisolated enum AgentGoalGateNotice {
    /// Shared tail: why nobody is being waited on, and what to do instead.
    private static let automaticFlowGuidance = """
    This is automatic. Goal evidence planning runs on its own in the background — no user approval, release, or authorization is involved, and asking for one does not speed it up. Keep making progress with read-only tools: inspect the repository, gather the evidence the proposal needs, and state findings concretely. Never tell the user you are waiting to be unblocked, released, approved, or authorized; it is false and it sends them looking for a control that does not exist. If a blocked tool is genuinely the only way forward, name the specific evidence you still need and why.
    """

    /// Returned to the model in place of a blocked tool result.
    static let blockedToolPayload = """
    Blocked: Goal evidence planning has not produced a validated execution plan yet, so write-tier tools are locked.

    \(automaticFlowGuidance)
    """

    /// Same block, reached through the delegated-executor path.
    static let blockedDelegationPayload = """
    Blocked: Goal evidence planning has not produced a validated execution plan yet, so delegated execution is locked.

    \(automaticFlowGuidance)
    """
}
