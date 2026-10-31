package web

import (
	"context"
	"embed"
	"encoding/json"
	"errors"
	"fmt"
	"html/template"
	"log"
	"net"
	"net/http"
	"os"
	"sync"
	"time"

	"github.com/godbus/dbus/v5"
	"github.com/ibizaman/nixos-kiosk/networkmanager"
	"github.com/skip2/go-qrcode"
)

//go:embed *.html
var htmlFiles embed.FS
var htmlTemplates = template.Must(template.ParseFS(htmlFiles, "*.html"))

type ConnectionStatus string

const ConnectionStatusInitial ConnectionStatus = "initial"
const ConnectionStatusError ConnectionStatus = "error"
const ConnectionStatusSuccess ConnectionStatus = "success"

type LiveData struct {
	ConnectionStatus chan<- ConnectionStatus
}

type Settings struct {
	UpdateURL    string `json:"updateUrl"`
	MDNSHostname string `json:"mdnsHostname"`
}

type ServerConfig struct {
	Addr            string
	HotspotSSID     string
	HotspotPSK      string
	SettingsPath    string
	DefaultSettings Settings
}

type ManagePageData struct {
	APMode        bool
	ConnectedSSID string
	Strength      uint8
	HotspotSSID   string
	HotspotPSK    string
	Settings      Settings
}

func Start(ctx context.Context, nm *networkmanager.Client, cfg ServerConfig) (LiveData, <-chan error) {
	mux := http.NewServeMux()
	settingsMu := &sync.Mutex{}

	statusCh := make(chan ConnectionStatus, 1)
	ld := LiveData{ConnectionStatus: statusCh}
	// Drain so daemon sends never block.
	go func() {
		for range statusCh {
		}
	}()

	mux.HandleFunc("GET /manage", managePage(nm, cfg, settingsMu))
	mux.HandleFunc("POST /manage/wifi", wifiConnectPost(nm))
	mux.HandleFunc("GET /manage/wifi/status", wifiStatusGet(nm))
	mux.HandleFunc("POST /manage/settings", settingsPost(cfg, settingsMu))
	mux.HandleFunc("/wifi.png", qrcodeImage(cfg.HotspotSSID, cfg.HotspotPSK))

	mux.HandleFunc("/connect", func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, "/manage", http.StatusMovedPermanently)
	})
	mux.HandleFunc("/status", func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, "/manage/wifi/status?"+r.URL.RawQuery, http.StatusMovedPermanently)
	})
	// POST /{$} kept for backwards compatibility with existing clients.
	mux.HandleFunc("POST /{$}", wifiConnectPost(nm))
	mux.HandleFunc("GET /{$}", func(w http.ResponseWriter, r *http.Request) {
		http.Redirect(w, r, "/manage", http.StatusFound)
	})

	server := &http.Server{
		Addr:         cfg.Addr,
		Handler:      mux,
		ReadTimeout:  10 * time.Second,
		WriteTimeout: 60 * time.Second,
	}

	log.Printf("listening on %s\n", cfg.Addr)

	errChan := make(chan error, 1)
	go func() {
		err := serve(ctx, server)
		switch {
		case errors.Is(err, http.ErrServerClosed), errors.Is(err, context.Canceled):
			errChan <- nil
		default:
			errChan <- err
		}
	}()

	return ld, errChan
}

func serve(ctx context.Context, srv *http.Server) error {
	ln, err := net.Listen("tcp", srv.Addr)
	if err != nil {
		return err
	}
	sdNotify("READY=1\n")

	errCh := make(chan error, 1)
	go func() {
		errCh <- srv.Serve(ln)
	}()
	select {
	case <-ctx.Done():
		shutdownCtx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
		defer cancel()
		if err := srv.Shutdown(shutdownCtx); err != nil {
			return err
		}
		return <-errCh
	case err := <-errCh:
		return err
	}
}

func managePage(nm *networkmanager.Client, cfg ServerConfig, mu *sync.Mutex) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		log.Printf("%s: [%s] %s", r.RemoteAddr, r.Method, r.RequestURI)

		activeConn, err := nm.GetActiveConnectionByID("kiosk")
		if err != nil {
			log.Printf("managePage: get active connection: %s", err)
		}
		apMode := activeConn == nil || !activeConn.IsActivatingOrActivated()

		var connectedSSID string
		var strength uint8
		if !apMode {
			if info, err := nm.GetActiveWifiInfo(); err == nil && info != nil {
				connectedSSID = info.SSID
				strength = info.Strength
			}
		}

		mu.Lock()
		settings := loadSettings(cfg.SettingsPath, cfg.DefaultSettings)
		mu.Unlock()

		data := ManagePageData{
			APMode:        apMode,
			ConnectedSSID: connectedSSID,
			Strength:      strength,
			HotspotSSID:   cfg.HotspotSSID,
			HotspotPSK:    cfg.HotspotPSK,
			Settings:      settings,
		}
		if err := htmlTemplates.ExecuteTemplate(w, "manage.html", data); err != nil {
			log.Printf("managePage: template: %s", err)
		}
	}
}

type wifiConnectResponse struct {
	Status string `json:"status"`
	Path   string `json:"path,omitempty"`
	Error  string `json:"error,omitempty"`
}

