//
//  L10n+Settings.swift
//  WillDeep
//
//  Split out of L10n.swift to keep files under the repository size limit.
//  The Settings window carries roughly a third of the app's user-visible
//  strings, so it moves as one block rather than being sliced by tab.
//

import Foundation

extension L10n {
    enum Settings {
        static let windowTitle = String(localized: "settings.window.title", defaultValue: "Settings")
        static let tabUpdates = String(localized: "settings.tab.updates", defaultValue: "Updates")
        static let tabTypography = String(localized: "settings.tab.typography", defaultValue: "Font")
        static let tabEditing = String(localized: "settings.tab.editing", defaultValue: "Editing")
        static let tabAppearance = String(localized: "settings.tab.appearance", defaultValue: "Format")
        static let tabBackground = String(localized: "settings.tab.background", defaultValue: "Background")
        static let tabWorkspace = String(localized: "settings.tab.workspace", defaultValue: "Workspace")
        static let tabAgent = String(localized: "settings.tab.agent", defaultValue: "AI Providers")
        static let tabSubagents = String(localized: "settings.tab.subagents", defaultValue: "Subagents")
        static let tabSomeIM = String(localized: "settings.tab.some-im", defaultValue: "some.im")
        static let tabReplicate = String(localized: "settings.tab.replicate", defaultValue: "Replicate")
        static let tabMemory = String(localized: "settings.tab.memory", defaultValue: "Memory")
        static let tabRules = String(localized: "settings.tab.rules", defaultValue: "Rules")
        static let tabSkills = String(localized: "settings.tab.skills", defaultValue: "Skills")
        static let tabConnectors = String(localized: "settings.tab.connectors", defaultValue: "Connectors")
        static let tabMcp = String(localized: "settings.tab.mcp", defaultValue: "MCP")
        static let tabTools = String(localized: "settings.tab.tools", defaultValue: "Tools")
        static let tabTerminal = String(localized: "settings.tab.terminal", defaultValue: "Terminal")
        static let tabLocalAgents = String(localized: "settings.tab.local-agents", defaultValue: "Local Agents")
        static let tabRemoteRuntimes = String(localized: "settings.tab.remote-runtimes", defaultValue: "Runtimes")
        static let tabMobileGateway = String(localized: "settings.tab.mobile-gateway", defaultValue: "Mobile Gateway")
        static let tabVoice = String(localized: "settings.tab.voice", defaultValue: "Voice")
        static let agentBarSettings = String(localized: "agent.statusbar.settings", defaultValue: "Settings")
        static let agentBarMobileGateway = String(localized: "agent.statusbar.mobile-gateway", defaultValue: "Mobile Gateway")

        static let groupGeneral = String(localized: "settings.group.general", defaultValue: "General")
        static let groupEditor = String(localized: "settings.group.editor", defaultValue: "Editor")
        static let groupAI = String(localized: "settings.group.ai", defaultValue: "AI Agents")
        static let groupAgentTools = String(localized: "settings.group.agent-tools", defaultValue: "Agent Tools")
        static let groupAccountAndDevices = String(localized: "settings.group.account-and-devices", defaultValue: "Account & Devices")
        static let groupRuntimes = String(localized: "settings.group.runtimes", defaultValue: "Runtimes")
        static let groupIntegrations = String(localized: "settings.group.integrations", defaultValue: "Integrations")
        static let groupTerminal = String(localized: "settings.group.terminal", defaultValue: "Terminal")
        static let groupVoice = String(localized: "settings.group.voice", defaultValue: "Voice")

        static let sectionTypography = String(localized: "settings.section.typography", defaultValue: "Typography")
        static let sectionEditorText = String(localized: "settings.section.editor-text", defaultValue: "Editor Text")
        static let sectionWorkspaceText = String(localized: "settings.section.workspace-text", defaultValue: "Workspace List")
        static let sectionInterfaceSkin = String(localized: "settings.section.interface-skin", defaultValue: "Interface Skin")
        static let interfaceSkinHelp = String(localized: "settings.interface-skin.help", defaultValue: "Choose a full-window skin. Skin changes apply to window chrome, sidebars, panels, selection color, and the recommended editor theme.")
        static let sectionColorStyle = String(localized: "settings.section.color-style", defaultValue: "Color Style")
        static let sectionEditorBackground = String(localized: "settings.section.editor-background", defaultValue: "Editor Background")
        static let sectionWorkspaceWallpaper = String(localized: "settings.section.workspace-wallpaper", defaultValue: "Workspace Wallpaper")
        static let sectionAgentWallpaper = String(localized: "settings.section.agent-wallpaper", defaultValue: "Agent Global Wallpaper")
        static let builtInWallpapers = String(localized: "settings.workspace-wallpaper.built-in", defaultValue: "Built-in Wallpapers")
        static let backgroundChoices = String(localized: "settings.workspace-wallpaper.choices", defaultValue: "Background Choices")
        static let workspaceWallpaperHelp = String(localized: "settings.workspace-wallpaper.help", defaultValue: "Choose the shared wallpaper and image layout here. Agent workspace effects are controlled separately below. WillDeep keeps a private managed copy of custom images.")
        static let workspaceWallpaperInstallFailed = String(localized: "settings.workspace-wallpaper.install-failed", defaultValue: "WillDeep couldn't use that image. Choose a valid image smaller than 64 MB and 80 megapixels.")
        static let sectionEditor = String(localized: "settings.section.editor", defaultValue: "Editor")
        static let sectionSidebar = String(localized: "settings.section.sidebar", defaultValue: "Sidebar")
        static let sectionInspector = String(localized: "settings.section.inspector", defaultValue: "Inspector")
        static let sectionSave = String(localized: "settings.section.save", defaultValue: "Save")
        static let sectionAgentProviders = String(localized: "settings.section.agent-providers", defaultValue: "Agent Providers")
        static let sectionImageUnderstanding = String(localized: "settings.section.image-understanding", defaultValue: "Image Understanding")
        static let sectionLocalModelAcceleration = String(localized: "settings.section.local-model-acceleration", defaultValue: "本地模型加速")
        static let sectionConversationTitle = String(localized: "settings.section.conversation-title", defaultValue: "Conversation Title")
        static let sectionToolApproval = String(localized: "settings.section.tool-approval", defaultValue: "Tool approval")
        static let sectionConcurrency = String(localized: "settings.section.concurrency", defaultValue: "Concurrency")
        static let sectionAgentAppearance = String(localized: "settings.section.agent-appearance", defaultValue: "Appearance")
        static let sectionAgentChatText = String(localized: "settings.section.agent-chat-text", defaultValue: "Agent Chat Text")
        static let sectionSoftwareUpdate = String(localized: "settings.section.software-update", defaultValue: "Software Update")
        static let sectionAgentAlwaysAllow = String(localized: "settings.section.agent-always-allow", defaultValue: "Agent Always Allow")
        static let sectionWebTools = String(localized: "settings.section.web-tools", defaultValue: "Web tools")

        static let toggleShowLineNumbers = String(localized: "settings.toggle.show-line-numbers", defaultValue: "Show Line Numbers")
        static let toggleHighlightCurrentLine = String(localized: "settings.toggle.highlight-current-line", defaultValue: "Highlight Current Line")
        static let toggleGlassEditorBackground = String(localized: "settings.toggle.glass-editor-background", defaultValue: "Glass Editor Background")
        static let toggleAgentWallpaper = String(localized: "settings.toggle.agent-wallpaper", defaultValue: "Use as Agent Global Background")
        static let toggleAgentWallpaperGlass = String(localized: "settings.toggle.agent-wallpaper-glass", defaultValue: "Frosted Glass")
        static let toggleTrimTrailingWhitespace = String(localized: "settings.toggle.trim-trailing-whitespace", defaultValue: "Trim Trailing Whitespace")
        static let toggleEnsureFinalNewline = String(localized: "settings.toggle.ensure-final-newline", defaultValue: "Ensure Final Newline")
        static let toggleAutoApproveSafe = String(localized: "settings.toggle.auto-approve-safe", defaultValue: "AI-approve normal commands")

        static let buttonChoose = String(localized: "settings.button.choose", defaultValue: "Choose…")
        static let buttonClear = String(localized: "settings.button.clear", defaultValue: "Clear")
        static let buttonSave = String(localized: "settings.button.save", defaultValue: "Save")
        static let buttonRevert = String(localized: "settings.button.revert", defaultValue: "Revert")

        static let perProviderConcurrency = String(localized: "settings.per-provider-concurrency", defaultValue: "Per-provider concurrency")
        static let chatBaseFontSize = String(localized: "settings.chat-base-font-size", defaultValue: "Chat base font size")
        static let noAlwaysAllowed = String(localized: "settings.no-always-allowed", defaultValue: "No commands are always allowed.")

        // MARK: Generic appearance/editor labels reused across tabs.
        static let labelFont = String(localized: "settings.label.font", defaultValue: "Font")
        static let labelTheme = String(localized: "settings.label.theme", defaultValue: "Theme")
        static let labelImage = String(localized: "settings.label.image", defaultValue: "Image")
        static let labelImageMode = String(localized: "settings.label.image-mode", defaultValue: "Image Mode")
        static let labelImageSize = String(localized: "settings.label.image-size", defaultValue: "Image Size")
        static let labelImageOpacity = String(localized: "settings.label.image-opacity", defaultValue: "Image Opacity")
        static let labelAgentWallpaperSurfaceOpacity = String(localized: "settings.label.agent-wallpaper-surface-opacity", defaultValue: "Agent Surface Opacity")
        static let labelGlassMaterial = String(localized: "settings.label.glass-material", defaultValue: "Glass Material")
        static let labelGlassStrength = String(localized: "settings.label.glass-strength", defaultValue: "Glass Strength")
        static let labelEditorSurface = String(localized: "settings.label.editor-surface", defaultValue: "Editor Surface")
        static let labelTextSize = String(localized: "settings.label.text-size", defaultValue: "Text Size")
        static let labelLineHeight = String(localized: "settings.label.line-height", defaultValue: "Line Height")
        static let labelInstalledVersion = String(localized: "settings.label.installed-version", defaultValue: "Installed Version")
        static let labelDefaultView = String(localized: "settings.label.default-view", defaultValue: "Default View")
        static let labelViewOrder = String(localized: "settings.label.view-order", defaultValue: "View Order")
        static let noImageSelected = String(localized: "settings.no-image-selected", defaultValue: "No image selected")
        static let noBackground = String(localized: "settings.no-background", defaultValue: "No Background")
        static let chooseBackgroundImageTitle = String(localized: "settings.choose-background-image.title", defaultValue: "Choose Editor Background Image")
        static let chooseWorkspaceWallpaperTitle = String(localized: "settings.choose-workspace-wallpaper.title", defaultValue: "Choose Workspace Wallpaper")
        static let backgroundImageModeFill = String(localized: "settings.background-image-mode.fill", defaultValue: "Fill & Crop")
        static let backgroundImageModeFit = String(localized: "settings.background-image-mode.fit", defaultValue: "Fit")
        static let backgroundImageModeStretch = String(localized: "settings.background-image-mode.stretch", defaultValue: "Stretch")
        static let backgroundImageModeCenter = String(localized: "settings.background-image-mode.center", defaultValue: "Center")
        static let backgroundImageModeTile = String(localized: "settings.background-image-mode.tile", defaultValue: "Tile")
        static let agentWallpaperHelp = String(localized: "settings.agent-wallpaper.help", defaultValue: "Uses the workspace wallpaper selected above throughout the Agent workspace. Adjust the interface surface opacity and optional frosted glass for readability.")
        static let savedStatus = String(localized: "settings.saved-status", defaultValue: "Saved.")
        static let allChangesSaved = String(localized: "settings.all-changes-saved", defaultValue: "All changes saved")
        static let softwareUpdateHelp = String(localized: "settings.software-update.help", defaultValue: "WillDeep checks for signed updates automatically. You can also check now; Sparkle verifies the download before installing it.")
        static func versionAndBuild(_ version: String, _ build: String) -> String {
            let template = String(localized: "settings.software-update.version-and-build", defaultValue: "%@ (Build %@)")
            return String(format: template, version, build)
        }

        enum BuiltInWallpaper {
            static func name(_ id: String) -> String {
                switch id {
                case BuiltInWorkspaceWallpaper.pastelDrift.id:
                    return String(localized: "settings.workspace-wallpaper.name.pastel-drift", defaultValue: "Pastel Drift")
                case BuiltInWorkspaceWallpaper.ringedWorld.id:
                    return String(localized: "settings.workspace-wallpaper.name.ringed-world", defaultValue: "Ringed World")
                case BuiltInWorkspaceWallpaper.skyGarden.id:
                    return String(localized: "settings.workspace-wallpaper.name.sky-garden", defaultValue: "Sky Garden")
                case BuiltInWorkspaceWallpaper.springQipao.id:
                    return String(localized: "settings.workspace-wallpaper.name.spring-qipao", defaultValue: "Spring Qipao")
                case BuiltInWorkspaceWallpaper.glacierMirror.id:
                    return String(localized: "settings.workspace-wallpaper.name.glacier-mirror", defaultValue: "Glacier Mirror")
                case BuiltInWorkspaceWallpaper.emeraldSteppe.id:
                    return String(localized: "settings.workspace-wallpaper.name.emerald-steppe", defaultValue: "Emerald Steppe")
                case BuiltInWorkspaceWallpaper.coralRealm.id:
                    return String(localized: "settings.workspace-wallpaper.name.coral-realm", defaultValue: "Coral Realm")
                case BuiltInWorkspaceWallpaper.auroraSanctuary.id:
                    return String(localized: "settings.workspace-wallpaper.name.aurora-sanctuary", defaultValue: "Aurora Sanctuary")
                default:
                    return id
                }
            }
        }

        enum InterfaceSkin {
            static func name(_ skin: EditorInterfaceSkin) -> String {
                switch skin.id {
                case EditorInterfaceSkin.system.id:
                    return String(localized: "settings.interface-skin.system.name", defaultValue: "System Default")
                case EditorInterfaceSkin.mistForest.id:
                    return String(localized: "settings.interface-skin.mist-forest.name", defaultValue: "Mist Forest")
                case EditorInterfaceSkin.ricePaper.id:
                    return String(localized: "settings.interface-skin.rice-paper.name", defaultValue: "Rice Paper")
                case EditorInterfaceSkin.sciFiRaster.id:
                    return String(localized: "settings.interface-skin.sci-fi-raster.name", defaultValue: "Sci-Fi Raster")
                case EditorInterfaceSkin.midnightSlate.id:
                    return String(localized: "settings.interface-skin.midnight-slate.name", defaultValue: "Midnight Slate")
                case EditorInterfaceSkin.auroraNight.id:
                    return String(localized: "settings.interface-skin.aurora-night.name", defaultValue: "Aurora Night")
                case EditorInterfaceSkin.emberGraphite.id:
                    return String(localized: "settings.interface-skin.ember-graphite.name", defaultValue: "Ember Graphite")
                default:
                    return skin.id
                }
            }

