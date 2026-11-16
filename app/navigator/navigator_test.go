package navigator

import (
	"context"
	"errors"
	"sync"
	"testing"
	"time"
)

type mockClient struct {
	mu            sync.Mutex
	currentURL    string
	connectErr    error
	navigateErr   error
	navigateCalls []string
	connectCalls  int
}

func (m *mockClient) GetCurrentURL() (string, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.currentURL, nil
}

func (m *mockClient) Connect() (func() error, error) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.connectCalls++
	if m.connectErr != nil {
		return nil, m.connectErr
	}
	return func() error { return nil }, nil
}

func (m *mockClient) Navigate(url string) error {
	m.mu.Lock()
	defer m.mu.Unlock()
	if m.navigateErr != nil {
		return m.navigateErr
	}
	m.navigateCalls = append(m.navigateCalls, url)
	m.currentURL = url
	return nil
}

func (m *mockClient) setCurrentURL(url string) {
	m.mu.Lock()
	defer m.mu.Unlock()
	m.currentURL = url
}

func (m *mockClient) getNavigateCalls() []string {
	m.mu.Lock()
	defer m.mu.Unlock()
	out := make([]string, len(m.navigateCalls))
	copy(out, m.navigateCalls)
	return out
}

func (m *mockClient) getConnectCalls() int {
	m.mu.Lock()
	defer m.mu.Unlock()
	return m.connectCalls
}

func runNavigator(t *testing.T, mock *mockClient, ch chan string, duration time.Duration) {
	t.Helper()
	cfg := Config{
		NewClient:    func() Client { return mock },
		PollInterval: 10 * time.Millisecond,
	}
	ctx, cancel := context.WithTimeout(context.Background(), duration)
	defer cancel()
	Run(ctx, cfg, ch)
}

func TestNavigatesOnURLReceived(t *testing.T) {
	mock := &mockClient{}
	ch := make(chan string, 1)
	ch <- "http://localhost:8000/manage"

	runNavigator(t, mock, ch, 100*time.Millisecond)

	calls := mock.getNavigateCalls()
	if len(calls) == 0 {
		t.Fatal("Navigate was never called")
	}
	if calls[0] != "http://localhost:8000/manage" {
		t.Errorf("Navigate called with %q, want %q", calls[0], "http://localhost:8000/manage")
	}
}

func TestNoNavigationWhenURLAlreadyCurrent(t *testing.T) {
	// Chromium is already on the target URL — no navigation needed.
	mock := &mockClient{currentURL: "http://localhost:8000/manage"}
	ch := make(chan string, 1)
	ch <- "http://localhost:8000/manage"

	runNavigator(t, mock, ch, 100*time.Millisecond)

	if calls := mock.getNavigateCalls(); len(calls) != 0 {
		t.Errorf("Navigate called %d times, want 0 (URL already current)", len(calls))
	}
	if n := mock.getConnectCalls(); n != 0 {
		t.Errorf("Connect called %d times, want 0 (URL already current)", n)
	}
}

func TestRenavigatesAfterChromiumRestart(t *testing.T) {
	// After the initial navigation, Chromium restarts and lands on a different
	// URL. The navigator must detect the drift and navigate back.
	mock := &mockClient{}
	ch := make(chan string, 1)
	ch <- "http://localhost:8000/manage"

	cfg := Config{
		NewClient: func() Client { return mock },
		PollInterval: 10 * time.Millisecond,
	}
	ctx, cancel := context.WithTimeout(context.Background(), 200*time.Millisecond)
	defer cancel()

	// After the first successful navigation, simulate Chromium restarting and
	// opening on a blank page.
	go func() {
		time.Sleep(40 * time.Millisecond)
		mock.setCurrentURL("about:blank")
	}()

	Run(ctx, cfg, ch)

	calls := mock.getNavigateCalls()
	if len(calls) < 2 {
		t.Errorf("Navigate called %d times, want at least 2 (initial + after restart)", len(calls))
	}
	for _, c := range calls {
		if c != "http://localhost:8000/manage" {
			t.Errorf("Navigate called with unexpected URL %q", c)
		}
	}
}

func TestRetriesOnConnectFailure(t *testing.T) {
	// Connect fails on the first attempt, succeeds on the second.
	var mu sync.Mutex
	attempt := 0
	successMock := &mockClient{} // no error — used from attempt 2 onward

	cfg := Config{
		NewClient: func() Client {
			mu.Lock()
			defer mu.Unlock()
			attempt++
			if attempt == 1 {
				return &mockClient{connectErr: errors.New("connection refused")}
			}
			return successMock
		},
		PollInterval: 10 * time.Millisecond,
	}

	ch := make(chan string, 1)
	ch <- "http://localhost:8000/manage"

	ctx, cancel := context.WithTimeout(context.Background(), 200*time.Millisecond)
	defer cancel()
	Run(ctx, cfg, ch)

	if calls := successMock.getNavigateCalls(); len(calls) == 0 {
		t.Error("Navigate never called after connect failure resolved")
	}
}

func TestLatestURLWins(t *testing.T) {
	// When two URLs are queued before the first poll, only the latest is used.
	mock := &mockClient{}
	ch := make(chan string, 1)

	// Send setup URL then immediately overwrite with normal URL.
	ch <- "http://localhost:8000/manage"
	// Drain and replace with the newer URL (mirrors the inner goroutine logic).
	<-ch
	ch <- "https://kiosk.example.com/view"

	runNavigator(t, mock, ch, 100*time.Millisecond)

	calls := mock.getNavigateCalls()
	if len(calls) == 0 {
		t.Fatal("Navigate never called")
	}
	if calls[0] != "https://kiosk.example.com/view" {
		t.Errorf("Navigate called with %q, want latest URL %q", calls[0], "https://kiosk.example.com/view")
	}
}

