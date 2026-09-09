//
//  AgentCommandSafetyTests.swift
//  WillDeepTests
//
//  Split from AgentToolIntegrationTests.swift to keep files under the
//  repository file-size limit. SafeCommand classification, run_command
//  risk escalation, sandbox policy decisions, and shell execution.
//

import Testing
import Foundation
@testable import WillDeep

/// Ceiling for headless `run_command` spawns driven from tests. Mirrors the
/// constant in AgentToolsCoreTests: these tests assert behavior, not latency,
/// and a tight budget is blown by spawn contention under a full-load run.
private let headlessCommandTimeoutSeconds = 30.0

extension WillDeepTests {
    // MARK: - SafeCommand classification

    @Test("shell parser preserves connectors and treats quoted operators as data")
    func shellParserPreservesConnectorSemantics() throws {
        let chain = try #require(AgentShellCommandParser.parse(
            "cd repo && printf 'a | b || rm' | git status || git ls-files"
        ))

        #expect(chain.segments.map(\.text) == [
            "cd repo",
            "printf 'a | b || rm'",
            "git status",
            "git ls-files",
        ])
        #expect(chain.segments.map(\.connectorToNext) == [
            .and,
            .pipeline,
            .or,
            nil,
        ])
        #expect(chain.segments[1].runsInPipeline)
        #expect(chain.segments[2].runsInPipeline)
        #expect(!chain.requiresBackgroundJudgment)
    }

    @Test("shell parser strips unquoted comments and records background execution")
    func shellParserHandlesCommentsAndBackgroundJobs() throws {
        let commented = try #require(AgentShellCommandParser.parse(
            "git status # inspect only\nprintf '# still data'"
        ))
        #expect(commented.segments.map(\.text) == ["git status", "printf '# still data'"])
        #expect(commented.segments.first?.connectorToNext == .sequence)

        let background = try #require(AgentShellCommandParser.parse("git status & git ls-files"))
        #expect(background.segments.first?.connectorToNext == .background)
        #expect(background.requiresBackgroundJudgment)
    }

    @Test("SafeCommand classifies common read-only commands as alwaysSafe")
    func testSafeCommandAllowlist() {
        // Single safe commands.
        #expect(SafeCommand.classify(command: "cat README.md") == .alwaysSafe)
        #expect(SafeCommand.classify(command: "head -n 50 src/main.rs") == .alwaysSafe)
        #expect(SafeCommand.classify(command: "rg \"AgentSettingsStore\" Xedit") == .alwaysSafe)
        #expect(SafeCommand.classify(command: "ls -la") == .alwaysSafe)
        #expect(SafeCommand.classify(command: "pwd") == .alwaysSafe)
        #expect(SafeCommand.classify(command: "wc -l Sources/*.swift") == .alwaysSafe)
        #expect(SafeCommand.classify(command: "diff -u a.swift b.swift") == .alwaysSafe)
        #expect(SafeCommand.classify(command: "realpath .") == .alwaysSafe)
        #expect(SafeCommand.classify(command: "jq . package.json") == .alwaysSafe)
        #expect(SafeCommand.classify(command: "xxd -l 64 binary.bin") == .alwaysSafe)
        #expect(SafeCommand.classify(command: "mdfind 'kMDItemDisplayName == *.swift'") == .alwaysSafe)
        #expect(SafeCommand.classify(command: "defaults read com.apple.finder") == .alwaysSafe)
        #expect(SafeCommand.classify(command: "defaults write com.apple.finder AppleShowAllFiles true") == .needsJudgment)
        #expect(SafeCommand.classify(command: "unzip -l archive.zip") == .alwaysSafe)
        #expect(SafeCommand.classify(command: "unzip -lq archive.zip") == .alwaysSafe)
        #expect(SafeCommand.classify(command: "unzip archive.zip") == .needsJudgment)
        #expect(SafeCommand.classify(command: "unzip -ov archive.zip") == .needsJudgment)

        // Quoted command-looking text is data, not authority.
        #expect(SafeCommand.classify(command: "printf 'rm sudo > | &&'") == .alwaysSafe)
        #expect(SafeCommand.classify(command: "printf '$(rm -rf /)'") == .alwaysSafe)
        #expect(SafeCommand.classify(command: "printf \"$(rm -rf /)\"") == .alwaysDangerous)

        // git read-only subcommands.
        #expect(SafeCommand.classify(command: "git diff") == .alwaysSafe)
        #expect(SafeCommand.classify(command: "git log --oneline -10") == .alwaysSafe)
        #expect(SafeCommand.classify(command: "git status") == .alwaysSafe)
        #expect(SafeCommand.classify(command: "git show HEAD") == .alwaysSafe)
        #expect(SafeCommand.classify(command: "git grep -n alwaysSafe") == .alwaysSafe)
        #expect(SafeCommand.classify(command: "git merge-base HEAD develop") == .alwaysSafe)
        #expect(SafeCommand.classify(command: "git version") == .alwaysSafe)
        #expect(SafeCommand.classify(
            command: "git config --global --list --show-origin 2>&1 | head -20; echo \"---exit:$?\""
        ) == .alwaysSafe)

        // A local commit is reversible and runs inside the workspace sandbox.
        #expect(SafeCommand.classify(command: "git commit -m 'fix: retry'") == .alwaysSafe)
        #expect(SafeCommand.isLocalGitCommit(command: "git commit -m 'fix: retry'"))
        #expect(!SafeCommand.isLocalGitCommit(command: "git commit -m ok && git push"))
        #expect(!SafeCommand.isLocalGitCommit(command: "git push origin main"))

        // git config writes must NOT be auto-approved.
        #expect(SafeCommand.classify(command: "git config user.email rocky@example.com") == .needsJudgment)
        #expect(SafeCommand.classify(command: "git config --add safe.directory /tmp/foo") == .needsJudgment)

        // git stash without args (writes) must NOT be auto-approved.
        #expect(SafeCommand.classify(command: "git stash") == .needsJudgment)
        #expect(SafeCommand.classify(command: "git stash list") == .alwaysSafe)

        // Git inspectors with mutation-shaped arguments must not inherit the
        // read-only classification of their bare subcommand.
        #expect(SafeCommand.classify(command: "git branch") == .alwaysSafe)
        #expect(SafeCommand.classify(command: "git branch feature/new") == .needsJudgment)
        #expect(SafeCommand.classify(command: "git tag") == .alwaysSafe)
        #expect(SafeCommand.classify(command: "git tag v1.2.3") == .needsJudgment)
        #expect(SafeCommand.classify(command: "git remote -v") == .alwaysSafe)
        #expect(SafeCommand.classify(command: "git remote show origin") == .alwaysSafe)
        #expect(SafeCommand.classify(command: "git remote add origin https://example.com/repo.git") == .needsJudgment)
        #expect(SafeCommand.classify(command: "git branch --contains HEAD") == .alwaysSafe)
        #expect(SafeCommand.classify(command: "git tag --list 'v1.*'") == .alwaysSafe)
        #expect(SafeCommand.classify(command: "git diff --output=changes.patch") == .needsJudgment)
        #expect(SafeCommand.classify(command: "git grep --open-files-in-pager=vim needle") == .needsJudgment)

        // Stream tools are read-only only when their own output options do
        // not name a file or invoke a nested program.
        #expect(SafeCommand.classify(command: "printf ok | tee") == .alwaysSafe)
        #expect(SafeCommand.classify(command: "printf ok | tee status.txt") == .needsJudgment)
        #expect(SafeCommand.classify(command: "sed -n '1,10p' file") == .alwaysSafe)
        #expect(SafeCommand.classify(command: "sed -i '' 's/a/b/' file") == .needsJudgment)
        #expect(SafeCommand.classify(command: "sort input.txt") == .alwaysSafe)
        #expect(SafeCommand.classify(command: "sort -o output.txt input.txt") == .needsJudgment)
        #expect(SafeCommand.classify(command: "yq -i '.enabled = true' config.yml") == .needsJudgment)
        #expect(SafeCommand.classify(command: "awk '{print $1}' file") == .alwaysSafe)
        #expect(SafeCommand.classify(command: "awk '{print > \"out\"}' file") == .needsJudgment)
        #expect(SafeCommand.classify(command: "base64 input.bin") == .alwaysSafe)
        #expect(SafeCommand.classify(command: "base64 -o output.txt input.bin") == .needsJudgment)
        #expect(SafeCommand.classify(command: "iconv -o converted.txt input.txt") == .needsJudgment)
        #expect(SafeCommand.classify(command: "xxd -l 10 input.bin") == .alwaysSafe)
        #expect(SafeCommand.classify(command: "xxd input.bin output.hex") == .needsJudgment)

        // Common build/dev commands are low-risk workspace operations:
        // they may write build artifacts, but should not require a manual
        // approval click in smart/goal flows.
        #expect(SafeCommand.classify(command: "go build -o bin/metaserver . 2>&1") == .alwaysSafe)
        #expect(SafeCommand.classify(command: "GOCACHE=$(pwd)/.cache/go-build GOMODCACHE=$(pwd)/.cache/go-mod go build -o bin/metaserver . 2>&1") == .alwaysSafe)
        #expect(SafeCommand.classify(command: "go test ./...") == .alwaysSafe)
        #expect(SafeCommand.classify(command: "go env -w GOPROXY=https://proxy.golang.org") == .needsJudgment)
        #expect(SafeCommand.classify(command: "yarn run dev") == .alwaysSafe)
        #expect(SafeCommand.classify(command: "yarn build") == .alwaysSafe)
        #expect(SafeCommand.classify(command: "yarn install") == .alwaysSafe)
        #expect(SafeCommand.classify(command: "yarn add pptxgenjs") == .alwaysSafe)
        #expect(SafeCommand.classify(command: "yarn --registry https://registry.yarnpkg.com add pptxgenjs") == .alwaysSafe)
        #expect(SafeCommand.classify(command: "npm run build") == .alwaysSafe)
        #expect(SafeCommand.classify(command: "npm install pptxgenjs") == .alwaysSafe)
        #expect(SafeCommand.classify(command: "npm install --save-dev pptxgenjs") == .alwaysSafe)
        #expect(SafeCommand.classify(command: "npm --registry https://registry.npmjs.org install pptxgenjs") == .alwaysSafe)
        #expect(SafeCommand.classify(command: "npm ci") == .alwaysSafe)
        #expect(SafeCommand.classify(command: "npm install -g pptxgenjs") == .needsJudgment)
        #expect(SafeCommand.classify(command: "pnpm run typecheck") == .alwaysSafe)
        #expect(SafeCommand.classify(command: "pnpm install") == .alwaysSafe)
        #expect(SafeCommand.classify(command: "pnpm add pptxgenjs") == .alwaysSafe)
        #expect(SafeCommand.classify(command: "vite --host 127.0.0.1") == .alwaysSafe)
        #expect(SafeCommand.classify(command: "nginx -s reload") == .alwaysSafe)
        #expect(SafeCommand.classify(command: "nginx -s stop") == .needsJudgment)
        #expect(SafeCommand.classify(command: "npm publish") == .needsJudgment)
    }

    @Test("run_command only auto-approves bounded cleanup of rebuildable workspace directories")
    func testRebuildableWorkspaceCleanupPolicy() {
        let workspace = URL(fileURLWithPath: "/tmp/willdeep-cleanup-workspace").standardizedFileURL
        let safeCommands = [
            "rm -rf node_modules",
            "cd web && rm -rf node_modules .vite dist",
            "rm -r .build",
            "rm -rf .cache/go-build .cache/go-mod",
        ]

        for command in safeCommands {
            let decision = AgentSandboxPolicy.commandDecision(
                command: command,
                rootDirectory: workspace
            )
            #expect(
                decision.mode == .workspaceWrite,
                "\(command): \(decision.reason)"
            )
            #expect(decision.requiresTypedConfirmation == false)
            #expect(
                AgentSandboxPolicy.canAutoApproveWorkspaceWriteCommand(
                    command: command,
                    rootDirectory: workspace
                ),
                "Expected bounded cleanup to auto-approve: \(command)"
            )
        }

        let unsafeCommands = [
            "rm -rf .",
            "rm -rf ..",
            "rm -rf src",
            "rm -rf node_modules/*",
            "rm -rf /tmp/node_modules",
            "rm -rf ~/.cache/go-build",
            "rm -rf node_modules src",
        ]
        for command in unsafeCommands {
            #expect(!AgentSandboxPolicy.canAutoApproveWorkspaceWriteCommand(
                command: command,
                rootDirectory: workspace
            ))
        }
    }

    @Test("run_command auto-approves rebuildable cleanup inside a project's additional folders")
    func testRebuildableWorkspaceCleanupPolicyWithAdditionalRoots() {
        let workspace = URL(fileURLWithPath: "/tmp/willdeep-cleanup-workspace").standardizedFileURL
        let secondary = URL(fileURLWithPath: "/tmp/willdeep-cleanup-secondary").standardizedFileURL

        struct Case {
            let command: String
            let expected: Bool
            let note: String
        }
        let cases = [
            Case(
                command: "cd \(secondary.path) && rm -rf node_modules",
                expected: true,
                note: "relative cleanup after cd into the second project folder"
            ),
            Case(
                command: "rm -rf \(secondary.path)/node_modules",
                expected: true,
                note: "absolute cleanup target inside the second project folder"
            ),
            Case(
                command: "cd \(secondary.path)/web && rm -rf node_modules dist",
                expected: true,
                note: "nested subdirectory of the second project folder"
            ),
            Case(
                command: "rm -rf /tmp/willdeep-cleanup-elsewhere/node_modules",
                expected: false,
                note: "path outside every authorized root stays manual"
            ),
            Case(
                command: "rm -rf \(secondary.path)",
                expected: false,
                note: "the authorized root itself is never a cleanup target"
            ),
            Case(
                command: "cd \(secondary.path) && rm -rf src",
                expected: false,
                note: "non-rebuildable directory stays manual even inside the second root"
            ),
        ]

        for testCase in cases {
            let approved = AgentSandboxPolicy.canAutoApproveWorkspaceWriteCommand(
                command: testCase.command,
                rootDirectory: workspace,
                additionalWorkspaceRoots: [secondary]
            )
            #expect(approved == testCase.expected, "\(testCase.note): \(testCase.command)")
        }

        // Without the additional root the same second-folder cleanup must
        // still fall back to a manual approval card.
        #expect(!AgentSandboxPolicy.canAutoApproveWorkspaceWriteCommand(
            command: "cd \(secondary.path) && rm -rf node_modules",
            rootDirectory: workspace
        ))
    }

    @Test("SafeCommand: shell wrappers with harmless sentinel commands auto-approve")
    func testSafeCommandShellWrapperSentinel() {
        #expect(SafeCommand.classify(command: #"/bin/sh -lc "echo DOCKER_DONE""#) == .alwaysSafe)
        #expect(SafeCommand.classify(command: #"bash -c "printf '%s\n' DOCKER_DONE""#) == .alwaysSafe)
        #expect(SafeCommand.classify(command: #"env PATH=/usr/bin:/bin zsh -lc "echo DOCKER_DONE""#) == .alwaysSafe)

        #expect(SafeCommand.classify(command: #"bash -lc "rm -rf /tmp/build""#) == .alwaysDangerous)
        #expect(SafeCommand.classify(command: #"bash -lc "cat /etc/passwd""#) == .needsJudgment)
    }

    @Test("SafeCommand pipelines: every segment must be safe for the chain to auto-approve")
    func testSafeCommandPipelines() {
        // Two safe segments → safe.
        #expect(SafeCommand.classify(command: "git diff | head -50") == .alwaysSafe)
        #expect(SafeCommand.classify(command: "rg foo | wc -l") == .alwaysSafe)
        // A dangerous segment poisons the whole chain.
        #expect(SafeCommand.classify(command: "git diff && rm -rf node_modules") == .alwaysDangerous)
        #expect(SafeCommand.classify(command: "cat a.txt; sudo rm /tmp/x") == .alwaysDangerous)
        // An unknown segment downgrades safe → needsJudgment.
        #expect(SafeCommand.classify(command: "cat a.txt | xargs cargo run") == .needsJudgment)
        #expect(SafeCommand.classify(command: "git status || rm -rf repo") == .alwaysDangerous)
        #expect(SafeCommand.classify(command: "git status &") == .needsJudgment)
        #expect(SafeCommand.classify(command: "command rm -rf repo") == .alwaysDangerous)
        #expect(SafeCommand.classify(command: "command -v rm") == .alwaysSafe)
        #expect(SafeCommand.classify(command: "xargs -0 rm") == .alwaysDangerous)
        #expect(SafeCommand.classify(command: "xargs -I{} sh -c 'rm -rf repo'") == .alwaysDangerous)
        #expect(SafeCommand.classify(command: "xargs -n1 printf") == .alwaysSafe)
        #expect(SafeCommand.classify(command: "git branch -Dfeature/old") == .needsJudgment)
        #expect(SafeCommand.classify(command: "git tag --delete=v1.0.0") == .needsJudgment)
        #expect(SafeCommand.classify(command: "sed -ni '1,5p' file") == .needsJudgment)
        #expect(SafeCommand.classify(command: "sort -ooutput.txt input.txt") == .needsJudgment)
        #expect(SafeCommand.classify(command: "awk 'BEGIN { system (\"touch out\") }'") == .needsJudgment)
    }

    @Test("workspace read-only chain with cd, printf, pipes, and git ls-files never asks")
    func workspaceReadOnlyCompositeCommandDoesNotAsk() {
        let root = URL(fileURLWithPath: "/tmp/willdeep-composite-workspace")
        let command = "cd \(root.path) && printf '\\n--- tracked files ---\\n' && git ls-files | head -20"

        #expect(SafeCommand.classify(command: command) == .alwaysSafe)
        let decision = AgentSandboxPolicy.commandDecision(command: command, rootDirectory: root)
        #expect(decision.mode == .readOnly)
        #expect(decision.requiresUserApproval == false)
        #expect(decision.requiresTypedConfirmation == false)
    }

    @Test("pipeline cd does not leak its working directory into sibling commands")
    func pipelineCDDoesNotChangeSiblingWorkingDirectory() {
        let root = URL(fileURLWithPath: "/tmp/willdeep-pipeline-workspace")
        let piped = AgentSandboxPolicy.commandDecision(
            command: "cd \(root.path)/subdir | cat ../outside.txt",
            rootDirectory: root
        )
        let sequenced = AgentSandboxPolicy.commandDecision(
            command: "cd \(root.path)/subdir && cat ../inside.txt",
            rootDirectory: root
        )

        // `cd` on the left of a pipe runs in a subshell; the sibling `cat`
        // still resolves from the workspace root, so `../outside.txt` is an
        // external path and must be preflight-escalated.
        #expect(piped.mode == .escalated)
        #expect(piped.requiresUserApproval)
        #expect(sequenced.mode == .readOnly)
        #expect(!sequenced.requiresUserApproval)
    }

    @Test("SafeCommand rejects redirections and command substitution")
    func testSafeCommandRejectsRedirectionAndSubstitution() {
        #expect(SafeCommand.classify(command: "cat foo > bar") == .alwaysDangerous)
        #expect(SafeCommand.classify(command: "echo $(rm -rf /)") == .alwaysDangerous)
        #expect(SafeCommand.classify(command: "GOCACHE=$(rm -rf /tmp/cache) go build -o bin/metaserver .") == .alwaysDangerous)
        #expect(SafeCommand.classify(command: "ls `pwd`") == .alwaysDangerous)
        // Harmless stderr redirection should still be classified as safe.
        #expect(SafeCommand.classify(command: "git status 2>/dev/null") == .alwaysSafe)
    }

    @Test("Smart review receives bounded read-only command substitutions")
    func smartReviewReceivesBoundedReadOnlyCommandSubstitution() throws {
        let command = #"OUT=$(find performance-results -maxdepth 1 -type d -name 'deadlock-repro-rc12-20260810T233450' | tail -1); echo '--- files ---'; find "$OUT" -maxdepth 2 -type f -printf '%TY-%Tm-%Td %TH:%TM:%TS %p\n' | sort | tail -15; echo '--- deadlocks metric ---'; mysql -h127.0.0.1 -P3306 -NBe "SELECT NAME, COUNT FROM information_schema.innodb_metrics WHERE NAME='lock_deadlocks';"; echo '--- app ---'; grep -n -E 'Error 1213|Deadlock found|settlement_credit' "$OUT/gateway.log" | tail -20 || true"#

        let resolution = try #require(SafeCommand.resolveProvablySafeShellExpansions(in: command))
        #expect(resolution.requiresJudgment)
        #expect(!resolution.command.contains("$("))
        #expect(SafeCommand.classify(command: command) == .needsJudgment)
        let judgePayload = AgentInjectionDefense.judgeUserPayload(command: command)
        #expect(judgePayload.contains("segment_count=11"))
        #expect(judgePayload.contains(command))

        let decision = AgentSandboxPolicy.commandDecision(
            command: command,
            rootDirectory: URL(fileURLWithPath: "/tmp/willdeep-command-substitution-workspace")
        )
        #expect(decision.mode == .escalated)
        #expect(decision.requiresUserApproval)
        #expect(!decision.requiresTypedConfirmation)
        #expect(AppState.canSendToSafetyJudge(toolName: "run_command", sandboxDecision: decision))
    }

    @Test("Dangerous or unknown command substitutions stay behind typed confirmation")
    func dangerousCommandSubstitutionsStayHumanGated() {
        let commands = [
            "OUT=$(rm -rf /tmp/cache); printf '%s\\n' \"$OUT\"",
            "OUT=$(custom-side-effect-tool); printf '%s\\n' \"$OUT\"",
            "OUT=`find performance-results -type d`; printf '%s\\n' \"$OUT\"",
        ]

        for command in commands {
            #expect(SafeCommand.classify(command: command) == .alwaysDangerous)
            let decision = AgentSandboxPolicy.commandDecision(
                command: command,
                rootDirectory: URL(fileURLWithPath: "/tmp/willdeep-command-substitution-workspace")
            )
            #expect(decision.mode == .escalated)
            #expect(decision.requiresUserApproval)
            #expect(decision.requiresTypedConfirmation)
            #expect(!AppState.canSendToSafetyJudge(toolName: "run_command", sandboxDecision: decision))
        }

        let boundednessFailures = [
            "SECRET=$(cat ~/.ssh/id_rsa); printf '%s\\n' \"$SECRET\"",
            "OUT=$(mkdir generated-output); printf '%s\\n' \"$OUT\"",
            "API_KEY=$(find performance-results -type d | tail -1); printf '%s\\n' \"$API_KEY\"",
        ]
        for command in boundednessFailures {
            let decision = AgentSandboxPolicy.commandDecision(
                command: command,
                rootDirectory: URL(fileURLWithPath: "/tmp/willdeep-command-substitution-workspace")
            )
            #expect(decision.mode == .escalated)
            #expect(decision.requiresUserApproval)
            #expect(decision.requiresTypedConfirmation)
            #expect(!AppState.canSendToSafetyJudge(toolName: "run_command", sandboxDecision: decision))
        }
    }

    @Test("MySQL inline read queries use AI review while mutations and credentials stay human-gated")
    func mysqlInlineQuerySafetyBoundaries() {
        let readOnly = "mysql -h127.0.0.1 -P3306 -NBe \"SELECT NAME, COUNT FROM information_schema.innodb_metrics WHERE NAME='lock_deadlocks';\""
        #expect(SafeCommand.classify(command: readOnly) == .needsJudgment)

        let readDecision = AgentSandboxPolicy.commandDecision(
            command: readOnly,
            rootDirectory: URL(fileURLWithPath: "/tmp/willdeep-mysql-review-workspace")
        )
        #expect(readDecision.mode == .escalated)
        #expect(readDecision.requiresUserApproval)
        #expect(!readDecision.requiresTypedConfirmation)
        #expect(AppState.canSendToSafetyJudge(toolName: "run_command", sandboxDecision: readDecision))

        let humanGated = [
            "mysql -h127.0.0.1 -P3306 -e \"DELETE FROM jobs WHERE id = 1\"",
            "mysql -h127.0.0.1 -P3306 -e \"SELECT 1; DROP TABLE jobs\"",
            "mysql -h127.0.0.1 -P3306 -psecret -e \"SELECT 1\"",
            "mysql -hselect.example -P3306",
            "mysql -h127.0.0.1 -P3306",
        ]
        for command in humanGated {
            #expect(SafeCommand.classify(command: command) == .alwaysDangerous)
            let decision = AgentSandboxPolicy.commandDecision(
                command: command,
                rootDirectory: URL(fileURLWithPath: "/tmp/willdeep-mysql-review-workspace")
            )
            #expect(decision.requiresTypedConfirmation)
        }
    }

    @Test("MySQL 多语句按句判定：全只读走 AI 复核，夹带写或引号不闭合仍留人工")
    func mysqlMultiStatementReadOnlyBoundaries() {
        // 用户实测案例：`SELECT 'SOCKET_OK'; SHOW DATABASES;` 每一句都只读，
        // 却因为“看见分号就整条判危”落到人工确认卡，而同一天单语句的
        // `SELECT VERSION();` 被裁判自动放行。分号不该是判据，语句内容才是。
        let aiReviewed = [
            "mysql -uroot -e \"SELECT 'SOCKET_OK'; SHOW DATABASES;\"",
            "mysql -h127.0.0.1 -e \"SELECT VERSION(); SHOW DATABASES; SHOW TABLES;\"",
            // 引号内的分号是数据，不是分隔符。
            "mysql -uroot -e \"SELECT ';' AS semicolon\"",
            // 空语句（连续分号、结尾分号）不改变判定。
            "mysql -uroot -e \"SELECT 1;; SHOW DATABASES;\"",
        ]
        for command in aiReviewed {
            #expect(SafeCommand.classify(command: command) == .needsJudgment)
            let decision = AgentSandboxPolicy.commandDecision(
                command: command,
                rootDirectory: URL(fileURLWithPath: "/tmp/willdeep-mysql-review-workspace")
            )
            #expect(!decision.requiresTypedConfirmation)
            #expect(AppState.canSendToSafetyJudge(toolName: "run_command", sandboxDecision: decision))
        }

        // 逐句判定不是放水：任意一句不是只读，整条仍然落人工。
        let humanGated = [
            "mysql -uroot -e \"SELECT 1; DROP TABLE jobs\"",
            "mysql -uroot -e \"SHOW DATABASES; DELETE FROM jobs WHERE id = 1\"",
            "mysql -uroot -e \"SELECT 1; SELECT * FROM jobs INTO OUTFILE '/tmp/x'\"",
            // 引号不闭合 —— 解析不确定就 fail-closed。
            "mysql -uroot -e \"SELECT 'unterminated; SHOW DATABASES\"",
        ]
        for command in humanGated {
            #expect(SafeCommand.classify(command: command) == .alwaysDangerous)
            let decision = AgentSandboxPolicy.commandDecision(
                command: command,
                rootDirectory: URL(fileURLWithPath: "/tmp/willdeep-mysql-review-workspace")
            )
            #expect(decision.requiresTypedConfirmation)
            #expect(!AppState.canSendToSafetyJudge(toolName: "run_command", sandboxDecision: decision))
        }
    }

    @Test("snake_case 标识符里的凭据词不触发人工确认，连字符与真实凭据仍拦截")
    func credentialMarkerBoundaryRespectsSnakeCase() {
        let root = URL(fileURLWithPath: "/tmp/willdeep-cred-marker-workspace")
        // 审计日志实锤的误伤：读工作区源码文件，只因文件名是 snake_case
        // 且含 token/secret 字样就要人工点。下划线是标识符字符，不是边界。
        let benign = [
            "sed -n '100,240p' internal/gateway/token_plan_quota.go",
            "grep -rn \"loadPlan\" internal/gateway/token_plan_quota.go",
            "wc -l internal/auth/secret_rotation_helper.go",
        ]
        for command in benign {
            let decision = AgentSandboxPolicy.commandDecision(command: command, rootDirectory: root)
            #expect(!decision.requiresTypedConfirmation, "误伤: \(command)")
        }
        // 连字符仍是边界：k8s secret 对象名是真实凭据引用，必须继续命中。
        let kubeSecret = AgentSandboxPolicy.commandDecision(
            command: "kubectl -n tokenhub get secret tokenhub-secret -o yaml",
            rootDirectory: root
        )
        #expect(kubeSecret.requiresTypedConfirmation)
    }

    @Test("git commit 提交信息不参与凭据词扫描，路径参数照常扫描")
    func gitCommitMessageExemptFromCredentialScan() {
        let root = URL(fileURLWithPath: "/tmp/willdeep-cred-marker-workspace")
        // 提交一段“支持 Bearer Token 认证”的说明不读取任何凭据。
        let benign = [
            "git commit -m \"feat(subscription): support Bearer Token and Basic Auth\"",
            "git commit --message=\"rotate token handling in gateway\"",
            "git commit -am \"docs: describe secret scanning rules\"",
        ]
        for command in benign {
            let decision = AgentSandboxPolicy.commandDecision(command: command, rootDirectory: root)
            #expect(!decision.requiresTypedConfirmation, "误伤: \(command)")
        }
        // message 之外的参数不豁免：pathspec 指向 ~/.ssh 仍然人工。
        let flagged = AgentSandboxPolicy.commandDecision(
            command: "git commit -m fix ~/.ssh/config",
            rootDirectory: root
        )
        #expect(flagged.requiresTypedConfirmation)
    }

    @Test("工作区内词撞名路径豁免凭据扫描；工作区外与 .env 永不豁免")
    func workspaceLocalMarkerPathExemption() {
        let root = URL(fileURLWithPath: "/tmp/willdeep-cred-marker-workspace")
        // read_file 工具本就免审可读工作区文件；命令行读同一份文件不该另立门槛。
        let benign = AgentSandboxPolicy.commandDecision(
            command: "cat internal/auth/token.go",
            rootDirectory: root
        )
        #expect(!benign.requiresTypedConfirmation)
        // 工作区外的同名路径保持人工。
        let outside = AgentSandboxPolicy.commandDecision(
            command: "cat /etc/pki/token.pem",
            rootDirectory: root
        )
        #expect(outside.requiresTypedConfirmation)
        // sensitivePathFragments（.env、~/.ssh …）不吃这个豁免。
        let dotenv = AgentSandboxPolicy.commandDecision(
            command: "cat .env",
            rootDirectory: root
        )
        #expect(dotenv.requiresTypedConfirmation)
    }

    @Test("SafeCommand: shell 控制流 + whois 等只读网络命令自动放行")
    func testSafeCommandShellControlFlow() {
        // 用户实测案例：纯只读 whois 循环此前落到 LLM judge 又被拒，
        // 次次人工审批。for 头 / do 前缀 / whois / done 现在全部静态放行。
        #expect(SafeCommand.classify(
            command: "for ext in io ai app dev co net org; do echo \"=== deepcoder.$ext ===\"; whois \"deepcoder.$ext\" 2>&1 | grep -iE \"no match|not found|status\"; done"
        ) == .alwaysSafe)

        // 控制流关键字本身无负载。
        #expect(SafeCommand.classify(command: "while read line; do echo \"$line\"; done") == .alwaysSafe)
        #expect(SafeCommand.classify(command: "if grep -q TODO a.swift; then echo found; fi") == .alwaysSafe)
        #expect(SafeCommand.classify(command: "time git status") == .alwaysSafe)
        #expect(SafeCommand.classify(command: "time rm -rf /tmp/x") == .alwaysDangerous)

        // 关键字剥掉后负载照常受走查约束——危险负载一票否决。
        #expect(SafeCommand.classify(command: "for f in a b; do rm \"$f\"; done") == .alwaysDangerous)
        #expect(SafeCommand.classify(command: "if true; then sudo reboot; fi") == .alwaysDangerous)
        #expect(SafeCommand.classify(command: "while true; do curl http://x.example; done") == .needsJudgment)

        // 未知负载仍然降级到 needsJudgment，不会因为有 for 头就放行。
        #expect(SafeCommand.classify(command: "for f in a b; do mycustomtool \"$f\"; done") == .needsJudgment)

        // whois 与 dig/host 同族，直接安全。
        #expect(SafeCommand.classify(command: "whois example.com") == .alwaysSafe)
        #expect(SafeCommand.classify(command: "whois example.com 2>&1 | grep -i status") == .alwaysSafe)
    }

    @Test("SafeCommand: kubectl inspection and terminal clear auto-approve")
    func testSafeCommandKubectlInspection() {
        let filteredInspection = "kubectl config current-context; kubectl get ns | grep -i token; "
            + "kubectl get deploy -A 2>/dev/null | grep -i tokenhub"

        #expect(SafeCommand.classify(command: "clear") == .alwaysSafe)
        #expect(SafeCommand.classify(command: "kubectl get pods -A") == .alwaysSafe)
        #expect(SafeCommand.classify(command: "kubectl -n tokenhub describe deploy api") == .alwaysSafe)
        #expect(SafeCommand.classify(command: "kubectl --context prod logs deploy/api --tail=100") == .alwaysSafe)
        #expect(SafeCommand.classify(command: "kubectl config current-context") == .alwaysSafe)
        #expect(SafeCommand.classify(command: "kubectl auth can-i get pods") == .alwaysSafe)
        #expect(SafeCommand.classify(command: "kubectl rollout status deploy/api") == .alwaysSafe)
        #expect(SafeCommand.classify(command: "NS=tokenhub; kubectl -n $NS get job perf-30m; date -u +%H:%M:%S") == .alwaysSafe)
        #expect(SafeCommand.classify(command: filteredInspection) == .alwaysSafe)

        let filteredInspectionDecision = AgentSandboxPolicy.commandDecision(
            command: filteredInspection,
            rootDirectory: URL(fileURLWithPath: "/tmp/willdeep-kubectl-filter-workspace")
        )
        // kubectl 要连集群 API，所以它是带网络的只读档，不再是 .readOnly。
        // 早先落在无网那档，结果一台配好 kubeconfig 的机器上连 `get pods`
        // 都跑不了：合成 HOME 让 kubectl 找不到 ~/.kube/config，报
        // current-context is not set 并回落 localhost:8080。
        #expect(filteredInspectionDecision.mode == .readOnlyNetwork)
        #expect(!filteredInspectionDecision.requiresUserApproval)
        #expect(!filteredInspectionDecision.requiresTypedConfirmation)

        // 1.358.0-rc1：主目录是真的，kubectl 直接读到 `~/.kube/config`，
        // 原来那条按命令静态判定再注入 KUBECONFIG 的窄例外已经删掉。
        #expect(!AgentSandboxPolicy.redirectsHome(.readOnlyNetwork))

        let sensitiveFileRead = AgentSandboxPolicy.commandDecision(
            command: "kubectl get ns | grep token .env",
            rootDirectory: URL(fileURLWithPath: "/tmp/willdeep-kubectl-filter-workspace")
        )
        #expect(sensitiveFileRead.requiresTypedConfirmation)

        #expect(SafeCommand.classify(command: "kubectl apply -f deploy.yaml") == .needsJudgment)
        #expect(SafeCommand.classify(command: "kubectl diff -k overlays/prod") == .needsJudgment)
        #expect(SafeCommand.classify(command: "kubectl delete pod api-0") == .needsJudgment)
        #expect(SafeCommand.classify(command: "kubectl exec deploy/api -- sh") == .needsJudgment)
        #expect(SafeCommand.classify(command: "kubectl --token secret get pods") == .alwaysDangerous)
        #expect(SafeCommand.classify(command: "kubectl config use-context prod") == .needsJudgment)
        #expect(SafeCommand.classify(command: "kubectl rollout restart deploy/api") == .needsJudgment)
        #expect(SafeCommand.classify(command: "kubectl get secrets -A -o yaml") == .alwaysDangerous)
        #expect(SafeCommand.classify(command: "kubectl config view --raw") == .alwaysDangerous)
    }

    @Test("SafeCommand: common operations inspectors stay read-only")
    func testSafeCommandOperationsInspection() {
        #expect(SafeCommand.classify(command: "getent hosts db.internal") == .alwaysSafe)
        #expect(SafeCommand.classify(command: "ss -lntp") == .alwaysSafe)
        #expect(SafeCommand.classify(command: "free -h") == .alwaysSafe)
        #expect(SafeCommand.classify(command: "timedatectl") == .alwaysSafe)
        #expect(SafeCommand.classify(command: "timedatectl status") == .alwaysSafe)
        #expect(SafeCommand.classify(command: "timedatectl show -p Timezone") == .alwaysSafe)
        #expect(SafeCommand.classify(command: "resolvectl query db.internal") == .alwaysSafe)
        #expect(SafeCommand.classify(command: "resolvectl status") == .alwaysSafe)
        #expect(SafeCommand.classify(command: "hostnamectl status") == .alwaysSafe)

        #expect(SafeCommand.classify(command: "timedatectl set-timezone UTC") == .needsJudgment)
        #expect(SafeCommand.classify(command: "timedatectl set-ntp false") == .needsJudgment)
        #expect(SafeCommand.classify(command: "resolvectl flush-caches") == .needsJudgment)
        #expect(SafeCommand.classify(command: "resolvectl dns eth0 1.1.1.1") == .needsJudgment)
        #expect(SafeCommand.classify(command: "hostnamectl set-hostname changed") == .needsJudgment)

        let remoteInspection = "ssh root@example.com 'cat /etc/resolv.conf; "
            + "getent hosts db.internal; timedatectl status; resolvectl query db.internal'"
        #expect(SafeCommand.classify(command: remoteInspection) == .alwaysSafe)

        let productionShape = "ssh -o ConnectTimeout=15 "
            + "-o StrictHostKeyChecking=accept-new root@example.com "
            + "'getent hosts db.internal; timedatectl status'"
        let productionDecision = AgentSandboxPolicy.commandDecision(
            command: productionShape,
            rootDirectory: URL(fileURLWithPath: "/tmp/willdeep-ops-inspection")
        )
        #expect(productionDecision.mode == .readOnlyNetwork)
        #expect(!productionDecision.requiresUserApproval)
        #expect(!productionDecision.requiresTypedConfirmation)
    }

    @Test
    func testSafeCommandNetworkFetcherBoundaries() {
        #expect(SafeCommand.classify(command: "curl https://example.com/status") == .needsJudgment)
        #expect(SafeCommand.classify(command: "curl -fsSL https://example.com/status | jq .") == .needsJudgment)
        #expect(SafeCommand.classify(command: "wget https://example.com/report.json") == .needsJudgment)

        #expect(SafeCommand.classify(command: "curl -X POST https://example.com/deploy") == .needsJudgment)
        #expect(SafeCommand.classify(command: "curl -d '{\"probe\":true}' https://example.com/test") == .needsJudgment)
        #expect(SafeCommand.classify(command: "curl -H 'Authorization: Bearer value' https://example.com") == .needsJudgment)
        #expect(SafeCommand.classify(command: "curl -o payload.txt https://example.com") == .alwaysDangerous)
        #expect(SafeCommand.classify(command: "curl --upload-file payload.txt https://example.com") == .alwaysDangerous)
        #expect(SafeCommand.classify(command: "curl file:///etc/passwd") == .alwaysDangerous)
        #expect(SafeCommand.classify(command: "wget --post-data=a=1 https://example.com") == .alwaysDangerous)
    }

    @Test
    func credentialCurlLoopUsesRedactedSmartReview() {
        let secret = "sk_testCredentialValue123456789"
        let command = """
        API_KEY=\"\(secret)\"
        MODELS=\"alpha beta\"
        for model in $MODELS; do curl -sS -X POST -H \"Authorization: Bearer $API_KEY\" -H \"Content-Type: application/json\" -d '{\"model\":\"'$model'\",\"prompt\":\"OK\"}' https://example.com/v1/chat/completions; done
        """

        #expect(SafeCommand.classify(command: command) == .needsJudgment)
        #expect(SafeCommand.containsNetworkFetcherInvocation(command))
        let redacted = AgentInjectionDefense.redactedCommandForSafetyJudge(command)
        #expect(!redacted.contains(secret))
        #expect(redacted.contains("API_KEY=\"[REDACTED]\""))
        #expect(redacted.contains("Authorization: [REDACTED]"))
        #expect(redacted.contains("-X POST"))
        #expect(redacted.contains("/v1/chat/completions"))

        let decision = AgentSandboxPolicy.commandDecision(
            command: command,
            rootDirectory: URL(fileURLWithPath: "/tmp/willdeep-redacted-curl-review")
        )
        #expect(decision.mode == .escalated)
        #expect(decision.requiresUserApproval)
        #expect(!decision.requiresTypedConfirmation)
        #expect(AppState.canSendToSafetyJudge(toolName: "run_command", sandboxDecision: decision))

        let payload = AgentInjectionDefense.judgeUserPayload(command: redacted)
        #expect(!payload.contains(secret))
        #expect(payload.contains("[REDACTED]"))

        let history = AgentInjectionDefense.judgeHistoryContext(
            approved: ["curl -H 'Authorization: Bearer \(secret)' https://example.com/v1/models"],
            rejected: []
        )
        #expect(!history.contains(secret))
        #expect(history.contains("Authorization: [REDACTED]"))
    }

    @Test("SafeCommand rejects find with -delete or -exec")
    func testSafeCommandFindRules() {
        #expect(SafeCommand.classify(command: "find . -name '*.swift'") == .alwaysSafe)
        #expect(SafeCommand.classify(command: "find . -name '*.tmp' -delete") == .alwaysDangerous)
        #expect(SafeCommand.classify(command: "find . -name '*.log' -exec rm {} ;") == .alwaysDangerous)
    }

    // MARK: - rc3 token-level hardening

    @Test("SafeCommand: token-level rm detection catches pipeline tails")
    func testSafeCommandTokenLevelRmInPipeline() {
        // Pre-rc3 the pipeline tail `xargs rm` survived because the
        // substring needle `"rm "` only matched if `rm` had a trailing
        // space and was followed by an arg; the lowercased(+" ") trick
        // worked on segments like `rm -rf` but not on `xargs rm` where
        // `rm` was at the start of the second tokens slot.
        #expect(SafeCommand.classify(command: "find . -name '*.tmp' | xargs rm") == .alwaysDangerous)
        #expect(SafeCommand.classify(command: "find . -name '*.tmp' | xargs rm -rf") == .alwaysDangerous)
        #expect(SafeCommand.classify(command: "find . -print0 | xargs -0 rm -rf") == .alwaysDangerous)
        // Same shape with `kill` — pre-rc3 needed `"kill "` to match;
        // `... | kill 1234` slipped through. Token check fixes it.
        #expect(SafeCommand.classify(command: "ps aux | grep node | awk '{print $2}' | xargs kill -9") == .alwaysDangerous)
    }

    @Test("SafeCommand: word-boundary kills 'perm'/'armchair' false positives")
    func testSafeCommandFalsePositivesGone() {
        // Pre-rc3 substring match on `"rm "` flagged `"perm "` and
        // anything else containing the literal substring. Token level
        // matching needs `rm` to be its own token.
        // (These don't reach .alwaysSafe — they're not in the allowlist —
        // but they must no longer hit the dangerous path.)
        #expect(SafeCommand.classify(command: "perm /tmp/foo") != .alwaysDangerous)
        #expect(SafeCommand.classify(command: "harmless-tool --opt val") != .alwaysDangerous)
        // Real allowlist word that visually contains "ls" but is its
        // own token must still be safe.
        #expect(SafeCommand.classify(command: "ls -la") == .alwaysSafe)
    }

    @Test("SafeCommand: cp/ln dangerous only when a flag is present")
    func testSafeCommandCpLnFlagGate() {
        // Pre-rc3 `"cp -"` substring meant `cp -r` was caught (yes) but
        // `cp src dst` was correctly NOT marked dangerous. We preserve
        // that nuance after tokenization.
        #expect(SafeCommand.classify(command: "cp -r foo bar") == .alwaysDangerous)
        #expect(SafeCommand.classify(command: "cp -R foo bar") == .alwaysDangerous)
        #expect(SafeCommand.classify(command: "ln -s a b") == .alwaysDangerous)
        #expect(SafeCommand.classify(command: "ln -sf a b") == .alwaysDangerous)
        // Plain forms fall through to needsJudgment (not auto-run).
        #expect(SafeCommand.classify(command: "cp foo bar") == .needsJudgment)
        #expect(SafeCommand.classify(command: "ln a b") == .needsJudgment)
    }

    @Test("SafeCommand: low-risk creation commands auto-approve")
    func testSafeCommandWorkspaceCreate() {
        // mkdir/touch/mktemp write, but only create — auto-approve so the
        // agent doesn't stall on `mkdir -p build/`.
        #expect(SafeCommand.classify(command: "mkdir build") == .alwaysSafe)
        #expect(SafeCommand.classify(command: "mkdir -p src/a/b") == .alwaysSafe)
        #expect(SafeCommand.classify(command: "touch README.md") == .alwaysSafe)
        #expect(SafeCommand.classify(command: "mktemp -d") == .alwaysSafe)
        // A destructive token anywhere in the pipeline still wins.
        #expect(SafeCommand.classify(command: "mkdir foo && rm -rf bar") == .alwaysDangerous)
        // Redirection out of a creation command is still refused.
        #expect(SafeCommand.classify(command: "touch foo > /etc/passwd") == .alwaysDangerous)
    }

    @Test("SafeCommand: dangerousSubstrings cover token-less shapes")
    func testSafeCommandDangerousSubstrings() {
        // Fork bomb — no whitespace, tokenize returns one giant token,
        // substring scan catches it.
        #expect(SafeCommand.classify(command: ":(){:|:&};:") == .alwaysDangerous)
        // dd if= — the `=` glues the dangerous bit into the first token.
        #expect(SafeCommand.classify(command: "dd if=/dev/zero of=/dev/sda bs=1m") == .alwaysDangerous)
        // mkfs.* family — `mkfs.ext4`, `mkfs.hfs` etc.
        #expect(SafeCommand.classify(command: "mkfs.ext4 /dev/sda1") == .alwaysDangerous)
        #expect(SafeCommand.classify(command: "mkfs.hfs /dev/disk2") == .alwaysDangerous)
    }

    @Test("SafeCommand: `su` joins sudo/doas as privilege escalation")
    func testSafeCommandSuAddedToTokens() {
        // Added in rc3 alongside sudo/doas — equally dangerous and the
        // pre-rc3 needle list missed it.
        #expect(SafeCommand.classify(command: "su - root") == .alwaysDangerous)
        #expect(SafeCommand.classify(command: "su -c 'whoami'") == .alwaysDangerous)
    }

    @Test("SafeCommand treats cd/pushd/popd as alwaysSafe")
    func testSafeCommandCdAllowed() {
        // The common "navigate then read" chain the agent emits.
        #expect(SafeCommand.classify(command: "cd /tmp/proj && git status") == .alwaysSafe)
        #expect(SafeCommand.classify(command: "cd /tmp/proj && git status --short | grep '^\\(M\\|A\\|D\\|R\\|C\\)' | head -20") == .alwaysSafe)
        #expect(SafeCommand.classify(command: "cd ~") == .alwaysSafe)
        #expect(SafeCommand.classify(command: "pushd /tmp && ls && popd") == .alwaysSafe)
        // Command substitution must still kill the whole line — that
        // gate sits above the per-token check.
        #expect(SafeCommand.classify(command: "cd $(rm -rf /)") == .alwaysDangerous)
    }

    // MARK: - run_command risk and sandbox policy

    @Test("agent tool registry escalates dangerous run_command invocations to .danger")
    func testRunCommandRiskEscalatesForDestructiveShell() {
        let benignRisk = AgentToolRegistry.risk(
            for: "run_command",
            arguments: ["command": .string("ls -la")]
        )
        let dangerousRisk = AgentToolRegistry.risk(
            for: "run_command",
            arguments: ["command": .string("rm -rf build/output")]
        )
        let forcePushRisk = AgentToolRegistry.risk(
            for: "run_command",
            arguments: ["command": .string("git push --force origin main")]
        )
        let forcePushWithDirectoryRisk = AgentToolRegistry.risk(
            for: "run_command",
            arguments: ["command": .string("git -C /Users/rocky/Sites/Xedit push --force origin main")],
            rootDirectory: URL(fileURLWithPath: "/Users/rocky/Sites/Xedit")
        )

        #expect(benignRisk == .read)
        #expect(dangerousRisk == .danger)
        #expect(forcePushRisk == .danger)
        #expect(forcePushWithDirectoryRisk == .danger)
    }

    @Test("run_command classifies cd plus read-only commands as read risk")
    func testRunCommandRiskAllowsReadOnlyShellChains() {
        let gitDiffRisk = AgentToolRegistry.risk(
            for: "run_command",
            arguments: ["command": .string("cd Xedit && git diff")]
        )
        let grepRisk = AgentToolRegistry.risk(
            for: "run_command",
            arguments: ["command": .string("cd Sources; rg \"AgentTool\" .")]
        )
        let writeAfterCDRisk = AgentToolRegistry.risk(
            for: "run_command",
            arguments: ["command": .string("cd Xedit && git add AgentTools.swift")]
        )
        let unsafeCDRisk = AgentToolRegistry.risk(
            for: "run_command",
            arguments: ["command": .string("cd .. && git diff")]
        )
        let redirectedReadRisk = AgentToolRegistry.risk(
            for: "run_command",
            arguments: ["command": .string("cd Xedit && git diff > /tmp/out.patch")]
        )
        let harmlessRedirectionRisk = AgentToolRegistry.risk(
            for: "run_command",
            arguments: ["command": .string("cd Xedit && git status 2>/dev/null")]
        )
        let goBuildRisk = AgentToolRegistry.risk(
            for: "run_command",
            arguments: ["command": .string("cd /Users/rocky/Sites/Xedit && go build -o bin/metaserver . 2>&1")],
            rootDirectory: URL(fileURLWithPath: "/Users/rocky/Sites/Xedit")
        )
        let goBuildWithWorkspaceCacheCommand = "cd /Users/rocky/Sites/Xedit && GOCACHE=$(pwd)/.cache/go-build GOMODCACHE=$(pwd)/.cache/go-mod go build -o bin/metaserver . 2>&1"
        let goBuildWithWorkspaceCacheRisk = AgentToolRegistry.risk(
            for: "run_command",
            arguments: ["command": .string(goBuildWithWorkspaceCacheCommand)],
            rootDirectory: URL(fileURLWithPath: "/Users/rocky/Sites/Xedit")
        )
        let yarnDevRisk = AgentToolRegistry.risk(
            for: "run_command",
            arguments: ["command": .string("yarn run dev")],
            rootDirectory: URL(fileURLWithPath: "/Users/rocky/Sites/Xedit")
        )
        let npmInstallRisk = AgentToolRegistry.risk(
            for: "run_command",
            arguments: ["command": .string("npm install left-pad")],
            rootDirectory: URL(fileURLWithPath: "/Users/rocky/Sites/Xedit")
        )
        let npmRegistryInstallRisk = AgentToolRegistry.risk(
            for: "run_command",
            arguments: ["command": .string("npm --registry https://registry.npmjs.org install left-pad")],
            rootDirectory: URL(fileURLWithPath: "/Users/rocky/Sites/Xedit")
        )
        let npmGlobalInstallRisk = AgentToolRegistry.risk(
            for: "run_command",
            arguments: ["command": .string("npm install -g left-pad")],
            rootDirectory: URL(fileURLWithPath: "/Users/rocky/Sites/Xedit")
        )
        let redirectedDecision = AgentSandboxPolicy.commandDecision(
            command: "cd Xedit && git diff > /tmp/out.patch",
            rootDirectory: nil
        )
        let harmlessRedirectionDecision = AgentSandboxPolicy.commandDecision(
            command: "cd Xedit && git status 2>/dev/null",
            rootDirectory: nil
        )
        let goBuildDecision = AgentSandboxPolicy.commandDecision(
            command: "cd /Users/rocky/Sites/Xedit && go build -o bin/metaserver . 2>&1",
            rootDirectory: URL(fileURLWithPath: "/Users/rocky/Sites/Xedit")
        )
        let goBuildWithWorkspaceCacheDecision = AgentSandboxPolicy.commandDecision(
            command: goBuildWithWorkspaceCacheCommand,
            rootDirectory: URL(fileURLWithPath: "/Users/rocky/Sites/Xedit")
        )
        let unsafeGoBuildCacheDecision = AgentSandboxPolicy.commandDecision(
            command: "cd /Users/rocky/Sites/Xedit && GOCACHE=$(rm -rf /tmp/cache) go build -o bin/metaserver .",
            rootDirectory: URL(fileURLWithPath: "/Users/rocky/Sites/Xedit")
        )
        let npmInstallDecision = AgentSandboxPolicy.commandDecision(
            command: "npm install left-pad",
            rootDirectory: URL(fileURLWithPath: "/Users/rocky/Sites/Xedit")
        )
        let npmRegistryInstallDecision = AgentSandboxPolicy.commandDecision(
            command: "npm --registry https://registry.npmjs.org install left-pad",
            rootDirectory: URL(fileURLWithPath: "/Users/rocky/Sites/Xedit")
        )
        let npmGlobalInstallDecision = AgentSandboxPolicy.commandDecision(
            command: "npm install -g left-pad",
            rootDirectory: URL(fileURLWithPath: "/Users/rocky/Sites/Xedit")
        )
        let heredocDecision = AgentSandboxPolicy.commandDecision(
            command: """
            cat > Sources/App/main.go << 'GOEOF'
            package main

            import "fmt"

            func main() {
                fmt.Println("$(literal shell-looking text in generated code)")
            }
            GOEOF
            """,
            rootDirectory: URL(fileURLWithPath: "/tmp/willdeep-test-workspace")
        )

        #expect(gitDiffRisk == .read)
        #expect(grepRisk == .read)
        #expect(writeAfterCDRisk == .write)
        #expect(unsafeCDRisk == .write)
        // `/tmp/out.patch` is an explicit external target. The preflight
        // preserves that target by escalating before launch instead of
        // pretending it is a workspace-contained write.
        #expect(redirectedDecision.mode == .escalated)
        #expect(redirectedDecision.requiresTypedConfirmation == false)
        #expect(harmlessRedirectionDecision.mode == .readOnly)
        #expect(harmlessRedirectionDecision.requiresTypedConfirmation == false)
        #expect(heredocDecision.mode == .workspaceWrite)
        #expect(heredocDecision.requiresTypedConfirmation == false)
        #expect(redirectedReadRisk == .write)
        #expect(harmlessRedirectionRisk == .read)
        #expect(goBuildRisk == .write)
        #expect(goBuildWithWorkspaceCacheRisk == .write)
        #expect(yarnDevRisk == .write)
        #expect(npmInstallRisk == .write)
        #expect(npmRegistryInstallRisk == .write)
        #expect(npmGlobalInstallRisk == .write)
        // Builds carry the registry grant: `go build` resolves modules through
        // GOPROXY on a cold cache. Writes stay confined to the workspace.
        #expect(goBuildDecision.mode == .workspaceWriteNetworkCredentialed)
        #expect(goBuildDecision.requiresTypedConfirmation == false)
        #expect(goBuildWithWorkspaceCacheDecision.mode == .workspaceWriteNetworkCredentialed)
        #expect(goBuildWithWorkspaceCacheDecision.requiresUserApproval == true)
        #expect(goBuildWithWorkspaceCacheDecision.requiresTypedConfirmation == false)
        #expect(AgentSandboxPolicy.canAutoApproveWorkspaceWriteCommand(
            command: goBuildWithWorkspaceCacheCommand,
            rootDirectory: URL(fileURLWithPath: "/Users/rocky/Sites/Xedit")
        ))
        #expect(unsafeGoBuildCacheDecision.mode == .escalated)
        #expect(unsafeGoBuildCacheDecision.requiresTypedConfirmation == true)
        #expect(!AgentSandboxPolicy.canAutoApproveWorkspaceWriteCommand(
            command: "cd /Users/rocky/Sites/Xedit && GOCACHE=$(rm -rf /tmp/cache) go build -o bin/metaserver .",
            rootDirectory: URL(fileURLWithPath: "/Users/rocky/Sites/Xedit")
        ))
        #expect(npmInstallDecision.mode == .workspaceWriteNetworkCredentialed)
        #expect(npmInstallDecision.requiresTypedConfirmation == false)
        #expect(npmRegistryInstallDecision.mode == .workspaceWriteNetworkCredentialed)
        #expect(npmRegistryInstallDecision.requiresTypedConfirmation == false)
        #expect(AgentSandboxPolicy.canAutoApproveWorkspaceWriteCommand(
            command: "npm install left-pad",
            rootDirectory: URL(fileURLWithPath: "/Users/rocky/Sites/Xedit")
        ))
        #expect(AgentSandboxPolicy.canAutoApproveWorkspaceWriteCommand(
            command: "npm --registry https://registry.npmjs.org install left-pad",
            rootDirectory: URL(fileURLWithPath: "/Users/rocky/Sites/Xedit")
        ))
        #expect(npmGlobalInstallDecision.mode == .workspaceWrite)
        #expect(!AgentSandboxPolicy.canAutoApproveWorkspaceWriteCommand(
            command: "npm install -g left-pad",
            rootDirectory: URL(fileURLWithPath: "/Users/rocky/Sites/Xedit")
        ))
        #expect(!AgentSandboxPolicy.canAutoApproveWorkspaceWriteCommand(
            command: "npm publish",
            rootDirectory: URL(fileURLWithPath: "/Users/rocky/Sites/Xedit")
        ))
    }

    @Test("run_command allows workspace absolute cd for read-only commands")
    func testRunCommandRiskAllowsWorkspaceAbsoluteReadOnlyShellChains() {
        let workspace = URL(fileURLWithPath: "/Users/rocky/Sites/Xedit").standardizedFileURL
        let sourceDirectory = workspace.appendingPathComponent("Xedit").standardizedFileURL

        let gitDiffRisk = AgentToolRegistry.risk(
            for: "run_command",
            arguments: ["command": .string("cd \(workspace.path) && git diff")],
            rootDirectory: workspace
        )
        let rgRisk = AgentToolRegistry.risk(
            for: "run_command",
            arguments: ["command": .string("cd \(sourceDirectory.path) && rg AgentTool .")],
            rootDirectory: workspace
        )
        let gitDashCRisk = AgentToolRegistry.risk(
            for: "run_command",
            arguments: ["command": .string("git -C \(workspace.path) diff -- Xedit/AgentTools.swift")],
            rootDirectory: workspace
        )
        let outsideCDRisk = AgentToolRegistry.risk(
            for: "run_command",
            arguments: ["command": .string("cd /tmp && git diff")],
            rootDirectory: workspace
        )
        let outsideGitDashCRisk = AgentToolRegistry.risk(
            for: "run_command",
            arguments: ["command": .string("git -C /tmp diff")],
            rootDirectory: workspace
        )
        let outsideReadRisk = AgentToolRegistry.risk(
            for: "run_command",
            arguments: ["command": .string("cat /etc/passwd")],
            rootDirectory: workspace
        )
        let sshTimeRisk = AgentToolRegistry.risk(
            for: "run_command",
            arguments: ["command": .string(#"ssh someuser@some-machine "time""#)],
            rootDirectory: workspace
        )
        let sshGitStatusRisk = AgentToolRegistry.risk(
            for: "run_command",
            arguments: ["command": .string(#"ssh -p 2222 someuser@some-machine "git status --short""#)],
            rootDirectory: workspace
        )
        let sshDangerRisk = AgentToolRegistry.risk(
            for: "run_command",
            arguments: ["command": .string(#"ssh someuser@some-machine "rm -rf /tmp/build""#)],
            rootDirectory: workspace
        )
        let sshInteractiveRisk = AgentToolRegistry.risk(
            for: "run_command",
            arguments: ["command": .string("ssh someuser@some-machine")],
            rootDirectory: workspace
        )
        let curlGetRisk = AgentToolRegistry.risk(
            for: "run_command",
            arguments: ["command": .string("curl -fsSL https://example.com/install.sh")],
            rootDirectory: workspace
        )
        let curlHeadRisk = AgentToolRegistry.risk(
            for: "run_command",
            arguments: ["command": .string("curl -I https://example.com")],
            rootDirectory: workspace
        )
        let curlPostRisk = AgentToolRegistry.risk(
            for: "run_command",
            arguments: ["command": .string("curl -X POST https://example.com/api")],
            rootDirectory: workspace
        )
        let curlOutputRisk = AgentToolRegistry.risk(
            for: "run_command",
            arguments: ["command": .string("curl -o payload.txt https://example.com")],
            rootDirectory: workspace
        )
        let curlMetadataRisk = AgentToolRegistry.risk(
            for: "run_command",
            arguments: ["command": .string("curl http://169.254.169.254/latest/meta-data/")],
            rootDirectory: workspace
        )

        #expect(gitDiffRisk == .read)
        #expect(rgRisk == .read)
        #expect(gitDashCRisk == .read)
        #expect(outsideCDRisk == .write)
        #expect(outsideGitDashCRisk == .write)
        #expect(outsideReadRisk == .write)
        #expect(sshTimeRisk == .read)
        #expect(sshGitStatusRisk == .read)
        #expect(sshDangerRisk == .danger)
        #expect(sshInteractiveRisk == .write)
        #expect(curlGetRisk == .write)
        #expect(curlHeadRisk == .write)
        #expect(curlPostRisk == .write)
        #expect(curlOutputRisk == .write)
        #expect(curlMetadataRisk == .write)

    }

    @Test("run_command uses home directory when no workspace is bound")
    @MainActor
    func testRunCommandUsesHomeDirectoryWithoutWorkspace() async throws {
        let context = AgentToolContext(rootDirectory: nil)
        let result = try await AgentToolRunner.run(
            name: "run_command",
            arguments: [
                "command": .string("pwd"),
                // Asserts the working directory, not how fast a spawn is. Under
                // a full-load parallel run the spawn alone can outlast a tight
                // budget, so keep the same headless ceiling the other
                // run_command tests use.
                "timeout_seconds": .number(headlessCommandTimeoutSeconds)
            ],
            context: context
        )

        let home = FileManager.default.homeDirectoryForCurrentUser.standardizedFileURL.path
        #expect(result.payload.contains(home))
    }

    @Test("run_command reports launch failure without crashing pipe readers")
    @MainActor
    func testRunCommandLaunchFailureDoesNotCrash() async {
        let missingWorkspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("willdeep_missing_run_command_\(UUID().uuidString)")
        let context = AgentToolContext(
            rootDirectory: missingWorkspace,
            sandboxMode: .escalated
        )

        do {
            _ = try await AgentToolRunner.run(
                name: "run_command",
                arguments: [
                    "command": .string("pwd"),
                    "timeout_seconds": .number(headlessCommandTimeoutSeconds)
                ],
                context: context
            )
            Issue.record("run_command unexpectedly launched in a missing working directory")
        } catch {
            #expect(!error.localizedDescription.isEmpty)
        }
    }

    @Test("run_command drains large output without hanging")
    @MainActor
    func testRunCommandDrainsLargeOutput() async throws {
        let workspace = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            .appendingPathComponent("willdeep_test_run_command_output_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        let context = AgentToolContext(rootDirectory: workspace)
        // Timeout sized for CI: the GitHub Actions macos-26 runner
        // takes ~5s to spawn ruby + write 200 KB to stdout (this test
        // failed rc5 at 5.186s against the previous 5s budget). Local
        // M-series machines finish in ~200ms so this only matters as
        // headroom. The test's intent ("doesn't hang on a full pipe")
        // is unchanged — the assertion still requires exit 0 + the
        // `[truncated]` marker; the timeout is only the upper bound
        // for "this command actually ran".
        let result = try await AgentToolRunner.run(
            name: "run_command",
            arguments: [
                "command": .string("/usr/bin/ruby -e 'STDOUT.write(\"x\" * 200000)'"),
                "timeout_seconds": .number(30)
            ],
            context: context
        )

        #expect(result.summary.hasPrefix("exit 0"))
        #expect(result.payload.contains("[truncated]"))
    }

    @Test("run_command exposes common user binary paths")
    func testRunCommandUsesSupplementalShellPath() {
        // Originally this ran `printf '%s' "$PATH"` through run_command and
        // asserted on the output. That's flaky on CI: run_command goes through
        // `sandbox-exec`, and on the virtualized GitHub macOS runner seatbelt
        // does not reliably propagate the injected PATH to the child `/bin/sh`
        // — the test passes locally but fails in CI with an empty $PATH.
        // Assert the deterministic injection logic instead: `shellEnvironment`
        // is exactly the environment run_command hands the child process, so
        // testing it covers the same intent without depending on seatbelt's
        // env passing inside CI virtualization.
        let environment = AgentToolRunner.shellEnvironment(from: ["PATH": "/usr/bin:/bin"])
        let path = environment["PATH"] ?? ""
        #expect(path.contains("/opt/homebrew/bin"))
        #expect(path.contains("/usr/local/bin"))
        // Pre-existing entries are preserved; supplemental dirs are appended.
        #expect(path.contains("/usr/bin"))
    }

}

@Suite
@MainActor
struct AgentScheduledReadOnlySSHTests {
    @Test("plain SSH inherits only a recursively proven read-only remote command")
    func classifiesRemoteLogInspectionWithoutBlessingMutations() {
        #expect(SafeCommand.classify(
            command: #"ssh root@h1.niuwoai.com 'journalctl -u niuwo --since "24 hours ago" --no-pager'"#
        ) == .alwaysSafe)
        #expect(SafeCommand.classify(
            command: #"ssh -p 2222 root@h1.niuwoai.com 'systemctl show niuwo -p ActiveEnterTimestamp -p RestartCount; systemctl status sslcat --no-pager'"#
        ) == .alwaysSafe)
        #expect(SafeCommand.classify(
            command: #"ssh root@h1.niuwoai.com 'journalctl -u niuwo --since "24 hours ago" --no-pager | grep -Ei "error|failed|panic" | head -20'"#
        ) == .alwaysSafe)

        #expect(SafeCommand.classify(
            command: "ssh root@h1.niuwoai.com 'systemctl restart niuwo'"
        ) == .needsJudgment)
        #expect(SafeCommand.classify(
            command: "ssh root@h1.niuwoai.com 'systemctl cat niuwo'"
        ) == .needsJudgment)
        #expect(SafeCommand.classify(
            command: "ssh root@h1.niuwoai.com 'journalctl --rotate'"
        ) == .needsJudgment)
        #expect(SafeCommand.classify(
            command: "ssh root@h1.niuwoai.com 'journalctl -u niuwo > /tmp/niuwo.log'"
        ) == .alwaysDangerous)
        #expect(SafeCommand.classify(command: "ssh root@h1.niuwoai.com") == .needsJudgment)
        #expect(SafeCommand.classify(
            command: #"ssh -o ProxyCommand=helper root@h1.niuwoai.com 'journalctl -u niuwo'"#
        ) == .needsJudgment)
    }

    @Test("read-only SSH selects an unattended network sandbox")
    func selectsReadOnlyNetworkWithoutApproval() {
        let workspace = URL(fileURLWithPath: "/tmp/willdeep-workspace")
        let decision = AgentSandboxPolicy.commandDecision(
            command: #"ssh root@h1.niuwoai.com 'journalctl -u niuwo --since "24 hours ago" --no-pager'"#,
            rootDirectory: workspace
        )

        #expect(decision.mode == .readOnlyNetwork)
        #expect(!decision.requiresUserApproval)
        #expect(!decision.requiresTypedConfirmation)
    }

    @Test("read-only network sandbox permits SSH but denies workspace writes")
    func keepsNetworkedInspectionFilesystemReadOnly() {
        guard FileManager.default.isExecutableFile(atPath: "/usr/bin/sandbox-exec") else { return }
        let root = URL(fileURLWithPath: "/tmp/willdeep-workspace")
        let launch = AgentSandboxPolicy.shellLaunch(
            command: #"ssh root@h1.niuwoai.com 'journalctl -u niuwo --no-pager'"#,
            mode: .readOnlyNetwork,
            rootDirectory: root
        )
        let profile = launch.arguments.first { $0.contains("allow network") } ?? ""

        #expect(profile.contains("(allow network*)"))
        #expect(!profile.contains("(subpath \"\(root.path)\")"))
        #expect(profile.contains("(literal \"/dev/null\")"))
    }

    @Test("ordinary Smart conversations statically approve visible-terminal SSH inspection")
    func ordinaryConversationReusesReadOnlyNetworkPolicy() async {
        let appState = AppState()
        let approval = await appState.autoApprovalSource(
            toolName: "terminal_send_command",
            arguments: [
                "command": .string(
                    #"ssh root@h1.niuwoai.com 'journalctl -u niuwo --since "24 hours ago" --no-pager'"#
                )
            ],
            risk: .write,
            rootDirectory: URL(fileURLWithPath: "/tmp/willdeep-workspace"),
            interactionMode: .normal,
            approvalMode: .smart
        )

        #expect(approval == .staticAllowlist)
    }
}