            static func summary(_ skin: EditorInterfaceSkin) -> String {
                switch skin.id {
                case EditorInterfaceSkin.system.id:
                    return String(localized: "settings.interface-skin.system.summary", defaultValue: "Follows macOS with stable native contrast.")
                case EditorInterfaceSkin.mistForest.id:
                    return String(localized: "settings.interface-skin.mist-forest.summary", defaultValue: "Soft green and warm mist for calm long sessions.")
                case EditorInterfaceSkin.ricePaper.id:
                    return String(localized: "settings.interface-skin.rice-paper.summary", defaultValue: "Low-saturation ink and paper tones with a quiet reading feel.")
                case EditorInterfaceSkin.sciFiRaster.id:
                    return String(localized: "settings.interface-skin.sci-fi-raster.summary", defaultValue: "Deep cyan neon with a compact terminal-like atmosphere.")
                case EditorInterfaceSkin.midnightSlate.id:
                    return String(localized: "settings.interface-skin.midnight-slate.summary", defaultValue: "Blue-black depth for longer night coding.")
                case EditorInterfaceSkin.auroraNight.id:
                    return String(localized: "settings.interface-skin.aurora-night.summary", defaultValue: "Dark green-blue with clear aurora accents.")
                case EditorInterfaceSkin.emberGraphite.id:
                    return String(localized: "settings.interface-skin.ember-graphite.summary", defaultValue: "Graphite warmth with ember highlights.")
                default:
                    return skin.id
                }
            }
        }

        enum LearningReview {
            static let section = String(localized: "settings.learning-review.section", defaultValue: "Learning Review")
            static let title = String(localized: "settings.learning-review.title", defaultValue: "Review automatic learning")
            static let description = String(localized: "settings.learning-review.description", defaultValue: "Memory saves, skill candidates, and MCP suggestions discovered at turn end stay here until reviewed.")
            static let empty = String(localized: "settings.learning-review.empty", defaultValue: "No pending learning items.")
            static let copy = String(localized: "settings.learning-review.copy", defaultValue: "Copy details")
            static let copied = String(localized: "settings.learning-review.copied", defaultValue: "Copied")
            static let editSkillDraft = String(localized: "settings.learning-review.edit-skill-draft", defaultValue: "Edit skill draft")
            static let editSkillDraftTitle = String(localized: "settings.learning-review.edit-skill-draft-title", defaultValue: "Edit Skill Draft")
            static let createSkillFromDraft = String(localized: "settings.learning-review.create-skill-from-draft", defaultValue: "Create skill from draft")
            static let configureMCPFromDraft = String(localized: "settings.learning-review.configure-mcp-from-draft", defaultValue: "Configure MCP suggestion")
            static let saveSkillDraft = String(localized: "settings.learning-review.save-skill-draft", defaultValue: "Save Draft")
            static let markReviewed = String(localized: "settings.learning-review.mark-reviewed", defaultValue: "Mark reviewed")
            static let dismiss = String(localized: "settings.learning-review.dismiss", defaultValue: "Dismiss")
            static let clearReviewed = String(localized: "settings.learning-review.clear-reviewed", defaultValue: "Clear reviewed")
            static let decisionPending = String(localized: "settings.learning-review.decision.pending", defaultValue: "Pending")
            static let decisionReviewed = String(localized: "settings.learning-review.decision.reviewed", defaultValue: "Reviewed")
            static let decisionDismissed = String(localized: "settings.learning-review.decision.dismissed", defaultValue: "Dismissed")
            static func pendingCount(_ a1: String) -> String {
                let template = String(localized: "settings.learning-review.pending-count", defaultValue: "%@ pending")
                return String(format: template, a1)
            }
            static func morePending(_ a1: String) -> String {
                let template = String(localized: "settings.learning-review.more-pending", defaultValue: "%@ more pending items hidden")
                return String(format: template, a1)
            }
            static func reviewedDisclosure(_ a1: String) -> String {
                let template = String(localized: "settings.learning-review.reviewed-disclosure", defaultValue: "Reviewed items (%@)")
                return String(format: template, a1)
            }
            static func moreReviewed(_ a1: String) -> String {
                let template = String(localized: "settings.learning-review.more-reviewed", defaultValue: "%@ more reviewed items hidden")
                return String(format: template, a1)
            }
        }

        enum WebTools {
            static let providerLabel = String(localized: "settings.web-tools.provider", defaultValue: "Search Provider")
            static let providerAuto = String(localized: "settings.web-tools.provider.auto", defaultValue: "Auto")
            static let providerExa = String(localized: "settings.web-tools.provider.exa", defaultValue: "Exa")
            static let providerBrave = String(localized: "settings.web-tools.provider.brave", defaultValue: "Brave")
            static let exaKeyLabel = String(localized: "settings.web-tools.exa-api-key", defaultValue: "Exa API Key")
            static let braveKeyLabel = String(localized: "settings.web-tools.brave-api-key", defaultValue: "Brave Search API Key")
            static let description = String(localized: "settings.web-tools.description", defaultValue: "Enables the built-in web_search tool. Auto tries local Exa first, then Brave; if both keys are empty and some.im is signed in, it uses some.im managed search. API keys are stored in the macOS Keychain. web_fetch needs no key and asks for approval per domain.")

            static func providerName(_ provider: AgentWebSearchProvider) -> String {
                switch provider {
                case .auto:
                    return providerAuto
                case .exa:
                    return providerExa
                case .brave:
                    return providerBrave
                }
            }
        }

        enum SomeIM {
            static let accountSection = String(localized: "settings.some-im.account-section", defaultValue: "some.im Account")
            static let emailLabel = String(localized: "settings.some-im.email", defaultValue: "Email")
            static let emailCodeLabel = String(localized: "settings.some-im.email-code", defaultValue: "Verification Code")
            static let sendCode = String(localized: "settings.some-im.send-code", defaultValue: "Send Code")
            static let sendingCode = String(localized: "settings.some-im.sending-code", defaultValue: "Sending...")
            static let verifyCode = String(localized: "settings.some-im.verify-code", defaultValue: "Verify & Connect")
            static let verifyingCode = String(localized: "settings.some-im.verifying-code", defaultValue: "Connecting...")
            static let refreshBalance = String(localized: "settings.some-im.refresh-balance", defaultValue: "Refresh Balance")
            static let openSomeIM = String(localized: "settings.some-im.open", defaultValue: "Open some.im")
            static let logout = String(localized: "settings.some-im.logout", defaultValue: "Sign Out")
            static let logoutConfirmTitle = String(localized: "settings.some-im.logout-confirm-title", defaultValue: "Sign out of some.im?")
            static let logoutConfirmMessage = String(localized: "settings.some-im.logout-confirm-message", defaultValue: "This signs out every app on this Mac that shares this some.im login.")
            static let loggedOut = String(localized: "settings.some-im.logged-out", defaultValue: "Signed out of some.im.")
            static let logoutCancel = String(localized: "settings.some-im.logout-cancel", defaultValue: "Cancel")
            static let accountNotConnected = String(localized: "settings.some-im.account-not-connected", defaultValue: "Not connected")
            static let accountConnected = String(localized: "settings.some-im.account-connected", defaultValue: "Connected")
            static let creditsLabel = String(localized: "settings.some-im.credits", defaultValue: "Credits")
            static let defaultModelLabel = String(localized: "settings.some-im.default-model", defaultValue: "Default Model")
            static let newTabDefaultSection = String(localized: "settings.some-im.new-tab-default-section", defaultValue: "New Tab Default")
            static let newTabDefaultLabel = String(localized: "settings.some-im.new-tab-default-label", defaultValue: "Default model mode")
            static let newTabDefaultManaged = String(localized: "settings.some-im.new-tab-default-managed", defaultValue: "Managed Routing")
            static let newTabDefaultModel = String(localized: "settings.some-im.new-tab-default-model", defaultValue: "DeepSeek V4 Flash")
            static let newTabDefaultManagedHelp = String(localized: "settings.some-im.new-tab-default-managed-help", defaultValue: "New tabs use Managed Routing. You can still choose a concrete model in the composer for the current conversation.")
            static let newTabDefaultModelHelp = String(localized: "settings.some-im.new-tab-default-model-help", defaultValue: "New tabs use some.im's deepseek-v4-flash and let you choose another concrete model in the composer.")
            static let newTabDefaultLoginRequired = String(localized: "settings.some-im.new-tab-default-login-required", defaultValue: "Sign in to some.im to configure the default model mode for new tabs.")
            static let codeSent = String(localized: "settings.some-im.code-sent", defaultValue: "Verification code sent.")
            static let connected = String(localized: "settings.some-im.connected", defaultValue: "some.im connected.")
            static let browserLoginSection = String(localized: "settings.some-im.browser-login-section", defaultValue: "Browser Login")
            static let browserLoginDescription = String(localized: "settings.some-im.browser-login-description", defaultValue: "WillDeep prepares a secure some.im sign-in request automatically. Open it in your browser, sign in, then return to WillDeep when some.im says you can continue.")
            static let browserLoginPlaceholderTitle = String(localized: "settings.some-im.browser-login-placeholder-title", defaultValue: "Ready for browser sign-in")
            static let browserLoginPlaceholderDescription = String(localized: "settings.some-im.browser-login-placeholder-description", defaultValue: "Open some.im in your browser to finish signing in. WillDeep will keep waiting here for the account connection.")
            static let browserLoginQRCodeAccessibilityLabel = String(localized: "settings.some-im.browser-login-qr.accessibility-label", defaultValue: "some.im browser login QR code")
            static let browserLoginQRCodeUnavailable = String(localized: "settings.some-im.browser-login-qr.unavailable", defaultValue: "QR code unavailable")
            static let browserLoginCodeLabel = String(localized: "settings.some-im.browser-login-code", defaultValue: "Random Code")
            static let generateBrowserLoginLink = String(localized: "settings.some-im.generate-browser-login-link", defaultValue: "Generate Link")
            static let openBrowserLoginLink = String(localized: "settings.some-im.open-browser-login-link", defaultValue: "Open in Browser")
            static let copyBrowserLoginLink = String(localized: "settings.some-im.copy-browser-login-link", defaultValue: "Copy Link")
            static let copyBrowserLoginCode = String(localized: "settings.some-im.copy-browser-login-code", defaultValue: "Copy Code")
            static let browserLoginReady = String(localized: "settings.some-im.browser-login-ready", defaultValue: "Browser sign-in is ready.")
            static let browserLoginWaiting = String(localized: "settings.some-im.browser-login-waiting", defaultValue: "Waiting for browser sign-in...")
            static let browserLoginConnected = String(localized: "settings.some-im.browser-login-connected", defaultValue: "some.im account connected.")
            static let browserLoginExpired = String(localized: "settings.some-im.browser-login-expired", defaultValue: "Browser sign-in expired. Open some.im again to restart.")
            static let browserLoginClientSecretMissing = String(localized: "settings.some-im.browser-login-client-secret-missing", defaultValue: "This build is missing the some.im client-login secret. Set WILLDEEP_CLIENT_LOGIN_SECRET and rebuild WillDeep.")
            static let browserLoginMissingCredentials = String(localized: "settings.some-im.browser-login-missing-credentials", defaultValue: "Browser sign-in completed, but some.im did not return WillDeep credentials. Open some.im again and try signing in.")
            static let browserLoginCredentialSaveFailed = String(localized: "settings.some-im.browser-login-credential-save-failed", defaultValue: "some.im returned credentials, but WillDeep could not save them locally. Check Keychain access and try signing in again.")
            static let browserLoginConnectedTitle = String(localized: "settings.some-im.browser-login-connected-title", defaultValue: "Browser sign-in complete")
            static func browserLoginConnectedDescription(_ a1: String) -> String {
                String(localized: "settings.some-im.browser-login-connected-description", defaultValue: "Connected as \(a1). You can close the browser tab and continue in WillDeep.")
            }
            static let browserLoginOpened = String(localized: "settings.some-im.browser-login-opened", defaultValue: "some.im opened in your browser. Finish signing in there, then return to WillDeep.")
            static let browserLoginCopied = String(localized: "settings.some-im.browser-login-copied", defaultValue: "Browser login link copied.")
            static let browserLoginCodeCopied = String(localized: "settings.some-im.browser-login-code-copied", defaultValue: "Browser login code copied.")
            static let connectionSection = String(localized: "settings.some-im.connection-section", defaultValue: "some.im Integration")
            static let enabledToggle = String(localized: "settings.some-im.enabled-toggle", defaultValue: "Use some.im for multimodal generation")
            static let regionLabel = String(localized: "settings.some-im.region", defaultValue: "Region")
            static let baseURLLabel = String(localized: "settings.some-im.base-url", defaultValue: "Base URL")
            static let apiKeyLabel = String(localized: "settings.some-im.api-key", defaultValue: "API Key")
            static let fetchModels = String(localized: "settings.some-im.fetch-models", defaultValue: "Fetch Models")
            static let fetchingModels = String(localized: "settings.some-im.fetching-models", defaultValue: "Fetching...")
            static let description = String(localized: "settings.some-im.description", defaultValue: "Stores your some.im key in Keychain and lets WillDeep route image/video generation to the relay instead of guessing whether the active chat model supports generation.")
            static let imageSection = String(localized: "settings.some-im.image-section", defaultValue: "Image generation")
            static let videoSection = String(localized: "settings.some-im.video-section", defaultValue: "Video generation")
            static let imageModelLabel = String(localized: "settings.some-im.image-model", defaultValue: "Image Model")
            static let videoModelLabel = String(localized: "settings.some-im.video-model", defaultValue: "Video Model")
            static let priorityPlaceholder = String(localized: "settings.some-im.priority-placeholder", defaultValue: "Priority models, comma-separated")
            static let imageHelp = String(localized: "settings.some-im.image-help", defaultValue: "Image generation tools prefer this list. Default is gpt-image-2 when some.im is configured.")
            static let videoHelp = String(localized: "settings.some-im.video-help", defaultValue: "Choose the preferred some.im video model for async video-generation tasks.")
            static func accountSummary(_ email: String, _ credits: String) -> String {
                let template = String(localized: "settings.some-im.account-summary", defaultValue: "%1$@ · %2$@ credits")
                return String(format: template, email, credits)
            }
            static func fetchedModels(_ a1: String) -> String {
                let template = String(localized: "settings.some-im.fetched-models", defaultValue: "Fetched %@ models.")
                return String(format: template, a1)
            }
            static func regionName(_ region: SomeIMRelayRegion) -> String {
                switch region {
                case .china:
                    return String(localized: "settings.some-im.region.china", defaultValue: "China (api.niuwoai.com)")
                case .international:
                    return String(localized: "settings.some-im.region.international", defaultValue: "International (some.im)")
                case .custom:
                    return String(localized: "settings.some-im.region.custom", defaultValue: "Custom")
                }
            }
        }

        enum ImageUnderstanding {
            static let providerLabel = String(localized: "settings.image-understanding.provider", defaultValue: "Provider")
            static let baseURLLabel = String(localized: "settings.image-understanding.base-url", defaultValue: "Base URL")
            static let apiKeyLabel = String(localized: "settings.image-understanding.api-key", defaultValue: "API Key")
            static let visionModelLabel = String(localized: "settings.image-understanding.vision-model", defaultValue: "Vision Model")
            static let description = String(localized: "settings.image-understanding.description", defaultValue: "Used only when the active Agent provider cannot accept images directly. Multiple attached images are described in one request, then the description is sent to the main model.")
            static let fetchModels = String(localized: "settings.image-understanding.fetch-models", defaultValue: "Fetch Models")
            static let fetchingModels = String(localized: "settings.image-understanding.fetching-models", defaultValue: "Fetching...")
            static let fetchImageModels = String(localized: "settings.image-understanding.fetch-image-models", defaultValue: "Fetch Image Models")
            static let fetchingImages = String(localized: "settings.image-understanding.fetching-images", defaultValue: "Fetching Images...")
            static let fetchedModelsLabel = String(localized: "settings.image-understanding.fetched-models", defaultValue: "Fetched Models")
        }

