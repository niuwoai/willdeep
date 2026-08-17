//
//  L10n+Onboarding.swift
//  WillDeep
//

import Foundation

extension L10n {
    enum Onboarding {
        enum Common {
            static let recommended = String(localized: "onboarding.common.recommended", defaultValue: "Recommended")
            static let optional = String(localized: "onboarding.common.optional", defaultValue: "Optional")
        }

        enum Navigation {
            static let productName = String(localized: "onboarding.navigation.product-name", defaultValue: "WillDeep")
            static let setupTitle = String(localized: "onboarding.navigation.setup-title", defaultValue: "Quick setup")
            static let welcome = String(localized: "onboarding.navigation.welcome", defaultValue: "Welcome")
            static let someIM = String(localized: "onboarding.navigation.some-im", defaultValue: "some.im account")
            static let provider = String(localized: "onboarding.navigation.provider", defaultValue: "AI provider")
            static let done = String(localized: "onboarding.navigation.done", defaultValue: "Ready")
            static let changeLater = String(localized: "onboarding.navigation.change-later", defaultValue: "You can change everything later in Settings.")
        }

        enum SomeIM {
            static let title = String(localized: "onboarding.some-im.title", defaultValue: "Sign in to some.im")
            static let subtitle = String(localized: "onboarding.some-im.subtitle", defaultValue: "The fastest way to make WillDeep useful. One account configures chat, image and video generation, and vision fallback.")
            static let signInTitle = String(localized: "onboarding.some-im.sign-in-title", defaultValue: "Continue securely in your browser")
            static let signInDetail = String(localized: "onboarding.some-im.sign-in-detail", defaultValue: "We'll wait here while you sign in, then connect WillDeep automatically.")
            static let chatCapability = String(localized: "onboarding.some-im.capability.chat", defaultValue: "AI chat")
            static let mediaCapability = String(localized: "onboarding.some-im.capability.media", defaultValue: "Images & video")
            static let visionCapability = String(localized: "onboarding.some-im.capability.vision", defaultValue: "Vision fallback")
            static let note = String(localized: "onboarding.some-im.note", defaultValue: "Your credentials stay in macOS Keychain. Prefer your own API keys? You can skip this and configure a provider next.")
            static func statusCheckFailed(_ a1: String) -> String {
                let template = String(localized: "onboarding.some-im.status-check-failed", defaultValue: "Could not check browser sign-in: %@")
                return String(format: template, a1)
            }
        }

        enum Welcome {
            static let eyebrow = String(localized: "onboarding.welcome.eyebrow", defaultValue: "A few quick choices")
            static let title = String(localized: "onboarding.welcome.title", defaultValue: "Welcome to WillDeep")
            static let subtitle = String(localized: "onboarding.welcome.subtitle", defaultValue: "Set up your AI connection now. You can change every choice later.")
            static let someIMTitle = String(localized: "onboarding.welcome.some-im-title", defaultValue: "Start with some.im")
            static let someIMDetail = String(localized: "onboarding.welcome.some-im-detail", defaultValue: "Sign in once for managed chat, image, video, and vision models.")
            static let providerTitle = String(localized: "onboarding.welcome.provider-title", defaultValue: "Or bring your own provider")
            static let providerDetail = String(localized: "onboarding.welcome.provider-detail", defaultValue: "Use an existing Claude, OpenAI, DeepSeek, or compatible API key.")
        }

