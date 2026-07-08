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
	root.AddCommand(newServeCollabRelayCommand())
	root.AddCommand(newChromeNativeHostCommand())
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
	var desktopTokenFile string
	var pairingTTL time.Duration
	var allowPairing bool
	var pairingBaseURL string
	var relayBaseURL string
	var relayRoom string
	var relayToken string
	var relayTokenFile string

	cmd := &cobra.Command{
		Use:   "serve-mobile",
		Short: "Start the LAN mobile gateway for WillDeep",
		RunE: func(cmd *cobra.Command, args []string) error {
			resolvedDesktopToken := desktopToken
			if desktopTokenFile != "" {
				bytes, err := os.ReadFile(desktopTokenFile)
				if err != nil {
					return fmt.Errorf("read desktop token file: %w", err)
				}
				resolvedDesktopToken = string(bytes)
			}
			resolvedRelayToken := relayToken
			if relayTokenFile != "" {
				bytes, err := os.ReadFile(relayTokenFile)
				if err != nil {
					return fmt.Errorf("read relay token file: %w", err)
				}
				resolvedRelayToken = string(bytes)
			}
			cfg, err := agent.NewMobileGatewayConfig(agent.MobileGatewayConfigInput{
				Host:           host,
				Port:           port,
				DesktopName:    desktopName,
				DesktopToken:   resolvedDesktopToken,
				PairingTTL:     pairingTTL,
				AllowPairing:   allowPairing,
				PairingBaseURL: pairingBaseURL,
				RelayBaseURL:   relayBaseURL,
				RelayRoom:      relayRoom,
				RelayToken:     resolvedRelayToken,
				RemotePush:     agent.LoadMobileRemotePushConfig(),
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
	cmd.Flags().IntVar(&port, "port", 8877, "listen port")
	cmd.Flags().StringVar(&desktopName, "desktop-name", "", "desktop name shown in pairing payload")
	cmd.Flags().StringVar(&desktopToken, "desktop-token", "", "desktop peer bearer token; generated if empty")
	cmd.Flags().StringVar(&desktopTokenFile, "desktop-token-file", "", "file containing desktop peer bearer token")
	cmd.Flags().DurationVar(&pairingTTL, "pairing-ttl", 2*time.Minute, "pairing token lifetime")
	cmd.Flags().BoolVar(&allowPairing, "allow-pairing", true, "allow QR pairing for new devices")
	cmd.Flags().StringVar(&pairingBaseURL, "pairing-base-url", "", "public LAN base URL embedded in pairing payload")
	cmd.Flags().StringVar(&relayBaseURL, "relay-base-url", "", "public relay base URL embedded in pairing payload")
	cmd.Flags().StringVar(&relayRoom, "relay-room", "", "public relay broadcast room embedded in pairing payload")
	cmd.Flags().StringVar(&relayToken, "relay-token", "", "public relay bearer token embedded in pairing payload; prefer --relay-token-file")
	cmd.Flags().StringVar(&relayTokenFile, "relay-token-file", "", "file containing public relay bearer token")
	return cmd
}

func newServeCollabRelayCommand() *cobra.Command {
	var host string
	var port int
	var publicBaseURL string
	var token string
	var tokenFile string
	var feishuAppID string
	var feishuAppSecret string
	var feishuAppSecretFile string
	var feishuLongConnection bool
	var feishuLongConnectionEventTypes string
	var maxEvents int

	cmd := &cobra.Command{
		Use:   "serve-collab-relay",
		Short: "Start the public collaboration relay for Feishu, DingTalk, and WeCom callbacks",
		RunE: func(cmd *cobra.Command, args []string) error {
			cfg, err := agent.NewCollaborationRelayConfig(agent.CollaborationRelayConfigInput{
				Host:                           host,
				Port:                           port,
				PublicBaseURL:                  publicBaseURL,
				Token:                          token,
				TokenFile:                      tokenFile,
				FeishuAppID:                    feishuAppID,
				FeishuAppSecret:                feishuAppSecret,
				FeishuAppSecretFile:            feishuAppSecretFile,
				FeishuLongConnectionEnabled:    feishuLongConnection,
				FeishuLongConnectionEventTypes: feishuLongConnectionEventTypes,
				MaxEvents:                      maxEvents,
			})
			if err != nil {
				return err
			}

			ctx, stop := signal.NotifyContext(cmd.Context(), os.Interrupt, syscall.SIGTERM)
			defer stop()
			return agent.ServeCollaborationRelay(ctx, cfg)
		},
	}
	cmd.Flags().StringVar(&host, "host", "127.0.0.1", "listen host")
	cmd.Flags().IntVar(&port, "port", 8899, "listen port")
	cmd.Flags().StringVar(&publicBaseURL, "public-base-url", "https://fly.niuwoai.com", "public HTTPS base URL used in platform callbacks")
	cmd.Flags().StringVar(&token, "token", "", "bearer token for polling queued events; generated if empty")
	cmd.Flags().StringVar(&tokenFile, "token-file", "", "file containing bearer token for polling queued events")
	cmd.Flags().StringVar(&feishuAppID, "feishu-app-id", os.Getenv("WILLDEEP_FEISHU_APP_ID"), "Feishu app_id used by the setup QR endpoint")
	cmd.Flags().StringVar(&feishuAppSecret, "feishu-app-secret", os.Getenv("WILLDEEP_FEISHU_APP_SECRET"), "Feishu app_secret used for long connection; prefer --feishu-app-secret-file in production")
	cmd.Flags().StringVar(&feishuAppSecretFile, "feishu-app-secret-file", os.Getenv("WILLDEEP_FEISHU_APP_SECRET_FILE"), "file containing Feishu app_secret for long connection")
	cmd.Flags().BoolVar(&feishuLongConnection, "feishu-long-connection", envBool("WILLDEEP_FEISHU_LONG_CONNECTION"), "receive Feishu events through the official SDK long connection instead of requiring a public event callback")
	cmd.Flags().StringVar(&feishuLongConnectionEventTypes, "feishu-long-connection-event-types", os.Getenv("WILLDEEP_FEISHU_LONG_CONNECTION_EVENT_TYPES"), "comma-separated Feishu event types registered on the long connection client")
	cmd.Flags().IntVar(&maxEvents, "max-events", 500, "maximum in-memory callback events retained for polling")
	return cmd
}

func envBool(name string) bool {
	switch os.Getenv(name) {
	case "1", "true", "TRUE", "yes", "YES", "on", "ON":
		return true
	default:
		return false
	}
}

func newChromeNativeHostCommand() *cobra.Command {
	return &cobra.Command{
		Use:   "chrome-native-host",
		Short: "Run the Chrome Native Messaging host for the WillDeep browser extension",
		RunE: func(cmd *cobra.Command, args []string) error {
			ctx, stop := signal.NotifyContext(cmd.Context(), os.Interrupt, syscall.SIGTERM)
			defer stop()
			return agent.ServeChromeNativeHost(ctx, os.Stdin, os.Stdout)
		},
	}
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
