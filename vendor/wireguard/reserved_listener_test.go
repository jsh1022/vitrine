// Vitrine regression: Objective-C reserves the SOCKS listener before async Go startup.
package main

import (
	"io"
	"net"
	"testing"
	"time"

	"ytmuwg/internal/testpeer"
)

func TestReservedListenerSurvivesAsynchronousStartup(t *testing.T) {
	peer, err := testpeer.Start(testpeer.Options{Keepalive: 0})
	if err != nil {
		t.Fatal(err)
	}
	t.Cleanup(peer.Close)
	profile, err := ParseProfile(peer.ClientConfig)
	if err != nil {
		t.Fatal(err)
	}
	reserved, err := net.ListenTCP("tcp4", &net.TCPAddr{IP: net.IPv4(127, 0, 0, 1)})
	if err != nil {
		t.Fatal(err)
	}
	port := reserved.Addr().(*net.TCPAddr).Port
	// A client can queue a SOCKS greeting while the Go engine is not initialized.
	queued, err := net.DialTimeout("tcp4", reserved.Addr().String(), time.Second)
	if err != nil {
		reserved.Close()
		t.Fatal(err)
	}
	t.Cleanup(func() { queued.Close() })
	if _, err = queued.Write([]byte{5, 1, 2}); err != nil {
		reserved.Close()
		t.Fatal(err)
	}
	file, err := reserved.File()
	reserved.Close()
	if err != nil {
		t.Fatal(err)
	}
	// Same descriptor-adoption sequence used by YTMUWGStart's C bridge.
	adopted, err := net.FileListener(file)
	file.Close()
	if err != nil {
		t.Fatal(err)
	}
	engine, err := StartEngine(profile, testUser, testPass, EngineOptions{Listener: adopted, DialTimeout: 4 * time.Second})
	if err != nil {
		adopted.Close()
		t.Fatal(err)
	}
	t.Cleanup(engine.Close)
	if engine.Port() != port {
		t.Fatalf("reserved port changed: %d -> %d", port, engine.Port())
	}
	queued.SetReadDeadline(time.Now().Add(3 * time.Second))
	response := make([]byte, 2)
	if _, err = io.ReadFull(queued, response); err != nil || response[0] != 5 || response[1] != 2 {
		t.Fatalf("queued SOCKS greeting lost during startup: %v %v", response, err)
	}
	queued.Close()
	h := &harness{peer: peer, engine: engine}
	status, body, _ := get(t, h.socksClient(t, testUser, testPass), "https://fixture.test/", "")
	if status != 200 || body != "through-tunnel" {
		t.Fatalf("TLS request did not use adopted listener: %d %q", status, body)
	}
}