        enum LocalModel {
            static let enabled = String(localized: "settings.local-model.enabled", defaultValue: "启用本地辅助模型")
            static let baseURL = String(localized: "settings.local-model.base-url", defaultValue: "本地 Endpoint")
            static let visionModel = String(localized: "settings.local-model.vision-model", defaultValue: "图片理解模型")
            static let summaryModel = String(localized: "settings.local-model.summary-model", defaultValue: "Summary 模型")
            static let preferVision = String(localized: "settings.local-model.prefer-vision", defaultValue: "图片识别先用本地")
            static let preferTitle = String(localized: "settings.local-model.prefer-title", defaultValue: "会话标题先用本地")
            static let preferContextSummary = String(localized: "settings.local-model.prefer-context-summary", defaultValue: "上下文压缩先用本地")
            static let exposeComposerModel = String(localized: "settings.local-model.expose-composer-model", defaultValue: "加入 composer 模型备选")
            static let composerModelName = String(localized: "settings.local-model.composer-model-name", defaultValue: "composer 显示名称")
            static let composerModelNamePlaceholder = String(localized: "settings.local-model.composer-model-name-placeholder", defaultValue: "Local Chat (Ollama)")
            static let description = String(localized: "settings.local-model.description", defaultValue: "启用后，图片理解、会话标题可先请求本机 OpenAI-compatible 服务；上下文压缩默认不走本地，避免小模型误压缩长上下文。失败时自动回退到你配置的远端 provider。")
            static let downloadSection = String(localized: "settings.local-model.download-section", defaultValue: "模型下载")
            static let packageLabel = String(localized: "settings.local-model.package", defaultValue: "推荐包")
            static let filesLabel = String(localized: "settings.local-model.files", defaultValue: "必要文件")
            static let locationLabel = String(localized: "settings.local-model.location", defaultValue: "保存位置")
            static let download = String(localized: "settings.local-model.download", defaultValue: "后台下载")
            static let downloading = String(localized: "settings.local-model.downloading", defaultValue: "下载中")
            static let cancel = String(localized: "settings.local-model.cancel", defaultValue: "取消")
            static let openFolder = String(localized: "settings.local-model.open-folder", defaultValue: "打开目录")
            static let findLocalFiles = String(localized: "settings.local-model.find-local-files", defaultValue: "查找本地文件")
            static let findingLocalFiles = String(localized: "settings.local-model.finding-local-files", defaultValue: "查找中")
            static let findResults = String(localized: "settings.local-model.find-results", defaultValue: "本地候选文件")
            static let findNoResults = String(localized: "settings.local-model.find-no-results", defaultValue: "没有在常见目录找到同名必要文件。")
            static let findMatched = String(localized: "settings.local-model.find-matched", defaultValue: "大小匹配")
            static let findClose = String(localized: "settings.local-model.find-close", defaultValue: "大小接近")
            static let findMismatch = String(localized: "settings.local-model.find-mismatch", defaultValue: "大小不像")
            static let installed = String(localized: "settings.local-model.installed", defaultValue: "必要文件已就绪。")
            static let notInstalled = String(localized: "settings.local-model.not-installed", defaultValue: "尚未下载完整模型包。")
            static let canceled = String(localized: "settings.local-model.canceled", defaultValue: "下载已取消。")
            static let downloadHelp = String(localized: "settings.local-model.download-help", defaultValue: "只下载主模型 GGUF 和 mmproj 视觉 projector，不会下载同仓库里的所有量化版本。下载完成后仍需要 Ollama、LM Studio 或 llama.cpp server 加载这些文件并提供 OpenAI-compatible endpoint。")
            static let localProviderListed = String(localized: "settings.local-model.provider-listed", defaultValue: "勾选“加入 composer 模型备选”后，本地模型会以你设置的名称进入模型菜单；断网时可手动切过去聊天。")

            static func progress(_ fileIndex: String, _ fileCount: String, _ fileName: String) -> String {
                let template = String(localized: "settings.local-model.progress", defaultValue: "文件 %1$@/%2$@：%3$@")
                return String(format: template, fileIndex, fileCount, fileName)
            }

            static func downloaded(_ done: String, _ total: String) -> String {
                let template = String(localized: "settings.local-model.downloaded", defaultValue: "已下载 %1$@ / %2$@")
                return String(format: template, done, total)
            }

            static func failed(_ message: String) -> String {
                let template = String(localized: "settings.local-model.failed", defaultValue: "下载失败：%@")
                return String(format: template, message)
            }

            static func findSize(_ actual: String, _ expected: String) -> String {
                let template = String(localized: "settings.local-model.find-size", defaultValue: "%1$@ / 约 %2$@")
                return String(format: template, actual, expected)
            }

            static func findFailed(_ message: String) -> String {
                let template = String(localized: "settings.local-model.find-failed", defaultValue: "查找失败：%@")
                return String(format: template, message)
            }
        }

        enum AgentBehavior {
            static let saveBehaviorNote = String(localized: "settings.agent-behavior.save-note", defaultValue: "Keystrokes stay local until you press Save (⌘↩). API keys are stored separately in Keychain.")
            static let titleModelLabel = String(localized: "settings.agent-behavior.title-model", defaultValue: "Title Model")
            static let titleModelPlaceholder = String(localized: "settings.agent-behavior.title-model-placeholder", defaultValue: "(leave empty → use Flash model)")
            static let titleModelDescription = String(localized: "settings.agent-behavior.title-model-description", defaultValue: "A short one-shot completion summarizes each new chat into a ≤12-char title after the first assistant reply. Set a cheap/fast model here (e.g. `deepseek-chat`, `gpt-4o-mini`, `qwen-turbo`) to avoid burning Pro tokens on titling. Empty → falls back to the active provider's Flash model.")
            static let toolApprovalDescription = String(localized: "settings.agent-behavior.tool-approval-description", defaultValue: "Read-only shell commands in the built-in allowlist (cat, head, tail, ls, find without -delete/-exec, git diff/log/status/show, rg, grep, wc, file, stat, which, pwd, echo, …) run without asking. Commands outside the allowlist are passed to a one-shot LLM judge running on the active provider's **Flash** model (cheap & fast — never Pro), and only YES verdicts auto-run. Destructive patterns (rm, sudo, git push --force, git reset --hard, …) still require typing \"confirm\".")
            static let concurrencyDescription = String(localized: "settings.agent-behavior.concurrency-description", defaultValue: "Cap on simultaneous Agent turns per provider. Each provider has its own quota — running 3 DashScope sessions doesn't block OpenAI sessions. When the cap is hit, new dispatches queue (FIFO) and drain as turns finish. Raising the cap immediately promotes queued work; lowering it just stops promoting new ones (running turns are never aborted). Default 3 is conservative — bump up if your provider's rate limit comfortably allows.")
            static let anthropicMaxOutputTokens = String(localized: "settings.agent-behavior.anthropic-max-output-tokens", defaultValue: "Anthropic reply limit")
            static let anthropicMaxOutputTokensDescription = String(localized: "settings.agent-behavior.anthropic-max-output-tokens-description", defaultValue: "Maximum tokens a single Anthropic reply may produce (max_tokens). Default 32K keeps long documents and large refactor replies from truncating; legacy Claude 3.x models are automatically clamped to their lower API caps.")
            static func agentAppearanceDescription(_ a1: String, _ a2: String) -> String {
                let template = String(localized: "settings.agent-behavior.appearance-description", defaultValue: "Base size (pt) for Agent chat message body and rendered Markdown blocks (paragraphs, lists, quotes, fenced code, tables). Tool-call summaries, footers, message headers, and composer chrome keep their fixed sizes — this knob is about reading the conversation, not resizing the whole UI. Default is 15 pt; range %1$@ – %2$@ pt.")
                return String(format: template, a1, a2)
            }
        }

        enum Voice {
            static let overlaySection = String(localized: "settings.voice.overlay.section", defaultValue: "Floating Transcription Bar")
            static let overlayPositionLabel = String(localized: "settings.voice.overlay.position", defaultValue: "Position")
            static let overlaySizeLabel = String(localized: "settings.voice.overlay.size", defaultValue: "Size")
            static let overlayColorLabel = String(localized: "settings.voice.overlay.color", defaultValue: "Color")
            static let overlayWaveLabel = String(localized: "settings.voice.overlay.wave", defaultValue: "Waveform")
            static let overlayCornerLabel = String(localized: "settings.voice.overlay.corner", defaultValue: "Corner radius")
            static let overlayPreviewTitle = String(localized: "settings.voice.overlay.preview.title", defaultValue: "Preview")
            static let overlayPreviewDescription = String(localized: "settings.voice.overlay.preview.description", defaultValue: "Uses the same style presets as fastv's floating transcription toolbar.")
            static let overlayPreviewButton = String(localized: "settings.voice.overlay.preview.button", defaultValue: "Show bar")
            static let overlayDescription = String(localized: "settings.voice.overlay.description", defaultValue: "These settings apply to both the Fn push-to-talk shortcut and the composer mic button.")

            static let overlayPositionTopLeft = String(localized: "settings.voice.overlay.position.top-left", defaultValue: "Top left")
            static let overlayPositionTopRight = String(localized: "settings.voice.overlay.position.top-right", defaultValue: "Top right")
            static let overlayPositionBottomLeft = String(localized: "settings.voice.overlay.position.bottom-left", defaultValue: "Bottom left")
            static let overlayPositionBottomRight = String(localized: "settings.voice.overlay.position.bottom-right", defaultValue: "Bottom right")
            static let overlayPositionBottomCenter = String(localized: "settings.voice.overlay.position.bottom-center", defaultValue: "Bottom center")

            static let overlayStyleMinimal = String(localized: "settings.voice.overlay.style.minimal", defaultValue: "Minimal")
            static let overlayStyleCompact = String(localized: "settings.voice.overlay.style.compact", defaultValue: "Compact")
            static let overlayStyleNormal = String(localized: "settings.voice.overlay.style.normal", defaultValue: "Normal")
            static let overlayStyleLarge = String(localized: "settings.voice.overlay.style.large", defaultValue: "Large")

            static let overlayWaveClassic = String(localized: "settings.voice.overlay.wave.classic", defaultValue: "Classic bars")
            static let overlayWaveEqualizer = String(localized: "settings.voice.overlay.wave.equalizer", defaultValue: "Equalizer")
            static let overlayWaveSpectrum = String(localized: "settings.voice.overlay.wave.spectrum", defaultValue: "Spectrum")
            static let overlayWavePulse = String(localized: "settings.voice.overlay.wave.pulse", defaultValue: "Pulse")
            static let overlayWaveDigital = String(localized: "settings.voice.overlay.wave.digital", defaultValue: "Digital matrix")
            static let overlayWaveSkyline = String(localized: "settings.voice.overlay.wave.skyline", defaultValue: "Neon skyline")
            static let overlayWaveSine = String(localized: "settings.voice.overlay.wave.sine", defaultValue: "Sine wave")
            static let overlayWaveCosine = String(localized: "settings.voice.overlay.wave.cosine", defaultValue: "Cosine wave")
            static let overlayWaveECG = String(localized: "settings.voice.overlay.wave.ecg", defaultValue: "ECG")

            static let overlayCornerSubtle = String(localized: "settings.voice.overlay.corner.subtle", defaultValue: "Subtle")
            static let overlayCornerRounded = String(localized: "settings.voice.overlay.corner.rounded", defaultValue: "Rounded")
            static let overlayCornerSoft = String(localized: "settings.voice.overlay.corner.soft", defaultValue: "Soft")
            static let overlayCornerCapsule = String(localized: "settings.voice.overlay.corner.capsule", defaultValue: "Capsule")

            static let overlayColorBlue = String(localized: "settings.voice.overlay.color.blue", defaultValue: "Blue")
            static let overlayColorPurple = String(localized: "settings.voice.overlay.color.purple", defaultValue: "Purple")
            static let overlayColorPink = String(localized: "settings.voice.overlay.color.pink", defaultValue: "Pink")
            static let overlayColorGreen = String(localized: "settings.voice.overlay.color.green", defaultValue: "Green")
            static let overlayColorOrange = String(localized: "settings.voice.overlay.color.orange", defaultValue: "Orange")
            static let overlayColorRed = String(localized: "settings.voice.overlay.color.red", defaultValue: "Red")
            static let overlayColorBlackWhite = String(localized: "settings.voice.overlay.color.black-white", defaultValue: "Black + white")
            static let overlayColorWhiteBlack = String(localized: "settings.voice.overlay.color.white-black", defaultValue: "White + black")
            static let overlayColorSkyGlass = String(localized: "settings.voice.overlay.color.sky-glass", defaultValue: "Sky glass")
            static let overlayColorMintCream = String(localized: "settings.voice.overlay.color.mint-cream", defaultValue: "Mint cream")
            static let overlayColorLavenderMist = String(localized: "settings.voice.overlay.color.lavender-mist", defaultValue: "Lavender mist")
            static let overlayColorPeachSorbet = String(localized: "settings.voice.overlay.color.peach-sorbet", defaultValue: "Peach sorbet")
            static let overlayColorRoseQuartz = String(localized: "settings.voice.overlay.color.rose-quartz", defaultValue: "Rose quartz")
            static let overlayColorLemonCream = String(localized: "settings.voice.overlay.color.lemon-cream", defaultValue: "Lemon cream")
            static let overlayColorAquaGlass = String(localized: "settings.voice.overlay.color.aqua-glass", defaultValue: "Aqua glass")
            static let overlayColorWarmSand = String(localized: "settings.voice.overlay.color.warm-sand", defaultValue: "Warm sand")
            static let overlayColorDarkGrayWhite = String(localized: "settings.voice.overlay.color.dark-gray-white", defaultValue: "Dark gray + white")
            static let overlayColorDarkBlueCyan = String(localized: "settings.voice.overlay.color.dark-blue-cyan", defaultValue: "Dark blue + cyan")
            static let overlayColorDarkPurplePink = String(localized: "settings.voice.overlay.color.dark-purple-pink", defaultValue: "Dark purple + pink")
            static let overlayColorQuantumCyan = String(localized: "settings.voice.overlay.color.quantum-cyan", defaultValue: "Quantum cyan")
            static let overlayColorNeonTokyo = String(localized: "settings.voice.overlay.color.neon-tokyo", defaultValue: "Neon Tokyo")
            static let overlayColorAuroraMint = String(localized: "settings.voice.overlay.color.aurora-mint", defaultValue: "Aurora mint")
            static let overlayColorIonStorm = String(localized: "settings.voice.overlay.color.ion-storm", defaultValue: "Ion storm")
            static let overlayColorPlasmaCore = String(localized: "settings.voice.overlay.color.plasma-core", defaultValue: "Plasma core")
            static let overlayColorSolarFlare = String(localized: "settings.voice.overlay.color.solar-flare", defaultValue: "Solar flare")
            static let overlayColorHologram = String(localized: "settings.voice.overlay.color.hologram", defaultValue: "Hologram")
            static let overlayColorLaserGrid = String(localized: "settings.voice.overlay.color.laser-grid", defaultValue: "Laser grid")
            static let overlayColorDeepSpace = String(localized: "settings.voice.overlay.color.deep-space", defaultValue: "Deep space")
            static let overlayColorCyberSunset = String(localized: "settings.voice.overlay.color.cyber-sunset", defaultValue: "Cyber sunset")
            static let overlayColorLunarSignal = String(localized: "settings.voice.overlay.color.lunar-signal", defaultValue: "Lunar signal")
            static let overlayColorCosmicGrape = String(localized: "settings.voice.overlay.color.cosmic-grape", defaultValue: "Cosmic grape")
            static let overlayColorDarkGreenLime = String(localized: "settings.voice.overlay.color.dark-green-lime", defaultValue: "Dark green + lime")
            static let overlayColorDarkRedCoral = String(localized: "settings.voice.overlay.color.dark-red-coral", defaultValue: "Dark red + coral")
            static let overlayColorDarkGrayBlue = String(localized: "settings.voice.overlay.color.dark-gray-blue", defaultValue: "Dark gray + blue")
            static let overlayColorDarkGrayGreen = String(localized: "settings.voice.overlay.color.dark-gray-green", defaultValue: "Dark gray + green")
            static let overlayColorDarkGrayOrange = String(localized: "settings.voice.overlay.color.dark-gray-orange", defaultValue: "Dark gray + orange")
            static let overlayColorDarkGrayPink = String(localized: "settings.voice.overlay.color.dark-gray-pink", defaultValue: "Dark gray + pink")
            static let overlayColorDarkGrayPurple = String(localized: "settings.voice.overlay.color.dark-gray-purple", defaultValue: "Dark gray + purple")
            static let overlayColorDarkGrayRed = String(localized: "settings.voice.overlay.color.dark-gray-red", defaultValue: "Dark gray + red")
            static let overlayColorDarkGrayYellow = String(localized: "settings.voice.overlay.color.dark-gray-yellow", defaultValue: "Dark gray + yellow")
            static let overlayColorDarkGrayCyan = String(localized: "settings.voice.overlay.color.dark-gray-cyan", defaultValue: "Dark gray + cyan")

