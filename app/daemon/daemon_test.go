package daemon

import (
	"context"
	"sync/atomic"
	"testing"
	"time"

	"github.com/ibizaman/nixos-kiosk/networkmanager"
)

type mockNM struct {
	getActive func(id string) (*networkmanager.ActiveConnection, error)
	getSaved  func(id string) (*networkmanager.SavedConnection, error)

	apCalls      []string
	connectCalls []string
}

func (m *mockNM) GetActiveConnectionByID(id string) (*networkmanager.ActiveConnection, error) {
	if m.getActive != nil {
		return m.getActive(id)
	}
	return nil, nil
}

func (m *mockNM) GetSavedConnectionByID(id string) (*networkmanager.SavedConnection, error) {
	if m.getSaved != nil {
		return m.getSaved(id)
	}
	return nil, nil
}

func (m *mockNM) CreateOrUpdateAP(id, ssid, psk, ip string, prefix uint8) (string, error) {
	m.apCalls = append(m.apCalls, id)
	return "/mock/ap/path/" + id, nil
}

func (m *mockNM) Connect(path string) (*networkmanager.ConnectResult, error) {
	m.connectCalls = append(m.connectCalls, path)
	return &networkmanager.ConnectResult{ActiveConnectionPath: path}, nil
}

func activated() *networkmanager.ActiveConnection {
	return &networkmanager.ActiveConnection{
		ID:    "kiosk",
		State: uint32(networkmanager.NMActiveConnectionStateActivated),
	}
}

func savedKiosk(ssid string) *networkmanager.SavedConnection {
	return &networkmanager.SavedConnection{ID: "kiosk", SSID: ssid}
}

func runWatcher(t *testing.T, nm *mockNM, cfg Config, duration time.Duration) {
	t.Helper()
	cfg.PollInterval = 10 * time.Millisecond
	ctx, cancel := context.WithTimeout(context.Background(), duration)
	defer cancel()
	Start(ctx, nm, cfg)
}

func TestInitialSetupMode(t *testing.T) {
	nm := &mockNM{}

	var setupCalls, normalCalls int
	runWatcher(t, nm, Config{
		IP:           "192.168.4.1",
		Prefix:       24,
		SetupAction:  func(bool) { setupCalls++ },
		NormalAction: func(string) { normalCalls++ },
	}, 50*time.Millisecond)

	if setupCalls == 0 {
		t.Error("SetupAction never called on initial state")
	}
	if normalCalls != 0 {
		t.Errorf("NormalAction called %d times, want 0", normalCalls)
	}
	if len(nm.apCalls) == 0 {
		t.Error("AP never created")
	}
	// AP must use the "-ap" suffix to avoid colliding with the WiFi client profile "kiosk".
	for _, id := range nm.apCalls {
		if id == "kiosk" {
			t.Errorf("AP created with bare profile ID %q; must be %q", id, "kiosk-ap")
		}
	}
}

func TestNormalModeOnActiveWiFi(t *testing.T) {
	nm := &mockNM{
		getActive: func(id string) (*networkmanager.ActiveConnection, error) {
			if id == "kiosk" {
				return activated(), nil
			}
			return nil, nil
		},
		getSaved: func(id string) (*networkmanager.SavedConnection, error) {
			if id == "kiosk" {
				return savedKiosk("HomeWifi"), nil
			}
			return nil, nil
		},
	}

	var normalSSID string
	var normalCalls, setupCalls int
	runWatcher(t, nm, Config{
		IP:           "192.168.4.1",
		Prefix:       24,
		SetupAction:  func(bool) { setupCalls++ },
		NormalAction: func(ssid string) { normalCalls++; normalSSID = ssid },
	}, 50*time.Millisecond)

	if normalCalls == 0 {
		t.Error("NormalAction never called when WiFi is active")
	}
	if normalSSID != "HomeWifi" {
		t.Errorf("NormalAction SSID = %q, want %q", normalSSID, "HomeWifi")
	}
	if setupCalls != 0 {
		t.Errorf("SetupAction called %d times, want 0", setupCalls)
	}
	if len(nm.apCalls) != 0 {
		t.Errorf("AP created %d times, want 0 when WiFi already active", len(nm.apCalls))
	}
}

func TestAPActiveDoesNotTriggerNormalMode(t *testing.T) {
	// The kiosk AP uses profile ID "kiosk-ap". The daemon watches "kiosk" (WiFi
	// client). An active AP profile must not be mistaken for a successful WiFi
	// connection.
	nm := &mockNM{
		// "kiosk" WiFi client: not active, not saved
		getActive: func(string) (*networkmanager.ActiveConnection, error) { return nil, nil },
		getSaved:  func(string) (*networkmanager.SavedConnection, error) { return nil, nil },
	}

	var setupCalls, normalCalls int
	runWatcher(t, nm, Config{
		IP:           "192.168.4.1",
		Prefix:       24,
		SetupAction:  func(bool) { setupCalls++ },
		NormalAction: func(string) { normalCalls++ },
	}, 50*time.Millisecond)

	if setupCalls == 0 {
		t.Error("SetupAction never called; should be in setup mode when AP active but no WiFi client")
	}
	if normalCalls != 0 {
		t.Errorf("NormalAction called %d times; AP must not trigger normal mode", normalCalls)
	}
}

