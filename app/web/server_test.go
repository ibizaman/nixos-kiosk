package web

import (
	"context"
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"net/url"
	"os"
	"path/filepath"
	"strings"
	"sync"
	"testing"
)

// TestStartRegistersRoutesSafely verifies that Start does not panic when
// registering HTTP routes. Route registration is synchronous before the
// server goroutine launches, so a pre-cancelled context is enough to
// exercise it without leaving a server running.
func TestStartRegistersRoutesSafely(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	cancel()
	_, errCh := Start(ctx, nil, ServerConfig{
		Addr:        "127.0.0.1:0",
		HotspotSSID: "Test",
		HotspotPSK:  "testpassword",
	})
	if err := <-errCh; err != nil {
		t.Fatal(err)
	}
}

func settingsPath(t *testing.T) string {
	t.Helper()
	return filepath.Join(t.TempDir(), "settings.json")
}

func writeSettings(t *testing.T, path string, s Settings) {
	t.Helper()
	data, err := json.Marshal(s)
	if err != nil {
		t.Fatal(err)
	}
	if err := os.WriteFile(path, data, 0o640); err != nil {
		t.Fatal(err)
	}
}

func readSettings(t *testing.T, path string) Settings {
	t.Helper()
	return LoadSettings(path, Settings{})
}

