//
//  WorkflowState.swift
//  WillDeep
//
//  1.85.0-rc19:Workflow agent 跨调用共享 mutable state 的标准容器。
//
//  动机:deep-research 这种管线里,N 个 search agent 并发跑、每个 agent
//  完成后立刻把它发现的 URL 塞进一个共享 dedup map,后续 fetch agent
//  从这个 map 里挑没见过的;同时 fetch 总数有预算上限,需要一个全局
//  counter 计数。Claude Code workflow runtime 用 JS 闭包持有 `Map`/`Set`
//  + 计数器自然解决;Swift 这边 actor 是天然答案,但每个 workflow 都
//  写一遍 actor 样板太啰嗦,统一抽到这里。
//
//  用法:
//
//      let seen = WorkflowState(Set<String>())
//      ...
//      let isNovel = await seen.update { set -> Bool in
//          set.insert(url).inserted
//      }
//      if isNovel { ... }
//
//  或者读快照:
//      let snapshot = await seen.snapshot()
//
//  设计选择:value 必须 Sendable;`update` 闭包是 sync 不是 async,
//  避免在 actor 里嵌 await 引起优先级反转。返回任意 R 让 caller 既能
//  纯 mutation 也能从 mutation 里顺手提取结果(典型如 `inserted` 标
//  志)。
//

import Foundation

actor WorkflowState<Value: Sendable> {
    private var value: Value

    init(_ initial: Value) {
        self.value = initial
    }

    /// 拿当前值的快照(value 必须可值复制,actor 隔离保证读到一致状态)。
    func snapshot() -> Value {
        value
    }

    /// 在 actor 隔离里跑 mutation,顺手返回任意 R。典型:
    ///   `let inserted = await state.update { $0.insert(url).inserted }`
    @discardableResult
    func update<R: Sendable>(_ mutation: (inout Value) -> R) -> R {
        mutation(&value)
    }

    /// 重新设整个 value。少见 —— 多数场景 `update` 就够了。
    func replace(with newValue: Value) {
        value = newValue
    }
}