func TestURLPrefixNoNavigationOnSubPage(t *testing.T) {
	// Browser is on a sub-page under the prefix — navigator must not redirect.
	mock := &mockClient{currentURL: "http://dashboard.local/lovelace/kitchen"}
	ch := make(chan string, 1)
	ch <- "http://localhost:8000/manage"

	cfg := Config{
		NewClient:    func() Client { return mock },
		PollInterval: 10 * time.Millisecond,
		URLPrefix:    "http://dashboard.local",
	}
	ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
	defer cancel()
	Run(ctx, cfg, ch)

	if calls := mock.getNavigateCalls(); len(calls) != 0 {
		t.Errorf("Navigate called %d times, want 0 (URL is under prefix)", len(calls))
	}
}

func TestURLPrefixNavigatesWhenOffPrefix(t *testing.T) {
	// Browser drifted to an unrelated page — navigator must redirect to target.
	mock := &mockClient{currentURL: "http://other.site/page"}
	ch := make(chan string, 1)
	ch <- "http://localhost:8000/manage"

	cfg := Config{
		NewClient:    func() Client { return mock },
		PollInterval: 10 * time.Millisecond,
		URLPrefix:    "http://dashboard.local",
	}
	ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
	defer cancel()
	Run(ctx, cfg, ch)

	calls := mock.getNavigateCalls()
	if len(calls) == 0 {
		t.Fatal("Navigate never called (URL was outside prefix)")
	}
	if calls[0] != "http://localhost:8000/manage" {
		t.Errorf("Navigate called with %q, want %q", calls[0], "http://localhost:8000/manage")
	}
}

func TestManagePageNeverRedirected(t *testing.T) {
	// User navigated to /manage from the display URL — navigator must not redirect
	// back regardless of what the target URL is.
	for _, host := range []string{"localhost:8000", "nixos-kiosk.local"} {
		mock := &mockClient{currentURL: "http://" + host + "/manage"}
		ch := make(chan string, 1)
		ch <- "http://homeassistant.local/lovelace"

		cfg := Config{
			NewClient:    func() Client { return mock },
			PollInterval: 10 * time.Millisecond,
		}
		ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
		defer cancel()
		Run(ctx, cfg, ch)

		if calls := mock.getNavigateCalls(); len(calls) != 0 {
			t.Errorf("host %s: Navigate called %d times, want 0 (on /manage)", host, len(calls))
		}
	}
}

func TestURLPrefixEmptyFallsBackToExactMatch(t *testing.T) {
	// No prefix set and browser is on a different external URL — must navigate.
	mock := &mockClient{currentURL: "http://other.site/page"}
	ch := make(chan string, 1)
	ch <- "https://kiosk.example.com/view"

	cfg := Config{
		NewClient:    func() Client { return mock },
		PollInterval: 10 * time.Millisecond,
	}
	ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
	defer cancel()
	Run(ctx, cfg, ch)

	calls := mock.getNavigateCalls()
	if len(calls) == 0 {
		t.Fatal("Navigate never called (URL differs from target, no prefix set)")
	}
	if calls[0] != "https://kiosk.example.com/view" {
		t.Errorf("Navigate called with %q, want %q", calls[0], "https://kiosk.example.com/view")
	}
}

func TestURLPrefixManagePageExceptionWinsOverPrefix(t *testing.T) {
	// User is on /manage — must not be redirected even when prefix is set and
	// /manage is not under the prefix.
	mock := &mockClient{currentURL: "http://localhost:8000/manage"}
	ch := make(chan string, 1)
	ch <- "http://dashboard.local/lovelace"

	cfg := Config{
		NewClient:    func() Client { return mock },
		PollInterval: 10 * time.Millisecond,
		URLPrefix:    "http://dashboard.local",
	}
	ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
	defer cancel()
	Run(ctx, cfg, ch)

	if calls := mock.getNavigateCalls(); len(calls) != 0 {
		t.Errorf("Navigate called %d times, want 0 (on /manage, exception must win over prefix)", len(calls))
	}
}

func TestGetURLPrefixOverridesStaticField(t *testing.T) {
	// GetURLPrefix takes precedence over the static URLPrefix field.
	// Browser is on a page under the dynamic prefix — must not redirect.
	mock := &mockClient{currentURL: "http://dynamic.local/page"}
	ch := make(chan string, 1)
	ch <- "http://localhost:8000/manage"

	cfg := Config{
		NewClient:    func() Client { return mock },
		PollInterval: 10 * time.Millisecond,
		URLPrefix:    "http://static.local", // would cause a redirect
		GetURLPrefix: func() string { return "http://dynamic.local" },
	}
	ctx, cancel := context.WithTimeout(context.Background(), 100*time.Millisecond)
	defer cancel()
	Run(ctx, cfg, ch)

	if calls := mock.getNavigateCalls(); len(calls) != 0 {
		t.Errorf("Navigate called %d times, want 0 (GetURLPrefix should override URLPrefix)", len(calls))
	}
}

func TestNoNavigationWithoutURL(t *testing.T) {
	mock := &mockClient{}
	ch := make(chan string)

	runNavigator(t, mock, ch, 100*time.Millisecond)

	if calls := mock.getNavigateCalls(); len(calls) != 0 {
		t.Errorf("Navigate called %d times with no URL sent, want 0", len(calls))
	}
}
