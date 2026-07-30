package daemon

import (
	"context"
	"fmt"
	"log"
	"os"
	"sync"
	"time"

	"github.com/ibizaman/nixos-kiosk/networkmanager"
	"github.com/ibizaman/nixos-kiosk/web"
)

type Config struct {
	SSID         string
	Port         uint16
	ListenAddr   string
	Password     string
	SetupAction  func()
	NormalAction func()
}

func Start(ctx context.Context, c Config) error {
	n, err := networkmanager.NewClient()
	if err != nil {
		log.Fatalf("could not initialize network manager: %s", err)
	}
	defer n.Close()

	var wg sync.WaitGroup

	errChan := make(chan error)

	wg.Add(2)
	defer wg.Wait()

	go func() {
		errChan <- web.Start(ctx, n, c.ListenAddr, c.SSID, c.Password)
		wg.Done()
	}()

	go func() {
		c.watcher(ctx, n, "kiosk")
		wg.Done()
	}()

	return nil
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
			fmt.Fprintf(os.Stderr, "watcher: could not list active connections: %s", err)
		}
		if activeConnection != nil && activeConnection.IsActivatingOrActivated() {
			lastActiveConnection = time.Now().UTC()
			if !lastStateIsNormal {
				c.NormalAction()
				lastStateIsNormal = true
			}
			continue
		}

		savedConnection, err := n.GetSavedConnectionByID(profileID)
		if err != nil {
			fmt.Fprintf(os.Stderr, "watcher: could not list active connections: %s", err)
		}

		if savedConnection == nil || time.Now().UTC().Sub(lastActiveConnection) > time.Minute {
			path, err := n.CreateOrUpdateAP(profileID, c.SSID, c.Password)
			if err != nil {
				fmt.Fprintf(os.Stderr, "watcher: could not create Access Point: %s", err)
			}

			if _, err := n.Connect(path); err != nil {
				fmt.Fprintf(os.Stderr, "watcher: could not start Access Point: %s", err)
			}

			if lastStateIsNormal {
				c.SetupAction()
				lastStateIsNormal = false
			}
		}
	}
}