            static let headerTitle = String(localized: "settings.voice.header-title", defaultValue: "On-device Voice (SenseVoice)")
            static let headerDescription = String(localized: "settings.voice.header-description", defaultValue: "Push-to-talk in the composer transcribes on-device. Optional AI cleanup can polish the result after transcription.")
            static let cleanupSection = String(localized: "settings.voice.cleanup.section", defaultValue: "AI Cleanup")
            static let cleanupModeLabel = String(localized: "settings.voice.cleanup.mode", defaultValue: "After transcription")
            static let cleanupOff = String(localized: "settings.voice.cleanup.off", defaultValue: "Off")
            static let cleanupPunctuation = String(localized: "settings.voice.cleanup.punctuation", defaultValue: "Punctuation + paragraphs")
            static let cleanupBulletPoints = String(localized: "settings.voice.cleanup.bullet-points", defaultValue: "Structure into points")
            static let cleanupOffDescription = String(localized: "settings.voice.cleanup.off-description", defaultValue: "Append the local transcript exactly as produced by SenseVoice.")
            static let cleanupPunctuationDescription = String(localized: "settings.voice.cleanup.punctuation-description", defaultValue: "Use the configured AI model to add punctuation, paragraphs, and light wording cleanup without summarizing.")
            static let cleanupBulletPointsDescription = String(localized: "settings.voice.cleanup.bullet-points-description", defaultValue: "Use the configured AI model to lightly organize longer dictation into a few clear points.")
            static let cleanupPrivacyNote = String(localized: "settings.voice.cleanup.privacy-note", defaultValue: "When AI cleanup is enabled, the transcribed text is sent to your configured AI provider. Voice audio still stays on this Mac.")
            static let languageSection = String(localized: "settings.voice.language.section", defaultValue: "Transcription Language")
            static let languageLabel = String(localized: "settings.voice.language.label", defaultValue: "Language")
            static let languageDescription = String(localized: "settings.voice.language.description", defaultValue: "Follow system is the default. Choose Japanese or another fixed language when you need deterministic voice-input testing.")
            static let languageFollowSystem = String(localized: "settings.voice.language.follow-system", defaultValue: "Follow system")
            static let languageAuto = String(localized: "settings.voice.language.auto", defaultValue: "Auto detect")
            static let languageChinese = String(localized: "settings.voice.language.chinese", defaultValue: "Chinese")
            static let languageEnglish = String(localized: "settings.voice.language.english", defaultValue: "English")
            static let languageCantonese = String(localized: "settings.voice.language.cantonese", defaultValue: "Cantonese")
            static let languageJapanese = String(localized: "settings.voice.language.japanese", defaultValue: "Japanese")
            static let languageKorean = String(localized: "settings.voice.language.korean", defaultValue: "Korean")
            static let statusInstalledTitle = String(localized: "settings.voice.status-installed-title", defaultValue: "SenseVoice model installed")
            static let statusNotInstalledTitle = String(localized: "settings.voice.status-not-installed-title", defaultValue: "Model not installed yet")
            static let statusInstalledDetail = String(localized: "settings.voice.status-installed-detail", defaultValue: "Mic button in composer is enabled. Press and hold to record, release to transcribe. Tip: hold the Fn key anywhere in the app for the same push-to-talk.")
            static let statusNotInstalledDetail = String(localized: "settings.voice.status-not-installed-detail", defaultValue: "Click Download below (~937 MB). After install the mic button in composer goes live and the Fn-key push-to-talk shortcut starts working.")
            static let downloadButton = String(localized: "settings.voice.download-button", defaultValue: "Download model (~937 MB)")
            static let importButton = String(localized: "settings.voice.import-button", defaultValue: "Import from fastv (0 MB)")
            static let importHelp = String(localized: "settings.voice.import-help", defaultValue: "Symlink an existing fastv model copy — no download.")
            static let revealInFinder = String(localized: "settings.voice.reveal-in-finder", defaultValue: "Reveal in Finder")
            static let importing = String(localized: "settings.voice.importing", defaultValue: "Importing from fastv…")
            static let cancel = String(localized: "settings.voice.cancel", defaultValue: "Cancel")
            static let memorySection = String(localized: "settings.voice.memory-section", defaultValue: "Memory")
            static let preloadToggle = String(localized: "settings.voice.preload-toggle", defaultValue: "Preload on launch")
            static let preloadDescription = String(localized: "settings.voice.preload-description", defaultValue: "Keep the ~937 MB voice model out of memory at launch by default. Enable this after your first transcription if you prefer instant push-to-talk over lower idle memory.")
            static let loadedInMemory = String(localized: "settings.voice.loaded-in-memory", defaultValue: "Loaded in memory")
            static let notInMemory = String(localized: "settings.voice.not-in-memory", defaultValue: "Not in memory")
            static let unloadNow = String(localized: "settings.voice.unload-now", defaultValue: "Unload now")
            static let refreshStatusHelp = String(localized: "settings.voice.refresh-status-help", defaultValue: "Refresh status")
            static let autoUnloadNote = String(localized: "settings.voice.auto-unload-note", defaultValue: "The model also auto-unloads after 5 minutes of foreground idle, 10 minutes of background, or when the app's resident memory exceeds 4 GB.")
            static let modelLocation = String(localized: "settings.voice.model-location", defaultValue: "Model location")
        }

        enum Tools {
            static let alwaysAllowNote = String(localized: "settings.tools.always-allow-note", defaultValue: "Rules apply to command families such as `git push`; dangerous commands still require confirmation.")
            static let removeButton = String(localized: "settings.tools.remove", defaultValue: "Remove")
            static let clearAllButton = String(localized: "settings.tools.clear-all", defaultValue: "Clear All")
            static let cliSection = String(localized: "settings.tools.cli-section", defaultValue: "Command Line Tool")
            static func installedAt(_ a1: String) -> String {
                let template = String(localized: "settings.tools.cli-installed-at", defaultValue: "Installed at %@")
                return String(format: template, a1)
            }
            static func needsUpdateAt(_ a1: String) -> String {
                let template = String(localized: "settings.tools.cli-needs-update", defaultValue: "A command exists at %@ and can be updated.")
                return String(format: template, a1)
            }
            static let notInstalled = String(localized: "settings.tools.cli-not-installed", defaultValue: "Install the willdeep command for Terminal.")
            static let installingButton = String(localized: "settings.tools.cli-installing", defaultValue: "Installing...")
            static let reinstallButton = String(localized: "settings.tools.cli-reinstall", defaultValue: "Reinstall")
            static let updateButton = String(localized: "settings.tools.cli-update", defaultValue: "Update")
            static let installButton = String(localized: "settings.tools.cli-install", defaultValue: "Install")
            static let installingMessage = String(localized: "settings.tools.cli-installing-message", defaultValue: "Installing without administrator privileges.")
            static let installedMessage = String(localized: "settings.tools.cli-installed-message", defaultValue: "Installed. Try: willdeep . Add ~/.local/bin to PATH if needed.")
        }

        enum LocalAgents {
            static let discoveredSection = String(localized: "settings.local-agents.discovered-section", defaultValue: "Discovered CLI Agents")
            static let description = String(localized: "settings.local-agents.description", defaultValue: "Scans common install paths and PATH without launching the tools.")
            static let refreshButton = String(localized: "settings.local-agents.refresh", defaultValue: "Refresh")
            static let notFound = String(localized: "settings.local-agents.not-found", defaultValue: "Not found on this Mac")
            static let integrationSection = String(localized: "settings.local-agents.integration-section", defaultValue: "WillDeep Integration")
            static let integrationDescription = String(localized: "settings.local-agents.integration-description", defaultValue: "Discovery means the CLI exists locally. Direct delegation means the current Agent tool surface can invoke it after user approval.")
            static let discoveryOnly = String(localized: "settings.local-agents.discovery-only", defaultValue: "Discovered only — not yet exposed as a callable Agent tool.")
            static func summary(_ a1: String, _ a2: String) -> String {
                let template = String(localized: "settings.local-agents.summary", defaultValue: "%1$@ of %2$@ known CLI agents found")
                return String(format: template, a1, a2)
            }
            static func directTool(_ a1: String) -> String {
                let template = String(localized: "settings.local-agents.direct-tool", defaultValue: "Direct delegation available through `%@`.")
                return String(format: template, a1)
            }
        }

        enum MobileGateway {
            static let controlSection = String(localized: "settings.mobile-gateway.control-section", defaultValue: "LAN Access")
            static let listenSection = String(localized: "settings.mobile-gateway.listen-section", defaultValue: "Gateway")
            static let pairingSection = String(localized: "settings.mobile-gateway.pairing-section", defaultValue: "Pairing")
            static let devicesSection = String(localized: "settings.mobile-gateway.devices-section", defaultValue: "Paired Devices")
            static let allowPairingToggle = String(localized: "settings.mobile-gateway.allow-pairing-toggle", defaultValue: "Allow new device pairing")
            static let statusLabel = String(localized: "settings.mobile-gateway.status", defaultValue: "Status")
            static let addressLabel = String(localized: "settings.mobile-gateway.address", defaultValue: "LAN address")
            static let protocolLabel = String(localized: "settings.mobile-gateway.protocol", defaultValue: "Protocol")
            static let desktopPeerLabel = String(localized: "settings.mobile-gateway.desktop-peer", defaultValue: "Desktop peer")
            static let pairingBaseURLLabel = String(localized: "settings.mobile-gateway.pairing-base-url", defaultValue: "Pairing URL")
            static let fallbackBaseURLsLabel = String(localized: "settings.mobile-gateway.fallback-base-urls", defaultValue: "Fallback URLs")
            static let expiresLabel = String(localized: "settings.mobile-gateway.expires", defaultValue: "Expires")
            static let hostPrompt = String(localized: "settings.mobile-gateway.host-prompt", defaultValue: "0.0.0.0")
            static let portInputLabel = String(localized: "settings.mobile-gateway.port-input", defaultValue: "Port")
            static let portPrompt = String(localized: "settings.mobile-gateway.port-prompt", defaultValue: "8877")
            static let desktopNamePrompt = String(localized: "settings.mobile-gateway.desktop-name-prompt", defaultValue: "Desktop name shown on Android")
            static let executablePathPrompt = String(localized: "settings.mobile-gateway.executable-path-prompt", defaultValue: "Optional willdeep-agent executable path")
            static let relayBaseURLPrompt = String(localized: "settings.mobile-gateway.relay-base-url-prompt", defaultValue: "Optional public relay URL")
            static let relayRoomPrompt = String(localized: "settings.mobile-gateway.relay-room-prompt", defaultValue: "Relay room")
            static let customRelayToggle = String(localized: "settings.mobile-gateway.custom-relay-toggle", defaultValue: "Custom relay service")
            static let customRelayDescription = String(localized: "settings.mobile-gateway.custom-relay-description", defaultValue: "Only change these if you run your own compatible WebSocket relay. The default public relay is already configured.")
            static let restartButton = String(localized: "settings.mobile-gateway.restart", defaultValue: "Apply & Restart")
            static let refreshButton = String(localized: "settings.mobile-gateway.refresh", defaultValue: "Refresh")
            static let copyPayloadButton = String(localized: "settings.mobile-gateway.copy-payload", defaultValue: "Copy pairing payload")
            static let refreshPairingButton = String(localized: "settings.mobile-gateway.refresh-pairing", defaultValue: "Refresh pairing QR")
            static let revokeButton = String(localized: "settings.mobile-gateway.revoke", defaultValue: "Revoke")
            static let notRunning = String(localized: "settings.mobile-gateway.not-running", defaultValue: "Not running")
            static let connected = String(localized: "settings.mobile-gateway.connected", defaultValue: "Connected")
            static let disconnected = String(localized: "settings.mobile-gateway.disconnected", defaultValue: "Disconnected")
            static let stopped = String(localized: "settings.mobile-gateway.stopped", defaultValue: "Stopped")
            static let starting = String(localized: "settings.mobile-gateway.starting", defaultValue: "Starting...")
            static let running = String(localized: "settings.mobile-gateway.running", defaultValue: "Running")
            static let runningRelay = String(localized: "settings.mobile-gateway.running-relay", defaultValue: "Running (internet relay)")
            static let transportModeLabel = String(localized: "settings.mobile-gateway.transport-mode", defaultValue: "Connection")
            static let transportModeRelay = String(localized: "settings.mobile-gateway.transport-mode-relay", defaultValue: "Internet relay")
            static let transportModeLanGateway = String(localized: "settings.mobile-gateway.transport-mode-lan", defaultValue: "Local network")
            static let transportModeRelayCaption = String(localized: "settings.mobile-gateway.transport-mode-relay-caption", defaultValue: "Default. Connects through the public relay, so your phone works from anywhere with no local gateway to run. Session content is routed through the relay server (transport-encrypted, not yet end-to-end).")
            static let transportModeLanGatewayCaption = String(localized: "settings.mobile-gateway.transport-mode-lan-caption", defaultValue: "Fallback. Runs a local gateway process for same-network pairing with per-device tokens — useful offline or on isolated networks.")
            static let rotateRelayButton = String(localized: "settings.mobile-gateway.rotate-relay", defaultValue: "Rotate relay room")
            static let scanHintRelay = String(localized: "settings.mobile-gateway.scan-hint-relay", defaultValue: "Scan this QR code with the WillDeep Android app to pair over the internet relay. Works off your local network.")
            static let devicesRelayNote = String(localized: "settings.mobile-gateway.devices-relay-note", defaultValue: "Relay mode shares one room token instead of per-device tokens. To de-authorize a phone, rotate the relay room — every paired device must re-scan.")
            static let noPairingPayload = String(localized: "settings.mobile-gateway.no-pairing-payload", defaultValue: "Pairing is unavailable. Refresh pairing after enabling new device pairing.")
            static let startToPair = String(localized: "settings.mobile-gateway.start-to-pair", defaultValue: "Start the gateway to show a QR pairing code.")
            static let noDevices = String(localized: "settings.mobile-gateway.no-devices", defaultValue: "No Android devices are paired yet.")
            static let revoked = String(localized: "settings.mobile-gateway.revoked", defaultValue: "Revoked")
            static let qrAccessibilityLabel = String(localized: "settings.mobile-gateway.qr-accessibility-label", defaultValue: "Mobile Gateway pairing QR code")
            static let qrUnavailable = String(localized: "settings.mobile-gateway.qr-unavailable", defaultValue: "QR code unavailable")
            static let listenDescription = String(localized: "settings.mobile-gateway.listen-description", defaultValue: "The gateway listens only after you enable it. Android connects over the local network; Agent execution, tools, patches, and file access still run through the Mac app.")
            static let advancedToggle = String(localized: "settings.mobile-gateway.advanced-toggle", defaultValue: "Show advanced info (IP / port / executable)")
            static let logSection = String(localized: "settings.mobile-gateway.log-section", defaultValue: "Gateway log")
            static let scanHint = String(localized: "settings.mobile-gateway.scan-hint", defaultValue: "Scan this QR code with the WillDeep Android app to pair over your local network.")
            static func resolvedExecutable(_ a1: String) -> String {
                let template = String(localized: "settings.mobile-gateway.resolved-executable", defaultValue: "Using %@")
                return String(format: template, a1)
            }
            static func failed(_ a1: String) -> String {
                let template = String(localized: "settings.mobile-gateway.failed", defaultValue: "Failed: %@")
                return String(format: template, a1)
            }
            static func lastConnected(_ a1: String) -> String {
                let template = String(localized: "settings.mobile-gateway.last-connected", defaultValue: "Last connected %@")
                return String(format: template, a1)
            }
            static func createdAt(_ a1: String) -> String {
                let template = String(localized: "settings.mobile-gateway.created-at", defaultValue: "Paired %@")
                return String(format: template, a1)
            }
        }

