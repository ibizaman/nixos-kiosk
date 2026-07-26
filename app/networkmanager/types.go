package networkmanager

// NMState maps to NM_STATE_* constants from NetworkManager.
type NMState uint32

const (
	NMStateUnknown         NMState = 0
	NMStateAsleep          NMState = 10
	NMStateDisconnected    NMState = 20
	NMStateDisconnecting   NMState = 30
	NMStateConnecting      NMState = 40
	NMStateConnectedLocal  NMState = 50
	NMStateConnectedSite   NMState = 60
	NMStateConnectedGlobal NMState = 70
)

// NMDeviceType maps to NM_DEVICE_TYPE_* constants.
type NMDeviceType uint32

const (
	NMDeviceTypeUnknown  NMDeviceType = 0
	NMDeviceTypeEthernet NMDeviceType = 1
	NMDeviceTypeWifi     NMDeviceType = 2
	NMDeviceTypeLoopback NMDeviceType = 14
)

type NMActiveConnectionState uint32

const (
	NMActiveConnectionStateUnknown      NMActiveConnectionState = 0
	NMActiveConnectionStateActivating   NMActiveConnectionState = 1
	NMActiveConnectionStateActivated    NMActiveConnectionState = 2
	NMActiveConnectionStateDeactivating NMActiveConnectionState = 3
	NMActiveConnectionStateDeactivated  NMActiveConnectionState = 4
)

// NetworkDevice is a snapshot of a single NM device.
type NetworkDevice struct {
	Path      string       `json:"path"`
	Interface string       `json:"interface"`
	Type      NMDeviceType `json:"type"`
	TypeName  string       `json:"typeName"`
	State     uint32       `json:"state"`
	StateName string       `json:"stateName"`
}

// AccessPoint is a snapshot of a single WiFi access point.
type AccessPoint struct {
	Path     string `json:"path"`
	SSID     string `json:"ssid"`
	Strength uint8  `json:"strength"`
	Secured  bool   `json:"secured"`
	WpaFlags uint32 `json:"wpaFlags"`
	RsnFlags uint32 `json:"rsnFlags"`
}

// ActiveConnection is a snapshot of one active NM connection.
type ActiveConnection struct {
	Path      string `json:"path"`
	ID        string `json:"id"`
	UUID      string `json:"uuid"`
	State     uint32 `json:"state"`
	StateName string `json:"stateName"`
	Default   bool   `json:"default"` // true when this is the default IPv4 route
}

// SavedConnection is a connection profile stored in NM Settings.
// These are the profiles visible in nmcli connection show.
type SavedConnection struct {
	Path        string `json:"path"`
	ID          string `json:"id"` // human-readable name
	UUID        string `json:"uuid"`
	Type        string `json:"type"` // "802-11-wireless", "802-3-ethernet", etc.
	SSID        string `json:"ssid"` // non-empty for WiFi profiles only
	AutoConnect bool   `json:"autoConnect"`
}

// ConnectResult is returned by Connect and ConnectWifi.
type ConnectResult struct {
	// ActiveConnectionPath is the DBus path of the newly activated connection.
	ActiveConnectionPath string `json:"activeConnectionPath"`
}

// NetworkInfo is the full snapshot of NM state.
type NetworkInfo struct {
	State             NMState            `json:"state"`
	StateName         string             `json:"stateName"`
	Connectivity      uint32             `json:"connectivity"` // NM_CONNECTIVITY_*
	Devices           []NetworkDevice    `json:"devices"`
	ActiveConnections []ActiveConnection `json:"activeConnections"`
	AccessPoints      []AccessPoint      `json:"accessPoints"` // deduplicated by SSID
}
