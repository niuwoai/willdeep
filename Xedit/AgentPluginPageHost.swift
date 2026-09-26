//
//  AgentPluginPageHost.swift
//  WillDeep
//
//  Full-center plugin destination host. Rich pages run in an isolated,
//  non-persistent WKWebView; simple declarative pages remain native SwiftUI.
//

import AppKit
import Combine
import os
import SwiftUI
import UniformTypeIdentifiers
import WebKit

private let pluginPageLog = Logger(subsystem: "com.willdeep.agent", category: "plugin-page")

struct AgentPluginPageHost: View {
    @EnvironmentObject private var appState: AppState
    @ObservedObject private var registry = AgentPluginRegistry.shared
    @ObservedObject private var sessionState = AgentPluginDestinationSessionState.shared
    let destinationID: AgentPluginDestinationID

    var body: some View {
        Group {
            if let destination = registry.destination(id: destinationID) {
                VStack(spacing: 0) {
                    toolbar(destination)
                    Divider().opacity(0.5)
                    page(destination)
                }
            } else {
                AgentPluginUnavailableView(
                    title: L10n.Plugins.pageUnavailable,
                    detail: L10n.Plugins.noPluginsDetail,
                    systemImage: "puzzlepiece.extension"
                ) {
                    Button(L10n.Plugins.morePlugins) {
                        appState.agentPrimaryDestination = .pluginCenter
                    }
                }
                .task(id: destinationID) {
                    await registry.refresh()
                    if registry.destination(id: destinationID) == nil {
                        appState.agentPrimaryDestination = .pluginCenter
                    }
                }
            }
        }
        .tint(.primary)
    }