func TestNormalModeCalledOnlyOnce(t *testing.T) {
	// NormalAction should fire exactly once per transition, not on every poll.
	nm := &mockNM{
		getActive: func(id string) (*networkmanager.ActiveConnection, error) {
			if id == "kiosk" {
				return activated(), nil
			}
			return nil, nil
		},
		getSaved: func(id string) (*networkmanager.SavedConnection, error) {
			if id == "kiosk" {
				return savedKiosk("HomeWifi"), nil
			}
			return nil, nil
		},
	}

	var normalCalls int
	runWatcher(t, nm, Config{
		IP:           "192.168.4.1",
		Prefix:       24,
		SetupAction:  func(bool) {},
		NormalAction: func(string) { normalCalls++ },
	}, 100*time.Millisecond)

	if normalCalls != 1 {
		t.Errorf("NormalAction called %d times, want exactly 1", normalCalls)
	}
}

func TestSetupModeCalledOnlyOnce(t *testing.T) {
	// SetupAction should fire exactly once per transition to setup mode.
	nm := &mockNM{}

	var setupCalls int
	runWatcher(t, nm, Config{
		IP:           "192.168.4.1",
		Prefix:       24,
		SetupAction:  func(bool) { setupCalls++ },
		NormalAction: func(string) {},
	}, 100*time.Millisecond)

	if setupCalls != 1 {
		t.Errorf("SetupAction called %d times, want exactly 1", setupCalls)
	}
}

func TestGracePeriodKeepsNormalMode(t *testing.T) {
	// After WiFi drops, the daemon must stay in normal mode for the 1-minute grace
	// period before switching back to AP/setup mode.
	//
	// Strategy: use an advancing mock clock and a mock NM that returns active WiFi
	// for the first few polls, then inactive. The clock advances 10ms per call, so
	// the time since last connection stays << 1 minute while the test runs.
	var pollCount atomic.Int32
	mockTime := time.Now().UTC()

	nm := &mockNM{
		getActive: func(id string) (*networkmanager.ActiveConnection, error) {
			n := pollCount.Add(1)
			if id == "kiosk" && n <= 3 {
				return activated(), nil
			}
			return nil, nil
		},
		getSaved: func(id string) (*networkmanager.SavedConnection, error) {
			if id == "kiosk" {
				return savedKiosk("HomeWifi"), nil
			}
			return nil, nil
		},
	}

	var setupCalls int
	runWatcher(t, nm, Config{
		IP:          "192.168.4.1",
		Prefix:      24,
		SetupAction: func(bool) { setupCalls++ },
		NormalAction: func(string) {},
		now: func() time.Time {
			// Advance by 10ms on each call; total elapsed << 1 minute.
			mockTime = mockTime.Add(10 * time.Millisecond)
			return mockTime
		},
	}, 150*time.Millisecond)

	if setupCalls != 0 {
		t.Errorf("SetupAction called %d times during grace period, want 0", setupCalls)
	}
}

func TestSetupModeAfterGracePeriodExpires(t *testing.T) {
	// Once the grace period exceeds 1 minute, the daemon must re-enter setup mode.
	//
	// Strategy: mock clock advances by 30 seconds per call. After WiFi drops (poll
	// 4+), the elapsed time since last connection quickly exceeds 1 minute.
	var pollCount atomic.Int32
	mockTime := time.Now().UTC()

	nm := &mockNM{
		getActive: func(id string) (*networkmanager.ActiveConnection, error) {
			n := pollCount.Add(1)
			if id == "kiosk" && n <= 3 {
				return activated(), nil
			}
			return nil, nil
		},
		getSaved: func(id string) (*networkmanager.SavedConnection, error) {
			if id == "kiosk" {
				return savedKiosk("HomeWifi"), nil
			}
			return nil, nil
		},
	}

	var setupCalls int
	runWatcher(t, nm, Config{
		IP:          "192.168.4.1",
		Prefix:      24,
		SetupAction: func(bool) { setupCalls++ },
		NormalAction: func(string) {},
		now: func() time.Time {
			// Advance 30 seconds per call; after WiFi drops, elapsed > 1 minute fast.
			mockTime = mockTime.Add(30 * time.Second)
			return mockTime
		},
	}, 500*time.Millisecond)

	if setupCalls == 0 {
		t.Error("SetupAction never called after grace period expired")
	}
	if len(nm.apCalls) == 0 {
		t.Error("AP never recreated after grace period expired")
	}
}

func TestInitialSetupIsDistinguishedFromReconnect(t *testing.T) {
	// SetupAction(initialSetup=true) on first boot, false after WiFi dropout.
	var setupCallArgs []bool
	var pollCount atomic.Int32

	nm := &mockNM{
		getActive: func(id string) (*networkmanager.ActiveConnection, error) {
			n := pollCount.Add(1)
			if id == "kiosk" && n >= 5 && n <= 8 {
				return activated(), nil
			}
			return nil, nil
		},
		getSaved: func(id string) (*networkmanager.SavedConnection, error) {
			n := int(pollCount.Load())
			if id == "kiosk" && n >= 5 {
				return savedKiosk("HomeWifi"), nil
			}
			return nil, nil
		},
	}

	mockTime := time.Now().UTC()
	runWatcher(t, nm, Config{
		IP:           "192.168.4.1",
		Prefix:       24,
		SetupAction:  func(initial bool) { setupCallArgs = append(setupCallArgs, initial) },
		NormalAction: func(string) {},
		now: func() time.Time {
			mockTime = mockTime.Add(30 * time.Second)
			return mockTime
		},
	}, 600*time.Millisecond)

	if len(setupCallArgs) < 2 {
		t.Fatalf("SetupAction called %d times, want at least 2 (initial + reconnect)", len(setupCallArgs))
	}
	if !setupCallArgs[0] {
		t.Error("First SetupAction call should have initialSetup=true")
	}
	if setupCallArgs[1] {
		t.Error("Second SetupAction call should have initialSetup=false (reconnect after dropout)")
	}
}
