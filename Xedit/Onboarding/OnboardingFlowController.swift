//
//  OnboardingFlowController.swift
//  WillDeep
//
//  1.88.0 起。首次启动 onboarding sheet 的总控开关。
//  - hasCompleted 持久化到 UserDefaults。
//  - isPresented 是 SwiftUI sheet 的 binding 目标。
//  - WindowRootView .onAppear 调 presentIfNeeded():第一窗口会把
//    isPresented 翻成 true,后续窗口因为 hasShownThisSession 标志而 noop。
//

import Foundation
import Combine

@MainActor
final class OnboardingFlowController: ObservableObject {
    static let shared = OnboardingFlowController()

    private static let hasCompletedKey = "willdeep.onboarding.hasCompleted.v1"

    @Published var isPresented: Bool = false
    private var hasShownThisSession = false

    private init() {}

    var hasCompleted: Bool {
        get { UserDefaults.standard.bool(forKey: Self.hasCompletedKey) }
        set { UserDefaults.standard.set(newValue, forKey: Self.hasCompletedKey) }
    }

    /// 第一窗口出现时调。已完成或本会话已经弹过都直接 noop。
    func presentIfNeeded() {
        guard !hasShownThisSession else { return }
        guard !hasCompleted else { return }
        hasShownThisSession = true
        isPresented = true
    }

    func markCompleted() {
        hasCompleted = true
        isPresented = false
    }

    /// Help 菜单或调试用:强制重弹。
    func presentNow() {
        hasShownThisSession = true
        isPresented = true
    }
}