    private func toolbar(_ destination: AgentPluginDestinationDescriptor) -> some View {
        HStack(spacing: 10) {
            AgentPluginIcon(icon: destination.navigation.icon, packageURL: destination.packageURL)
                .frame(width: 16, height: 16)
                .foregroundStyle(.primary)
            Text(registry.localizedTitle(for: destination))
                .font(.system(size: 14, weight: .semibold))
                .lineLimit(1)
            Spacer(minLength: 8)
            ForEach(registry.pageToolbarCommands(for: destination)) { command in
                Button {
                    run(command.id, destination: destination)
                } label: {
                    Label(
                        registry.localizedString(command.titleKey, pluginID: destination.pluginID),
                        systemImage: command.icon?.replacingOccurrences(of: "sf:", with: "") ?? "bolt"
                    )
                }
                .buttonStyle(.borderless)
            }
            Button {
                sessionState.requestRefresh(destinationID: destination.qualifiedID)
            } label: {
                Image(systemName: "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help(L10n.Plugins.refresh)
            Menu {
                Button(L10n.Plugins.settings) {
                    appState.agentPrimaryDestination = .pluginCenter
                }
                Button(L10n.Plugins.openInFinder) {
                    NSWorkspace.shared.activateFileViewerSelecting([destination.packageURL])
                }
            } label: {
                Image(systemName: "ellipsis")
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(.horizontal, 16)
        .frame(height: AgentDesign.headerHeight)
    }

    @ViewBuilder
    private func page(_ destination: AgentPluginDestinationDescriptor) -> some View {
        switch destination.mainPage.runtime {
        case .localWeb, .mcpApp:
            AgentPluginWebPage(destination: destination)
        case .declarative:
            AgentPluginDeclarativePage(destination: destination)
        }
    }

    private func run(_ commandID: String, destination: AgentPluginDestinationDescriptor) {
        Task {
            _ = try? await AgentPluginCommandExecutor.execute(
                pluginID: destination.pluginID,
                commandID: commandID,
                arguments: [:],
                destinationID: destination.qualifiedID,
                appState: appState
            )
        }
    }
}

private struct AgentPluginWebPage: View {
    @EnvironmentObject private var appState: AppState
    @Environment(\.colorScheme) private var colorScheme
    @ObservedObject private var sessionState = AgentPluginDestinationSessionState.shared
    let destination: AgentPluginDestinationDescriptor

    @State private var html: String?
    @State private var baseURL: URL?
    @State private var errorMessage: String?
    @State private var isLoading = false
    /// 手动重新载入的可见反馈。和 isLoading 分开：isLoading 只在首次没有
    /// html 时用来占位，重载时 html 一直在，那条路走不到。
    @State private var isReloading = false

    var body: some View {
        Group {
            if let html {
                AgentPluginWebView(
                    html: composedHTML(html),
                    baseURL: baseURL,
                    destination: destination,
                    context: destinationContext,
                    appState: appState
                )
                // 视图身份必须跟着目标走。所有插件页共用 AgentModeView 里
                // 同一个结构槽位，没有 .id 的话换插件只会走 updateNSView：
                // makeNSView 不再执行，于是上一个插件的 WKWebView 被原地复用
                // ——它的 websiteDataStore 和 scheme handler 的 pluginID 都是
                // 创建时钉死的，`/__media__/` 会去上一个插件的 plugin-data 下
                // 找图，整页图片 404（短剧工坊反复出现的"图不显示"）。带上
                // .id 才会重新走 makeNSView，保活缓存也才按目标各自命中。
                // 只钉 qualifiedID：激活包切换仍由 updateNSView 回写
                // packageURL 处理，不必为此另起一张页面。
                .id(destination.qualifiedID)
                // 重新载入时旧页面还挂着，下面那个 isLoading 分支根本走不到，
                // 用户点完「重新载入」屏幕纹丝不动，只能以为没反应。这里在
                // 顶部叠一条细进度条，不遮挡内容。
                .overlay(alignment: .top) {
                    if isReloading {
                        ProgressView()
                            .progressViewStyle(.linear)
                            .controlSize(.small)
                            .tint(.accentColor)
                            .transition(.opacity)
                    }
                }
                .animation(.easeOut(duration: 0.15), value: isReloading)
            } else if isLoading {
                VStack(spacing: 10) {
                    ProgressView()
                    Text(L10n.Plugins.pageLoading).foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                AgentPluginUnavailableView(
                    title: L10n.Plugins.pageUnavailable,
                    detail: errorMessage ?? L10n.Plugins.pageUnavailable,
                    systemImage: "exclamationmark.triangle"
                ) {
                    Button(L10n.Plugins.retry) {
                        sessionState.requestRefresh(destinationID: destination.qualifiedID)
                    }
                    Button(L10n.Plugins.openMCPSettings) {
                        EditorSettingsNavigation.shared.open(.mcp, appState: appState)
                    }
                }
            }
        }
        .task(id: taskIdentity) {
            // 第一次进来 html 还是 nil，走占位视图；之后每次 generation 变化
            // 都是一次手动重载，改用顶部进度条给反馈。
            let isManualReload = html != nil
            if isManualReload { isReloading = true }
            await loadPage(keepingPreviousHTML: isManualReload)
            if isManualReload {
                // 本地入口文件读起来只要几毫秒，进度条一闪而过等于没有。
                // 压到最短可见时长，让「点了有反应」这件事成立。
                try? await Task.sleep(nanoseconds: 320_000_000)
                isReloading = false
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: .agentMCPResourcesDidChange)) { notification in
            guard destination.mainPage.runtime == .mcpApp,
                  let server = destination.mainPage.server,
                  let uri = destination.mainPage.resourceURI,
                  notification.userInfo?[AgentMCPResourceNotificationKey.serverID] as? String
                    == "plugin:\(destination.pluginID):\(server)" else {
                return
            }
            let changedURI = notification.userInfo?[AgentMCPResourceNotificationKey.uri] as? String
            if changedURI == nil || changedURI == uri {
                sessionState.requestRefresh(destinationID: destination.qualifiedID)
            }
        }
    }

    private var taskIdentity: String {
        let generation = sessionState.refreshGenerations[destination.qualifiedID, default: 0]
        // packageURL 参与身份：注册表刷新把同名插件的激活包从一个副本切到另一个
        // 副本（内置 ↔ 本地安装同版本并存时会发生）后，必须以新副本重读入口
        // HTML，否则旧 HTML 配新资源根，哈希对不上的子资源整页白掉。
        return "\(destination.qualifiedID):\(generation):\(destination.packageURL.path)"
    }

    private var destinationContext: AgentPluginDestinationContext {
        let manifest = AgentPluginRegistry.shared.record(pluginID: destination.pluginID)?.activePackage.manifest
        let permissions = Set(manifest?.permissions ?? [])
        let workspace = permissions.contains(.workspaceRead) || permissions.contains(.workspaceWrite)
            ? (appState.activeRuntime?.workspaceLocation?.localPath
                ?? appState.activeRuntime?.workspaceRootPath
                ?? appState.rootDirectory?.path)
            : nil
        let session = permissions.contains(.conversationRead)
            ? appState.activeAgentSessionID?.uuidString
            : nil
        return AgentPluginDestinationContext(
            destinationID: destination.qualifiedID,
            selectedItemID: sessionState.selectedItemID(for: destination.qualifiedID),
            workspaceReference: workspace,
            sessionReference: session,
            locale: Locale.current.identifier,
            colorScheme: colorScheme == .dark ? "dark" : "light"
        )
    }

    private func loadPage(keepingPreviousHTML: Bool = false) async {
        isLoading = true
        // 重载时留着旧页面，避免整块内容闪成空白再长回来。
        if !keepingPreviousHTML { html = nil }
        errorMessage = nil
        do {
            switch destination.mainPage.runtime {
            case .localWeb:
                guard let path = destination.mainPage.entryPath else {
                    throw AgentPluginPackageError.invalidContribution(destination.mainPage.id)
                }
                let url = try AgentPluginPackageLoader.safeResourceURL(
                    relativePath: path,
                    packageURL: destination.packageURL
                )
                let data = try Data(contentsOf: url)
                guard let source = String(data: data, encoding: .utf8), !source.isEmpty else {
                    throw AgentPluginPackageError.unreadableManifest(path)
                }
                baseURL = url.deletingLastPathComponent()
                html = source
            case .mcpApp:
                guard let server = destination.mainPage.server,
                      let uri = destination.mainPage.resourceURI else {
                    throw AgentPluginPackageError.invalidContribution(destination.mainPage.id)
                }
                let payload = try await AgentMCPBridge.readPluginResource(
                    pluginID: destination.pluginID,
                    serverName: server,
                    uri: uri
                )
                Task {
                    try? await AgentMCPBridge.subscribePluginResource(
                        pluginID: destination.pluginID,
                        serverName: server,
                        uri: uri
                    )
                }
                let resource = try AgentPluginMCPResourcePayload.mcpAppDocument(
                    from: payload,
                    expectedURI: uri
                )
                html = resource.text
                baseURL = nil
            case .declarative:
                break
            }
        } catch {
            errorMessage = error.localizedDescription
        }
        isLoading = false
    }

    private func composedHTML(_ source: String) -> String {
        let background = colorScheme == .dark ? "#1c1c1e" : "#ffffff"
        let foreground = colorScheme == .dark ? "#f2f2f4" : "#1a1a1c"
        let secondary = colorScheme == .dark ? "#a1a1a6" : "#6c6c70"
        let accent = colorScheme == .dark ? "#f2f2f4" : "#111111"
        let bodyFontSize = Int(appState.agentChatBaseFontSize.rounded())
        let csp = "default-src 'self' 'unsafe-inline' data: blob:; "
            + "script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; "
            + "img-src 'self' data: blob:; connect-src 'none'; frame-src 'none'; "
            + "object-src 'none'; base-uri 'none'; form-action 'none';"
        let bootstrap = """
        <meta http-equiv="Content-Security-Policy" content="\(csp)">
        <style>
        :root { --willdeep-bg: \(background); --willdeep-fg: \(foreground); --willdeep-secondary: \(secondary); --willdeep-accent: \(accent); --willdeep-body-font-size: \(bodyFontSize)px; color-scheme: \(colorScheme == .dark ? "dark" : "light"); }
        html, body { margin: 0; min-height: 100%; background: var(--willdeep-bg); color: var(--willdeep-fg); font-family: -apple-system, BlinkMacSystemFont, sans-serif; font-size: var(--willdeep-body-font-size); }
        input, button, select, textarea { accent-color: var(--willdeep-accent); }
        a { color: var(--willdeep-accent); }
        </style>
        <script>
        (function() {
          var handler = window.webkit && window.webkit.messageHandlers && window.webkit.messageHandlers.willdeepPlugin;
          window.willdeep = window.willdeep || {};
          window.willdeep.getContext = function() { return window.__WILLDEEP_CONTEXT__ || {}; };
          window.willdeep.selectItem = function(itemID) { if (handler) handler.postMessage({type:'selectItem', itemID:itemID}); };
          window.willdeep.refresh = function() { if (handler) handler.postMessage({type:'refresh'}); };
          window.willdeep.openConversation = function(sessionID, messageID) {
            if (handler) handler.postMessage({type:'openConversation', sessionID:sessionID, messageID:messageID});
          };
          window.willdeep.executeCommand = function(commandID, args) {
            var requestID = (window.crypto && crypto.randomUUID) ? crypto.randomUUID() : String(Date.now()) + Math.random();
            if (handler) handler.postMessage({type:'executeCommand', requestID:requestID, commandID:commandID, arguments:args || {}});
            return new Promise(function(resolve, reject) {
              function listener(event) {
                if (!event.detail || event.detail.requestID !== requestID) return;
                window.removeEventListener('willdeep:command-result', listener);
                if (event.detail.error) reject(new Error(event.detail.error)); else resolve(event.detail.result);
              }
              window.addEventListener('willdeep:command-result', listener);
            });
          };
          function willdeepBridgeRequest(type, payload) {
            var requestID = (window.crypto && crypto.randomUUID) ? crypto.randomUUID() : String(Date.now()) + Math.random();
            var message = {type:type, requestID:requestID};
            for (var key in payload) { if (Object.prototype.hasOwnProperty.call(payload, key)) message[key] = payload[key]; }
            if (handler) handler.postMessage(message);
            return new Promise(function(resolve, reject) {
              function listener(event) {
                if (!event.detail || event.detail.requestID !== requestID) return;
                window.removeEventListener('willdeep:bridge-result', listener);
                if (event.detail.error) reject(new Error(event.detail.error)); else resolve(event.detail.result);
              }
              window.addEventListener('willdeep:bridge-result', listener);
            });
          }
          // 插件能问模型，但拿不到任何一把 key：provider 与模型都由宿主校验，
          // 页面递上来的 baseURL 一律不认。需要 ai.chat / providers.read 权限。
          window.willdeep.ai = {
            providers: function() { return willdeepBridgeRequest('aiProviders', {}); },
            complete: function(request) { return willdeepBridgeRequest('aiComplete', {request: request || {}}); },
            // 停止一条正在跑的对话。按 complete() 里传的 streamID 找：没传
            // streamID 的请求停不了，因为页面手上没有别的把手。停下来之后
            // complete() 那个 promise 会以「已取消」reject。
            cancel: function(streamID) { return willdeepBridgeRequest('aiCancel', {streamID: streamID || ''}); },
            generateImage: function(request) { return willdeepBridgeRequest('aiGenerateImage', {request: request || {}}); }
          };
          // 已启用技能的只读清单。页面拿到的是 identifier / 名称 / 描述，
          // SKILL.md 正文和它的磁盘路径都不出宿主：把 identifier 放进
          // ai.complete 的 skills 数组，宿主会替你把正文读出来注入。
          window.willdeep.skills = {
            list: function() { return willdeepBridgeRequest('skillsList', {}); }
          };
          // 工作区文件的只读通道。路径可以是相对当前工作区根的，也可以是
          // fs.list 回给你的绝对路径；越界的一律拒。需要 workspace.read。
          window.willdeep.fs = {
            list: function(path) { return willdeepBridgeRequest('fsList', {path: path || ''}); },
            read: function(path) { return willdeepBridgeRequest('fsRead', {path: path || ''}); },
            search: function(request) {
              var req = request || {};
              return willdeepBridgeRequest('fsSearch', {
                query: req.query || '',
                path: req.path || '',
                regex: !!req.regex,
                limit: req.limit || 0
              });
            }
          };
          // 插件自己的小仓库。页面跑在 nonPersistent 的 WebView 里,
          // localStorage 刷新一次就空了,要跨刷新记住东西就用这个。
          window.willdeep.storage = {
            get: function(key) { return willdeepBridgeRequest('storageGet', {key: key}); },
            set: function(key, value) { return willdeepBridgeRequest('storageSet', {key: key, value: value}); },
            remove: function(key) { return willdeepBridgeRequest('storageRemove', {key: key}); },
            keys: function() { return willdeepBridgeRequest('storageKeys', {}); }
          };
          // 宿主事件。willdeep.events.on('turn.finished', cb) 之后,宿主每次
          // 推事件都会调你的回调,不用再拿定时器扫。
          var willdeepEventListeners = {};
          window.addEventListener('willdeep:host-event', function(event) {
            var detail = event.detail || {};
            var listeners = willdeepEventListeners[detail.name] || [];
            for (var i = 0; i < listeners.length; i++) {
              try { listeners[i](detail.payload || {}); } catch (error) { /* 插件的回调炸了不该带塌桥 */ }
            }
          });
          window.willdeep.events = {
            on: function(name, callback) {
              if (typeof callback !== 'function') return Promise.reject(new Error('callback must be a function'));
              willdeepEventListeners[name] = (willdeepEventListeners[name] || []).concat([callback]);
              return willdeepBridgeRequest('eventsSubscribe', {name: name});
            },
            off: function(name, callback) {
              var listeners = willdeepEventListeners[name] || [];
              willdeepEventListeners[name] = callback
                ? listeners.filter(function(entry) { return entry !== callback; })
                : [];
            }
          };
          // 写工作区文件（需要 workspace.write）。走的是 Agent 改文件同一条
          // 路：路径守卫、编辑器同步、改动登记全都继承,写完能在 Changes
          // 面板里看到。
          window.willdeep.fs.write = function(path, text) {
            return willdeepBridgeRequest('fsWrite', {path: path || '', text: text || ''});
          };
          // 改一段而不是整文件覆盖。找不到、不唯一、改了个寂寞,三种失败的
          // 判定与报错跟 Agent 的 edit_file 完全一致。
          window.willdeep.fs.patch = function(path, oldString, newString, options) {
            var opts = options || {};
            return willdeepBridgeRequest('fsPatch', {
              path: path || '',
              oldString: oldString || '',
              newString: typeof newString === 'string' ? newString : '',
              replaceAll: !!opts.replaceAll
            });
          };
          // 跑命令（需要 process.execute）。只读命令直接跑,其余一律弹确认框,
          // 恶意名单上的连问都不问。
          window.willdeep.process = {
            run: function(command) { return willdeepBridgeRequest('processRun', {command: command || ''}); }
          };
          // 宿主代发的 HTTP（需要 network.access + manifest 里的 networkDomains）。
          window.willdeep.net = {
            fetch: function(url, init) {
              var options = init || {};
              return willdeepBridgeRequest('netFetch', {
                url: url || '',
                method: options.method || 'GET',
                headers: options.headers || {},
                body: typeof options.body === 'string' ? options.body : null
              });
            }
          };
          window.willdeep.clipboard = {
            write: function(text) { return willdeepBridgeRequest('clipboardWrite', {text: text || ''}); }
          };
          window.willdeep.notify = function(notification) {
            var payload = notification || {};
            return willdeepBridgeRequest('notify', {title: payload.title || '', body: payload.body || ''});
          };
          // 把活交给主 Agent。insert 只填输入框,send 才真的起回合。
          // 需要 conversation.write。
          window.willdeep.chat = {
            insert: function(text) { return willdeepBridgeRequest('chatInsert', {text: text || ''}); },
            send: function(text) { return willdeepBridgeRequest('chatSend', {text: text || ''}); }
          };
          // 桥的版本与能力清单。插件据此降级,而不是在旧宿主上白屏:
          //   if ((window.willdeep.capabilities || []).indexOf('fs.search') >= 0) { … }
          window.willdeep.version = '\(AgentPluginPageBridge.version)';
          window.willdeep.capabilities = \(AgentPluginPageBridge.capabilitiesJSONLiteral);
          window.__willdeepDeliverMCPMessage = function(message) {
            window.dispatchEvent(new MessageEvent('message', {data:message, source:null}));
          };
          window.addEventListener('message', function(event) {
            var data = event.data;
            if (event.source !== window || !data || data.jsonrpc !== '2.0' || typeof data.method !== 'string') return;
            if (handler) handler.postMessage({type:'mcpMessage', message:data});
          });
          // 子资源加载失败与 CSP 拦截不会触发任何导航回调，宿主此前完全不可见；
          // 这里回传给宿主打日志，让"白页"类故障有现场可查。
          function reportPageDiagnostic(kind, detail) {
            if (handler) handler.postMessage({type:'pageDiagnostic', kind:String(kind), detail:String(detail).slice(0, 512)});
          }
          window.addEventListener('error', function(event) {
            var target = event.target || {};
            if (target !== window && target.tagName) {
              reportPageDiagnostic('resource-error', target.tagName + ' ' + (target.src || target.href || ''));
            } else if (event.message) {
              reportPageDiagnostic('js-error', event.message + ' @' + (event.filename || '') + ':' + (event.lineno || 0));
            }
          }, true);
          window.addEventListener('securitypolicyviolation', function(event) {
            reportPageDiagnostic('csp', event.violatedDirective + ' blocked ' + (event.blockedURI || ''));
          });
        })();
        </script>
        """
        if let range = source.range(of: "<head", options: .caseInsensitive),
           let close = source[range.lowerBound...].firstIndex(of: ">") {
            var copy = source
            copy.insert(contentsOf: bootstrap, at: copy.index(after: close))
            return copy
        }
        return "<!doctype html><html><head>\(bootstrap)</head><body>\(source)</body></html>"
    }
}

private struct AgentPluginDeclarativePage: View {
    let destination: AgentPluginDestinationDescriptor
    @State private var document: AgentPluginSidebarDocument?
    @State private var error: String?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 14) {
                if let document {
                    ForEach(document.components) { component in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(localized(component.titleKey))
                                .font(component.kind == .section ? .headline : .body)
                            if let subtitle = component.subtitleKey {
                                Text(localized(subtitle)).foregroundStyle(.secondary)
                            }
                            if let progress = component.progress {
                                ProgressView(value: max(0, min(progress, 1)))
                            }
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(14)
                        .background(RoundedRectangle(cornerRadius: 10).fill(Color.primary.opacity(0.04)))
                    }
                } else if let error {
                    AgentPluginUnavailableView(
                        title: L10n.Plugins.pageUnavailable,
                        detail: error,
                        systemImage: "exclamationmark.triangle"
                    ) { EmptyView() }
                } else {
                    ProgressView().frame(maxWidth: .infinity)
                }
            }
            .padding(20)
        }
        .task { await load() }
    }

    private func localized(_ key: String?) -> String {
        guard let key else { return "" }
        return AgentPluginRegistry.shared.localizedString(key, pluginID: destination.pluginID)
    }

    private func load() async {
        guard let schema = destination.mainPage.schema else {
            error = L10n.Plugins.pageUnavailable
            return
        }
        do {
            let url = try AgentPluginPackageLoader.safeResourceURL(relativePath: schema, packageURL: destination.packageURL)
            let data = try Data(contentsOf: url)
            document = try JSONDecoder().decode(AgentPluginSidebarDocument.self, from: data)
        } catch {
            self.error = error.localizedDescription
        }
    }
}

private struct AgentPluginUnavailableView<Actions: View>: View {
    let title: String
    let detail: String
    let systemImage: String
    @ViewBuilder let actions: () -> Actions

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 28, weight: .regular))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.system(size: 16, weight: .semibold))
            Text(detail)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 420)
            HStack(spacing: 8) { actions() }
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct AgentPluginWebView: NSViewRepresentable {
    let html: String
    let baseURL: URL?
    let destination: AgentPluginDestinationDescriptor
    let context: AgentPluginDestinationContext
    let appState: AppState

    /// 缓存键跟着激活包走：重装或内置↔本地切换后必须另起一张页面。
    private var liveCacheKey: String {
        AgentPluginLivePageCache.key(
            destinationID: destination.qualifiedID,
            packagePath: destination.packageURL.path
        )
    }

    func makeNSView(context coordinatorContext: Context) -> WKWebView {
        // 离屏保活：用户切去聊天再切回来时，把原来那张还活着的页面挂回去，
        // 而不是重新载入一张空白的。makeCoordinator 已经把同一个 Coordinator
        // 取了回来，两者必须成对，否则消息桥会接到一个陌生的 WebView 上。
        if let cached = AgentPluginLivePageCache.shared.reusableEntry(for: liveCacheKey),
           cached.coordinator === coordinatorContext.coordinator {
            AgentPluginLivePageCache.shared.markMounted(liveCacheKey)
            return cached.webView
        }
        let configuration = WKWebViewConfiguration()
        // 一个插件一个持久化仓：页面刷新不再丢 localStorage，同时因为
        // 所有插件页面共用同一个源（willdeep-plugin://bundle/），必须靠
        // 分仓而不是靠源隔离来防止互相读取。详见 AgentPluginWebsiteDataStore。
        configuration.websiteDataStore = AgentPluginWebsiteDataStore.store(for: destination.pluginID)
        let schemeHandler = AgentPluginSchemeHandler(
            packageURL: destination.packageURL,
            pluginID: destination.pluginID
        )
        configuration.setURLSchemeHandler(schemeHandler, forURLScheme: AgentPluginSchemeHandler.scheme)
        coordinatorContext.coordinator.schemeHandler = schemeHandler
        let preferences = WKWebpagePreferences()
        preferences.allowsContentJavaScript = true
        configuration.defaultWebpagePreferences = preferences
        configuration.userContentController.add(coordinatorContext.coordinator, name: "willdeepPlugin")
        let webView = WKWebView(frame: .zero, configuration: configuration)
        // 网页检查器：默认关，插件作者在设置里自己开。开着不多给页面任何
        // 能力，但检查器能读到页面内存里的一切，不该是所有用户的默认状态。
        if #available(macOS 13.3, *) {
            webView.isInspectable = AgentSettingsStore.loadPluginPageInspectable()
        }
        webView.navigationDelegate = coordinatorContext.coordinator
        webView.uiDelegate = coordinatorContext.coordinator
        webView.setValue(false, forKey: "drawsBackground")
        coordinatorContext.coordinator.webView = webView
        // 同一个目标换了激活包（重装、内置↔本地切换）会落到另一个键上，
        // 旧那张页面对着旧资源根，留着只会占容量，直接拆掉。
        var evicted = AgentPluginLivePageCache.shared.evictAll(destinationID: destination.qualifiedID)
        evicted += AgentPluginLivePageCache.shared.store(
            webView: webView,
            coordinator: coordinatorContext.coordinator,
            for: liveCacheKey
        )
        for entry in evicted where entry.webView !== webView {
            Self.tearDown(entry.webView, coordinator: entry.coordinator as? Coordinator)
        }
        return webView
    }

    func updateNSView(_ webView: WKWebView, context coordinatorContext: Context) {
        let coordinator = coordinatorContext.coordinator
        coordinator.destination = destination
        coordinator.destinationContext = context
        coordinator.appState = appState
        coordinator.schemeHandler?.packageURL = destination.packageURL
        coordinator.schemeHandler?.pluginID = destination.pluginID
        if coordinator.loadedHTML != html || coordinator.baseURL != baseURL {
            coordinator.prepareForReload()
            coordinator.loadedHTML = html
            coordinator.baseURL = baseURL
            webView.loadHTMLString(html, baseURL: coordinator.pluginBaseURL(for: baseURL))
        } else {
            coordinator.pushContext()
        }
    }

    func makeCoordinator() -> Coordinator {
        // 复用缓存里的 Coordinator，页面的桥接状态（已加载的 HTML、MCP
        // 订阅、scheme handler）才跟着一起回来；新建一个的话 loadedHTML 是
        // 空的，updateNSView 会立刻把页面重载，保活就白做了。
        if let cached = AgentPluginLivePageCache.shared.reusableEntry(for: liveCacheKey)?.coordinator
            as? Coordinator {
            return cached
        }
        return Coordinator(destination: destination, destinationContext: context, appState: appState)
    }

    static func dismantleNSView(_ nsView: WKWebView, coordinator: Coordinator) {
        // 归缓存所有的页面只是暂时离屏，不能拆：拆掉等于把玩到一半的游戏、
        // 填了一半的表单清零，而这正是用户切一下就回来时最不该发生的事。
        if AgentPluginLivePageCache.shared.markUnmounted(nsView) { return }
        tearDown(nsView, coordinator: coordinator)
    }

    /// 真正的拆卸：页面被淘汰或不再归缓存所有时才走这里。
    static func tearDown(_ webView: WKWebView, coordinator: Coordinator?) {
        // 页面没了还在跑的模型请求就是纯烧钱：结果没人收，增量也送不出去。
        // 注意这里只在真正拆卸时走到——归缓存的离屏页面在 dismantleNSView
        // 就返回了，它的请求要继续跑，用户切回来时还等着看结果。
        coordinator?.cancelAllAIRequests()
        coordinator?.sendMCPRequest(
            method: "ui/resource-teardown",
            params: ["reason": "destination-closed"]
        )
        webView.configuration.userContentController.removeScriptMessageHandler(forName: "willdeepPlugin")
    }

    final class Coordinator: NSObject, WKNavigationDelegate, WKUIDelegate, WKScriptMessageHandler {
        var destination: AgentPluginDestinationDescriptor
        var destinationContext: AgentPluginDestinationContext
        weak var appState: AppState?
        weak var webView: WKWebView?
        var loadedHTML: String?
        var baseURL: URL?
        var schemeHandler: AgentPluginSchemeHandler?
        var consecutiveProcessCrashes = 0
        var mcpAppInitialized = false
        var nextHostRequestID = 1
        var crashResetWorkItem: DispatchWorkItem?
        /// 在跑的插件 AI 请求，requestID -> Task。没有它时关掉页面只是
        /// 把结果丢了，请求本身会一路跑完并照常计费。
        private var runningAIRequests: [String: Task<Void, Never>] = [:]
        /// 页面自己生成的 streamID -> 宿主 requestID。取消只能按前者找。
        private var aiRequestIDsByStreamID: [String: String] = [:]
        var navigationFailureRetries = 0
        var isShowingFailureDocument = false
        /// 页面订阅了哪些宿主事件。没订阅的事件不推——省掉一次
        /// evaluateJavaScript，也避免插件收到自己没要的东西。
        var subscribedHostEvents: Set<AgentPluginHostEvent> = []
        var hostEventSubscriptions: [AnyCancellable] = []
        /// 上一次推给页面的会话与回合状态，用于把 @Published 的重复发布
        /// 收敛成「真的变了才推」。
        var lastPublishedSessionID: UUID?
        var lastPublishedResponding = false

        init(
            destination: AgentPluginDestinationDescriptor,
            destinationContext: AgentPluginDestinationContext,
            appState: AppState
        ) {
            self.destination = destination
            self.destinationContext = destinationContext
            self.appState = appState
        }

        func webView(_ webView: WKWebView, didFinish navigation: WKNavigation!) {
            pushContext()
            if !isShowingFailureDocument { navigationFailureRetries = 0 }
            crashResetWorkItem?.cancel()
            let workItem = DispatchWorkItem { [weak self] in
                self?.consecutiveProcessCrashes = 0
            }
            crashResetWorkItem = workItem
            DispatchQueue.main.asyncAfter(deadline: .now() + 10, execute: workItem)
        }

        func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
            crashResetWorkItem?.cancel()
            mcpAppInitialized = false
            consecutiveProcessCrashes += 1
            guard consecutiveProcessCrashes >= 3 else {
                // 页面是 loadHTMLString 灌进去的，reload() 只会去请求 baseURL 那个目录，
                // 换来一张白页；恢复必须重灌同一份 HTML。
                reloadDocument()
                return
            }
            let pluginName = destination.pluginID
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let alert = NSAlert()
                alert.alertStyle = .warning
                alert.messageText = "\(pluginName): \(L10n.Plugins.pageUnavailable)"
                alert.informativeText = L10n.Plugins.pageCrashedRepeatedly
                alert.addButton(withTitle: L10n.Plugins.morePlugins)
                alert.addButton(withTitle: L10n.Plugins.cancel)
                if alert.runModal() == .alertFirstButtonReturn {
                    self.appState?.agentPrimaryDestination = .pluginCenter
                }
            }
        }

        func prepareForReload() {
            crashResetWorkItem?.cancel()
            mcpAppInitialized = false
            navigationFailureRetries = 0
            isShowingFailureDocument = false
        }

        /// 重新灌入当前文档。WKWebView 的 `reload()` 对 loadHTMLString 加载的页面无效：
        /// 它请求的是 baseURL（插件包里的目录），拿不到内容就留下一张白页。
        func reloadDocument() {
            guard let webView, let loadedHTML else { return }
            mcpAppInitialized = false
            webView.loadHTMLString(loadedHTML, baseURL: pluginBaseURL(for: baseURL))
        }

        func webView(
            _ webView: WKWebView,
            didFailProvisionalNavigation navigation: WKNavigation!,
            withError error: Error
        ) {
            handleNavigationFailure(error)
        }

        func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
            handleNavigationFailure(error)
        }

        /// 导航失败以前是彻底静默的：用户看到的就是一张白页，没有任何提示。
        /// 先重灌一次，仍旧失败就把错误显示出来。
        private func handleNavigationFailure(_ error: Error) {
            if (error as NSError).code == NSURLErrorCancelled { return }
            guard navigationFailureRetries < 1 else {
                showFailureDocument(message: error.localizedDescription)
                return
            }
            navigationFailureRetries += 1
            reloadDocument()
        }

        private func showFailureDocument(message: String) {
            guard let webView, !isShowingFailureDocument else { return }
            isShowingFailureDocument = true
            let document = """
            <!doctype html><html><head><meta charset="utf-8">
            <style>
            html, body { margin: 0; height: 100%; font-family: -apple-system, BlinkMacSystemFont, sans-serif; }
            body { display: flex; flex-direction: column; align-items: center; justify-content: center; gap: 8px; \
            color: \(destinationContext.colorScheme == "dark" ? "#f2f2f4" : "#1a1a1c"); \
            background: \(destinationContext.colorScheme == "dark" ? "#1c1c1e" : "#ffffff"); }
            .title { font-size: 15px; font-weight: 600; }
            .detail { font-size: 12px; opacity: 0.6; max-width: 420px; text-align: center; }
            </style></head><body>
            <div class="title">\(Self.escapeHTML(L10n.Plugins.pageUnavailable))</div>
            <div class="detail">\(Self.escapeHTML(message))</div>
            </body></html>
            """
            webView.loadHTMLString(document, baseURL: nil)
        }

        private static func escapeHTML(_ raw: String) -> String {
            raw.replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
        }

        func webView(
            _ webView: WKWebView,
            decidePolicyFor navigationAction: WKNavigationAction,
            decisionHandler: @escaping (WKNavigationActionPolicy) -> Void
        ) {
            guard let url = navigationAction.request.url else {
                decisionHandler(.cancel)
                return
            }
            let scheme = url.scheme?.lowercased() ?? ""
            if scheme == "about" || scheme == "data" {
                decisionHandler(.allow)
                return
            }
            if scheme == AgentPluginSchemeHandler.scheme, url.host == AgentPluginSchemeHandler.host {
                decisionHandler(.allow)
                return
            }
            decisionHandler(.cancel)
        }

        func webView(
            _ webView: WKWebView,
            createWebViewWith configuration: WKWebViewConfiguration,
            for navigationAction: WKNavigationAction,
            windowFeatures: WKWindowFeatures
        ) -> WKWebView? {
            nil
        }

        func userContentController(_ userContentController: WKUserContentController, didReceive message: WKScriptMessage) {
            guard let body = message.body as? [String: Any],
                  let type = body["type"] as? String else { return }
            switch type {
            case "selectItem":
                let itemID = (body["itemID"] as? String).map { String($0.prefix(512)) }
                Task { @MainActor in
                    AgentPluginDestinationSessionState.shared.select(
                        itemID: itemID,
                        destinationID: destination.qualifiedID
                    )
                }
            case "refresh":
                Task { @MainActor in
                    AgentPluginDestinationSessionState.shared.requestRefresh(
                        destinationID: destination.qualifiedID
                    )
                }
            case "executeCommand":
                executeCommand(body)
            case "openConversation":
                openConversation(body)
            case "aiProviders":
                listAIProviders(body)
            case "aiComplete":
                runAICompletion(body)
            case "aiCancel":
                cancelAICompletion(body)
            case "aiGenerateImage":
                runAIImageGeneration(body)
            case "skillsList":
                listSkills(body)
            case "fsList", "fsRead", "fsSearch":
                handleFileRequest(type: type, body: body)
            case "storageGet", "storageSet", "storageRemove", "storageKeys":
                handleStorageRequest(type: type, body: body)
            case "eventsSubscribe":
                handleEventSubscription(body)
            case "chatInsert", "chatSend":
                handleChatRequest(type: type, body: body)
            case "fsWrite":
                handleFileWrite(body)
            case "fsPatch":
                handleFilePatch(body)
            case "processRun":
                handleProcessRun(body)
            case "netFetch":
                handleNetworkFetch(body)
            case "clipboardWrite", "notify":
                handleDeviceRequest(type: type, body: body)
            case "mcpMessage":
                handleMCPMessage(body["message"])
            case "pageDiagnostic":
                let kind = String((body["kind"] as? String ?? "unknown").prefix(64))
                let detail = String((body["detail"] as? String ?? "").prefix(512))
                pluginPageLog.error(
                    "plugin page diagnostic: plugin=\(self.destination.pluginID, privacy: .public) kind=\(kind, privacy: .public) detail=\(detail, privacy: .public)"
                )
            default:
                break
            }
        }

        func pushContext() {
            guard let webView,
                  let data = try? JSONEncoder().encode(destinationContext),
                  let json = String(data: data, encoding: .utf8) else { return }
            let script = "window.__WILLDEEP_CONTEXT__ = \(json); window.dispatchEvent(new CustomEvent('willdeep:context-changed', {detail: window.__WILLDEEP_CONTEXT__}));"
            webView.evaluateJavaScript(script)
            if destination.mainPage.runtime == .mcpApp, mcpAppInitialized,
               let contextObject = try? JSONSerialization.jsonObject(with: data) {
                sendMCPMessage([
                    "jsonrpc": "2.0",
                    "method": "ui/notifications/host-context-changed",
                    "params": [
                        "theme": destinationContext.colorScheme,
                        "locale": destinationContext.locale,
                        "willdeep": contextObject,
                    ],
                ])
            }
        }

        func pluginBaseURL(for localBaseURL: URL?) -> URL? {
            let mapped = AgentPluginWebResourceResolver.schemeBaseURL(
                forEntryDirectory: localBaseURL,
                packageURL: destination.packageURL
            )
            if mapped == nil, localBaseURL != nil {
                // baseURL 落空意味着页面里所有相对子资源都会静默加载失败，
                // 留一条日志让这类"白页"下次能自己喊出来。
                pluginPageLog.error(
                    "plugin page baseURL mismatch: plugin=\(self.destination.pluginID, privacy: .public) entryDir=\(localBaseURL?.path ?? "nil", privacy: .public) package=\(self.destination.packageURL.path, privacy: .public)"
                )
            }
            return mapped
        }

        private func executeCommand(_ body: [String: Any]) {
            let requestID = (body["requestID"] as? String).map { String($0.prefix(160)) } ?? UUID().uuidString
            let pluginID = destination.pluginID
            let rawArguments = body["arguments"] as? [String: Any] ?? [:]
            let encodedArguments = JSONSerialization.isValidJSONObject(rawArguments)
                ? try? JSONSerialization.data(withJSONObject: rawArguments)
                : nil
            let argumentBytes = encodedArguments?.count ?? 0

            func record(commandID: String, resultBytes: Int, seconds: Double, outcome: String, error: String?) {
                AgentPluginAuditLog.recordHostCall(AgentPluginAuditLog.HostCall(
                    recordedAt: Date(),
                    pluginID: pluginID,
                    commandID: String(commandID.prefix(160)),
                    argumentCount: rawArguments.count,
                    argumentBytes: argumentBytes,
                    resultBytes: resultBytes,
                    seconds: seconds,
                    outcome: outcome,
                    errorDescription: error.map { String($0.prefix(240)) }
                ))
            }

            // 这几道门槛原先是**静默 return**：页面的 promise 永远不落地，
            // 表现是按钮一直转，既没有结果也没有错误。既然现在要记这条路，
            // 就一并把它改成回一个错误——留痕一个「什么都没发生」的调用，
            // 不如让调用方知道自己被拒了。
            guard let commandID = body["commandID"] as? String, commandID.count <= 160 else {
                record(commandID: "", resultBytes: 0, seconds: 0, outcome: "rejected", error: "invalid commandID")
                sendCommandResult(requestID: requestID, result: nil, error: "Invalid command identifier")
                return
            }
            guard AgentPluginCommandArgumentPolicy.accepts(
                keyCount: rawArguments.count, encodedArguments: encodedArguments
            ) else {
                record(
                    commandID: commandID, resultBytes: 0, seconds: 0, outcome: "rejected",
                    error: "arguments too large: \(rawArguments.count) keys, \(argumentBytes) bytes"
                )
                sendCommandResult(requestID: requestID, result: nil, error: "Command arguments are too large")
                return
            }
            let startedAt = Date()
            Task { @MainActor [weak self] in
                guard let self, let appState = self.appState else { return }
                do {
                    let result = try await AgentPluginCommandExecutor.executeJSON(
                        pluginID: pluginID,
                        commandID: commandID,
                        arguments: rawArguments,
                        destinationID: self.destination.qualifiedID,
                        appState: appState
                    )
                    // 字节数而不是内容：这条路最常见的故障是页面 JSON.parse
                    // 抛「Unterminated string」，那时要问的是回了多少字节。
                    record(
                        commandID: commandID,
                        resultBytes: result?.utf8.count ?? 0,
                        seconds: Date().timeIntervalSince(startedAt),
                        outcome: "succeeded", error: nil
                    )
                    self.sendCommandResult(requestID: requestID, result: result, error: nil)
                } catch {
                    record(
                        commandID: commandID, resultBytes: 0,
                        seconds: Date().timeIntervalSince(startedAt),
                        outcome: "failed", error: error.localizedDescription
                    )
                    self.sendCommandResult(requestID: requestID, result: nil, error: error.localizedDescription)
                }
            }
        }

        private func openConversation(_ body: [String: Any]) {
            guard AgentPluginRegistry.shared.hasPermission(
                .conversationRead,
                pluginID: destination.pluginID
            ),
                  let sessionString = body["sessionID"] as? String,
                  let messageString = body["messageID"] as? String,
                  let sessionID = UUID(uuidString: sessionString),
                  let messageID = UUID(uuidString: messageString),
                  let session = AgentSessionStore.load(id: sessionID),
                  let message = session.messages.first(where: { $0.id == messageID }) else {
                return
            }
            Task { @MainActor [weak self] in
                guard let appState = self?.appState else { return }
                appState.isAgentPanelVisible = true
                appState.agentPrimaryDestination = .conversation
                _ = appState.selectAndRevealAgentSessionInSidebar(id: sessionID)
                AgentTranscriptReader.openSingleMessage(message, sessionTitle: session.title)
            }
        }

        /// 已启用技能的只读清单，给页面自己实现 `$` 选择器用。技能正文不经手
        /// 页面：它把选中的 identifier 放进 ai.complete 的 skills，由宿主注入。
        private func listSkills(_ body: [String: Any]) {
            let requestID = (body["requestID"] as? String).map { String($0.prefix(160)) } ?? UUID().uuidString
            guard AgentPluginRegistry.shared.hasPermission(
                .skillsRead,
                pluginID: destination.pluginID
            ) else {
                sendBridgeResult(
                    requestID: requestID,
                    result: nil,
                    error: AgentPluginAIError.skillPermissionDenied.localizedDescription
                )
                return
            }
            Task { [weak self] in
                let skills = await AppState.pluginSkills().map(\.jsonObject)
                await MainActor.run {
                    self?.sendBridgeResult(requestID: requestID, result: ["skills": skills], error: nil)
                }
            }
        }

        private func listAIProviders(_ body: [String: Any]) {
            let requestID = (body["requestID"] as? String).map { String($0.prefix(160)) } ?? UUID().uuidString
            Task { @MainActor [weak self] in
                guard let self, let appState = self.appState else { return }
                guard AgentPluginRegistry.shared.hasPermission(
                    .providersRead,
                    pluginID: self.destination.pluginID
                ) || AgentPluginRegistry.shared.hasPermission(
                    .aiChat,
                    pluginID: self.destination.pluginID
                ) else {
                    self.sendBridgeResult(
                        requestID: requestID,
                        result: nil,
                        error: AgentPluginAIError.permissionDenied.localizedDescription
                    )
                    return
                }
                let providers = await appState.pluginAIProviders().map(\.jsonObject)
                self.sendBridgeResult(requestID: requestID, result: ["providers": providers], error: nil)
            }
        }

        private func runAICompletion(_ body: [String: Any]) {
            let requestID = (body["requestID"] as? String).map { String($0.prefix(160)) } ?? UUID().uuidString
            let raw = body["request"] as? [String: Any] ?? [:]
            guard JSONSerialization.isValidJSONObject(raw),
                  let encoded = try? JSONSerialization.data(withJSONObject: raw),
                  encoded.count <= 262_144 else {
                sendBridgeResult(requestID: requestID, result: nil, error: "Invalid AI request")
                return
            }
            switch AgentPluginAIRequestValidator.request(from: raw) {
            case .failure(let error):
                sendBridgeResult(requestID: requestID, result: nil, error: error.localizedDescription)
            case .success(let request):
                // 并发闸。超了就当场拒，不排队：排队只会把一堆过时的生成
                // 请求攞到后面才发出去，用户已经不想要那个结果了。
                // 图片生成走的是另一条路，不受这道闸管。
                guard runningAIRequests.count < AgentPluginAIRequest.maximumConcurrentRequests else {
                    sendBridgeResult(
                        requestID: requestID,
                        result: nil,
                        error: AgentPluginAIError.tooManyConcurrentRequests.localizedDescription
                    )
                    return
                }
                let task = Task { @MainActor [weak self] in
                    guard let self, let appState = self.appState else { return }
                    do {
                        // 有 streamID 就把增量回推给页面，让它一边等一边显示。
                        // 页面自己生成这个 id，宿主只负责原样带回。
                        let streamID = request.streamID
                        let result = try await appState.runPluginAICompletion(
                            pluginID: self.destination.pluginID,
                            request: request,
                            onDelta: streamID.map { id in
                                { [weak self] delta in
                                    Task { @MainActor in self?.sendAIDelta(streamID: id, delta: delta) }
                                }
                            },
                            onReasoning: streamID.map { id in
                                { [weak self] delta in
                                    Task { @MainActor in self?.sendAIReasoning(streamID: id, delta: delta) }
                                }
                            }
                        )
                        self.finishAIRequest(requestID: requestID)
                        self.sendBridgeResult(
                            requestID: requestID,
                            result: [
                                "text": result.text,
                                "model": result.model,
                                "providerID": result.providerID,
                                // 恒在，空数组表示模型选择用正文回答。页面据此
                                // 回落到自己的文本解析，而不是当成失败。
                                "toolCalls": result.toolCalls.map(\.jsonObject),
                            ],
                            error: nil
                        )
                    } catch {
                        self.finishAIRequest(requestID: requestID)
                        let message = error is CancellationError
                            ? AgentPluginAIError.cancelled.localizedDescription
                            : error.localizedDescription
                        self.sendBridgeResult(requestID: requestID, result: nil, error: message)
                    }
                }
                runningAIRequests[requestID] = task
                if let streamID = request.streamID {
                    aiRequestIDsByStreamID[streamID] = requestID
                }
            }
        }

        /// 页面按停止。只认 streamID：宿主自己那个 requestID 从来不出桥，
        /// 页面手里没有它。取消后对应的 complete() 以「已取消」reject，
        /// 迟到的增量也不会再发了。
        private func cancelAICompletion(_ body: [String: Any]) {
            let requestID = (body["requestID"] as? String).map { String($0.prefix(160)) } ?? UUID().uuidString
            let streamID = String((body["streamID"] as? String ?? "").prefix(160))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !streamID.isEmpty, let target = aiRequestIDsByStreamID[streamID] else {
                sendBridgeResult(requestID: requestID, result: ["cancelled": false], error: nil)
                return
            }
            runningAIRequests[target]?.cancel()
            sendBridgeResult(requestID: requestID, result: ["cancelled": true], error: nil)
        }

        private func finishAIRequest(requestID: String) {
            runningAIRequests[requestID] = nil
            for (streamID, owner) in aiRequestIDsByStreamID where owner == requestID {
                aiRequestIDsByStreamID[streamID] = nil
            }
        }

        /// 页面真正拆卸时把在跑的全停掉。
        func cancelAllAIRequests() {
            for task in runningAIRequests.values { task.cancel() }
            runningAIRequests.removeAll()
            aiRequestIDsByStreamID.removeAll()
        }

        private func runAIImageGeneration(_ body: [String: Any]) {
            let requestID = (body["requestID"] as? String).map { String($0.prefix(160)) } ?? UUID().uuidString
            let raw = body["request"] as? [String: Any] ?? [:]
            guard JSONSerialization.isValidJSONObject(raw),
                  let encoded = try? JSONSerialization.data(withJSONObject: raw),
                  encoded.count <= 65_536 else {
                sendBridgeResult(requestID: requestID, result: nil, error: "Invalid image request")
                return
            }
            switch AgentPluginImageRequestValidator.request(from: raw) {
            case .failure(let error):
                sendBridgeResult(requestID: requestID, result: nil, error: error.localizedDescription)
            case .success(let request):
                Task { @MainActor [weak self] in
                    guard let self, let appState = self.appState else { return }
                    do {
                        let result = try await appState.runPluginImageGeneration(
                            pluginID: self.destination.pluginID,
                            request: request
                        )
                        self.sendBridgeResult(
                            requestID: requestID,
                            result: [
                                "mediaURL": result.mediaURL,
                                "filePath": result.filePath,
                                "model": result.model,
                                "providerID": result.providerID,
                            ],
                            error: nil
                        )
                    } catch {
                        self.sendBridgeResult(requestID: requestID, result: nil, error: error.localizedDescription)
                    }
                }
            }
        }

        /// 思考增量。和正文分开一条事件，页面要把它显示成「思考」而不是结果。
        ///
        /// 结构化生成的头十几秒正文一个字都没有，页面除了转圈没有别的可显示。
        /// 推理模型这段时间一直在输出思考文本，露出来等待就有了内容。
        private func sendAIReasoning(streamID: String, delta: String) {
            let detail: [String: Any] = ["streamID": streamID, "delta": String(delta.prefix(4_000))]
            guard let webView,
                  JSONSerialization.isValidJSONObject(detail),
                  let data = try? JSONSerialization.data(withJSONObject: detail),
                  let json = String(data: data, encoding: .utf8) else {
                return
            }
            webView.evaluateJavaScript(
                "window.dispatchEvent(new CustomEvent('willdeep:ai-reasoning', {detail: \(json)}));"
            )
        }

        /// 流式增量。和 bridge-result 分开一条事件，避免页面把中间态当成结果。
        /// 单条增量截断，防止一次极长的 delta 把注入的 JS 撑爆。
        private func sendAIDelta(streamID: String, delta: String) {
            let detail: [String: Any] = ["streamID": streamID, "delta": String(delta.prefix(4_000))]
            guard let webView,
                  JSONSerialization.isValidJSONObject(detail),
                  let data = try? JSONSerialization.data(withJSONObject: detail),
                  let json = String(data: data, encoding: .utf8) else {
                return
            }
            webView.evaluateJavaScript(
                "window.dispatchEvent(new CustomEvent('willdeep:ai-delta', {detail: \(json)}));"
            )
        }

        // MARK: 工作区只读通道

        private func handleFileRequest(type: String, body: [String: Any]) {
            let requestID = (body["requestID"] as? String).map { String($0.prefix(160)) } ?? UUID().uuidString
            guard AgentPluginRegistry.shared.hasPermission(
                .workspaceRead,
                pluginID: destination.pluginID
            ) else {
                sendBridgeResult(
                    requestID: requestID,
                    result: nil,
                    error: AgentPluginCapabilityError
                        .permissionDenied(AgentPluginPermission.workspaceRead.rawValue)
                        .localizedDescription
                )
                return
            }
            let path = String((body["path"] as? String ?? "").prefix(4_096))
            let query = String((body["query"] as? String ?? "").prefix(512))
            let isRegex = body["regex"] as? Bool ?? false
            let rawLimit = body["limit"] as? Int
            Task { @MainActor [weak self] in
                guard let self, let appState = self.appState else { return }
                let roots = appState.pluginAccessibleWorkspaceRoots
                guard !roots.isEmpty else {
                    self.sendBridgeResult(
                        requestID: requestID,
                        result: nil,
                        error: AgentPluginCapabilityError.noWorkspace.localizedDescription
                    )
                    return
                }
                // 目录遍历与搜索会打磁盘，别占着主线程。
                let outcome: Result<[String: Any], Error> = await Task.detached(priority: .userInitiated) {
                    do {
                        switch type {
                        case "fsList":
                            return .success(try AgentPluginFileAccess.list(path: path, roots: roots))
                        case "fsRead":
                            return .success(try AgentPluginFileAccess.read(path: path, roots: roots))
                        default:
                            return .success(try AgentPluginFileAccess.search(
                                query: query,
                                path: path,
                                isRegularExpression: isRegex,
                                limit: (rawLimit ?? 0) > 0 ? rawLimit : nil,
                                roots: roots
                            ))
                        }
                    } catch {
                        return .failure(error)
                    }
                }.value
                switch outcome {
                case .success(let result):
                    self.sendBridgeResult(requestID: requestID, result: result, error: nil)
                case .failure(let error):
                    self.sendBridgeResult(requestID: requestID, result: nil, error: error.localizedDescription)
                }
            }
        }

        // MARK: 插件自己的存储

        private func handleStorageRequest(type: String, body: [String: Any]) {
            let requestID = (body["requestID"] as? String).map { String($0.prefix(160)) } ?? UUID().uuidString
            let pluginID = destination.pluginID
            let key = String((body["key"] as? String ?? "").prefix(AgentPluginStorageStore.maximumKeyLength))
            let value = body["value"]
            do {
                switch type {
                case "storageGet":
                    let stored = AgentPluginStorageStore.value(forKey: key, pluginID: pluginID)
                    sendBridgeResult(requestID: requestID, result: ["value": stored ?? NSNull()], error: nil)
                case "storageSet":
                    guard let value else { throw AgentPluginCapabilityError.invalidArgument("value") }
                    try AgentPluginStorageStore.setValue(value, forKey: key, pluginID: pluginID)
                    sendBridgeResult(requestID: requestID, result: ["ok": true], error: nil)
                case "storageRemove":
                    try AgentPluginStorageStore.removeValue(forKey: key, pluginID: pluginID)
                    sendBridgeResult(requestID: requestID, result: ["ok": true], error: nil)
                default:
                    sendBridgeResult(
                        requestID: requestID,
                        result: ["keys": AgentPluginStorageStore.keys(pluginID: pluginID)],
                        error: nil
                    )
                }
            } catch {
                sendBridgeResult(requestID: requestID, result: nil, error: error.localizedDescription)
            }
        }

        // MARK: 宿主事件

        private func handleEventSubscription(_ body: [String: Any]) {
            let requestID = (body["requestID"] as? String).map { String($0.prefix(160)) } ?? UUID().uuidString
            guard let name = body["name"] as? String,
                  let event = AgentPluginHostEvent.named(name) else {
                sendBridgeResult(
                    requestID: requestID,
                    result: nil,
                    error: AgentPluginCapabilityError.invalidArgument("name").localizedDescription
                )
                return
            }
            guard AgentPluginRegistry.shared.hasPermission(
                event.requiredPermission,
                pluginID: destination.pluginID
            ) else {
                sendBridgeResult(
                    requestID: requestID,
                    result: nil,
                    error: AgentPluginCapabilityError
                        .permissionDenied(event.requiredPermission.rawValue)
                        .localizedDescription
                )
                return
            }
            subscribedHostEvents.insert(event)
            startHostEventObservationIfNeeded()
            sendBridgeResult(requestID: requestID, result: ["subscribed": event.rawValue], error: nil)
        }

        /// 第一次有人订阅时才挂观察者。没插件关心的时候，宿主一个
        /// publisher 都不订。
        func startHostEventObservationIfNeeded() {
            guard hostEventSubscriptions.isEmpty, let appState else { return }
            lastPublishedSessionID = appState.activeAgentSessionID
            lastPublishedResponding = appState.isAgentResponding
            // objectWillChange 是 AppState 唯一一个稳定的「有东西变了」信号；
            // 真正的去重在 publishHostEventsIfChanged 里按值比对，所以这里
            // 收到多少次无所谓。
            appState.objectWillChange
                .receive(on: DispatchQueue.main)
                .sink { [weak self] _ in
                    // objectWillChange 在写入之前发，读值要等这一拍过去。
                    DispatchQueue.main.async { self?.publishHostEventsIfChanged() }
                }
                .store(in: &hostEventSubscriptions)
        }

        private func publishHostEventsIfChanged() {
            guard let appState, !subscribedHostEvents.isEmpty else { return }
            let sessionID = appState.activeAgentSessionID
            if sessionID != lastPublishedSessionID {
                lastPublishedSessionID = sessionID
                lastPublishedResponding = appState.isAgentResponding
                sendHostEvent(.sessionChanged, payload: [
                    "sessionID": sessionID?.uuidString ?? NSNull(),
                ])
                sendHostEvent(.workspaceChanged, payload: [
                    "workspaceRoot": appState.activeRuntime?.workspaceRootPath ?? NSNull(),
                ])
                return
            }
            let responding = appState.isAgentResponding
            if responding != lastPublishedResponding {
                lastPublishedResponding = responding
                sendHostEvent(responding ? .turnStarted : .turnFinished, payload: [
                    "sessionID": sessionID?.uuidString ?? NSNull(),
                ])
            }
        }

        private func sendHostEvent(_ event: AgentPluginHostEvent, payload: [String: Any]) {
            guard subscribedHostEvents.contains(event),
                  AgentPluginRegistry.shared.hasPermission(
                      event.requiredPermission,
                      pluginID: destination.pluginID
                  ),
                  let webView else { return }
            let detail: [String: Any] = ["name": event.rawValue, "payload": payload]
            guard JSONSerialization.isValidJSONObject(detail),
                  let data = try? JSONSerialization.data(withJSONObject: detail),
                  let json = String(data: data, encoding: .utf8) else { return }
            webView.evaluateJavaScript(
                "window.dispatchEvent(new CustomEvent('willdeep:host-event', {detail: \(json)}));"
            )
        }

        // MARK: 写文件 / 跑命令 / 代发网络 / 剪贴板与通知

        private func handleFileWrite(_ body: [String: Any]) {
            let requestID = (body["requestID"] as? String).map { String($0.prefix(160)) } ?? UUID().uuidString
            let path = String((body["path"] as? String ?? "").prefix(4_096))
            let text = body["text"] as? String ?? ""
            let pluginID = destination.pluginID
            Task { @MainActor [weak self] in
                guard let self, let appState = self.appState else { return }
                do {
                    let result = try appState.pluginWriteWorkspaceFile(
                        path: path,
                        text: text,
                        pluginID: pluginID
                    )
                    self.sendBridgeResult(requestID: requestID, result: result, error: nil)
                } catch {
                    self.sendBridgeResult(requestID: requestID, result: nil, error: error.localizedDescription)
                }
            }
        }

        private func handleFilePatch(_ body: [String: Any]) {
            let requestID = (body["requestID"] as? String).map { String($0.prefix(160)) } ?? UUID().uuidString
            let path = String((body["path"] as? String ?? "").prefix(4_096))
            let oldString = body["oldString"] as? String ?? ""
            let newString = body["newString"] as? String ?? ""
            let replaceAll = body["replaceAll"] as? Bool ?? false
            let pluginID = destination.pluginID
            Task { @MainActor [weak self] in
                guard let self, let appState = self.appState else { return }
                do {
                    let result = try appState.pluginPatchWorkspaceFile(
                        path: path,
                        oldString: oldString,
                        newString: newString,
                        replaceAll: replaceAll,
                        pluginID: pluginID
                    )
                    self.sendBridgeResult(requestID: requestID, result: result, error: nil)
                } catch {
                    self.sendBridgeResult(requestID: requestID, result: nil, error: error.localizedDescription)
                }
            }
        }

        private func handleProcessRun(_ body: [String: Any]) {
            let requestID = (body["requestID"] as? String).map { String($0.prefix(160)) } ?? UUID().uuidString
            let command = String((body["command"] as? String ?? "").prefix(4_096))
            let pluginID = destination.pluginID
            Task { @MainActor [weak self] in
                guard let self, let appState = self.appState else { return }
                do {
                    let result = try await appState.pluginRunCommand(command, pluginID: pluginID)
                    self.sendBridgeResult(requestID: requestID, result: result, error: nil)
                } catch {
                    self.sendBridgeResult(requestID: requestID, result: nil, error: error.localizedDescription)
                }
            }
        }

        private func handleNetworkFetch(_ body: [String: Any]) {
            let requestID = (body["requestID"] as? String).map { String($0.prefix(160)) } ?? UUID().uuidString
            let url = String((body["url"] as? String ?? "").prefix(4_096))
            let method = String((body["method"] as? String ?? "GET").prefix(16))
            let headers = (body["headers"] as? [String: String]) ?? [:]
            let payload = body["body"] as? String
            let pluginID = destination.pluginID
            Task { @MainActor [weak self] in
                guard let self, let appState = self.appState else { return }
                do {
                    let result = try await appState.pluginFetch(
                        url: url,
                        method: method,
                        headers: headers,
                        body: payload,
                        pluginID: pluginID
                    )
                    self.sendBridgeResult(requestID: requestID, result: result, error: nil)
                } catch {
                    self.sendBridgeResult(requestID: requestID, result: nil, error: error.localizedDescription)
                }
            }
        }

        private func handleDeviceRequest(type: String, body: [String: Any]) {
            let requestID = (body["requestID"] as? String).map { String($0.prefix(160)) } ?? UUID().uuidString
            let pluginID = destination.pluginID
            let text = String((body["text"] as? String ?? "").prefix(120_000))
            let title = String((body["title"] as? String ?? "").prefix(400))
            let notificationBody = String((body["body"] as? String ?? "").prefix(2_000))
            Task { @MainActor [weak self] in
                guard let self, let appState = self.appState else { return }
                do {
                    if type == "clipboardWrite" {
                        try appState.pluginWriteClipboard(text, pluginID: pluginID)
                    } else {
                        try appState.pluginPostNotification(
                            title: title,
                            body: notificationBody,
                            pluginID: pluginID
                        )
                    }
                    self.sendBridgeResult(requestID: requestID, result: ["ok": true], error: nil)
                } catch {
                    self.sendBridgeResult(requestID: requestID, result: nil, error: error.localizedDescription)
                }
            }
        }

        // MARK: 把活交给 Agent

        private func handleChatRequest(type: String, body: [String: Any]) {
            let requestID = (body["requestID"] as? String).map { String($0.prefix(160)) } ?? UUID().uuidString
            let text = String((body["text"] as? String ?? "").prefix(AppState.pluginChatMaximumLength + 1))
            let pluginID = destination.pluginID
            Task { @MainActor [weak self] in
                guard let self, let appState = self.appState else { return }
                do {
                    let delivered = type == "chatInsert"
                        ? try appState.pluginPrefillAgentInput(text, pluginID: pluginID)
                        : try appState.pluginSendAgentMessage(text, pluginID: pluginID)
                    self.sendBridgeResult(requestID: requestID, result: ["ok": delivered], error: nil)
                } catch {
                    self.sendBridgeResult(requestID: requestID, result: nil, error: error.localizedDescription)
                }
            }
        }

        private func sendBridgeResult(requestID: String, result: [String: Any]?, error: String?) {
            var detail: [String: Any] = ["requestID": requestID]
            if let result { detail["result"] = result }
            if let error { detail["error"] = String(error.prefix(2_000)) }
            guard let webView,
                  JSONSerialization.isValidJSONObject(detail),
                  let data = try? JSONSerialization.data(withJSONObject: detail),
                  let json = String(data: data, encoding: .utf8) else {
                return
            }
            webView.evaluateJavaScript(
                "window.dispatchEvent(new CustomEvent('willdeep:bridge-result', {detail: \(json)}));"
            )
        }

        private func handleMCPMessage(_ rawMessage: Any?) {
            guard destination.mainPage.runtime == .mcpApp,
                  let message = rawMessage as? [String: Any],
                  JSONSerialization.isValidJSONObject(message),
                  let encoded = try? JSONSerialization.data(withJSONObject: message),
                  encoded.count <= 65_536,
                  message["jsonrpc"] as? String == "2.0",
                  let method = message["method"] as? String,
                  method.count <= 160 else { return }

            let requestID = validRPCID(message["id"])
            switch method {
            case "ui/initialize":
                guard let requestID else { return }
                mcpAppInitialized = false
                sendMCPResult(
                    id: requestID,
                    result: [
                        "protocolVersion": "2026-01-26",
                        "hostInfo": ["name": "WillDeep", "version": appVersion],
                        "hostCapabilities": [
                            "serverTools": [:],
                            "serverResources": [:],
                        ],
                        "hostContext": hostContextObject,
                    ]
                )
            case "ui/notifications/initialized":
                mcpAppInitialized = true
                pushContext()
            case "ping":
                if let requestID { sendMCPResult(id: requestID, result: [:]) }
            case "tools/call":
                guard mcpAppInitialized, let requestID else {
                    sendMCPErrorIfPossible(id: requestID, code: -32002, message: "MCP App is not initialized")
                    return
                }
                callMCPAppTool(message: message, requestID: requestID)
            case "resources/read":
                guard mcpAppInitialized, let requestID else {
                    sendMCPErrorIfPossible(id: requestID, code: -32002, message: "MCP App is not initialized")
                    return
                }
                readMCPAppResource(message: message, requestID: requestID)
            case "notifications/message", "ui/notifications/size-changed":
                break
            default:
                sendMCPErrorIfPossible(id: requestID, code: -32601, message: "Unsupported MCP App method: \(method)")
            }
        }

        private func callMCPAppTool(message: [String: Any], requestID: Any) {
            guard let params = message["params"] as? [String: Any],
                  let toolName = params["name"] as? String,
                  toolName.count <= 160,
                  let serverName = destination.mainPage.server,
                  let command = AgentPluginRegistry.shared.commands(for: destination.pluginID).first(where: {
                      $0.handler.type == .mcpTool
                        && $0.handler.server == serverName
                        && $0.handler.tool == toolName
                  }) else {
                sendMCPErrorIfPossible(id: requestID, code: -32602, message: "Tool is not declared for this MCP App")
                return
            }
            let rawArguments = params["arguments"] as? [String: Any] ?? [:]
            guard rawArguments.count <= 64,
                  JSONSerialization.isValidJSONObject(rawArguments),
                  let encoded = try? JSONSerialization.data(withJSONObject: rawArguments),
                  encoded.count <= 65_536 else {
                sendMCPErrorIfPossible(id: requestID, code: -32602, message: "Invalid tool arguments")
                return
            }
            Task { @MainActor [weak self] in
                guard let self, let appState = self.appState else { return }
                do {
                    let result = try await AgentPluginCommandExecutor.executeJSON(
                        pluginID: self.destination.pluginID,
                        commandID: command.id,
                        arguments: rawArguments,
                        destinationID: self.destination.qualifiedID,
                        appState: appState
                    )
                    self.sendMCPResult(id: requestID, result: self.jsonValue(from: result) ?? [:])
                } catch {
                    self.sendMCPErrorIfPossible(id: requestID, code: -32000, message: error.localizedDescription)
                }
            }
        }

        private func readMCPAppResource(message: [String: Any], requestID: Any) {
            guard let params = message["params"] as? [String: Any],
                  let uri = params["uri"] as? String,
                  !uri.isEmpty, uri.count <= 2_048,
                  let serverName = destination.mainPage.server else {
                sendMCPErrorIfPossible(id: requestID, code: -32602, message: "Invalid resource URI")
                return
            }
            Task { @MainActor [weak self] in
                guard let self else { return }
                do {
                    let result = try await AgentMCPBridge.readPluginResource(
                        pluginID: self.destination.pluginID,
                        serverName: serverName,
                        uri: uri
                    )
                    self.sendMCPResult(id: requestID, result: self.jsonValue(from: result) ?? [:])
                } catch {
                    self.sendMCPErrorIfPossible(id: requestID, code: -32000, message: error.localizedDescription)
                }
            }
        }

        private var hostContextObject: [String: Any] {
            var context: [String: Any] = [
                "destinationID": destinationContext.destinationID,
                "locale": destinationContext.locale,
                "colorScheme": destinationContext.colorScheme,
            ]
            context["selectedItemID"] = destinationContext.selectedItemID
            context["workspaceReference"] = destinationContext.workspaceReference
            context["sessionReference"] = destinationContext.sessionReference
            return [
                "theme": destinationContext.colorScheme,
                "locale": destinationContext.locale,
                "displayMode": "fullscreen",
                "availableDisplayModes": ["fullscreen"],
                "willdeep": context,
            ]
        }

        private var appVersion: String {
            (Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String) ?? "0.0.0"
        }

        private func validRPCID(_ value: Any?) -> Any? {
            switch value {
            case let value as String where value.count <= 160:
                return value
            case let value as NSNumber:
                return value
            default:
                return nil
            }
        }

        private func jsonValue(from raw: String?) -> Any? {
            guard let raw, let data = raw.data(using: .utf8) else { return nil }
            return try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])
        }

        private func sendMCPResult(id: Any, result: Any) {
            sendMCPMessage(["jsonrpc": "2.0", "id": id, "result": result])
        }

        private func sendMCPErrorIfPossible(id: Any?, code: Int, message: String) {
            guard let id else { return }
            sendMCPMessage([
                "jsonrpc": "2.0",
                "id": id,
                "error": ["code": code, "message": String(message.prefix(2_000))],
            ])
        }

        fileprivate func sendMCPRequest(method: String, params: [String: Any]) {
            guard destination.mainPage.runtime == .mcpApp, mcpAppInitialized else { return }
            let id = nextHostRequestID
            nextHostRequestID += 1
            sendMCPMessage(["jsonrpc": "2.0", "id": id, "method": method, "params": params])
        }

        private func sendMCPMessage(_ message: [String: Any]) {
            guard let webView,
                  JSONSerialization.isValidJSONObject(message),
                  let data = try? JSONSerialization.data(withJSONObject: message),
                  data.count <= 65_536,
                  let json = String(data: data, encoding: .utf8) else { return }
            webView.evaluateJavaScript("window.__willdeepDeliverMCPMessage && window.__willdeepDeliverMCPMessage(\(json));")
        }

        private func sendCommandResult(requestID: String, result: String?, error: String?) {
            guard let webView else { return }
            let payload: [String: Any?] = [
                "requestID": requestID,
                "result": result,
                "error": error,
            ]
            guard let data = try? JSONSerialization.data(
                withJSONObject: payload.compactMapValues { $0 },
                options: []
            ), let json = String(data: data, encoding: .utf8) else { return }
            webView.evaluateJavaScript(
                "window.dispatchEvent(new CustomEvent('willdeep:command-result', {detail: \(json)}));"
            )
        }
    }
}

