//
//  ContentViewBackgrounds.swift
//  Xedit
//
//  Window/editor background chrome split out of the monolithic
//  ContentView.swift in rc39. The main window paints itself in three
//  layers — solid `windowBackgroundColor` (the floor), an optional
//  user-chosen image (fill / fit / stretch / center), and an optional
//  glass `NSVisualEffectView` overlay behind the text editor. Plus
//  shared helpers: the sidebar resize handle (drag-to-resize divider)
//  and a `.cursor(_:)` view modifier wrapping NSCursor push/pop on
//  hover.
//
//  These types were previously `private` to ContentView.swift; pulling
//  them out forced them to internal so the main view can still see them
//  across the module. They have no external dependencies beyond
//  EditorSettings + AppKit.
//

import SwiftUI
import AppKit

/// Flat solid color that fills the whole window's safe-area outside
/// any panel. Used as the bottom layer before the editor area paints
/// itself.
struct WorkspaceWindowBackground: View {
    var body: some View {
        Color(nsColor: .windowBackgroundColor)
            .ignoresSafeArea()
    }
}

/// Solid `windowBackgroundColor` plus an optional user-chosen image,
/// laid out per `EditorSettings.windowBackgroundImageMode` and
/// `…Scale`. Lives inside a GeometryReader so the image's frame can
/// match the editor area exactly (scaledToFill / Fit / stretch /
/// center variants each need the surrounding pane's size).
struct EditorAreaBackground: View {
    let settings: EditorSettings

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                Color(nsColor: .windowBackgroundColor)

                if let image = backgroundImage {
                    imageView(image, in: proxy.size)
                        .opacity(settings.windowBackgroundImageOpacity)
                }
            }
        }
        .clipped()
    }

    private var backgroundImage: NSImage? {
        guard let path = settings.windowBackgroundImagePath else { return nil }
        return NSImage(contentsOfFile: path)
    }

    @ViewBuilder
    private func imageView(_ image: NSImage, in size: CGSize) -> some View {
        switch settings.windowBackgroundImageMode {
        case .fill:
            Image(nsImage: image)
                .resizable()
                .scaledToFill()
                .frame(width: size.width, height: size.height)
                .scaleEffect(settings.windowBackgroundImageScale)
                .clipped()
        case .fit:
            Image(nsImage: image)
                .resizable()
                .scaledToFit()
                .frame(width: size.width, height: size.height)
                .scaleEffect(settings.windowBackgroundImageScale)
                .clipped()
        case .stretch:
            Image(nsImage: image)
                .resizable()
                .frame(
                    width: max(1, size.width * settings.windowBackgroundImageScale),
                    height: max(1, size.height * settings.windowBackgroundImageScale)
                )
                .frame(width: size.width, height: size.height)
                .clipped()
        case .center:
            Image(nsImage: image)
                .resizable()
                .frame(
                    width: max(1, image.size.width * settings.windowBackgroundImageScale),
                    height: max(1, image.size.height * settings.windowBackgroundImageScale)
                )
                .frame(width: size.width, height: size.height)
                .clipped()
        }
    }
}

/// Wraps the editor in an `NSVisualEffectView` glass layer when
/// `settings.editorGlassEnabled` — opacity comes from the same
/// settings group so the background image, glass overlay, and text
/// area can be tuned together.
struct EditorGlassBackgroundModifier: ViewModifier {
    let settings: EditorSettings

    func body(content: Content) -> some View {
        if settings.editorGlassEnabled {
            ZStack {
                VisualEffectView(material: settings.editorGlassMaterial.material)
                    .opacity(settings.editorGlassOpacity)
                content
            }
        } else {
            content
        }
    }
}

extension View {
    func editorGlassBackground(settings: EditorSettings) -> some View {
        modifier(EditorGlassBackgroundModifier(settings: settings))
    }
}

/// `NSVisualEffectView` SwiftUI wrapper. Locked to `.behindWindow`
/// blending + `.active` state so the glass effect looks consistent
/// regardless of window focus.
struct VisualEffectView: NSViewRepresentable {
    let material: NSVisualEffectView.Material

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = .behindWindow
        view.state = .active
        view.material = material
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = .behindWindow
        nsView.state = .active
    }
}

/// Thin vertical drag handle wedged between the sidebar and the
/// editor area. Renders a 1pt separator line inside a 10pt-wide
/// hit-test area so users don't have to aim precisely. Width binding
/// is clamped to `[minWidth, maxWidth]`.
struct SidebarResizeHandle: View {
    @Binding var width: CGFloat
    let minWidth: CGFloat
    let maxWidth: CGFloat

    @State private var dragStartWidth: CGFloat?

    var body: some View {
        ZStack {
            Rectangle()
                .fill(Color(nsColor: .separatorColor).opacity(0.22))
                .frame(width: 1)
        }
        .frame(width: 10)
        .contentShape(Rectangle())
        .cursor(.resizeLeftRight)
        .gesture(
            DragGesture(minimumDistance: 1)
                .onChanged { value in
                    let startWidth = dragStartWidth ?? width
                    dragStartWidth = startWidth
                    width = min(max(startWidth + value.translation.width, minWidth), maxWidth)
                }
                .onEnded { _ in
                    dragStartWidth = nil
                }
        )
    }
}

/// Push an NSCursor while the pointer is over `content`, pop it on
/// exit. Used by SidebarResizeHandle and any other view that wants a
/// non-default cursor without dropping out to AppKit.
struct CursorModifier: ViewModifier {
    let cursor: NSCursor

    func body(content: Content) -> some View {
        content.onHover { isHovering in
            if isHovering {
                cursor.push()
            } else {
                NSCursor.pop()
            }
        }
    }
}

extension View {
    func cursor(_ cursor: NSCursor) -> some View {
        modifier(CursorModifier(cursor: cursor))
    }
}
