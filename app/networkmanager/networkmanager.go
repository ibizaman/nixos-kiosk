package networkmanager

import (
	"fmt"
	"log"
	"net"
	"time"

	"github.com/godbus/dbus/v5"
)

// https://gitlab.com/prismlinux/libs-deletion_scheduled-131984893/golang-deletion_scheduled-82069458/-/blob/network/v0.1.1/network

// DBus interface and path constants.
const (
	nmDest    = "org.freedesktop.NetworkManager"
	nmPath    = "/org/freedesktop/NetworkManager"
	nmIface   = "org.freedesktop.NetworkManager"
	propIface = "org.freedesktop.DBus.Properties"

	nmDeviceIface     = "org.freedesktop.NetworkManager.Device"
	nmWirelessIface   = "org.freedesktop.NetworkManager.Device.Wireless"
	nmAPiface         = "org.freedesktop.NetworkManager.AccessPoint"
	nmActiveConnIface = "org.freedesktop.NetworkManager.Connection.Active"

	nmSettingsPath  = "/org/freedesktop/NetworkManager/Settings"
	nmSettingsIface = "org.freedesktop.NetworkManager.Settings"
	nmConnIface     = "org.freedesktop.NetworkManager.Settings.Connection"

	// anyDevice / anyAP are the "don't care" sentinel paths used by NM.
	anyDevice = dbus.ObjectPath("/")
	anyAP     = dbus.ObjectPath("/")
)

// Client talks to NetworkManager over the system DBus.
// It is not safe for concurrent use — callers are responsible for
// synchronisation (e.g. wrapping it in a mutex-guarded service struct).
type Client struct {
	conn *dbus.Conn
}

// NewClient connects to the system DBus and returns a ready Client.
func NewClient() (*Client, error) {
	conn, err := dbus.ConnectSystemBus()
	if err != nil {
		return nil, fmt.Errorf("network: connect system bus: %w", err)
	}
	return &Client{conn: conn}, nil
}

// Close releases the underlying DBus connection.
func (c *Client) Close() {
	if c.conn != nil {
		_ = c.conn.Close()
	}
}

// snapshot

// NetworkInfo returns a full snapshot: NM state, devices, active connections,
// and deduplicated WiFi access points.
func (c *Client) NetworkInfo() (*NetworkInfo, error) {
	state, err := c.state()
	if err != nil {
		return nil, err
	}

	connectivity, err := c.connectivity()
	if err != nil {
		connectivity = 0 // non-fatal; older NM versions may not expose this
	}

	devices, err := c.Devices()
	if err != nil {
		return nil, err
	}

	active, err := c.ActiveConnections()
	if err != nil {
		return nil, err
	}

	aps, err := c.AccessPoints()
	if err != nil {
		log.Printf("WARN: could not get access points info: %s", err)
		aps = nil // non-fatal; no wifi adapter present
	}

	return &NetworkInfo{
		State:             state,
		StateName:         stateName(state),
		Connectivity:      connectivity,
		Devices:           devices,
		ActiveConnections: active,
		AccessPoints:      aps,
	}, nil
}

// IsConnected returns true when NM reports global (internet) connectivity.
func (c *Client) IsConnected() (bool, error) {
	s, err := c.state()
	if err != nil {
		return false, err
	}
	return s == NMStateConnectedGlobal, nil
}

// list

// Devices returns all NM-managed network devices.
func (c *Client) Devices() ([]NetworkDevice, error) {
	v, err := c.prop(c.obj(nmPath), nmIface, "Devices")
	if err != nil {
		return nil, fmt.Errorf("network: read Devices: %w", err)
	}
	paths, ok := v.Value().([]dbus.ObjectPath)
	if !ok {
		return nil, fmt.Errorf("network: Devices: unexpected type %T", v.Value())
	}

	out := make([]NetworkDevice, 0, len(paths))
	for _, p := range paths {
		dev, err := c.readDevice(p)
		if err != nil {
			continue
		}
		out = append(out, dev)
	}
	return out, nil
}

