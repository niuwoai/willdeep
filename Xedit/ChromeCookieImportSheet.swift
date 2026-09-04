//
//  ChromeCookieImportSheet.swift
//  WillDeep
//
//  地址栏那个导入 icon 弹出的页面。刻意把「会发生什么」讲清楚再让用户点：
//  读 Chrome 的 cookie 需要过 macOS 钥匙串授权框，cookie 只进本机这个内置
//  浏览器，密码一概不碰。用户点了才动，没有任何后台自动导入。

import AppKit
import SwiftUI

struct ChromeCookieImportSheet: View {
    @ObservedObject var controller: AgentEmbeddedBrowserController
    @Environment(\.dismiss) private var dismiss

    @State private var pickedRoot: URL?
    @State private var profiles: [ChromeProfile] = []
    @State private var selectedProfileID: String?
    @State private var phase: Phase = .idle

    private enum Phase: Equatable {
        case idle
        case importing
        case done(ChromeCookieImportSummary)
        case failed(String)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            Divider()
            content
            Divider()
            footer
        }
        .padding(18)
        .frame(width: 440)
        .onDisappear { pickedRoot?.stopAccessingSecurityScopedResource() }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Image(systemName: "person.crop.circle.badge.plus")
                .font(.system(size: 22))
                .foregroundStyle(.tint)
            VStack(alignment: .leading, spacing: 2) {
                Text(L10n.ChromeImport.title)
                    .font(.system(size: 15, weight: .semibold))
                Text(L10n.ChromeImport.subtitle)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        VStack(alignment: .leading, spacing: 12) {
            consentNotice
            if pickedRoot == nil {
                // 沙箱下 App 读不到自己容器外的文件，得由用户亲自在文件框里选中
                // Chrome 数据目录，授权就在这一步给出。
                Button(action: chooseChromeFolder) {
                    Label(L10n.ChromeImport.chooseFolder, systemImage: "folder")
                }
            } else if profiles.isEmpty {
                Label(L10n.ChromeImport.notFound, systemImage: "magnifyingglass")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                if profiles.count > 1 {
                    Picker(L10n.ChromeImport.profile, selection: profileSelection) {
                        ForEach(profiles) { profile in
                            Text(profile.displayName).tag(profile.id)
                        }
                    }
                    .pickerStyle(.menu)
                }
            }
            phaseView
        }
    }

    private var consentNotice: some View {
        VStack(alignment: .leading, spacing: 6) {
            noticeRow("lock.shield", L10n.ChromeImport.noticeKeychain)
            noticeRow("desktopcomputer", L10n.ChromeImport.noticeLocal)
            noticeRow("key.slash", L10n.ChromeImport.noticeNoPasswords)
        }
        .padding(11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
    }

    private func noticeRow(_ symbol: String, _ text: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: 14)
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var phaseView: some View {
        switch phase {
        case .idle:
            EmptyView()
        case .importing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text(L10n.ChromeImport.importing).font(.system(size: 11)).foregroundStyle(.secondary)
            }
        case .done(let summary):
            Label(L10n.ChromeImport.done(summary.imported), systemImage: "checkmark.circle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.green)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 12))
                .foregroundStyle(.orange)
        }
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button(L10n.ChromeImport.close) { dismiss() }
            Button(action: runImport) {
                Text(L10n.ChromeImport.action)
            }
            .buttonStyle(.borderedProminent)
            .disabled(pickedRoot == nil || profiles.isEmpty || phase == .importing)
        }
    }

    /// 打开文件框，默认落到 Chrome 数据目录，让用户选中它。选中即授予沙箱对该
    /// 目录的读权限，随后在这个范围内枚举 profile。
    private func chooseChromeFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = L10n.ChromeImport.chooseFolder
        panel.message = L10n.ChromeImport.choosePrompt
        let defaultRoot = ChromeCookieImporter.defaultChromeRoot
        if FileManager.default.fileExists(atPath: defaultRoot.path) {
            panel.directoryURL = defaultRoot
        }
        guard panel.runModal() == .OK, let url = panel.url else { return }
        pickedRoot?.stopAccessingSecurityScopedResource()
        _ = url.startAccessingSecurityScopedResource()
        pickedRoot = url
        phase = .idle
        // 用户可能选的是 Chrome 根，也可能直接选了某个 profile 目录，两种都认。
        let found = ChromeCookieImporter.discoverProfiles(chromeRoot: url)
        profiles = found.isEmpty ? ChromeCookieImporter.discoverProfiles(chromeRoot: url.deletingLastPathComponent()) : found
        selectedProfileID = profiles.first?.id
    }

    private var profileSelection: Binding<String> {
        Binding(
            get: { selectedProfileID ?? profiles.first?.id ?? "" },
            set: { selectedProfileID = $0 }
        )
    }

    private func runImport() {
        let profileID = selectedProfileID ?? profiles.first?.id
        guard let profile = profiles.first(where: { $0.id == profileID }) else { return }
        phase = .importing
        Task {
            let result = await controller.importChromeCookies(from: profile)
            await MainActor.run {
                switch result {
                case .success(let summary): phase = .done(summary)
                case .failure(let error): phase = .failed(error.localizedDescription)
                }
            }
        }
    }
}
