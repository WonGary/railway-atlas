// Desktop distribution of the web app. Two fixed public sources supply
// station reports and timetable resources on request.
package main

import (
	"context"
	"encoding/json"
	"errors"
	"flag"
	"fmt"
	"io"
	"log"
	"net"
	"net/http"
	"net/url"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"runtime"
	"strconv"
	"strings"
	"time"
	"unicode/utf16"
	"unicode/utf8"
)

const feedHost = "cnrail.geogv.org"

var feedPath = regexp.MustCompile(`^(search|(?:poi|feature|stationroute)/[0-9a-f]{32}|train/[A-Z0-9]{1,12})$`)
var client = &http.Client{
	Timeout: 12 * time.Second,
	CheckRedirect: func(req *http.Request, via []*http.Request) error {
		if len(via) > 2 || req.URL.Host != feedHost || req.URL.User != nil || (req.URL.Scheme != "https" && req.URL.Scheme != "http") {
			return errors.New("unexpected feed redirect")
		}
		return nil
	},
}

// Forward individual ranges from the public schedule file. The browser pins
// the file version across requests and checks resource sizes and checksums.
func timetablePackage(w http.ResponseWriter, r *http.Request) {
	const upstream = "http://down.lltskb.com/lulutong.apk"
	const maxFile = 100000000
	req, err := http.NewRequestWithContext(r.Context(), r.Method, upstream, nil)
	if err != nil {
		http.Error(w, "invalid timetable source", http.StatusBadGateway)
		return
	}
	var start, end int64
	if r.Method == http.MethodGet {
		rangeValue := r.Header.Get("Range")
		first, last, ok := strings.Cut(strings.TrimPrefix(rangeValue, "bytes="), "-")
		var a, b error
		start, a = strconv.ParseInt(first, 10, 64)
		end, b = strconv.ParseInt(last, 10, 64)
		if !ok || a != nil || b != nil || start < 0 || end < start || end >= maxFile || end-start+1 > 4100000 ||
			rangeValue != fmt.Sprintf("bytes=%d-%d", start, end) || r.Header.Get("If-Match") == "" {
			http.Error(w, "invalid timetable range", http.StatusBadRequest)
			return
		}
		req.Header.Set("Range", rangeValue)
		req.Header.Set("If-Match", r.Header.Get("If-Match"))
	}
	req.Header.Set("Accept-Encoding", "identity")
	resp, err := client.Do(req)
	if err != nil {
		http.Error(w, "timetable source unavailable", http.StatusBadGateway)
		return
	}
	defer resp.Body.Close()
	etag := resp.Header.Get("ETag")
	if resp.Request.URL.String() != upstream || etag == "" {
		http.Error(w, "unrecognized timetable version", http.StatusBadGateway)
		return
	}
	w.Header().Set("Cache-Control", "no-store")
	w.Header().Set("ETag", etag)
	w.Header().Set("Content-Type", "application/octet-stream")
	if r.Method == http.MethodHead && resp.StatusCode == http.StatusOK && resp.ContentLength > 0 && resp.ContentLength <= maxFile {
		w.Header().Set("Content-Length", strconv.FormatInt(resp.ContentLength, 10))
		return
	}
	if r.Method != http.MethodGet || resp.StatusCode != http.StatusPartialContent || etag != req.Header.Get("If-Match") ||
		resp.ContentLength != end-start+1 || !strings.HasPrefix(resp.Header.Get("Content-Range"), fmt.Sprintf("bytes %d-%d/", start, end)) {
		http.Error(w, "timetable version or range changed", http.StatusBadGateway)
		return
	}
	w.Header().Set("Content-Length", strconv.FormatInt(resp.ContentLength, 10))
	w.Header().Set("Content-Range", resp.Header.Get("Content-Range"))
	w.WriteHeader(http.StatusPartialContent)
	io.CopyN(w, resp.Body, resp.ContentLength)
}