// ActiveConnections returns all currently active NM connections.
func (c *Client) ActiveConnections() ([]ActiveConnection, error) {
	v, err := c.prop(c.obj(nmPath), nmIface, "ActiveConnections")
	if err != nil {
		return nil, fmt.Errorf("network: read ActiveConnections: %w", err)
	}
	paths, ok := v.Value().([]dbus.ObjectPath)
	if !ok {
		return nil, fmt.Errorf("network: ActiveConnections: unexpected type %T", v.Value())
	}

	out := make([]ActiveConnection, 0, len(paths))
	for _, p := range paths {
		ac, err := c.readActiveConn(p)
		if err != nil {
			continue
		}
		out = append(out, ac)
	}
	return out, nil
}

func (c *Client) GetActiveConnection(path dbus.ObjectPath) (ActiveConnection, error) {
	ac, err := c.readActiveConn(path)
	if err != nil {
		return ActiveConnection{}, err
	}
	return ac, nil
}

func (c *Client) GetActiveConnectionByID(id string) (*ActiveConnection, error) {
	activeConnections, err := c.ActiveConnections()
	if err != nil {
		return nil, fmt.Errorf("could not retrieve networkmanager active connections: %w", err)
	}

	for _, ac := range activeConnections {
		if ac.ID == id {
			return &ac, nil
		}
	}

	return nil, nil
}

// AccessPoints returns deduplicated access points from all WiFi devices.
// Hidden networks (empty SSID) are excluded.
func (c *Client) AccessPoints() ([]AccessPoint, error) {
	devs, err := c.Devices()
	if err != nil {
		return nil, err
	}
	return c.allAccessPoints(devs)
}

// RequestScan triggers a wireless scan on every WiFi device.
// Results become available via AccessPoints after a short delay (~2 s).
func (c *Client) RequestScan() error {
	devs, err := c.Devices()
	if err != nil {
		return err
	}

	opts := map[string]dbus.Variant{} // NM requires an (even empty) options map
	for _, d := range devs {
		if d.Type != NMDeviceTypeWifi {
			continue
		}
		// Best-effort; a device may already be scanning.
		_ = c.obj(dbus.ObjectPath(d.Path)).Call(nmWirelessIface+".RequestScan", 0, opts).Err
	}
	return nil
}

// ListSavedConnections returns all connection profiles stored in NM Settings.
// This is the equivalent of `nmcli connection show`.
func (c *Client) ListSavedConnections() ([]SavedConnection, error) {
	var paths []dbus.ObjectPath
	if err := c.obj(nmSettingsPath).Call(nmSettingsIface+".ListConnections", 0).Store(&paths); err != nil {
		return nil, fmt.Errorf("network: ListConnections: %w", err)
	}

	out := make([]SavedConnection, 0, len(paths))
	for _, p := range paths {
		sc, err := c.readSavedConn(p)
		if err != nil {
			continue
		}
		out = append(out, sc)
	}
	return out, nil
}

// GetSavedConnection returns the profile of the given path.
func (c *Client) GetSavedConnection(path string) (SavedConnection, error) {
	return c.readSavedConn(dbus.ObjectPath(path))
}

func (c *Client) GetSavedConnectionByID(id string) (*SavedConnection, error) {
	savedConnections, err := c.ListSavedConnections()
	if err != nil {
		return nil, fmt.Errorf("could not retrieve networkmanager saved connections: %w", err)
	}

	for _, sc := range savedConnections {
		if sc.ID == id {
			return &sc, nil
		}
	}

	return nil, nil
}

// connect / disconnect

// Connect activates an existing saved connection profile on the best available
// device. connectionPath must be a path returned by ListSavedConnections.
func (c *Client) Connect(connectionPath string) (*ConnectResult, error) {
	cp := dbus.ObjectPath(connectionPath)

	var activePath dbus.ObjectPath
	if err := c.obj(nmPath).Call(
		nmIface+".ActivateConnection", 0,
		cp, anyDevice, anyAP,
	).Store(&activePath); err != nil {
		return nil, fmt.Errorf("network: ActivateConnection: %w", err)
	}

	return &ConnectResult{ActiveConnectionPath: string(activePath)}, nil
}

