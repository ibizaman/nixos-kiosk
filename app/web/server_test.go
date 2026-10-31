package web

import (
	"context"
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