func stationFeed(w http.ResponseWriter, r *http.Request) {
	path := strings.TrimPrefix(r.URL.Path, "/station-feed/")
	if !feedPath.MatchString(path) {
		http.NotFound(w, r)
		return
	}
	query := url.Values{"locale": {"zhcn"}}
	if path == "search" {
		keyword := strings.TrimSpace(r.URL.Query().Get("keyword"))
		if keyword == "" || utf8.RuneCountInString(keyword) > 80 {
			http.Error(w, "invalid station name", 400)
			return
		}
		query.Set("keyword", keyword)
		path += "/"
	}
	endpoint := url.URL{Scheme: "http", Host: feedHost, Path: "/api/" + path, RawQuery: query.Encode()}
	if strings.HasPrefix(path, "train/") {
		number := strings.TrimPrefix(path, "train/")
		endpoint.Path = "/api/route/CN/" + number
		endpoint.RawPath = "/api/route/CN%2F" + number
	}
	req, err := http.NewRequestWithContext(r.Context(), "GET", endpoint.String(), nil)
	if err != nil {
		http.Error(w, "invalid upstream", 502)
		return
	}
	resp, err := client.Do(req)
	if err != nil {
		http.Error(w, "station feed unavailable", 502)
		return
	}
	defer resp.Body.Close()
	const maximum = 4000000
	data, err := io.ReadAll(io.LimitReader(resp.Body, maximum+1))
	if err != nil || resp.StatusCode != http.StatusOK || len(data) > maximum {
		http.Error(w, "station feed unavailable", 502)
		return
	}
	if len(data) > 0 && data[0] == '"' {
		// Some feeds wrap their JSON in a UTF-16 string. Preserve code units
		// before unwrapping, including surrogate pairs in non-BMP station names.
		var text string
		if json.Unmarshal(data, &text) != nil {
			http.Error(w, "invalid station feed", 502)
			return
		}
		units := utf16.Encode([]rune(text))
		if len(units) < 2 || units[0] < 1 || int(units[0])+1 >= len(units) {
			http.Error(w, "missing station data", 502)
			return
		}
		n := int(units[0])
		payload := units[n+1:]
		for i := range payload {
			payload[i] -= units[1+i%n]
		}
		data = []byte(string(utf16.Decode(payload)))
	}
	if len(data) == 0 && strings.HasPrefix(path, "stationroute/") {
		data = []byte(`{"hash":[],"list":[]}`)
	}
	if !json.Valid(data) {
		http.Error(w, "invalid station data", 502)
		return
	}
	w.Header().Set("Content-Type", "application/json; charset=utf-8")
	w.Header().Set("Cache-Control", "no-store")
	w.Write(data)
}

func main() {
	quiet := flag.Bool("no-open", false, "print the address without opening a browser")
	flag.Parse()
	self, err := os.Executable()
	if err != nil {
		log.Fatal(err)
	}
	root := filepath.Join(filepath.Dir(self), "Web")
	if _, err := os.Stat(filepath.Join(root, "index.html")); err != nil {
		log.Fatal("请先解压整个文件夹，将启动器与 Web 目录放在一起。")
	}
	// A stable loopback origin preserves the browser's IndexedDB and settings.
	listener, err := net.Listen("tcp4", "127.0.0.1:18763")
	if err != nil {
		log.Fatal("本机 18763 端口已被使用。请检查是否已打开铁道漫游。")
	}
	address := listener.Addr().String()
	page := "http://" + address + "/"
	files := http.FileServer(http.Dir(root))
	server := &http.Server{ReadHeaderTimeout: 5 * time.Second, IdleTimeout: 45 * time.Second}
	server.Handler = http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Host != address || (r.Method != "GET" && r.Method != "HEAD") {
			http.Error(w, "invalid request", http.StatusForbidden)
			return
		}
		if strings.HasPrefix(r.URL.Path, "/station-feed/") || r.URL.Path == "/timetable-package" {
			if r.Header.Get("Sec-Fetch-Site") == "cross-site" || (r.Header.Get("Origin") != "" && r.Header.Get("Origin") != "http://"+address) {
				http.Error(w, "local app only", 403)
				return
			}
			if r.URL.Path == "/timetable-package" {
				timetablePackage(w, r)
			} else {
				stationFeed(w, r)
			}
			return
		}
		files.ServeHTTP(w, r)
	})
	fmt.Printf("铁道漫游　%s\n关闭此窗口或按 Ctrl+C 退出。\n", page)
	if !*quiet {
		go func() {
			var cmd *exec.Cmd
			switch runtime.GOOS {
			case "darwin":
				cmd = exec.Command("open", page)
			case "windows":
				cmd = exec.Command("rundll32", "url.dll,FileProtocolHandler", page)
			default:
				cmd = exec.Command("xdg-open", page)
			}
			if err := cmd.Run(); err != nil {
				fmt.Println("请在浏览器打开上面的本机地址。")
			}
		}()
	}
	if err := server.Serve(listener); err != nil && !errors.Is(err, http.ErrServerClosed) && !errors.Is(err, context.Canceled) {
		log.Fatal(err)
	}
}