// CreateWifi creates a WiFi profile.
//
// On success the active connection path is returned.
func (c *Client) CreateWifi(id string, ssid string, password string) (string, error) {
	settings := map[string]map[string]dbus.Variant{
		"connection": {
			"type": dbus.MakeVariant("802-11-wireless"),
		},
		"802-11-wireless": {
			"ssid": dbus.MakeVariant([]byte(ssid)),
			"mode": dbus.MakeVariant("infrastructure"),
		},
	}

	if password != "" {
		settings["802-11-wireless-security"] = map[string]dbus.Variant{
			"key-mgmt": dbus.MakeVariant("wpa-psk"),
			"psk":      dbus.MakeVariant(password),
		}
	}

	return c.createOrUpdate(id, settings)
}

// Disconnect deactivates an active connection.
// activeConnectionPath must be a path from ActiveConnections or ConnectResult.
func (c *Client) Disconnect(activeConnectionPath string) error {
	if err := c.obj(nmPath).Call(
		nmIface+".DeactivateConnection", 0,
		dbus.ObjectPath(activeConnectionPath),
	).Err; err != nil {
		return fmt.Errorf("network: DeactivateConnection: %w", err)
	}
	return nil
}

// CreateAP creates or updates a WiFi access poinrt profile
func (c *Client) CreateOrUpdateAP(id string, ssid string, psk string, ip string, prefix uint8) (string, error) {
	ipNet := net.ParseIP(ip)
	if ipNet == nil {
		return "", fmt.Errorf("CreateOrUpdateAP: ip '%s' is not valid", ip)
	}
	settings := map[string]map[string]dbus.Variant{
		"connection": {
			"type":        dbus.MakeVariant("802-11-wireless"),
			"autoconnect": dbus.MakeVariant(false),
		},
		"802-11-wireless": {
			"mode": dbus.MakeVariant("ap"),
			"ssid": dbus.MakeVariant([]byte(ssid)),
		},
		"802-11-wireless-security": {
			"key-mgmt": dbus.MakeVariant("wpa-psk"),
			"psk":      dbus.MakeVariant(psk),
		},
		"ipv4": {
			"method": dbus.MakeVariant("manual"),
			"address-data": dbus.MakeVariant([]map[string]dbus.Variant{
				{
					"address": dbus.MakeVariant(ip),
					"prefix":  dbus.MakeVariant(uint32(prefix)),
				},
			}),
			"dns-data": dbus.MakeVariant([]string{
				ip,
			}),
			"gateway":         dbus.MakeVariant(ip),
			"ignore-auto-dns": dbus.MakeVariant(true),
		},
		"ipv6": {
			"method": dbus.MakeVariant("disabled"),
		},
	}

	return c.createOrUpdate(id, settings)
}

func (c *Client) createOrUpdate(id string, settings map[string]map[string]dbus.Variant) (string, error) {
	settings["connection"]["id"] = dbus.MakeVariant(id)

	var found *SavedConnection
	if saved, err := c.ListSavedConnections(); err != nil {
		return "", fmt.Errorf("network: could not list existing profiles: %w", err)
	} else {
		for _, s := range saved {
			if s.ID == id {
				found = &s
			}
		}
	}

	var path dbus.ObjectPath
	if found != nil {
		connObj := c.obj(dbus.ObjectPath(found.Path))
		err := connObj.Call(
			nmConnIface+".Update", 0, settings,
		).Err
		if err != nil {
			return "", fmt.Errorf("network: could not update profile: %w", err)
		}
		return found.Path, nil
	} else {
		iface := nmSettingsIface + ".AddConnection"

		if err := c.obj(nmSettingsPath).Call(
			iface, 0, settings,
		).Store(&path); err != nil {
			return "", fmt.Errorf("network: could not create access point: %w", err)
		}
		return string(path), nil
	}
}

func (c *Client) WaitWhileConnecting(path string, timeout time.Duration) (string, error) {
	end := time.Now().Add(timeout)
	var state NMActiveConnectionState
	var err error
	for now := time.Now(); now.Before(end); {
		var a ActiveConnection
		a, err = c.readActiveConn(dbus.ObjectPath(path))
		if err != nil {
			time.Sleep(2 * time.Second)
			continue
		}

		state = NMActiveConnectionState(a.State)
		if state == NMActiveConnectionStateActivating {
			time.Sleep(2 * time.Second)
			continue
		}
		break
	}
	return activeConnectionStateName(state), err
}

