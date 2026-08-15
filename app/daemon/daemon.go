package daemon

import (
	"context"
	"fmt"
	"os"
	"time"

	"github.com/ibizaman/nixos-kiosk/networkmanager"
)

type Config struct {
	SSID         string
	Password     string
	IP           string
	Prefix       uint8
	SetupAction  func(initialSetup bool)
	NormalAction func(ssid string)
}

func Start(ctx context.Context, n *networkmanager.Client, c Config) {
	c.watcher(ctx, n, "kiosk")
}

func (c Config) watcher(ctx context.Context, n *networkmanager.Client, profileID string) {
	var lastActiveConnection time.Time
	var lastStateIsNormal bool

	for {
		if ctx.Err() != nil {
			return
		}

		activeConnection, err := n.GetActiveConnectionByID(profileID)
		if err != nil {
			fmt.Fprintf(os.Stderr, "watcher: could not list active connections: %s\n", err)
			continue
		}
		savedConnection, err := n.GetSavedConnectionByID(profileID)
		if err != nil {
			fmt.Fprintf(os.Stderr, "watcher: could not list active connections: %s\n", err)
			continue
		}

		if activeConnection != nil && activeConnection.IsActivatingOrActivated() {
			lastActiveConnection = time.Now().UTC()
			if !lastStateIsNormal {
				fmt.Printf("watcher: entering normal mode\n")
				c.NormalAction(savedConnection.SSID)
				lastStateIsNormal = true
			}

			time.Sleep(5 * time.Second)
			continue
		}

		if savedConnection == nil || time.Now().UTC().Sub(lastActiveConnection) > time.Minute {
			path, err := n.CreateOrUpdateAP(profileID, c.SSID, c.Password, c.IP, c.Prefix)
			if err != nil {
				fmt.Fprintf(os.Stderr, "watcher: could not create Access Point: %s\n", err)
				continue
			}

			if _, err := n.Connect(path); err != nil {
				fmt.Fprintf(os.Stderr, "watcher: could not start Access Point: %s\n", err)
				continue
			}

			if lastStateIsNormal || lastActiveConnection.Equal(time.Time{}) {
				fmt.Printf("watcher: entering setup mode\n")
				c.SetupAction(lastActiveConnection.Equal(time.Time{}))
				lastStateIsNormal = false
			}
		}

		time.Sleep(5 * time.Second)
	}
}
