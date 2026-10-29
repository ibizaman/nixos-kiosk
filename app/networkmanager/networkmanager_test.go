package networkmanager

import "testing"

func TestIsActivatingOrActivated(t *testing.T) {
	tests := []struct {
		state    NMActiveConnectionState
		want     bool
	}{
		{NMActiveConnectionStateUnknown, false},
		{NMActiveConnectionStateActivating, true},
		{NMActiveConnectionStateActivated, true},
		{NMActiveConnectionStateDeactivating, false},
		{NMActiveConnectionStateDeactivated, false},
	}
	for _, tt := range tests {
		ac := ActiveConnection{State: uint32(tt.state)}
		if got := ac.IsActivatingOrActivated(); got != tt.want {
			t.Errorf("state %d: IsActivatingOrActivated() = %v, want %v", tt.state, got, tt.want)
		}
	}
}