// internal helpers

func (c *Client) obj(path dbus.ObjectPath) dbus.BusObject {
	return c.conn.Object(nmDest, path)
}

func (c *Client) prop(obj dbus.BusObject, iface, name string) (dbus.Variant, error) {
	var v dbus.Variant
	err := obj.Call(propIface+".Get", 0, iface, name).Store(&v)
	return v, err
}

func (c *Client) state() (NMState, error) {
	v, err := c.prop(c.obj(nmPath), nmIface, "State")
	if err != nil {
		return NMStateUnknown, fmt.Errorf("network: read State: %w", err)
	}
	u, ok := v.Value().(uint32)
	if !ok {
		return NMStateUnknown, fmt.Errorf("network: State: unexpected type %T", v.Value())
	}
	return NMState(u), nil
}

func (c *Client) connectivity() (uint32, error) {
	v, err := c.prop(c.obj(nmPath), nmIface, "Connectivity")
	if err != nil {
		return 0, err
	}
	u, _ := v.Value().(uint32)
	return u, nil
}

func (c *Client) readDevice(path dbus.ObjectPath) (NetworkDevice, error) {
	obj := c.obj(path)

	ifaceV, _ := c.prop(obj, nmDeviceIface, "Interface")
	typeV, _ := c.prop(obj, nmDeviceIface, "DeviceType")
	stateV, _ := c.prop(obj, nmDeviceIface, "State")

	iface, _ := ifaceV.Value().(string)
	devType, _ := typeV.Value().(uint32)
	state, _ := stateV.Value().(uint32)

	dt := NMDeviceType(devType)
	return NetworkDevice{
		Path:      string(path),
		Interface: iface,
		Type:      dt,
		TypeName:  deviceTypeName(dt),
		State:     state,
		StateName: deviceStateName(state),
	}, nil
}

func (c *Client) readActiveConn(path dbus.ObjectPath) (ActiveConnection, error) {
	obj := c.obj(path)

	idV, _ := c.prop(obj, nmActiveConnIface, "Id")
	uuidV, _ := c.prop(obj, nmActiveConnIface, "Uuid")
	stateV, _ := c.prop(obj, nmActiveConnIface, "State")
	defV, _ := c.prop(obj, nmActiveConnIface, "Default")

	id, _ := idV.Value().(string)
	uuid, _ := uuidV.Value().(string)
	state, _ := stateV.Value().(uint32)
	def, _ := defV.Value().(bool)

	return ActiveConnection{
		Path:      string(path),
		ID:        id,
		UUID:      uuid,
		State:     state,
		StateName: activeConnectionStateName(NMActiveConnectionState(state)),
		Default:   def,
	}, nil
}

func (c *Client) readSavedConn(path dbus.ObjectPath) (SavedConnection, error) {
	obj := c.conn.Object(nmDest, path)

	var raw map[string]map[string]dbus.Variant
	if err := obj.Call(nmConnIface+".GetSettings", 0).Store(&raw); err != nil {
		return SavedConnection{}, fmt.Errorf("network: GetSettings %s: %w", path, err)
	}

	conn := raw["connection"]
	id, _ := conn["id"].Value().(string)
	uuid, _ := conn["uuid"].Value().(string)
	connType, _ := conn["type"].Value().(string)
	autoConnect := true // NM default
	if v, ok := conn["autoconnect"]; ok {
		autoConnect, _ = v.Value().(bool)
	}

	var ssid string
	if wifi, ok := raw["802-11-wireless"]; ok {
		if b, ok := wifi["ssid"].Value().([]byte); ok {
			ssid = string(b)
		}
	}

	return SavedConnection{
		Path:        string(path),
		ID:          id,
		UUID:        uuid,
		Type:        connType,
		SSID:        ssid,
		AutoConnect: autoConnect,
	}, nil
}