        enum RemoteRuntimes {
            static let listSection = String(localized: "settings.remote-runtimes.list-section", defaultValue: "Remote Runtimes")
            static let empty = String(localized: "settings.remote-runtimes.empty", defaultValue: "No remote runtimes configured.")
            static let addButton = String(localized: "settings.remote-runtimes.add", defaultValue: "Add SSH Runtime")
            static let addDaemonButton = String(localized: "settings.remote-runtimes.add-daemon", defaultValue: "Add Daemon Runtime")
            static let newRuntimeDefaultName = String(localized: "settings.remote-runtimes.new-default-name", defaultValue: "New SSH Runtime")
            static let newDaemonRuntimeDefaultName = String(localized: "settings.remote-runtimes.new-daemon-default-name", defaultValue: "New Daemon Runtime")
            static let connectionSection = String(localized: "settings.remote-runtimes.connection-section", defaultValue: "SSH Connection")
            static let displayNameLabel = String(localized: "settings.remote-runtimes.display-name", defaultValue: "Display name")
            static let displayNamePrompt = String(localized: "settings.remote-runtimes.display-name.prompt", defaultValue: "Name shown in the runtime list")
            static let transportLabel = String(localized: "settings.remote-runtimes.transport", defaultValue: "Transport")
            static let sshTransportLabel = String(localized: "settings.remote-runtimes.transport.ssh", defaultValue: "SSH")
            static let daemonTransportLabel = String(localized: "settings.remote-runtimes.transport.daemon", defaultValue: "Daemon")
            static let hostLabel = String(localized: "settings.remote-runtimes.host", defaultValue: "Host")
            static let hostPrompt = String(localized: "settings.remote-runtimes.host.prompt", defaultValue: "example.com or SSH config host")
            static let usernameLabel = String(localized: "settings.remote-runtimes.username", defaultValue: "Username")
            static let usernamePrompt = String(localized: "settings.remote-runtimes.username.prompt", defaultValue: "Remote login user")
            static let portInputLabel = String(localized: "settings.remote-runtimes.port-input", defaultValue: "Port")
            static let portPrompt = String(localized: "settings.remote-runtimes.port.prompt", defaultValue: "22")
            static func portLabel(_ a1: String) -> String {
                let template = String(localized: "settings.remote-runtimes.port", defaultValue: "Port %@")
                return String(format: template, a1)
            }
            static let identityFileLabel = String(localized: "settings.remote-runtimes.identity-file", defaultValue: "SSH identity file path (optional)")
            static let identityFilePrompt = String(localized: "settings.remote-runtimes.identity-file.prompt", defaultValue: "~/.ssh/id_rsa")
            static let daemonURLLabel = String(localized: "settings.remote-runtimes.daemon-url", defaultValue: "Daemon URL")
            static let daemonURLPrompt = String(localized: "settings.remote-runtimes.daemon-url.prompt", defaultValue: "http://127.0.0.1:8765")
            static let daemonTokenLabel = String(localized: "settings.remote-runtimes.daemon-token", defaultValue: "Daemon token (stored in Keychain)")
            static let daemonTokenPrompt = String(localized: "settings.remote-runtimes.daemon-token.prompt", defaultValue: "Paste daemon token")
            static let workspacePathLabel = String(localized: "settings.remote-runtimes.workspace-path", defaultValue: "Remote workspace path")
            static let workspacePathPrompt = String(localized: "settings.remote-runtimes.workspace-path.prompt", defaultValue: "/path/to/workspace")
            static let sshDescription = String(localized: "settings.remote-runtimes.ssh-description", defaultValue: "Uses the system ssh client with BatchMode authentication. Configure hosts in your normal SSH config or provide an optional identity-file path; WillDeep stores only the path, never private key contents.")
            static let terminalSection = String(localized: "settings.remote-runtimes.terminal-section", defaultValue: "Interactive Terminal")
            static let terminalAutoRunLabel = String(localized: "settings.remote-runtimes.terminal-auto-run", defaultValue: "Run terminal startup queue after connect")
            static let terminalStartupDirectoryLabel = String(localized: "settings.remote-runtimes.terminal-startup-directory", defaultValue: "Startup directory")
            static let terminalStartupDirectoryPrompt = String(localized: "settings.remote-runtimes.terminal-startup-directory.prompt", defaultValue: "/var/www/app")
            static let terminalStartupCommandsLabel = String(localized: "settings.remote-runtimes.terminal-startup-commands", defaultValue: "Auto commands")
            static let terminalStartupCommandsHelp = String(localized: "settings.remote-runtimes.terminal-startup-commands.help", defaultValue: "One command per line. These run before jump commands.")
            static let terminalJumpCommandsLabel = String(localized: "settings.remote-runtimes.terminal-jump-commands", defaultValue: "Jump commands")
            static let terminalJumpCommandsHelp = String(localized: "settings.remote-runtimes.terminal-jump-commands.help", defaultValue: "One command per line. These run after auto commands, for bastion or second-hop shells.")
            static let terminalDelayLabel = String(localized: "settings.remote-runtimes.terminal-delay", defaultValue: "Command delay (ms)")
            static let terminalDelayPrompt = String(localized: "settings.remote-runtimes.terminal-delay.prompt", defaultValue: "450")
            static let terminalIdleTimeoutLabel = String(localized: "settings.remote-runtimes.terminal-idle-timeout", defaultValue: "Idle timeout (s)")
            static let terminalIdleTimeoutPrompt = String(localized: "settings.remote-runtimes.terminal-idle-timeout.prompt", defaultValue: "5")
            static let terminalServicesLabel = String(localized: "settings.remote-runtimes.terminal-services", defaultValue: "Common services")
            static let terminalServicesHelp = String(localized: "settings.remote-runtimes.terminal-services.help", defaultValue: "One service name per line for the Agent Terminal service menu.")
            static let terminalDescription = String(localized: "settings.remote-runtimes.terminal-description", defaultValue: "The Agent Terminal uses an interactive SSH PTY. User typing goes straight to the terminal; AI command input still requires approval.")
            static let probeSection = String(localized: "settings.remote-runtimes.probe-section", defaultValue: "Probe")
            static let platformLabel = String(localized: "settings.remote-runtimes.platform", defaultValue: "Platform")
            static let capabilitiesLabel = String(localized: "settings.remote-runtimes.capabilities", defaultValue: "Capabilities")
            static let toolchainLabel = String(localized: "settings.remote-runtimes.toolchain", defaultValue: "Toolchain")
            static let collaborationLabel = String(localized: "settings.remote-runtimes.collaboration", defaultValue: "Collaboration")
            static let githubCLIMissing = String(localized: "settings.remote-runtimes.github-cli-missing", defaultValue: "GitHub CLI (gh) not found. Install it on the remote host and run gh auth login for GitHub workflows.")
            static let githubCLIAuthSuggested = String(localized: "settings.remote-runtimes.github-cli-auth-suggested", defaultValue: "Run gh auth login on the remote host to enable GitHub workflows.")
            static let mirrorLabel = String(localized: "settings.remote-runtimes.mirrors", defaultValue: "Registries / mirrors")
            static let proxyLabel = String(localized: "settings.remote-runtimes.proxies", defaultValue: "Proxy settings")
            static let lastProbeLabel = String(localized: "settings.remote-runtimes.last-probe", defaultValue: "Last probe")
            static let probeButton = String(localized: "settings.remote-runtimes.probe", defaultValue: "Test & Probe")
            static let probingButton = String(localized: "settings.remote-runtimes.probing", defaultValue: "Probing...")
            static let saveButton = String(localized: "settings.remote-runtimes.save", defaultValue: "Save")
            static let deleteButton = String(localized: "settings.remote-runtimes.delete", defaultValue: "Delete")
            static let savedStatus = String(localized: "settings.remote-runtimes.saved", defaultValue: "Runtime saved.")
            static let deletedStatus = String(localized: "settings.remote-runtimes.deleted", defaultValue: "Runtime deleted.")
            static func probingStatus(_ a1: String) -> String {
                let template = String(localized: "settings.remote-runtimes.probing-status", defaultValue: "Probing %@...")
                return String(format: template, a1)
            }
            static func probeSucceeded(_ a1: String, _ a2: String) -> String {
                let template = String(localized: "settings.remote-runtimes.probe-succeeded", defaultValue: "Probe succeeded: %1$@ / %2$@.")
                return String(format: template, a1, a2)
            }
            static func probeFailed(_ a1: String) -> String {
                let template = String(localized: "settings.remote-runtimes.probe-failed", defaultValue: "Probe failed: %@")
                return String(format: template, a1)
            }
            static let daemonSection = String(localized: "settings.remote-runtimes.daemon-section", defaultValue: "Daemon Runtime")
            static let daemonDescription = String(localized: "settings.remote-runtimes.daemon-description", defaultValue: "Connects to willdeep-agent over HTTP/WebSocket. Keep the daemon bound to 127.0.0.1 and reach it through an SSH tunnel; WillDeep stores the token in Keychain.")
        }

        enum Provider {
            static let editsAutoSave = String(localized: "settings.provider.edits-auto-save", defaultValue: "Edits save automatically. The active provider (★) drives the next chat turn — click any star to switch.")
            static let addTooltip = String(localized: "settings.provider.add-tooltip", defaultValue: "Add provider")
            static let removeTooltip = String(localized: "settings.provider.remove-tooltip", defaultValue: "Remove selected provider")
            static let activeTooltip = String(localized: "settings.provider.active-tooltip", defaultValue: "Active provider")
            static let makeActiveTooltip = String(localized: "settings.provider.make-active-tooltip", defaultValue: "Make active")
            static let emptySelection = String(localized: "settings.provider.empty-selection", defaultValue: "Pick a provider on the left, or add one with +")
            static let connectionSection = String(localized: "settings.provider.connection", defaultValue: "Connection")
            static let displayNameLabel = String(localized: "settings.provider.display-name", defaultValue: "Display name")
            static let displayNamePlaceholder = String(localized: "settings.provider.display-name-placeholder", defaultValue: "e.g. Work OpenAI")
            static let presetLabel = String(localized: "settings.provider.preset", defaultValue: "Preset")
            static let protocolLabel = String(localized: "settings.provider.protocol", defaultValue: "Protocol")
            static let openAIChatDefault = String(localized: "settings.provider.openai-chat-default", defaultValue: "OpenAI Chat (default)")
            static let protocolOpenAIChat = String(localized: "settings.provider.protocol-openai-chat", defaultValue: "OpenAI Chat")
            static let protocolAnthropicMessages = String(localized: "settings.provider.protocol-anthropic-messages", defaultValue: "Anthropic Messages")
            static let protocolGoogleGemini = String(localized: "settings.provider.protocol-google-gemini", defaultValue: "Google Gemini")
            static let protocolOpenAIResponses = String(localized: "settings.provider.protocol-openai-responses", defaultValue: "OpenAI Responses")
            static let baseURLLabel = String(localized: "settings.provider.base-url", defaultValue: "Base URL")
            static let apiKeyLabel = String(localized: "settings.provider.api-key", defaultValue: "API key")
            static let baseURLDefault = String(localized: "settings.provider.base-url-default", defaultValue: "Using preset URL")
            static let baseURLCustom = String(localized: "settings.provider.base-url-custom", defaultValue: "Customized")
            static func protocolLine(_ a1: String) -> String {
                let template = String(localized: "settings.provider.protocol-line", defaultValue: "Protocol: %@")
                return String(format: template, a1)
            }
            static let modelsSection = String(localized: "settings.provider.models", defaultValue: "Models")
            static let routingSection = String(localized: "settings.provider.routing", defaultValue: "Routing")
            static let defaultTierLabel = String(localized: "settings.provider.default-tier", defaultValue: "Default tier")
            static let fetchModels = String(localized: "settings.provider.fetch-models", defaultValue: "Fetch Models")
            static let fetchingModels = String(localized: "settings.provider.fetching-models", defaultValue: "Fetching…")
            static func modelListInvalidFormat(_ issue: String, _ actual: String, _ expected: String) -> String {
                let template = String(
                    localized: "settings.provider.model-list-invalid-format",
                    defaultValue: "Invalid model-list response: %@. Received %@. Expected %@."
                )
                return String(format: template, issue, actual, expected)
            }
            static func v1ProbeSucceeded(_ count: String, _ url: String) -> String {
                let template = String(
                    localized: "settings.provider.v1-probe-succeeded",
                    defaultValue: "Fetched %@ models from %@. Add /v1 to the Base URL?"
                )
                return String(format: template, count, url)
            }
            static let appendV1Action = String(
                localized: "settings.provider.append-v1-action",
                defaultValue: "Add /v1"
            )
            static let appendV1Help = String(
                localized: "settings.provider.append-v1-help",
                defaultValue: "Use the verified /v1 address as this provider's Base URL"
            )
            static let removeV1Action = String(
                localized: "settings.provider.remove-v1-action",
                defaultValue: "Remove /v1"
            )
            static let removeV1Help = String(
                localized: "settings.provider.remove-v1-help",
                defaultValue: "Use the verified address without /v1 as this provider's Base URL"
            )
            static func v1RemovalProbeSucceeded(_ count: String, _ url: String) -> String {
                let template = String(
                    localized: "settings.provider.v1-removal-probe-succeeded",
                    defaultValue: "Fetched %@ models from %@. Remove /v1 from the Base URL?"
                )
                return String(format: template, count, url)
            }
            static func baseURLUpdated(_ url: String) -> String {
                let template = String(
                    localized: "settings.provider.base-url-updated",
                    defaultValue: "Base URL updated to %@."
                )
                return String(format: template, url)
            }
            static let alternatesHint = String(localized: "settings.provider.alternates-hint", defaultValue: "One model id per line — surfaces in the chat picker as one-click switches.")
            static let showAlternatesToggle = String(localized: "settings.provider.show-alternates-toggle", defaultValue: "Show alternate models")
            static let pickFromFetched = String(localized: "settings.provider.pick-from-fetched", defaultValue: "Pick from fetched models")
            static let hideKey = String(localized: "settings.provider.hide-key", defaultValue: "Hide key")
            static let showKey = String(localized: "settings.provider.show-key", defaultValue: "Show key")
            static let modelIDPlaceholder = String(localized: "settings.provider.model-id-placeholder", defaultValue: "model-id")
            static func primarySuffix(_ a1: String) -> String {
                let template = String(localized: "settings.provider.primary-suffix", defaultValue: "%@ primary")
                return String(format: template, a1)
            }
            static func alternatesSuffix(_ a1: String) -> String {
                let template = String(localized: "settings.provider.alternates-suffix", defaultValue: "%@ alternates")
                return String(format: template, a1)
            }
        }