/// 把 `willdeep-plugin://bundle/...` 的请求路径解析成插件包内的真实文件。
/// 目录请求（含根路径）落到该目录下的 `index.html`，否则请求 baseURL 只会得到一张白页。
enum AgentPluginWebResourceResolver {
    static let directoryIndexFile = "index.html"

    /// 把入口 HTML 所在目录映射成 `willdeep-plugin://bundle/<相对目录>/` 的
    /// 文档 baseURL。两侧都先走 `canonicalFileURL`（realpath）再比前缀：
    /// 入口目录来自 `safeResourceURL`，天生是 realpath 形态；包根若不做同样
    /// 的规范化，路径里只要有一段软链接前缀就会对不上，静默返回 nil，页面里
    /// 全部相对子资源随之无声失败——这正是插件页"只剩内联内容"白页的形态。
    static func schemeBaseURL(forEntryDirectory localBaseURL: URL?, packageURL: URL) -> URL? {
        guard let localBaseURL else { return nil }
        let packagePath = AgentPluginPackageLoader.canonicalFileURL(packageURL).path
        let localPath = AgentPluginPackageLoader.canonicalFileURL(localBaseURL).path
        let prefix = packagePath.hasSuffix("/") ? packagePath : packagePath + "/"
        guard localPath == packagePath || localPath.hasPrefix(prefix) else { return nil }
        let relative = localPath == packagePath ? "" : String(localPath.dropFirst(prefix.count))
        let encoded = relative
            .split(separator: "/", omittingEmptySubsequences: true)
            .map { String($0).addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? String($0) }
            .joined(separator: "/")
        return URL(string: "\(AgentPluginSchemeHandler.scheme)://\(AgentPluginSchemeHandler.host)/\(encoded)/")
    }

