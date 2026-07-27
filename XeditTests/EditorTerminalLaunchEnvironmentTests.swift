import Testing
@testable import WillDeep

struct EditorTerminalLaunchEnvironmentTests {
    @Test("WillDeep local shells expose the Claude Code compatibility marker")
    func localShellInjectsClaudeCodeMarker() {
        let environment = EditorTerminalLaunchEnvironment.variables(
            from: ["PATH": "/usr/bin"],
            settings: .default,
            injectClaudeCodeCompatibility: true,
            markAsAgentTerminal: false
        )

        #expect(
            environment[EditorTerminalLaunchEnvironment.claudeCodeCompatibilityKey] == "1"
        )
        #expect(environment[EditorTerminalLaunchEnvironment.agentTerminalKey] == nil)
        #expect(environment["PATH"] == "/usr/bin")
        #expect(environment["TERM"] == "xterm-256color")
    }

    @Test("Delegated shells do not impersonate Claude Code")
    func delegatedShellOmitsClaudeCodeMarker() {
        let environment = EditorTerminalLaunchEnvironment.variables(
            from: [:],
            settings: .default,
            injectClaudeCodeCompatibility: false,
            markAsAgentTerminal: true
        )

        #expect(
            environment[EditorTerminalLaunchEnvironment.claudeCodeCompatibilityKey] == nil
        )
        #expect(environment[EditorTerminalLaunchEnvironment.agentTerminalKey] == "1")
    }

    @Test("Terminal settings can override injected defaults")
    func explicitSettingsOverrideInjectedDefaults() {
        var settings = EditorTerminalSettings.default
        settings.environmentText = """
        CLAUDECODE=
        TERM=xterm-custom
        """

        let environment = EditorTerminalLaunchEnvironment.variables(
            from: [:],
            settings: settings,
            injectClaudeCodeCompatibility: true,
            markAsAgentTerminal: true
        )

        #expect(environment[EditorTerminalLaunchEnvironment.claudeCodeCompatibilityKey] == "")
        #expect(environment["TERM"] == "xterm-custom")
    }

    @Test("Environment lines expand variables in order and accumulate PATH")
    func environmentExpandsOrderedPathAssignments() {
        var settings = EditorTerminalSettings.default
        settings.environmentText = """
        JAVA_HOME=/Library/JDK
        MAVEN_HOME=/Users/test/apache-maven
        PATH=$JAVA_HOME/bin:$PATH:.
        PATH=$MAVEN_HOME/bin:$PATH
        PATH="$PATH:$HOME/.npm-global/bin"
        PATH="/opt/homebrew/opt/mysql-client/bin:$PATH"
        LITERAL='$HOME/kept'
        """

        let environment = EditorTerminalLaunchEnvironment.variables(
            from: [
                "PATH": "/usr/bin:/bin",
                "HOME": "/Users/test"
            ],
            settings: settings,
            injectClaudeCodeCompatibility: false,
            markAsAgentTerminal: false
        )

        #expect(environment["JAVA_HOME"] == "/Library/JDK")
        #expect(environment["MAVEN_HOME"] == "/Users/test/apache-maven")
        #expect(
            environment["PATH"]
                == "/opt/homebrew/opt/mysql-client/bin:/Users/test/apache-maven/bin:/Library/JDK/bin:/usr/bin:/bin:.:/Users/test/.npm-global/bin"
        )
        #expect(environment["LITERAL"] == "$HOME/kept")
    }
}
