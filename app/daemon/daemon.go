package daemon

import (
	"context"
	"encoding/binary"
	"fmt"
	"net"
	"os"
	"syscall"
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

	// ConnectivityCheckHost is TCP-dialled on port 443 to confirm internet
	// access before switching to normal mode. Empty → "www.github.com".
	ConnectivityCheckHost string
	// NTPServer is queried (UDP/123) to sync the clock once internet is
	// confirmed. Empty → "0.nixos.pool.ntp.org".
	NTPServer string

	// PollInterval controls how often the watcher checks connection state.
	// Zero defaults to 5 seconds.
	PollInterval time.Duration
	// now returns the current time. Nil defaults to time.Now().UTC.
	now func() time.Time
	// injectable for tests; nil uses real implementations.
	checkConnectivity func(host string) error
	syncNTP           func(server string) error
}

func (c Config) effectiveNTPServer() string {
	if c.NTPServer == "" {
		return "0.nixos.pool.ntp.org"
	}
	return c.NTPServer
}

func (c Config) doSyncNTP() error {
	fn := c.syncNTP
	if fn == nil {
		fn = syncNTP
	}
	return fn(c.effectiveNTPServer())
}

func (c Config) effectiveConnectivityHost() string {
	if c.ConnectivityCheckHost == "" {
		return "www.github.com"
	}
	return c.ConnectivityCheckHost
}

func (c Config) doConnectivityCheck() error {
	fn := c.checkConnectivity
	if fn == nil {
		fn = checkConnectivity
	}
	return fn(c.effectiveConnectivityHost())
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
	WaitWhileConnecting(path string, timeout time.Duration) (string, error)
	Disconnect(activeConnectionPath string) error
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
				if apConn, err := n.GetActiveConnectionByID(apProfileID); err == nil && apConn != nil {
					if err := n.Disconnect(apConn.Path); err != nil {
						fmt.Fprintf(os.Stderr, "watcher: could not disconnect AP: %s\n", err)
					}
				}
				if err := c.doConnectivityCheck(); err != nil {
					fmt.Fprintf(os.Stderr, "watcher: connectivity check failed, will retry: %s\n", err)
					time.Sleep(c.pollInterval())
					continue
				}
				if err := c.doSyncNTP(); err != nil {
					fmt.Fprintf(os.Stderr, "watcher: NTP sync failed (continuing): %s\n", err)
				}
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

			result, err := n.Connect(path)
			if err != nil {
				fmt.Fprintf(os.Stderr, "watcher: could not start Access Point: %s\n", err)
				time.Sleep(c.pollInterval())
				continue
			}

			state, err := n.WaitWhileConnecting(result.ActiveConnectionPath, 30*time.Second)
			if err != nil || state != "activated" {
				fmt.Fprintf(os.Stderr, "watcher: Access Point did not activate (state: %s, err: %v)\n", state, err)
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

// checkConnectivity dials host:443 over TCP to verify internet access.
func checkConnectivity(host string) error {
	conn, err := net.DialTimeout("tcp", net.JoinHostPort(host, "443"), 5*time.Second)
	if err != nil {
		return err
	}
	conn.Close()
	return nil
}

// syncNTP sends a minimal NTP request to server:123 and sets the system clock.
func syncNTP(server string) error {
	conn, err := net.DialTimeout("udp", net.JoinHostPort(server, "123"), 5*time.Second)
	if err != nil {
		return err
	}
	defer conn.Close()

	if err := conn.SetDeadline(time.Now().Add(5 * time.Second)); err != nil {
		return err
	}

	req := make([]byte, 48)
	req[0] = 0x1b // LI=0, VN=3, Mode=3 (client)
	if _, err := conn.Write(req); err != nil {
		return err
	}

	resp := make([]byte, 48)
	if _, err := conn.Read(resp); err != nil {
		return err
	}

	// Transmit timestamp is at bytes 40-47: seconds since 1900-01-01
	secs := binary.BigEndian.Uint32(resp[40:44])
	const ntpEpochOffset = 2208988800
	unixSecs := int64(secs) - ntpEpochOffset

	tv := syscall.Timeval{Sec: unixSecs}
	return syscall.Settimeofday(&tv)
}
