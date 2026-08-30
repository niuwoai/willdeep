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
    let settings: EditorSettings

    var body: some View {
        settings.interfaceSkin.windowBackground
            .ignoresSafeArea()
    }
}

/// Solid workspace color plus an optional user-chosen image,
/// laid out per `EditorSettings.windowBackgroundImageMode` and
/// `…Scale`. Shared by the Editor detail area and the standalone Agent
/// window so the same official wallpaper setting follows the user across
/// WillDeep's two work surfaces.
struct WorkspaceWallpaperBackground: View {
    let settings: EditorSettings
    var appliesAgentEffects = false
    @State private var backgroundImage: NSImage?

    private var showsWallpaper: Bool {
        appliesAgentEffects
            ? settings.hasConfiguredAgentWallpaper
            : settings.hasConfiguredWorkspaceWallpaper
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack {
                settings.interfaceSkin.windowBackground

                if showsWallpaper, let image = backgroundImage {
                    imageView(image, in: proxy.size)
                        .opacity(settings.windowBackgroundImageOpacity)
                }

                if appliesAgentEffects,
                   showsWallpaper,
                   settings.agentWallpaperGlassEnabled {
                    VisualEffectView(
                        material: settings.agentWallpaperGlassMaterial.material,
                        blendingMode: .withinWindow
                    )
                    .opacity(settings.agentWallpaperGlassOpacity)
                }
            }
        }
        .clipped()
        // The Agent window uses a full-size transparent title bar. Without
        // opting the wallpaper itself out of the window safe area, SwiftUI
        // leaves the rounded-corner/titlebar/bottom insets painted by the
        // window background. Foreground content still keeps its safe layout.
        .ignoresSafeArea()
        .task(id: settings.windowBackgroundImagePath) {
            backgroundImage = nil
            guard let path = settings.windowBackgroundImagePath else { return }
            guard let url = BuiltInWorkspaceWallpaper.resolvedImageURL(for: path) else { return }
            let data = await Task.detached(priority: .utility) {
                try? Data(contentsOf: url, options: [.mappedIfSafe])
            }.value
            guard !Task.isCancelled else { return }
            backgroundImage = data.flatMap(NSImage.init(data:))
        }
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
        case .tile:
            let scale = max(0.25, settings.windowBackgroundImageScale)
            Image(nsImage: image)
                .resizable(capInsets: EdgeInsets(), resizingMode: .tile)
                .frame(
                    width: max(1, size.width / scale),
                    height: max(1, size.height / scale),
                    alignment: .topLeading
                )
                .scaleEffect(scale, anchor: .topLeading)
                .frame(width: size.width, height: size.height, alignment: .topLeading)
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
    let blendingMode: NSVisualEffectView.BlendingMode

    init(
        material: NSVisualEffectView.Material,
        blendingMode: NSVisualEffectView.BlendingMode = .behindWindow
    ) {
        self.material = material
        self.blendingMode = blendingMode
    }

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.blendingMode = blendingMode
        view.state = .active
        view.material = material
        return view
    }

    func updateNSView(_ nsView: NSVisualEffectView, context: Context) {
        nsView.material = material
        nsView.blendingMode = blendingMode
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

    /// 悬停才显示、但任何时候都占位的元素。用 opacity 而不是 `if` 分支：
    /// 条件插入会让父容器随鼠标进出改变高度，整列内容跟着跳。隐藏时一并
    /// 让出点击和无障碍焦点，免得看不见的按钮还能被点到、还被读屏念出来。
    func hoverRevealed(_ isVisible: Bool) -> some View {
        opacity(isVisible ? 1 : 0)
            .allowsHitTesting(isVisible)
            .accessibilityHidden(!isVisible)
    }
}