func wifiConnectPost(nm *networkmanager.Client) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		log.Printf("%s: [%s] %s", r.RemoteAddr, r.Method, r.RequestURI)

		if err := r.ParseForm(); err != nil {
			writeJSON(w, http.StatusBadRequest, wifiConnectResponse{Status: "error", Error: "invalid form data"})
			return
		}

		ssid := r.FormValue("ssid")
		password := r.FormValue("password")

		if ssid == "" {
			writeJSON(w, http.StatusBadRequest, wifiConnectResponse{Status: "error", Error: "SSID cannot be empty"})
			return
		}
		if len(password) < 8 {
			writeJSON(w, http.StatusBadRequest, wifiConnectResponse{Status: "error", Error: "Password must be 8 characters minimum"})
			return
		}

		path, err := nm.CreateWifi("kiosk", ssid, password)
		if err != nil {
			log.Printf("wifiConnectPost: create: %s", err)
			writeJSON(w, http.StatusInternalServerError, wifiConnectResponse{Status: "error", Error: err.Error()})
			return
		}

		result, err := nm.Connect(path)
		if err != nil {
			log.Printf("wifiConnectPost: connect: %s", err)
			writeJSON(w, http.StatusInternalServerError, wifiConnectResponse{Status: "error", Error: err.Error()})
			return
		}

		writeJSON(w, http.StatusOK, wifiConnectResponse{Status: "ok", Path: result.ActiveConnectionPath})
	}
}

type wifiStatusResponse struct {
	Status string `json:"status"`
	State  string `json:"state,omitempty"`
	Error  string `json:"error,omitempty"`
}

func wifiStatusGet(nm *networkmanager.Client) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		log.Printf("%s: [%s] %s", r.RemoteAddr, r.Method, r.RequestURI)

		path := r.URL.Query().Get("path")
		if path == "" {
			writeJSON(w, http.StatusBadRequest, wifiStatusResponse{Status: "error", Error: "missing query parameter path"})
			return
		}
		if len(path) > 256 {
			writeJSON(w, http.StatusBadRequest, wifiStatusResponse{Status: "error", Error: "path too long"})
			return
		}
		objPath := dbus.ObjectPath(path)
		if !objPath.IsValid() {
			writeJSON(w, http.StatusBadRequest, wifiStatusResponse{Status: "error", Error: "invalid dbus path"})
			return
		}

		ac, err := nm.GetActiveConnection(objPath)
		if err != nil {
			writeJSON(w, http.StatusInternalServerError, wifiStatusResponse{
				Status: "error",
				Error:  fmt.Sprintf("could not verify connection status: %s", err),
			})
			return
		}
		writeJSON(w, http.StatusOK, wifiStatusResponse{Status: "ok", State: ac.StateName})
	}
}

type settingsResponse struct {
	Status string `json:"status"`
	Error  string `json:"error,omitempty"`
}

func settingsPost(cfg ServerConfig, mu *sync.Mutex) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		log.Printf("%s: [%s] %s", r.RemoteAddr, r.Method, r.RequestURI)

		if err := r.ParseForm(); err != nil {
			writeJSON(w, http.StatusBadRequest, settingsResponse{Status: "error", Error: "invalid form data"})
			return
		}

		mu.Lock()
		defer mu.Unlock()

		s := loadSettings(cfg.SettingsPath, cfg.DefaultSettings)
		if v := r.FormValue("hostname"); v != "" {
			s.MDNSHostname = v
		}
		if v := r.FormValue("updateUrl"); v != "" {
			s.UpdateURL = v
		}

		if err := saveSettings(cfg.SettingsPath, s); err != nil {
			log.Printf("settingsPost: save: %s", err)
			writeJSON(w, http.StatusInternalServerError, settingsResponse{Status: "error", Error: err.Error()})
			return
		}
		writeJSON(w, http.StatusOK, settingsResponse{Status: "ok"})
	}
}

func qrcodeImage(ssid string, psk string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		log.Printf("%s: [%s] %s", r.RemoteAddr, r.Method, r.RequestURI)
		payload := fmt.Sprintf("WIFI:T:WPA;S:%s;P:%s;;", ssid, psk)
		png, err := qrcode.Encode(payload, qrcode.Medium, 512)
		if err != nil {
			http.Error(w, err.Error(), http.StatusInternalServerError)
			return
		}
		w.Header().Set("Content-Type", "image/png")
		_, _ = w.Write(png)
	}
}

func loadSettings(path string, defaults Settings) Settings {
	data, err := os.ReadFile(path)
	if err != nil {
		return defaults
	}
	var s Settings
	if err := json.Unmarshal(data, &s); err != nil {
		return defaults
	}
	return s
}

func saveSettings(path string, s Settings) error {
	data, err := json.Marshal(s)
	if err != nil {
		return err
	}
	return os.WriteFile(path, data, 0o644)
}

func writeJSON(w http.ResponseWriter, status int, resp any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(resp)
}

// sdNotify sends state to systemd via NOTIFY_SOCKET. No-op outside systemd.
func sdNotify(state string) {
	socket := os.Getenv("NOTIFY_SOCKET")
	if socket == "" {
		return
	}
	conn, err := net.DialUnix("unixgram", nil, &net.UnixAddr{Name: socket, Net: "unixgram"})
	if err != nil {
		log.Printf("sdNotify: %s", err)
		return
	}
	defer conn.Close()
	if _, err := conn.Write([]byte(state)); err != nil {
		log.Printf("sdNotify: write: %s", err)
	}
}