func postSettings(t *testing.T, path string, form url.Values) *httptest.ResponseRecorder {
	t.Helper()
	cfg := ServerConfig{SettingsPath: path}
	mu := &sync.Mutex{}
	req := httptest.NewRequest(http.MethodPost, "/manage/settings",
		strings.NewReader(form.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	w := httptest.NewRecorder()
	settingsPost(cfg, mu)(w, req)
	return w
}

func TestSettingsPost_URLPrefixSet(t *testing.T) {
	path := settingsPath(t)
	form := url.Values{"urlPrefix": {"https://dashboard.local"}}
	postSettings(t, path, form)
	s := readSettings(t, path)
	if s.URLPrefix != "https://dashboard.local" {
		t.Errorf("URLPrefix = %q, want %q", s.URLPrefix, "https://dashboard.local")
	}
}

func TestSettingsPost_URLPrefixCanBeCleared(t *testing.T) {
	path := settingsPath(t)
	writeSettings(t, path, Settings{URLPrefix: "https://old.local"})
	postSettings(t, path, url.Values{"urlPrefix": {""}})
	s := readSettings(t, path)
	if s.URLPrefix != "" {
		t.Errorf("URLPrefix = %q, want empty after explicit clear", s.URLPrefix)
	}
}

func TestSettingsPost_URLPrefixOmittedPreservesExisting(t *testing.T) {
	path := settingsPath(t)
	writeSettings(t, path, Settings{URLPrefix: "https://keep.local"})
	// POST without urlPrefix field at all — existing value must be preserved.
	postSettings(t, path, url.Values{"normalUrl": {"https://example.com"}})
	s := readSettings(t, path)
	if s.URLPrefix != "https://keep.local" {
		t.Errorf("URLPrefix = %q, want %q (omitted field should not clear)", s.URLPrefix, "https://keep.local")
	}
}

func TestSaveSettings_FilePermissions(t *testing.T) {
	path := settingsPath(t)
	if err := saveSettings(path, Settings{}); err != nil {
		t.Fatal(err)
	}
	info, err := os.Stat(path)
	if err != nil {
		t.Fatal(err)
	}
	if perm := info.Mode().Perm(); perm != 0o640 {
		t.Errorf("settings.json mode = %04o, want 0640", perm)
	}
}

func TestLoadSettings_URLPrefixRoundtrip(t *testing.T) {
	path := settingsPath(t)
	writeSettings(t, path, Settings{URLPrefix: "https://example.com/prefix"})
	s := readSettings(t, path)
	if s.URLPrefix != "https://example.com/prefix" {
		t.Errorf("URLPrefix roundtrip = %q, want %q", s.URLPrefix, "https://example.com/prefix")
	}
}

func postSettingsWithHostnameState(t *testing.T, settPath, stPath string, form url.Values) *httptest.ResponseRecorder {
	t.Helper()
	cfg := ServerConfig{SettingsPath: settPath, HostnameStatePath: stPath}
	mu := &sync.Mutex{}
	req := httptest.NewRequest(http.MethodPost, "/manage/settings",
		strings.NewReader(form.Encode()))
	req.Header.Set("Content-Type", "application/x-www-form-urlencoded")
	w := httptest.NewRecorder()
	settingsPost(cfg, mu)(w, req)
	return w
}

func TestSettingsPost_HostnameWritesStateFile(t *testing.T) {
	dir := t.TempDir()
	sPath := filepath.Join(dir, "settings.json")
	hPath := filepath.Join(dir, "hostname")
	postSettingsWithHostnameState(t, sPath, hPath, url.Values{"hostname": {"my-kiosk"}})
	got, err := os.ReadFile(hPath)
	if err != nil {
		t.Fatalf("hostname state file not written: %v", err)
	}
	if string(got) != "my-kiosk" {
		t.Errorf("hostname state = %q, want %q", got, "my-kiosk")
	}
	s := readSettings(t, sPath)
	if s.MDNSHostname != "my-kiosk" {
		t.Errorf("settings MDNSHostname = %q, want %q", s.MDNSHostname, "my-kiosk")
	}
}

func TestSettingsPost_HostnameEmptyDoesNotWriteStateFile(t *testing.T) {
	dir := t.TempDir()
	sPath := filepath.Join(dir, "settings.json")
	hPath := filepath.Join(dir, "hostname")
	postSettingsWithHostnameState(t, sPath, hPath, url.Values{"normalUrl": {"https://example.com"}})
	if _, err := os.Stat(hPath); err == nil {
		t.Error("hostname state file should not be created when hostname field is empty")
	}
}

func TestSettingsPost_InvalidHostnameRejected(t *testing.T) {
	cases := []string{
		"bad hostname",
		"bad.hostname",
		"-start-hyphen",
		"end-hyphen-",
		"",
	}
	for _, h := range cases {
		t.Run(h, func(t *testing.T) {
			dir := t.TempDir()
			sPath := filepath.Join(dir, "settings.json")
			hPath := filepath.Join(dir, "hostname")
			w := postSettingsWithHostnameState(t, sPath, hPath, url.Values{"hostname": {h}})
			if h == "" {
				// empty hostname is a no-op, not an error
				if w.Code != http.StatusOK {
					t.Errorf("empty hostname: got %d, want 200", w.Code)
				}
				return
			}
			if w.Code != http.StatusBadRequest {
				t.Errorf("hostname %q: got %d, want 400", h, w.Code)
			}
		})
	}
}

func TestValidHostname(t *testing.T) {
	valid := []string{"kiosk", "my-kiosk", "kiosk-01", "a", "A1"}
	for _, h := range valid {
		if !validHostname(h) {
			t.Errorf("validHostname(%q) = false, want true", h)
		}
	}
	invalid := []string{"", "-kiosk", "kiosk-", "my kiosk", "my.kiosk", "kiosk/x"}
	for _, h := range invalid {
		if validHostname(h) {
			t.Errorf("validHostname(%q) = true, want false", h)
		}
	}
}

func renderStrengthBars(t *testing.T, strength uint8) string {
	t.Helper()
	var buf strings.Builder
	if err := htmlTemplates.ExecuteTemplate(&buf, "strength-bars", strength); err != nil {
		t.Fatalf("ExecuteTemplate strength-bars(%d): %v", strength, err)
	}
	return buf.String()
}

func TestStrengthBarsTemplate(t *testing.T) {
	cases := []struct {
		strength    uint8
		wantActive  int
	}{
		{0, 0},
		{1, 1},
		{24, 1},
		{25, 2},
		{49, 2},
		{50, 3},
		{74, 3},
		{75, 4},
		{100, 4},
	}
	for _, c := range cases {
		out := renderStrengthBars(t, c.strength)
		if out == "" {
			t.Errorf("strength=%d: template rendered nothing", c.strength)
		}
		got := strings.Count(out, `class="strength-bar active"`)
		if got != c.wantActive {
			t.Errorf("strength=%d: got %d active bars, want %d\noutput: %s",
				c.strength, got, c.wantActive, out)
		}
		total := strings.Count(out, "strength-bar")
		if total < 4 {
			t.Errorf("strength=%d: got %d strength-bar mentions, want at least 4", c.strength, total)
		}
	}
}
