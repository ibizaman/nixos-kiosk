package main

import (
	"context"
	"encoding/json"
	"fmt"
	"log"
	"math/rand"
	"os"
	"os/signal"
	"strings"
	"time"

	"github.com/ibizaman/nixos-kiosk/chromium"
	"github.com/ibizaman/nixos-kiosk/daemon"
	"github.com/ibizaman/nixos-kiosk/networkmanager"
	"github.com/ibizaman/nixos-kiosk/web"
	"github.com/urfave/cli/v3"
)

func main() {
	cmd := &cli.Command{
		Usage: "Manage a NixOS Kiosk",
		Commands: []*cli.Command{
			{
				Name:    "network-manager",
				Aliases: []string{"nm"},
				Usage:   "Run queries against NetworkManager over DBUS",
				Commands: []*cli.Command{
					{
						Name:    "status",
						Aliases: []string{"s"},
						Usage:   "show network manager status",
						Action:  networkManagerStatus,
					},
					{
						Name:    "profiles",
						Aliases: []string{"p"},
						Usage:   "list saved profiles",
						Action:  networkManagerProfiles,
					},
					{
						Name:    "connect",
						Aliases: []string{"c"},
						Usage:   "connect using a saved profiles",
						Arguments: []cli.Argument{
							&cli.StringArg{
								Name: "profile",
							},
						},
						Action: networkManagerConnect,
					},
					{
						Name:    "add",
						Aliases: []string{"a"},
						Usage:   "connect to an SSID. Reads PSK from NIXOS_KIOSK_PSK env var or the file given in the --psk-file argument.",
						Arguments: []cli.Argument{
							&cli.StringArg{
								Name:  "SSID",
								Value: "Kiosk Setup",
							},
						},
						Flags: []cli.Flag{
							&cli.StringFlag{
								Name:    "psk-file",
								Aliases: []string{"f"},
								Usage:   "filename where the PSK is stored",
							},
						},
						Action: networkManagerAdd,
					},
					{
						Name:    "addAP",
						Aliases: []string{"ap"},
						Usage:   "Create or update an Access Point. Reads PSK from NIXOS_KIOSK_PSK env var or the file given in the --psk-file argument.",
						Arguments: []cli.Argument{
							&cli.StringArg{
								Name: "id",
							},
							&cli.StringArg{
								Name:  "SSID",
								Value: "Kiosk Setup",
							},
						},
						Flags: []cli.Flag{
							&cli.StringFlag{
								Name:    "psk-file",
								Aliases: []string{"f"},
								Usage:   "filename where the PSK is stored",
							},
							&cli.StringFlag{
								Name:    "dns",
								Aliases: []string{"d"},
								Usage:   "IP of the DNS server",
							},
						},
						Action: networkManagerAddAP,
					},
				},
			},
			{
				Name:    "serve",
				Aliases: []string{"s"},
				Usage:   "Serve web pages",
				Arguments: []cli.Argument{
					&cli.StringArg{
						Name:  "SSID",
						Value: "Kiosk Setup",
					},
				},
				Flags: []cli.Flag{
					&cli.Uint16Flag{
						Name:    "port",
						Aliases: []string{"p"},
						Usage:   "port on which to listen to",
						Value:   8000,
					},
				},
				Action: serve,
			},
			{
				Name:    "chromium",
				Aliases: []string{"c"},
				Usage:   "Control a chromium browser through the debug port",
				Flags: []cli.Flag{
					&cli.Uint16Flag{
						Name:    "port",
						Aliases: []string{"p"},
						Usage:   "port on which to talk to chromium",
						Value:   9222,
					},
				},
				Commands: []*cli.Command{
					{
						Name:    "url",
						Aliases: []string{"u"},
						Usage:   "Print the current displayed URL",
						Action:  chromiumGetURL,
					},
					{
						Name:    "navigate",
						Aliases: []string{"n"},
						Usage:   "Navigate to the given URL",
						Arguments: []cli.Argument{
							&cli.StringArg{
								Name:  "URL",
								Value: "URL to display",
							},
						},
						Action: chromiumNagivate,
					},
				},
			},
			{
				Name:    "daemon",
				Aliases: []string{"d"},
				Usage:   "Serve web pages, watch for active WiFi connection and switch systemd target",
				Arguments: []cli.Argument{
					&cli.StringArg{
						Name:  "SSID",
						Value: "Kiosk Setup",
					},
					&cli.StringArg{
						Name:  "URL",
						Value: "URL to show when WiFi connection is active",
					},
				},
				Flags: []cli.Flag{
					&cli.Uint16Flag{
						Name:    "port",
						Aliases: []string{"p"},
						Usage:   "port on which to listen to",
						Value:   8000,
					},
					&cli.Uint16Flag{
						Name:    "chromium-port",
						Aliases: []string{"c"},
						Usage:   "port on which chromium listens to",
						Value:   9222,
					},
					&cli.StringFlag{
						Name:    "dns",
						Aliases: []string{"d"},
						Usage:   "IP of the DNS server",
					},
				},
				Action: startDaemon,
			},
		},
	}

	if err := cmd.Run(context.Background(), os.Args); err != nil {
		log.Fatal(err)
	}
}