        enum MCP {
            static let serversDescription = String(localized: "settings.mcp.servers-description", defaultValue: "Servers available in this workspace.")
            static func serversEnabled(_ a1: String, _ a2: String) -> String {
                let template = String(localized: "settings.mcp.servers-enabled", defaultValue: "%1$@ of %2$@ MCP servers enabled")
                return String(format: template, a1, a2)
            }
            static let refresh = String(localized: "settings.mcp.refresh", defaultValue: "Refresh")
            static let cursorConfig = String(localized: "settings.mcp.cursor-config", defaultValue: "Cursor mcp.json")
            static let newServer = String(localized: "settings.mcp.new-server", defaultValue: "New MCP Server")
            static let recommendedServers = String(localized: "settings.mcp.recommended-servers", defaultValue: "Recommended MCP Servers")
            static let recommendedDescription = String(localized: "settings.mcp.recommended-description", defaultValue: "Add common MCP servers with safe defaults. Playwright uses npx -y so first launch does not stop at an interactive install prompt.")
            static let addPreset = String(localized: "settings.mcp.add-preset", defaultValue: "Add")
            static let playwrightPresetTitle = String(localized: "settings.mcp.playwright-preset-title", defaultValue: "Playwright MCP")
            static let playwrightChinaPresetTitle = String(localized: "settings.mcp.playwright-china-preset-title", defaultValue: "Playwright MCP (China mirror)")
            static let userServers = String(localized: "settings.mcp.user-servers", defaultValue: "User MCP Servers")
            static let cursorServers = String(localized: "settings.mcp.cursor-servers", defaultValue: "Cursor MCP Servers")
            static let codexServers = String(localized: "settings.mcp.codex-servers", defaultValue: "Codex MCP Servers")
            static let noServers = String(localized: "settings.mcp.no-servers", defaultValue: "No servers in this group.")
            static let logout = String(localized: "settings.mcp.logout", defaultValue: "Logout")
            static func toolsEnabled(_ a1: String) -> String {
                let template = String(localized: "settings.mcp.tools-enabled", defaultValue: "%@ tools enabled")
                return String(format: template, a1)
            }
            static let toolListNotRefreshed = String(localized: "settings.mcp.tool-list-not-refreshed", defaultValue: "Tool list not refreshed")
            static let disabled = String(localized: "settings.mcp.disabled", defaultValue: "Disabled")
            static let trustedHelp = String(localized: "settings.mcp.trusted-help", defaultValue: "Trusted. Pinned tools auto-run.")
            static let untrustedHelp = String(localized: "settings.mcp.untrusted-help", defaultValue: "Untrusted. Always-Allow rules ignored — every call gates.")
            static func markedTrusted(_ a1: String) -> String {
                let template = String(localized: "settings.mcp.marked-trusted", defaultValue: "Marked %@ as trusted.")
                return String(format: template, a1)
            }
            static func markedUntrusted(_ a1: String) -> String {
                let template = String(localized: "settings.mcp.marked-untrusted", defaultValue: "Marked %@ as untrusted. Always-Allow rules will be ignored for it.")
                return String(format: template, a1)
            }
            static let trustLevelFull = String(localized: "settings.mcp.trust-level-full", defaultValue: "Fully trusted — all calls auto-run")
            static let trustLevelStandard = String(localized: "settings.mcp.trust-level-standard", defaultValue: "Default — read-style calls auto-run, writes ask")
            static let trustLevelUntrusted = String(localized: "settings.mcp.trust-level-untrusted", defaultValue: "Untrusted — every call asks")
            static let trustLevelHelp = String(localized: "settings.mcp.trust-level-help", defaultValue: "Trust level for this server's tool calls")
            static func markedFullyTrusted(_ a1: String) -> String {
                let template = String(localized: "settings.mcp.marked-fully-trusted", defaultValue: "Marked %@ as fully trusted. All its calls now auto-run — writes included.")
                return String(format: template, a1)
            }
            static let refreshTools = String(localized: "settings.mcp.refresh-tools", defaultValue: "Refresh Tools")
            static let delete = String(localized: "settings.mcp.delete", defaultValue: "Delete")
            static func headersPrefix(_ a1: String) -> String {
                let template = String(localized: "settings.mcp.headers-prefix", defaultValue: "headers: %@")
                return String(format: template, a1)
            }
            static func lastChecked(_ a1: String) -> String {
                let template = String(localized: "settings.mcp.last-checked", defaultValue: "Last checked: %@")
                return String(format: template, a1)
            }
            static func failedPrefix(_ a1: String) -> String {
                let template = String(localized: "settings.mcp.failed-prefix", defaultValue: "Failed: %@")
                return String(format: template, a1)
            }
            static let openedCursorConfig = String(localized: "settings.mcp.opened-cursor-config", defaultValue: "Opened Cursor mcp.json.")
            static let cursorConfigMissing = String(localized: "settings.mcp.cursor-config-missing", defaultValue: "Cursor mcp.json does not exist yet.")
            static func createdServer(_ a1: String) -> String {
                let template = String(localized: "settings.mcp.created-server", defaultValue: "Created %@.")
                return String(format: template, a1)
            }
            static func deletedServer(_ a1: String) -> String {
                let template = String(localized: "settings.mcp.deleted-server", defaultValue: "Deleted %@.")
                return String(format: template, a1)
            }
            static func authCleared(_ a1: String) -> String {
                let template = String(localized: "settings.mcp.auth-cleared", defaultValue: "Authorization header cleared for %@.")
                return String(format: template, a1)
            }
            static let newServerTitle = String(localized: "settings.mcp.new-server-title", defaultValue: "New MCP Server")
            static let serverNamePlaceholder = String(localized: "settings.mcp.server-name-placeholder", defaultValue: "Server name")
            static let transportLabel = String(localized: "settings.mcp.transport", defaultValue: "Transport")
            static let urlPlaceholder = String(localized: "settings.mcp.url-placeholder", defaultValue: "https://example.com/mcp")
            static let headersLabel = String(localized: "settings.mcp.headers", defaultValue: "Headers")
            static let headersHint = String(localized: "settings.mcp.headers-hint", defaultValue: "One header per line, for example: Authorization=Bearer ...")
            static let commandPathPlaceholder = String(localized: "settings.mcp.command-path-placeholder", defaultValue: "/absolute/path/to/server")
            static let argsPlaceholder = String(localized: "settings.mcp.args-placeholder", defaultValue: "Arguments separated by spaces")
            static let environmentLabel = String(localized: "settings.mcp.environment", defaultValue: "Environment")
            static let environmentHint = String(localized: "settings.mcp.environment-hint", defaultValue: "One variable per line, for example: HTTPS_PROXY=http://127.0.0.1:7890")
            static let timeoutLabel = String(localized: "settings.mcp.timeout", defaultValue: "Timeout")
            static let cancelButton = String(localized: "settings.mcp.cancel", defaultValue: "Cancel")
            static let createButton = String(localized: "settings.mcp.create", defaultValue: "Create")
            static let errorServerNameRequired = String(localized: "settings.mcp.error-server-name", defaultValue: "Server name is required.")
            static let errorValidURLRequired = String(localized: "settings.mcp.error-valid-url", defaultValue: "A valid server URL is required.")
            static let errorCommandRequired = String(localized: "settings.mcp.error-command-required", defaultValue: "Command is required.")
        }

        enum Replicate {
            static let clearButton = String(localized: "settings.replicate.clear", defaultValue: "Clear")
            static let envConfigured = String(localized: "settings.replicate.env-configured", defaultValue: "Configured via the REPLICATE_API_TOKEN environment variable")
            static let configured = String(localized: "settings.replicate.configured", defaultValue: "Replicate is configured")
            static let notConfigured = String(localized: "settings.replicate.not-configured", defaultValue: "Replicate is not configured")
            static let tokenDescription = String(localized: "settings.replicate.token-description", defaultValue: "Used for Replicate image upscale, erase, inpaint, and video/image prediction tasks. The token is stored in Keychain and never written to chats, logs, or commits.")
            static let workflowSection = String(localized: "settings.replicate.workflow-section", defaultValue: "Default Workflow Versions")
            static let upscaleLabel = String(localized: "settings.replicate.upscale", defaultValue: "Image upscale")
            static let eraseLabel = String(localized: "settings.replicate.erase", defaultValue: "Image erase")
            static let inpaintLabel = String(localized: "settings.replicate.inpaint", defaultValue: "Mask inpaint")
            static let versionPlaceholder = String(localized: "settings.replicate.version-placeholder", defaultValue: "Replicate version hash")
            static let workflowDescription = String(localized: "settings.replicate.workflow-description", defaultValue: "With common model version hashes filled in, media-task thumbnails can start an upscale directly, and the image edit panel reuses the default inpaint version.")
        }

        enum Connectors {
            static let description = String(localized: "settings.connectors.description", defaultValue: "Manage team collaboration platforms that WillDeep can use for notifications, commands, and document publishing.")
            static let replicateSummary = String(localized: "settings.connectors.replicate-summary", defaultValue: "Image upscale, erase, inpaint, and prediction tasks. Token stays in Keychain.")
            static let statusConfigured = String(localized: "settings.connectors.status-configured", defaultValue: "Configured")
            static let statusNotConfigured = String(localized: "settings.connectors.status-not-configured", defaultValue: "Not configured")
            static let platformsSection = String(localized: "settings.connectors.platforms-section", defaultValue: "Platforms")
            static let capabilitiesSection = String(localized: "settings.connectors.capabilities-section", defaultValue: "Capabilities")
            static let safetySection = String(localized: "settings.connectors.safety-section", defaultValue: "Safety")
            static let experimentalBadge = String(localized: "settings.connectors.experimental", defaultValue: "Experimental")
            static let enabledToggle = String(localized: "settings.connectors.enabled-toggle", defaultValue: "Enable connector")
            static let authModeLabel = String(localized: "settings.connectors.auth-mode", defaultValue: "Authorization")
            static let connectionStateLabel = String(localized: "settings.connectors.connection-state", defaultValue: "State")
            static let appIDLabel = String(localized: "settings.connectors.app-id", defaultValue: "App ID")
            static let appIDPrompt = String(localized: "settings.connectors.app-id-prompt", defaultValue: "Platform app_id / client_id")
            static let tenantIDLabel = String(localized: "settings.connectors.tenant-id", defaultValue: "Tenant / Corp ID")
            static let tenantIDPrompt = String(localized: "settings.connectors.tenant-id-prompt", defaultValue: "Optional enterprise identifier")
            static let redirectURILabel = String(localized: "settings.connectors.redirect-uri", defaultValue: "Redirect URI")
            static let redirectURIPrompt = String(localized: "settings.connectors.redirect-uri-prompt", defaultValue: "https://fly.niuwoai.com/oauth/<platform>/callback")
            static let authorizationURLLabel = String(localized: "settings.connectors.authorization-url", defaultValue: "Authorization URL")
            static let authorizationURLPrompt = String(localized: "settings.connectors.authorization-url-prompt", defaultValue: "https://... or URL with {client_id}, {redirect_uri}, {state}")
            static let credentialReferenceLabel = String(localized: "settings.connectors.credential-reference", defaultValue: "Credential reference")
            static let credentialReferencePrompt = String(localized: "settings.connectors.credential-reference-prompt", defaultValue: "Keychain item or env name, not the secret itself")
            static let defaultSpaceLabel = String(localized: "settings.connectors.default-space", defaultValue: "Default doc space")
            static let defaultSpacePrompt = String(localized: "settings.connectors.default-space-prompt", defaultValue: "Folder, wiki, or drive token")
            static let defaultChatLabel = String(localized: "settings.connectors.default-chat", defaultValue: "Default chat")
            static let defaultChatPrompt = String(localized: "settings.connectors.default-chat-prompt", defaultValue: "Group, robot, or conversation ID")
            static let writePolicyLabel = String(localized: "settings.connectors.write-policy", defaultValue: "Write policy")
            static let cloudRelayToggle = String(localized: "settings.connectors.cloud-relay", defaultValue: "Use WillDeep Cloud Relay for incoming events")
            static let cloudRelayDescription = String(localized: "settings.connectors.cloud-relay-description", defaultValue: "Incoming @mentions need a public callback. Cloud Relay can receive platform events and forward them to this Mac when it is online.")
            static let secretStorageNote = String(localized: "settings.connectors.secret-storage-note", defaultValue: "Secrets and OAuth tokens should live in macOS Keychain. This panel stores only non-sensitive routing metadata.")
            static let authorizationURLHelp = String(localized: "settings.connectors.authorization-url-help", defaultValue: "Leave empty to only prepare the callback and Keychain reference. When filled, WillDeep appends standard OAuth query parameters unless placeholders are present.")
            static let prepareAuthorization = String(localized: "settings.connectors.prepare-authorization", defaultValue: "Prepare authorization")
            static let generateQRCode = String(localized: "settings.connectors.generate-qr-code", defaultValue: "Generate QR code")
            static let openAuthorization = String(localized: "settings.connectors.open-authorization", defaultValue: "Open authorization")
            static let copyAuthorizationURL = String(localized: "settings.connectors.copy-authorization-url", defaultValue: "Copy authorization URL")
            static let copyRedirectURI = String(localized: "settings.connectors.copy-redirect-uri", defaultValue: "Copy redirect URI")
            static let clearCredentials = String(localized: "settings.connectors.clear-credentials", defaultValue: "Clear credentials")
            static let openDocs = String(localized: "settings.connectors.open-docs", defaultValue: "Open docs")
            static let advancedConfiguration = String(localized: "settings.connectors.advanced-configuration", defaultValue: "Advanced configuration")
            static let larkCLIConfigureApp = String(localized: "settings.connectors.lark-cli.configure-app", defaultValue: "Configure app")
            static let larkCLILogin = String(localized: "settings.connectors.lark-cli.login", defaultValue: "Login")
            static let larkCLIInstall = String(localized: "settings.connectors.lark-cli.install", defaultValue: "Install lark-cli")
            static let larkCLIVerify = String(localized: "settings.connectors.lark-cli.verify", defaultValue: "Verify status")
            static let larkCLIHelp = String(localized: "settings.connectors.lark-cli.help", defaultValue: "Official lark-cli is the recommended local bridge for active Feishu operations. It stores credentials in the OS keychain and lets WillDeep call Feishu with structured commands instead of raw shell.")
            static let larkCLINotInstalled = String(localized: "settings.connectors.lark-cli.not-installed", defaultValue: "lark-cli not found")
            static let larkCLIInstalling = String(localized: "settings.connectors.lark-cli.installing", defaultValue: "Installing official lark-cli...")
            static let larkCLIInstallSucceeded = String(localized: "settings.connectors.lark-cli.install-succeeded", defaultValue: "Official lark-cli installed.")
            static let larkCLIConfigStarted = String(localized: "settings.connectors.lark-cli.config-started", defaultValue: "Starting lark-cli app configuration...")
            static let larkCLIConfigFinished = String(localized: "settings.connectors.lark-cli.config-finished", defaultValue: "lark-cli app configuration finished.")
            static let larkCLILoginStarted = String(localized: "settings.connectors.lark-cli.login-started", defaultValue: "Starting lark-cli login...")
            static let larkCLILoginFinished = String(localized: "settings.connectors.lark-cli.login-finished", defaultValue: "lark-cli login command finished.")
            static let larkCLIVerifying = String(localized: "settings.connectors.lark-cli.verifying", defaultValue: "Checking lark-cli authorization...")
            static let larkCLIVerified = String(localized: "settings.connectors.lark-cli.verified", defaultValue: "lark-cli authorization verified.")
            static let larkCLIQRCodeReady = String(localized: "settings.connectors.lark-cli.qr-ready", defaultValue: "lark-cli authorization QR code is ready.")
            static let dingtalkMCPConfigure = String(localized: "settings.connectors.dingtalk-mcp.configure", defaultValue: "Configure official MCP")
            static let dingtalkMCPHelp = String(localized: "settings.connectors.dingtalk-mcp.help", defaultValue: "DingTalk does not currently expose a lark-cli-style official CLI. Use the official DingTalk MCP server as the preferred local tool bridge; event intake can still use Stream SDK or relay callbacks.")
            static let dingtalkMCPCapability = String(localized: "settings.connectors.dingtalk-mcp.capability", defaultValue: "DingTalk official MCP tools")
            static let dingtalkMCPInstallHint = String(localized: "settings.connectors.dingtalk-mcp.install-hint", defaultValue: "Uses stdio: npx -y dingtalk-mcp@latest. Fill DINGTALK_Client_ID and DINGTALK_Client_Secret from the DingTalk developer console; keep secrets out of git.")
            static let dingtalkMCPReason = String(localized: "settings.connectors.dingtalk-mcp.reason", defaultValue: "DingTalk's practical official integration path is MCP for active tool calls, plus Stream SDK or relay callbacks for incoming events.")
            static let dingtalkMCPDraftOpened = String(localized: "settings.connectors.dingtalk-mcp.draft-opened", defaultValue: "Opened DingTalk MCP setup draft.")
            static let feishuDocsNote = String(localized: "settings.connectors.feishu-docs-note", defaultValue: "Feishu document writing is feasible through OpenAPI after OAuth scopes are granted. WillDeep should preview generated docs before publishing.")
            static let feishuQRCodeHelp = String(localized: "settings.connectors.feishu-qr-help", defaultValue: "Scan this QR code with Feishu to configure WillDeep. Custom App ID setup is available under Advanced configuration.")
            static let feishuQRCodeReady = String(localized: "settings.connectors.feishu-qr-ready", defaultValue: "Ready to scan with Feishu")
            static let feishuQRCodeAccessibilityLabel = String(localized: "settings.connectors.feishu-qr-accessibility-label", defaultValue: "Feishu authorization QR code")
            static let feishuQRCodeUnavailable = String(localized: "settings.connectors.feishu-qr-unavailable", defaultValue: "Authorization QR code unavailable")
            static let feishuQRCodePlaceholderTitle = String(localized: "settings.connectors.feishu-qr-placeholder-title", defaultValue: "No authorization QR yet")
            static let feishuQRCodePlaceholderDescription = String(localized: "settings.connectors.feishu-qr-placeholder-description", defaultValue: "WillDeep prepares a short-lived setup link when this panel opens.")

