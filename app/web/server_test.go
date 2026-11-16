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
