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

	// PollInterval controls how often the watcher checks connection state.
	// Zero defaults to 5 seconds.
	PollInterval time.Duration
	// now returns the current time. Nil defaults to time.Now().UTC.
	now func() time.Time
}

func (c Config) pollInterval() time.Duration {
	if c.PollInterval == 0 {
		return 5 * time.Second
	}
	return c.PollInterval
}

func (c Config) currentTime() time.Time {
	if c.now == nil {
		return time.Now().UTC()
	}
	return c.now()
}

func Start(ctx context.Context, n NetworkManager, c Config) {
	c.watcher(ctx, n, "kiosk")
}

type NetworkManager interface {
	GetActiveConnectionByID(id string) (*networkmanager.ActiveConnection, error)
	GetSavedConnectionByID(id string) (*networkmanager.SavedConnection, error)
	CreateOrUpdateAP(id string, ssid string, psk string, ip string, prefix uint8) (string, error)
	Connect(connectionPath string) (*networkmanager.ConnectResult, error)
}

func (c Config) watcher(ctx context.Context, n NetworkManager, profileID string) {
	// AP uses a distinct profile ID so it never appears as the WiFi client connection.
	apProfileID := profileID + "-ap"
	var lastActiveConnection time.Time
	var lastStateIsNormal bool
	var lastStateIsSetup bool // tracks whether we have already called SetupAction

	for {
		if ctx.Err() != nil {
			return
		}

		activeConnection, err := n.GetActiveConnectionByID(profileID)
		if err != nil {
			fmt.Fprintf(os.Stderr, "watcher: could not list active connections: %s\n", err)
			time.Sleep(c.pollInterval())
			continue
		}
		savedConnection, err := n.GetSavedConnectionByID(profileID)
		if err != nil {
			fmt.Fprintf(os.Stderr, "watcher: could not list saved connections: %s\n", err)
			time.Sleep(c.pollInterval())
			continue
		}

		if activeConnection != nil && activeConnection.IsActivatingOrActivated() {
			lastActiveConnection = c.currentTime()
			if !lastStateIsNormal {
				fmt.Printf("watcher: entering normal mode\n")
				c.NormalAction(savedConnection.SSID)
				lastStateIsNormal = true
				lastStateIsSetup = false
			}

			time.Sleep(c.pollInterval())
			continue
		}

		if savedConnection == nil || c.currentTime().Sub(lastActiveConnection) > time.Minute {
			path, err := n.CreateOrUpdateAP(apProfileID, c.SSID, c.Password, c.IP, c.Prefix)
			if err != nil {
				fmt.Fprintf(os.Stderr, "watcher: could not create Access Point: %s\n", err)
				time.Sleep(c.pollInterval())
				continue
			}

			if _, err := n.Connect(path); err != nil {
				fmt.Fprintf(os.Stderr, "watcher: could not start Access Point: %s\n", err)
				time.Sleep(c.pollInterval())
				continue
			}

			// Call SetupAction only on transitions: normal→setup or initial startup.
			if lastStateIsNormal || !lastStateIsSetup {
				initialSetup := lastActiveConnection.Equal(time.Time{})
				fmt.Printf("watcher: entering setup mode\n")
				c.SetupAction(initialSetup)
				lastStateIsNormal = false
				lastStateIsSetup = true
			}
		}

		time.Sleep(c.pollInterval())
	}
}