            static let platformFeishu = String(localized: "settings.connectors.platform.feishu", defaultValue: "Feishu")
            static let platformDingTalk = String(localized: "settings.connectors.platform.dingtalk", defaultValue: "DingTalk")
            static let platformWeCom = String(localized: "settings.connectors.platform.wecom", defaultValue: "WeCom")
            static let platformWechatClaw = String(localized: "settings.connectors.platform.wechat-claw", defaultValue: "WeChat / Claw")
            static let summaryFeishu = String(localized: "settings.connectors.summary.feishu", defaultValue: "Best first target for OAuth, bots, and AI-generated docs.")
            static let summaryDingTalk = String(localized: "settings.connectors.summary.dingtalk", defaultValue: "Good for enterprise bots, approvals, and operational notifications.")
            static let summaryWeCom = String(localized: "settings.connectors.summary.wecom", defaultValue: "Official bridge for WeChat-style enterprise messaging.")
            static let summaryWechatClaw = String(localized: "settings.connectors.summary.wechat-claw", defaultValue: "Desktop automation bridge for personal workflows; keep it out of production defaults.")

            static let authWebhook = String(localized: "settings.connectors.auth.webhook", defaultValue: "Webhook")
            static let authOfficialLarkCLI = String(localized: "settings.connectors.auth.official-lark-cli", defaultValue: "Official lark-cli")
            static let authOfficialMCP = String(localized: "settings.connectors.auth.official-mcp", defaultValue: "Official MCP")
            static let authOAuth = String(localized: "settings.connectors.auth.oauth", defaultValue: "OAuth")
            static let authCloudRelay = String(localized: "settings.connectors.auth.cloud-relay", defaultValue: "Cloud Relay")
            static let authDesktopAutomation = String(localized: "settings.connectors.auth.desktop-automation", defaultValue: "Desktop automation")
            static let authWebhookHelp = String(localized: "settings.connectors.auth.webhook-help", defaultValue: "One-way robot messages and simple slash-like workflows. Fast to set up, limited user context.")
            static let authOfficialLarkCLIHelp = String(localized: "settings.connectors.auth.official-lark-cli-help", defaultValue: "Use Feishu/Lark's official CLI for local app setup, OAuth login, and active docs/messages/calendar operations.")
            static let authOfficialMCPHelp = String(localized: "settings.connectors.auth.official-mcp-help", defaultValue: "Use the platform's official MCP server as the active tool bridge. Credentials still need explicit user configuration.")
            static let authOAuthHelp = String(localized: "settings.connectors.auth.oauth-help", defaultValue: "User-authorized access for docs, drive, chat, and future write actions. Tokens belong in Keychain.")
            static let authCloudRelayHelp = String(localized: "settings.connectors.auth.cloud-relay-help", defaultValue: "Public event callbacks land in WillDeep Cloud Relay, then forward to the Mac app.")
            static let authDesktopAutomationHelp = String(localized: "settings.connectors.auth.desktop-automation-help", defaultValue: "Local GUI automation for personal workflows. Useful as a fallback, fragile for teams.")

            static let stateNotConfigured = String(localized: "settings.connectors.state.not-configured", defaultValue: "Not configured")
            static let stateReady = String(localized: "settings.connectors.state.ready", defaultValue: "Ready to authorize")
            static let stateConnected = String(localized: "settings.connectors.state.connected", defaultValue: "Connected")
            static let stateNeedsReview = String(localized: "settings.connectors.state.needs-review", defaultValue: "Needs review")

            static let capabilitySendMessages = String(localized: "settings.connectors.capability.send-messages", defaultValue: "Send messages")
            static let capabilityReceiveCommands = String(localized: "settings.connectors.capability.receive-commands", defaultValue: "Receive @mentions and commands")
            static let capabilityCreateDocs = String(localized: "settings.connectors.capability.create-docs", defaultValue: "Create documents")
            static let capabilityEditDocs = String(localized: "settings.connectors.capability.edit-docs", defaultValue: "Edit existing documents")
            static let capabilityImportDocs = String(localized: "settings.connectors.capability.import-docs", defaultValue: "Import documents as context")
            static let capabilityCalendar = String(localized: "settings.connectors.capability.calendar", defaultValue: "Calendar context")
            static let capabilityTasks = String(localized: "settings.connectors.capability.tasks", defaultValue: "Tasks")
            static let capabilityApprovals = String(localized: "settings.connectors.capability.approvals", defaultValue: "Approvals")
            static let capabilityDesktopAutomation = String(localized: "settings.connectors.capability.desktop-automation", defaultValue: "Desktop automation")

            static let policyPreviewThenPublish = String(localized: "settings.connectors.policy.preview-then-publish", defaultValue: "Preview before publish")
            static let policyAskEveryTime = String(localized: "settings.connectors.policy.ask-every-time", defaultValue: "Ask every time")
            static let policyAllowNewDocs = String(localized: "settings.connectors.policy.allow-new-docs", defaultValue: "Allow new docs only")

            static func enabledCount(_ a1: String, _ a2: String) -> String {
                let template = String(localized: "settings.connectors.enabled-count", defaultValue: "%1$@ of %2$@ connectors enabled")
                return String(format: template, a1, a2)
            }
            static func configurationSection(_ a1: String) -> String {
                let template = String(localized: "settings.connectors.configuration-section", defaultValue: "%@ Configuration")
                return String(format: template, a1)
            }
            static func statusLine(_ a1: String, _ a2: String, _ a3: String) -> String {
                let template = String(localized: "settings.connectors.status-line", defaultValue: "%1$@ · %2$@ · %3$@ capabilities")
                return String(format: template, a1, a2, a3)
            }
            static func authorizationPrepared(_ a1: String) -> String {
                let template = String(localized: "settings.connectors.authorization-prepared", defaultValue: "%@ is ready for OAuth wiring.")
                return String(format: template, a1)
            }
            static func authorizationOpened(_ a1: String) -> String {
                let template = String(localized: "settings.connectors.authorization-opened", defaultValue: "%@ authorization page opened.")
                return String(format: template, a1)
            }
            static func authorizationQRCodeReady(_ a1: String) -> String {
                let template = String(localized: "settings.connectors.authorization-qr-ready", defaultValue: "%@ authorization QR code is ready.")
                return String(format: template, a1)
            }
            static func authorizationURLCopied(_ a1: String) -> String {
                let template = String(localized: "settings.connectors.authorization-url-copied", defaultValue: "%@ authorization URL copied.")
                return String(format: template, a1)
            }
            static func authorizationNeedsAppID(_ a1: String) -> String {
                let template = String(localized: "settings.connectors.authorization-needs-app-id", defaultValue: "Add an App ID before preparing %@ authorization.")
                return String(format: template, a1)
            }
            static func redirectURICopied(_ a1: String) -> String {
                let template = String(localized: "settings.connectors.redirect-uri-copied", defaultValue: "%@ redirect URI copied.")
                return String(format: template, a1)
            }
            static func credentialsCleared(_ a1: String) -> String {
                let template = String(localized: "settings.connectors.credentials-cleared", defaultValue: "%@ local credentials cleared.")
                return String(format: template, a1)
            }
            static func larkCLIInstalled(_ a1: String) -> String {
                let template = String(localized: "settings.connectors.lark-cli.installed", defaultValue: "Installed: %@")
                return String(format: template, a1)
            }
            static func larkCLICommandFailed(_ a1: String) -> String {
                let template = String(localized: "settings.connectors.lark-cli.command-failed", defaultValue: "lark-cli failed: %@")
                return String(format: template, a1)
            }
        }

        enum Skill {
            static let autoExtractSection = String(localized: "settings.skill.auto-extract-section", defaultValue: "Automatic Skill Extraction")
            static let autoExtractTitle = String(localized: "settings.skill.auto-extract-title", defaultValue: "Auto-extract reusable skills from conversations")
            static let autoExtractDescription = String(localized: "settings.skill.auto-extract-description", defaultValue: "When enabled, WillDeep can surface reusable workflows as skill candidates.")
            static let minimumToolCallsLabel = String(localized: "settings.skill.minimum-tool-calls", defaultValue: "Minimum tool calls")
            static let minimumToolCallsHint = String(localized: "settings.skill.minimum-tool-calls-hint", defaultValue: "Conversations with fewer tool calls are skipped.")
            static let marketplaceSection = String(localized: "settings.skill.marketplace-section", defaultValue: "Skill Marketplace")
            static let marketplaceDescription = String(localized: "settings.skill.marketplace-description", defaultValue: "Install first-party skills from the bundled static catalog. A server-backed marketplace can replace this catalog later.")
            static let marketplaceInstall = String(localized: "settings.skill.marketplace-install", defaultValue: "Install")
            static let marketplaceInstalled = String(localized: "settings.skill.marketplace-installed", defaultValue: "Installed")
            static let marketplaceUpdate = String(localized: "settings.skill.marketplace-update", defaultValue: "Update")
            static let marketplaceUninstall = String(localized: "settings.skill.marketplace-uninstall", defaultValue: "Uninstall")
            static let marketplaceConflictLabel = String(localized: "settings.skill.marketplace-conflict-label", defaultValue: "Name conflict")
            static let marketplaceNoResults = String(localized: "settings.skill.marketplace-no-results", defaultValue: "No marketplace skills match the current search.")
            static let marketplaceStaticSource = String(localized: "settings.skill.marketplace-static-source", defaultValue: "Static catalog")
            static let marketplaceCredentialConfigured = String(localized: "settings.skill.marketplace-credential-configured", defaultValue: "Configured")
            static let marketplaceCredentialRequired = String(localized: "settings.skill.marketplace-credential-required", defaultValue: "Required")
            static let marketplaceCredentialClear = String(localized: "settings.skill.marketplace-credential-clear", defaultValue: "Clear")
            static let marketplaceInvalidSkill = String(localized: "settings.skill.marketplace-invalid-skill", defaultValue: "Marketplace skill name is invalid.")
            static func marketplaceCount(_ a1: String) -> String {
                let template = String(localized: "settings.skill.marketplace-count", defaultValue: "%@ marketplace skills")
                return String(format: template, a1)
            }
            static func marketplaceCredentialCleared(_ a1: String) -> String {
                let template = String(localized: "settings.skill.marketplace-credential-cleared", defaultValue: "Cleared %@.")
                return String(format: template, a1)
            }
            static func marketplaceVersion(_ a1: String) -> String {
                let template = String(localized: "settings.skill.marketplace-version", defaultValue: "v%@")
                return String(format: template, a1)
            }
            static func marketplaceMinimumVersion(_ a1: String) -> String {
                let template = String(localized: "settings.skill.marketplace-minimum-version", defaultValue: "Requires WillDeep %@+")
                return String(format: template, a1)
            }
            static func marketplaceInstalledStatus(_ a1: String) -> String {
                let template = String(localized: "settings.skill.marketplace-installed-status", defaultValue: "Installed %@")
                return String(format: template, a1)
            }
            static func marketplaceUpdateStatus(_ a1: String, _ a2: String) -> String {
                let template = String(localized: "settings.skill.marketplace-update-status", defaultValue: "Installed %@ · Latest %@")
                return String(format: template, a1, a2)
            }
            static func marketplaceInstalledMessage(_ a1: String) -> String {
                let template = String(localized: "settings.skill.marketplace-installed-message", defaultValue: "Installed %@.")
                return String(format: template, a1)
            }
            static func marketplaceUpdatedMessage(_ a1: String) -> String {
                let template = String(localized: "settings.skill.marketplace-updated-message", defaultValue: "Updated %@.")
                return String(format: template, a1)
            }
            static func marketplaceUninstalledMessage(_ a1: String) -> String {
                let template = String(localized: "settings.skill.marketplace-uninstalled-message", defaultValue: "Uninstalled %@.")
                return String(format: template, a1)
            }
            static func marketplaceConflict(_ a1: String) -> String {
                let template = String(localized: "settings.skill.marketplace-conflict", defaultValue: "A user skill named %@ already exists. Rename or remove it before installing this marketplace skill.")
                return String(format: template, a1)
            }
            static func marketplaceMissing(_ a1: String) -> String {
                let template = String(localized: "settings.skill.marketplace-missing", defaultValue: "Marketplace skill %@ is not installed.")
                return String(format: template, a1)
            }
            static func availableCount(_ a1: String, _ a2: String) -> String {
                let template = String(localized: "settings.skill.available-count", defaultValue: "%1$@ of %2$@ skills available")
                return String(format: template, a1, a2)
            }
            static let refresh = String(localized: "settings.skill.refresh", defaultValue: "Refresh")
            static let openFolder = String(localized: "settings.skill.open-folder", defaultValue: "Open Folder")
            static let newSkill = String(localized: "settings.skill.new-skill", defaultValue: "New Skill")
            static let searchPlaceholder = String(localized: "settings.skill.search-placeholder", defaultValue: "Search by skill name, description, or path...")
            static let builtInSkills = String(localized: "settings.skill.built-in", defaultValue: "Built-in Skills")
            static let userSkills = String(localized: "settings.skill.user", defaultValue: "User Skills")
            static let pluginSkills = String(localized: "settings.skill.plugin", defaultValue: "Plugin Skills")
            static let noSkills = String(localized: "settings.skill.no-skills", defaultValue: "No skills in this group.")
            static let viewContent = String(localized: "settings.skill.view-content", defaultValue: "View content")
            static let unableToRead = String(localized: "settings.skill.unable-to-read", defaultValue: "Unable to read skill content.")
            static let loadingContent = String(localized: "settings.skill.loading-content", defaultValue: "Loading…")
            static let previousPage = String(localized: "settings.skill.previous-page", defaultValue: "Previous")
            static let nextPage = String(localized: "settings.skill.next-page", defaultValue: "Next")
            static func pageIndicator(_ page: String, _ total: String) -> String {
                let template = String(localized: "settings.skill.page-indicator", defaultValue: "Page %1$@ of %2$@")
                return String(format: template, locale: Locale.current, page, total)
            }
            static let deleteUserSkill = String(localized: "settings.skill.delete-user-skill", defaultValue: "Delete")
            static let deleteUserSkillHelp = String(localized: "settings.skill.delete-user-skill-help", defaultValue: "Delete this user skill")
            static let deleteUserSkillMessage = String(localized: "settings.skill.delete-user-skill-message", defaultValue: "This removes the user skill folder from disk. Built-in and plugin skills are not affected.")
            static let deleteUserSkillConfirm = String(localized: "settings.skill.delete-user-skill-confirm", defaultValue: "Delete")
            static let newUserSkillTitle = String(localized: "settings.skill.new-user-skill", defaultValue: "New User Skill")
            static let skillNamePlaceholder = String(localized: "settings.skill.name-placeholder", defaultValue: "Skill name")
            static let descriptionPlaceholder = String(localized: "settings.skill.description-placeholder", defaultValue: "Description")
            static let cancelButton = String(localized: "settings.skill.cancel", defaultValue: "Cancel")
            static let createButton = String(localized: "settings.skill.create", defaultValue: "Create")
            static let defaultBody = String(localized: "settings.skill.default-body", defaultValue: "Describe when and how the Agent should use this skill.")
            static let openedFolder = String(localized: "settings.skill.opened-folder", defaultValue: "Opened user skills folder.")
            static func createdSkill(_ a1: String) -> String {
                let template = String(localized: "settings.skill.created", defaultValue: "Created %@.")
                return String(format: template, a1)
            }
            static func deleteUserSkillTitle(_ a1: String) -> String {
                let template = String(localized: "settings.skill.delete-user-skill-title", defaultValue: "Delete %@?")
                return String(format: template, a1)
            }
            static func deletedUserSkill(_ a1: String) -> String {
                let template = String(localized: "settings.skill.deleted-user-skill", defaultValue: "Deleted %@.")
                return String(format: template, a1)
            }
            static func deleteUserSkillFailed(_ a1: String) -> String {
                let template = String(localized: "settings.skill.delete-user-skill-failed", defaultValue: "Could not delete skill: %@")
                return String(format: template, a1)
            }
        }