func networkManagerStatus(ctx context.Context, cmd *cli.Command) error {
	c, err := networkmanager.NewClient()
	if err != nil {
		log.Fatal(err)
	}
	defer c.Close()

	info, err := c.NetworkInfo()
	if err != nil {
		log.Fatal(err)
	}

	infoStr, err := json.Marshal(info)
	if err != nil {
		log.Fatalf("cannot marshal info: %s", err)
	}
	fmt.Printf("%s", string(infoStr))
	return nil
}

func networkManagerProfiles(ctx context.Context, cmd *cli.Command) error {
	c, err := networkmanager.NewClient()
	if err != nil {
		log.Fatal(err)
	}
	defer c.Close()

	conns, err := c.ListSavedConnections()
	if err != nil {
		log.Fatal(err)
	}

	connsStr, err := json.Marshal(conns)
	if err != nil {
		log.Fatalf("cannot marshal info: %s", err)
	}
	fmt.Printf("%s", string(connsStr))
	return nil
}

func networkManagerConnect(ctx context.Context, cmd *cli.Command) error {
	profile := cmd.StringArg("profile")

	c, err := networkmanager.NewClient()
	if err != nil {
		log.Fatal(err)
	}
	defer c.Close()

	res, err := c.Connect(profile)
	if err != nil {
		log.Fatal(err)
	}
	resStr, err := json.Marshal(res.ActiveConnectionPath)
	if err != nil {
		log.Fatalf("cannot marshal result: %s", err)
	}

	state, err := c.WaitWhileConnecting(res.ActiveConnectionPath, 30*time.Second)
	if err != nil {
		log.Fatal(err)
	}
	fmt.Printf("%s: %s", string(resStr), state)
	return nil
}

func networkManagerAdd(ctx context.Context, cmd *cli.Command) error {
	ssid := cmd.StringArg("SSID")
	password := readPassword(cmd)

	c, err := networkmanager.NewClient()
	if err != nil {
		log.Fatal(err)
	}
	defer c.Close()

	res, err := c.CreateWifi(ssid, ssid, password)
	if err != nil {
		log.Fatal(err)
	}

	resStr, err := json.Marshal(res)
	if err != nil {
		log.Fatalf("cannot marshal result: %s", err)
	}
	fmt.Printf("%s", string(resStr))
	return nil
}

func networkManagerAddAP(ctx context.Context, cmd *cli.Command) error {
	id := cmd.StringArg("id")
	ssid := cmd.StringArg("SSID")
	dns := cmd.StringArg("dns")
	password := readPassword(cmd)

	c, err := networkmanager.NewClient()
	if err != nil {
		log.Fatal(err)
	}
	defer c.Close()

	res, err := c.CreateOrUpdateAP(id, ssid, password, dns)
	if err != nil {
		log.Fatal(err)
	}

	resStr, err := json.Marshal(res)
	if err != nil {
		log.Fatalf("cannot marshal result: %s", err)
	}
	fmt.Printf("%s", string(resStr))
	return nil
}