    static func fileURL(forRequestPath path: String, packageURL: URL) throws -> URL {
        let decoded = path.removingPercentEncoding ?? path
        let relativePath = decoded.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        guard !relativePath.isEmpty else {
            return try AgentPluginPackageLoader.safeResourceURL(
                relativePath: directoryIndexFile,
                packageURL: packageURL
            )
        }
        let resourceURL = try AgentPluginPackageLoader.safeResourceURL(
            relativePath: relativePath,
            packageURL: packageURL
        )
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: resourceURL.path, isDirectory: &isDirectory),
              isDirectory.boolValue else {
            return resourceURL
        }
        return try AgentPluginPackageLoader.safeResourceURL(
            relativePath: relativePath + "/" + directoryIndexFile,
            packageURL: packageURL
        )
    }
}

private final class AgentPluginSchemeHandler: NSObject, WKURLSchemeHandler {
    nonisolated static let scheme = "willdeep-plugin"
    nonisolated static let host = "bundle"
    private let packageURLLock = NSLock()
    private var lockedPackageURL: URL
    private var lockedPluginID: String
    private let maximumResourceBytes = 8 * 1024 * 1024
    private let maximumMediaBytes = 32 * 1024 * 1024

    /// 生成媒体的落盘目录是按插件分的（plugin-data/<pluginID>/generated-images），
    /// 所以这个值钉死在创建时刻就等于把图钉在了创建时那个插件上。视图身份
    /// 现在跟着目标走，正常路径下不会再出现复用；这里仍然可写，是为了任何
    /// 复用了同一张 WKWebView 的宿主都不会静默去错误的插件目录取图——那种
    /// 失败只在统一日志里留一行，页面上只是一张空框。
    var pluginID: String {
        get {
            packageURLLock.lock()
            defer { packageURLLock.unlock() }
            return lockedPluginID
        }
        set {
            packageURLLock.lock()
            defer { packageURLLock.unlock() }
            lockedPluginID = newValue
        }
    }