        enum Memory {
            static let featuresSection = String(localized: "settings.memory.features-section", defaultValue: "Memory Features")
            static let enableToggle = String(localized: "settings.memory.enable", defaultValue: "Enable memory")
            static let enableDescription = String(localized: "settings.memory.enable-description", defaultValue: "When enabled, the Agent can use saved preferences, recurring facts, and project notes as personalization context.")
            static let retrievalSection = String(localized: "settings.memory.retrieval-section", defaultValue: "Memory Retrieval")
            static let autoRetrievalToggle = String(localized: "settings.memory.auto-retrieval", defaultValue: "Auto-retrieve memories")
            static let autoRetrievalDescription = String(localized: "settings.memory.auto-retrieval-description", defaultValue: "Automatically search related memories before each Agent turn and inject the best matches as compact context.")
            static let queryRewriteToggle = String(localized: "settings.memory.query-rewrite", defaultValue: "Rewrite retrieval query")
            static let queryRewriteDescription = String(localized: "settings.memory.query-rewrite-description", defaultValue: "Use the tool model to turn conversational wording into a focused semantic search query.")
            static let maxRetrievedLabel = String(localized: "settings.memory.max-retrieved", defaultValue: "Max retrieved memories")
            static let similarityThresholdLabel = String(localized: "settings.memory.similarity-threshold", defaultValue: "Similarity threshold")
            static let similarityBroad = String(localized: "settings.memory.similarity-broad", defaultValue: "Broad (0%)")
            static let similarityStrict = String(localized: "settings.memory.similarity-strict", defaultValue: "Strict (100%)")
            static let summariesSection = String(localized: "settings.memory.summaries-section", defaultValue: "Memory Summaries")
            static let autoSummaryToggle = String(localized: "settings.memory.auto-summary", defaultValue: "Auto-summarize conversations")
            static let autoSummaryDescription = String(localized: "settings.memory.auto-summary-description", defaultValue: "Extract durable facts from conversations and save them as candidate memories.")
            static let maintenanceSection = String(localized: "settings.memory.maintenance-section", defaultValue: "Memory Maintenance")
            static let dailyMaintenanceToggle = String(localized: "settings.memory.daily-maintenance", defaultValue: "Run daily memory maintenance")
            static let maintenanceDescription = String(localized: "settings.memory.maintenance-description", defaultValue: "Archives duplicate or stale transient entries, removes expired archived entries, and records the last maintenance result.")
            static let runMaintenanceButton = String(localized: "settings.memory.run-maintenance", defaultValue: "Run maintenance cycle")
            static let previewMaintenanceButton = String(localized: "settings.memory.preview-maintenance", defaultValue: "Preview next cycle")
            static let triggerTimeLabel = String(localized: "settings.memory.trigger-time", defaultValue: "Trigger time")
            static let transientTTLLabel = String(localized: "settings.memory.transient-ttl", defaultValue: "Transient memory TTL")
            static let archiveRetentionLabel = String(localized: "settings.memory.archive-retention", defaultValue: "Archive retention")
            static func daysFormat(_ a1: String) -> String {
                let template = String(localized: "settings.memory.days-format", defaultValue: "%@ days")
                return String(format: template, a1)
            }
            static let mergeParametersLabel = String(localized: "settings.memory.merge-parameters", defaultValue: "Similarity and merge parameters")
            static let mergeParametersDescription = String(localized: "settings.memory.merge-parameters-description", defaultValue: "The current local maintenance pass handles retention and archiving. LLM-assisted duplicate merging can be wired into this section once the Agent memory retrieval pipeline starts consuming embeddings.")
            static func archivedMemoriesLabel(_ a1: String) -> String {
                let template = String(localized: "settings.memory.archived-label", defaultValue: "Archived memories (%@)")
                return String(format: template, a1)
            }
            static let noArchivedMemories = String(localized: "settings.memory.no-archived", defaultValue: "No archived memories.")
            static let exportSnapshotButton = String(localized: "settings.memory.export-snapshot", defaultValue: "Export memory snapshot")
            static let toolModelSection = String(localized: "settings.memory.tool-model-section", defaultValue: "Memory Tool Model")
            static let toolModelLabel = String(localized: "settings.memory.tool-model", defaultValue: "Tool model")
            static let useActiveAgentModel = String(localized: "settings.memory.use-active-agent-model", defaultValue: "Use active Agent model")
            static let toolModelDescription = String(localized: "settings.memory.tool-model-description", defaultValue: "Used for query rewriting and future LLM-assisted memory maintenance. Leave blank to follow the active Agent model.")
            static let embeddingSection = String(localized: "settings.memory.embedding-section", defaultValue: "Embedding Model")
            static let embeddingPlaceholder = String(localized: "settings.memory.embedding-placeholder", defaultValue: "Embedding model")
            static let embeddingDescription = String(localized: "settings.memory.embedding-description", defaultValue: "Used for semantic retrieval. Leave the default unless your provider exposes a compatible embedding model.")
            static let statisticsSection = String(localized: "settings.memory.statistics-section", defaultValue: "Statistics")
            static let totalMemoriesLabel = String(localized: "settings.memory.total-memories", defaultValue: "Total memories")
            static let autoGeneratedLabel = String(localized: "settings.memory.auto-generated", defaultValue: "Auto-generated")
            static let manualLabel = String(localized: "settings.memory.manual", defaultValue: "Manual")
            static let addMemorySection = String(localized: "settings.memory.add-memory-section", defaultValue: "Add Memory")
            static let lifetimeLabel = String(localized: "settings.memory.lifetime", defaultValue: "Lifetime")
            static let scopeLabel = String(localized: "settings.memory.scope", defaultValue: "Scope")
            static let projectScopeRequiresWorkspace = String(localized: "settings.memory.project-scope-requires-workspace", defaultValue: "Open a workspace before saving a project-scoped memory.")
            static let addMemoryButton = String(localized: "settings.memory.add-memory", defaultValue: "Add memory")
            static let searchSection = String(localized: "settings.memory.search-section", defaultValue: "Search Memories")
            static let searchPlaceholder = String(localized: "settings.memory.search-placeholder", defaultValue: "Search by text...")
            static let includeArchivedToggle = String(localized: "settings.memory.include-archived", defaultValue: "Include archived")
            static func shownCount(_ a1: String) -> String {
                let template = String(localized: "settings.memory.shown-count", defaultValue: "%@ shown")
                return String(format: template, a1)
            }
            static let resetSearchButton = String(localized: "settings.memory.reset-search", defaultValue: "Reset search")
            static let clearAllButton = String(localized: "settings.memory.clear-all", defaultValue: "Clear all")
            static let noMemoriesMatching = String(localized: "settings.memory.no-matching", defaultValue: "No memories match the current filters.")
            static let memoryListSection = String(localized: "settings.memory.memory-list-section", defaultValue: "Memory List")
            static let dailySleepCycleTitle = String(localized: "settings.memory.daily-sleep-cycle", defaultValue: "Daily sleep cycle")
            static func headerSummary(_ a1: String, _ a2: String) -> String {
                let template = String(localized: "settings.memory.header-summary", defaultValue: "Archived %1$@ · Next: %2$@")
                return String(format: template, a1, a2)
            }
            static let notScheduled = String(localized: "settings.memory.not-scheduled", defaultValue: "Not scheduled")
            static func lastStatus(_ a1: String) -> String {
                let template = String(localized: "settings.memory.last-status", defaultValue: "Last: %@")
                return String(format: template, a1)
            }
            static func maintenanceCounts(_ a1: String, _ a2: String, _ a3: String, _ a4: String) -> String {
                let template = String(localized: "settings.memory.maintenance-counts", defaultValue: "Inspected %1$@, archived %2$@, removed %3$@, merged %4$@.")
                return String(format: template, a1, a2, a3, a4)
            }
            static func tokensLine(_ a1: String, _ a2: String) -> String {
                let template = String(localized: "settings.memory.tokens-line", defaultValue: "LLM tokens: %1$@ input / %2$@ output")
                return String(format: template, a1, a2)
            }
            static func usedXTimes(_ a1: String) -> String {
                let template = String(localized: "settings.memory.used-x-times", defaultValue: "Used %@x")
                return String(format: template, a1)
            }
            static func confidenceTag(_ a1: String) -> String {
                let template = String(localized: "settings.memory.confidence-tag", defaultValue: "%@%% confidence")
                return String(format: template, a1)
            }
            static let sensitiveTag = String(localized: "settings.memory.sensitive-tag", defaultValue: "Sensitive redacted")
            static func topicsLine(_ a1: String) -> String {
                let template = String(localized: "settings.memory.topics-line", defaultValue: "Topics: %@")
                return String(format: template, a1)
            }
            static func provenanceLine(_ a1: String) -> String {
                let template = String(localized: "settings.memory.provenance-line", defaultValue: "Provenance: %@")
                return String(format: template, a1)
            }
            static func projectFingerprintLine(_ a1: String) -> String {
                let template = String(localized: "settings.memory.project-fingerprint-line", defaultValue: "Project fingerprint: %@")
                return String(format: template, a1)
            }
            static func projectPathLine(_ a1: String) -> String {
                let template = String(localized: "settings.memory.project-path-line", defaultValue: "Project: %@")
                return String(format: template, a1)
            }
            static func projectUnknownLine(_ a1: String) -> String {
                let template = String(localized: "settings.memory.project-unknown-line", defaultValue: "Unknown project (fingerprint %@) — edit and re-save as Project while the workspace is open to rebind")
                return String(format: template, a1)
            }
            static let scopeFilterLabel = String(localized: "settings.memory.scope-filter", defaultValue: "Show")
            static let scopeFilterAll = String(localized: "settings.memory.scope-filter-all", defaultValue: "All")
            static let scopeFilterGlobal = String(localized: "settings.memory.scope-filter-global", defaultValue: "Global only")
            static let scopeFilterCurrentProject = String(localized: "settings.memory.scope-filter-current-project", defaultValue: "This workspace")
            static let currentProjectTag = String(localized: "settings.memory.current-project-tag", defaultValue: "Current workspace")
            static func lastAccessedLine(_ a1: String) -> String {
                let template = String(localized: "settings.memory.last-accessed-line", defaultValue: "Last retrieved: %@")
                return String(format: template, a1)
            }
            static let archivedTag = String(localized: "settings.memory.archived-tag", defaultValue: "Archived")
            static let editTooltip = String(localized: "settings.memory.edit-tooltip", defaultValue: "Edit memory")
            static let restoreTooltip = String(localized: "settings.memory.restore-tooltip", defaultValue: "Restore memory")
            static let archiveTooltip = String(localized: "settings.memory.archive-tooltip", defaultValue: "Archive memory")
            static let deleteTooltip = String(localized: "settings.memory.delete-tooltip", defaultValue: "Delete memory")
            static let cancelButton = String(localized: "settings.memory.cancel", defaultValue: "Cancel")
            static let saveButton = String(localized: "settings.memory.save", defaultValue: "Save")
            static let exportPanelTitle = String(localized: "settings.memory.export-panel-title", defaultValue: "Export Memory Snapshot")
            static func exportedTo(_ a1: String) -> String {
                let template = String(localized: "settings.memory.exported-to", defaultValue: "Exported to %@.")
                return String(format: template, a1)
            }
        }

        enum GlobalRules {
            static let fileSection = String(localized: "settings.global-rules.file-section", defaultValue: "Global Rules File")
            static let enableToggle = String(localized: "settings.global-rules.enable", defaultValue: "Enable global rules")
            static let filePathLabel = String(localized: "settings.global-rules.file-path", defaultValue: "File")
            static let reloadButton = String(localized: "settings.global-rules.reload", defaultValue: "Reload")
            static let description = String(localized: "settings.global-rules.description", defaultValue: "WillDeep reads this Markdown file before every Agent turn. The default is ~/.willdeep/CLAUDE.md, but you can point it at any personal rules file.")
            static let editorSection = String(localized: "settings.global-rules.editor-section", defaultValue: "Rules Content")
            static let precedenceNote = String(localized: "settings.global-rules.precedence-note", defaultValue: "Global rules apply across workspaces. Repository AGENTS.md or CLAUDE.md files are still included as project-specific instructions.")
            static let choosePanelTitle = String(localized: "settings.global-rules.choose-title", defaultValue: "Choose Global Rules File")
            static func loadedStatus(_ a1: String) -> String {
                let template = String(localized: "settings.global-rules.loaded-status", defaultValue: "Loaded %@.")
                return String(format: template, a1)
            }
            static func noFileStatus(_ a1: String) -> String {
                let template = String(localized: "settings.global-rules.no-file-status", defaultValue: "No rules file yet at %@. Save to create it.")
                return String(format: template, a1)
            }
            static func savedStatus(_ a1: String) -> String {
                let template = String(localized: "settings.global-rules.saved-status", defaultValue: "Saved %@.")
                return String(format: template, a1)
            }
            static func saveFailed(_ a1: String) -> String {
                let template = String(localized: "settings.global-rules.save-failed", defaultValue: "Save failed: %@")
                return String(format: template, a1)
            }
        }
    }
}
