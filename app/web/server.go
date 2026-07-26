package web

import (
	"embed"
	"encoding/json"
	"errors"
	"fmt"
	"html/template"
	"log"
	"net/http"
	"time"

	"github.com/godbus/dbus/v5"
	"github.com/ibizaman/nixos-kiosk/networkmanager"
	"github.com/skip2/go-qrcode"
)

//go:embed *.html
var htmlFiles embed.FS
var htmlTemplates = template.Must(template.ParseFS(htmlFiles, "*.html"))

func Start(nm *networkmanager.Client, addr string, ssid string, psk string) error {
	mux := http.NewServeMux()

	mux.HandleFunc("/connect", qrcodePage(ssid, psk))
	mux.HandleFunc("/wifi.png", qrcodeImage(ssid, psk))

	mux.HandleFunc("/", setupPage(nm))
	mux.HandleFunc("/status", setupPollPage(nm))

	server := &http.Server{
		Addr:         ":8000",
		Handler:      mux,
		ReadTimeout:  10 * time.Second,
		WriteTimeout: 60 * time.Second,
	}

	log.Printf("listening on %s\n", addr)

	err := server.ListenAndServe()
	if errors.Is(err, http.ErrServerClosed) {
		return nil
	}
	return err
}

type Data struct {
	SSID string
	PSK  string
}

func qrcodePage(ssid string, psk string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		log.Printf("%s: [%s] %s", r.RemoteAddr, r.Method, r.RequestURI)
		htmlTemplates.ExecuteTemplate(w, "connect.html", Data{
			SSID: ssid,
			PSK:  psk,
		})
	}
}

func qrcodeImage(ssid string, psk string) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		log.Printf("%s: [%s] %s", r.RemoteAddr, r.Method, r.RequestURI)
		payload := fmt.Sprintf(
			"WIFI:T:WPA;S:%s;P:%s;;",
			ssid,
			psk,
		)

		png, err := qrcode.Encode(
			payload,
			qrcode.Medium,
			512,
		)

		if err != nil {
			http.Error(w, err.Error(), 500)
			return
		}

		w.Header().Set("Content-Type", "image/png")
		w.Write(png)
	}
}

type SetupData struct {
	AccessPoints     []networkmanager.AccessPoint
	SavedConnections []networkmanager.SavedConnection
	Message          string
	Error            SetupFormResponse
}

type SetupFormResponse struct {
	Status string `json:"status"`
	Path   string `json:"path"`
	Error  string `json:"error"`
}

func setupPage(nm *networkmanager.Client) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		log.Printf("%s: [%s] %s", r.RemoteAddr, r.Method, r.RequestURI)
		if r.Method == "POST" {
			if err := r.ParseForm(); err != nil {
				log.Printf("%s: [%s] %s: %s", r.RemoteAddr, r.Method, r.RequestURI, err)
				writeJSON(w, http.StatusBadRequest, SetupFormResponse{
					Status: "error",
					Error:  "Invalid form data",
				})
				return
			}

			ssid := r.FormValue("ssid")
			password := r.FormValue("password")

			if ssid == "" {
				writeJSON(w, http.StatusBadRequest, SetupFormResponse{
					Status: "error",
					Error:  "SSID cannot be empty",
				})
				return
			}

			if len(password) < 8 {
				writeJSON(w, http.StatusBadRequest, SetupFormResponse{
					Status: "error",
					Error:  "Password should be 8 characters minimum",
				})
				return
			}

			path, err := nm.CreateWifi("kiosk", ssid, password)
			if err != nil {
				log.Printf("%s: [%s] %s: %s", r.RemoteAddr, r.Method, r.RequestURI, err)
				writeJSON(w, http.StatusInternalServerError, SetupFormResponse{
					Status: "error",
					Error:  err.Error(),
				})
				return
			}

			activeConnectionPath, err := nm.Connect(path)
			if err != nil {
				log.Printf("%s: [%s] %s: %s", r.RemoteAddr, r.Method, r.RequestURI, err)
				writeJSON(w, http.StatusInternalServerError, SetupFormResponse{
					Status: "error",
					Error:  err.Error(),
				})
				return
			}

			writeJSON(w, http.StatusOK, SetupFormResponse{
				Status: "ok",
				Path:   activeConnectionPath.ActiveConnectionPath,
			})
			return
		}

		accessPoints, err := nm.AccessPoints()
		if err != nil {
			log.Printf("could not find access points: %s", err)
		}
		savedConnections, err := nm.ListSavedConnections()
		if err != nil {
			log.Printf("could not find access points: %s", err)
		}

		data := SetupData{
			AccessPoints:     accessPoints,
			SavedConnections: savedConnections,
		}

		htmlTemplates.ExecuteTemplate(w, "setup.html", data)
	}
}

type SetupPollResponse struct {
	Status string `json:"status"`
	State  string `json:"state"`
	Error  string `json:"error"`
}

func setupPollPage(nm *networkmanager.Client) http.HandlerFunc {
	return func(w http.ResponseWriter, r *http.Request) {
		log.Printf("%s: [%s] %s", r.RemoteAddr, r.Method, r.RequestURI)

		queries := r.URL.Query()
		path := queries.Get("path")
		if path == "" {
			writeJSON(w, http.StatusBadRequest, SetupPollResponse{
				Status: "error",
				Error:  "missing query parameter path",
			})
		}

		if len(path) > 256 {
			writeJSON(w, http.StatusBadRequest, SetupPollResponse{
				Status: "error",
				Error:  "path too long, max 256 characters accepted",
			})
			return
		}
		objPath := dbus.ObjectPath(path)
		if !objPath.IsValid() {
			writeJSON(w, http.StatusBadRequest, SetupPollResponse{
				Status: "error",
				Error:  "invalid dbus path",
			})
			return
		}

		activeConnection, err := nm.GetActiveConnection(objPath)
		if err != nil {
			writeJSON(w, http.StatusInternalServerError, SetupPollResponse{
				Status: "error",
				Error:  fmt.Sprintf("could not verify connection status: %s", err),
			})
			return
		}

		writeJSON(w, http.StatusOK, SetupPollResponse{
			Status: "ok",
			State:  activeConnection.StateName,
		})
	}
}

func writeJSON(w http.ResponseWriter, status int, resp any) {
	w.Header().Set("Content-Type", "application/json")
	w.WriteHeader(status)
	_ = json.NewEncoder(w).Encode(resp)
}