    /// 资源根必须跟着 destination 的激活包走。它在 `makeNSView` 时创建，而
    /// 注册表刷新可能把激活包切到另一个副本（内置 ↔ 本地安装同版本并存）；
    /// 若资源根钉死在创建时的副本上，就会出现"入口 HTML 是 A 副本、子资源
    /// 从 B 副本取"的混装，带哈希文件名的产物（Vite dist）整页 404 白掉。
    /// `updateNSView` 每次都回写此值。
    var packageURL: URL {
        get {
            packageURLLock.lock()
            defer { packageURLLock.unlock() }
            return lockedPackageURL
        }
        set {
            packageURLLock.lock()
            defer { packageURLLock.unlock() }
            lockedPackageURL = newValue
        }
    }

    init(packageURL: URL, pluginID: String) {
        self.lockedPackageURL = packageURL
        self.lockedPluginID = pluginID
    }

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        do {
            guard let requestURL = urlSchemeTask.request.url,
                  requestURL.scheme == Self.scheme,
                  requestURL.host == Self.host else {
                throw AgentPluginPackageError.resourceOutsidePackage(urlSchemeTask.request.url?.absoluteString ?? "")
            }
            let isGeneratedMedia = requestURL.path.hasPrefix("/__media__/")
            let resourceURL = try (isGeneratedMedia
                ? AgentPluginGeneratedMediaResolver.fileURL(forRequestPath: requestURL.path, pluginID: pluginID)
                : AgentPluginWebResourceResolver.fileURL(forRequestPath: requestURL.path, packageURL: self.packageURL))
            let values = try resourceURL.resourceValues(forKeys: [.isRegularFileKey, .fileSizeKey])
            guard values.isRegularFile == true,
                  (values.fileSize ?? 0) <= (isGeneratedMedia ? maximumMediaBytes : maximumResourceBytes) else {
                throw AgentPluginPackageError.oversizedManifest(requestURL.path)
            }
            let data = try Data(contentsOf: resourceURL, options: [.mappedIfSafe])
            let mimeType = UTType(filenameExtension: resourceURL.pathExtension)?.preferredMIMEType
                ?? "application/octet-stream"
            let response = URLResponse(
                url: requestURL,
                mimeType: mimeType,
                expectedContentLength: data.count,
                textEncodingName: mimeType.hasPrefix("text/") || mimeType.contains("javascript") ? "utf-8" : nil
            )
            urlSchemeTask.didReceive(response)
            urlSchemeTask.didReceive(data)
            urlSchemeTask.didFinish()
        } catch {
            // 页面那头只知道「这张图挂了」——它的 error 监听器报得出 IMG 和
            // URL，报不出原因。原因只有这里知道，而这里以前一句不说，于是
            // 「插件里看不到图」在日志里只剩一条 resource-error，查不下去。
            pluginPageLog.error(
                "plugin resource failed: plugin=\(self.pluginID, privacy: .public) path=\(urlSchemeTask.request.url?.path ?? "nil", privacy: .public) reason=\(String(describing: error), privacy: .public)"
            )
            urlSchemeTask.didFailWithError(error)
        }
    }

    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}
}