        enum Provider {
            static let title = String(localized: "onboarding.provider.title", defaultValue: "Add your own AI provider")
            static let subtitle = String(localized: "onboarding.provider.subtitle", defaultValue: "Optional. Add another provider or use your own API key. The provider saved here becomes active.")
            static let someIMConnected = String(localized: "onboarding.provider.some-im-connected", defaultValue: "some.im is connected. You can safely skip this step unless you want another provider.")
            static let labelProvider = String(localized: "onboarding.provider.label-provider", defaultValue: "Provider")
            static let labelBaseURL = String(localized: "onboarding.provider.label-base-url", defaultValue: "Base URL")
            static let labelAPIKey = String(localized: "onboarding.provider.label-api-key", defaultValue: "API key")
            static let labelModel = String(localized: "onboarding.provider.label-model", defaultValue: "Default model")
            static let placeholderBaseURL = String(localized: "onboarding.provider.placeholder-base-url", defaultValue: "https://api.example.com")
            static let placeholderAPIKey = String(localized: "onboarding.provider.placeholder-api-key", defaultValue: "Stored securely in Keychain")
            static let placeholderModel = String(localized: "onboarding.provider.placeholder-model", defaultValue: "Model ID")
            static let visionRequired = String(localized: "onboarding.provider.vision-required", defaultValue: "This model needs a separate vision provider for pasted images")
            static let labelVisionProvider = String(localized: "onboarding.provider.label-vision-provider", defaultValue: "Vision provider")
            static let labelVisionBaseURL = String(localized: "onboarding.provider.label-vision-base-url", defaultValue: "Vision Base URL")
            static let labelVisionAPIKey = String(localized: "onboarding.provider.label-vision-api-key", defaultValue: "Vision API key")
            static let labelVisionModel = String(localized: "onboarding.provider.label-vision-model", defaultValue: "Vision model")
            static let errorUnknownPreset = String(localized: "onboarding.provider.error-unknown-preset", defaultValue: "Unknown provider preset.")
            static let errorBaseURLRequired = String(localized: "onboarding.provider.error-base-url-required", defaultValue: "Base URL is required for this provider.")
            static let errorModelRequired = String(localized: "onboarding.provider.error-model-required", defaultValue: "Please specify a model ID.")
            static let errorVisionBaseURLRequired = String(localized: "onboarding.provider.error-vision-base-url-required", defaultValue: "Vision Base URL is required for this model.")
            static let errorVisionModelRequired = String(localized: "onboarding.provider.error-vision-model-required", defaultValue: "Please specify a vision model ID.")
            static let errorVisionAPIKeyRequired = String(localized: "onboarding.provider.error-vision-api-key-required", defaultValue: "Vision API key is required for this provider.")
        }

        enum Done {
            static let eyebrow = String(localized: "onboarding.done.eyebrow", defaultValue: "Setup complete")
            static let title = String(localized: "onboarding.done.title", defaultValue: "You're ready to build")
            static let subtitle = String(localized: "onboarding.done.subtitle", defaultValue: "WillDeep is ready. Here's what was configured on this Mac.")
            static let aiTitle = String(localized: "onboarding.done.ai-title", defaultValue: "AI connection")
            static let settingsTitle = String(localized: "onboarding.done.settings-title", defaultValue: "Settings")
            static let providerReady = String(localized: "onboarding.done.provider-ready", defaultValue: "Your AI provider is saved and active.")
            static let aiLater = String(localized: "onboarding.done.ai-later", defaultValue: "Not configured yet. Add a provider from Settings when you're ready.")
            static let settingsDetail = String(localized: "onboarding.done.settings-detail", defaultValue: "Press ⌘, anytime to change providers, memory, or skills.")
            static let tipAgent = String(localized: "onboarding.done.tip-agent", defaultValue: "Start with a plain-language request. WillDeep will inspect the workspace, use tools, and show its progress.")
            static func someIMReady(_ a1: String) -> String {
                let template = String(localized: "onboarding.done.some-im-ready", defaultValue: "some.im is connected as %@.")
                return String(format: template, a1)
            }
            static func existingProviderReady(_ a1: String) -> String {
                let template = String(localized: "onboarding.done.existing-provider-ready", defaultValue: "%@ is already configured and active.")
                return String(format: template, a1)
            }
        }

        enum Footer {
            static let back = String(localized: "onboarding.footer.back", defaultValue: "Back")
            static let `continue` = String(localized: "onboarding.footer.continue", defaultValue: "Continue")
            static let startSetup = String(localized: "onboarding.footer.start-setup", defaultValue: "Start setup")
            static let skipForNow = String(localized: "onboarding.footer.skip-for-now", defaultValue: "Skip for now")
            static let saveContinue = String(localized: "onboarding.footer.save-continue", defaultValue: "Save & Continue")
            static let getStarted = String(localized: "onboarding.footer.get-started", defaultValue: "Open WillDeep")
            static func stepProgress(_ a1: String, _ a2: String) -> String {
                let template = String(localized: "onboarding.footer.step-progress", defaultValue: "Step %@ of %@")
                return String(format: template, a1, a2)
            }
        }
    }
}