func (c *Client) allAccessPoints(devs []NetworkDevice) ([]AccessPoint, error) {
	seen := make(map[string]struct{})
	var out []AccessPoint

	for _, d := range devs {
		if d.Type != NMDeviceTypeWifi {
			log.Printf("AllAccessPoints: ignoring device %s with type %s", d.Path, d.TypeName)
			continue
		}
		aps, err := c.apForDevice(dbus.ObjectPath(d.Path))
		if err != nil {
			log.Printf("AllAccessPoints: could not get access points for device %s: %s", d.Path, err)
			continue
		}
		for _, ap := range aps {
			if ap.SSID == "" {
				log.Printf("AllAccessPoints: ignoring ap for device %s %s with empty SSID", d.Path, ap.Path)
				continue
			}
			if _, dup := seen[ap.SSID]; dup {
				continue
			}
			seen[ap.SSID] = struct{}{}
			out = append(out, ap)
		}
	}
	return out, nil
}

func (c *Client) apForDevice(path dbus.ObjectPath) ([]AccessPoint, error) {
	var apPaths []dbus.ObjectPath
	if err := c.obj(path).Call(nmWirelessIface+".GetAllAccessPoints", 0).Store(&apPaths); err != nil {
		return nil, fmt.Errorf("network: GetAllAccessPoints: %w", err)
	}

	out := make([]AccessPoint, 0, len(apPaths))
	for _, p := range apPaths {
		ap, err := c.readAP(p)
		if err != nil {
			continue
		}
		out = append(out, ap)
	}
	return out, nil
}

func (c *Client) readAP(path dbus.ObjectPath) (AccessPoint, error) {
	obj := c.obj(path)

	ssidV, _ := c.prop(obj, nmAPiface, "Ssid")
	strengthV, _ := c.prop(obj, nmAPiface, "Strength")
	wpaV, _ := c.prop(obj, nmAPiface, "WpaFlags")
	rsnV, _ := c.prop(obj, nmAPiface, "RsnFlags")

	ssidBytes, _ := ssidV.Value().([]byte)
	strength, _ := strengthV.Value().(uint8)
	wpaFlags, _ := wpaV.Value().(uint32)
	rsnFlags, _ := rsnV.Value().(uint32)

	return AccessPoint{
		Path:     string(path),
		SSID:     string(ssidBytes),
		Strength: strength,
		Secured:  wpaFlags > 0 || rsnFlags > 0,
		WpaFlags: wpaFlags,
		RsnFlags: rsnFlags,
	}, nil
}

// name maps

func stateName(s NMState) string {
	switch s {
	case NMStateAsleep:
		return "asleep"
	case NMStateDisconnected:
		return "disconnected"
	case NMStateDisconnecting:
		return "disconnecting"
	case NMStateConnecting:
		return "connecting"
	case NMStateConnectedLocal:
		return "connected_local"
	case NMStateConnectedSite:
		return "connected_site"
	case NMStateConnectedGlobal:
		return "connected_global"
	default:
		return "unknown"
	}
}

func deviceTypeName(t NMDeviceType) string {
	switch t {
	case NMDeviceTypeEthernet:
		return "ethernet"
	case NMDeviceTypeWifi:
		return "wifi"
	case NMDeviceTypeLoopback:
		return "loopback"
	default:
		return "unknown"
	}
}

func deviceStateName(s uint32) string {
	switch s {
	case 10:
		return "unmanaged"
	case 20:
		return "unavailable"
	case 30:
		return "disconnected"
	case 40:
		return "prepare"
	case 50:
		return "config"
	case 60:
		return "need_auth"
	case 70:
		return "ip_config"
	case 80:
		return "ip_check"
	case 90:
		return "secondaries"
	case 100:
		return "activated"
	case 110:
		return "deactivating"
	case 120:
		return "failed"
	default:
		return "unknown"
	}
}

func activeConnectionStateName(s NMActiveConnectionState) string {
	switch s {
	case NMActiveConnectionStateActivating:
		return "activating"
	case NMActiveConnectionStateActivated:
		return "activated"
	case NMActiveConnectionStateDeactivating:
		return "deactivating"
	case NMActiveConnectionStateDeactivated:
		return "deactivated"
	default:
		return "unknown"
	}
}
