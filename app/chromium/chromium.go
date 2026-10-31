package chromium

import (
	"context"
	"encoding/base64"
	"encoding/json"
	"errors"
	"fmt"
	"net/http"
	"time"

	"github.com/gorilla/websocket"
)

type Client struct {
	addr string
	ws   *websocket.Conn
}

func NewClient(ip string, port uint16) Client {
	return Client{
		addr: fmt.Sprintf("http://%s:%d", ip, port),
	}
}

type targetInfo struct {
	Type                 string `json:"type"`
	WebSocketDebuggerURL string `json:"webSocketDebuggerUrl"`
	URL                  string `json:"url"`
}

func (c *Client) Connect() (func() error, error) {
	if c.ws != nil {
		if err := c.ws.Close(); err != nil {
			return nil, fmt.Errorf(" %s", err)
		}
	}

	resp, err := http.Get(fmt.Sprintf("%s/json/list", c.addr))
	if err != nil {
		return nil, err
	}
	defer resp.Body.Close()

	var targets []targetInfo
	if err := json.NewDecoder(resp.Body).Decode(&targets); err != nil {
		return nil, err
	}

	var wsURL string
	for _, t := range targets {
		if t.Type == "page" {
			wsURL = t.WebSocketDebuggerURL
			break
		}
	}
	if wsURL == "" {
		return nil, fmt.Errorf("no page target found")
	}

	c.ws, _, err = websocket.DefaultDialer.Dial(wsURL, nil)
	if err != nil {
		return nil, err
	}
	return c.ws.Close, err
}

func (c Client) GetCurrentURL() (string, error) {
	resp, err := http.Get(fmt.Sprintf("%s/json/list", c.addr))
	if err != nil {
		return "", err
	}
	defer resp.Body.Close()

	var targets []targetInfo
	if err := json.NewDecoder(resp.Body).Decode(&targets); err != nil {
		return "", err
	}

	var url string
	for _, t := range targets {
		if t.Type == "page" {
			url = t.URL
			break
		}
	}
	if url == "" {
		return "", fmt.Errorf("no url found")
	}
	return url, nil
}

func (c Client) Navigate(url string) error {
	if c.ws == nil {
		return errors.New("No socket connected, call .Connect first")
	}

	resp, err := sendAndGet(c.ws, Request{
		ID:     42,
		Method: "Page.navigate",
		Params: map[string]string{
			"url": url,
		},
	})
	if err != nil {
		return err
	}

	if resp.Error != "" {
		return errors.New(resp.Error)
	}
	return nil
}

type screenshotRequest struct {
	ID     int    `json:"id"`
	Method string `json:"method"`
	Params struct {
		Format                string `json:"format"`
		CaptureBeyondViewport bool   `json:"captureBeyondViewport"`
	} `json:"params"`
}

type screenshotResult struct {
	ID     int    `json:"id"`
	Error  string `json:"error"`
	Result struct {
		Data string `json:"data"`
	} `json:"result"`
}

func (c Client) Screenshot() ([]byte, error) {
	if c.ws == nil {
		return nil, errors.New("not connected, call Connect first")
	}

	var req screenshotRequest
	req.ID = 43
	req.Method = "Page.captureScreenshot"
	req.Params.Format = "png"
	req.Params.CaptureBeyondViewport = true

	if err := c.ws.WriteJSON(req); err != nil {
		return nil, err
	}

	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()

	for {
		select {
		case <-ctx.Done():
			return nil, ctx.Err()
		default:
			var r screenshotResult
			if err := c.ws.ReadJSON(&r); err != nil {
				return nil, err
			}
			if r.ID != req.ID {
				continue
			}
			if r.Error != "" {
				return nil, errors.New(r.Error)
			}
			return base64.StdEncoding.DecodeString(r.Result.Data)
		}
	}
}

type Request struct {
	ID     int               `json:"id"`
	Method string            `json:"method"`
	Params map[string]string `json:"params,omitempty"`
}

func NewRequest(Method string) Request {
	return Request{
		Method: Method,
		Params: make(map[string]string),
	}
}

func (r *Request) AddParam(key string, value string) *Request {
	r.Params[key] = value
	return r
}

type Response struct {
	ID    int    `json:"id"`
	Error string `json:"error"`
}

func sendAndGet(ws *websocket.Conn, send Request) (Response, error) {
	err := ws.WriteJSON(send)
	if err != nil {
		return Response{}, err
	}

	return readResponseResponse(ws, send.ID)
}

func readResponseResponse(ws *websocket.Conn, ID int) (Response, error) {
	if ws == nil {
		return Response{}, errors.New("No socket connected, call .Connect first")
	}

	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()

	for {
		select {
		case <-ctx.Done():
			return Response{}, ctx.Err()

		default:
			var r Response
			if err := ws.ReadJSON(&r); err != nil {
				return r, err
			}
			if r.ID != ID {
				continue
			}
			return r, nil
		}
	}
}
