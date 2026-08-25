//
//  AgentEmbeddedBrowserHostTests.swift
//  XeditTests
//
//  The handover between the sidebar host and the detached-window host. One
//  controller owns one WKWebView, so the two hosts pass it back and forth —
//  and SwiftUI does not promise that the old host is torn down before the new
//  one is built.
//

import Testing
import Foundation
import WebKit
@testable import WillDeep

@Suite
@MainActor
struct AgentEmbeddedBrowserHostTests {

    /// The detach bug: the sidebar's dismantle arrives after the window host
    /// has already taken the web view, and used to pull it back out — leaving
    /// the detached panel blank while navigation still "worked" invisibly.
    @Test
    func lateTeardownDoesNotStealTheWebViewFromItsNewHost() {
        let sidebar = AgentEmbeddedBrowserHostView()
        let window = AgentEmbeddedBrowserHostView()
        let webView = WKWebView()

        sidebar.attach(webView)
        #expect(webView.superview === sidebar)

        // Detaching into a window: the new host takes it first.
        window.attach(webView)
        #expect(webView.superview === window)

        // …and only then does SwiftUI dismantle the sidebar's host.
        sidebar.detach()

        #expect(webView.superview === window)
    }

    @Test
    func detachStillReleasesAWebViewThatIsStillHosted() {
        let host = AgentEmbeddedBrowserHostView()
        let webView = WKWebView()

        host.attach(webView)
        host.detach()

        #expect(webView.superview == nil)
    }

    @Test
    func reattachingToTheSameHostIsIdempotent() {
        let host = AgentEmbeddedBrowserHostView()
        let webView = WKWebView()

        host.attach(webView)
        host.attach(webView)

        #expect(webView.superview === host)
        #expect(host.subviews.count == 1)
    }

    /// Going back to the sidebar is the same handover in reverse.
    @Test
    func reattachMovesTheWebViewBackToTheSidebar() {
        let sidebar = AgentEmbeddedBrowserHostView()
        let window = AgentEmbeddedBrowserHostView()
        let webView = WKWebView()

        window.attach(webView)
        sidebar.attach(webView)
        window.detach()

        #expect(webView.superview === sidebar)
        #expect(window.subviews.isEmpty)
    }
}