@Suite
struct AgentProjectWorkspaceCommandSafetyTests {
    @Test("read-only commands accept absolute paths in another Project root")
    func sandboxAcceptsAdditionalProjectRoot() {
        let primary = URL(fileURLWithPath: "/tmp/willdeep-frontend")
        let backend = URL(fileURLWithPath: "/tmp/willdeep-backend")
        let decision = AgentSandboxPolicy.commandDecision(
            command: "sed -n '1,20p' /tmp/willdeep-backend/app/service.swift",
            rootDirectory: primary,
            additionalWorkspaceRoots: [backend]
        )

        #expect(decision.mode == .readOnly)
        #expect(!decision.requiresUserApproval)
    }

    @Test("workspace-write sandbox grants every Project root")
    func sandboxProfileIncludesAdditionalProjectRoot() {
        let primary = URL(fileURLWithPath: "/tmp/willdeep-frontend")
        let backend = URL(fileURLWithPath: "/tmp/willdeep-backend")
        let launch = AgentSandboxPolicy.shellLaunch(
            command: "touch /tmp/willdeep-backend/generated.txt",
            mode: .workspaceWrite,
            rootDirectory: primary,
            additionalWorkspaceRoots: [backend]
        )

        let profile = launch.arguments.dropFirst().first ?? ""
        #expect(profile.contains("/tmp/willdeep-frontend"))
        #expect(profile.contains("/tmp/willdeep-backend"))
    }

}

