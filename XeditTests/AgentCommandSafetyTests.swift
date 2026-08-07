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
        #expect(SafeCommand.classify(command: "npm publish") == .needsJudgment)
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
        #expect(SafeCommand.classify(command: "clear") == .alwaysSafe)
        #expect(SafeCommand.classify(command: "kubectl get pods -A") == .alwaysSafe)
        #expect(SafeCommand.classify(command: "kubectl -n tokenhub describe deploy api") == .alwaysSafe)
        #expect(SafeCommand.classify(command: "kubectl --context prod logs deploy/api --tail=100") == .alwaysSafe)
        #expect(SafeCommand.classify(command: "kubectl config current-context") == .alwaysSafe)
        #expect(SafeCommand.classify(command: "kubectl auth can-i get pods") == .alwaysSafe)
        #expect(SafeCommand.classify(command: "kubectl rollout status deploy/api") == .alwaysSafe)
        #expect(SafeCommand.classify(command: "NS=tokenhub; kubectl -n $NS get job perf-30m; date -u +%H:%M:%S") == .alwaysSafe)

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

    @Test("SafeCommand: ordinary network reads use the judge, credential and mutation shapes stay manual")
    func testSafeCommandNetworkFetcherBoundaries() {
        #expect(SafeCommand.classify(command: "curl https://example.com/status") == .needsJudgment)
        #expect(SafeCommand.classify(command: "curl -fsSL https://example.com/status | jq .") == .needsJudgment)
        #expect(SafeCommand.classify(command: "wget https://example.com/report.json") == .needsJudgment)

        #expect(SafeCommand.classify(command: "curl -X POST https://example.com/deploy") == .alwaysDangerous)
        #expect(SafeCommand.classify(command: "curl -H 'Authorization: Bearer value' https://example.com") == .alwaysDangerous)
        #expect(SafeCommand.classify(command: "curl -o payload.txt https://example.com") == .alwaysDangerous)
        #expect(SafeCommand.classify(command: "curl file:///etc/passwd") == .alwaysDangerous)
        #expect(SafeCommand.classify(command: "wget --post-data=a=1 https://example.com") == .alwaysDangerous)
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
        #expect(goBuildDecision.mode == .workspaceWrite)
        #expect(goBuildDecision.requiresTypedConfirmation == false)
        #expect(goBuildWithWorkspaceCacheDecision.mode == .workspaceWrite)
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
        #expect(npmInstallDecision.mode == .workspaceWriteNetwork)
        #expect(npmInstallDecision.requiresTypedConfirmation == false)
        #expect(npmRegistryInstallDecision.mode == .workspaceWriteNetwork)
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