func readPassword(cmd *cli.Command) string {
	var password string
	if psk_file := cmd.String("psk-file"); psk_file != "" {
		p, err := os.ReadFile(psk_file)
		if err != nil {
			log.Fatalf("Could not read psk-file: %s", err)
		}
		password = strings.TrimSpace(string(p))
	} else {
		password = os.Getenv("NIXOS_KIOSK_PSK")
	}
	if password == "" {
		log.Fatalf("No password given with NIXOS_KIOSK_PSK env var or --psk-file")
	}
	return password
}

func serve(ctx context.Context, cmd *cli.Command) error {
	ssid := cmd.StringArg("SSID")
	port := cmd.Uint16("port")
	addr := fmt.Sprintf("0.0.0.0:%d", port)
	password := genPassword()

	n, err := networkmanager.NewClient()
	if err != nil {
		log.Fatalf("could not initialize network manager: %s", err)
	}
	defer n.Close()

	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt)
	defer cancel()

	return web.Start(ctx, n, addr, ssid, password)
}

func chromiumGetURL(ctx context.Context, cmd *cli.Command) error {
	port := cmd.Uint16("port")

	cClient := chromium.NewClient("127.0.0.1", port)

	url, err := cClient.GetCurrentURL()
	if err != nil {
		log.Fatalf("could not get current URL in chromium: %s", err)
	}

	fmt.Println(url)
	return nil
}

func chromiumNagivate(ctx context.Context, cmd *cli.Command) error {
	url := cmd.StringArg("URL")
	port := cmd.Uint16("port")

	cClient := chromium.NewClient("127.0.0.1", port)

	close, err := cClient.Connect()
	if err != nil {
		return err
	}
	defer close()

	if err := cClient.Navigate(url); err != nil {
		log.Fatalf("could not display new URL in chromium: %s", err)
	}

	return nil
}

func startDaemon(ctx context.Context, cmd *cli.Command) error {
	navigateChan := make(chan string)

	go navigator(ctx, "127.0.0.1", cmd.Uint16("chromium-port"), navigateChan)

	c := daemon.Config{
		SSID:       cmd.StringArg("SSID"),
		ListenAddr: fmt.Sprintf("0.0.0.0:%d", cmd.Uint16("port")),
		Password:   genPassword(),
		DNSIP:      cmd.String("dns"),
		SetupAction: func() {
			navigateChan <- "http://setup.local/connect"
		},
		NormalAction: func() {
			navigateChan <- cmd.StringArg("URL")
		},
	}

	ctx, cancel := signal.NotifyContext(context.Background(), os.Interrupt)
	defer cancel()

	defer func() {
		close(navigateChan)
	}()
	return daemon.Start(ctx, c)
}

var letters = []rune("123456789")

func genPassword() string {
	b := make([]rune, 9)
	for i := range 4 {
		b[i] = letters[rand.Intn(len(letters))]
	}
	b[4] = '-'
	for i := range 4 {
		b[i+5] = letters[rand.Intn(len(letters))]
	}
	return string(b)
}

func navigator(ctx context.Context, ip string, port uint16, navigateChan <-chan string) func() {
	var url string
	var gotNew bool

	return func() {
		go func() {
			for {
				newURL, ok := <-navigateChan
				if !ok {
					return
				}

				if newURL != url {
					url = newURL
					gotNew = true
					fmt.Fprintf(os.Stderr, "navigator: will navigate to new url: %s", url)
				}
			}
		}()

		for {
			if ctx.Err() != nil {
				return
			}

			if gotNew {
				cClient := chromium.NewClient(ip, port)

				close, err := cClient.Connect()
				if err != nil {
					fmt.Fprintf(os.Stderr, "navigator: could not connect to websocket: %s", err)
				}
				defer close()

				if err := cClient.Navigate(url); err != nil {
					fmt.Fprintf(os.Stderr, "navigator: could navigate to new url: %s", err)
				}
				gotNew = false
			}

			time.Sleep(5 * time.Second)
		}
	}
}