/// 沙箱网络策略：构建取依赖、只读网络诊断，以及"拒网被误读成 DNS 故障"的识别。
///
/// 刻意独立成 suite 而不是挂进 `WillDeepTests`：函数级 `-only-testing`
/// 选择器匹配不到那个聚合 suite，会静默跑 0 个用例却报 `TEST SUCCEEDED`。
/// 独立后可以 `-only-testing:XeditTests/AgentSandboxNetworkPolicyTests`
/// 精确复跑。
@Suite("沙箱网络策略")
struct AgentSandboxNetworkPolicyTests {
    @Test("workspace builds may fetch dependencies over the network")
    func buildCommandsGetWorkspaceNetwork() {
        let root = URL(fileURLWithPath: "/Users/rocky/Sites/Xedit")

        for command in [
            "go build ./...",
            "cargo build --release",
            "swift build",
            "npm run build",
            "yarn build",
            "make all",
            "xcodebuild -scheme Xedit build"
        ] {
            let decision = AgentSandboxPolicy.commandDecision(
                command: command,
                rootDirectory: root
            )
            // 1.263.0：构建工具除了 registry 网络，还需要真实 HOME 才能读到
            // `~/.npmrc` / `~/.gitconfig` / `~/.cargo/config`。写入限制不变。
            #expect(
                decision.mode == .workspaceWriteNetworkCredentialed,
                "\(command) should build with registry access, got \(decision.mode)"
            )
            #expect(!decision.requiresTypedConfirmation)
        }
    }

    @Test("global installs stay outside the workspace network grant")
    func globalInstallDoesNotGetNetwork() {
        let root = URL(fileURLWithPath: "/Users/rocky/Sites/Xedit")

        for command in ["npm install -g left-pad", "yarn --global add left-pad"] {
            let decision = AgentSandboxPolicy.commandDecision(
                command: command,
                rootDirectory: root
            )
            #expect(
                decision.mode == .workspaceWrite,
                "\(command) writes outside the workspace and must not gain network"
            )
        }
    }

    @Test("read-only network diagnostics run without approval")
    func networkDiagnosticsAreAutoApproved() {
        let root = URL(fileURLWithPath: "/Users/rocky/Sites/Xedit")

        for command in [
            "ping -c 1 goproxy.cn",
            "dig +short proxy.golang.org",
            "nslookup repo.yarnpkg.com",
            "host registry.npmjs.org",
            "traceroute goproxy.cn",
            "netstat -an"
        ] {
            let decision = AgentSandboxPolicy.commandDecision(
                command: command,
                rootDirectory: root
            )
            #expect(
                decision.mode == .readOnlyNetwork,
                "\(command) is a read-only diagnostic, got \(decision.mode)"
            )
            #expect(
                !decision.requiresUserApproval,
                "\(command) should not prompt for approval"
            )
        }
    }
    /// 1.358.0-rc1：合成 HOME 拆掉之后，`git config --global --list` 直接就能
    /// 读到真实 `~/.gitconfig`，原来那条 `GIT_CONFIG_GLOBAL` 窄例外连同它的
    /// 静态判定一起删了。这里改钉新的边界：HOME 是真的，钥匙仍然只给凭证档。
    @Test("非凭证档保留真实 HOME，但拿不到 ssh-agent")
    func sandboxedEnvironmentKeepsRealHomeWithoutKeys() {
        let realHome = FileManager.default.homeDirectoryForCurrentUser.path
        let environment = AgentSandboxPolicy.sandboxedEnvironment(
            mode: .readOnly,
            rootDirectory: URL(fileURLWithPath: "/Users/rocky/Sites/Xedit"),
            command: "git config --global --list --show-origin 2>&1 | head -20",
            base: ["HOME": realHome, "SSH_AUTH_SOCK": "/tmp/agent.sock"]
        )
        #expect(environment["HOME"] == realHome)
        #expect(environment["SSH_AUTH_SOCK"] == nil)
        #expect(environment["GIT_CONFIG_GLOBAL"] == nil)
        #expect(!AgentSandboxPolicy.redirectsHome(.readOnly))

        let credentialed = AgentSandboxPolicy.sandboxedEnvironment(
            mode: .workspaceWriteNetworkCredentialed,
            rootDirectory: URL(fileURLWithPath: "/Users/rocky/Sites/Xedit"),
            base: ["HOME": realHome, "SSH_AUTH_SOCK": "/tmp/agent.sock"]
        )
        #expect(credentialed["HOME"] == realHome)
        #expect(credentialed["SSH_AUTH_SOCK"] == "/tmp/agent.sock")
    }

    @Test("a read-only delegated target command does not become a write operation")
    func readOnlyDelegatedCommandStaysReadOnly() {
        let arguments: [String: AgentJSONValue] = [
            "profile": .string(AgentSubagentProfileCatalog.opsRunnerID),
            "target_command": .string("git config --global --list --show-origin")
        ]
        #expect(AgentToolRegistry.risk(
            for: "spawn_agent",
            arguments: arguments,
            rootDirectory: URL(fileURLWithPath: "/Users/rocky/Sites/Xedit")
        ) == .read)
        #expect(!AppState.subagentHasExactCommandAuthorization(arguments: arguments))

        let sensitiveArguments: [String: AgentJSONValue] = [
            "profile": .string(AgentSubagentProfileCatalog.opsRunnerID),
            "target_command": .string("cat ~/.ssh/id_ed25519")
        ]
        #expect(AgentToolRegistry.risk(
            for: "spawn_agent",
            arguments: sensitiveArguments,
            rootDirectory: URL(fileURLWithPath: "/Users/rocky/Sites/Xedit")
        ) != .read)
        #expect(AppState.subagentHasExactCommandAuthorization(
            arguments: sensitiveArguments,
            rootDirectory: URL(fileURLWithPath: "/Users/rocky/Sites/Xedit")
        ))
    }

    /// 1.358.0-rc1 起沙箱不再拒网络，所以"域名解析失败"在任何档位下都只能
    /// 是真的解析失败。反过来解释会把排查引进一堵不存在的墙——这条弯路正是
    /// 当初加这层识别要避免的，只是墙拆了之后，识别本身成了那堵墙。
    @Test("网络已放行，DNS 形状的失败在任何档位都不算沙箱拒绝")
    func dnsShapedFailuresAreNeverSandboxDenials() {
        let outputs = [
            "dial tcp: lookup proxy.golang.org: no such host",
            "socket.gaierror: [Errno 8] nodename nor servname provided, or not known",
            "npm ERR! getaddrinfo ENOTFOUND registry.npmjs.org",
            "curl: (6) Could not resolve host: goproxy.cn"
        ]

        for mode in [AgentSandboxMode.readOnly, .readOnlyNetwork, .workspaceWrite,
                     .workspaceWriteNetwork, .workspaceWriteNetworkCredentialed, .escalated] {
            #expect(!AgentSandboxPolicy.deniesNetwork(mode), "\(mode.rawValue)")
            for output in outputs {
                #expect(
                    !AgentSandboxPolicy.looksLikeSandboxDenial(
                        exitStatus: 1,
                        output: output,
                        sandboxMode: mode
                    ),
                    "\(output) under \(mode.rawValue) is a genuine network failure"
                )
            }
        }
    }

    @Test("common filesystem and runtime denial shapes trigger one-shot recovery")
    func commonFilesystemDenialsCountAsSandboxDenial() {
        let outputs = [
            "mkdir: /Library/Caches/tool: Read-only file system",
            "npm ERR! code EACCES\nnpm ERR! syscall mkdir",
            "Error: EACCES: permission denied, open '/Users/test/.cache/tool'",
            "NSCocoaErrorDomain Code=513: You don’t have permission to save the file.",
            "spawn helper EPERM: operation blocked",
        ]

        for output in outputs {
            #expect(AgentSandboxPolicy.looksLikeSandboxDenial(
                exitStatus: 1,
                output: output,
                sandboxMode: .workspaceWrite
            ))
            #expect(!AgentSandboxPolicy.looksLikeSandboxDenial(
                exitStatus: 1,
                output: output,
                sandboxMode: .escalated
            ))
        }
    }

    @Test("deniesNetwork matches the emitted seatbelt profile")
    func deniesNetworkMatchesProfile() {
        let root = URL(fileURLWithPath: "/tmp/willdeep-frontend")

        for mode in [
            AgentSandboxMode.readOnly,
            .readOnlyNetwork,
            .workspaceWrite,
            .workspaceWriteNetwork
        ] {
            // Must be a command that is sandboxed in *every* mode. Ordinary
            // safe commands (`true`, `touch`) skip seatbelt entirely under
            // `.readOnly`, so there would be no profile to compare against —
            // a network head always keeps the profile.
            let launch = AgentSandboxPolicy.shellLaunch(
                command: "curl -sI https://example.com",
                mode: mode,
                rootDirectory: root
            )
            #expect(
                launch.executableURL.lastPathComponent == "sandbox-exec",
                "\(mode.rawValue): expected a sandboxed launch"
            )
            let profile = launch.arguments.dropFirst().first ?? ""
            let profileDenies = profile.contains("(deny network*)")
            #expect(
                profileDenies == AgentSandboxPolicy.deniesNetwork(mode),
                "\(mode.rawValue): profile and deniesNetwork disagree"
            )
        }
    }
}
