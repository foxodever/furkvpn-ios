package libxray

import (
	"crypto/ecdsa"
	"crypto/elliptic"
	"crypto/rand"
	"crypto/sha256"
	"crypto/x509"
	"crypto/x509/pkix"
	"encoding/hex"
	"encoding/json"
	"encoding/pem"
	"fmt"
	"math/big"
	"net"
	"net/http"
	"net/http/httptest"
	"reflect"
	"strings"
	"testing"
	"time"
)

func TestUpgradeHysteria(t *testing.T) {
	cfg := mustParse(t, `{"outbounds": [
	  {"tag": "hy", "protocol": "hysteria", "streamSettings": {"network": "hysteria", "finalmask": {
	    "udp": [{"type": "salamander", "settings": {"password": "obfs"}}],
	    "quicParams": {"brutalUp": "50 mbps", "udpHop": {"ports": "20000-30000", "interval": "5-10"}}}}},
	  {"tag": "no-interval", "protocol": "hysteria", "streamSettings": {"finalmask": {
	    "quicParams": {"udpHop": {"ports": 443}}}}},
	  {"tag": "no-ports", "protocol": "hysteria", "streamSettings": {"finalmask": {
	    "quicParams": {"udpHop": {"interval": 30}}}}},
	  {"tag": "new-form", "protocol": "hysteria", "streamSettings": {"finalmask": {
	    "udp": [{"type": "udphop", "settings": {"mode": "intervalRemote", "remotePorts": "1-2", "interval": 5}}]}}},
	  {"tag": "vless", "protocol": "vless", "streamSettings": {"network": "tcp"}}
	]}`)
	if !upgradeHysteria(cfg) {
		t.Fatal("nothing changed")
	}
	mask := func(n int) map[string]any {
		return asMap(asMap(cfg["outbounds"].([]any)[n])["streamSettings"])["finalmask"].(map[string]any)
	}
	want := []any{
		map[string]any{"type": "salamander", "settings": map[string]any{"password": "obfs"}},
		map[string]any{"type": "udphop", "settings": map[string]any{
			"mode": "intervalLocal,intervalRemote", "remotePorts": "20000-30000", "interval": "5-10"}},
	}
	if got := mask(0)["udp"]; !reflect.DeepEqual(got, want) {
		t.Errorf("udp = %v", got)
	}
	if got := mask(0)["quicParams"]; !reflect.DeepEqual(got, map[string]any{"brutalUp": "50 mbps"}) {
		t.Errorf("quicParams = %v", got)
	}
	settings := asMap(mask(1)["udp"].([]any)[0])["settings"].(map[string]any)
	if settings["interval"] != defaultHopInterval || settings["remotePorts"] != json.Number("443") {
		t.Errorf("without an interval: %v", settings)
	}
	if _, ok := mask(2)["udp"]; ok {
		t.Errorf("without ports: %v", mask(2))
	}
	if got := len(mask(3)["udp"].([]any)); got != 1 {
		t.Errorf("new form: %d masks", got)
	}
	if upgradeHysteria(cfg) {
		t.Error("changed again")
	}
}

// The servers come from the panel the way Remnawave writes them (obfuscation and the old port
// hopping); the app connects to a Hysteria 2 server of the same core through them.
func TestHysteriaServer(t *testing.T) {
	certPEM, keyPEM, pin := selfSignedCert(t, "hy.furk.test")
	port := freeUDPPort(t)
	lines := func(b []byte) string {
		out, _ := json.Marshal(strings.Split(strings.TrimSpace(string(b)), "\n"))
		return string(out)
	}
	server, err := startTestInstance(mustParse(t, fmt.Sprintf(`{
	  "log": {"loglevel": "none"},
	  "inbounds": [{"protocol": "hysteria", "listen": "127.0.0.1", "port": %d,
	    "settings": {"version": 2, "clients": [{"auth": "secret-auth"}]},
	    "streamSettings": {"network": "hysteria", "hysteriaSettings": {"version": 2},
	      "security": "tls", "tlsSettings": {"alpn": ["h3"], "certificates": [{"certificate": %s, "key": %s}]},
	      "finalmask": {"udp": [{"type": "salamander", "settings": {"password": "obfs-secret"}}]}}}],
	  "outbounds": [{"protocol": "freedom", "settings": {"finalRules": [{"action": "allow"}]}}]}`, port, lines(certPEM), lines(keyPEM))))
	if err != nil {
		t.Fatal(err)
	}
	defer server.Close()

	site := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) { w.WriteHeader(http.StatusNoContent) }))
	defer site.Close()
	client := func(auth string) string {
		return fmt.Sprintf(`{"outbounds": [{"tag": "proxy", "protocol": "hysteria",
	    "settings": {"version": 2, "address": "127.0.0.1", "port": %d},
	    "streamSettings": {"network": "hysteria", "hysteriaSettings": {"version": 2, "auth": %q},
	      "security": "tls", "tlsSettings": {"serverName": "hy.furk.test", "alpn": ["h3"], "pinnedPeerCertSha256": %q},
	      "finalmask": {"udp": [{"type": "salamander", "settings": {"password": "obfs-secret"}}],
	        "quicParams": {"udpHop": {"ports": "%d", "interval": "5"}}}}},
	    {"tag": "direct", "protocol": "freedom"}]}`, port, auth, pin, port)
	}
	if ms, err := MeasureDelay(client("secret-auth"), site.URL, 3000); err != nil || ms < 0 {
		t.Fatalf("delay: %d, %v", ms, err)
	}
	if _, err := MeasureDelay(client("wrong-auth"), site.URL, 3000); err == nil {
		t.Fatal("a wrong password connected")
	}
}

func selfSignedCert(t *testing.T, name string) (certPEM, keyPEM []byte, sha string) {
	t.Helper()
	key, err := ecdsa.GenerateKey(elliptic.P256(), rand.Reader)
	if err != nil {
		t.Fatal(err)
	}
	tmpl := &x509.Certificate{
		SerialNumber: big.NewInt(1),
		Subject:      pkix.Name{CommonName: name},
		DNSNames:     []string{name},
		NotBefore:    time.Now().Add(-time.Hour),
		NotAfter:     time.Now().Add(time.Hour),
		KeyUsage:     x509.KeyUsageDigitalSignature,
		ExtKeyUsage:  []x509.ExtKeyUsage{x509.ExtKeyUsageServerAuth},
	}
	der, err := x509.CreateCertificate(rand.Reader, tmpl, tmpl, &key.PublicKey, key)
	if err != nil {
		t.Fatal(err)
	}
	keyDER, err := x509.MarshalECPrivateKey(key)
	if err != nil {
		t.Fatal(err)
	}
	sum := sha256.Sum256(der)
	return pem.EncodeToMemory(&pem.Block{Type: "CERTIFICATE", Bytes: der}),
		pem.EncodeToMemory(&pem.Block{Type: "EC PRIVATE KEY", Bytes: keyDER}),
		hex.EncodeToString(sum[:])
}

func freeUDPPort(t *testing.T) int {
	t.Helper()
	c, err := net.ListenPacket("udp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer c.Close()
	return c.LocalAddr().(*net.UDPAddr).Port
}
