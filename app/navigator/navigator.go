package navigator

import (
	"context"
	"fmt"
	"os"
	"time"
)

// Client controls a Chromium instance.
type Client interface {
	GetCurrentURL() (string, error)
	Connect() (func() error, error)
	Navigate(url string) error
}

// Config holds navigator settings.
type Config struct {
	// NewClient returns a fresh Client on each poll cycle.
	NewClient func() Client
	// PollInterval between URL checks. Zero defaults to 5 seconds.
	PollInterval time.Duration
}

func (c Config) pollInterval() time.Duration {
	if c.PollInterval == 0 {
		return 5 * time.Second
	}
	return c.PollInterval
}

// Run loops until ctx is cancelled, reading target URLs from navigateChan and
// ensuring Chromium always shows the most recently requested URL. It
// re-navigates whenever Chromium's current URL drifts from the target (e.g.
// after cage/Chromium restarts).
func Run(ctx context.Context, cfg Config, navigateChan <-chan string) {
	// pending holds at most one URL. The inner goroutine writes it; the outer
	// loop reads it. Buffered size 1 avoids the data race that plain shared
	// variables would introduce.
	pending := make(chan string, 1)

	go func() {
		for {
			newURL, ok := <-navigateChan
			if !ok {
				return
			}
			// Evict any queued URL so the latest one always wins.
			select {
			case <-pending:
			default:
			}
			pending <- newURL
			fmt.Fprintf(os.Stderr, "navigator: will navigate to: %s\n", newURL)
		}
	}()

	var targetURL string

	for {
		if ctx.Err() != nil {
			return
		}

		select {
		case url := <-pending:
			targetURL = url
		default:
		}

		if targetURL != "" {
			c := cfg.NewClient()
			currentURL, err := c.GetCurrentURL()
			if err != nil || currentURL != targetURL {
				closeWS, err := c.Connect()
				if err != nil {
					fmt.Fprintf(os.Stderr, "navigator: could not connect to websocket: %s\n", err)
				} else {
					if err := c.Navigate(targetURL); err != nil {
						fmt.Fprintf(os.Stderr, "navigator: could not navigate to %s: %s\n", targetURL, err)
					}
					closeWS()
				}
			}
		}

		time.Sleep(cfg.pollInterval())
	}
}
