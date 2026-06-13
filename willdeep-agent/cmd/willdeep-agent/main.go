package main

import (
	"context"
	"fmt"
	"os"
	"os/signal"
	"syscall"
	"time"

	"github.com/spf13/cobra"
	"github.com/xurenlu/willdeep/willdeep-agent/internal/agent"
)

func main() {
	if err := newRootCommand().Execute(); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func newRootCommand() *cobra.Command {
	var workspace string
	var jsonOutput bool

	root := &cobra.Command{
		Use:           "willdeep-agent",
		Short:         "Remote runtime daemon for WillDeep",
		SilenceUsage:  true,
		SilenceErrors: true,
	}
	root.PersistentFlags().StringVar(&workspace, "workspace", ".", "workspace root allowed for filesystem, git, and command operations")
	root.PersistentFlags().BoolVar(&jsonOutput, "json", false, "print machine-readable JSON output")

	root.AddCommand(newServeCommand(&workspace))
	root.AddCommand(newServeMobileCommand())
	root.AddCommand(newProbeCommand(&workspace, &jsonOutput))
	root.AddCommand(newVersionCommand(&jsonOutput))
	return root
}

func newServeCommand(workspace *string) *cobra.Command {
	var host string
	var port int
	var token string
	var tokenFile string

	cmd := &cobra.Command{
		Use:   "serve",
		Short: "Start the remote runtime HTTP/WebSocket daemon",
		RunE: func(cmd *cobra.Command, args []string) error {
			cfg, err := agent.NewServerConfig(agent.ServerConfigInput{
				Host:      host,
				Port:      port,
				Workspace: *workspace,
				Token:     token,
				TokenFile: tokenFile,
			})
			if err != nil {
				return err
			}

			ctx, stop := signal.NotifyContext(cmd.Context(), os.Interrupt, syscall.SIGTERM)
			defer stop()
			return agent.Serve(ctx, cfg)
		},
	}
	cmd.Flags().StringVar(&host, "host", "127.0.0.1", "listen host")
	cmd.Flags().IntVar(&port, "port", 8765, "listen port")
	cmd.Flags().StringVar(&token, "token", "", "bearer token; defaults to WILLDEEP_AGENT_TOKEN")
	cmd.Flags().StringVar(&tokenFile, "token-file", "", "file containing bearer token")
	return cmd
}

func newServeMobileCommand() *cobra.Command {
	var host string
	var port int
	var desktopName string
	var desktopToken string
	var pairingTTL time.Duration
	var allowPairing bool
	var pairingBaseURL string

	cmd := &cobra.Command{
		Use:   "serve-mobile",
		Short: "Start the LAN mobile gateway for WillDeep",
		RunE: func(cmd *cobra.Command, args []string) error {
			cfg, err := agent.NewMobileGatewayConfig(agent.MobileGatewayConfigInput{
				Host:           host,
				Port:           port,
				DesktopName:    desktopName,
				DesktopToken:   desktopToken,
				PairingTTL:     pairingTTL,
				AllowPairing:   allowPairing,
				PairingBaseURL: pairingBaseURL,
			})
			if err != nil {
				return err
			}

			ctx, stop := signal.NotifyContext(cmd.Context(), os.Interrupt, syscall.SIGTERM)
			defer stop()
			return agent.ServeMobileGateway(ctx, cfg)
		},
	}
	cmd.Flags().StringVar(&host, "host", "127.0.0.1", "listen host")
	cmd.Flags().IntVar(&port, "port", 8876, "listen port")
	cmd.Flags().StringVar(&desktopName, "desktop-name", "", "desktop name shown in pairing payload")
	cmd.Flags().StringVar(&desktopToken, "desktop-token", "", "desktop peer bearer token; generated if empty")
	cmd.Flags().DurationVar(&pairingTTL, "pairing-ttl", 2*time.Minute, "pairing token lifetime")
	cmd.Flags().BoolVar(&allowPairing, "allow-pairing", true, "allow QR pairing for new devices")
	cmd.Flags().StringVar(&pairingBaseURL, "pairing-base-url", "", "public LAN base URL embedded in pairing payload")
	return cmd
}

func newProbeCommand(workspace *string, jsonOutput *bool) *cobra.Command {
	return &cobra.Command{
		Use:   "probe",
		Short: "Print runtime platform, toolchain, mirror, and proxy information",
		RunE: func(cmd *cobra.Command, args []string) error {
			root, err := agent.NewWorkspaceRoot(*workspace)
			if err != nil {
				return err
			}
			report := agent.Probe(context.Background(), root)
			if *jsonOutput {
				return agent.WriteJSON(os.Stdout, report)
			}
			fmt.Fprintln(os.Stdout, agent.FormatProbe(report))
			return nil
		},
	}
}

func newVersionCommand(jsonOutput *bool) *cobra.Command {
	return &cobra.Command{
		Use:   "version",
		Short: "Print willdeep-agent version",
		RunE: func(cmd *cobra.Command, args []string) error {
			info := agent.VersionInfo()
			if *jsonOutput {
				return agent.WriteJSON(os.Stdout, info)
			}
			fmt.Fprintf(os.Stdout, "willdeep-agent %s\n", info.Version)
			return nil
		},
	}
}