enum AgentPluginGeneratedMediaResolver {
    /// 所有插件数据目录的根（`~/Library/Application Support/WillDeep/plugin-data`）。
    /// 插件 MCP 网关也从这里找插件公布的 `mcp-http.json`。
    nonisolated static var pluginDataRoot: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Application Support", isDirectory: true)
        return base.appendingPathComponent("WillDeep/plugin-data", isDirectory: true)
    }

    static func directory(pluginID: String) throws -> URL {
        guard pluginID.range(of: #"^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$"#, options: .regularExpression) != nil else {
            throw AgentPluginPackageError.resourceOutsidePackage(pluginID)
        }
        return pluginDataRoot
            .appendingPathComponent(pluginID, isDirectory: true)
            .appendingPathComponent("generated-images", isDirectory: true)
    }

    static func fileURL(forRequestPath path: String, pluginID: String) throws -> URL {
        let decoded = path.removingPercentEncoding ?? path
        let filename = String(decoded.dropFirst("/__media__/".count))
        guard !filename.isEmpty, filename == URL(fileURLWithPath: filename).lastPathComponent else {
            throw AgentPluginPackageError.resourceOutsidePackage(path)
        }
        let root = try directory(pluginID: pluginID).standardizedFileURL
        let candidate = root.appendingPathComponent(filename, isDirectory: false).standardizedFileURL
        guard candidate.deletingLastPathComponent() == root else {
            throw AgentPluginPackageError.resourceOutsidePackage(path)
        }
        return candidate
    }
}
